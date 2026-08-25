//
//  IndicatorSystem.swift
//  Kline
//
//  系统指标扩展：副图指标分组/参数规格、公式式系统指标模板、原生指标计算函数。
//
//  Created by 孙楚昆 on 2026/8/18.
//

import Foundation

// MARK: - 参数规格

/// 单个整数参数规格（用于全屏参数编辑页与默认值初始化）
struct SubParamSpec: Identifiable, Equatable {
    let key: String
    let label: String
    let range: ClosedRange<Int>
    let defaultValue: Int
    var id: String { key }
}

// MARK: - 副图指标分组与参数

extension SubChartKind {
    var group: String {
        switch self {
        case .vol, .amo, .vmacd, .vr, .vrsi, .obv, .col: return "量能"
        case .macd, .wmacd, .dmi, .trix: return "趋向"
        case .kdj, .rsi, .cci, .kd, .lwr, .marsi, .brar, .cr, .mass, .cdj: return "超买超卖"
        }
    }

    /// 是否为公式式系统指标（CDJ / COL）
    var isFormulaBased: Bool { self == .cdj || self == .col }

    /// 副图指标的分组展示顺序（用于选择页分组排序）
    static let groupOrder: [String] = ["量能", "趋向", "超买超卖"]

    var paramSpecs: [SubParamSpec] {
        switch self {
        case .vol, .amo: return []
        case .macd, .wmacd:
            return [.init(key: "fast", label: "快", range: 1...300, defaultValue: 12),
                    .init(key: "slow", label: "慢", range: 1...300, defaultValue: 26),
                    .init(key: "signal", label: "信号", range: 1...300, defaultValue: 9)]
        case .kdj:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 9),
                    .init(key: "k", label: "K", range: 1...100, defaultValue: 3),
                    .init(key: "d", label: "D", range: 1...100, defaultValue: 3)]
        case .rsi:
            return [.init(key: "p1", label: "P1", range: 1...300, defaultValue: 6),
                    .init(key: "p2", label: "P2", range: 1...300, defaultValue: 12),
                    .init(key: "p3", label: "P3", range: 1...300, defaultValue: 24)]
        case .cci:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 14)]
        case .kd:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 9),
                    .init(key: "m1", label: "M1", range: 1...100, defaultValue: 3),
                    .init(key: "m2", label: "M2", range: 1...100, defaultValue: 3)]
        case .lwr:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 9),
                    .init(key: "m1", label: "M1", range: 1...100, defaultValue: 3)]
        case .marsi:
            return [.init(key: "n1", label: "N1", range: 1...300, defaultValue: 6),
                    .init(key: "n2", label: "N2", range: 1...300, defaultValue: 12)]
        case .dmi:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 14),
                    .init(key: "m", label: "M", range: 1...100, defaultValue: 6)]
        case .trix:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 12),
                    .init(key: "m", label: "M", range: 1...100, defaultValue: 9)]
        case .vmacd:
            return [.init(key: "short", label: "快", range: 1...300, defaultValue: 12),
                    .init(key: "long", label: "慢", range: 1...300, defaultValue: 26),
                    .init(key: "m", label: "M", range: 1...100, defaultValue: 9)]
        case .brar:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 26)]
        case .cr:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 26),
                    .init(key: "m1", label: "M1", range: 1...100, defaultValue: 5),
                    .init(key: "m2", label: "M2", range: 1...100, defaultValue: 10),
                    .init(key: "m3", label: "M3", range: 1...100, defaultValue: 20)]
        case .mass:
            return [.init(key: "n", label: "N", range: 1...100, defaultValue: 9),
                    .init(key: "n1", label: "N1", range: 1...300, defaultValue: 25),
                    .init(key: "m", label: "M", range: 1...100, defaultValue: 6)]
        case .vr:
            return [.init(key: "n", label: "N", range: 1...300, defaultValue: 26),
                    .init(key: "m", label: "M", range: 1...100, defaultValue: 6)]
        case .vrsi:
            return [.init(key: "n1", label: "N1", range: 1...300, defaultValue: 6),
                    .init(key: "n2", label: "N2", range: 1...300, defaultValue: 12),
                    .init(key: "n3", label: "N3", range: 1...300, defaultValue: 24)]
        case .obv:
            return [.init(key: "m", label: "M", range: 1...300, defaultValue: 30)]
        case .cdj, .col:
            return [.init(key: "n", label: "N", range: 1...100, defaultValue: 3),
                    .init(key: "m", label: "M", range: 1...100, defaultValue: 3)]
        }
    }

    var defaultParams: [String: Int] {
        var d: [String: Int] = [:]
        for s in paramSpecs { d[s.key] = s.defaultValue }
        return d
    }

    /// 公式式系统指标（CDJ / COL）：按参数生成完整公式
    func formula(with params: [String: Int]) -> String? {
        let n = params["n"] ?? 3
        let m = params["m"] ?? 3
        switch self {
        case .cdj:
            return """
            N:=\(n);M:=\(m);
            RSV:=(HHV(H,N)-C)/(HHV(H,N)-LLV(L,N))*100;
            VALUE:=SMA(RSV,M,1);
            K:SMA(VALUE,M,1);
            D:SMA(K,M,1);
            J:3*K-2*D;
            NOTEXT_Q:15,DOTLINE;
            NOTEXT_W:85,DOTLINE;
            NOTEXT_E:35,DOTLINE;
            NOTEXT_R:65,DOTLINE;
            """
        case .col:
            return """
            N:=\(n);M:=\(m);
            RSV:=(HHV(VOL,N)-VOL)/(HHV(VOL,N)-LLV(VOL,N))*100;
            VALUE:=SMA(RSV,M,1);
            K:SMA(VALUE,M,1);
            D:SMA(K,M,1);
            J:3*K-2*D;
            NOTEXT_Q:-5,DOTLINE;
            NOTEXT_W:105,DOTLINE;
            NOTEXT_E:35,DOTLINE;
            NOTEXT_R:65,DOTLINE;
            """
        default:
            return nil
        }
    }
}

