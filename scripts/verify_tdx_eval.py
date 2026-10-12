# -*- coding: utf-8 -*-
# verify_tdx_eval.py —— tdx_eval.py 的 PC 端冒烟差分（首帧引擎实验）
#
# 用法：python scripts/verify_tdx_eval.py
# 手算期望值逐例断言，覆盖 TDXEvaluator 镜像语义的关键点：
# MA 窗口 NaN 跳过 / EMA·SMA 递归播种 / REF / HHV·LLV / SUM(X,0) / STD /
# 除零→0 / 比较 NaN→0 / AND / CROSS / IF / BARSLAST / SAR / MEMA / 批量隔离失败
# 输出风格：逐例 [pass]/[fail]

import importlib.util
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "Kline", "PyScripts", "tdx_eval.py")

spec = importlib.util.spec_from_file_location("tdx_eval", SCRIPT)
tdx_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tdx_eval)


# ---- AST 构造助手（与 PyTDXFormulaBridge.astJSON 序列化格式一致）----

def num(v):
    return {"t": "num", "v": v}

def var(n):
    return {"t": "var", "n": n}

def call(fn, *args):
    return {"t": "call", "fn": fn, "args": list(args)}

def binop(op, l, r):
    return {"t": "bin", "op": op, "l": l, "r": r}

def stmt(name, expr, output=True):
    return {"n": name, "o": 1 if output else 0, "e": expr}

def bars(c, h=None, l=None, o=None, v=None, a=None):
    n = len(c)
    return {
        "c": c, "h": h or c, "l": l or c, "o": o or c,
        "v": v or [1.0] * n, "a": a or [1.0] * n,
    }


# ---- 断言 ----

_failures = []
_total = 0


def check(name, cond, detail=""):
    global _total
    _total += 1
    if cond:
        print("[%s] %s" % ("pass", name))
    else:
        print("[%s] %s  %s" % ("fail", name, detail))
        _failures.append(name)


def run_one(cases_bars, stmts):
    inp = {"bars": cases_bars, "requests": [{"stmts": stmts}]}
    out = tdx_eval.run(inp)
    assert out.get("ok") is True, "顶层 ok != true"
    return out["results"][0]


def expect_line(result, line_name, expected, tag, tol=1e-12):
    """输出行逐点断言：expected 中 None 表示 NaN（Python 侧已转为 None）"""
    ok_lines = result.get("ok") is True
    if not ok_lines:
        check(tag, False, "请求失败: %s" % result.get("error"))
        return
    lines = {l["n"]: l["v"] for l in result["lines"]}
    vals = lines.get(line_name)
    if vals is None:
        check(tag, False, "缺输出行 %s" % line_name)
        return
    ok = len(vals) == len(expected)
    detail = "len %s != %s" % (len(vals), len(expected)) if not ok else ""
    if ok:
        for i, (got, exp) in enumerate(zip(vals, expected)):
            if exp is None:
                if got is not None:
                    ok, detail = False, "idx %d: %r != NaN" % (i, got)
                    break
            elif got is None or abs(got - exp) > tol:
                ok, detail = False, "idx %d: %r != %r" % (i, got, exp)
                break
    check(tag, ok, detail)


NAN = None

results_out = []

# 1. MA 基础 + 窗口推进
r = run_one(bars([1, 2, 3, 4, 5]), [stmt("MA3", call("MA", var("C"), num(3)))])
expect_line(r, "MA3", [1.0, 1.5, 2.0, 3.0, 4.0], "MA 窗口均值")

# 2. MA 窗口 NaN 跳过
r = run_one(bars([1.0, float("nan"), 3.0, 4.0]), [stmt("MA2", call("MA", var("C"), num(2)))])
expect_line(r, "MA2", [1.0, 1.0, 3.0, 3.5], "MA 窗口 NaN 跳过")

# 3. EMA 递归（k=2/(N+1)）
r = run_one(bars([1, 2, 3]), [stmt("E", call("EMA", var("C"), num(3)))])
expect_line(r, "E", [1.0, 1.5, 2.25], "EMA 递归")

