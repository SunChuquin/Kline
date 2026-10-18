# -*- coding: utf-8 -*-
"""sim_state.py — 交易状态持久层（阶段 B：状态所有权反转）。

职责：读取 / 写入 / 增量应用 `Documents/Simulation/sim.json`，由 Python 引擎
独占持有状态文件的读写权，Swift 侧退化为「投影缓存 + 桥接客户端」。

契约（与 KlinePythonBridge 一致）：
  - 桥接注入模块全局 dict `kline_input`；产出模块级 dict `kline_result`，
    `kline_result["ok"]` 为 bool。
  - 输入 `filePath`：sim.json 绝对路径（Swift 侧传入，避免 Python 硬编码沙盒路径）。
  - 日期一律 ISO8601 字符串（UTC 带 Z），与 SimStore 落盘口径一致。
  - UUID 与 Date 通过字符串在 JSON 层面传递，Python 不做类型转换。

op 一览（阶段 B）：
  sim_state_load    —— 读取 sim.json，返回完整状态（含 revision）
  sim_state_save    —— 写入完整状态到 sim.json
  sim_state_apply   —— 增量应用状态变更（accounts/positions/orders/fills/ledger/
                      logs/conditionalOrders/alertRecords/selectedAccountID），
                      返回更新后的完整状态 + 新 revision
"""

import json
import os
import threading

# --- 全局锁：防止并发写入 sim.json 导致损坏 -------------------------------
_lock = threading.Lock()

# --- 信任链版本（与 sim_rules.py 独立，sim_state 契约变更时 +1） ---------
SIM_STATE_SCRIPT_VERSION = 1
SIM_STATE_REQUIRED_API_VERSION = 1


def _err(msg):
    return {"ok": False, "error": msg}


def _ok(result=None):
    r = {"ok": True}
    if result is not None:
        r["result"] = result
    return r


def _load_file(filePath):
    """读取 sim.json，缺失或损坏返回空骨架。"""
    if not filePath or not os.path.exists(filePath):
        return _empty_state()
    try:
        with open(filePath, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return _empty_state()
        # 保证必备键存在
        state = _empty_state()
        for k in state:
            if k in data:
                state[k] = data[k]
        return state
    except Exception:
        return _empty_state()


def _empty_state():
    return {
        "schemaVersion": 3,
        "accounts": [],
        "positions": [],
        "orders": [],
        "fills": [],
        "ledger": [],
        "logs": [],
        "conditionalOrders": [],
        "selectedAccountID": None,
        "alertRecords": [],
        "revision": 0,
    }


def _save_file(filePath, state):
    """原子写入 sim.json（写临时文件后 rename，避免崩溃时损坏原文件）。"""
    if not filePath:
        return False, "filePath 缺失"
    dirPath = os.path.dirname(filePath)
    if dirPath and not os.path.exists(dirPath):
        os.makedirs(dirPath, exist_ok=True)
    tmpPath = filePath + ".tmp"
    try:
        with open(tmpPath, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2, sort_keys=True)
        os.replace(tmpPath, filePath)
        return True, ""
    except Exception as e:
        try:
            if os.path.exists(tmpPath):
                os.remove(tmpPath)
        except Exception:
            pass
        return False, str(e)


# =========================================================================
# op 实现
# =========================================================================

def _op_sim_state_load(inp):
    filePath = inp.get("filePath")
    state = _load_file(filePath)
    return _ok(state)


def _op_sim_state_save(inp):
    filePath = inp.get("filePath")
    state = inp.get("state")
    if not isinstance(state, dict):
        return _err("state 缺失或非对象")
    ok, err = _save_file(filePath, state)
    if not ok:
        return _err(err)
    return _ok()


def _op_sim_state_apply(inp):
    """增量应用状态变更。

    输入：
      {
        "filePath": "...",
        "changes": {
          "accounts": [...],          # 可选，全部替换
          "positions": [...],
          "orders": [...],
          "fills": [...],
          "ledger": [...],
          "logs": [...],
          "conditionalOrders": [...],
          "alertRecords": [...],
          "selectedAccountID": "...",
          "schemaVersion": 3,
        },
        "merge": {                    # 可选，数组类型字段的合并模式
          "orders": "append",         # append / replace （默认 replace）
          "fills": "append",
          "ledger": "append",
          "logs": "append",
          "conditionalOrders": "replace",
          "alertRecords": "append",
        }
      }
    返回：更新后的完整状态 + 新 revision
    """
    filePath = inp.get("filePath")
    changes = inp.get("changes") or {}
    merge = inp.get("merge") or {}

    with _lock:
        state = _load_file(filePath)

        # 逐字段应用变更
        for key in ("accounts", "positions", "orders", "fills", "ledger", "logs",
                    "conditionalOrders", "alertRecords"):
            if key in changes:
                val = changes[key]
                if not isinstance(val, list):
                    return _err("changes.%s 须为数组" % key)
                mode = merge.get(key, "replace")
                if mode == "append" and isinstance(state.get(key), list):
                    state[key] = state[key] + val
                else:
                    state[key] = val

        if "selectedAccountID" in changes:
            state["selectedAccountID"] = changes["selectedAccountID"]
        if "schemaVersion" in changes:
            state["schemaVersion"] = changes["schemaVersion"]

        # revision 自增
        state["revision"] = int(state.get("revision", 0)) + 1

        ok, err = _save_file(filePath, state)
        if not ok:
            return _err(err)

    return _ok(state)


# --- op 分发表 --------------------------------------------------------------
_OPS = {
    "sim_state_load": _op_sim_state_load,
    "sim_state_save": _op_sim_state_save,
    "sim_state_apply": _op_sim_state_apply,
}


def run(inp):
    """桥接入口：inp 为 kline_input，含 op 字段。返回 kline_result 形状 dict。"""
    op = inp.get("op")
    fn = _OPS.get(op)
    if fn is None:
        return _err("未知 op：%s" % op)
    try:
        return fn(inp)
    except Exception as e:
        return _err("脚本异常：%s" % e)


# 供桥接层直接 import 调用（不走 JSON 分发）
__all__ = ["run", "SIM_STATE_SCRIPT_VERSION", "SIM_STATE_REQUIRED_API_VERSION"]
