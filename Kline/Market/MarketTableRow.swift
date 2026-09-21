//
//  MarketTableRow.swift
//  Kline
//
//  行情/自选统一行控件：mode 区分表头/数据行，共用唯一列网格与右边界竖线。
//

import SwiftUI



// MARK: - 唯一列网格（表头 / 表内容共用的唯一定义）
// 统一列宽、格子对齐与右边界竖线；marker 参数区分表头/数据内容。

struct MarketTableRow: View {
    /// 行形态：表头（字段名+排序箭头）或数据行（某标的值）
    enum Mode {
        case header
        case data(meta: MetaItem)

        var isHeader: Bool {
            if case .header = self { return true }
            return false
        }
    }

    let page: MarketConfigPage
    let mode: Mode
    @ObservedObject var config: MarketConfigStore
    @ObservedObject var rowCache: MarketRowCache

    /// 数据行点击打开详情；默认打开详情页
    var onOpen: ((MetaItem) -> Void)? = nil
    /// 表头点击字段排序；默认内部切 config
    var onColumnTapped: ((MarketField) -> Void)? = nil

    // === 整表冻结 + 横向滚动 ===
    /// 冻结前 N 个可见列（固定不参与横向滚动），其余列横向 offset 平移
    var frozenCount: Int = 3
    /// 整表共享的横向滚动偏移（由外层手势驱动）
    var xOffset: CGFloat = 0
    /// 是否为自选（置顶）标：高亮整行背景 + 标的文字变红；默认 false
    var isFaved: Bool = false

    // === 行高 / 字号覆盖（紧凑布局用；nil = 沿用既有写死值，A 档渲染零变化） ===
    /// 行高覆盖：nil 时沿用既有 38（表头）/ 45（数据行）
    var heightOverride: CGFloat? = nil
    /// 主字号覆盖：nil 时沿用既有 18；代码副行按 0.72 比例缩放（下限 10）
    var fontSizeOverride: CGFloat? = nil

    /// 自选高亮背景色：比普通行更深（浅灰底）
    private var rowBackground: Color {
        isFaved ? Color(.systemGray5) : Color(.systemBackground)
    }

    /// 统一列宽（保留当前表格样式：固定 108pt 等宽 + 竖线）
    private static let colW: CGFloat = 108
    private static let lineW: CGFloat = 0.5

    /// 把可视列转成渲染列：相邻的「代码 + 名称」合并为一个双行单元格（名称在上、代码在下），宽度=两列之和。
    private func renderColumns(_ cols: [MarketColumnPref]) -> [ColumnLayout] {
        Self.renderColumns(cols)
    }

    /// 静态版 renderColumns（供外层计算横向滚动上限等复用，保证与渲染完全一致）。
    /// 列宽取「用户 widthOverride ?? 默认宽」：合并列默认 162pt、普通列默认 colW。
    fileprivate static func renderColumns(_ cols: [MarketColumnPref]) -> [ColumnLayout] {
        var out: [ColumnLayout] = []
        var i = 0
        while i < cols.count {
            let cur = cols[i]
            // 找到相邻的 name/code 对（顺序任意），合并为一个双行单元格
            if cur.field == .name || cur.field == .code {
                let next = i + 1 < cols.count ? cols[i + 1] : nil
                if let n = next, n.field != cur.field, (n.field == .name || n.field == .code) {
                    // 合并列宽度以 name 字段的覆盖值为准
                    let namePref = cur.field == .name ? cur : n
                    let w = namePref.widthOverride ?? mergedDefaultWidth
                    out.append(ColumnLayout(field: .name, width: w, isNameCode: true, overrideField: .name))
                    i += 2
                    continue
                }
            }
            out.append(ColumnLayout(field: cur.field, width: cur.widthOverride ?? colW, isNameCode: false, overrideField: cur.field))
            i += 1
        }
        return out
    }

    /// 合并列（名称+代码）默认渲染宽：保留当前 0.75×2 列规则
    private static let mergedDefaultWidth: CGFloat = colW * 2 * 0.75

