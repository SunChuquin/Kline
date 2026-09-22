#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""新旧两份 txt 目录的「变更判定」——**全项目唯一一份实现**。

为什么必须只有一份
------------------
`tdx_parser.py`（导入）与 `TrollRestore/diff_live_patch.py`（差分）都要回答同一个问题：
"这次增量更新里，哪些标的的 txt 真变了？" 两处各写一套，迟早漂移（一边按 size 判、
一边按 mtime 判），于是导入漏读、差分漏比，且很难发现。所以把判定抽成本模块，
两边共同 import。

为什么"变更"必须整文件重读（正确性，不是优化）
----------------------------------------------
主库存的是**前复权**K线；通达信每次除权除息会**重新缩放该标的的全部历史价格**。
缩放后每行价格字符数常常不变 → 文件**尺寸一模一样**，旧逻辑 `getsize==meta.last_size`
会把这种改写**永久漏掉**。因此本模块把"内容/时间戳任一不同"判为变更，调用方据此
**从头读整个 txt**。

三种判定 mode（按文件名 basename 配对，txt 目录是平铺的）
----------------------------------------------------------
· `stat`    比 (size, st_mtime_ns)，只 stat 不读内容 —— 实测 **~0.1s / 3637 文件**。
· `content` Python hashlib.sha256 全量内容比对（1MB 分块，不整读入内存）—— 实测 **~30s / 701MB×2**。
· `bc`      Beyond Compare 5 CLI，`criteria crc` 只比 CRC（不读全文、也不改文件时间）—— 实测 **~27s**。
            找不到 BCompare.exe 或 CLI 失败时**自动退回 `content`**，并在 `detail` 里写明原因（不报错中断）。

对外只暴露 `changed_files(old_dir, new_dir, mode="stat", bc_exe=None, timeout=900)`。

命令行自测
----------
    python txt_changes.py <old_dir> <new_dir> [stat|content|bc]
