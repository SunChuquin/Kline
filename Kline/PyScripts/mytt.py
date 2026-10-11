# -*- coding: utf-8 -*-
"""mytt.py — MyTT 麦语言-通达信-同花顺指标函数库（pandas API → numpy 垫片版）。

契约来源
  - `.trae/documents/python-engine/Python引擎下沉可行性分析.md` §3.2 候选 2
    （公式引擎解析层+函数库下沉，阶段 A：MyTT 函数库 + pandas API numpy 垫片）。

Provenance / 许可
  - 函数源码逐行取自 MyTT V3.3（2023-11-09），https://github.com/mpquant/MyTT
    （MIT License，版权所有 mpquant 及社区贡献者），仅把 `import pandas as pd`
    替换为下方的 numpy 垫片 `pd`，函数体零改动。
  - 引擎包仅内嵌 numpy（无 pandas），故 MyTT 依赖的 11 处 pandas API
    （Series.shift/diff/rolling{sum,std,max,min,mean,apply}/ewm/cumsum/ffill）
    由 `_Series`/`_Rolling`/`_EWM` 垫片实现。

垫片语义基准（pandas 2.2.3，PC 探针实测；差分 golden 亦由 pandas 2.2.3 生成）
  - rolling(N) 默认 min_periods=N：窗口不完整或含 NaN → 输出 NaN
    （sum/mean/max/min/std/apply 一致）；
  - cumsum：NaN 位输出 NaN 且跳过累加（[1,nan,3,4] → [1,nan,4,8]，非 np.cumsum 传染）；
  - ewm(adjust=False) NaN 为三段式（pandas 2.2.3 实测）：前导 NaN 输出 NaN、
    首个有效值输出 = x 本身、mid-NaN 位输出保持前值、gap 个 NaN 后的恢复位 v
    满足 y = ((1-α)^(g+1)·y_prev + α·v) / ((1-α)^(g+1) + α)，恢复位之后回到
    纯递推 y = (1-α)·y + α·x（分母重置，非 num/den 双递推——后者会造成
    ~α·gap 级瞬态偏差）。连续有效位与 pandas 逐位同构。
    已知分歧：pandas 3.0.6 在 α=0.5 的 mid-NaN 场景偏离此模型（疑似 bug，
    如 EMA(C,3)），故 golden 一律以 pandas 2.2.3 为准；
  - 浮点：rolling 聚合与 pandas 逐窗算法差异为 ulp 级（实测 sum≤2.2e-16、
    std≤5.5e-14），差分容差 1e-10 相对；ewm 双递推与 pandas Cython 同构，
    期望逐位一致。

执行契约（由 Swift 桥接层包装，本脚本不做文件 IO、不依赖 stdout）
  - 桥接把输入 JSON 解析后注入模块全局变量 `kline_input`（dict）；
  - 本脚本定义模块级 dict `kline_result`，`kline_result["ok"]` 为 bool；
  - 脚本异常由包装统一捕获写 error 字段；输出 NaN 一律序列化为 null
    （桥接 json.dump 的 allow_nan 默认 True 会写出非法 JSON 字面量 NaN）。

op = "functions"（函数库批量求值：输入序列 + 调用表 → 各函数输出序列）
  输入: {"op":"functions",
         "series":{"C":[...],"H":[...],...},          # 等长数值数组；null 视为 NaN
         "calls":[{"id":"ma5","fn":"MA","args":["C",5]},   # id 可选，供后续 $引用
                  {"fn":"CROSS","args":["$ma5","$ma10"]},  # $id 引用前序单输出结果
                  {"fn":"...","args":["$kdj#0"]},          # $id#k 引用多输出第 k 列
                  ...]}
  - args 元素三种：序列名字符串（查 series）/ "$id" / "$id#k" 前序结果引用 /
    数字标量（int/float，拒绝 bool）。序列与 $引用一律传 ndarray 副本
    （FILTER 会原位改写入参，防跨调用污染）。
  - 输出: {"ok":true,"result":{"results":[{"fn":"MA","outputs":[[...]]},...]}}
    多输出函数（MACD/KDJ/DMI 等）outputs 为多列；bool 序列输出 true/false；
    NaN → null。RET 等标量输出为单元素数组。
"""

import numpy as np


#------------------ pandas API 垫片（仅覆盖 MyTT 用到的 11 处调用面） ---------------

