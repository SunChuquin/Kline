//
//  MarketTest2View.swift
//  Kline
//
//  Created by AI on 2026/09/02.
//  测试2页：参考同花顺 PC 风格 资金看盘宽表布局
//  静态演示：顶部 LOGO + 一级全球/板块 Tab + A股二级分段 + 14列宽表头（横滑）+ 静态数据行
//

import SwiftUI

// MARK: - 表头列定义（宽表，横滑）

private enum FundColumn: String, CaseIterable, Identifiable {
    case name          // 看资金 → 名称代码
    case latest        // 最新
    case changePct     // 涨幅
    case change        // 涨跌
    case star          // 星级
    case turnoverRate  // 换手
    case volRatio      // 量比
    case bigOrder      // 大单净量
    case mainInflow    // 主力净流入
    case amplitude     // 振幅
    case momentum      // 涨速
    case peTTM         // 市盈(动)
    case pb            // 市净率
    case floatMv       // 流通市值
    case totalMv       // 总市值

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "看资金"
        case .latest: return "最新"
        case .changePct: return "涨幅"
        case .change: return "涨跌"
        case .star: return "星级"
        case .turnoverRate: return "换手"
        case .volRatio: return "量比"
        case .bigOrder: return "大单净量"
        case .mainInflow: return "主力净流入"
        case .amplitude: return "振幅"
        case .momentum: return "涨速"
        case .peTTM: return "市盈(动)"
        case .pb: return "市净率"
        case .floatMv: return "流通市值"
        case .totalMv: return "总市值"
        }
    }

    /// 每列宽度（像素近似值，iPad 屏幕宽 1024）
    var width: CGFloat {
        switch self {
        case .name: return 150
        case .latest, .changePct, .change, .turnoverRate, .volRatio,
             .amplitude, .momentum, .pb, .star: return 62
        case .bigOrder, .mainInflow: return 90
        case .peTTM: return 78
        case .floatMv, .totalMv: return 100
        }
    }

    /// 是否右对齐（数值列）
    var rightAligned: Bool {
        switch self {
        case .name, .star: return false
        default: return true
        }
    }

    /// 是否在表头右侧带「排序箭头」（涨幅=默认主排序，红箭头下）
    var sortArrow: SortDir? {
        switch self {
        case .changePct: return .down
        default: return nil
        }
    }

    enum SortDir {
        case up, down
    }
}

// MARK: - 页面主体

struct MarketTest2View: View {

    // 一级分类：全球 / A股 / 板块 / 科创 / 港股 / 美股 / 汇率 / 期货 / 基金 / 债券
    private enum TopTab: String, CaseIterable, Identifiable {
        case world = "全球"
        case AShare = "A股"
        case sector = "板块"
        case sci = "科创"
        case hk = "港股"
        case us = "美股"
        case fx = "汇率"
        case futures = "期货"
        case fund = "基金"
        case bond = "债券"
        var id: String { rawValue }
    }

    // A股 二级分段：全部A股 / 上证A股 / 深证A股 / 北证A股 / 创业板
    private enum ASeg: String, CaseIterable, Identifiable {
        case all = "全部A股"
        case sh = "上证A股"
        case sz = "深证A股"
        case bj = "北证A股"
        case cyb = "创业板"
        var id: String { rawValue }
    }

    /// 行数据（纯静态演示）
    private struct Row: Identifiable {
        let id = UUID()
        let name: String
        let code: String
        let latest: Double
        let changePct: Double
        let change: Double
        let star: Int             // 0-5 星
        let turnoverRate: Double  // %
        let volRatio: Double
        let bigOrder: Double      // 大单净量（%成交额），可负
        let mainInflow: Double    // 主力净流入（万元），可负
        let amplitude: Double     // %
        let momentum: Double      // 涨速（%，可负）
        let peTTM: Double?        // 市盈(动) 可为 nil
        let pb: Double
        let floatMv: Double       // 流通市值（亿元）
        let totalMv: Double       // 总市值（亿元）

