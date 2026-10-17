#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_sim_rules_trust.py — 交易域信任链（套件 8）常量/fixture 的唯一规范写盘者。

《Python引擎下沉可行性分析.md》§10.9（套件 8）+ §9.10（降级矩阵）：
  D2 已定「硬约束复核一并下沉」→ Swift 侧不再有交易规则实现，红线 4 的缓解只剩
  「签名 + 版本锁 + 脚本哈希」。本脚本把「脚本哈希」「版本锁」以及**交易规则配置常量**
  从 sim_rules.py（唯一真源）抽出，写到三处消费点：

    1. Kline/Python/SimRulesTrust.swift         编译期常量（运行时信任链读它）
    2. Kline/Python/SimTradeRuleConstants.swift 交易规则配置常量镜像（呈现层同步读）
    3. KlineTests/Fixtures/sim_rules_trust.json 测试/CI 读它

  三处（脚本 / Swift 常量 / fixture）任一漂移都会被
  `KlineTests/SimRulesTrustTests` 与 `python3 scripts/verify_sim_rules.py --trust`
  拦下。改了 sim_rules.py（含仅注释）后**必须**重跑本脚本。

  为什么把「配置常量」也纳入信任链（§11.22）：`SimTradingRules` 的 lotSize /
  priceTick / 费率 / 涨跌停幅是**呈现层每帧要读**的值——下沉后若每帧都去请求引擎，
  等于把闸门 6（防抖 + 投影）用在常量上；而若 Swift 各留一份副本，又会与引擎漂移。
  折中即：**真源留引擎脚本，Swift 只保存自动生成的镜像**，靠本脚本 + 信任链测试拦漂移，
  于是呈现层可同步读、零运行期成本，且无第二真源。

用法:
  python3 scripts/gen_sim_rules_trust.py           # 写三处
  python3 scripts/gen_sim_rules_trust.py --check   # 只校验是否漂移（不写盘）
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
RULES_SWIFT = os.path.join(REPO, "Kline", "Python", "SimTradeRuleConstants.swift")
FIXTURE = os.path.join(REPO, "KlineTests", "Fixtures", "sim_rules_trust.json")

SCRIPT_NAME = "sim_rules"

_RE_SCRIPT_VERSION = re.compile(r"^SIM_RULES_SCRIPT_VERSION\s*=\s*(\d+)", re.M)
_RE_API_VERSION = re.compile(r"^SIM_RULES_REQUIRED_API_VERSION\s*=\s*(\d+)", re.M)
_RE_SWIFT_SHA = re.compile(r'(?<=static let expectedScriptSHA256 = ")[0-9a-f]{64}(?=")')
_RE_SWIFT_SCRIPT_VERSION = re.compile(r"(?<=static let scriptVersion = )\d+")
_RE_SWIFT_API_VERSION = re.compile(r"(?<=static let requiredAPIVersion = )\d+")

# 交易规则配置常量：sim_rules.py 常量名 → (Swift 名, 类型)
_RULE_CONSTS = (
    ("lotSize",        "_LOT_SIZE",        int),
    ("priceTick",      "_PRICE_TICK",      float),
    ("commissionRate", "_COMMISSION_RATE", float),
    ("commissionMin",  "_COMMISSION_MIN",  float),
    ("stampTaxRate",   "_STAMP_TAX_RATE",  float),
    ("limitPct",       "_LIMIT_PCT",       float),
)


def read_rule_constants(text):
    """从 sim_rules.py 文本解析规则常量（行首 `_NAME = 数值`）。"""
    out = {}
    for key, name, cast in _RULE_CONSTS:
        m = re.search(r"^%s\s*=\s*([0-9]+(?:\.[0-9]+)?)" % re.escape(name), text, re.M)
        if not m:
            raise SystemExit("sim_rules.py 缺交易规则常量 %s" % name)
        out[key] = cast(m.group(1))
    return out


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
            "requiredApiVersion": int(m2.group(1)),
            "ruleConstants": read_rule_constants(text)}


def _fixture_obj(v):
    return {"script": SCRIPT_NAME, "sha256": v["sha256"],
            "scriptVersion": v["scriptVersion"], "requiredApiVersion": v["requiredApiVersion"],
            "ruleConstants": v["ruleConstants"]}


def _lit(key, value, cast):
    if cast is int:
        return str(int(value))
    return repr(float(value))


def rules_swift_text(v):
    """生成 SimTradeRuleConstants.swift 的**完整期望文本**（唯一规范形态）。"""
    rows = []
    for key, name, cast in _RULE_CONSTS:
        rows.append("    /// sim_rules.py `%s`\n    static let %s = %s\n"
                    % (name, key, _lit(key, v["ruleConstants"][key], cast)))
    return (
        "//\n"
        "//  SimTradeRuleConstants.swift\n"
        "//  Kline\n"
        "//\n"
        "//  ⚠️ **本文件由 scripts/gen_sim_rules_trust.py 自动生成，勿手改。**\n"
        "//\n"
        "//  真源 = `Kline/PyScripts/sim_rules.py` 顶部的交易规则常量\n"
        "//  （%s）。\n"
        "//\n"
        "//  角色（《Python引擎下沉可行性分析.md》§10.9 套件 8 的扩展，见 §11.22）：\n"
        "//  D2 之后交易规则单一真源是引擎脚本，Swift 侧只保存**自动生成的镜像**——\n"
        "//  漂移由 `gen_sim_rules_trust.py --check` / `verify_sim_rules.py --trust` /\n"
        "//  `KlineTests/SimRulesTrustTests` 三重拦下。因此呈现层可以**同步**读到正确常量，\n"
        "//  无需为「整手 / 最小报价档位 / 费率 / 涨跌停幅」在每帧走一次引擎请求（闸门 6）。\n"
        "//\n"
        "//  ⚠️ 改了 sim_rules.py（含仅注释）后必须重跑\n"
        "//     `python3 scripts/gen_sim_rules_trust.py`。\n"
        "//\n"
        "\n"
        "import Foundation\n"
        "\n"
        "enum SimTradeRuleConstants {\n"
        "%s"
        "}\n"
        % (", ".join(n for _, n, _ in _RULE_CONSTS), "".join(rows))
    )


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
    if not os.path.exists(RULES_SWIFT):
        print("规则常量文件缺失：%s（请重新生成）" % RULES_SWIFT)
        return 1
    with open(RULES_SWIFT, encoding="utf-8") as f:
        rules = f.read()
    if rules != rules_swift_text(v):
        print("规则常量漂移：%s 与真源不一致" % RULES_SWIFT)
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
    print("信任链一致：sha256=%s scriptVersion=%d requiredApiVersion=%d ruleConstants=%s"
          % (v["sha256"], v["scriptVersion"], v["requiredApiVersion"],
             json.dumps(v["ruleConstants"], ensure_ascii=False, sort_keys=True)))
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
    with open(RULES_SWIFT, "w", encoding="utf-8") as f:
        f.write(rules_swift_text(v))
    with open(FIXTURE, "w", encoding="utf-8") as f:
        json.dump(_fixture_obj(v), f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("已写入：\n  %s\n  %s\n  %s" % (SWIFT, RULES_SWIFT, FIXTURE))
    print("信任链：sha256=%s scriptVersion=%d requiredApiVersion=%d ruleConstants=%s"
          % (v["sha256"], v["scriptVersion"], v["requiredApiVersion"],
             json.dumps(v["ruleConstants"], ensure_ascii=False, sort_keys=True)))
    return 0


def main():
    v = read_script()
    if "--check" in sys.argv:
        return check(v)
    return write(v)


if __name__ == "__main__":
    sys.exit(main())