class _Series:
    """pd.Series 最小垫片：持有 float ndarray，链式方法返回 _Series。"""

    __slots__ = ("_a",)

    def __init__(self, data):
        self._a = np.asarray(data, dtype=float)

    def __array__(self, dtype=None):
        # numpy 协议：np.array(series) 直接转 1-d 数组
        # （MyTT 的 LAST 用 np.array(pd.Series(...).rolling(...).apply(...))，
        #  不带 .values；pandas Series 支持 __array__，垫片对齐）
        return self._a if dtype is None else self._a.astype(dtype)

    def shift(self, n=1):
        a = self._a
        n = int(n)
        out = np.full(len(a), np.nan)
        if n >= 0:
            if 0 < n < len(a):
                out[n:] = a[:len(a) - n]
            elif n == 0:
                out = a.copy()
        else:
            m = -n
            if 0 < m < len(a):
                out[:len(a) - m] = a[m:]
        return _Series(out)

    def diff(self, n=1):
        a = self._a
        n = int(n)
        out = np.full(len(a), np.nan)
        if n == 0:
            out = a.copy()
        elif 0 < n < len(a):
            out[n:] = a[n:] - a[:-n]
        return _Series(out)

    def rolling(self, n):
        return _Rolling(self._a, int(n))

    def ewm(self, span=None, alpha=None, adjust=False):
        return _EWM(self._a, span, alpha)

    def cumsum(self):
        # pandas 语义：NaN 位输出 NaN 且跳过累加（非 np.cumsum 的传染 NaN）
        a = self._a
        out = np.full(len(a), np.nan)
        s = 0.0
        seen = False
        for i in range(len(a)):
            x = a[i]
            if np.isnan(x):
                continue
            s = s + x if seen else x
            seen = True
            out[i] = s
        return _Series(out)

    def ffill(self):
        a = self._a.copy()
        for i in range(1, len(a)):
            if np.isnan(a[i]):
                a[i] = a[i - 1]
        return _Series(a)

    @property
    def values(self):
        return self._a


class _Rolling:
    """pd.rolling(N) 垫片：min_periods 默认 = 窗口宽（窗口不完整或含 NaN → NaN）。

    sum/mean/std 为 pandas 2.2.3 Cython（_libs/window/aggregations.pyx）的
    Python 直译——固定窗口全程单状态增量（i=0 setup，增长期逐个 add，滑动期
    每步 remove a[i-N] + add a[i]），add/remove 各持独立 Kahan 补偿；
    NaN 不进 Kahan 状态（nobs 不变），nobs<N ⇒ 输出 NaN（等价窗口含 NaN）。
    目的：与 pandas 逐位一致（含 RD 四舍五入边界），且纯标量运算跨平台
    （macOS numpy / iOS 引擎 numpy）IEEE 确定性。max/min/apply 为比较或
    lambda 自算，无浮点结构问题，保持逐窗。
    """

    __slots__ = ("_a", "_n")

    def __init__(self, a, n):
        self._a = a
        self._n = n

    # ---- 事件驱动骨架：产出每个位置的 (removed, added) 增量事件 ----
    def _events(self):
        """固定窗口 rolling(N)：i=0 为 setup（add a[0]）；i<N 只 add a[i]；
        i>=N 每步 remove a[i-N] + add a[i]（pandas start/end 增量路径）。"""
        a = self._a
        n = self._n
        L = len(a)
        for i in range(L):
            if i == 0:
                yield i, (), (a[0],)
            elif i < n:
                yield i, (), (a[i],)
            else:
                yield i, (a[i - n],), (a[i],)

    # ---- roll_sum 直译 ----
    def sum(self):
        a = self._a
        n = self._n
        L = len(a)
        out = np.full(L, np.nan)
        if n <= 0 or L == 0:
            return _Series(out)
        nobs = 0
        sum_x = 0.0
        comp_add = 0.0
        comp_rm = 0.0
        num_consec = 0
        prev_value = a[0]
        for i, removed, added in self._events():
            for val in removed:
                if val == val:
                    nobs -= 1
                    y = -val - comp_rm
                    t = sum_x + y
                    comp_rm = t - sum_x - y
                    sum_x = t
            for val in added:
                if val == val:
                    nobs += 1
                    y = val - comp_add
                    t = sum_x + y
                    comp_add = t - sum_x - y
                    sum_x = t
                    if val == prev_value:
                        num_consec += 1
                    else:
                        num_consec = 1
                    prev_value = val
            # calc_sum（minp = n）
            if nobs == 0 == n:
                out[i] = 0.0
            elif nobs >= n:
                out[i] = prev_value * nobs if num_consec >= nobs else sum_x
        return _Series(out)

    # ---- roll_mean 直译 ----
    def mean(self):
        a = self._a
        n = self._n
        L = len(a)
        out = np.full(L, np.nan)
        if n <= 0 or L == 0:
            return _Series(out)
        nobs = 0
        neg_ct = 0
        sum_x = 0.0
        comp_add = 0.0
        comp_rm = 0.0
        num_consec = 0
        prev_value = a[0]
        for i, removed, added in self._events():
            for val in removed:
                if val == val:
                    nobs -= 1
                    y = -val - comp_rm
                    t = sum_x + y
                    comp_rm = t - sum_x - y
                    sum_x = t
                    if np.signbit(val):
                        neg_ct -= 1
            for val in added:
                if val == val:
                    nobs += 1
                    y = val - comp_add
                    t = sum_x + y
                    comp_add = t - sum_x - y
                    sum_x = t
                    if np.signbit(val):
                        neg_ct += 1
                    if val == prev_value:
                        num_consec += 1
                    else:
                        num_consec = 1
                    prev_value = val
            # calc_mean（minp = n）
            if nobs >= n and nobs > 0:
                result = sum_x / nobs
                if num_consec >= nobs:
                    result = prev_value
                elif neg_ct == 0 and result < 0:
                    result = 0.0
                elif neg_ct == nobs and result > 0:
                    result = 0.0
                out[i] = result
        return _Series(out)

    # ---- roll_var 直译（Welford + Kahan），std = sqrt ----
    def std(self, ddof=0):
        a = self._a
        n = self._n
        L = len(a)
        out = np.full(L, np.nan)
        if n <= 0 or L == 0:
            return _Series(out)
        nobs = 0
        mean_x = 0.0
        ssqdm_x = 0.0
        comp_add = 0.0
        comp_rm = 0.0
        num_consec = 0
        prev_value = a[0]
        for i, removed, added in self._events():
            for val in removed:
                if val != val:
                    continue
                nobs -= 1
                if nobs:
                    prev_mean = mean_x - comp_rm
                    y = val - comp_rm
                    t = y - mean_x
                    comp_rm = t + mean_x - y
                    delta = t
                    mean_x = mean_x - delta / nobs
                    ssqdm_x = ssqdm_x - (val - prev_mean) * (val - mean_x)
                else:
                    mean_x = 0.0
                    ssqdm_x = 0.0
            for val in added:
                if val != val:
                    continue
                nobs += 1
                if val == prev_value:
                    num_consec += 1
                else:
                    num_consec = 1
                prev_value = val
                prev_mean = mean_x - comp_add
                y = val - comp_add
                t = y - mean_x
                comp_add = t + mean_x - y
                delta = t
                mean_x = mean_x + delta / nobs
                ssqdm_x = ssqdm_x + (val - prev_mean) * (val - mean_x)
            # calc_var（minp = n）
            if nobs >= n and nobs > ddof:
                if nobs == 1 or num_consec >= nobs:
                    out[i] = 0.0
                else:
                    out[i] = np.sqrt(ssqdm_x / (nobs - ddof))
        return _Series(out)

    def _valid_idx(self):
        """有效窗口右端 i 的集合：i >= n-1 且窗口 [i-n+1, i] 内无 NaN。"""
        a = self._a
        n = self._n
        L = len(a)
        if L < n or n <= 0:
            return []
        c = np.concatenate(([0], np.cumsum(np.isnan(a))))  # NaN 前缀和
        idx = np.arange(n - 1, L)
        ok = (c[idx + 1] - c[idx + 1 - n]) == 0
        return idx[ok]

    def _map(self, fn):
        a = self._a
        out = np.full(len(a), np.nan)
        for i in self._valid_idx():
            out[i] = fn(a[i - self._n + 1:i + 1])
        return out

    def max(self):
        return _Series(self._map(np.max))

    def min(self):
        return _Series(self._map(np.min))

    def apply(self, fn, raw=False):
        # raw True/False 一律传 ndarray：MyTT 的 raw=False 用法（AVEDEV/LAST）
        # 只调用 ndarray 自带方法（x.mean() 等），无需真 Series
        return _Series(self._map(fn))