    /// 默认渲染列布局（供边线拖改覆盖层/外部计算复用），保证与表头、数据行渲染完全一致
    static func renderedColumns(for page: MarketConfigPage, config: MarketConfigStore) -> [ColumnLayout] {
        renderColumns(config.visibleColumns(for: page))
    }

    /// 由「未保存的草稿列配置」算渲染列：表头设置面板里边改边看（如冻结列名）时用，
    /// 保证与保存后表格的真实列顺序一致
    static func renderedColumns(draft columns: [MarketColumnPref]) -> [ColumnLayout] {
        renderColumns(MarketConfigStore.visibleColumns(in: columns))
    }

    /// 某列第一次超过「默认宽 ± 阈值」前，不写入覆盖值（保持 widthOverride = nil，可随默认宽联动）
    static func shouldClearOverride(_ width: CGFloat, col: ColumnLayout) -> Bool {
        let base = col.isNameCode ? mergedDefaultWidth : colW
        return abs(width - base) < 0.5
    }

    /// 冻结前 N 列后的其余列总宽（供外层算最大横向偏移）；收到冻结区起始分隔线宽
    static func scrollContentWidth(for page: MarketConfigPage, config: MarketConfigStore, frozenCount: Int) -> CGFloat {
        let cols = renderColumns(config.visibleColumns(for: page))
        let frozenCols = Array(cols.prefix(frozenCount))
        let scrollCols = Array(cols.dropFirst(frozenCount))
        let frozenW = frozenCols.reduce(lineW) { $0 + $1.width + lineW }
        let scrollW = scrollCols.reduce(0) { $0 + $1.width + lineW }
        return frozenW + scrollW
    }

