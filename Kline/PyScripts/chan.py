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
  输入: {"op":"chan","bars":[[d,o,h,l,c],...],"config":{...}}
  - bars 按 d 升序（乱序先排序）；o/h/l/c 数值，要求 low<=min(o,c) 且
    high>=max(o,c)（与 chan.py CKLine_Unit.check 一致，非法报错）。
  - config 可选；缺省时全部取默认值（与历史输出逐字节一致）。
  - 输出: {"ok":true,"result":{
      "klc":[{"idx":..,"dir":1|-1,"high":..,"low":..,"fromKlu":..,"toKlu":..,"fx":1|-1|0},...],
      "bi":[{"idx":..,"dir":1|-1,"fromKlc":..,"toKlc":..,
             "beginVal":..,"endVal":..,"fromKlu":..,"toKlu":..,
             "confirmed":true|false},...]}}
    - klc.dir：1=UP/-1=DOWN（本 klc 的合并方向，决定包含时取高低原则）；
    - klc.fx：1=顶分型/-1=底分型/0=未知；
    - klu 下标为 bars 排序后的原始行号；fromKlu/toKlu = 合并区间起止；
    - bi.dir：1=向上笔（起于底分型）/-1=向下笔；fromKlu/toKlu 为笔起止
      峰值 klu（klc 内从后往前首个等于合并 high/low 者，同 chan.py get_peak_klu）；
    - bi.confirmed：仅当 bi_last_unconfirmed=true 时输出（默认不输出，保持旧契约）。

config 白名单（未知键 / 非法值 → {"ok":false,"error":...} 结构化错误，不抛异常）
  - bi_algo: "normal"（默认）| "clv1"
      normal = chan.py CBiList 流式状态机（历史行为）；
      clv1   = 分型序列法（老笔）：先按"相邻同类保留更极端"归并分型，再在异类
               分型间成笔。两者在"同类分型价格相等"与首笔候选选择上不同，不能
               只靠下面三个开关互相等价。
  - bi_min_gap: 4（默认）| 3  成笔所需的最小合并K线下标差。
      normal 映射 chan.py is_strict=True 的 span>=4（默认）/ span>=3；
      clv1   映射 CL-V1 R3：两分型中心合并K线下标差 >= 3。
  - bi_fx_check: "strict"（默认）| "skip"  分型校验强度。
      strict = chan.py CKLine.check_fx_valid（除 pre/self/next 三点高低关系外，
               还要求两分型端点方向互破）；
      skip   = 跳过该额外校验，只保留"异类分型 + 间隔 + 顶高于底"三项。
  - bi_end_is_peak: true（默认）| false  笔终点是否必须为两分型区间内的极值。
      true  = chan.py bi_end_is_peak（分型之间不允许越过终点的高/低）；
      false = 不做该校验（CL-V1 R3 无此条）。
  - bi_last_unconfirmed: false（默认）| true  末笔未完成表达。
      false = 末笔按最后一个已确认分型收笔（历史行为）；
      true  = CL-V1 R3 末笔顺延：最后一个分型之后若继续创出该笔方向的新极值，
              端点顺延到该极值K线；无论是否顺延都把末笔 confirmed 置 false 并
              在 bi 元素上输出 confirmed 字段（新增字段，不改变既有字段语义）。
  - include_segments: false（默认）| true  是否附带线段。
      true 时 result 增加顶层 "segments"（seg_algo="chan"：特征序列 + 缺口第二
      序列确认 + 段终点极值 + 笔破坏回溯；left_method="peak"）。线段在内部
      笔视图上计算：normal 分支按上游规则补 1 根末尾虚笔（不进入 bi 数组），
      clv1 分支把末笔视为未确认笔。segments 元素:
        {"idx":..,"dir":1|-1,"startBi":..,"endBi":..,
         "beginVal":..,"endVal":..,"confirmed":bool,"reason":..,"biCount":..}
      注意 startBi/endBi 是内部笔视图下标，normal 分支可能等于末笔之后新增的
      虚笔下标（即 bi 数组长度），不会改变 bi 数组本身。
      false 时不输出该字段，其余输出与历史逐字节一致。
  - include_centers: true（默认）| false  是否附带笔中枢。
      中枢只在显式请求时输出：显式传 include_centers=true，或传
      include_seg_centers=true；两个键都不传时 result 不含任何中枢字段
      （与 P1 输出逐字节一致）。语义 = chan.py ZS/ZSList（zs_algo="normal"、
      one_bi_zs=False、need_combine=True、zs_combine_mode="zs"）：在每条线段
      内部取反向笔成中枢、同区间延伸、同段内合并。顶层键 "centers"，元素：
        {"idx","beginLine","endLine","beginKlu","endKlu","zg","zd","gg","dd",
         "lineCount","confirmed","extended","merged","ended"}
      beginLine/endLine = 笔下标；beginKlu/endKlu = 对应原始 K 线下标；
      zg/zd = 中枢区间（ZG/ZD）；gg/dd = 区间内最高/最低（GG/DD）；
      lineCount = 成分笔数；confirmed = 所属线段是否确认；
      extended = 是否被后续笔延伸（成分 > 初始 2 根）；merged = 合并吸收的
      中枢数；ended = 是否已终结（后续已出现离开区间的笔）。
  - include_seg_centers: false（默认）| true  是否附带段中枢（高级项）。
      以线段为"线"、以段段（segseg）为容器，与上游 segzs_list 同构；
      顶层键 "segCenters"，字段同上，beginLine/endLine 改为段下标。
      为 true 时同时输出 "centers"。

CL-V1 口径预设（P0 对齐用，客户端显式传入）:
  {"bi_algo":"clv1","bi_min_gap":3,"bi_fx_check":"skip",
   "bi_end_is_peak":false,"bi_last_unconfirmed":true}