class _EWM:
    """pd.ewm(adjust=False) 垫片（pandas 2.2.3 实测行为，三段式）：
    - 连续有效位：纯递推 y = (1-α)·y + α·x（与 pandas 逐位同构）；
    - NaN 位：输出保持前值；
    - gap 个 NaN 后的恢复位：F 模型归一
      y = ((1-α)^(g+1)·y_prev + α·v) / ((1-α)^(g+1) + α)，
      随后回到纯递推（pandas 在恢复位后分母重置，不保持 num/den 双递推）。
    """

    __slots__ = ("_a", "_alpha")

    def __init__(self, a, span, alpha):
        if span is not None:
            self._alpha = 2.0 / (float(span) + 1.0)
        elif alpha is not None:
            self._alpha = float(alpha)
        else:
            raise ValueError("ewm 需要 span 或 alpha")
        self._a = a

    def mean(self):
        a = self._a
        al = self._alpha
        out = np.full(len(a), np.nan)
        prev = None   # 上一有效位输出
        gap = 0       # 上一有效位以来的连续 NaN 个数
        for i in range(len(a)):
            x = a[i]
            if np.isnan(x):
                if prev is not None:
                    out[i] = prev   # NaN 位输出保持前值
                    gap += 1
                continue
            if prev is None:
                prev = float(x)     # 首个有效值：y = x
            elif gap == 0:
                prev = (1.0 - al) * prev + al * x          # 连续有效：纯递推
            else:
                w = (1.0 - al) ** (gap + 1)                # 恢复位：F 模型归一
                prev = (w * prev + al * x) / (w + al)
            gap = 0
            out[i] = prev
        return _Series(out)


class _Pd:
    """pd 伪模块：MyTT 仅用到 pd.Series(...) 构造。"""
    Series = _Series


