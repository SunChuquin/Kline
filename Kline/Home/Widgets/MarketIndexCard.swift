//
//  MarketIndexCard.swift
//  Kline
//
//  行情指数卡片（大盘指数卡）：Apple Stocks + TradingView 风格。
//
//  设计口径（2026-11-22 用户给定）：
//  · **单一组件，按 ColorScheme 自动切换日间 / 夜间两套配色**，不分别开发两套卡片；
//  · 日间：页面底色 #F1F4F8、白色卡片 + 轻微阴影、主文字 #172033、次级文字 #929BAA、
//    分割线 #EDF0F4、涨 #E34D4D / 跌 #16A36A；
//  · 夜间：深蓝黑渐变卡片（#131B29 → #0B1220）+ 1pt 高光描边、白字、亮红亮绿；
//  · 三种形态：标准卡（价格 + 右侧走势 + 最高/最低/成交额）、紧凑卡（密集网格）、
//    图表卡（走势优先，大图）；
//  · 涨跌配色遵循中国 A 股习惯：红涨 / 绿跌 / 平盘与无值语义灰；
//  · 价格与涨跌**一律使用预格式化字符串**（金融数值不在视图层做浮点拼接），
//    指数保留 2 位小数、银行家舍入，等宽数字保证纵向对位；
//  · 兼容 iOS 15：不使用 Swift Charts、`contentTransition(.numericText())` 等 16+ API；
//    字号走 @ScaledMetric 随动态字体缩放，并限制上限避免撑破卡片。
//

import SwiftUI

// MARK: - 涨跌方向

/// 涨跌方向：卡片配色的唯一语义来源（不让视图各自判断正负号）
enum MarketQuoteDirection: String {
    case up          // 涨（红）
    case down        // 跌（绿）
    case flat        // 平盘（灰）
    case unavailable // 无有效值（灰）

    /// 由涨跌幅（Decimal，避免浮点比较抖动）判定方向
    static func from(changePct: Decimal?) -> MarketQuoteDirection {
        guard let pct = changePct else { return .unavailable }
        if pct > 0 { return .up }
        if pct < 0 { return .down }
        return .flat
    }
}

// MARK: - 卡片数据模型

/// 指数卡片数据：**只承载已格式化好的展示文本** + 原始走势值。
/// 视图内部不写死任何行情数字，换指数只需换模型。
struct MarketIndexQuote: Identifiable, Equatable {
    /// 唯一标识（指数代码）
    let id: String
    /// 指数名称，如「上证指数」
    let name: String
    /// 展示代码，如「SH000001」
    let code: String
    /// 市场标记，如「SSE」
    var market: String?
    /// 交易状态文案，如「交易中」「已收盘」（nil = 不显示）
    var status: String?
    /// 现价文本，如「3,862.40」（已按 2 位小数格式化）
    var priceText: String
    /// 涨跌额文本，如「+28.65」
    var changeText: String
    /// 涨跌幅文本，如「+0.75%」
    var pctText: String
    /// 涨跌方向
    var direction: MarketQuoteDirection
    /// 迷你走势点位（升序，旧→新）；不足 2 点时不绘制
    var sparkline: [Double]
    /// 最高文本（可选）
    var highText: String?
    /// 最低文本（可选）
    var lowText: String?
    /// 成交额文本（可选），如「4,218.6 亿」
    var turnoverText: String?
    /// 更新时间文本（可选），如「15:00」
    var updatedText: String?
}

// MARK: - 数值格式化（金融口径）

/// 指数展示格式化：2 位小数、银行家舍入（NumberFormatter 默认 .halfEven）、千分位分组。
/// 只在主线程调用；NumberFormatter 非线程安全，故统一收口于此。
enum MarketIndexQuoteFormatter {

    private static let priceFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "zh_CN")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.roundingMode = .halfEven
        return f
    }()

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "zh_CN")
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.roundingMode = .halfEven
        return f
    }()

    /// 现价：3,862.40；非有限值 / 无值返回 "-"
    static func price(_ value: Double?) -> String {
        guard let v = value, v.isFinite else { return "-" }
        return priceFormatter.string(from: NSNumber(value: v)) ?? "-"
    }

    /// 涨跌额：+28.65 / -12.30 / 0.00
    static func signedChange(_ value: Double?) -> String {
        guard let v = value, v.isFinite else { return "-" }
        let body = priceFormatter.string(from: NSNumber(value: abs(v))) ?? "-"
        if v > 0 { return "+" + body }
        if v < 0 { return "-" + body }
        return body
    }

    /// 涨跌幅：+0.75% / -0.42%
    static func signedPercent(_ value: Double?) -> String {
        guard let v = value, v.isFinite else { return "-" }
        let body = percentFormatter.string(from: NSNumber(value: abs(v))) ?? "-"
        if v > 0 { return "+" + body + "%" }
        if v < 0 { return "-" + body + "%" }
        return body + "%"
    }
}