// MARK: - 主图系统指标（CMK 公式模板）

enum SystemFormulas {
    /// CMK 主图指标（麦克支撑压力平滑版，仅 N 参数可调）：仅保留 6 根虚线，不含 MA 均线
    static func cmk(n: Int) -> String {
        """
        N:=\(n);
        HLC:=REF(MA((HIGH+LOW+CLOSE)/3,N),1);
        HV:=EMA(HHV(HIGH,N),3);
        LV:=EMA(LLV(LOW,N),3);
        NOTEXT_STOR:EMA(2*HV-LV,3),COLORGRAY,DOTLINE;
        NOTEXT_MIDR:EMA(HLC+HV-LV,3),COLORGRAY,DOTLINE;
        NOTEXT_WEKR:EMA(HLC*2-LV,3),COLORGRAY,DOTLINE;
        NOTEXT_WEKS:EMA(HLC*2-HV,3),COLORGRAY,DOTLINE;
        NOTEXT_MIDS:EMA(HLC-HV+LV,3),COLORGRAY,DOTLINE;
        NOTEXT_STOS:EMA(2*LV-HV,3),COLORGRAY,DOTLINE;
        """
    }
}

// MARK: - 原生指标计算函数

extension ChartSeries {
    // MARK: 基础算子

    /// SMA(X, N, M) = (M*X + (N-M)*PREV) / N
    static func sma(_ values: [Double], period: Int, m: Double) -> [Double] {
        var result = Array(repeating: Double.nan, count: values.count)
        guard period > 0 else { return result }
        var prev: Double?
        for (i, v) in values.enumerated() {
            if let p = prev {
                let cur = (m * v + (Double(period) - m) * p) / Double(period)
                result[i] = cur
                prev = cur
            } else if !v.isNaN {
                result[i] = v
                prev = v
            }
        }
        return result
    }

    private static func rollingSum(_ arr: [Double], period: Int) -> [Double] {
        var result = Array(repeating: 0.0, count: arr.count)
        guard period > 0 else { return result }
        var sum = 0.0
        for i in 0..<arr.count {
            sum += arr[i]
            if i >= period { sum -= arr[i - period] }
            result[i] = sum
        }
        return result
    }

    // MARK: CCI（顺势指标）