pd = _Pd()


#------------------ 以下函数源码逐行取自 MyTT V3.3（MIT，见模块 docstring） ----------
#------------------ 0级：核心工具函数 --------------------------------------------
def RD(N,D=3):   return np.round(N,D)        #四舍五入取3位小数
def RET(S,N=1):  return np.array(S)[-N]      #返回序列倒数第N个值,默认返回最后一个
def ABS(S):      return np.abs(S)            #返回N的绝对值
def LN(S):       return np.log(S)            #求底是e的自然对数,
def POW(S,N):    return np.power(S,N)        #求S的N次方
def SQRT(S):     return np.sqrt(S)           #求S的平方根
def SIN(S):      return np.sin(S)            #求S的正弦值（弧度)
def COS(S):      return np.cos(S)            #求S的余弦值（弧度)
def TAN(S):      return np.tan(S)            #求S的正切值（弧度)
def MAX(S1,S2):  return np.maximum(S1,S2)    #序列max
def MIN(S1,S2):  return np.minimum(S1,S2)    #序列min
def IF(S,A,B):   return np.where(S,A,B)      #序列布尔判断 return=A  if S==True  else  B


def REF(S, N=1):          #对序列整体下移动N,返回序列(shift后会产生NAN)
    return pd.Series(S).shift(N).values

def DIFF(S, N=1):         #前一个值减后一个值,前面会产生nan
    return pd.Series(S).diff(N).values     #np.diff(S)直接删除nan，会少一行

def STD(S,N):             #求序列的N日标准差，返回序列
    return  pd.Series(S).rolling(N).std(ddof=0).values

def SUM(S, N):            #对序列求N天累计和，返回序列    N=0对序列所有依次求和
    return pd.Series(S).rolling(N).sum().values if N>0 else pd.Series(S).cumsum().values

def CONST(S):             #返回序列S最后的值组成常量序列
    return np.full(len(S),S[-1])

def HHV(S,N):             #HHV(C, 5) 最近5天收盘最高价
    return pd.Series(S).rolling(N).max().values

def LLV(S,N):             #LLV(C, 5) 最近5天收盘最低价
    return pd.Series(S).rolling(N).min().values

def HHVBARS(S,N):         #求N周期内S最高值到当前周期数, 返回序列
    return pd.Series(S).rolling(N).apply(lambda x: np.argmax(x[::-1]),raw=True).values

def LLVBARS(S,N):         #求N周期内S最低值到当前周期数, 返回序列
    return pd.Series(S).rolling(N).apply(lambda x: np.argmin(x[::-1]),raw=True).values

def MA(S,N):              #求序列的N日简单移动平均值，返回序列
    return pd.Series(S).rolling(N).mean().values

def EMA(S,N):             #指数移动平均,为了精度 S>4*N  EMA至少需要120周期     alpha=2/(span+1)
    return pd.Series(S).ewm(span=N, adjust=False).mean().values

def SMA(S, N, M=1):       #中国式的SMA,至少需要120周期才精确 (雪球180周期)    alpha=1/(1+com)
    return pd.Series(S).ewm(alpha=M/N,adjust=False).mean().values           #com=N-M/M

def WMA(S, N):            #通达信S序列的N日加权移动平均 Yn = (1*X1+2*X2+3*X3+...+n*Xn)/(1+2+3+...+Xn)
    return pd.Series(S).rolling(N).apply(lambda x:x[::-1].cumsum().sum()*2/N/(N+1),raw=True).values

def DMA(S, A):            #求S的动态移动平均，A作平滑因子,必须 0<A<1  (此为核心函数，非指标）
    if isinstance(A,(int,float)):  return pd.Series(S).ewm(alpha=A,adjust=False).mean().values
    A=np.array(A);   A[np.isnan(A)]=1.0;   Y= np.zeros(len(S));   Y[0]=S[0]
    for i in range(1,len(S)): Y[i]=A[i]*S[i]+(1-A[i])*Y[i-1]      #A支持序列 by jqz1226
    return Y

def AVEDEV(S, N):         #平均绝对偏差  (序列与其平均值的绝对差的平均值)
    return pd.Series(S).rolling(N).apply(lambda x: (np.abs(x - x.mean())).mean()).values

def SLOPE(S, N):          #返S序列N周期回线性回归斜率
    return pd.Series(S).rolling(N).apply(lambda x: np.polyfit(range(N),x,deg=1)[0],raw=True).values

def FORCAST(S, N):        #返回S序列N周期回线性回归后的预测值， jqz1226改进成序列出
    return pd.Series(S).rolling(N).apply(lambda x:np.polyval(np.polyfit(range(N),x,deg=1),N-1),raw=True).values

def LAST(S, A, B):        #从前A日到前B日一直满足S_BOOL条件, 要求A>B & A>0 & B>=0
    return np.array(pd.Series(S).rolling(A+1).apply(lambda x:np.all(x[::-1][B:]),raw=True),dtype=bool)