    var body: some View {
        // 行高 / 字号：未传覆盖值时与既有写死值完全一致（表头 38 / 数据行 45 / 主字号 18 / 副字号 13）
        let rowHeight: CGFloat = heightOverride ?? (mode.isHeader ? 38 : 45)
        let mainFont: CGFloat = fontSizeOverride ?? 18
        let subFont: CGFloat = fontSizeOverride.map { max(10, $0 * 0.72) } ?? 13
        let cols = renderColumns(config.visibleColumns(for: page))
        let frozenCols = Array(cols.prefix(frozenCount))
        let scrollCols = Array(cols.dropFirst(frozenCount))
        let frozenW = frozenCols.reduce(Self.lineW) { $0 + $1.width + Self.lineW }
        let scrollW = scrollCols.reduce(0) { $0 + $1.width + Self.lineW }
        let rule = config.sortRule(for: page)

        // 用 GeometryReader 实测宿主宽 visW（自动落在安全区/贴边后的真实可视宽内）。
        // ⚠️ 行外框必须固定=visW：若用 minWidth: 列总和，ZStack 布局宽会被撑到所有列之和
        //（远超屏宽），.clipped() 只裁视觉不裁布局尺寸，外层 VStack 居中它 → 两侧对称溢出
        //（mini 等无刘海机型无 inset 吸收，溢出最明显）。列总和只放进内部滚动区。
        GeometryReader { geo in
            let visW = geo.size.width
            ZStack(alignment: .topLeading) {
                // 滚动区：其余列（前接与冻结区等宽的占位），横向 offset 平移
                HStack(spacing: 0) {
                    Color.clear.frame(width: frozenW)
                    ForEach(scrollCols) { col in
                        content(col, header: mode.isHeader, meta: metaOf, rule: rule,
                                mainFont: mainFont, subFont: subFont)
                            .padding(.horizontal, col.isNameCode ? 8 : 6)
                            .frame(width: col.width, alignment: col.isNameCode ? .leading : (col.field.alignRight ? .trailing : .leading))
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                        Color.clear.frame(width: Self.lineW)   // 列边界线已隐藏，仅保留宽度占位
                    }
                }
                // 滚动区宽度 = max(可视宽, 全部列宽)：列放得下就铺满，放不下才横向滚动
                .frame(width: max(visW, frozenW + scrollW), height: rowHeight, alignment: .leading)
                .padding(.top, mode.isHeader ? 1 : 0)
                .background(rowBackground)
                .offset(x: xOffset)
                .zIndex(0)
                .clipped()

                // 冻结区：前 N 列固定，盖在滚动区上方，右侧竖分割线
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.lineW)   // 列边界线已隐藏，仅保留宽度占位
                    ForEach(frozenCols) { col in
                        content(col, header: mode.isHeader, meta: metaOf, rule: rule,
                                mainFont: mainFont, subFont: subFont)
                            .padding(.horizontal, col.isNameCode ? 8 : 6)
                            .frame(width: col.width, alignment: col.isNameCode ? .leading : (col.field.alignRight ? .trailing : .leading))
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                        Color.clear.frame(width: Self.lineW)   // 列边界线已隐藏，仅保留宽度占位
                    }
                }
                .frame(width: frozenW, height: rowHeight, alignment: .leading)
                .padding(.top, mode.isHeader ? 1 : 0)
                .background(rowBackground)
                .overlay(alignment: .trailing) { Color.clear.frame(width: 0.5) }   // 冻结区分割线已隐藏，保留占位
                .zIndex(2)
                .clipped()
            }
            // 整行严格 = visW 并裁剪，列再多也不越界（溢出交给内部滚动区 + offset 处理）
            .frame(width: visW, height: rowHeight, alignment: .leading)
            .clipped()
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            // 数据行整行可点打开标的详情；表头 metaOf 为 nil 不触发（不拦截排序按钮）
            if let m = metaOf { onOpen?(m) }
        }
    }

    /// 当前行的 meta（数据行才有；表头为占位 nil）
    private var metaOf: MetaItem? {
        if case .data(let meta) = mode { return meta }
        return nil
    }

    /// 单元格内容：表头 = 字段名(+排序箭头)；数据 = 字段文本(红涨绿跌)。
    /// 合并列（代码+名称）渲染为双行：名称在上、代码在下。
    /// `mainFont` / `subFont` 为字号（未传覆盖值时分别等于既有 18 / 13）。
    @ViewBuilder
    private func content(_ col: ColumnLayout, header: Bool, meta: MetaItem?, rule: MarketSortRule?,
                         mainFont: CGFloat, subFont: CGFloat) -> some View {
        if header {
            // 合并列表头：显示「名称/代码」
            let active = rule?.field == col.field
            Button(action: {
                if let cb = onColumnTapped { cb(col.field) }
                else { config.toggleSort(field: col.field, page: page) }
            }) {
                if col.isNameCode {
                    HStack(spacing: 3) {
                        Text("名称/代码")
                            .font(.system(size: mainFont, weight: .medium))
                            .foregroundColor(active ? Color.accentColor : Color(.secondaryLabel))
                            .lineLimit(1)
                        if active, let r = rule {
                            Image(systemName: r.order == .descending ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color.accentColor)
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 3) {
                        Text(col.field.title)
                            .font(.system(size: mainFont, weight: .medium))
                            .foregroundColor(active ? Color.accentColor : Color(.secondaryLabel))
                            .lineLimit(1)
                        // 已配置筛选的字段：显示漏斗小图标（没有选中排序箭头时也显示）
                        if !config.filterLabels(for: col.field, page: page).isEmpty {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                        }
                        if active, let r = rule {
                            Image(systemName: r.order == .descending ? "chevron.down" : "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color.accentColor)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .buttonStyle(.plain)
        } else if let meta = meta {
            // 自选高亮：名称/代码/板块等「标的」列文字变红（指标数值仍红涨绿跌）
            if col.isNameCode {
                let fg: Color = isFaved ? .red : .primary
                VStack(alignment: .leading, spacing: 1) {
                    Text(meta.name)
                        .font(.system(size: mainFont, weight: .medium))
                        .foregroundColor(fg)
                        .lineLimit(1)
                    Text(meta.displayCode)
                        .font(.system(size: subFont))
                        .foregroundColor(isFaved ? fg : Color(.secondaryLabel))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                let isLabel = col.field == .name || col.field == .code || col.field == .type
                let cellFg: Color = isFaved && isLabel ? Color.red : rowCache.colorFor(meta.id, col.field)
                Text(rowCache.textFor(meta.id, col.field))
                    .font(.system(size: mainFont))
                    .foregroundColor(cellFg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