    static func cci(highs: [Double], lows: [Double], closes: [Double], n: Int) -> [Double] {
        let count = closes.count
        var typ = Array(repeating: 0.0, count: count)
        for i in 0..<count { typ[i] = (highs[i] + lows[i] + closes[i]) / 3 }
        let maTyp = ma(values: typ, period: n)
        var result = Array(repeating: Double.nan, count: count)
        guard n > 0, count >= n else { return result }
        for i in (n - 1)..<count {
            let start = i - n + 1
            let mean = maTyp[i]
            var dev = 0.0
            for j in start...i { dev += abs(typ[j] - mean) }
            let avedev = dev / Double(n)
            let denom = 0.015 * avedev
            result[i] = denom == 0 ? 0 : (typ[i] - mean) / denom
        }
        return result
    }

    // MARK: KD（随机指标，无 J）

    static func kd(highs: [Double], lows: [Double], closes: [Double], n: Int, m1: Int, m2: Int) -> (k: [Double], d: [Double]) {
        let count = closes.count
        var rsv = Array(repeating: Double.nan, count: count)
        for i in 0..<count {
            let start = max(0, i - n + 1)
            let hh = highs[start...i].max() ?? 0
            let ll = lows[start...i].min() ?? 0
            rsv[i] = (hh - ll) == 0 ? 50 : (closes[i] - ll) / (hh - ll) * 100
        }
        let kArr = sma(rsv, period: m1, m: 1)
        let dArr = sma(kArr, period: m2, m: 1)
        return (kArr, dArr)
    }

    // MARK: LWR（威廉指标，两条线）

    static func lwr(highs: [Double], lows: [Double], closes: [Double], n: Int, m1: Int, m2: Int) -> (l1: [Double], l2: [Double]) {
        let count = closes.count
        var l1 = Array(repeating: Double.nan, count: count)
        for i in 0..<count {
            let start = max(0, i - n + 1)
            let hh = highs[start...i].max() ?? 0
            let ll = lows[start...i].min() ?? 0
            l1[i] = (hh - ll) == 0 ? 0 : (hh - closes[i]) / (hh - ll) * 100
        }
        let l2 = sma(l1, period: m1, m: 1)
        return (l1, l2)
    }

    // MARK: MARSI（慢 RSI，相对强弱平均线）

    static func marsi(closes: [Double], n1: Int, n2: Int) -> (r1: [Double], r2: [Double]) {
        let count = closes.count
        var dif = Array(repeating: 0.0, count: count)
        for i in 1..<count { dif[i] = closes[i] - closes[i - 1] }
        let vu = dif.map { max($0, 0) }
        let vd = dif.map { max(-$0, 0) }
        func line(_ n: Int) -> [Double] {
            let mau = sma(vu, period: n, m: 1)
            let mad = sma(vd, period: n, m: 1)
            let r = zip(mau, mad).map { $0 + $1 == 0 ? 100 : 100 * $0 / ($0 + $1) }
            return ma(values: r, period: n)
        }
        return (line(n1), line(n2))
    }

    // MARK: DMI（趋向指标）

    static func dmi(highs: [Double], lows: [Double], closes: [Double], n: Int, m: Int) -> (pdi: [Double], mdi: [Double], adx: [Double], adxr: [Double]) {
        let count = closes.count
        var tr = Array(repeating: 0.0, count: count)
        var up = Array(repeating: 0.0, count: count)
        var dn = Array(repeating: 0.0, count: count)
        for i in 1..<count {
            tr[i] = max(highs[i] - lows[i], max(abs(highs[i] - closes[i - 1]), abs(lows[i] - closes[i - 1])))
            let hd = highs[i] - highs[i - 1]
            let ld = lows[i - 1] - lows[i]
            if hd > 0 && hd > ld { up[i] = hd }
            if ld > 0 && ld > hd { dn[i] = ld }
        }
        // 预计算一次滚动和，避免循环内对每个 i 重复调用 rollingSum 造成 O(n²)
        let sumTR = rollingSum(tr, period: n)
        let sumUp = rollingSum(up, period: n)
        let sumDn = rollingSum(dn, period: n)
        var pdi = Array(repeating: Double.nan, count: count)
        var mdi = Array(repeating: Double.nan, count: count)
        var dx = Array(repeating: Double.nan, count: count)
        for i in 1..<count {
            let st = sumTR[i]
            if st > 0 {
                pdi[i] = sumUp[i] / st * 100
                mdi[i] = sumDn[i] / st * 100
                let s = pdi[i] + mdi[i]
                dx[i] = s == 0 ? 0 : abs(pdi[i] - mdi[i]) / s * 100
            }
        }
        let adx = ma(values: dx, period: m)
        var adxr = Array(repeating: Double.nan, count: count)
        for i in 0..<count where i - m >= 0 {
            if !adx[i].isNaN, !adx[i - m].isNaN { adxr[i] = (adx[i] + adx[i - m]) / 2 }
        }
        return (pdi, mdi, adx, adxr)
    }

