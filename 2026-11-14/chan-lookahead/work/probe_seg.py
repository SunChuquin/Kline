#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探针：打印 HSI bars[:4094] 最后两个段的内部状态（eigen、笔 sure 标记）。只读。"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ab_test_v2 as A
import chan

d = json.load(open("daily_11.json"))
bars = A.normalize(d["bars"])[:4094]
A.bar_hi = [b[2] for b in bars]
A.bar_lo = [b[3] for b in bars]

cap = {}
orig = chan._build_segs


def spy(bis):
    cap.setdefault("bis", bis)   # 只取第一次（笔级），后面的调用是段段级
    return orig(bis)


chan._build_segs = spy
res = chan._op_chan({"op": "chan", "bars": bars, "config": dict(A.CFG)})
chan._build_segs = orig
segs = orig(cap["bis"])
bis = cap["bis"]

print("bars=%d bi=%d seg=%d" % (len(bars), len(bis), len(segs)))
for s in segs[-3:]:
    print("\nSEG idx=%d dir=%d startBi=%d endBi=%d biCount=%d is_sure=%s reason=%s"
          % (s.idx, s.dir, s.start_bi.idx, s.end_bi.idx,
             s.end_bi.idx - s.start_bi.idx + 1, s.is_sure, s.reason))
    print("  beginVal=%.2f endVal=%.2f" % (s.get_begin_val(), s.get_end_val()))
    ef = s.eigen_fx
    if ef is None:
        print("  eigen_fx=None")
        continue
    print("  eigen dir=%d ele_n=%d last_evidence_idx=%s last_evidence_sure=%s"
          % (ef.dir, len(ef.ele), getattr(ef.last_evidence_bi, "idx", None),
             ef.last_evidence_bi_is_sure))
    for i, ele in enumerate(ef.ele):
        if ele is None:
            print("   ele[%d]=None" % i)
            continue
        print("   ele[%d] fx=%s gap=%s bis=%s sure=%s" % (
            i, ele.fx, ele.gap,
            [(b.idx, b.dir, b.is_sure, b.used_to_be_sure) for b in ele.lst],
            [b.is_used_to_be_sure for b in ele.lst]))
    print("  all_bi_is_sure=%s" % ef.all_bi_is_sure())

print("\n尾部 8 笔：")
for b in bis[-8:]:
    print(" bi idx=%d dir=%d begin_klc=%s end_klc=%s is_sure=%s used_to_be_sure=%s"
          % (b.idx, b.dir,
             (b.begin_klc.idx, b.begin_klc.high, b.begin_klc.low),
             (b.end_klc.idx, b.end_klc.high, b.end_klc.low),
             b.is_sure, b.used_to_be_sure))
