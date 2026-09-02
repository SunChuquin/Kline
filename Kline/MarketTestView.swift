//
//  MarketTestView.swift
//  Kline
//
//  Created by AI on 2026/09/01.
//  测试页：参考同花顺风格 紧凑榜单（P0）+ 市场概况（P1）
//  纯静态演示数据，仅用于展示布局样式，不接入真实行情/自选/详情。
//

import SwiftUI

// MARK: - 榜单分类 / 周期 定义

enum RankingTab: String, CaseIterable, Identifiable {
    case changePct = "涨幅榜"
    case dropPct = "跌幅榜"
    case momentum = "涨速榜"
    case turnover = "金额榜"
    case turnoverRate = "换手榜"
    case volumeRatio = "量比榜"
    var id: String { rawValue }
}

enum PeriodTab: String, CaseIterable, Identifiable {
    case today = "今日"
    case d3 = "3日"
    case d5 = "5日"
    case d10 = "10日"
    case d20 = "20日"
    case d60 = "60日"
    var id: String { rawValue }
}

/// 涨跌幅分段：和参考图一一对应（涨停 / >7% / 5-7 / 3-5 / 0-3 / 平 / 0-3 / 3-5 / 5-7 / >7% / 跌停）
enum PctBucket: CaseIterable, Identifiable {
    case limitUp       // 涨停 ≥10%（简化判定）
    case over7         // 7% ≤ 涨 < 10%
    case range5_7      // 5% ≤ 涨 < 7%
    case range3_5      // 3% ≤ 涨 < 5%
    case range0_3      // 0 < 涨 < 3%
    case flat          // 涨跌幅 = 0
    case range0_3Down  // -3% < 跌 < 0
    case range3_5Down  // -5% ≤ 跌 < -3%
    case range5_7Down  // -7% ≤ 跌 < -5%
    case over7Down     // -10% < 跌 ≤ -7%
    case limitDown     // 跌停 ≤ -10%

    var id: String { label }

    var label: String {
        switch self {
        case .limitUp: return "涨停"
        case .over7: return ">7%"
        case .range5_7: return "5-7"
        case .range3_5: return "3-5"
        case .range0_3: return "0-3"
        case .flat: return "平"
        case .range0_3Down: return "0-3"
        case .range3_5Down: return "3-5"
        case .range5_7Down: return "5-7"
        case .over7Down: return ">7%"
        case .limitDown: return "跌停"
        }
    }

    var color: Color {
        switch self {
        case .flat: return .secondary
        case .limitUp, .over7, .range5_7, .range3_5, .range0_3: return .red
        case .range0_3Down, .range3_5Down, .range5_7Down, .over7Down, .limitDown: return .green
        }
    }
}

// MARK: - 页面主体

struct MarketTestView: View {
    // 顶部市场分类 Tab（沪深京 / 北证 / 创业 / 科创 / 沪深主板）
    private enum MarketSegTab: String, CaseIterable, Identifiable {
        case hsj = "沪深京"
        case bz = "北证"
        case cy = "创业"
        case kc = "科创"
        case zhuban = "沪深主板"
        var id: String { rawValue }
    }

    /// 演示行数据（纯静态，仅布局展示）
    private struct DemoRow: Identifiable {
        let id = UUID()
        let name: String
        let code: String
        let tag: String
        let price: Double
        let pctToday: Double
        let pct3: Double
        let pct5: Double
        let pct10: Double
        let pct20: Double
        let pct60: Double
        let amountYi: Double   // 成交额（亿）
        let turnRate: Double   // 换手率 %
        let volRatio: Double   // 量比
        var isFaved: Bool

        /// 当前周期对应的涨幅
        func pct(for p: PeriodTab) -> Double {
            switch p {
            case .today: return pctToday
            case .d3: return pct3
            case .d5: return pct5
            case .d10: return pct10
            case .d20: return pct20
            case .d60: return pct60
            }
        }
    }

    @State private var segTab: MarketSegTab = .zhuban
    @State private var rankingTab: RankingTab = .changePct
    @State private var periodTab: PeriodTab = .today
    @State private var displayRows: [DemoRow] = []
    // 可变的演示数据源（🔔 点击切换置顶用）
    @State private var demoRows: [DemoRow] = MarketTestView.seedData

    // MARK: - 演示数据（布局展示用）