#------------------   1级：应用层函数(通过0级核心函数实现）使用方法请参考通达信--------------------------------
def COUNT(S, N):                       # COUNT(CLOSE>O, N):  最近N天满足S_BOO的天数  True的天数
    return SUM(S,N)

def EVERY(S, N):                       # EVERY(CLOSE>O, 5)   最近N天是否都是True
    return  IF(SUM(S,N)==N,True,False)

def EXIST(S, N):                       # EXIST(CLOSE>3010, N=5)  n日内是否存在一天大于3000点
    return IF(SUM(S,N)>0,True,False)

def FILTER(S, N):                      # FILTER函数，S满足条件后，将其后N周期内的数据置为0, FILTER(C==H,5)
    for i in range(len(S)): S[i+1:i+1+N]=0  if S[i] else S[i+1:i+1+N]
    return S                           # 例：FILTER(C==H,5) 涨停后，后5天不再发出信号
                                      # 注意：op 层对入参传副本，防原位改写污染 series/前序结果
def BARSLAST(S):                       #上一次条件成立到当前的周期, BARSLAST(C/REF(C,1)>=1.1) 上一次涨停到今天的天数
    M=np.concatenate(([0],np.where(S,1,0)))
    for i in range(1, len(M)):  M[i]=0 if M[i] else M[i-1]+1
    return M[1:]

def BARSLASTCOUNT(S):                  # 统计连续满足S条件的周期数        by jqz1226
    rt = np.zeros(len(S)+1)            # BARSLASTCOUNT(CLOSE>OPEN)表示统计连续收阳的周期数
    for i in range(len(S)): rt[i+1]=rt[i]+1  if S[i] else rt[i+1]
    return rt[1:]

def BARSSINCEN(S, N):                  # N周期内第一次S条件成立到现在的周期数,N为常量  by jqz1226 ,  peakgao
    return pd.Series(S).rolling(N).apply(lambda x:N-1-np.argmax(x) if np.argmax(x) or x[0] else float('nan'),raw=True).values

def CROSS(S1, S2):                     # 判断向上金叉穿越 CROSS(MA(C,5),MA(C,10))  判断向下死叉 CROSS(MA(C,10),MA(C,5))
    return np.concatenate(([False], np.logical_not((S1>S2)[:-1]) & (S1>S2)[1:]))    # 不使用0级函数,移植方便  by jqz1226

def LONGCROSS(S1,S2,N):                # 两条线维持一定周期后交叉,S1在N周期内都小于S2,本周期从S1下方向上穿过S2时返回1,否则返回0
    return  np.array(np.logical_and(LAST(S1<S2,N,1),(S1>S2)),dtype=bool)            # N=1时等同于CROSS(S1, S2)

def VALUEWHEN(S, X):                   # 当S条件成立时,取X的当前值,否则取VALUEWHEN的上个成立时的X值   by jqz1226
    return pd.Series(np.where(S,X,np.nan)).ffill().values

def BETWEEN(S, A, B):                  # S处于A和B之间时为真。 包括 A<S<B 或 A>S>B
    return ((A<S) & (S<B)) | ((A>S) & (S>B))

def TOPRANGE(S):                       # TOPRANGE(HIGH)表示当前最高价是近多少周期内最高价的最大值 by jqz1226
    rt = np.zeros(len(S))
    for i in range(1,len(S)):  rt[i] = np.argmin(np.flipud(S[:i]<S[i]))
    return rt.astype('int')

def LOWRANGE(S):                       # LOWRANGE(LOW)表示当前最低价是近多少周期内最低价的最小值 by jqz1226
    rt = np.zeros(len(S))
    for i in range(1,len(S)):  rt[i] = np.argmin(np.flipud(S[:i]>S[i]))
    return rt.astype('int')


#------------------   2级：技术指标函数(全部通过0级，1级函数实现） ------------------------------
def MACD(CLOSE,SHORT=12,LONG=26,M=9):             # EMA的关系，S取120日，和雪球小数点2位相同
    DIF = EMA(CLOSE,SHORT)-EMA(CLOSE,LONG);
    DEA = EMA(DIF,M);      MACD=(DIF-DEA)*2
    return RD(DIF),RD(DEA),RD(MACD)

def KDJ(CLOSE,HIGH,LOW, N=9,M1=3,M2=3):           # KDJ指标
    RSV = (CLOSE - LLV(LOW, N)) / (HHV(HIGH, N) - LLV(LOW, N)) * 100
    K = EMA(RSV, (M1*2-1));    D = EMA(K,(M2*2-1));        J=K*3-D*2
    return K, D, J

def RSI(CLOSE, N=24):                           # RSI指标,和通达信小数点2位相同
    DIF = CLOSE-REF(CLOSE,1)
    return RD(SMA(MAX(DIF,0), N) / SMA(ABS(DIF), N) * 100)