        /// 某列的字符串展示
        func text(for col: FundColumn) -> String {
            switch col {
            case .name: return ""
            case .latest: return String(format: "%.2f", latest)
            case .changePct: return String(format: "%+.2f%%", changePct)
            case .change: return String(format: "%+.2f", change)
            case .star: return Array(repeating: "★", count: star).joined()
            case .turnoverRate: return String(format: "%.2f%%", turnoverRate)
            case .volRatio: return String(format: "%.2f", volRatio)
            case .bigOrder: return String(format: "%+.2f%%", bigOrder)
            case .mainInflow: return Self.fmtWan(mainInflow)
            case .amplitude: return String(format: "%.2f%%", amplitude)
            case .momentum: return String(format: "%+.2f%%", momentum)
            case .peTTM: return peTTM.map { String(format: "%.2f", $0) } ?? "-"
            case .pb: return String(format: "%.2f", pb)
            case .floatMv: return Self.fmtYi(floatMv)
            case .totalMv: return Self.fmtYi(totalMv)
            }
        }

        /// 某列的文字颜色（红涨绿跌灰平）
        func tint(for col: FundColumn) -> Color {
            switch col {
            case .latest, .changePct, .change, .mainInflow, .momentum, .bigOrder:
                if changePct > 0 { return .red }
                if changePct < 0 { return .green }
                return .secondary
            case .star: return .orange
            default: return .primary
            }
        }

        static func fmtYi(_ yi: Double) -> String {
            if yi >= 10000 { return String(format: "%.2f万亿", yi / 10000) }
            return String(format: "%.0f亿", yi)
        }
        static func fmtWan(_ wan: Double) -> String {
            if abs(wan) >= 10000 {
                return String(format: "%+.2f亿", wan / 10000)
            }
            return String(format: "%+.0f万", wan)
        }
    }

    @State private var topTab: TopTab = .AShare
    @State private var aSeg: ASeg = .all
    // 表头与数据行横向滚动的共享偏移量：表头/数据滚动区都据此 offset，天然同步
    @State private var hScrollOffset: CGFloat = 0
    @State private var hDragStart: CGFloat = 0   // 一次横向拖动的起始偏移
    @State private var vScrollOffset: CGFloat = 0 // 纵向滚动偏移（手势驱动，绕过 ScrollView 手势冲突）
    @State private var vDragStart: CGFloat = 0
    @State private var panAxis: String? = nil     // 当前拖动主轴："h" / "v"