    private static let seedData: [DemoRow] = [
        DemoRow(name: "华宇科技", code: "600001", tag: "消费电子", price: 25.30, pctToday: 9.98, pct3: 12.40, pct5: 15.80, pct10: 8.20, pct20: 3.10, pct60: -5.60, amountYi: 45.20, turnRate: 8.50, volRatio: 2.30, isFaved: true),
        DemoRow(name: "龙芯微电", code: "600011", tag: "半导体", price: 66.75, pctToday: 7.12, pct3: 6.20, pct5: 3.50, pct10: -1.80, pct20: -8.40, pct60: -22.00, amountYi: 32.80, turnRate: 5.60, volRatio: 1.85, isFaved: true),
        DemoRow(name: "星图智能", code: "600003", tag: "人工智能", price: 88.60, pctToday: 5.26, pct3: 8.90, pct5: 12.00, pct10: 18.50, pct20: 25.00, pct60: 41.20, amountYi: 58.30, turnRate: 9.20, volRatio: 2.95, isFaved: true),
        DemoRow(name: "紫金矿业", code: "600007", tag: "有色金属", price: 21.80, pctToday: 3.87, pct3: 1.20, pct5: -0.60, pct10: -2.40, pct20: -4.80, pct60: 6.30, amountYi: 61.50, turnRate: 3.20, volRatio: 1.20, isFaved: false),
        DemoRow(name: "江南生物", code: "600004", tag: "医药生物", price: 44.10, pctToday: 1.23, pct3: 2.10, pct5: 3.40, pct10: -1.20, pct20: -6.50, pct60: -15.30, amountYi: 18.90, turnRate: 2.40, volRatio: 0.98, isFaved: false),
        DemoRow(name: "凌云航空", code: "600005", tag: "航空运输", price: 15.20, pctToday: 0.00, pct3: 0.40, pct5: -0.20, pct10: 1.80, pct20: 4.20, pct60: 8.90, amountYi: 20.60, turnRate: 2.80, volRatio: 1.33, isFaved: false),
        DemoRow(name: "天工重工", code: "600006", tag: "高端装备", price: 8.65, pctToday: -2.45, pct3: -3.10, pct5: -4.20, pct10: -7.80, pct20: -12.50, pct60: -18.00, amountYi: 9.60, turnRate: 4.50, volRatio: 1.10, isFaved: false),
        DemoRow(name: "华夏银行", code: "600008", tag: "银行", price: 7.32, pctToday: -0.68, pct3: -0.40, pct5: 0.20, pct10: 1.10, pct20: 2.00, pct60: 3.50, amountYi: 15.40, turnRate: 0.90, volRatio: 0.82, isFaved: false),
        DemoRow(name: "北辰置业", code: "600009", tag: "房地产", price: 4.56, pctToday: 0.88, pct3: 1.40, pct5: 2.20, pct10: -3.50, pct20: -8.10, pct60: -20.40, amountYi: 8.30, turnRate: 2.00, volRatio: 1.05, isFaved: false),
        DemoRow(name: "海天调味", code: "600010", tag: "食品饮料", price: 98.20, pctToday: -1.10, pct3: -2.30, pct5: -1.80, pct10: 2.10, pct20: 5.60, pct60: 12.40, amountYi: 22.10, turnRate: 1.10, volRatio: 0.65, isFaved: false),
        DemoRow(name: "顺风物流", code: "600012", tag: "交通运输", price: 18.90, pctToday: -4.32, pct3: -5.00, pct5: -6.10, pct10: -8.30, pct20: -10.20, pct60: -14.60, amountYi: 12.70, turnRate: 3.80, volRatio: 1.42, isFaved: false),
        DemoRow(name: "蓝海能源", code: "600002", tag: "电力", price: 12.45, pctToday: -9.95, pct3: -11.00, pct5: -13.50, pct10: -16.20, pct20: -20.80, pct60: -28.40, amountYi: 30.50, turnRate: 12.30, volRatio: 3.60, isFaved: false)
    ]

    // 市场概况（演示数值，共 3193 只，自洽）
    private static let demoOverview = OverviewStats(
        totalTurnoverYuan: 12856e8,   // 12856 亿
        upCount: 1595, flatCount: 120, downCount: 1478,
        pending: 0,
        bucketCounts: [
            .limitUp: 42, .over7: 55, .range5_7: 88, .range3_5: 260, .range0_3: 1150,
            .flat: 120,
            .range0_3Down: 1120, .range3_5Down: 240, .range5_7Down: 72, .over7Down: 40, .limitDown: 6
        ]
    )

    // MARK: - 排序规则（随榜单/周期 Tab 变化）

    private func sortKey(for row: DemoRow) -> Double {
        switch rankingTab {
        case .changePct: return row.pct(for: periodTab)
        case .dropPct:   return -row.pct(for: periodTab)
        case .momentum:  return row.pct3
        case .turnover:  return row.amountYi
        case .turnoverRate: return row.turnRate
        case .volumeRatio: return row.volRatio
        }
    }

