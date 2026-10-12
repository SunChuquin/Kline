# -*- coding: utf-8 -*-
"""chan.py — 缠论 K 线聚合（合并 → 分型 → 笔），chan.py 语义移植版。

契约来源
  - `.trae/documents/python-engine/Python引擎下沉可行性分析.md` 候选 15
    （缠论 K 线聚合扩展，参考开源 chan.py）。

Provenance / 许可
  - 算法语义逐分支移植自 chan.py（https://github.com/Vespa314/chan.py，
    MIT License，Copyright (c) 2022 Memos），对应源文件：
    Combiner/KLine_Combiner.py（K 线包含关系合并 + 一字K线特判）、
    KLine/KLine.py（check_fx_valid STRICT 模式，CChanConfig 层默认）、
    KLine/KLine_List.py（add_single_klu 驱动）、
    Bi/BiList.py（笔生成状态机）、Bi/Bi.py（笔端点/峰值 klu）。
  - 移植范围锁定默认配置（以 CChanConfig({}) 构造 CBiConfig 的生效值为准，
    注意其与 CBiConfig 类自身默认不同）：bi_algo=normal、bi_strict=True、
    bi_fx_check=strict（CChanConfig 层默认；CBiConfig 类默认 "half" 不生效）、
    gap_as_kl=False（CChanConfig 层默认；类默认 True 不生效）、
    bi_end_is_peak=True、bi_allow_sub_peak=True、
    trigger_step=False（无虚笔 / 无 update_peak 路径——bi_allow_sub_peak=True
    使 can_update_peak 恒 False，虚笔仅服务 seg/zs 不在本脚本范围）。
    exclude_included=False、allow_top_equal=None（普通合并模式）。
  - PC 差分 oracle 即 chan.py 原版（scripts/verify_chan.py），golden 由其产出。

执行契约（由 Swift 桥接层包装，本脚本不做文件 IO、不依赖 stdout）
  - 桥接把输入 JSON 解析后注入模块全局变量 `kline_input`（dict）；
  - 本脚本定义模块级 dict `kline_result`，`kline_result["ok"]` 为 bool。

op = "chan"（日线序列 → 合并 K 线 + 分型 + 笔）
  输入: {"op":"chan","bars":[[d,o,h,l,c],...]}
  - bars 按 d 升序（乱序先排序）；o/h/l/c 数值，要求 low<=min(o,c) 且
    high>=max(o,c)（与 chan.py CKLine_Unit.check 一致，非法报错）。
  - 输出: {"ok":true,"result":{
      "klc":[{"idx":..,"dir":1|-1,"high":..,"low":..,"fromKlu":..,"toKlu":..,"fx":1|-1|0},...],
      "bi":[{"idx":..,"dir":1|-1,"fromKlc":..,"toKlc":..,
             "beginVal":..,"endVal":..,"fromKlu":..,"toKlu":..},...]}}
    - klc.dir：1=UP/-1=DOWN（本 klc 的合并方向，决定包含时取高低原则）；
    - klc.fx：1=顶分型/-1=底分型/0=未知；
    - klu 下标为 bars 排序后的原始行号；fromKlu/toKlu = 合并区间起止；
    - bi.dir：1=向上笔（起于底分型）/-1=向下笔；fromKlu/toKlu 为笔起止
      峰值 klu（klc 内从后往前首个等于合并 high/low 者，同 chan.py get_peak_klu）。
"""

_UP, _DOWN, _COMBINE = 1, -1, 0
_FX_TOP, _FX_BOTTOM, _FX_UNKNOWN = 1, -1, 0


def _err(msg):
    return {"ok": False, "error": msg}


def _as_num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


class _Klu(object):
    """单位 K 线（原始 bar）。"""

    __slots__ = ("idx", "high", "low")

    def __init__(self, idx, high, low):
        self.idx = idx
        self.high = high
        self.low = low


