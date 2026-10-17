#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_sim_rules_inputs.py — 从 A0 内置用例抽出「输入」，生成 A1 fixture 骨架。

阶段 A1（Swift dump 导出 golden，见《Python引擎下沉可行性分析.md》§12）：
fixture 的 **input 手写 / 评审**，**expected 只能由 Swift 现状 dump 写**
（§12.2）。本脚本负责前半段：把 `scripts/verify_sim_rules.py` 里 A0 已经
手写并评审过的输入抽出来，落成三个 fixture 的「输入骨架」：

  · KlineTests/Fixtures/sim_rules.json      计算类（A/B/C/D 组 + simFormat）—— 只写 input
  · KlineTests/Fixtures/strategy_dsl.json   解析类（E 组）—— input + expected（手写规格）
  · KlineTests/Fixtures/backtest_golden.json  回测（F 组）—— 只写 input

随后 `SimRulesContractTests` 在 dump 模式下补写 sim_rules / backtest_golden 的
expected（见 scripts/extract_sim_rules_golden.py）。

约定（与 §12 对齐，亦是两侧对拍口径）：
  - 每个 case：`{caseName, op, input, expected?}`；`op` 放 case 级（不在 input 内）。
  - `expected` = **op 的完整输出**（含 `ok`）；`ok:false` 的形状非法守卫用例
    不进 fixture（Swift 侧无法构造，留在 A0 内置用例里）。
  - 账户 id 统一换成固定 UUID（Swift `UUID` 只认 8-4-4-4-12）。

用法:
  python3 scripts/gen_sim_rules_inputs.py            # 生成/覆盖三个 fixture 的输入骨架
  python3 scripts/gen_sim_rules_inputs.py --check    # 只校验不写盘（打印各段落条数）