// MARK: - 配色令牌（日间 / 夜间两套）

/// 卡片配色：按 ColorScheme 解析。日间为 Apple Stocks 浅色系，夜间为金融终端深色系。
private struct MarketIndexCardColors {
    let isDark: Bool
    /// 涨 / 跌 / 平 / 无值
    let up: Color
    let down: Color
    let flat: Color
    let unavailable: Color
    /// 主文字（价格）/ 次级文字（名称、标签）
    let primaryText: Color
    let secondaryText: Color
    /// 分割线
    let divider: Color
    /// 涨跌徽标底色浓度（日间更淡，避免脏）
    let badgeFillOpacity: Double

    static func resolve(_ scheme: ColorScheme) -> MarketIndexCardColors {
        if scheme == .dark {
            return MarketIndexCardColors(
                isDark: true,
                up: AppColors.marketUp,
                down: AppColors.marketDown,
                flat: AppColors.textTertiary,
                unavailable: AppColors.textTertiary,
                primaryText: AppColors.textPrimary,
                secondaryText: AppColors.textSecondary,
                divider: AppColors.separator,
                badgeFillOpacity: 0.14
            )
        }
        return MarketIndexCardColors(
            isDark: false,
            up: AppColors.marketUp,
            down: AppColors.marketDown,
            flat: AppColors.textTertiary,
            unavailable: AppColors.textTertiary,
            primaryText: AppColors.textPrimary,
            secondaryText: AppColors.textSecondary,
            divider: AppColors.separator,
            badgeFillOpacity: 0.10
        )
    }