class _Klc(object):
    """合并后 K 线（chan.py CKLine_Combiner 语义）。"""

    __slots__ = ("idx", "dir", "high", "low", "lst", "fx", "pre", "next")

    def __init__(self, klu, idx, _dir):
        self.idx = idx
        self.dir = _dir
        self.high = klu.high
        self.low = klu.low
        self.lst = [klu]
        self.fx = _FX_UNKNOWN
        self.pre = None
        self.next = None

    # ---- Combiner.try_add：返回 UP/DOWN/COMBINE，COMBINE 时原地合并 ----
    def try_add(self, klu):
        h, l = klu.high, klu.low
        if self.high >= h and self.low <= l:
            d = _COMBINE          # 新K线被包含（或相等）
        elif self.high <= h and self.low >= l:
            d = _COMBINE          # 旧K线被包含
        elif self.high > h and self.low > l:
            d = _DOWN
        else:                     # self.high < h and self.low < l
            d = _UP
        if d == _COMBINE:
            self.lst.append(klu)
            if self.dir == _UP:
                # 一字K线特判：h==l 且 h==self.high → 不更新（保持原高低）
                if h != l or h != self.high:
                    self.high = max(self.high, h)
                    self.low = max(self.low, l)
            elif self.dir == _DOWN:
                if h != l or l != self.low:
                    self.high = min(self.high, h)
                    self.low = min(self.low, l)
            else:
                return _err_dir(self.dir)
        return d

    # ---- Combiner.update_fx（普通模式）+ 链表维护 ----
    def update_fx(self, pre, nxt):
        self.next = nxt
        self.pre = pre
        nxt.pre = self
        if pre.high < self.high and nxt.high < self.high and \
           pre.low < self.low and nxt.low < self.low:
            self.fx = _FX_TOP
        elif pre.high > self.high and nxt.high > self.high and \
           pre.low > self.low and nxt.low > self.low:
            self.fx = _FX_BOTTOM
        else:
            self.fx = _FX_UNKNOWN

    # ---- CKLine.check_fx_valid（STRICT，for_virtual=False）----
    # 注意：chan.py CChanConfig 层默认 bi_fx_check="strict"（CBiConfig 类默认
    # "half" 不会生效）：比 HALF 多看 self.pre 与 item2.next 一根。
    def check_fx_valid(self, item2):
        """self 为笔的候选起点分型（TOP/BOTTOM），item2 为候选终点分型。"""
        if self.fx == _FX_TOP:
            item2_high = max(item2.pre.high, item2.high, item2.next.high)
            self_low = min(self.pre.low, self.low, self.next.low)
            return self.high > item2_high and item2.low < self_low
        if self.fx == _FX_BOTTOM:
            item2_low = min(item2.pre.low, item2.low, item2.next.low)
            cur_high = max(self.pre.high, self.high, self.next.high)
            return self.low < item2_low and item2.high > cur_high
        return False

    # ---- Combiner.get_peak_klu：从后往前首个等于合并高/低的 klu ----
    def peak_klu(self, is_high):
        want = self.high if is_high else self.low
        for k in reversed(self.lst):
            if (k.high if is_high else k.low) == want:
                return k
        return None


def _err_dir(d):
    raise ValueError("KLINE_DIR=%r 非法（必须为 UP/DOWN）" % (d,))


class _Bi(object):
    """笔（chan.py CBi 语义，sure-only）。"""

    __slots__ = ("idx", "begin_klc", "end_klc", "dir")

    def __init__(self, begin_klc, end_klc, idx):
        if begin_klc.fx == _FX_BOTTOM:
            self.dir = _UP
        elif begin_klc.fx == _FX_TOP:
            self.dir = _DOWN
        else:
            raise ValueError("笔起点必须为顶/底分型（fx=%r）" % (begin_klc.fx,))
        if self.dir == _UP:
            if not begin_klc.low < end_klc.high:
                raise ValueError("向上笔方向与端点不一致")
        else:
            if not begin_klc.high > end_klc.low:
                raise ValueError("向下笔方向与端点不一致")
        self.idx = idx
        self.begin_klc = begin_klc
        self.end_klc = end_klc

    def is_up(self):
        return self.dir == _UP

    def get_begin_val(self):
        return self.begin_klc.low if self.is_up() else self.begin_klc.high

    def get_end_val(self):
        return self.end_klc.high if self.is_up() else self.end_klc.low

    def get_begin_klu(self):
        return self.begin_klc.peak_klu(is_high=not self.is_up())

    def get_end_klu(self):
        return self.end_klc.peak_klu(is_high=self.is_up())


class _BiList(object):
    """笔列表状态机（chan.py CBiList 语义，默认配置简化路径）。

    默认 bi_allow_sub_peak=True ⇒ can_update_peak 恒 False（update_peak 不移植）；
    trigger_step=False ⇒ 无虚笔（update_bi 仅 update_bi_sure）。
    """

    def __init__(self):
        self.bi_list = []
        self.last_end = None
        self.free_klc_lst = []

    def update_bi(self, klc):
        """klc = 倒数第二根 klc（fx 已更新）。返回是否产生新笔。"""
        if klc.fx == _FX_UNKNOWN:
            return False
        if self.last_end is None or len(self.bi_list) == 0:
            return self.try_create_first_bi(klc)
        if klc.fx == self.last_end.fx:
            return self.try_update_end(klc)
        if self.can_make_bi(klc, self.last_end):
            self.add_new_bi(self.last_end, klc)
            self.last_end = klc
            return True
        return False

    def try_create_first_bi(self, klc):
        for exist in self.free_klc_lst:
            if exist.fx == klc.fx:
                continue
            if self.can_make_bi(klc, exist):
                self.add_new_bi(exist, klc)
                self.last_end = klc
                return True
        self.free_klc_lst.append(klc)
        self.last_end = klc
        return False

    def add_new_bi(self, pre_klc, cur_klc):
        self.bi_list.append(_Bi(pre_klc, cur_klc, idx=len(self.bi_list)))

    def satisfy_bi_span(self, klc, last_end):
        """is_strict=True 且 gap_as_kl=False（CChanConfig 层默认）：span>=4，
        无跳空补偿（gap 补偿仅在 gap_as_kl=True 时逐 klc 查 has_gap_with_next）。"""
        return klc.idx - last_end.idx >= 4

    def can_make_bi(self, klc, last_end):
        """klc=候选新端，last_end=旧端（参数顺序同 chan.py）。"""
        if not self.satisfy_bi_span(klc, last_end):
            return False
        if not last_end.check_fx_valid(klc):
            return False
        if not _end_is_peak(last_end, klc):  # bi_end_is_peak=True
            return False
        return True

    def try_update_end(self, klc):
        if len(self.bi_list) == 0:
            return False
        last_bi = self.bi_list[-1]
        if last_bi.is_up() and klc.fx == _FX_TOP and klc.high >= last_bi.get_end_val():
            last_bi.end_klc = klc
            self.last_end = klc
            return True
        if (not last_bi.is_up()) and klc.fx == _FX_BOTTOM and \
                klc.low <= last_bi.get_end_val():
            last_bi.end_klc = klc
            self.last_end = klc
            return True
        return False