# 4. EMA 首段 NaN：首个有效值播种
r = run_one(bars([float("nan"), 2.0, 4.0]), [stmt("E", call("EMA", var("C"), num(3)))])
expect_line(r, "E", [NAN, 2.0, 3.0], "EMA NaN 跳过播种")

# 5. SMA(X,N,M)：cur=(M*X+(N-M)*PREV)/N，第4根=(1*4+3*1.6875)/4=2.265625
r = run_one(bars([1, 2, 3, 4]), [stmt("S", call("SMA", var("C"), num(4), num(1)))])
expect_line(r, "S", [1.0, 1.25, 1.6875, 2.265625], "SMA(X,N,M)")

# 6. MEMA == SMA(X,N,1)
r = run_one(bars([1, 2, 3, 4]), [stmt("M", call("MEMA", var("C"), num(4)))])
expect_line(r, "M", [1.0, 1.25, 1.6875, 2.265625], "MEMA")

# 7. REF
r = run_one(bars([1, 2, 3]), [stmt("R", call("REF", var("C"), num(1)))])
expect_line(r, "R", [NAN, 1.0, 2.0], "REF")

# 8. HHV/LLV
r = run_one(bars([1, 3, 2, 5]), [stmt("H2", call("HHV", var("C"), num(2))),
                                 stmt("L2", call("LLV", var("C"), num(2)))])
expect_line(r, "H2", [1.0, 3.0, 3.0, 5.0], "HHV")
expect_line(r, "L2", [1.0, 1.0, 2.0, 2.0], "LLV")

# 9. SUM(X,0)：NaN 不推进
r = run_one(bars([1.0, float("nan"), 2.0, 3.0]), [stmt("T", call("SUM", var("C"), num(0)))])
expect_line(r, "T", [1.0, NAN, 3.0, 6.0], "SUM(X,0) NaN 不推进")

# 10. SUM 窗口
r = run_one(bars([1, 2, 3, 4]), [stmt("S2", call("SUM", var("C"), num(2)))])
expect_line(r, "S2", [1.0, 3.0, 5.0, 7.0], "SUM(X,N)")

# 11. STD（总体方差开方，负值钳零）
r = run_one(bars([1, 3]), [stmt("D", call("STD", var("C"), num(2)))])
expect_line(r, "D", [0.0, 1.0], "STD")

# 12. 除零 → 0（通达信语义）
r = run_one(bars([4, 5]), [stmt("Z", binop("/", var("C"), num(0)))])
expect_line(r, "Z", [0.0, 0.0], "除零→0")

# 13. 比较含 NaN → 0
r = run_one(bars([float("nan"), 1.0]), [stmt("G", binop(">", var("C"), num(0)))])
expect_line(r, "G", [0.0, 1.0], "比较 NaN→0")

# 14. AND / 一元 not
r = run_one(bars([1.0, 3.0, 0.0]),
            [stmt("A", binop("and", binop(">", var("C"), num(0)), binop("<", var("C"), num(2)))),
             stmt("N", {"t": "un", "op": "not", "x": var("C")})])
expect_line(r, "A", [1.0, 0.0, 0.0], "AND")
expect_line(r, "N", [0.0, 0.0, 1.0], "NOT")

# 15. CROSS（首根 REF 为 NaN → 前值比较 false → 0）
r = run_one(bars([1, 2, 1, 2]),
            [stmt("X", call("CROSS", var("C"), call("REF", var("C"), num(1))))])
expect_line(r, "X", [0.0, 0.0, 0.0, 1.0], "CROSS")

# 16. IF
r = run_one(bars([0.5, 2.0]), [stmt("I", call("IF", binop(">", var("C"), num(1)), num(10), num(20)))])
expect_line(r, "I", [20.0, 10.0], "IF")

# 17. BARSLAST：未命中 NaN，命中计距
r = run_one(bars([1, 2, 1, 1]), [stmt("B", call("BARSLAST", binop(">", var("C"), num(1.5))))])
expect_line(r, "B", [NAN, 0.0, 1.0, 2.0], "BARSLAST")

