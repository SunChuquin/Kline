#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_pyscript_io_contract.py — 扫 `Kline/PyScripts/*.py` 的**桥接 IO 契约**。

契约（见 `KlinePythonBridge.assemblePyRun`）：包装脚本以
`g = {"__name__": "__main__", "__file__": 脚本路径, "kline_input": 入参}` 的方式 `exec` 业务脚本，
随后读**模块级** `kline_result`；不是 dict → 抛 `RuntimeError`，
`readResult` 又要求 `ok == true`，于是该脚本的**每一次**调用都失败（调用方只能静默降级）。

为什么需要这个闸门（2026-10-19 基线实验发现）：`quote_snapshot.py` 与 `sim_state.py`
只定义了 `run(inp)`（头注释还写着「产出模块级 kline_result」），**漏了模块级赋值** ——
于是「阶段 C 非帧快照路径」与「阶段 B 状态所有权反转」在生产里**从未生效**，且无人发现。
本脚本把这一类缺陷变成 CI 可拦的检查。

用法:
  python3 scripts/verify_pyscript_io_contract.py            # 扫仓内 PyScripts
  python3 scripts/verify_pyscript_io_contract.py <dir>      # 扫指定目录（如改动前的副本）
退出码 0 = 全部符合契约；非 0 = 有脚本不符。
"""

import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(REPO, "Kline", "PyScripts")


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    if not os.path.isdir(directory):
        print("目录不存在：%s" % directory)
        return 2
    names = sorted(n for n in os.listdir(directory) if n.endswith(".py"))
    if not names:
        print("目录内无 .py：%s" % directory)
        return 2

    bad, skipped = [], []
    for name in names:
        path = os.path.join(directory, name)
        with open(path, encoding="utf-8") as f:
            src = f.read()
        g = {"__name__": "__main__", "__file__": path,
             "kline_input": {"op": "__contract_probe__"}}
        try:
            exec(compile(src, path, "exec"), g)
        except ModuleNotFoundError as exc:
            # PC 侧缺第三方依赖（引擎内才有）：本闸门不判它，交由引擎内测试覆盖
            skipped.append((name, str(exc)))
            continue
        except Exception as exc:  # noqa: BLE001
            bad.append((name, "执行异常：%s" % exc))
            continue
        result = g.get("kline_result")
        if not isinstance(result, dict) or "ok" not in result:
            bad.append((name, "模块级 kline_result 缺失或非 dict（实得 %r）" % (result,)))
            continue
        print("OK   %-24s ok=%s %s" % (name, result.get("ok"),
                                     (result.get("error") or "")[:60]))

    print("-" * 72)
    print("脚本 %d / 符合 %d / 不符 %d / 跳过 %d"
          % (len(names), len(names) - len(bad) - len(skipped), len(bad), len(skipped)))
    for name, why in skipped:
        print("  SKIP %s：%s" % (name, why))
    for name, why in bad:
        print("  FAIL %s：%s" % (name, why))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