    // MARK: TRIX（三重指数平滑平均线）

    static func trix(closes: [Double], n: Int, m: Int) -> (trix: [Double], ma: [Double]) {
        let tr = ma(values: ma(values: ma(values: closes, period: n), period: n), period: n)
        var t = Array(repeating: Double.nan, count: closes.count)
        for i in 1..<closes.count where !tr[i - 1].isNaN && tr[i - 1] != 0 {
            t[i] = (tr[i] - tr[i - 1]) / tr[i - 1] * 100
        }
        return (t, ma(values: t, period: m))
    }

    // MARK: VMACD（量异同移动平均）

    static func vmacd(volumes: [Double], short: Int, long: Int, m: Int) -> (diff: [Double], dea: [Double], hist: [Double]) {
        let diff = zip(ema(values: volumes, period: short), ema(values: volumes, period: long)).map { $0 - $1 }
        let dea = ema(values: diff, period: m)
        return (diff, dea, zip(diff, dea).map { 2 * ($0 - $1) })
    }

    // MARK: BRAR（情绪指标）

    static func brar(highs: [Double], lows: [Double], opens: [Double], closes: [Double], n: Int) -> (br: [Double], ar: [Double]) {
        let count = closes.count
        var br = Array(repeating: Double.nan, count: count)
        var ar = Array(repeating: Double.nan, count: count)
        for i in 0..<count {
            let start = max(1, i - n + 1)
            var sumUp = 0.0, sumDn = 0.0, sumHo = 0.0, sumOl = 0.0
            if start <= i {
                for j in start...i {
                    sumUp += max(highs[j] - closes[j - 1], 0)
                    sumDn += max(closes[j - 1] - lows[j], 0)
                    sumHo += highs[j] - opens[j]
                    sumOl += opens[j] - lows[j]
                }
            }
            br[i] = sumDn == 0 ? 0 : sumUp / sumDn * 100
            ar[i] = sumOl == 0 ? 0 : sumHo / sumOl * 100
        }
        return (br, ar)
    }

    // MARK: CR（带状能量线）

    static func cr(highs: [Double], lows: [Double], closes: [Double], n: Int, m1: Int, m2: Int, m3: Int) -> (cr: [Double], ma1: [Double], ma2: [Double], ma3: [Double]) {
        let count = closes.count
        var mid = Array(repeating: 0.0, count: count)
        for i in 0..<count { mid[i] = (highs[i] + lows[i] + closes[i]) / 3 }
        var c = Array(repeating: Double.nan, count: count)
        for i in 1..<count {
            let start = max(1, i - n + 1)
            var sumUp = 0.0, sumDn = 0.0
            for j in start...i {
                sumUp += max(highs[j] - mid[j - 1], 0)
                sumDn += max(mid[j - 1] - lows[j], 0)
            }
            c[i] = sumDn == 0 ? 0 : sumUp / sumDn * 100
        }
        return (c, ma(values: c, period: m1), ma(values: c, period: m2), ma(values: c, period: m3))
    }

    // MARK: MASS（梅斯线）