# 18. SAR 单边上涨：全红（方向恒 1），值不高于前低
c_h, c_l = [2.0, 3.0, 4.0, 5.0], [1.0, 2.0, 3.0, 4.0]
r = run_one(bars(c_h, h=c_h, l=c_l), [stmt("S", call("SAR", num(0.02), num(0.2)))])
sar_ok = r.get("ok") is True and r["lines"][0].get("d") == [1, 1, 1, 1]
check("SAR 方向单边上涨全红", sar_ok, "d=%r" % (r.get("lines")[0].get("d") if r.get("lines") else None,))

# 19. 赋值语句（非输出）作为依赖 + 输出行顺序；EMA(C,2) 平滑系数 k=2/3
r = run_one(bars([1, 2, 3]),
            [stmt("TMP", call("EMA", var("C"), num(2)), output=False),
             stmt("OUT1", var("TMP")),
             stmt("OUT2", binop("-", var("TMP"), num(1)))])
expect_line(r, "OUT1", [1.0, 5.0 / 3.0, 23.0 / 9.0], "赋值依赖 OUT1")
expect_line(r, "OUT2", [0.0, 2.0 / 3.0, 14.0 / 9.0], "赋值依赖 OUT2")

# 20. 批量请求隔离：一个失败不影响另一个
inp = {"bars": bars([1, 2, 3]),
       "requests": [
           {"stmts": [stmt("M", call("MA", var("C"), num(2)))]},
           {"stmts": [stmt("BAD", call("NOSUCHFUNC", var("C")))]},
       ]}
out = tdx_eval.run(inp)
r0, r1 = out["results"]
check("批量隔离-成功请求", r0.get("ok") is True and len(r0["lines"]) == 1)
check("批量隔离-失败请求不拖垮", r1.get("ok") is False and "不支持" in (r1.get("error") or ""))

# 21. MACD(12,26,9) 端到端手算抽查（DIF = EMA12 - EMA26，DEA = EMA(DIF,9)）
c = [10.0 + i * 0.5 for i in range(40)]  # 单调上升
inp = {"bars": bars(c), "requests": [{"stmts": [
    stmt("DIF", binop("-", call("EMA", var("C"), num(12)), call("EMA", var("C"), num(26)))),
    stmt("DEA", call("EMA", {"t": "var", "n": "DIF"}, num(9))),
]}]}
out = tdx_eval.run(inp)
r = out["results"][0]
if r.get("ok") is True:
    dif = r["lines"][0]["v"]
    dea = r["lines"][1]["v"]
    # 手算 EMA 验证器（独立小实现，仅 40 根）
    def ema_ref(seq, n):
        k = 2.0 / (n + 1.0)
        prev = None
        out = []
        for v in seq:
            if prev is None:
                out.append(v)
                prev = v
            else:
                cur = v * k + prev * (1 - k)
                out.append(cur)
                prev = cur
        return out
    e12, e26 = ema_ref(c, 12), ema_ref(c, 26)
    dif_ref = [a - b for a, b in zip(e12, e26)]
    dea_ref = ema_ref(dif_ref, 9)
    ok = all(abs(a - b) < 1e-9 for a, b in zip(dif, dif_ref)) and \
         all(abs(a - b) < 1e-9 for a, b in zip(dea, dea_ref))
    check("MACD DIF/DEA 端到端手算对拍", ok)
else:
    check("MACD DIF/DEA 端到端手算对拍", False, r.get("error"))

# 22. 无输出行报错
r = run_one(bars([1, 2]), [stmt("TMP", var("C"), output=False)])
check("无输出行报错", r.get("ok") is False and "输出行" in (r.get("error") or ""))

# 23. 隐式乘法与运算优先级（2*(C-L) 由 Swift parser 序列化为 bin，这里验证数值链）
r = run_one(bars([5, 7], h=[6, 9], l=[4, 6]),
            [stmt("RNG", binop("*", num(2), binop("-", var("H"), var("L"))))])
expect_line(r, "RNG", [4.0, 6.0], "H/L 序列与乘法")

print()
if _failures:
    print("结果: %d/%d 通过，失败: %s" % (_total - len(_failures), _total, ", ".join(_failures)))
    sys.exit(1)
print("结果: %d/%d 全部通过" % (_total, _total))