"""

import importlib.util
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(REPO, "scripts", "verify_sim_rules.py")
FIX_DIR = os.path.join(REPO, "KlineTests", "Fixtures")

# 固定账户 UUID（对齐 Swift UUID 严格 8-4-4-4-12；Python 侧原样透传）
ACC1 = "11111111-1111-1111-1111-111111111111"   # A0 里的 "acc-1"
ACC2 = "22222222-2222-2222-2222-222222222222"   # A0 里的 "other"
_ACC_MAP = {"acc-1": ACC1, "other": ACC2}

TZ8 = 28800

# op → sim_rules.json 段落
_SECTION = {
    "sim_format": "simFormat",
    "cond_evaluate": "evaluate",
    "cond_validate_create": "validateCreate",
    "cond_grid_level_count": "gridLevelCount",
    "cond_text": "text",
    "cond_expired_reason": "sweep",
    "cond_fire_direction": "sweep",
    "cond_execution_price": "sweep",
    "cond_advance": "sweep",
    "cond_repeatable_finished": "sweep",
    "cond_alert_message": "sweep",
    "trade_calc": "tradingRules",
    "trade_validate": "tradingRules",
    "strategy_drafts": "mapping",
    "strategy_entry_draft": "mapping",
}

# op → strategy_dsl.json 段落（E 组；input + expected 均为手写规格）
_DSL_SECTION = {
    "strategy_parse": "strategyParse",
    "strategy_rule_line": "strategyRuleLine",
    "strategy_catalog": "strategyCatalog",
    "strategy_validate": "strategyValidate",
    "strategy_preview": "strategyPreview",
    "trade_parse": "tradeParse",
    "trade_serialize": "tradeSerialize",
    "trade_override": "tradeOverride",
}

SIM_SECTIONS = ["simFormat", "evaluate", "validateCreate", "gridLevelCount",
                "text", "sweep", "tradingRules", "mapping"]
DSL_SECTIONS = ["strategyParse", "strategyRuleLine", "strategyCatalog",
                "strategyValidate", "strategyPreview", "tradeParse",
                "tradeSerialize", "tradeOverride"]


# ---------------------------------------------------------------------------
# 载入 verify_sim_rules.py（脚本，非包）
# ---------------------------------------------------------------------------

def _load_verify():
    spec = importlib.util.spec_from_file_location("verify_sim_rules_mod", VERIFY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------------------
# 归一化
# ---------------------------------------------------------------------------

def _norm_account_ids(value):
    """递归把 A0 的账户 id 字符串换成固定 UUID。"""
    if isinstance(value, str):
        return _ACC_MAP.get(value, value)
    if isinstance(value, list):
        return [_norm_account_ids(v) for v in value]
    if isinstance(value, dict):
        return {k: _norm_account_ids(v) for k, v in value.items()}
    return value


# 时间敏感用例：evaluate 的 time 分支在 Swift 侧取 `Date()`（无 now 注入），
# 故把 fireDate 推到确定的远过去 / 远未来，保证 dump 与对拍长期稳定（§11.5 时区锁现状）。
_TIME_FIX = {
    "eval.time_hold_future": "2099-01-01T00:00:00Z",
    "eval.time_no_quote_holds": "2000-01-01T00:00:00Z",
    "eval.time_fire_with_last": "2000-01-01T00:00:00Z",
}


def _fix_determinism(case_name, inp):
    if case_name in _TIME_FIX:
        params = inp.setdefault("order", {}).setdefault("params", {})
        params["fireDate"] = _TIME_FIX[case_name]
    return inp


# ---------------------------------------------------------------------------
# 组装
# ---------------------------------------------------------------------------

def build():
    mod = _load_verify()
    cases = mod.cases()

    sim = {name: [] for name in SIM_SECTIONS}
    dsl = {name: [] for name in DSL_SECTIONS}
    backtest = []

    for c in cases:
        name = c["name"]
        op = c.get("op") or c["input"].get("op")
        inp = dict(c["input"])
        inp.pop("op", None)
        inp = _norm_account_ids(inp)
        inp = _fix_determinism(name, inp)
        expected = c["expected"]

        entry = {"caseName": name, "op": op, "input": inp}

        if op in _SECTION and op not in _DSL_SECTION:
            if expected.get("ok") is False:
                continue  # 形状非法守卫：Swift 侧无法构造，留 A0 内置用例
            sim[_SECTION[op]].append(entry)
        elif op in _DSL_SECTION:
            if expected.get("ok") is False:
                continue
            entry["expected"] = expected   # E 组：手写规格（文本口径稳定）
            dsl[_DSL_SECTION[op]].append(entry)
        elif op == "backtest_run":
            if expected.get("ok") is False:
                continue
            backtest.append(entry)
        else:
            raise SystemExit("未归类的 op：%r（case %s）" % (op, name))

    sim["_header"] = {
        "schema": 1,
        "generatedBy": "SimRulesContractTests dump (Swift 现状)",
        "generatedAt": "2026-10-17",
        "tzOffsetSeconds": TZ8,
        "now": "2026-10-17T02:30:00Z",
    }
    dsl["_header"] = {
        "schema": 1,
        "generatedBy": "手写规格（A0 手推期望值，非 dump）",
        "generatedAt": "2026-10-17",
        "tzOffsetSeconds": TZ8,
    }
    bt_header = {
        "schema": 1,
        "generatedBy": "SimRulesContractTests dump (Swift 现状)",
        "generatedAt": "2026-10-17",
        "tzOffsetSeconds": TZ8,
    }
    return sim, dsl, {"_header": bt_header, "cases": backtest}


def _ordered(obj, sections, header_key="_header"):
    out = {header_key: obj[header_key]}
    for s in sections:
        out[s] = obj[s]
    return out


def _load_existing(name):
    path = os.path.join(FIX_DIR, name)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _carry_expected(new_obj, old_obj, sections=None):
    """把已有 fixture 里按 caseName 命中的 `expected` 搬回来（保住 Swift dump 成果）。

    sections=None 表示 old_obj 是 {cases: [...]}; 否则按段遍历。
    """
    def index(cases):
        return {c.get("caseName"): c.get("expected")
                for c in (cases or []) if "expected" in c}

    if sections is None:
        idx = index(old_obj.get("cases")) if old_obj else {}
        for c in new_obj.get("cases", []):
            if c["caseName"] in idx:
                c["expected"] = idx[c["caseName"]]
        return
    for s in sections:
        idx = index((old_obj or {}).get(s))
        for c in new_obj.get(s, []):
            if c["caseName"] in idx:
                c["expected"] = idx[c["caseName"]]


def _write(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main():
    check = "--check" in sys.argv
    sim, dsl, bt = build()
    sim = _ordered(sim, SIM_SECTIONS)
    dsl = _ordered(dsl, DSL_SECTIONS)
    # 保住已 dump 的 expected（重跑输入骨架不得清空 golden）
    _carry_expected(sim, _load_existing("sim_rules.json"), SIM_SECTIONS)
    _carry_expected(bt, _load_existing("backtest_golden.json"), sections=None)

    counts = {
        "sim_rules.json": {s: len(sim[s]) for s in SIM_SECTIONS},
        "strategy_dsl.json": {s: len(dsl[s]) for s in DSL_SECTIONS},
        "backtest_golden.json": {"cases": len(bt["cases"])},
    }
    for k, v in counts.items():
        total = sum(v.values())
        print("%s：%d 条" % (k, total))
        for s, n in v.items():
            if n:
                print("    %-16s %d" % (s, n))

    if check:
        return 0

    _write(os.path.join(FIX_DIR, "sim_rules.json"), sim)
    _write(os.path.join(FIX_DIR, "strategy_dsl.json"), dsl)
    _write(os.path.join(FIX_DIR, "backtest_golden.json"), bt)
    print("已写入 %s" % FIX_DIR)
    return 0


if __name__ == "__main__":
    sys.exit(main())