    static func mass(highs: [Double], lows: [Double], n: Int, n1: Int, m: Int) -> (mass: [Double], ma: [Double]) {
        let count = highs.count
        let diff = zip(highs, lows).map { $0 - $1 }
        let e1 = ema(values: diff, period: n)
        let e2 = ema(values: e1, period: n)
        var ratio = Array(repeating: 0.0, count: count)
        for i in 0..<count { ratio[i] = e2[i] == 0 ? 0 : e1[i] / e2[i] }
        var result = Array(repeating: Double.nan, count: count)
        guard n1 > 0 else { return (result, []) }
        for i in (n1 - 1)..<count {
            var s = 0.0
            for j in (i - n1 + 1)...i { s += ratio[j] }
            result[i] = s
        }
        return (result, ma(values: result, period: m))
    }

    // MARK: VR（成交量比率）

    static func vr(closes: [Double], volumes: [Double], n: Int, m: Int) -> (vr: [Double], ma: [Double]) {
        let count = closes.count
        var v = Array(repeating: Double.nan, count: count)
        for i in 0..<count {
            let start = max(1, i - n + 1)
            var th = 0.0, tl = 0.0, tq = 0.0
            if start <= i {
                for j in start...i {
                    if closes[j] > closes[j - 1] { th += volumes[j] }
                    else if closes[j] < closes[j - 1] { tl += volumes[j] }
                    else { tq += volumes[j] }
                }
            }
            let denom = tl * 2 + tq
            v[i] = denom == 0 ? 0 : (th * 2 + tq) / denom * 100
        }
        return (v, ma(values: v, period: m))
    }

    // MARK: VRSI（量能强弱，三条线）

    static func vrsi(volumes: [Double], n1: Int, n2: Int, n3: Int) -> (r1: [Double], r2: [Double], r3: [Double]) {
        let count = volumes.count
        var dif = Array(repeating: 0.0, count: count)
        for i in 1..<count { dif[i] = volumes[i] - volumes[i - 1] }
        let up = dif.map { max($0, 0) }
        let ab = dif.map { abs($0) }
        func line(_ n: Int) -> [Double] {
            let mau = sma(up, period: n, m: 1)
            let mad = sma(ab, period: n, m: 1)
            return zip(mau, mad).map { $1 == 0 ? 100 : $0 / $1 * 100 }
        }
        return (line(n1), line(n2), line(n3))
    }

    // MARK: OBV（能量潮）

    static func obv(closes: [Double], volumes: [Double], m: Int) -> (obv: [Double], ma: [Double]) {
        let count = closes.count
        var o = Array(repeating: 0.0, count: count)
        for i in 1..<count {
            if closes[i] > closes[i - 1] { o[i] = o[i - 1] + volumes[i] }
            else if closes[i] < closes[i - 1] { o[i] = o[i - 1] - volumes[i] }
            else { o[i] = o[i - 1] }
        }
        return (o, ma(values: o, period: m))
    }

    // MARK: SAR（抛物线转向）

    static func sar(highs: [Double], lows: [Double], step: Double, maxStep: Double) -> (values: [Double], isUp: [Bool]) {
        let count = highs.count
        var out = Array(repeating: Double.nan, count: count)
        var upFlag = Array(repeating: true, count: count)
        guard count > 1 else { return (out, upFlag) }
        var isUp = true
        var af = step
        var extreme = highs[0]
        var sarVal = lows[0]
        out[0] = sarVal
        upFlag[0] = isUp
        for i in 1..<count {
            let prev = out[i - 1]
            if isUp {
                sarVal = prev + af * (extreme - prev)
                sarVal = min(sarVal, lows[i - 1])
            } else {
                sarVal = prev + af * (extreme - prev)
                sarVal = max(sarVal, highs[i - 1])
            }
            out[i] = sarVal
            if isUp && lows[i] < sarVal {
                isUp = false
                out[i] = extreme
                extreme = lows[i]
                af = step
            } else if !isUp && highs[i] > sarVal {
                isUp = true
                out[i] = extreme
                extreme = highs[i]
                af = step
            } else {
                if isUp {
                    if highs[i] > extreme { extreme = highs[i]; af = min(af + step, maxStep) }
                } else {
                    if lows[i] < extreme { extreme = lows[i]; af = min(af + step, maxStep) }
                }
            }
            upFlag[i] = isUp
        }
        return (out, upFlag)
    }
}