"""

_UP, _DOWN, _COMBINE = 1, -1, 0
_FX_TOP, _FX_BOTTOM, _FX_UNKNOWN = 1, -1, 0


def _err(msg):
    return {"ok": False, "error": msg}


def _as_num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


# ---------------------------------------------------------------- 配置
_DEFAULT_CONFIG = {
    "bi_algo": "normal",
    "bi_min_gap": 4,
    "bi_fx_check": "strict",
    "bi_end_is_peak": True,
    "bi_last_unconfirmed": False,
    "include_segments": False,
    "include_centers": True,
    "include_seg_centers": False,
}

_CONFIG_CHOICES = {
    "bi_algo": ("normal", "clv1"),
    "bi_min_gap": (3, 4),
    "bi_fx_check": ("strict", "skip"),
    "bi_end_is_peak": (True, False),
    "bi_last_unconfirmed": (True, False),
    "include_segments": (True, False),
    "include_centers": (True, False),
    "include_seg_centers": (True, False),
}


def _bad_config(msg):
    return _err("chan: config 非法 — " + msg)


def _parse_config(inp):
    """返回 (cfg, err)。cfg 为合并默认值后的 dict；err 为结构化错误或 None。"""
    raw = inp.get("config")
    if raw is None:
        return dict(_DEFAULT_CONFIG), None
    if not isinstance(raw, dict):
        return None, _bad_config("config 必须为对象，实际 %s" % type(raw).__name__)
    unknown = sorted(set(raw) - set(_DEFAULT_CONFIG), key=str)
    if unknown:
        return None, _bad_config("未知键 %r（白名单：%s）"
                                 % (unknown, sorted(_DEFAULT_CONFIG)))
    cfg = dict(_DEFAULT_CONFIG)
    for key, val in raw.items():
        want = _CONFIG_CHOICES[key]
        if key == "bi_min_gap":
            ok_type = isinstance(val, int) and not isinstance(val, bool)
        elif key in ("bi_end_is_peak", "bi_last_unconfirmed", "include_segments",
                     "include_centers", "include_seg_centers"):
            ok_type = isinstance(val, bool)
        else:
            ok_type = isinstance(val, str)
        if not ok_type or val not in want:
            return None, _bad_config("%s 取值 %r 非法（允许 %r）" % (key, val, want))
        cfg[key] = val
    return cfg, None


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

    # ---- CKLine.check_fx_valid（STRICT，for_virtual=True）----
    # 虚笔没有第三根 KLC：item2 只看 pre/self，且要求 item2.dir 与笔方向相反。
    def check_fx_valid_virtual(self, item2):
        if self.fx == _FX_TOP:
            if item2.dir != _DOWN:
                return False
            item2_high = max(item2.pre.high, item2.high)
            self_low = min(self.pre.low, self.low, self.next.low)
            return self.high > item2_high and item2.low < self_low
        if self.fx == _FX_BOTTOM:
            if item2.dir != _UP:
                return False
            item2_low = min(item2.pre.low, item2.low)
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

    def __init__(self, cfg):
        self.cfg = cfg
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
        return klc.idx - last_end.idx >= self.cfg["bi_min_gap"]

    def can_make_bi(self, klc, last_end):
        """klc=候选新端，last_end=旧端（参数顺序同 chan.py）。"""
        if not self.satisfy_bi_span(klc, last_end):
            return False
        if self.cfg["bi_fx_check"] != "skip" and not last_end.check_fx_valid(klc):
            return False
        if self.cfg["bi_end_is_peak"] and not _end_is_peak(last_end, klc):
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


# ---------------------------------------------------------------- CL-V1 笔层
# 语义对应 CL-V1 R1–R3（老笔），独立于上面的 normal 流式状态机：
# 两者在"同类分型价格相等"与首笔候选选择上不同，无法只靠开关互相等价。


class _MK(object):
    """CL-V1 合并K线（R1），额外记录极值所在原始K线下标（相等时保留较早者）。"""

    __slots__ = ("i0", "i1", "h", "l", "hi", "li", "dir")

    def __init__(self, i, h, l):
        self.i0 = i
        self.i1 = i
        self.h = h
        self.l = l
        self.hi = i
        self.li = i
        self.dir = _UP


def _clv1_merge(bars):
    """R1 包含处理：bars=[(d,o,h,l,c),...]（已按下标排序）→ [_MK]。"""
    mks = []
    for i, (_d, _o, h, l, _c) in enumerate(bars):
        if not mks:
            mks.append(_MK(i, h, l))
            continue
        last = mks[-1]
        contained = (h >= last.h and l <= last.l) or (h <= last.h and l >= last.l)
        if not contained:
            mk = _MK(i, h, l)
            mk.dir = _UP if h > last.h else _DOWN
            mks.append(mk)
            continue
        # 合并方向：已有 >=2 根取上一根相对前一根的走向，否则比较当前与上一根高点
        up = (last.h > mks[-2].h) if len(mks) >= 2 else (h > last.h)
        if up:
            nh, nl = max(last.h, h), max(last.l, l)
        else:
            nh, nl = min(last.h, h), min(last.l, l)
        nhi = i if (h > last.h if up else h < last.h) else last.hi
        nli = i if (l > last.l if up else l < last.l) else last.li
        last.h, last.l, last.hi, last.li = nh, nl, nhi, nli
        last.i1 = i
    return mks


def _clv1_fractals(mks):
    """R2 分型：返回 [(kind, mk_idx, price)]，相邻同类保留更极端者（严格比较）。"""
    raw = []
    for k in range(1, len(mks) - 1):
        a, b, c = mks[k - 1], mks[k], mks[k + 1]
        if b.h > a.h and b.h > c.h and b.l > a.l and b.l > c.l:
            raw.append((_FX_TOP, k, b.h))
        elif b.l < a.l and b.l < c.l and b.h < a.h and b.h < c.h:
            raw.append((_FX_BOTTOM, k, b.l))
    out = []
    for f in raw:
        if out and out[-1][0] == f[0]:
            keep_new = (f[2] > out[-1][2]) if f[0] == _FX_TOP else (f[2] < out[-1][2])
            if keep_new:
                out[-1] = f
            continue
        out.append(f)
    return out


def _clv1_fx_valid(mks, a_idx, a_kind, b_idx):
    """check_fx_valid(STRICT) 的合并K线版本：a=起点分型，b=终点分型。"""
    a, b = mks[a_idx], mks[b_idx]
    if a_kind == _FX_TOP:
        item2_high = max(mks[b_idx - 1].h, b.h, mks[b_idx + 1].h)
        self_low = min(mks[a_idx - 1].l, a.l, mks[a_idx + 1].l)
        return a.h > item2_high and b.l < self_low
    item2_low = min(mks[b_idx - 1].l, b.l, mks[b_idx + 1].l)
    cur_high = max(mks[a_idx - 1].h, a.h, mks[a_idx + 1].h)
    return a.l < item2_low and b.h > cur_high


def _clv1_end_is_peak(mks, a_idx, a_kind, b_idx):
    """bi_end_is_peak 的合并K线版本：两分型之间不允许越过终点的高/低。"""
    if a_kind == _FX_BOTTOM:
        thred = mks[b_idx].h
        for k in range(a_idx + 1, b_idx):
            if mks[k].h > thred:
                return False
        return True
    thred = mks[b_idx].l
    for k in range(a_idx + 1, b_idx):
        if mks[k].l < thred:
            return False
    return True


def _clv1_build_ends(mks, fractals, cfg):
    """R3 老笔：在归并后的分型序列上取端点。"""
    if len(fractals) < 2:
        return []
    gap = cfg["bi_min_gap"]
    ends = [fractals[0]]
    for f in fractals[1:]:
        last = ends[-1]
        if f[0] == last[0]:
            better = (f[2] > last[2]) if f[0] == _FX_TOP else (f[2] < last[2])
            if better:
                ends[-1] = f
            continue
        if f[1] - last[1] < gap:
            continue
        top, bot = (last, f) if last[0] == _FX_TOP else (f, last)
        if top[2] <= bot[2]:
            continue
        if cfg["bi_fx_check"] != "skip" and \
                not _clv1_fx_valid(mks, last[1], last[0], f[1]):
            continue
        if cfg["bi_end_is_peak"] and \
                not _clv1_end_is_peak(mks, last[1], last[0], f[1]):
            continue
        ends.append(f)
    return ends


def _clv1_last_unconfirmed(bars, bi_json):
    """R3 末笔：最后一个分型之后若创新极值则顺延端点，并标记 confirmed=false。"""
    if not bi_json:
        return
    last = bi_json[-1]
    start = last["toKlu"]
    if last["dir"] == _UP:
        best, best_bar = last["endVal"], last["toKlu"]
        for i in range(len(bars) - 1, start, -1):
            if bars[i][2] > best:
                best, best_bar = bars[i][2], i
                break
        if best > last["endVal"]:
            last["toKlu"], last["endVal"] = best_bar, best
    else:
        best, best_bar = last["endVal"], last["toKlu"]
        for i in range(len(bars) - 1, start, -1):
            if bars[i][3] < best:
                best, best_bar = bars[i][3], i
                break
        if best < last["endVal"]:
            last["toKlu"], last["endVal"] = best_bar, best
    last["confirmed"] = False


def _structure_flags(inp, cfg):
    """中枢输出需显式请求：include_centers 或 include_seg_centers 为 true。
    两者都不传时保持历史输出逐字节一致（include_centers 的"默认 true"只在
    调用方显式请求结构时生效）。返回 (笔中枢, 段中枢)。"""
    raw = inp.get("config")
    raw = raw if isinstance(raw, dict) else {}
    want_seg = cfg["include_seg_centers"] is True
    want_bi = raw.get("include_centers") is True or want_seg
    return want_bi, want_seg


def _fill_structure(result, seg_bis, cfg, want_bi_zs, want_seg_zs):
    """按需补充 segments / centers / segCenters（都不请求时 result 不变）。"""
    if not (cfg["include_segments"] or want_bi_zs or want_seg_zs):
        return
    segs = _build_segs(seg_bis)
    if cfg["include_segments"]:
        result["segments"] = _segments_json(segs)
    if want_bi_zs:
        result["centers"] = _centers_json(_zs_lst_of(seg_bis, segs))
    if want_seg_zs:
        result["segCenters"] = _seg_centers_json(segs)


def _run_clv1(bars, cfg, want_bi_zs=False, want_seg_zs=False):
    """CL-V1 口径：合并 → 分型 → 笔（可选末笔顺延）。返回 result dict。"""
    mks = _clv1_merge(bars)
    fractals = _clv1_fractals(mks)
    ends = _clv1_build_ends(mks, fractals, cfg)

    bi_json = []
    for i, (a, b) in enumerate(zip(ends, ends[1:])):
        up = b[0] == _FX_TOP
        a_mk, b_mk = mks[a[1]], mks[b[1]]
        bi_json.append({
            "idx": i,
            "dir": _UP if up else _DOWN,
            "fromKlc": a[1],
            "toKlc": b[1],
            "beginVal": a_mk.l if up else a_mk.h,
            "endVal": b_mk.h if up else b_mk.l,
            "fromKlu": a_mk.li if up else a_mk.hi,
            "toKlu": b_mk.hi if up else b_mk.li,
        })
    if cfg["bi_last_unconfirmed"]:
        for bi in bi_json:
            bi["confirmed"] = True
        _clv1_last_unconfirmed(bars, bi_json)

    fx_by_mk = {f[1]: f[0] for f in fractals}
    klc_json = [{
        "idx": k,
        "dir": mk.dir,
        "high": mk.h,
        "low": mk.l,
        "fromKlu": mk.i0,
        "toKlu": mk.i1,
        "fx": fx_by_mk.get(k, _FX_UNKNOWN),
    } for k, mk in enumerate(mks)]
    result = {"klc": klc_json, "bi": bi_json}
    _fill_structure(result, _seg_bis_clv1(ends, bi_json, cfg), cfg,
                    want_bi_zs, want_seg_zs)
    return result


# ---------------------------------------------------------------- 线段
# seg_algo="chan" / left_method="peak" 语义移植（chan.py Seg/EigenFX,
# Seg/SegListChan, Seg/SegListComm, Seg/Seg）。内部使用 _SegBi 轻量笔视图：
# normal 分支按上游规则补 1 根末尾虚笔（仅内部），clv1 分支把末笔标为未确认；
# 两者都不改写对外的 bi 数组。

_KUP, _KDOWN, _KCOMBINE, _KINCLUDED = 1, -1, 0, 2


class _SegKlc(object):
    """线段内部使用的端点K线视图（high/low/idx/fx + 原始bar下标 klu）。

    注意：idx 是合并K线下标（与 _Klc.idx 同空间），klu 才是原始 bar 下标。
    中枢导出（beginKlu/endKlu）必须用 klu，否则会把合并下标当原始下标绘制。
    """

    __slots__ = ("idx", "high", "low", "fx", "klu")

    def __init__(self, idx, high, low, fx, klu=None):
        self.idx = idx
        self.high = high
        self.low = low
        self.fx = fx
        self.klu = klu


class _SegBi(object):
    """线段内部使用的笔视图（对应 CBi，但只保留线段需要的字段）。"""

    __slots__ = ("idx", "dir", "begin_klc", "end_klc",
                 "is_sure", "used_to_be_sure", "next", "pre", "seg_idx")

    def __init__(self, idx, begin_klc, end_klc, is_sure=True):
        if begin_klc.fx == _FX_BOTTOM:
            self.dir = _UP
        elif begin_klc.fx == _FX_TOP:
            self.dir = _DOWN
        else:
            raise ValueError("线段笔视图起点必须为顶/底分型")
        self.idx = idx
        self.begin_klc = begin_klc
        self.end_klc = end_klc
        self.is_sure = is_sure
        self.used_to_be_sure = is_sure
        self.next = None
        self.pre = None
        self.seg_idx = None

    @property
    def is_used_to_be_sure(self):
        return self.is_sure or self.used_to_be_sure

    def is_up(self):
        return self.dir == _UP

    def is_down(self):
        return self.dir == _DOWN

    def get_begin_val(self):
        return self.begin_klc.low if self.is_up() else self.begin_klc.high

    def get_end_val(self):
        return self.end_klc.high if self.is_up() else self.end_klc.low

    def _high(self):
        return self.end_klc.high if self.is_up() else self.begin_klc.high

    def _low(self):
        return self.begin_klc.low if self.is_up() else self.end_klc.low


def _link_seg_bis(bis):
    for i, bi in enumerate(bis):
        bi.pre = bis[i - 1] if i > 0 else None
        bi.next = bis[i + 1] if i + 1 < len(bis) else None


def _seg_vcan_make_bi(klc, last_end, cfg):
    """虚笔候选校验（CBiList.can_make_bi for_virtual=True）。"""
    if klc.idx - last_end.idx < cfg["bi_min_gap"]:
        return False
    if cfg["bi_fx_check"] != "skip" and not last_end.check_fx_valid_virtual(klc):
        return False
    if cfg["bi_end_is_peak"] and not _end_is_peak(last_end, klc):
        return False
    return True


def _seg_bis_normal(chan, cfg):
    """从 normal 分支的确认笔构造内部笔视图，并按上游规则补末尾虚笔。"""
    bis = [_SegBi(b.idx, b.begin_klc, b.end_klc) for b in chan.bi_list.bi_list]
    _link_seg_bis(bis)
    if not bis or not chan.lst:
        return bis
    last_klc = chan.lst[-1]
    last = bis[-1]
    if last_klc.idx == last.end_klc.idx:
        return bis
    if (last.is_up() and last_klc.high >= last.end_klc.high) or \
       (last.is_down() and last_klc.low <= last.end_klc.low):
        last.end_klc = last_klc
        last.used_to_be_sure = True
        last.is_sure = False
        return bis
    tmp = last_klc
    while tmp is not None and tmp.idx > last.end_klc.idx:
        if _seg_vcan_make_bi(tmp, last.end_klc, cfg):
            bis.append(_SegBi(len(bis), last.end_klc, tmp, is_sure=False))
            _link_seg_bis(bis)
            break
        tmp = tmp.pre
    return bis


def _seg_bis_clv1(ends, bi_json, cfg):
    """从 CL-V1 笔（含末笔顺延结果）构造内部笔视图。"""
    bis = []
    for i, (a, b) in enumerate(zip(ends, ends[1:])):
        up = b[0] == _FX_TOP
        if up:
            b_klc = _SegKlc(a[1], bi_json[i]["beginVal"], bi_json[i]["beginVal"],
                            _FX_BOTTOM, bi_json[i]["fromKlu"])
            e_klc = _SegKlc(b[1], bi_json[i]["endVal"], bi_json[i]["endVal"],
                            _FX_TOP, bi_json[i]["toKlu"])
        else:
            b_klc = _SegKlc(a[1], bi_json[i]["beginVal"], bi_json[i]["beginVal"],
                            _FX_TOP, bi_json[i]["fromKlu"])
            e_klc = _SegKlc(b[1], bi_json[i]["endVal"], bi_json[i]["endVal"],
                            _FX_BOTTOM, bi_json[i]["toKlu"])
        bis.append(_SegBi(i, b_klc, e_klc))
    _link_seg_bis(bis)
    if bis and cfg["bi_last_unconfirmed"]:
        bis[-1].is_sure = False
        bis[-1].used_to_be_sure = False
    return bis


class _Eigen(object):
    """特征序列元素（CEigen：对笔做包含合并）。"""

    __slots__ = ("lst", "dir", "high", "low", "fx", "gap")

    def __init__(self, bi, _dir):
        self.lst = [bi]
        self.dir = _dir
        self.high = bi._high()
        self.low = bi._low()
        self.fx = _FX_UNKNOWN
        self.gap = False

    def try_add(self, bi, exclude_included=False, allow_top_equal=None):
        ih, il = bi._high(), bi._low()
        if self.high >= ih and self.low <= il:
            d = _KCOMBINE
        elif self.high <= ih and self.low >= il:
            if allow_top_equal == 1 and self.high == ih and self.low > il:
                d = _KDOWN
            elif allow_top_equal == -1 and self.low == il and self.high < ih:
                d = _KUP
            else:
                d = _KINCLUDED if exclude_included else _KCOMBINE
        elif self.high > ih and self.low > il:
            d = _KDOWN
        elif self.high < ih and self.low < il:
            d = _KUP
        else:
            raise ValueError("特征序列包含关系未知")
        if d == _KCOMBINE:
            self.lst.append(bi)
            if self.dir == _KUP:
                if ih != il or ih != self.high:  # 一字特判（对齐上游）
                    self.high = max(self.high, ih)
                    self.low = max(self.low, il)
            elif self.dir == _KDOWN:
                if ih != il or il != self.low:
                    self.high = min(self.high, ih)
                    self.low = min(self.low, il)
            else:
                raise ValueError("特征序列方向非法")
        return d

    def update_fx(self, pre, nxt, exclude_included=False, allow_top_equal=None):
        if exclude_included:
            if pre.high < self.high and nxt.high <= self.high and nxt.low < self.low:
                if allow_top_equal == 1 or nxt.high < self.high:
                    self.fx = _FX_TOP
            elif nxt.high > self.high and pre.low > self.low and nxt.low >= self.low:
                if allow_top_equal == -1 or nxt.low > self.low:
                    self.fx = _FX_BOTTOM
        else:
            if pre.high < self.high and nxt.high < self.high and \
                    pre.low < self.low and nxt.low < self.low:
                self.fx = _FX_TOP
            elif pre.high > self.high and nxt.high > self.high and \
                    pre.low > self.low and nxt.low > self.low:
                self.fx = _FX_BOTTOM
        if (self.fx == _FX_TOP and pre.high < self.low) or \
           (self.fx == _FX_BOTTOM and pre.low > self.high):
            self.gap = True

    def peak_bi_idx(self, is_high):
        want = self.high if is_high else self.low
        for bi in reversed(self.lst):
            if (bi._high() if is_high else bi._low()) == want:
                return bi.idx
        raise ValueError("特征序列找不到极值笔")

    def get_peak_bi_idx(self):
        assert self.fx != _FX_UNKNOWN
        if self.lst[0].dir == _UP:   # 下降线段，取最低笔的前一笔
            return self.peak_bi_idx(False) - 1
        return self.peak_bi_idx(True) - 1


class _EigenFX(object):
    """线段特征序列状态机（CEigenFX）。"""

    def __init__(self, _dir):
        self.dir = _dir
        self.ele = [None, None, None]
        self.lst = []
        self.exclude_included = True
        self.kl_dir = _KUP if _dir == _UP else _KDOWN
        self.last_evidence_bi = None
        self.last_evidence_bi_is_sure = False
        self.actual_break_flag = True

    def is_up(self):
        return self.dir == _UP

    def is_down(self):
        return self.dir == _DOWN

    def clear(self):
        self.ele = [None, None, None]
        self.lst = []

    def reset(self):
        bi_tmp_list = list(self.lst[1:])
        if self.exclude_included:
            self.clear()
            for bi in bi_tmp_list:
                if self.add(bi):
                    return True
        else:
            assert self.ele[1] is not None
            ele2_begin_idx = self.ele[1].lst[0].idx
            self.ele[0], self.ele[1], self.ele[2] = self.ele[1], self.ele[2], None
            self.lst = [bi for bi in bi_tmp_list if bi.idx >= ele2_begin_idx]
        return False

    def treat_first_ele(self, bi):
        self.ele[0] = _Eigen(bi, self.kl_dir)
        return False

    def treat_second_ele(self, bi):
        assert self.ele[0] is not None
        combine_dir = self.ele[0].try_add(bi, exclude_included=self.exclude_included)
        if combine_dir != _KCOMBINE:
            self.ele[1] = _Eigen(bi, self.kl_dir)
            if (self.is_up() and self.ele[1].high < self.ele[0].high) or \
               (self.is_down() and self.ele[1].low > self.ele[0].low):
                return self.reset()
        return False

    def treat_third_ele(self, bi):
        assert self.ele[0] is not None and self.ele[1] is not None
        self.last_evidence_bi = bi
        self.last_evidence_bi_is_sure = bi.is_used_to_be_sure
        allow_top_equal = (1 if bi.is_down() else -1) if self.exclude_included else None
        combine_dir = self.ele[1].try_add(bi, allow_top_equal=allow_top_equal)
        if combine_dir == _KCOMBINE:
            return False
        self.ele[2] = _Eigen(bi, combine_dir)
        if not self.actual_break():
            return self.reset()
        self.ele[1].update_fx(self.ele[0], self.ele[2],
                              exclude_included=self.exclude_included,
                              allow_top_equal=allow_top_equal)
        fx = self.ele[1].fx
        is_fx = (self.is_up() and fx == _FX_TOP) or \
                (self.is_down() and fx == _FX_BOTTOM)
        return True if is_fx else self.reset()

    def add(self, bi):
        assert bi.dir != self.dir
        self.lst.append(bi)
        if self.ele[0] is None:
            return self.treat_first_ele(bi)
        if self.ele[1] is None:
            return self.treat_second_ele(bi)
        if self.ele[2] is None:
            return self.treat_third_ele(bi)
        raise ValueError("特征序列3个元素已齐但未处理")

    def actual_break(self):
        if not self.exclude_included:
            return True
        assert self.ele[2] is not None and self.ele[1] is not None
        if (self.is_up() and self.ele[2].low < self.ele[1].lst[-1]._low()) or \
           (self.is_down() and self.ele[2].high > self.ele[1].lst[-1]._high()):
            return True
        assert len(self.ele[2].lst) == 1
        ele2_bi = self.ele[2].lst[0]
        if ele2_bi.next and ele2_bi.next.next:
            if ele2_bi.is_down():
                if ele2_bi.next.next._low() < ele2_bi._low():
                    self.last_evidence_bi = ele2_bi.next.next
                    self.last_evidence_bi_is_sure = ele2_bi.next.next.is_used_to_be_sure
                    return True
                if not ele2_bi.next.next.is_used_to_be_sure or \
                        ele2_bi.next.next.next is None:
                    self.actual_break_flag = False
                    return True
            elif ele2_bi.is_up():
                if ele2_bi.next.next._high() > ele2_bi._high():
                    self.last_evidence_bi = ele2_bi.next.next
                    self.last_evidence_bi_is_sure = ele2_bi.next.next.is_used_to_be_sure
                    return True
                if not ele2_bi.next.next.is_used_to_be_sure or \
                        ele2_bi.next.next.next is None:
                    self.actual_break_flag = False
                    return True
        else:
            if ele2_bi.next:
                if self.is_up() and ele2_bi.next._high() > self.ele[1].high:
                    pass
                elif self.is_down() and ele2_bi.next._low() < self.ele[1].low:
                    pass
                else:
                    self.actual_break_flag = False
                    return True
            else:
                self.actual_break_flag = False
                return True
        return False

    def can_be_end(self, bi_lst):
        assert self.ele[1] is not None
        if self.ele[1].gap:
            end_bi_idx = self.get_peak_bi_idx()
            thred_value = bi_lst[end_bi_idx].get_end_val()
            break_thred = self.ele[0].low if self.is_up() else self.ele[0].high
            return self.find_revert_fx(bi_lst, end_bi_idx + 2,
                                       thred_value, break_thred)
        if not self.actual_break_flag:
            return None
        return True

    def get_peak_bi_idx(self):
        assert self.ele[1] is not None
        return self.ele[1].get_peak_bi_idx()

    def all_bi_is_sure(self):
        assert self.last_evidence_bi is not None
        return next((False for bi in self.lst if not bi.is_used_to_be_sure),
                    True) and self.last_evidence_bi_is_sure

    def find_revert_fx(self, bi_lst, begin_idx, thred_value, break_thred):
        first_bi_dir = bi_lst[begin_idx].dir
        egien_fx = _EigenFX(_DOWN if first_bi_dir == _UP else _UP)
        for bi in bi_lst[begin_idx::2]:
            if egien_fx.add(bi):
                while True:
                    _test = egien_fx.can_be_end(bi_lst)
                    if not egien_fx.actual_break_flag:
                        _test = None
                    if _test in (True, None):
                        assert egien_fx.ele[2] is not None
                        self.last_evidence_bi = egien_fx.ele[2].lst[-1]
                        if _test is True:
                            self.last_evidence_bi_is_sure = \
                                self.last_evidence_bi.is_used_to_be_sure and \
                                egien_fx.last_evidence_bi_is_sure
                        return _test
                    if not egien_fx.reset():
                        break
        return None


class _SegEndValueErr(Exception):
    pass


class _SegLenErr(Exception):
    pass


class _Seg(object):
    """线段（CSeg）。"""

    __slots__ = ("idx", "start_bi", "end_bi", "is_sure", "used_to_be_sure",
                 "dir", "bi_list", "eigen_fx", "pre", "next", "reason", "seg_idx")

    def __init__(self, idx, start_bi, end_bi, is_sure=True, seg_dir=None,
                 reason="normal"):
        assert start_bi.idx == 0 or start_bi.dir == end_bi.dir or not is_sure
        self.idx = idx
        self.start_bi = start_bi
        self.end_bi = end_bi
        self.is_sure = is_sure
        self.used_to_be_sure = is_sure
        self.dir = end_bi.dir if seg_dir is None else seg_dir
        self.bi_list = []
        self.eigen_fx = None
        self.pre = None
        self.next = None
        self.seg_idx = None
        self.reason = reason
        if end_bi.idx - start_bi.idx < 2:
            self.is_sure = False
        self.check()

    def check(self):
        if not self.is_sure:
            return
        if self.is_down():
            if self.start_bi.get_begin_val() < self.end_bi.get_end_val():
                raise _SegEndValueErr("下降线段起始点应该高于结束点")
        elif self.start_bi.get_begin_val() > self.end_bi.get_end_val():
            raise _SegEndValueErr("上升线段起始点应该低于结束点")
        if self.end_bi.idx - self.start_bi.idx < 2:
            raise _SegLenErr("线段长度不能小于2")

    def is_up(self):
        return self.dir == _UP

    def is_down(self):
        return self.dir == _DOWN

    def get_begin_val(self):
        return self.start_bi.get_begin_val()

    def get_end_val(self):
        return self.end_bi.get_end_val()

    @property
    def is_used_to_be_sure(self):
        return self.is_sure or self.used_to_be_sure

    # ---- CSeg._low/_high：段端点极值（供更高级别（段中枢的段段）复用）----
    def _low(self):
        return self.end_bi.get_end_val() if self.is_down() else self.start_bi.get_begin_val()

    def _high(self):
        return self.end_bi.get_end_val() if self.is_up() else self.start_bi.get_begin_val()


def _find_peak_bi(bi_lst, is_high):
    peak_val = float("-inf") if is_high else float("inf")
    peak_bi = None
    for bi in bi_lst:
        if (is_high and bi.get_end_val() >= peak_val and bi.is_up()) or \
           (not is_high and bi.get_end_val() <= peak_val and bi.is_down()):
            if bi.pre and bi.pre.pre and \
               ((is_high and bi.pre.pre.get_end_val() > bi.get_end_val()) or
                    (not is_high and bi.pre.pre.get_end_val() < bi.get_end_val())):
                continue
            peak_val = bi.get_end_val()
            peak_bi = bi
    return peak_bi


class _SegListChan(object):
    """CSegListChan + CSegListComm（left_method="peak"）。"""

    def __init__(self):
        self.lst = []

    def __len__(self):
        return len(self.lst)

    def __getitem__(self, i):
        return self.lst[i]

    def update(self, bi_lst):
        self.do_init()
        if len(self) == 0:
            self.cal_seg_sure(bi_lst, 0)
        else:
            self.cal_seg_sure(bi_lst, self.lst[-1].end_bi.idx + 1)
        self.collect_left_seg(bi_lst)

    def do_init(self):
        while len(self) and not self.lst[-1].is_sure:
            _seg = self.lst[-1]
            if _seg.pre:
                _seg.pre.next = None
            self.lst.pop()
        if len(self):
            assert self.lst[-1].eigen_fx and self.lst[-1].eigen_fx.ele[-1]
            if not self.lst[-1].eigen_fx.ele[-1].lst[-1].is_sure:
                self.lst.pop()

    def cal_seg_sure(self, bi_lst, begin_idx):
        up_eigen = _EigenFX(_UP)    # 上升线段的下降笔
        down_eigen = _EigenFX(_DOWN)  # 下降线段的上升笔
        last_seg_dir = None if len(self) == 0 else self.lst[-1].dir
        for bi in bi_lst[begin_idx:]:
            fx_eigen = None
            if bi.is_down() and last_seg_dir != _UP:
                if up_eigen.add(bi):
                    fx_eigen = up_eigen
            elif bi.is_up() and last_seg_dir != _DOWN:
                if down_eigen.add(bi):
                    fx_eigen = down_eigen
            if len(self) == 0:  # 第一段方向判定
                if up_eigen.ele[1] is not None and bi.is_down():
                    last_seg_dir = _DOWN
                    down_eigen.clear()
                elif down_eigen.ele[1] is not None and bi.is_up():
                    up_eigen.clear()
                    last_seg_dir = _UP
                if up_eigen.ele[1] is None and last_seg_dir == _DOWN and bi.dir == _DOWN:
                    last_seg_dir = None
                elif down_eigen.ele[1] is None and last_seg_dir == _UP and bi.dir == _UP:
                    last_seg_dir = None
            if fx_eigen:
                self.treat_fx_eigen(fx_eigen, bi_lst)
                break

    def treat_fx_eigen(self, fx_eigen, bi_lst):
        _test = fx_eigen.can_be_end(bi_lst)
        end_bi_idx = fx_eigen.get_peak_bi_idx()
        if _test in (True, None):
            is_true = _test is not None
            if not self.add_new_seg(bi_lst, end_bi_idx,
                                    is_sure=is_true and fx_eigen.all_bi_is_sure()):
                self.cal_seg_sure(bi_lst, end_bi_idx + 1)
                return
            self.lst[-1].eigen_fx = fx_eigen
            if is_true:
                self.cal_seg_sure(bi_lst, end_bi_idx + 1)
        else:
            self.cal_seg_sure(bi_lst, fx_eigen.lst[1].idx)

    def try_add_new_seg(self, bi_lst, end_bi_idx, is_sure=True, seg_dir=None,
                        split_first_seg=True, reason="normal"):
        if len(self) == 0 and split_first_seg and end_bi_idx >= 3:
            peak_bi = _find_peak_bi(bi_lst[end_bi_idx - 3::-1],
                                    bi_lst[end_bi_idx].is_down())
            if peak_bi is not None:
                if (peak_bi.is_down() and
                        (peak_bi._low() < bi_lst[0]._low() or peak_bi.idx == 0)) or \
                   (peak_bi.is_up() and
                        (peak_bi._high() > bi_lst[0]._high() or peak_bi.idx == 0)):
                    self.add_new_seg(bi_lst, peak_bi.idx, is_sure=False,
                                     seg_dir=peak_bi.dir, reason="split_first_1st")
                    self.add_new_seg(bi_lst, end_bi_idx, is_sure=False,
                                     reason="split_first_2nd")
                    return
        bi1_idx = 0 if len(self) == 0 else self.lst[-1].end_bi.idx + 1
        bi1 = bi_lst[bi1_idx]
        bi2 = bi_lst[end_bi_idx]
        seg = _Seg(len(self.lst), bi1, bi2, is_sure=is_sure,
                   seg_dir=seg_dir, reason=reason)
        self.lst.append(seg)
        if len(self.lst) >= 2:
            self.lst[-2].next = self.lst[-1]
            self.lst[-1].pre = self.lst[-2]
        seg.bi_list = bi_lst[bi1_idx:end_bi_idx + 1]

    def add_new_seg(self, bi_lst, end_bi_idx, is_sure=True, seg_dir=None,
                    split_first_seg=True, reason="normal"):
        try:
            self.try_add_new_seg(bi_lst, end_bi_idx, is_sure, seg_dir,
                                 split_first_seg, reason)
        except _SegEndValueErr:
            if len(self.lst) == 0:
                return False
            raise
        return True

    def collect_first_seg(self, bi_lst):
        if len(bi_lst) < 3:
            return
        _high = max(bi._high() for bi in bi_lst)
        _low = min(bi._low() for bi in bi_lst)
        if abs(_high - bi_lst[0].get_begin_val()) >= \
                abs(_low - bi_lst[0].get_begin_val()):
            peak_bi = _find_peak_bi(bi_lst, True)
            assert peak_bi is not None
            self.add_new_seg(bi_lst, peak_bi.idx, is_sure=False, seg_dir=_UP,
                             split_first_seg=False, reason="0seg_find_high")
        else:
            peak_bi = _find_peak_bi(bi_lst, False)
            assert peak_bi is not None
            self.add_new_seg(bi_lst, peak_bi.idx, is_sure=False, seg_dir=_DOWN,
                             split_first_seg=False, reason="0seg_find_low")
        self.collect_left_as_seg(bi_lst)

    def collect_left_seg_peak_method(self, last_seg_end_bi, bi_lst):
        find_new_seg = False
        if last_seg_end_bi.is_down():
            peak_bi = _find_peak_bi(bi_lst[last_seg_end_bi.idx + 3:], True)
            if peak_bi and peak_bi.idx - last_seg_end_bi.idx >= 3:
                self.add_new_seg(bi_lst, peak_bi.idx, is_sure=False,
                                 seg_dir=_UP, reason="collectleft_find_high")
                find_new_seg = True
        else:
            peak_bi = _find_peak_bi(bi_lst[last_seg_end_bi.idx + 3:], False)
            if peak_bi and peak_bi.idx - last_seg_end_bi.idx >= 3:
                self.add_new_seg(bi_lst, peak_bi.idx, is_sure=False,
                                 seg_dir=_DOWN, reason="collectleft_find_low")
                find_new_seg = True
        last_seg_end_bi = self.lst[-1].end_bi
        if not find_new_seg:
            self.collect_left_as_seg(bi_lst)
        else:
            self.collect_left_seg_peak_method(last_seg_end_bi, bi_lst)

    def collect_segs(self, bi_lst):
        last_bi = bi_lst[-1]
        last_seg_end_bi = self.lst[-1].end_bi
        if last_bi.idx - last_seg_end_bi.idx < 3:
            return
        if last_seg_end_bi.is_down() and last_bi.get_end_val() <= last_seg_end_bi.get_end_val():
            peak_bi = _find_peak_bi(bi_lst[last_seg_end_bi.idx + 3:], True)
            if peak_bi:
                self.add_new_seg(bi_lst, peak_bi.idx, is_sure=False,
                                 seg_dir=_UP, reason="collectleft_find_high_force")
                self.collect_left_seg(bi_lst)
        elif last_seg_end_bi.is_up() and last_bi.get_end_val() >= last_seg_end_bi.get_end_val():
            peak_bi = _find_peak_bi(bi_lst[last_seg_end_bi.idx + 3:], False)
            if peak_bi:
                self.add_new_seg(bi_lst, peak_bi.idx, is_sure=False,
                                 seg_dir=_DOWN, reason="collectleft_find_low_force")
                self.collect_left_seg(bi_lst)
        else:
            self.collect_left_seg_peak_method(last_seg_end_bi, bi_lst)

    def collect_left_seg(self, bi_lst):
        if len(self) == 0:
            self.collect_first_seg(bi_lst)
        else:
            self.collect_segs(bi_lst)
            if len(bi_lst) > 0 and len(self.lst) > 0 and \
                    bi_lst[-1].idx - self.lst[-1].bi_list[-1].idx > 2 and \
                    not self.lst[-1].is_sure:
                self.lst = self.lst[:-1]
                self.collect_left_seg(bi_lst)

    def collect_left_as_seg(self, bi_lst):
        last_bi = bi_lst[-1]
        last_seg_end_bi = self.lst[-1].end_bi
        if last_seg_end_bi.idx + 1 >= len(bi_lst):
            return
        if last_seg_end_bi.dir == last_bi.dir:
            self.add_new_seg(bi_lst, last_bi.idx - 1, is_sure=False,
                             reason="collect_left_1")
        else:
            self.add_new_seg(bi_lst, last_bi.idx, is_sure=False,
                             reason="collect_left_0")


def _build_segs(bi_lst):
    """对（内部）笔视图跑一遍 seg_algo="chan"，返回 _Seg 列表。"""
    sl = _SegListChan()
    sl.update(bi_lst)
    return sl.lst


def _segments_json(segs):
    return [{
        "idx": seg.idx,
        "dir": seg.dir,
        "startBi": seg.start_bi.idx,
        "endBi": seg.end_bi.idx,
        "beginVal": seg.get_begin_val(),
        "endVal": seg.get_end_val(),
        "confirmed": seg.is_sure,
        "reason": seg.reason,
        "biCount": seg.end_bi.idx - seg.start_bi.idx + 1,
    } for seg in segs]


# ---------------------------------------------------------------- 中枢
# chan.py ZS/ZS.py + ZS/ZSList.py 语义移植（zs_algo="normal"、
# one_bi_zs=False、need_combine=True、zs_combine_mode="zs"）。
# 中枢机对"线"（笔或段）是泛型的：笔中枢 = 在每条线段内部取反向笔成中枢；
# 段中枢 = 在线段的线段（segseg）内部取反向段成中枢——与上游
# segzs_list = CZSList().cal_bi_zs(seg_list, segseg_list) 同构。


def _has_overlap(l1, h1, l2, h2, equal=False):
    return (h2 >= l1 and h1 >= l2) if equal else (h2 > l1 and h1 > l2)


def _assign_seg_idx(items, segs):
    """把 items（笔/段）归属到容器 segs（段/段段）的下标（cal_seg 语义）。"""
    j = 0
    for item in items:
        while j < len(segs) and item.idx > segs[j].end_bi.idx:
            j += 1
        item.seg_idx = segs[j].idx if j < len(segs) else len(segs)


def _line_endpoint_klu_idx(item, at_begin):
    """线（笔/段）起点/终点对应的原始 K 线下标（CBi/CSeg get_begin_klu 语义）。

    返回值始终是原始 bar 下标：CL-V1 分支的端点 _SegKlc 直接携带 klu；
    normal 分支的 _Klc.lst 内是 _Klu（idx 即原始下标），按合并极值反查；
    两者之外一律退回合并区间首根原始 K 线，绝不返回 _Klc/_SegKlc 的合并下标。
    """
    if isinstance(item, _Seg):
        return _line_endpoint_klu_idx(
            item.start_bi if at_begin else item.end_bi, at_begin)
    klc = item.begin_klc if at_begin else item.end_klc
    raw = getattr(klc, "klu", None)
    if raw is not None:
        return raw
    is_high = (not item.is_up()) if at_begin else item.is_up()
    lst = getattr(klc, "lst", None)
    if lst:
        want = klc.high if is_high else klc.low
        for k in reversed(lst):
            if (k.high if is_high else k.low) == want:
                return k.idx
        return lst[0].idx
    return klc.idx


class _ZS(object):
    """中枢（CZS）：low/high = ZD/ZG，peak_low/peak_high = DD/GG。"""

    __slots__ = ("begin_bi", "end_bi", "low", "high", "mid",
                 "peak_low", "peak_high", "is_sure", "sub_zs")

    def __init__(self, lst, is_sure=True):
        self.is_sure = is_sure
        self.sub_zs = []
        self.begin_bi = lst[0]
        self.update_zs_range(lst)
        self.peak_high = float("-inf")
        self.peak_low = float("inf")
        for item in lst:
            self.update_zs_end(item)

    def update_zs_range(self, lst):
        self.low = max(bi._low() for bi in lst)
        self.high = min(bi._high() for bi in lst)
        self.mid = (self.low + self.high) / 2

    def update_zs_end(self, item):
        self.end_bi = item
        if item._low() < self.peak_low:
            self.peak_low = item._low()
        if item._high() > self.peak_high:
            self.peak_high = item._high()

    def is_one_bi_zs(self):
        return self.begin_bi.idx == self.end_bi.idx

    def in_range(self, item):
        return _has_overlap(self.low, self.high, item._low(), item._high())

    def try_add_to_end(self, item):
        if not self.in_range(item):
            return False
        if self.is_one_bi_zs():
            self.update_zs_range([self.begin_bi, item])
        self.update_zs_end(item)
        return True

    def combine(self, zs2, combine_mode="zs"):
        if zs2.is_one_bi_zs():
            return False
        if self.begin_bi.seg_idx != zs2.begin_bi.seg_idx:
            return False
        if combine_mode == "zs":
            if not _has_overlap(self.low, self.high, zs2.low, zs2.high, equal=True):
                return False
            self.do_combine(zs2)
            return True
        if not _has_overlap(self.peak_low, self.peak_high,
                            zs2.peak_low, zs2.peak_high):
            return False
        self.do_combine(zs2)
        return True

    def _copy(self):
        cp = _ZS.__new__(_ZS)
        cp.begin_bi = self.begin_bi
        cp.end_bi = self.end_bi
        cp.low = self.low
        cp.high = self.high
        cp.mid = self.mid
        cp.peak_low = self.peak_low
        cp.peak_high = self.peak_high
        cp.is_sure = self.is_sure
        cp.sub_zs = []
        return cp

    def do_combine(self, zs2):
        if len(self.sub_zs) == 0:
            self.sub_zs.append(self._copy())
        self.sub_zs.append(zs2)
        self.low = min(self.low, zs2.low)
        self.high = max(self.high, zs2.high)
        self.peak_low = min(self.peak_low, zs2.peak_low)
        self.peak_high = max(self.peak_high, zs2.peak_high)
        self.end_bi = zs2.end_bi


class _ZSList(object):
    """中枢列表（CZSList.cal_bi_zs 的 zs_algo="normal" 路径）。"""

    __slots__ = ("zs_lst", "free_item_lst", "last_sure_pos", "last_seg_idx")

    def __init__(self):
        self.zs_lst = []
        self.free_item_lst = []
        self.last_sure_pos = -1
        self.last_seg_idx = 0

    def clear_free_lst(self):
        self.free_item_lst = []

    def update_last_pos(self, seg_list):
        self.last_sure_pos = -1
        self.last_seg_idx = 0
        idx = len(seg_list) - 1
        while idx >= 0:
            seg = seg_list[idx]
            if seg.is_sure:
                self.last_sure_pos = seg.start_bi.idx
                self.last_seg_idx = seg.idx
                return
            idx -= 1

    def seg_need_cal(self, seg):
        return seg.start_bi.idx >= self.last_sure_pos

    def try_construct_zs(self, lst, is_sure):
        if len(lst) == 1:
            return None
        lst = lst[-2:]
        min_high = min(item._high() for item in lst)
        max_low = max(item._low() for item in lst)
        return _ZS(lst, is_sure=is_sure) if min_high > max_low else None

    def add_to_free_lst(self, item, is_sure):
        if len(self.free_item_lst) != 0 and item.idx == self.free_item_lst[-1].idx:
            self.free_item_lst = self.free_item_lst[:-1]
        self.free_item_lst.append(item)
        res = self.try_construct_zs(self.free_item_lst, is_sure)
        if res is not None and res.begin_bi.idx > 0:
            self.zs_lst.append(res)
            self.clear_free_lst()
            self.try_combine()

    def try_add_to_end(self, item):
        return False if len(self.zs_lst) == 0 else self.zs_lst[-1].try_add_to_end(item)

    def update(self, item, is_sure=True):
        if len(self.free_item_lst) == 0 and self.try_add_to_end(item):
            self.try_combine()
            return
        self.add_to_free_lst(item, is_sure)

    def add_from_line_range(self, line_lst, seg_dir, seg_is_sure):
        deal_cnt = 0
        for item in line_lst:
            if item.dir == seg_dir:
                continue
            if deal_cnt < 1:
                self.add_to_free_lst(item, seg_is_sure)
                deal_cnt += 1
            else:
                self.update(item, seg_is_sure)

    def try_combine(self):
        while len(self.zs_lst) >= 2 and \
                self.zs_lst[-2].combine(self.zs_lst[-1], combine_mode="zs"):
            self.zs_lst = self.zs_lst[:-1]

    def cal(self, line_lst, seg_lst):
        while self.zs_lst and self.zs_lst[-1].begin_bi.idx >= self.last_sure_pos:
            self.zs_lst.pop()
        for seg in seg_lst[self.last_seg_idx:]:
            if not self.seg_need_cal(seg):
                continue
            self.clear_free_lst()
            self.add_from_line_range(line_lst[seg.start_bi.idx:seg.end_bi.idx + 1],
                                     seg.dir, seg.is_sure)
        if len(seg_lst):
            self.clear_free_lst()
            self.add_from_line_range(line_lst[seg_lst[-1].end_bi.idx + 1:],
                                     -seg_lst[-1].dir, False)
        self.update_last_pos(seg_lst)


def _zs_lst_of(lines, containers):
    _assign_seg_idx(lines, containers)
    zl = _ZSList()
    zl.cal(lines, containers)
    return zl


def _centers_json(zl):
    out = []
    last = len(zl.zs_lst) - 1
    for i, zs in enumerate(zl.zs_lst):
        # 终结：后续已出现不在区间内的线（free_lst 非空）→ 中枢封闭；
        # 末中枢若 free_lst 为空则仍可被延伸。
        ended = True if i < last else len(zl.free_item_lst) > 0
        out.append({
            "idx": i,
            "beginLine": zs.begin_bi.idx,
            "endLine": zs.end_bi.idx,
            "beginKlu": _line_endpoint_klu_idx(zs.begin_bi, True),
            "endKlu": _line_endpoint_klu_idx(zs.end_bi, False),
            "zg": zs.high,
            "zd": zs.low,
            "gg": zs.peak_high,
            "dd": zs.peak_low,
            "lineCount": zs.end_bi.idx - zs.begin_bi.idx + 1,
            "confirmed": zs.is_sure,
            "extended": zs.end_bi.idx - zs.begin_bi.idx > 1,
            "merged": len(zs.sub_zs),
            "ended": ended,
        })
    return out


def _seg_centers_json(segs):
    """段中枢：以线段为"线"、以段段（segseg）为容器，与上游 segzs_list 同构。"""
    if len(segs) < 2:
        return []
    seg_segs = _build_segs(segs)
    return _centers_json(_zs_lst_of(segs, seg_segs))


class _Chan(object):
    """chan.py CKLine_List.add_single_klu 驱动（trigger_step=False）。"""

    def __init__(self, cfg):
        self.lst = []          # List[_Klc]
        self.bi_list = _BiList(cfg)

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
    cfg, cfg_err = _parse_config(inp)
    if cfg_err is not None:
        return cfg_err
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

    ordered = [(d, o, h, l, c) for d, _orig, o, h, l, c in rows]
    want_bi_zs, want_seg_zs = _structure_flags(inp, cfg)
    if cfg["bi_algo"] == "clv1":
        return {"ok": True,
                "result": _run_clv1(ordered, cfg, want_bi_zs, want_seg_zs)}

    chan = _Chan(cfg)
    for pos, (_d, _o, h, l, _c) in enumerate(ordered):
        chan.add_klu(_Klu(pos, h, l))

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
    result = {"klc": klc_json, "bi": bi_json}
    _fill_structure(result, _seg_bis_normal(chan, cfg), cfg,
                    want_bi_zs, want_seg_zs)
    return {"ok": True, "result": result}


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    op = inp.get("op")
    if op == "chan":
        return _op_chan(inp)
    return _err("未知 op: %r（仅支持 chan）" % (op,))


kline_result = _main()