    // 演示 3 行数据（含各字段自洽）
    private static let demoRows: [Row] = [
        Row(name: "华宇科技", code: "600001",
            latest: 25.30, changePct: 9.98, change: 2.29,
            star: 5, turnoverRate: 8.50, volRatio: 2.30,
            bigOrder: 12.36, mainInflow: 25800,
            amplitude: 13.2, momentum: 0.36,
            peTTM: 36.4, pb: 4.21,
            floatMv: 142, totalMv: 258),
        Row(name: "龙芯微电", code: "600011",
            latest: 66.75, changePct: 7.12, change: 4.43,
            star: 4, turnoverRate: 5.60, volRatio: 1.85,
            bigOrder: 6.82, mainInflow: 18600,
            amplitude: 9.8, momentum: 0.14,
            peTTM: 128.6, pb: 6.85,
            floatMv: 588, totalMv: 1862),
        Row(name: "蓝海能源", code: "600002",
            latest: 12.45, changePct: -9.95, change: -1.37,
            star: 2, turnoverRate: 12.30, volRatio: 3.60,
            bigOrder: -15.40, mainInflow: -32500,
            amplitude: 12.6, momentum: -0.88,
            peTTM: nil, pb: 1.08,
            floatMv: 96, totalMv: 124),
        Row(name: "紫金矿业", code: "600007",
            latest: 21.80, changePct: 3.87, change: 0.81,
            star: 4, turnoverRate: 3.20, volRatio: 1.20,
            bigOrder: 4.51, mainInflow: 8200,
            amplitude: 5.4, momentum: 0.22,
            peTTM: 18.2, pb: 3.45,
            floatMv: 1024, totalMv: 2860),
        Row(name: "江南生物", code: "600004",
            latest: 44.10, changePct: 1.23, change: 0.54,
            star: 3, turnoverRate: 2.40, volRatio: 0.98,
            bigOrder: 1.20, mainInflow: 2400,
            amplitude: 3.8, momentum: 0.05,
            peTTM: 52.6, pb: 6.10,
            floatMv: 386, totalMv: 620),
        Row(name: "凌云航空", code: "600005",
            latest: 15.20, changePct: 0.00, change: 0.00,
            star: 3, turnoverRate: 2.80, volRatio: 1.33,
            bigOrder: 0.00, mainInflow: 0,
            amplitude: 2.6, momentum: 0.00,
            peTTM: 22.8, pb: 1.92,
            floatMv: 210, totalMv: 305),
        Row(name: "天工重工", code: "600006",
            latest: 8.65, changePct: -2.45, change: -0.22,
            star: 2, turnoverRate: 4.50, volRatio: 1.10,
            bigOrder: -3.26, mainInflow: -7600,
            amplitude: 5.1, momentum: -0.31,
            peTTM: 15.4, pb: 1.66,
            floatMv: 88, totalMv: 132),
        Row(name: "华夏银行", code: "600008",
            latest: 7.32, changePct: -0.68, change: -0.05,
            star: 3, turnoverRate: 0.90, volRatio: 0.82,
            bigOrder: -0.85, mainInflow: -1800,
            amplitude: 1.8, momentum: -0.02,
            peTTM: 5.2, pb: 0.62,
            floatMv: 1280, totalMv: 1420),
        Row(name: "北辰置业", code: "600009",
            latest: 4.56, changePct: 0.88, change: 0.04,
            star: 2, turnoverRate: 2.00, volRatio: 1.05,
            bigOrder: 0.42, mainInflow: 950,
            amplitude: 3.2, momentum: 0.06,
            peTTM: 28.6, pb: 0.88,
            floatMv: 156, totalMv: 210),
        Row(name: "海天调味", code: "600010",
            latest: 98.20, changePct: -1.10, change: -1.09,
            star: 4, turnoverRate: 1.10, volRatio: 0.65,
            bigOrder: -2.38, mainInflow: -5200,
            amplitude: 2.4, momentum: -0.12,
            peTTM: 45.2, pb: 8.96,
            floatMv: 1280, totalMv: 4620),
        Row(name: "顺风物流", code: "600012",
            latest: 18.90, changePct: -4.32, change: -0.85,
            star: 2, turnoverRate: 3.80, volRatio: 1.42,
            bigOrder: -6.70, mainInflow: -12400,
            amplitude: 6.2, momentum: -0.46,
            peTTM: 12.4, pb: 2.10,
            floatMv: 480, totalMv: 760),
        Row(name: "星图智能", code: "600013",
            latest: 88.60, changePct: 5.26, change: 4.42,
            star: 5, turnoverRate: 9.20, volRatio: 2.95,
            bigOrder: 9.40, mainInflow: 26800,
            amplitude: 8.4, momentum: 0.40,
            peTTM: 88.4, pb: 9.62,
            floatMv: 466, totalMv: 1580),
        Row(name: "中天能源", code: "600014",
            latest: 6.58, changePct: 2.01, change: 0.13,
            star: 3, turnoverRate: 3.10, volRatio: 1.22,
            bigOrder: 1.85, mainInflow: 3100,
            amplitude: 4.0, momentum: 0.10,
            peTTM: 9.8, pb: 1.24,
            floatMv: 132, totalMv: 186),
        Row(name: "恒大新材", code: "600015",
            latest: 32.40, changePct: 6.58, change: 2.00,
            star: 4, turnoverRate: 7.40, volRatio: 2.11,
            bigOrder: 7.26, mainInflow: 15600,
            amplitude: 9.0, momentum: 0.35,
            peTTM: 66.2, pb: 5.80,
            floatMv: 320, totalMv: 486),
        Row(name: "新能锂业", code: "600016",
            latest: 12.90, changePct: -3.22, change: -0.43,
            star: 2, turnoverRate: 6.80, volRatio: 2.30,
            bigOrder: -8.90, mainInflow: -21000,
            amplitude: 7.8, momentum: -0.52,
            peTTM: nil, pb: 3.30,
            floatMv: 142, totalMv: 268),
        Row(name: "风华纸业", code: "600017",
            latest: 9.86, changePct: 0.92, change: 0.09,
            star: 3, turnoverRate: 2.30, volRatio: 0.88,
            bigOrder: 0.66, mainInflow: 1380,
            amplitude: 2.9, momentum: 0.04,
            peTTM: 13.6, pb: 1.18,
            floatMv: 96, totalMv: 142),
        Row(name: "华力创通", code: "600018",
            latest: 27.30, changePct: 8.66, change: 2.18,
            star: 4, turnoverRate: 10.20, volRatio: 2.60,
            bigOrder: 8.32, mainInflow: 19800,
            amplitude: 11.4, momentum: 0.48,
            peTTM: 74.5, pb: 7.20,
            floatMv: 268, totalMv: 386),
        Row(name: "晶合集成", code: "600019",
            latest: 18.44, changePct: -2.87, change: -0.55,
            star: 2, turnoverRate: 5.10, volRatio: 1.55,
            bigOrder: -4.60, mainInflow: -9800,
            amplitude: 6.4, momentum: -0.35,
            peTTM: nil, pb: 2.84,
            floatMv: 412, totalMv: 655),
        Row(name: "立昂微", code: "600020",
            latest: 55.20, changePct: 4.35, change: 2.30,
            star: 4, turnoverRate: 6.80, volRatio: 1.92,
            bigOrder: 5.88, mainInflow: 14200,
            amplitude: 7.6, momentum: 0.26,
            peTTM: 92.6, pb: 5.66,
            floatMv: 355, totalMv: 520),
        Row(name: "通富微电", code: "600021",
            latest: 31.75, changePct: -1.66, change: -0.54,
            star: 3, turnoverRate: 4.40, volRatio: 1.12,
            bigOrder: -2.15, mainInflow: -4700,
            amplitude: 4.8, momentum: -0.18,
            peTTM: 68.3, pb: 3.42,
            floatMv: 602, totalMv: 930),
        Row(name: "兆易创新", code: "600022",
            latest: 120.50, changePct: 6.21, change: 7.05,
            star: 5, turnoverRate: 7.90, volRatio: 2.35,
            bigOrder: 10.76, mainInflow: 33200,
            amplitude: 9.2, momentum: 0.42,
            peTTM: 110.2, pb: 8.15,
            floatMv: 880, totalMv: 1360),
        Row(name: "韦尔股份", code: "600023",
            latest: 98.40, changePct: 2.15, change: 2.07,
            star: 4, turnoverRate: 3.40, volRatio: 1.35,
            bigOrder: 3.20, mainInflow: 7600,
            amplitude: 5.2, momentum: 0.16,
            peTTM: 68.5, pb: 4.80,
            floatMv: 420, totalMv: 1180),
        Row(name: "澜起科技", code: "600024",
            latest: 72.80, changePct: -1.48, change: -1.09,
            star: 3, turnoverRate: 2.60, volRatio: 0.92,
            bigOrder: -1.85, mainInflow: -4200,
            amplitude: 3.6, momentum: -0.10,
            peTTM: 85.2, pb: 6.10,
            floatMv: 336, totalMv: 780),
        Row(name: "中芯国际", code: "600025",
            latest: 58.60, changePct: 2.88, change: 1.64,
            star: 4, turnoverRate: 4.20, volRatio: 1.68,
            bigOrder: 4.62, mainInflow: 15600,
            amplitude: 5.8, momentum: 0.22,
            peTTM: nil, pb: 2.96,
            floatMv: 986, totalMv: 5200),
        Row(name: "北方华创", code: "600026",
            latest: 312.00, changePct: 4.45, change: 13.29,
            star: 5, turnoverRate: 5.60, volRatio: 2.05,
            bigOrder: 8.14, mainInflow: 28400,
            amplitude: 7.2, momentum: 0.30,
            peTTM: 76.8, pb: 9.20,
            floatMv: 980, totalMv: 1660),
        Row(name: "卓胜微", code: "600027",
            latest: 132.20, changePct: -3.10, change: -4.23,
            star: 3, turnoverRate: 4.80, volRatio: 1.75,
            bigOrder: -5.30, mainInflow: -12600,
            amplitude: 6.8, momentum: -0.40,
            peTTM: 95.4, pb: 8.62,
            floatMv: 520, totalMv: 620)
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBrandBar
            aSegBarIfNeeded
            tableHeaderSticky   // 冻结表头：不随垂直滚动隐藏，横向跟随数据列联动
            tableScroll         // 数据区：垂直 + 横向滚动
        }
        // 占满全高并顶部对齐：避免父级 .infinity 高度把内容垂直居中（否则顶栏上下出现大段空白）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 背景延伸到状态栏/安全区，顶栏视觉贴合屏幕顶部（内容仍保持在安全区内不被遮挡）
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: - 顶部 LOGO + 一级 Tab + 搜索