    private func reorder() {
        let faved = demoRows.filter(\.isFaved)
        let others = demoRows.filter { !$0.isFaved }
        displayRows = faved.sorted { sortKey(for: $0) > sortKey(for: $1) }
            + others.sorted { sortKey(for: $0) > sortKey(for: $1) }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topSegmentBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    Section(header: rankingBar) {
                        marketOverviewSection
                        compactRankList
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { reorder() }
        .onChange(of: rankingTab) { _ in reorder() }
        .onChange(of: periodTab) { _ in reorder() }
    }

    // MARK: - 顶部分段 + 筛选/设置

    private var topSegmentBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(MarketSegTab.allCases) { seg in
                        Button(action: { segTab = seg }) {
                            Text(seg.rawValue)
                                .font(.system(size: 15, weight: segTab == seg ? .bold : .regular))
                                .foregroundColor(segTab == seg ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .overlay(alignment: .bottom) {
                                    if segTab == seg {
                                        Rectangle().fill(Color.red).frame(height: 2).padding(.horizontal, 10)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 6)
            Button {} label: { Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(.secondary).font(.system(size: 16)) }
            .buttonStyle(.plain).frame(width: 30)
            Button {} label: { Image(systemName: "gearshape")
                .foregroundColor(.secondary).font(.system(size: 16)) }
            .buttonStyle(.plain).frame(width: 30)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 榜单 + 周期 Tab（吸顶）

    private var rankingBar: some View {
        VStack(spacing: 0) {
            // 榜单 Tab
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(RankingTab.allCases) { r in
                        Button(action: { rankingTab = r }) {
                            Text(r.rawValue)
                                .font(.system(size: 14, weight: rankingTab == r ? .bold : .regular))
                                .foregroundColor(rankingTab == r ? .red : .secondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .overlay(alignment: .bottom) {
                                    if rankingTab == r {
                                        Rectangle().fill(Color.red).frame(height: 2).padding(.horizontal, 11)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Color(.systemBackground))
            // 周期 Tab
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(PeriodTab.allCases) { p in
                        Button(action: { periodTab = p }) {
                            Text(p.rawValue)
                                .font(.system(size: 13, weight: periodTab == p ? .bold : .regular))
                                .foregroundColor(periodTab == p ? .red : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(periodTab == p ? Color.red.opacity(0.08) : Color.clear)
                                .cornerRadius(14)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .background(Color(.systemBackground))
            Divider()
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 市场概况区块（P1）

    private var marketOverviewSection: some View {
        let stats = Self.demoOverview
        let total = max(1, stats.upCount + stats.flatCount + stats.downCount)
        let totalTurnoverYi = stats.totalTurnoverYuan / 1e8
        let upRatio = Double(stats.upCount) / Double(total) * 100

        return VStack(alignment: .leading, spacing: 0) {
            // 标题行
            HStack(spacing: 6) {
                Text("市场概况").font(.system(size: 19, weight: .bold)).foregroundColor(.primary)
                Spacer()
                Text("总成交额").font(.system(size: 13)).foregroundColor(.secondary)
                Text(String(format: "%.0f亿", totalTurnoverYi)).font(.system(size: 14, weight: .bold)).foregroundColor(.red)
                Text("较昨日此时").font(.system(size: 13)).foregroundColor(.secondary)
                Text("——").font(.system(size: 14, weight: .bold)).foregroundColor(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(Color(.tertiaryLabel))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 三卡
            HStack(spacing: 10) {
                overviewCard(title: "主力净额", value: "-42.6亿", color: .green) {
                    Text("今日").font(.system(size: 11)).foregroundColor(.secondary)
                }
                overviewCard(title: "涨跌家数",
                             value: "\(stats.upCount):\(stats.flatCount):\(stats.downCount)",
                             color: .primary) {
                    Text(String(format: "共 %d 只", total))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                overviewCard(title: "市场情绪",
                             value: String(format: "涨%.0f%%家", upRatio),
                             color: .blue) {}
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 涨跌分布柱状图
            distributionChart(stats: stats)
                .padding(.horizontal, 12)
                .padding(.top, 14)

            // 底部红绿进度条
            upDownProgressBar(stats: stats)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)

            // 主题前瞻 banner 占位
            HStack(spacing: 8) {
                Image(systemName: "doc.text.image")
                    .foregroundColor(.orange).font(.system(size: 15))
                Text("【明日主题前瞻】AI 正深度融入药物研发全链条...")
                    .font(.system(size: 13)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(Color(.tertiaryLabel)).font(.system(size: 11))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .padding(.bottom, 12)
    }

    private func overviewCard<Extra: View>(title: String, value: String, color: Color,
                                           @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(title).font(.system(size: 13)).foregroundColor(.secondary)
            Text(value).font(.system(size: 18, weight: .bold)).foregroundColor(color)
                .minimumScaleFactor(0.7).lineLimit(1)
            extra()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    /// 11 段涨跌分布柱状图：顶部计数，中间柱，底部 label
    private func distributionChart(stats: OverviewStats) -> some View {
        let maxCount = PctBucket.allCases.reduce(0) { m, b in
            max(m, stats.bucketCounts[b] ?? 0)
        }
        let barMaxH: CGFloat = 110

        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(PctBucket.allCases) { b in
                let count = stats.bucketCounts[b] ?? 0
                let ratio: CGFloat = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
                VStack(spacing: 3) {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(b.color)
                        .frame(height: 14, alignment: .bottom)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(b.color.opacity(0.85))
                        .frame(height: max(2, ratio * barMaxH))
                    Text(b.label)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(height: 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: barMaxH + 14 + 12 + 4)
    }

    /// 底部红绿进度条：up（红） / flat（灰） / down（绿）
    private func upDownProgressBar(stats: OverviewStats) -> some View {
        let total = CGFloat(max(1, stats.upCount + stats.flatCount + stats.downCount))
        let upW = CGFloat(stats.upCount) / total
        let flatW = CGFloat(stats.flatCount) / total
        // let downW = 1 - upW - flatW
        return HStack(alignment: .center, spacing: 0) {
            Text("\(stats.upCount)").font(.system(size: 13, weight: .bold)).foregroundColor(.red)
            GeometryReader { g in
                HStack(spacing: 0) {
                    Color.red.frame(width: max(2, g.size.width * upW))
                    Color.secondary.opacity(0.35).frame(width: max(1, g.size.width * flatW))
                    Color.green
                }
            }
            .frame(height: 8)
            .cornerRadius(4)
            Text("\(stats.downCount)").font(.system(size: 13, weight: .bold)).foregroundColor(.green)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 紧凑榜单列表（P0）

    private var compactRankList: some View {
        VStack(spacing: 0) {
            ForEach(displayRows) { row in
                rankRow(row: row)
                Divider().padding(.leading, 16)
            }
        }
        .background(Color(.systemBackground))
    }

    private func rankRow(row: DemoRow) -> some View {
        let pct = row.pct(for: periodTab)
        let isFaved = demoRowFavedState(row)
        let tint: Color = pct > 0 ? .red : (pct < 0 ? .green : .secondary)

        return HStack(alignment: .top, spacing: 10) {
            // 自选 🔔（演示：点击切换置顶）
            Button(action: { toggleFaved(row) }) {
                Image(systemName: isFaved ? "bell.fill" : "bell")
                    .font(.system(size: 16))
                    .foregroundColor(isFaved ? .yellow : .secondary)
                    .frame(width: 24, height: 32)
            }
            .buttonStyle(.plain)

            // 左：名称 + 代码 + 标签
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.code).font(.system(size: 12)).foregroundColor(.secondary)
                    if !row.tag.isEmpty {
                        Text(row.tag)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .background(Color(.systemGray5))
                            .cornerRadius(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右：现价 + 涨幅
            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.fmtPrice(row.price))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(tint)
                    .lineLimit(1)
                Text(Self.fmtPct(pct))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.systemBackground))
    }

    private func demoRowFavedState(_ row: DemoRow) -> Bool {
        demoRows.first(where: { $0.id == row.id })?.isFaved ?? row.isFaved
    }

    private func toggleFaved(_ row: DemoRow) {
        if let idx = demoRows.firstIndex(where: { $0.id == row.id }) {
            demoRows[idx].isFaved.toggle()
        }
        reorder()
    }

    // MARK: - 市场概况聚合结构（演示）

    private struct OverviewStats {
        var totalTurnoverYuan: Double = 0   // 总成交额（元）→ 亿
        var upCount = 0, flatCount = 0, downCount = 0
        var pending = 0                     // 还没 bars 的数量
        /// 每个涨跌分段的计数
        var bucketCounts: [PctBucket: Int] = [:]
    }

    // MARK: - 辅助

    private static func fmtPrice(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.2f", v) }
        if v >= 1 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }
    private static func fmtPct(_ v: Double) -> String {
        return String(format: "%+.2f%%", v)
    }
}

#Preview {
    MarketTestView()
}