生成一份小目录（改 3 个同尺寸文件 + 删 1 + 增 1），三种 mode 都应报出同样 5 个变更。
"""

import hashlib
import os
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

# BC 报告里代表"有变化"的状态码（**英文、与 BC 界面语言无关**）
BC_CHANGE_STATUSES = {"diff", "ltonly", "rtonly", "ltnewer", "rtnewer"}
BC_CANDIDATES = (
    r"C:\Program Files\Beyond Compare 5\BCompare.exe",
    r"C:\Program Files (x86)\Beyond Compare 5\BCompare.exe",
)
_CHUNK = 1 << 20          # 1MB 分块，避免整文件读入内存


# ---------------------------------------------------------------------------
# 三种 mode 的实现
# ---------------------------------------------------------------------------

def _scan_stat(directory):
    """stat 判定用：{basename: (size, st_mtime_ns)}，只 stat 不读内容（~0.1s/3637）。"""
    out = {}
    with os.scandir(directory) as it:
        for e in it:
            if e.is_file():
                st = e.stat()
                out[e.name] = (st.st_size, st.st_mtime_ns)
    return out


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(_CHUNK), b""):
            h.update(chunk)
    return h.digest()


def _compare_stat(old_dir, new_dir, only_old, only_new, both):
    o = _scan_stat(old_dir)
    n = _scan_stat(new_dir)
    changed = set(o) ^ set(n)                      # 只在单侧 = 该侧新增/删除 → 也算变更
    for name in set(o) & set(n):
        if o[name] != n[name]:
            changed.add(name)
    return {"changed": changed, "only_old": set(o) - set(n), "only_new": set(n) - set(o)}


def _compare_content(old_dir, new_dir, only_old, only_new, both):
    changed = set(only_old) | set(only_new)
    for name in both:
        if _sha256(os.path.join(old_dir, name)) != _sha256(os.path.join(new_dir, name)):
            changed.add(name)
    return {"changed": changed, "only_old": set(only_old), "only_new": set(only_new)}


def _local(tag):
    return tag.rsplit("}", 1)[-1]


def _find_bc_exe(explicit=None):
    """优先显式路径，其次 Program Files / Program Files (x86)；找不到返回 None。"""
    for cand in ([explicit] if explicit else []) + list(BC_CANDIDATES):
        if cand and os.path.isfile(cand):
            return cand
    return None


def _compare_bc(old_dir, new_dir, only_old, only_new, both, bc_exe, timeout):
    """调用 BC 5 CLI 做内容比对（criteria crc）。返回 (结果, detail)；失败抛异常由上层退回。"""
    script = (
        'load "%s" "%s"\n'
        "criteria crc\n"
        "expand all\n"
        'folder-report layout:xml options:display-mismatches output-to:"%s"\n'
    )
    fd_s, script_path = tempfile.mkstemp(suffix=".txt", prefix="bc_cmp_")
    fd_r, report_path = tempfile.mkstemp(suffix=".xml", prefix="bc_rep_")
    os.close(fd_s)
    os.close(fd_r)
    try:
        with open(script_path, "w", encoding="utf-8") as fh:
            fh.write(script % (old_dir, new_dir, report_path))
        # /silent /closescript 必须带，否则会弹 GUI 挂住；**不要**用 shell=True
        proc = subprocess.run([bc_exe, "/silent", "/closescript", "@" + script_path],
                              capture_output=True, timeout=timeout)
        if proc.returncode != 0:
            raise RuntimeError("BCompare 退出码 %d: %s"
                               % (proc.returncode, (proc.stderr or b"").decode("utf-8", "replace")[:200]))
        if not os.path.isfile(report_path) or os.path.getsize(report_path) == 0:
            raise RuntimeError("BC 未生成报告文件")

        e_changed, e_old, e_new = set(), set(), set()
        root = ET.parse(report_path).getroot()      # 报告是 UTF-8（带 BOM）XML，ET 自动处理
        for fc in root.iter():
            if _local(fc.tag) != "filecomp":
                continue
            status = fc.get("status")
            if status not in BC_CHANGE_STATUSES:
                continue
            lt_name = rt_name = None
            for child in fc:
                ctag = _local(child.tag)
                if ctag not in ("lt", "rt"):
                    continue
                for sub in child:
                    if _local(sub.tag) == "name":
                        if ctag == "lt":
                            lt_name = (sub.text or "").strip()
                        else:
                            rt_name = (sub.text or "").strip()
            if status == "ltonly":
                if lt_name:
                    e_old.add(lt_name)
            elif status == "rtonly":
                if rt_name:
                    e_new.add(rt_name)
            else:                                    # diff / ltnewer / rtnewer
                if lt_name:
                    e_changed.add(lt_name)           # diff 时 lt/rt 同名，集合天然去重
                elif rt_name:
                    e_changed.add(rt_name)
        changed = e_changed | e_old | e_new
        return {"changed": changed, "only_old": e_old, "only_new": e_new}, ""
    finally:
        for p in (script_path, report_path):
            try:
                if os.path.isfile(p):
                    os.remove(p)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# 对外唯一入口
# ---------------------------------------------------------------------------

def changed_files(old_dir, new_dir, mode="stat", bc_exe=None, timeout=900):
    """判定新旧两份 txt 目录里哪些文件变了（按 basename 配对）。

    返回 dict：
      changed   : 两边都有但 (内容/时间戳) 不同 ∪ 只在单侧出现 的文件名集合
                  —— 只在单侧 = 该侧新增或删除的标的，也算变更
      only_old  : 只在旧目录出现（新侧已删除）
      only_new  : 只在新目录出现（新侧新增）
      mode      : 实际生效的 mode（`bc` 失败时会是退回后的 `"content"`）
      detail    : 人类可读的判定说明（含耗时、退回原因）
      old_count : 旧目录文件数
      new_count : 新目录文件数
    """
    t0 = time.time()
    o_names = {e.name for e in os.scandir(old_dir) if e.is_file()}
    n_names = {e.name for e in os.scandir(new_dir) if e.is_file()}
    only_old = o_names - n_names
    only_new = n_names - o_names
    both = sorted(o_names & n_names)

    actual_mode = mode
    note = ""
    res = None
    if mode == "bc":
        exe = _find_bc_exe(bc_exe)
        if exe is None:
            note = "未找到 BCompare.exe，退回 content 模式"
        else:
            try:
                res, _ = _compare_bc(old_dir, new_dir, only_old, only_new, both, exe, timeout)
            except Exception as e:                   # 不中断：退回 content 并写明原因
                note = "BC 调用失败（%s），退回 content 模式" % str(e)[:120]
    if res is None:
        if mode == "stat":
            res = _compare_stat(old_dir, new_dir, only_old, only_new, both)
        else:
            actual_mode = "content"
            if mode != "content":
                mode = "content"                     # bc 退回后即为 content
            res = _compare_content(old_dir, new_dir, only_old, only_new, both)

    el = time.time() - t0
    detail = "mode=%s，%d 文件，耗时 %.2fs" % (actual_mode, len(o_names) + len(n_names), el)
    if note:
        detail += "；" + note
    return {
        "changed": res["changed"],
        "only_old": res["only_old"],
        "only_new": res["only_new"],
        "mode": actual_mode,
        "detail": detail,
        "old_count": len(o_names),
        "new_count": len(n_names),
    }


if __name__ == "__main__":
    import argparse

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="新旧两份 txt 目录的变更判定（自测用）")
    ap.add_argument("old_dir")
    ap.add_argument("new_dir")
    ap.add_argument("mode", nargs="?", default="stat", choices=["stat", "content", "bc"])
    ap.add_argument("--bc-exe", dest="bc_exe", default=None)
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()

    r = changed_files(a.old_dir, a.new_dir, mode=a.mode, bc_exe=a.bc_exe, timeout=a.timeout)
    print("旧目录 %d 个文件 / 新目录 %d 个文件" % (r["old_count"], r["new_count"]))
    print("判定明细: %s" % r["detail"])
    print("变更 %d 个:" % len(r["changed"]))
    for name in sorted(r["changed"]):
        tag = "仅旧" if name in r["only_old"] else ("仅新" if name in r["only_new"] else "改写")
        print("  [%s] %s" % (tag, name))