    /// 夜间卡片底色渐变
    static let darkCardGradient = LinearGradient(
        colors: [
            Color(red: 0.075, green: 0.106, blue: 0.161),   // #131B29
            Color(red: 0.043, green: 0.071, blue: 0.125)    // #0B1220
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 夜间卡片高光描边
    static let darkBorderGradient = LinearGradient(
        colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 方向 → 颜色
    func tint(_ direction: MarketQuoteDirection) -> Color {
        switch direction {
        case .up: return up
        case .down: return down
        case .flat: return flat
        case .unavailable: return unavailable
        }
    }
}

/// 样张 / 宿主页面用的日间底色（#F1F4F8），夜间回落系统分组底色
private struct MarketIndexCardPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                AppColors.pageBackground
            } else {
                Color(red: 0.945, green: 0.957, blue: 0.973)   // #F1F4F8
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 迷你走势（无坐标轴、细线 + 渐变面积）

/// 迷你走势：无坐标轴、无边框，细折线 + 底部渐变填充。
/// 非有限值剔除；有效点不足 2 个时留白，不伪造走势。
struct MarketSparklineArea: View {
    let points: [Double]
    let tint: Color
    var lineWidth: CGFloat = 1.6
    /// 面积填充峰值浓度（图表卡更高，标准卡克制）
    var fillOpacity: Double = 0.26

    var body: some View {
        GeometryReader { geo in
            let values = points.filter { $0.isFinite }
            if values.count >= 2,
               let mn = values.min(),
               let mx = values.max() {
                let w = geo.size.width
                let h = geo.size.height
                let span = (mx - mn) > 0 ? (mx - mn) : 1
                let bottomInset = h * 0.1
                let drawable = max(h * 0.8, 1)
                let xs = values.indices.map { i in
                    w * CGFloat(i) / CGFloat(values.count - 1)
                }
                let ys = values.map { v in
                    h - bottomInset - CGFloat((v - mn) / span) * drawable
                }

                ZStack {
                    // 面积填充：折线闭合到底边
                    Path { path in
                        path.move(to: CGPoint(x: xs[0], y: ys[0]))
                        for i in 1..<xs.count {
                            path.addLine(to: CGPoint(x: xs[i], y: ys[i]))
                        }
                        path.addLine(to: CGPoint(x: xs[xs.count - 1], y: h))
                        path.addLine(to: CGPoint(x: xs[0], y: h))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(fillOpacity), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // 折线
                    Path { path in
                        path.move(to: CGPoint(x: xs[0], y: ys[0]))
                        for i in 1..<xs.count {
                            path.addLine(to: CGPoint(x: xs[i], y: ys[i]))
                        }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth,
                                                     lineCap: .round,
                                                     lineJoin: .round))
                }
            } else {
                // 数据不足：留白（不画假线）
                Color.clear
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 指数卡片

/// 行情指数卡片：单一组件、日间/夜间自动切换。
/// 三种形态：`.standard` 标准卡 / `.compact` 紧凑卡（密集网格）/ `.chart` 图表卡。
struct MarketIndexCard: View {
    enum Style {
        case standard   // 价格 + 右侧走势 + 最高/最低/成交额
        case compact    // 紧凑：名称/价格/涨跌 + 底部走势，供 3~6 列网格
        case chart      // 图表优先：价格与涨跌在上，大走势在下
    }

    let quote: MarketIndexQuote
    var style: Style = .standard
    /// 是否展示底部统计（标准卡 / 图表卡）
    var showsFooter: Bool = true
    /// 点击回调（nil = 纯展示）
    var onTap: ((MarketIndexQuote) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    // 字号随动态字体缩放（金融数字要求可读性，同时限制上限防止撑破卡片）
    @ScaledMetric(relativeTo: .largeTitle) private var standardPriceSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var compactPriceSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var chartPriceSize: CGFloat = 28
    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var largeChangeSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var compactChangeSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var codeSize: CGFloat = 11

    private var colors: MarketIndexCardColors { .resolve(colorScheme) }
    private var tint: Color { colors.tint(quote.direction) }
    private var isCompact: Bool { style == .compact }
    private var cornerRadius: CGFloat {
        switch style {
        case .standard: return 20
        case .chart: return 18
        case .compact: return 16
        }
    }
    private var contentPadding: CGFloat {
        switch style {
        case .standard: return 16
        case .chart: return 14
        case .compact: return 13
        }
    }
    private var priceSize: CGFloat {
        switch style {
        case .standard: return standardPriceSize
        case .chart: return chartPriceSize
        case .compact: return compactPriceSize
        }
    }

    var body: some View {
        if let onTap {
            Button(action: { onTap(quote) }) { cardBody }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: isCompact ? 7 : 12) {
            header
            switch style {
            case .standard:
                standardPriceBlock
                if showsFooter { footer }
            case .chart:
                chartPriceBlock
                MarketSparklineArea(points: quote.sparkline,
                                    tint: tint,
                                    lineWidth: 1.8,
                                    fillOpacity: 0.34)
                    .frame(height: 64)
                if showsFooter { footer }
            case .compact:
                compactPriceBlock
                MarketSparklineArea(points: quote.sparkline,
                                    tint: tint,
                                    lineWidth: 1.3,
                                    fillOpacity: 0.22)
                    .frame(height: 26)
            }
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// 卡片底：日间白卡 + 轻阴影 + 细描边；夜间深蓝黑渐变 + 高光描边
    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if colors.isDark {
            shape
                .fill(MarketIndexCardColors.darkCardGradient)
                .overlay(shape.stroke(MarketIndexCardColors.darkBorderGradient, lineWidth: 1))
        } else {
            shape
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
                .overlay(shape.stroke(colors.divider, lineWidth: 0.5))
        }
    }

    // MARK: 头部：名称 + 代码 + 交易状态

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(quote.name)
                    .font(.system(size: nameSize, weight: .semibold))
                    .foregroundColor(colors.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 4) {
                    Text(quote.code)
                        .lineLimit(1)
                    if let market = quote.market, !market.isEmpty {
                        Text("· \(market)")
                            .lineLimit(1)
                    }
                    if let updated = quote.updatedText, !updated.isEmpty {
                        Text("· \(updated)")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: isCompact ? codeSize - 1 : codeSize))
                .foregroundColor(colors.secondaryText)
            }

            Spacer(minLength: 4)

            if let status = quote.status, !status.isEmpty {
                statusChip(status)
            }
        }
    }

    /// 交易状态胶囊：状态点仅作提示，不表示涨跌方向
    private func statusChip(_ status: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.contains("交易") ? colors.down : colors.flat)
                .frame(width: 5, height: 5)
            Text(status)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(colors.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(colors.isDark ? Color.white.opacity(0.08)
                                  : Color(red: 0.945, green: 0.957, blue: 0.973))
        .clipShape(Capsule())
    }

    // MARK: 标准卡：价格 + 右侧走势

    private var standardPriceBlock: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                priceText
                changeBadge
            }

            Spacer(minLength: 8)

            MarketSparklineArea(points: quote.sparkline, tint: tint, lineWidth: 1.6)
                .frame(width: 104, height: 54)
        }
    }

    // MARK: 图表卡：价格与涨跌在上，大走势在下

    private var chartPriceBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            priceText
            Spacer(minLength: 8)
            changeBadge
        }
    }

    // MARK: 紧凑卡：价格 + 涨跌幅胶囊

    private var compactPriceBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            priceText
            changeBadge
        }
    }

    /// 价格（等宽数字，宽度不足时等比压缩，不换行）
    private var priceText: some View {
        Text(quote.priceText)
            .font(.system(size: priceSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(colors.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// 涨跌徽标：箭头 + 涨跌额 + 涨跌幅，方向色半透明底
    private var changeBadge: some View {
        HStack(spacing: 4) {
            if let icon = directionIcon {
                Image(systemName: icon)
                    .font(.system(size: isCompact ? 9 : 10, weight: .bold))
            }
            Text(joinedChangeText)
                .font(.system(size: isCompact ? compactChangeSize : largeChangeSize,
                              weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, isCompact ? 3 : 4)
        .background(tint.opacity(colors.badgeFillOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// 涨跌额 + 涨跌幅 合并文本；无值时只显示占位符
    private var joinedChangeText: String {
        switch quote.direction {
        case .unavailable:
            return "-"
        default:
            return "\(quote.changeText) (\(quote.pctText))"
        }
    }

    private var directionIcon: String? {
        switch quote.direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat, .unavailable: return nil
        }
    }

    // MARK: 底部统计：最高 / 最低 / 成交额

    @ViewBuilder
    private var footer: some View {
        if quote.highText != nil || quote.lowText != nil || quote.turnoverText != nil {
            HStack(alignment: .top, spacing: 8) {
                if let high = quote.highText { statColumn("最高", high) }
                Spacer(minLength: 4)
                if let low = quote.lowText { statColumn("最低", low) }
                Spacer(minLength: 4)
                if let turnover = quote.turnoverText { statColumn("成交额", turnover) }
            }
            .padding(.top, 10)
            .overlay(
                Rectangle()
                    .fill(colors.divider)
                    .frame(height: 0.5),
                alignment: .top
            )
        }
    }

    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(colors.secondaryText)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(colors.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 无障碍：金融数值必须整体朗读

    private var accessibilityText: String {
        var parts: [String] = [quote.name, quote.code]
        if let status = quote.status { parts.append(status) }
        parts.append("现价 \(quote.priceText)")
        if quote.direction == .unavailable {
            parts.append("暂无涨跌数据")
        } else {
            parts.append("涨跌 \(quote.changeText)")
            parts.append("涨跌幅 \(quote.pctText)")
        }
        if let high = quote.highText { parts.append("最高 \(high)") }
        if let low = quote.lowText { parts.append("最低 \(low)") }
        if let turnover = quote.turnoverText { parts.append("成交额 \(turnover)") }
        if let updated = quote.updatedText { parts.append("更新时间 \(updated)") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 卡片网格（首卡大卡 + N 列小卡）

/// 指数卡网格：首只指数用大卡（可关），其余按 `columnCount` 列排紧凑卡；
/// 空数据时显示显式空态，不伪造数值。
struct MarketIndexCardGrid: View {
    let quotes: [MarketIndexQuote]
    var onSelect: ((MarketIndexQuote) -> Void)?
    /// 每行列数（≥1；默认 2 列为「主卡 + 双列」口径）
    var columnCount: Int = 2
    /// 首只是否用标准卡（false = 全部按列数排紧凑卡，用于行密度演示）
    var showsLeadCard: Bool = true

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: max(columnCount, 1))
    }

    /// 参与网格的卡片：首卡用大卡时跳过第一只
    private var gridQuotes: ArraySlice<MarketIndexQuote> {
        showsLeadCard ? quotes.dropFirst() : quotes[...]
    }

    var body: some View {
        if quotes.isEmpty {
            Text("暂无指数数据")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
        } else {
            VStack(spacing: 12) {
                if showsLeadCard, let first = quotes.first {
                    MarketIndexCard(quote: first, style: .standard, onTap: onSelect)
                }
                if !gridQuotes.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(gridQuotes) { quote in
                            MarketIndexCard(quote: quote,
                                            style: .compact,
                                            showsFooter: false,
                                            onTap: onSelect)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 样张页（本阶段视觉验收用；接入真实数据后移除入口）

/// 卡片样张：日间/夜间自动切换，标准卡 / 图表卡 / 双列 / 3~6 列密度 / 涨跌平无值。
/// 数据全部为模拟值。
struct MarketIndexCardGalleryView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22))
                        .foregroundColor(AppColors.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("indexCardGallery.close")

                Text("行情卡片样张")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 56)
            .background(AppColors.pageBackground)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionTitle("标准卡片 · 价格 + 右侧走势 + 最高/最低/成交额")
                    MarketIndexCard(quote: Self.mockShanghai,
                                    style: .standard,
                                    onTap: { _ in })

                    sectionTitle("图表卡片 · 走势优先")
                    MarketIndexCard(quote: Self.mockShanghai,
                                    style: .chart,
                                    onTap: { _ in })

                    sectionTitle("双列紧凑卡片")
                    MarketIndexCardGrid(quotes: Self.mockGrid, onSelect: { _ in })

                    sectionTitle("行密度对比 · 每行 3 / 4 / 5 / 6 个")
                    ForEach([3, 4, 5, 6], id: \.self) { count in
                        rowDemo(count)
                    }

                    sectionTitle("状态对照 · 涨 / 跌 / 平 / 无值")
                    HStack(spacing: 12) {
                        MarketIndexCard(quote: Self.mockUp, style: .compact, showsFooter: false)
                        MarketIndexCard(quote: Self.mockDown, style: .compact, showsFooter: false)
                    }
                    HStack(spacing: 12) {
                        MarketIndexCard(quote: Self.mockFlat, style: .compact, showsFooter: false)
                        MarketIndexCard(quote: Self.mockNoData, style: .compact, showsFooter: false)
                    }

                    Text("以上行情为模拟数据，仅用于视觉验收；切换「个人中心 → Kline 主题」可对比日间/夜间两套配色。")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .background(MarketIndexCardPageBackground())
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(AppColors.textSecondary)
    }

    /// 行密度演示：同一批指数按 count 列排一行紧凑卡
    private func rowDemo(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每行 \(count) 个")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
            MarketIndexCardGrid(quotes: Array(Self.mockDense.prefix(count)),
                                onSelect: { _ in },
                                columnCount: count,
                                showsLeadCard: false)
        }
    }

    // MARK: 模拟数据

    fileprivate static func quote(id: String,
                                  name: String,
                                  code: String,
                                  market: String?,
                                  status: String?,
                                  price: Double?,
                                  change: Double?,
                                  pct: Double?,
                                  sparkline: [Double],
                                  high: Double? = nil,
                                  low: Double? = nil,
                                  turnover: String? = nil,
                                  updated: String? = nil) -> MarketIndexQuote {
        let direction = MarketQuoteDirection.from(changePct: pct.map { Decimal($0) })
        return MarketIndexQuote(
            id: id,
            name: name,
            code: code,
            market: market,
            status: status,
            priceText: MarketIndexQuoteFormatter.price(price),
            changeText: MarketIndexQuoteFormatter.signedChange(change),
            pctText: MarketIndexQuoteFormatter.signedPercent(pct),
            direction: direction,
            sparkline: sparkline,
            highText: high.map { MarketIndexQuoteFormatter.price($0) },
            lowText: low.map { MarketIndexQuoteFormatter.price($0) },
            turnoverText: turnover,
            updatedText: updated
        )
    }

    /// 确定性模拟走势（不用随机数，保证每次预览/每台设备一致）
    fileprivate static func wave(_ seed: Double, bias: Double, count: Int = 40) -> [Double] {
        (0..<count).map { i in
            let t = Double(i)
            return bias + sin(t * 0.34 + seed) * 6 + sin(t * 0.11 + seed * 2) * 3
        }
    }

    fileprivate static let mockShanghai = quote(
        id: "SH000001",
        name: "上证指数",
        code: "SH000001",
        market: "SSE",
        status: "交易中",
        price: 3862.40,
        change: 28.65,
        pct: 0.75,
        sparkline: wave(0.4, bias: 12),
        high: 3875.20,
        low: 3821.36,
        turnover: "4,285 亿",
        updated: "15:00"
    )

    fileprivate static let mockGrid: [MarketIndexQuote] = [
        quote(id: "SZ399001", name: "深证成指", code: "SZ399001", market: "SZSE",
              status: nil, price: 12145.82, change: 76.31, pct: 0.63,
              sparkline: wave(1.2, bias: 8)),
        quote(id: "SZ399006", name: "创业板指", code: "SZ399006", market: "SZSE",
              status: nil, price: 2845.61, change: -12.03, pct: -0.42,
              sparkline: wave(2.1, bias: 10)),
        quote(id: "SH000300", name: "沪深300", code: "SH000300", market: "SSE",
              status: nil, price: 4521.37, change: 18.92, pct: 0.42,
              sparkline: wave(3.3, bias: 6)),
        quote(id: "SH000688", name: "科创50", code: "SH000688", market: "SSE",
              status: "已收盘", price: 1023.55, change: -5.18, pct: -0.50,
              sparkline: wave(4.0, bias: 9))
    ]

    /// 行密度演示用：6 只指数（3/4/5/6 列各取前 N 只）
    fileprivate static let mockDense: [MarketIndexQuote] = [
        quote(id: "SH000001", name: "上证指数", code: "SH000001", market: "SSE",
              status: nil, price: 3862.40, change: 28.65, pct: 0.75,
              sparkline: wave(0.4, bias: 12)),
        quote(id: "SZ399001", name: "深证成指", code: "SZ399001", market: "SZSE",
              status: nil, price: 12145.82, change: 76.31, pct: 0.63,
              sparkline: wave(1.2, bias: 8)),
        quote(id: "SZ399006", name: "创业板指", code: "SZ399006", market: "SZSE",
              status: nil, price: 2845.61, change: -12.03, pct: -0.42,
              sparkline: wave(2.1, bias: 10)),
        quote(id: "SH000300", name: "沪深300", code: "SH000300", market: "SSE",
              status: nil, price: 4521.37, change: 18.92, pct: 0.42,
              sparkline: wave(3.3, bias: 6)),
        quote(id: "SH000688", name: "科创50", code: "SH000688", market: "SSE",
              status: nil, price: 1023.55, change: -5.18, pct: -0.50,
              sparkline: wave(4.0, bias: 9)),
        quote(id: "SH000016", name: "上证50", code: "SH000016", market: "SSE",
              status: nil, price: 2688.14, change: 9.76, pct: 0.36,
              sparkline: wave(4.8, bias: 7))
    ]

    fileprivate static let mockUp = quote(
        id: "MOCK-UP", name: "上涨样例", code: "MOCK001", market: nil, status: nil,
        price: 3862.40, change: 28.65, pct: 0.75, sparkline: wave(0.9, bias: 10)
    )

    fileprivate static let mockDown = quote(
        id: "MOCK-DOWN", name: "下跌样例", code: "MOCK002", market: nil, status: nil,
        price: 2845.61, change: -12.03, pct: -0.42, sparkline: wave(1.7, bias: 10)
    )

    fileprivate static let mockFlat = quote(
        id: "MOCK-FLAT", name: "平盘样例", code: "MOCK003", market: nil, status: "已收盘",
        price: 3110.00, change: 0, pct: 0, sparkline: wave(2.4, bias: 10)
    )

    fileprivate static let mockNoData = quote(
        id: "MOCK-NONE", name: "无值样例", code: "MOCK004", market: nil, status: nil,
        price: nil, change: nil, pct: nil, sparkline: []
    )
}

// MARK: - Preview

#Preview("指数卡片 · 日间") {
    ZStack {
        MarketIndexCardPageBackground()
        ScrollView {
            VStack(spacing: 12) {
                MarketIndexCard(quote: MarketIndexCardGalleryView.mockShanghai, style: .standard)
                MarketIndexCard(quote: MarketIndexCardGalleryView.mockShanghai, style: .chart)
                MarketIndexCardGrid(quotes: MarketIndexCardGalleryView.mockGrid)
            }
            .padding(16)
        }
    }
    .preferredColorScheme(.light)
}

#Preview("指数卡片 · 夜间") {
    ZStack {
        MarketIndexCardPageBackground()
        ScrollView {
            VStack(spacing: 12) {
                MarketIndexCard(quote: MarketIndexCardGalleryView.mockShanghai, style: .standard)
                MarketIndexCard(quote: MarketIndexCardGalleryView.mockShanghai, style: .chart)
                MarketIndexCardGrid(quotes: MarketIndexCardGalleryView.mockGrid)
            }
            .padding(16)
        }
    }
    .preferredColorScheme(.dark)
}
