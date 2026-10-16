#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 解析下沉 PC 差分验证：Python 移植版 lexer/parser（tdx_eval.py）vs Swift 快照 fixture。
# 用法: python3 scripts/verify_parse_port.py <fixture.json>
# 退出码 0 = 全一致；非 0 = 有差异（打印逐条）。
import json
import sys
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "Kline", "PyScripts", "tdx_eval.py")


def run_text_op(texts, mode="split"):
    """以 PC 方式执行 tdx_eval.py 的 text op：kline_input 注入后 exec，取 kline_result。"""
    src = open(SCRIPT, encoding="utf-8").read()
    kline_input = {
        "__text__": 1,
        "mode": mode,
        "texts": [{"id": i, "text": t} for i, t in enumerate(texts)],
        # text op 不需要 bars（split 模式）；eval 模式由调用方另行验证（fixture 是值级）
        "bars": {"c": [], "h": [], "l": [], "o": [], "v": [], "a": []},
    }
    g = {"kline_input": kline_input, "__name__": "__main__"}
    exec(compile(src, SCRIPT, "exec"), g)
    return g["kline_result"]


def main():
    fixture = json.load(open(sys.argv[1], encoding="utf-8"))
    labels = [e["label"] for e in fixture["units"]]
    texts = []
    # 还原语料文本：fixture 不存原文（避免双份）——语料 = golden 公式 + edge 语料，从
    # PyTDXEvalTests.goldenFormulas 同源重建（此处直接硬编码与 Swift 测试一致的语料）。
    corpus = dict(CORPUS)
    for lb in labels:
        if lb not in corpus:
            print("❌ fixture label %r 不在差分语料中（需与 Swift 语料同步）" % lb)
            return 2
        texts.append(corpus[lb])

    res = run_text_op(texts, mode="split")
    fails = []
    by_id = {r["id"]: r for r in res["results"]}
    for i, lb in enumerate(labels):
        got, want = by_id[i], fixture["units"][i]
        want_units = [(u["name"], u["text"]) for u in want["units"]]
        if not got.get("ok"):
            fails.append("%s: Python 解析失败 %r（Swift 成功）" % (lb, got.get("error")))
            continue
        got_units = [(u["name"], u["text"]) for u in got["units"]]
        if got_units != want_units:
            fails.append("%s:\n  Swift=%r\n  Pythn=%r" % (lb, want_units, got_units))

    # 错误文案逐字对比
    err_labels = [e["label"] for e in fixture["errors"]]
    err_texts = []
    for lb in err_labels:
        if lb not in ERR_CORPUS:
            print("❌ 错误语料 %r 缺失" % lb)
            return 2
        err_texts.append(ERR_CORPUS[lb])
    res2 = run_text_op(err_texts, mode="split")
    by_id2 = {r["id"]: r for r in res2["results"]}
    for i, lb in enumerate(err_labels):
        got, want = by_id2[i], fixture["errors"][i]
        got_err = "" if got.get("ok") else str(got.get("error", ""))
        want_err = want["error"]
        if got_err != want_err:
            fails.append("%s 错误文案:\n  Swift=%r\n  Pythn=%r" % (lb, want_err, got_err))

    if fails:
        print("❌ 差异 %d 条：" % len(fails))
        for f in fails:
            print(f)
        return 1
    print("✅ PC 差分全一致（units %d 语料 + 错误 %d 语料，逐字一致）" % (len(labels), len(err_labels)))
    return 0


# 与 Swift TDXParseFixtureTests.corpus()/errorCorpus() 逐条同步（改一侧必须改另一侧）
CORPUS = {
    "closeonly": "X: C;",
    "ma": "M5: MA(C,5);\nM10: MA(C,10);\nM60: MA(C,60);",
    "ema": "E12: EMA(C,12);\nS5: SMA(C,5,2);",
    "hhvllv": "H20: HHV(H,20);\nL10: LLV(L,10);",
    "sar": "S: SAR(0.02,0.2);",
    "divzero": "DZ: C/(C-C);\nN: C/2;",
    "std": "ST: STD(C,10);",
    "barslast": "B: BARSLAST(C > REF(C,1));",
    "batchA": "A1: MA(C,5);",
    "batchB": "B1: EMA(C,26);\nB2: SAR(0.02,0.2);",
    "edge:implicit": "X: 2HV;\nY: 2(C-L);",
    "edge:comment": "X: C; {块注释\n跨行} Y: H;",
    "edge:eq": "X: C = REF(C,1);",
    "edge:assign": "V1:=SMA(C,5,1),;\nX: V1;",
    "edge:opts": "X: MA(C,5),DOTLINE,COLORRED,LINETHICK2;",
}
ERR_CORPUS = {
    "err:badchar": "X: C @ H;",
    "err:noname": ": C;",
    "err:noassign": "X C;",
    "err:incomplete": "X: ",
    "err:unmatched": "X: MA(C,5;",
    "err:badstart": "X: + ;",
    "err:nooutput": "A:=C;",
    "err:empty": "",
    "err:unclosedcomment": "X: C; { 未闭合",
}


if __name__ == "__main__":
    sys.exit(main())