    private var topBrandBar: some View {
        HStack(spacing: 0) {
            // 同花顺 LOGO（占位，用 red ♣️ + 字代替）
            HStack(spacing: 4) {
                Image(systemName: "suit.club.fill")
                    .font(.system(size: 18)).foregroundColor(.red)
                Text("同花顺")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            // 一级 Tab（横滑）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(TopTab.allCases) { t in
                        Button(action: { topTab = t }) {
                            Text(t.rawValue)
                                .font(.system(size: 15, weight: topTab == t ? .bold : .regular))
                                .foregroundColor(topTab == t ? .red : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 8)

            // 🔍 搜索（右对齐）
            Button {} label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .frame(height: 38)
        }
        .frame(height: 44)
        .background(Color(.systemBackground))
    }

    // MARK: - A 股二级分段（仅当 topTab = .AShare 时显示）

    @ViewBuilder
    private var aSegBarIfNeeded: some View {
        if topTab == .AShare {
            HStack(spacing: 4) {
                ForEach(ASeg.allCases) { s in
                    Button(action: { aSeg = s }) {
                        Text(s.rawValue)
                            .font(.system(size: 13, weight: aSeg == s ? .bold : .regular))
                            .foregroundColor(aSeg == s ? .red : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(aSeg == s ? Color.red.opacity(0.08) : Color.clear)
                            .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6).opacity(0.4))
        }
    }

    // MARK: - 列分组：冻结前 3 列（名称/最新/涨幅），其余列横向滚动

    private let frozenCols: [FundColumn] = [.name, .latest, .changePct]
    private var scrollCols: [FundColumn] { FundColumn.allCases.filter { !frozenCols.contains($0) } }
    private var frozenWidth: CGFloat { frozenCols.reduce(0) { $0 + $1.width } }

    // MARK: - 冻结表头（不随垂直滚动隐藏；前 3 列固定，其余横向跟随数据列联动）

    private var tableHeaderSticky: some View {
        ZStack(alignment: .leading) {
            Color(.systemGray6)   // 背景铺满整个屏幕宽
            // 滚动区表头（横向跟随数据区滚动）
            HStack(spacing: 0) {
                Color.clear.frame(width: frozenWidth)   // 占位：让滚动列从冻结区右侧开始
                ForEach(scrollCols) { col in
                    headerCell(col)
                        .frame(width: col.width, height: 30, alignment: col.rightAligned ? .trailing : .leading)
                }
            }
            .padding(.horizontal, 10)
            .offset(x: hScrollOffset)
            // 冻结区表头（前 3 列，固定不动，灰底遮挡下方滚动内容）
            HStack(spacing: 0) {
                ForEach(frozenCols) { col in
                    headerCell(col)
                        .frame(width: col.width, height: 30, alignment: col.rightAligned ? .trailing : .leading)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: frozenWidth + 20, alignment: .leading)
            .background(Color(.systemGray6))
            .zIndex(2)   // 保证冻结表头盖在滚动表头上
            // 冻结区右侧竖分割线
            .overlay(alignment: .trailing) { Color(.separator).frame(width: 0.5) }
        }
        .frame(maxWidth: .infinity, maxHeight: 30, alignment: .leading)
        .clipped()
        .overlay(alignment: .bottom) { Color(.separator).frame(height: 0.5) }
    }

    // MARK: - 表格区（外垂直滚动；左右两侧：冻结列固定 + 滚动列横向滚动；上报横向偏移给冻结表头）

    private var tableScroll: some View {
        GeometryReader { geo in
            let viewW = geo.size.width
            let viewH = geo.size.height
            ZStack(alignment: .topLeading) {
                // 滚动区（其余列）：横向 + 纵向都用手势驱动的 offset
                VStack(spacing: 0) {
                    ForEach(Self.demoRows) { row in
                        scrollColsView(row, height: 40)
                        Color(.separator).frame(height: 0.5)
                    }
                }
                .offset(x: hScrollOffset, y: vScrollOffset)
                .frame(width: viewW + maxHOffset, alignment: .leading)

                // 冻结区（前 3 列）：横向固定，但随纵向滚动
                VStack(spacing: 0) {
                    ForEach(Self.demoRows) { row in
                        frozenColsView(row, height: 40)
                        Color(.separator).frame(height: 0.5)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: frozenWidth + 20, alignment: .leading)
                .offset(y: vScrollOffset)
                .background(Color(.systemBackground))
                .overlay(alignment: .trailing) { Color(.separator).frame(width: 0.5) }
                .zIndex(1)

                // 底部"更多数据"占位，保证纵向可滚动区域高度由手势上限控制
                Color.clear.frame(height: 1)
            }
            .frame(width: viewW, height: viewH, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(panDrag(viewH: viewH))
            .clipped()
        }
    }

    /// 纵向滚动上限（内容总高 - 可视高）
    private func maxVOffset(viewH: CGFloat) -> CGFloat {
        let contentH = CGFloat(Self.demoRows.count) * 40.5
        return max(0, contentH - viewH)
    }

    /// 横向滚动上限（超过则不可再左滑）
    private var maxHOffset: CGFloat {
        scrollContentWidth - (frozenWidth + 20)
    }

    /// 拖动手势：按主轴分别驱动横向/纵向滚动（表头与数据同步）
    private func panDrag(viewH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                if panAxis == nil {
                    // 首次位移判定主轴
                    panAxis = abs(v.translation.width) > abs(v.translation.height) ? "h" : "v"
                    hDragStart = hScrollOffset
                    vDragStart = vScrollOffset
                }
                if panAxis == "h" {
                    let candidate = hDragStart + v.translation.width
                    hScrollOffset = min(0, max(-maxHOffset, candidate))
                } else {
                    let candidate = vDragStart + v.translation.height
                    vScrollOffset = min(0, max(-maxVOffset(viewH: viewH), candidate))
                }
            }
            .onEnded { _ in
                panAxis = nil
                hDragStart = hScrollOffset
                vDragStart = vScrollOffset
            }
    }

    /// 滚动区内容总宽度 = 前3列占位 + 滚动列宽度
    private var scrollContentWidth: CGFloat {
        frozenWidth + scrollCols.reduce(0) { $0 + $1.width }
    }

    // MARK: - 冻结列行（前 3 列：名称/最新/涨幅，固定不动）

    private func frozenColsView(_ row: Row, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            // name 列：两行布局（名称 大 + 代码 小）
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(row.code)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: FundColumn.name.width, height: height, alignment: .leading)
            .padding(.horizontal, 4)
            // latest / changePct 数值列
            ForEach([FundColumn.latest, FundColumn.changePct]) { col in
                Text(row.text(for: col))
                    .font(.system(size: 13))
                    .foregroundColor(row.tint(for: col))
                    .lineLimit(1)
                    .frame(width: col.width, height: height, alignment: col.rightAligned ? .trailing : .leading)
                    .padding(.horizontal, 4)
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 滚动列行（其余列，横向滚动）

    private func scrollColsView(_ row: Row, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: frozenWidth)   // 占位，让滚动列与冻结区对齐
            ForEach(scrollCols) { col in
                Text(row.text(for: col))
                    .font(.system(size: 13))
                    .foregroundColor(row.tint(for: col))
                    .lineLimit(1)
                    .frame(width: col.width, height: height, alignment: col.rightAligned ? .trailing : .leading)
                    .padding(.horizontal, 4)
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 表头单元格（14 列）

    private func headerCell(_ col: FundColumn) -> some View {
        HStack(spacing: 2) {
            if col.rightAligned { Spacer(minLength: 0) }
            Text(col.title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if let dir = col.sortArrow {
                Image(systemName: "triangle.fill")
                    .rotationEffect(.degrees(dir == .down ? 0 : 180))
                    .font(.system(size: 7))
                    .foregroundColor(.red)
                    .offset(y: 1)
            }
            if !col.rightAligned { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 4)
    }
}

#Preview {
    MarketTest2View()
}