def WR(CLOSE, HIGH, LOW, N=10, N1=6):            #W&R 威廉指标
    WR = (HHV(HIGH, N) - CLOSE) / (HHV(HIGH, N) - LLV(LOW, N)) * 100
    WR1 = (HHV(HIGH, N1) - CLOSE) / (HHV(HIGH, N1) - LLV(LOW, N1)) * 100
    return RD(WR), RD(WR1)

def BIAS(CLOSE,L1=6, L2=12, L3=24):              # BIAS乖离率
    BIAS1 = (CLOSE - MA(CLOSE, L1)) / MA(CLOSE, L1) * 100
    BIAS2 = (CLOSE - MA(CLOSE, L2)) / MA(CLOSE, L2) * 100
    BIAS3 = (CLOSE - MA(CLOSE, L3)) / MA(CLOSE, L3) * 100
    return RD(BIAS1), RD(BIAS2), RD(BIAS3)

def BOLL(CLOSE,N=20, P=2):                       #BOLL指标，布林带
    MID = MA(CLOSE, N);
    UPPER = MID + STD(CLOSE, N) * P
    LOWER = MID - STD(CLOSE, N) * P
    return RD(UPPER), RD(MID), RD(LOWER)

def PSY(CLOSE,N=12, M=6):
    PSY=COUNT(CLOSE>REF(CLOSE,1),N)/N*100
    PSYMA=MA(PSY,M)
    return RD(PSY),RD(PSYMA)

def CCI(CLOSE,HIGH,LOW,N=14):
    TP=(HIGH+LOW+CLOSE)/3
    return (TP-MA(TP,N))/(0.015*AVEDEV(TP,N))

def ATR(CLOSE,HIGH,LOW, N=20):                    #真实波动N日平均值
    TR = MAX(MAX((HIGH - LOW), ABS(REF(CLOSE, 1) - HIGH)), ABS(REF(CLOSE, 1) - LOW))
    return MA(TR, N)

def BBI(CLOSE,M1=3,M2=6,M3=12,M4=20):             #BBI多空指标
    return (MA(CLOSE,M1)+MA(CLOSE,M2)+MA(CLOSE,M3)+MA(CLOSE,M4))/4

def DMI(CLOSE,HIGH,LOW,M1=14,M2=6):               #动向指标：结果和同花顺，通达信完全一致
    TR = SUM(MAX(MAX(HIGH - LOW, ABS(HIGH - REF(CLOSE, 1))), ABS(LOW - REF(CLOSE, 1))), M1)
    HD = HIGH - REF(HIGH, 1);     LD = REF(LOW, 1) - LOW
    DMP = SUM(IF((HD > 0) & (HD > LD), HD, 0), M1)
    DMM = SUM(IF((LD > 0) & (LD > HD), LD, 0), M1)
    PDI = DMP * 100 / TR;         MDI = DMM * 100 / TR
    ADX = MA(ABS(MDI - PDI) / (PDI + MDI) * 100, M2)
    ADXR = (ADX + REF(ADX, M2)) / 2
    return PDI, MDI, ADX, ADXR

def TAQ(HIGH,LOW,N):                               #唐安奇通道(海龟)交易指标，大道至简，能穿越牛熊
    UP=HHV(HIGH,N);    DOWN=LLV(LOW,N);    MID=(UP+DOWN)/2
    return UP,MID,DOWN

def KTN(CLOSE,HIGH,LOW,N=20,M=10):                 #肯特纳交易通道, N选20日，ATR选10日
    MID=EMA((HIGH+LOW+CLOSE)/3,N)
    ATRN=ATR(CLOSE,HIGH,LOW,M)
    UPPER=MID+2*ATRN;   LOWER=MID-2*ATRN
    return UPPER,MID,LOWER

def TRIX(CLOSE,M1=12, M2=20):                      #三重指数平滑平均线
    TR = EMA(EMA(EMA(CLOSE, M1), M1), M1)
    TRIX = (TR - REF(TR, 1)) / REF(TR, 1) * 100
    TRMA = MA(TRIX, M2)
    return TRIX, TRMA

def VR(CLOSE,VOL,M1=26):                            #VR容量比率
    LC = REF(CLOSE, 1)
    return SUM(IF(CLOSE > LC, VOL, 0), M1) / SUM(IF(CLOSE <= LC, VOL, 0), M1) * 100

def CR(CLOSE,HIGH,LOW,N=20):                        #CR价格动量指标
    MID=REF(HIGH+LOW+CLOSE,1)/3;
    return SUM(MAX(0,HIGH-MID),N)/SUM(MAX(0,MID-LOW),N)*100

def EMV(HIGH,LOW,VOL,N=14,M=9):                     #简易波动指标
    VOLUME=MA(VOL,N)/VOL;       MID=100*(HIGH+LOW-REF(HIGH+LOW,1))/(HIGH+LOW)
    EMV=MA(MID*VOLUME*(HIGH-LOW)/MA(HIGH-LOW,N),N);    MAEMV=MA(EMV,M)
    return EMV,MAEMV


