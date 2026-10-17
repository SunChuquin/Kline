#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""extract_sim_rules_golden.py — 从 xcodebuild 测试输出里抓 dump 出来的 golden。

iOS 模拟器进程受沙盒限制，写不到仓库路径（见 §12.3），因此 dump 模式把
fixture 以 base64 分片打到 stdout，由本脚本抓取落盘。

哨兵：
  KLINE_SIM_RULES_GOLDEN_B64:<idx>:<chunk>   → KlineTests/Fixtures/sim_rules.json
  KLINE_BACKTEST_GOLDEN_B64:<idx>:<chunk>    → KlineTests/Fixtures/backtest_golden.json

用法:
  xcodebuild test -scheme Kline -destination '...' \\
    -only-testing:KlineTests/SimRulesContractTests 2>&1 \\
    | python3 scripts/extract_sim_rules_golden.py
  # 或先落文件再解析：
  python3 scripts/extract_sim_rules_golden.py xcodebuild.log
"""

import base64
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX_DIR = os.path.join(REPO, "KlineTests", "Fixtures")

_TARGETS = {
    "KLINE_SIM_RULES_GOLDEN_B64": os.path.join(FIX_DIR, "sim_rules.json"),
    "KLINE_BACKTEST_GOLDEN_B64": os.path.join(FIX_DIR, "backtest_golden.json"),
}

_CHUNK_RE = re.compile(r"(KLINE_[A-Z_]+_B64):(\d+):([A-Za-z0-9+/=]+)")


def main():
    if len(sys.argv) >= 2:
        text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    else:
        text = sys.stdin.read()

    buckets = {}
    for m in _CHUNK_RE.finditer(text):
        sentinel, idx, chunk = m.group(1), int(m.group(2)), m.group(3)
        buckets.setdefault(sentinel, {})[idx] = chunk

    if not buckets:
        print("未发现任何 dump 哨兵（是否以 KLINE_DUMP_SIM_RULES=1 跑测试？）", file=sys.stderr)
        return 1

    for sentinel, parts in buckets.items():
        if sentinel not in _TARGETS:
            print("忽略未知哨兵 %s" % sentinel, file=sys.stderr)
            continue
        b64 = "".join(parts[i] for i in sorted(parts))
        raw = base64.b64decode(b64)
        obj = json.loads(raw.decode("utf-8"))
        path = _TARGETS[sentinel]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("已写入 %s（%d 分片，%d 字节）" % (os.path.relpath(path, REPO), len(parts), len(raw)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
