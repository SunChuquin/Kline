#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_sim_rules_trust.py — 交易域信任链（套件 8）常量/fixture 的唯一规范写盘者。

《Python引擎下沉可行性分析.md》§10.9（套件 8）+ §9.10（降级矩阵）：
  D2 已定「硬约束复核一并下沉」→ Swift 侧不再有交易规则实现，红线 4 的缓解只剩
  「签名 + 版本锁 + 脚本哈希」。本脚本把「脚本哈希」与「版本锁」两个可核对值从
  sim_rules.py（唯一真源）抽出，写到两处消费点：

    1. Kline/Python/SimRulesTrust.swift 的编译期常量（运行时信任链读它）
    2. KlineTests/Fixtures/sim_rules_trust.json（测试/CI 读它）

  三处（脚本 / Swift 常量 / fixture）任一漂移都会被
  `KlineTests/SimRulesTrustTests` 与 `python3 scripts/verify_sim_rules.py --trust`
  拦下。改了 sim_rules.py（含仅注释）后**必须**重跑本脚本。

用法:
  python3 scripts/gen_sim_rules_trust.py           # 写 Swift 常量 + fixture
  python3 scripts/gen_sim_rules_trust.py --check   # 只校验三者一致（不写盘）
退出码 0 = 一致（或写盘成功）；非 0 = 漂移 / 缺声明。
"""

import hashlib
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "Kline", "PyScripts", "sim_rules.py")
SWIFT = os.path.join(REPO, "Kline", "Python", "SimRulesTrust.swift")
FIXTURE = os.path.join(REPO, "KlineTests", "Fixtures", "sim_rules_trust.json")

SCRIPT_NAME = "sim_rules"

_RE_SCRIPT_VERSION = re.compile(r"^SIM_RULES_SCRIPT_VERSION\s*=\s*(\d+)", re.M)
_RE_API_VERSION = re.compile(r"^SIM_RULES_REQUIRED_API_VERSION\s*=\s*(\d+)", re.M)
_RE_SWIFT_SHA = re.compile(r'(?<=static let expectedScriptSHA256 = ")[0-9a-f]{64}(?=")')
_RE_SWIFT_SCRIPT_VERSION = re.compile(r"(?<=static let scriptVersion = )\d+")
_RE_SWIFT_API_VERSION = re.compile(r"(?<=static let requiredAPIVersion = )\d+")


def read_script():
    with open(SCRIPT, "rb") as f:
        raw = f.read()
    text = raw.decode("utf-8")
    sha = hashlib.sha256(raw).hexdigest()
    m1 = _RE_SCRIPT_VERSION.search(text)
    m2 = _RE_API_VERSION.search(text)
    if not m1 or not m2:
        raise SystemExit("sim_rules.py 缺版本声明（SIM_RULES_SCRIPT_VERSION / "
                         "SIM_RULES_REQUIRED_API_VERSION）")
    return {"sha256": sha, "scriptVersion": int(m1.group(1)),
            "requiredApiVersion": int(m2.group(1))}


def _fixture_obj(v):
    return {"script": SCRIPT_NAME, "sha256": v["sha256"],
            "scriptVersion": v["scriptVersion"], "requiredApiVersion": v["requiredApiVersion"]}


def _swift_ok(text, v):
    """Swift 常量与真源一致？返回 (是否一致, 说明)。"""
    for name, rx, want in (("expectedScriptSHA256", _RE_SWIFT_SHA, v["sha256"]),
                           ("scriptVersion", _RE_SWIFT_SCRIPT_VERSION, v["scriptVersion"]),
                           ("requiredAPIVersion", _RE_SWIFT_API_VERSION, v["requiredApiVersion"])):
        m = rx.search(text)
        if not m or m.group(0) != str(want):
            return False, "%s: Swift=%r 期望=%r" % (name, m.group(0) if m else None, want)
    return True, ""


def check(v):
    with open(SWIFT, encoding="utf-8") as f:
        swift = f.read()
    ok, why = _swift_ok(swift, v)
    if not ok:
        print("Swift 常量漂移：%s" % why)
        print("  请运行 python3 scripts/gen_sim_rules_trust.py 重新生成")
        return 1
    if not os.path.exists(FIXTURE):
        print("fixture 缺失：%s（请重新生成）" % FIXTURE)
        return 1
    with open(FIXTURE, encoding="utf-8") as f:
        fix = json.load(f)
    want = _fixture_obj(v)
    if fix != want:
        print("fixture 漂移：\n  磁盘=%s\n  期望=%s" % (json.dumps(fix, ensure_ascii=False),
                                                        json.dumps(want, ensure_ascii=False)))
        return 1
    print("信任链一致：sha256=%s scriptVersion=%d requiredApiVersion=%d"
          % (v["sha256"], v["scriptVersion"], v["requiredApiVersion"]))
    return 0


def write(v):
    with open(SWIFT, encoding="utf-8") as f:
        swift = f.read()
    new = _RE_SWIFT_SHA.sub(v["sha256"], swift, count=1)
    new = _RE_SWIFT_SCRIPT_VERSION.sub(str(v["scriptVersion"]), new, count=1)
    new = _RE_SWIFT_API_VERSION.sub(str(v["requiredApiVersion"]), new, count=1)
    if new != swift:
        with open(SWIFT, "w", encoding="utf-8") as f:
            f.write(new)
    with open(FIXTURE, "w", encoding="utf-8") as f:
        json.dump(_fixture_obj(v), f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("已写入：\n  %s\n  %s" % (SWIFT, FIXTURE))
    print("信任链：sha256=%s scriptVersion=%d requiredApiVersion=%d"
          % (v["sha256"], v["scriptVersion"], v["requiredApiVersion"]))
    return 0


def main():
    v = read_script()
    if "--check" in sys.argv:
        return check(v)
    return write(v)


if __name__ == "__main__":
    sys.exit(main())