def DPO(CLOSE,M1=20, M2=10, M3=6):                  #区间震荡线
    DPO = CLOSE - REF(MA(CLOSE, M1), M2);    MADPO = MA(DPO, M3)
    return DPO, MADPO

def BRAR(OPEN,CLOSE,HIGH,LOW,M1=26):                 #BRAR-ARBR 情绪指标
    AR = SUM(HIGH - OPEN, M1) / SUM(OPEN - LOW, M1) * 100
    BR = SUM(MAX(0, HIGH - REF(CLOSE, 1)), M1) / SUM(MAX(0, REF(CLOSE, 1) - LOW), M1) * 100
    return AR, BR

def DFMA(CLOSE,N1=10,N2=50,M=10):                    #平行线差指标
    DIF=MA(CLOSE,N1)-MA(CLOSE,N2); DIFMA=MA(DIF,M)   #通达信指标叫DMA 同花顺叫新DMA
    return DIF,DIFMA

def MTM(CLOSE,N=12,M=6):                             #动量指标
    MTM=CLOSE-REF(CLOSE,N);         MTMMA=MA(MTM,M)
    return MTM,MTMMA

def MASS(HIGH,LOW,N1=9,N2=25,M=6):                   #梅斯线
    MASS=SUM(MA(HIGH-LOW,N1)/MA(MA(HIGH-LOW,N1),N1),N2)
    MA_MASS=MA(MASS,M)
    return MASS,MA_MASS

def ROC(CLOSE,N=12,M=6):                             #变动率指标
    ROC=100*(CLOSE-REF(CLOSE,N))/REF(CLOSE,N);    MAROC=MA(ROC,M)
    return ROC,MAROC

def EXPMA(CLOSE,N1=12,N2=50):                        #EMA指数平均数指标
    return EMA(CLOSE,N1),EMA(CLOSE,N2);

def OBV(CLOSE,VOL):                                  #能量潮指标
    return SUM(IF(CLOSE>REF(CLOSE,1),VOL,IF(CLOSE<REF(CLOSE,1),-VOL,0)),0)/10000

def MFI(CLOSE,HIGH,LOW,VOL,N=14):                    #MFI指标是成交量的RSI指标
    TYP = (HIGH + LOW + CLOSE)/3
    V1=SUM(IF(TYP>REF(TYP,1),TYP*VOL,0),N)/SUM(IF(TYP<REF(TYP,1),TYP*VOL,0),N)
    return 100-(100/(1+V1))

def ASI(OPEN,CLOSE,HIGH,LOW,M1=26,M2=10):            #振动升降指标
    LC=REF(CLOSE,1);      AA=ABS(HIGH-LC);     BB=ABS(LOW-LC);
    CC=ABS(HIGH-REF(LOW,1));   DD=ABS(LC-REF(OPEN,1));
    R=IF( (AA>BB) & (AA>CC),AA+BB/2+DD/4,IF( (BB>CC) & (BB>AA),BB+AA/2+DD/4,CC+DD/4));
    X=(CLOSE-LC+(CLOSE-OPEN)/2+LC-REF(OPEN,1));
    SI=16*X/R*MAX(AA,BB);   ASI=SUM(SI,M1);   ASIT=MA(ASI,M2);
    return ASI,ASIT

def XSII(CLOSE, HIGH, LOW, N=102, M=7):              #薛斯通道II
    AA  = MA((2*CLOSE + HIGH + LOW)/4, 5)            #最新版DMA才支持 2021-12-4
    TD1 = AA*N/100;   TD2 = AA*(200-N) / 100
    CC =  ABS((2*CLOSE + HIGH + LOW)/4 - MA(CLOSE,20))/MA(CLOSE,20)
    DD =  DMA(CLOSE,CC);    TD3=(1+M/100)*DD;      TD4=(1-M/100)*DD
    return TD1, TD2, TD3, TD4


#------------------ op 分发（对齐 PyScripts 既有脚本模式） --------------------------

_FN_NAMES = (
    # 0 级
    "RD", "RET", "ABS", "LN", "POW", "SQRT", "SIN", "COS", "TAN",
    "MAX", "MIN", "IF", "REF", "DIFF", "STD", "SUM", "CONST",
    "HHV", "LLV", "HHVBARS", "LLVBARS", "MA", "EMA", "SMA", "WMA",
    "DMA", "AVEDEV", "SLOPE", "FORCAST", "LAST",
    # 1 级
    "COUNT", "EVERY", "EXIST", "FILTER", "BARSLAST", "BARSLASTCOUNT",
    "BARSSINCEN", "CROSS", "LONGCROSS", "VALUEWHEN", "BETWEEN",
    "TOPRANGE", "LOWRANGE",
    # 2 级
    "MACD", "KDJ", "RSI", "WR", "BIAS", "BOLL", "PSY", "CCI", "ATR",
    "BBI", "DMI", "TAQ", "KTN", "TRIX", "VR", "CR", "EMV", "DPO",
    "BRAR", "DFMA", "MTM", "MASS", "ROC", "EXPMA", "OBV", "MFI",
    "ASI", "XSII",
)
_FN_TABLE = {name: globals()[name] for name in _FN_NAMES}