def _end_is_peak(last_end, cur_end):
    """bi_end_is_peak：两分型之间不允许存在越过终点的高/低。"""
    if last_end.fx == _FX_BOTTOM:
        cmp_thred = cur_end.high
        klc = last_end.next
        while True:
            if klc.idx >= cur_end.idx:
                return True
            if klc.high > cmp_thred:
                return False
            klc = klc.next
    elif last_end.fx == _FX_TOP:
        cmp_thred = cur_end.low
        klc = last_end.next
        while True:
            if klc.idx >= cur_end.idx:
                return True
            if klc.low < cmp_thred:
                return False
            klc = klc.next
    return True


class _Chan(object):
    """chan.py CKLine_List.add_single_klu 驱动（trigger_step=False）。"""

    def __init__(self):
        self.lst = []          # List[_Klc]
        self.bi_list = _BiList()

    def add_klu(self, klu):
        if len(self.lst) == 0:
            self.lst.append(_Klc(klu, idx=0, _dir=_UP))
            return
        d = self.lst[-1].try_add(klu)
        if isinstance(d, dict):  # 防御（_err_dir 包装）——理论不可达
            raise ValueError(d.get("error", "combine err"))
        if d != _COMBINE:
            self.lst.append(_Klc(klu, idx=len(self.lst), _dir=d))
            if len(self.lst) >= 3:
                self.lst[-2].update_fx(self.lst[-3], self.lst[-1])
            self.bi_list.update_bi(self.lst[-2])


def _op_chan(inp):
    bars = inp.get("bars")
    if not isinstance(bars, list) or len(bars) < 1:
        return _err("chan: bars 必须为非空数组 [[d,o,h,l,c],...]")
    rows = []
    for i, b in enumerate(bars):
        if not isinstance(b, (list, tuple)) or len(b) < 5:
            return _err("chan: bars[%d] 必须为 5 元素数组 [d,o,h,l,c]" % i)
        d = b[0]
        if isinstance(d, bool) or not isinstance(d, (int, float)):
            return _err("chan: bars[%d].date 非法: %r" % (i, d))
        vals = []
        for v in b[1:5]:
            n = _as_num(v)
            if n is None:
                return _err("chan: bars[%d] 价格非法: %r" % (i, v))
            vals.append(float(n))
        o, h, l, c = vals
        if l > min(l, o, c) or h < max(h, o, c):
            return _err("chan: bars[%d] low/high 与 open/close 不一致（low=%.10g high=%.10g o=%.10g c=%.10g）"
                        % (i, l, h, o, c))
        rows.append((d, i, o, h, l, c))
    rows.sort(key=lambda x: (x[0], x[1]))  # date 升序（稳定，同序保持）

    chan = _Chan()
    klus = []
    for pos, (d, _orig, o, h, l, c) in enumerate(rows):
        klu = _Klu(pos, h, l)
        klus.append(klu)
        chan.add_klu(klu)

    klc_json = []
    for klc in chan.lst:
        klc_json.append({
            "idx": klc.idx,
            "dir": klc.dir,
            "high": klc.high,
            "low": klc.low,
            "fromKlu": klc.lst[0].idx,
            "toKlu": klc.lst[-1].idx,
            "fx": klc.fx,
        })
    bi_json = []
    for bi in chan.bi_list.bi_list:
        bk = bi.get_begin_klu()
        ek = bi.get_end_klu()
        bi_json.append({
            "idx": bi.idx,
            "dir": bi.dir,
            "fromKlc": bi.begin_klc.idx,
            "toKlc": bi.end_klc.idx,
            "beginVal": bi.get_begin_val(),
            "endVal": bi.get_end_val(),
            "fromKlu": bk.idx if bk is not None else -1,
            "toKlu": ek.idx if ek is not None else -1,
        })
    return {"ok": True, "result": {"klc": klc_json, "bi": bi_json}}


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    op = inp.get("op")
    if op == "chan":
        return _op_chan(inp)
    return _err("未知 op: %r（仅支持 chan）" % (op,))


kline_result = _main()