def _err(msg):
    return {"ok": False, "error": msg}


def _as_num(v):
    """数值校验：接受 int/float（拒绝 bool）；None 视为 NaN（series 的 null 位）。"""
    if v is None:
        return float("nan")
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


def _scalar_json(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, np.bool_):
        return bool(v)
    if isinstance(v, (float, np.floating)):
        f = float(v)
        if f != f or f == float("inf") or f == float("-inf"):
            return None
        return f
    if isinstance(v, (int, np.integer)):
        return int(v)
    return None


def _out_json(o):
    if isinstance(o, np.ndarray):
        return [_scalar_json(x) for x in o.tolist()]
    return _scalar_json(o)


def _resolve_arg(ra, arrays, env, k, j):
    """args 元素解析：'$id'/'$id#k' 前序引用 | 序列名 | 数字标量。一律传副本。"""
    if isinstance(ra, str):
        if ra.startswith("$"):
            key = ra[1:]
            base, _, idx = key.partition("#")
            v = env.get(base)
            if v is None:
                return _err("functions: calls[%d].args[%d] 引用未定义的前序结果 %r" % (k, j, ra))
            if isinstance(v, tuple):
                if idx == "":
                    return _err("functions: calls[%d].args[%d] %r 是多输出结果，需用 '$%s#k' 指定第 k 列"
                                % (k, j, ra, base))
                try:
                    return np.array(v[int(idx)], copy=True)
                except (ValueError, IndexError):
                    return _err("functions: calls[%d].args[%d] %r 引用列号非法" % (k, j, ra))
            if idx != "":
                return _err("functions: calls[%d].args[%d] %r 是单输出结果，不支持 '#k' 后缀" % (k, j, ra))
            return np.array(v, copy=True) if isinstance(v, np.ndarray) else v
        if ra in arrays:
            return np.array(arrays[ra], copy=True)  # 副本：FILTER 原位改写防污染
        return _err("functions: calls[%d].args[%d] 未知的序列名 %r（series 键：%s）"
                    % (k, j, ra, " / ".join(sorted(arrays))))
    n = _as_num(ra)
    if n is None:
        return _err("functions: calls[%d].args[%d] 非法参数 %r（仅支持序列名 / $前序引用 / 数字）"
                    % (k, j, ra))
    return n


def _op_functions(inp):
    series = inp.get("series")
    if not isinstance(series, dict) or not series:
        return _err("functions: series 必须为非空对象")
    arrays = {}
    length = None
    for name, raw in series.items():
        if not isinstance(name, str) or not name:
            return _err("functions: series 键必须为非空字符串: %r" % (name,))
        if not isinstance(raw, list) or not raw:
            return _err("functions: series[%r] 必须为非空数组" % name)
        vals = []
        for v in raw:
            n = _as_num(v)
            if n is None:
                return _err("functions: series[%r] 含非法数值 %r（null 视为 NaN，拒绝 bool）" % (name, v))
            vals.append(float(n))
        a = np.array(vals, dtype=float)
        if length is None:
            length = len(a)
        elif len(a) != length:
            return _err("functions: series 各序列必须等长（%r 长度 %d ≠ %d）" % (name, len(a), length))
        arrays[name] = a

    calls = inp.get("calls")
    if not isinstance(calls, list) or not calls:
        return _err("functions: calls 必须为非空数组")
    env = {}
    results = []
    for k, call in enumerate(calls):
        if not isinstance(call, dict):
            return _err("functions: calls[%d] 必须为对象" % k)
        fn = call.get("fn")
        if not isinstance(fn, str) or fn not in _FN_TABLE:
            return _err("functions: calls[%d] 未知函数 %r（支持 %d 个）" % (k, fn, len(_FN_TABLE)))
        raw_args = call.get("args", [])
        if not isinstance(raw_args, list):
            return _err("functions: calls[%d].args 必须为数组" % k)
        args = []
        for j, ra in enumerate(raw_args):
            v = _resolve_arg(ra, arrays, env, k, j)
            if isinstance(v, dict):
                return v
            args.append(v)
        try:
            out = _FN_TABLE[fn](*args)
        except Exception as e:
            return _err("functions: calls[%d] %s 执行失败: %s: %s" % (k, fn, type(e).__name__, e))
        outs = out if isinstance(out, tuple) else (out,)
        results.append({"fn": fn, "outputs": [_out_json(o) for o in outs]})
        cid = call.get("id")
        if cid is not None:
            if not isinstance(cid, str) or not cid:
                return _err("functions: calls[%d].id 必须为非空字符串" % k)
            env[cid] = out  # 原始值：单输出为 ndarray/标量，多输出为 tuple
    return {"ok": True, "result": {"results": results}}


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    op = inp.get("op")
    if op == "functions":
        return _op_functions(inp)
    return _err("未知 op: %r（仅支持 functions）" % (op,))


kline_result = _main()
