//
//  WrappingHStack.swift
//  Kline
//
//  通用流式换行布局（FlowLayout 语义，iOS 15 兼容——部署目标 15.0，禁用 iOS 16+ 的 Layout 协议）：
//  子项按理想宽横排，超出可用宽自动换到下一行。供模拟页指标行、自选 C 工具行、
//  账户卡网格等"多行水平内容在 iPhone 11（414pt）超宽出屏"的场景统一复用。
//
//  实现要点（两趟测量，刻意避开"在 alignmentGuide 闭包里改 @State"的老式 hack——
//  那种写法在视图构建期写状态，SwiftUI 6 严格并发下直接报错且行为未定义）：
//  ① 第一趟：子项 .fixedSize() 按理想尺寸渲染，background 里 GeometryReader 经
//     PreferenceKey 上报 (item.id, size)；此时尺寸未回收 → 所有子项堆在原点、组件高度 0；
//  ② 尺寸由 .onPreferenceChange 写入 @State（唯一写入点），自然触发第二次布局：
//     body 里根据可用宽（外层 GeometryReader）+ 已测尺寸做纯函数断行
//     （WrappingHStackLayoutMath），再用 ZStack + .offset 定位——闭包里只读
//     已算好的 (x, y)，绝不写状态。
//

import SwiftUI

// MARK: - 行内对齐方式

/// 每行内子项的水平排布：leading 左对齐 / center 居中 / trailing 右对齐
enum WrappingHStackAlignment {
    case leading, center, trailing
}

// MARK: - 断行纯函数（可单测）

/// 断行算法：与 SwiftUI 无关的纯静态函数，给定尺寸与可用宽即可确定整张布局，
/// 单测（WrappingHStackTests）直接钉死其行为，视图层只做"喂尺寸 + 照 (x,y) 摆放"。
enum WrappingHStackLayoutMath {

    /// 一行的断行结果
    struct Row: Equatable {
        var itemIndices: [Int]     // 行内子项在入参 sizes 里的下标
        var contentWidth: CGFloat  // 行内容总宽（含子项间水平间距）
        var height: CGFloat        // 行高 = 行内最高子项
    }

    /// 整体布局结果
    struct Layout: Equatable {
        var rows: [Row] = []
        var positions: [CGPoint] = []  // positions[i] = 第 i 个子项的左上角坐标
        var totalSize: CGSize = .zero  // 内容总尺寸（宽 = 最宽行；高 = 各行高 + 行间行距）
    }

    /// 纯函数断行。规则：逐项累加，当前行非空且放不下
    /// （已占宽 + 间距 + 本项宽 > 可用宽）才换行；单独一项超可用宽时独占一行、
    /// 宽度如实上报（不裁切，是否溢出显示交给上层决定）。
    static func layout(
        sizes: [CGSize],
        availableWidth: CGFloat,
        horizontalSpacing: CGFloat,
        rowSpacing: CGFloat,
        alignment: WrappingHStackAlignment
    ) -> Layout {
        var result = Layout()
        result.positions = Array(repeating: .zero, count: sizes.count)
        guard !sizes.isEmpty else { return result }  // 空集合 → 0 行 0 高

        var cursorY: CGFloat = 0   // 下一行的起始 y
        var rowIndices: [Int] = []
        var rowWidth: CGFloat = 0  // 当前行已占宽（含子项间水平间距）
        var rowHeight: CGFloat = 0

        // 结算一行：按 alignment 算起始 x、写入各项 (x, y)；行距只加在行与行之间
        // （不放循环外统一加，否则末行会多出一条行距）
        func commitRow() {
            guard !rowIndices.isEmpty else { return }
            if !result.rows.isEmpty { cursorY += rowSpacing }
            let startX: CGFloat
            switch alignment {
            case .leading:  startX = 0
            case .center:   startX = max(0, (availableWidth - rowWidth) / 2)  // 超宽行退化为左对齐，避免向左出屏
            case .trailing: startX = max(0, availableWidth - rowWidth)
            }
            var x = startX
            for index in rowIndices {
                result.positions[index] = CGPoint(x: x, y: cursorY)
                x += sizes[index].width + horizontalSpacing
            }
            result.rows.append(Row(itemIndices: rowIndices, contentWidth: rowWidth, height: rowHeight))
            result.totalSize.width = max(result.totalSize.width, rowWidth)
            cursorY += rowHeight
            rowIndices = []
            rowWidth = 0
            rowHeight = 0
        }

        for (index, size) in sizes.enumerated() {
            // 换行判定：空行永远放得下（单项超宽也先入行，下一项自然被挤到新行 → 独占一行）
            let needsNewRow = !rowIndices.isEmpty
                && rowWidth + horizontalSpacing + size.width > availableWidth
            if needsNewRow { commitRow() }
            if rowIndices.isEmpty {
                rowWidth = size.width
            } else {
                rowWidth += horizontalSpacing + size.width
            }
            rowIndices.append(index)
            rowHeight = max(rowHeight, size.height)
        }
        commitRow()  // 最后一行
        result.totalSize.height = cursorY
        return result
    }
}

// MARK: - 尺寸回传 PreferenceKey

/// 子项理想尺寸上报：[item.id: 理想尺寸]。多实例并存的 reduce 合并是安全的——
/// fixedSize 保证尺寸只取决于子项内容本身、与所在容器宽无关，同 id 必然同尺寸。
private struct WrappingHStackItemSizeKey<ID: Hashable>: PreferenceKey {
    static var defaultValue: [ID: CGSize] { [:] }
    static func reduce(value: inout [ID: CGSize], nextValue: () -> [ID: CGSize]) {
        for (id, size) in nextValue() { value[id] = size }
    }
}

/// 组件自适应高度上报：GeometryReader 内算出的内容总高，传给外层 .frame(height:)。
/// reduce 用 max 而非覆盖：嵌套使用时内层组件的高度也经此 key 冒泡，
/// 而内层高度必然 ≤ 所在行高 ≤ 外层总高，max 取值不受污染。
private struct WrappingHStackFittedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - 流式换行布局

/// 流式换行布局（FlowLayout 语义，iOS 15 兼容——部署目标 15.0，禁用 iOS 16+ 的 Layout 协议）：
/// 子项按理想宽横排，超出可用宽自动换到下一行；单独超宽的子项独占一行且不裁切。
///
/// 两趟测量特性：首趟尺寸未回收、组件高度为 0（未测量项按零尺寸兜底）；
/// 子项经 PreferenceKey 上报理想尺寸后由 .onPreferenceChange 写回 @State，
/// 自然触发第二次布局得到最终排布与高度。因此本组件可直接放进 VStack / ScrollView
/// 等自适应流里，调用方无需指定高度。
///
/// 垂直 ScrollView 内使用时宽度测量仍正确：外层 GeometryReader 拿到的是父级提议宽
/// （即视口宽），.frame(height:) 只覆盖高度提议、宽度原样透传。
struct WrappingHStack<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let horizontalSpacing: CGFloat
    let rowSpacing: CGFloat
    let alignment: WrappingHStackAlignment
    let content: (Item) -> Content

    /// 子项理想尺寸。唯一写入点是 .onPreferenceChange——绝不在布局闭包里写状态，
    /// 避免"视图构建期改 @State"这一 SwiftUI 经典未定义行为。
    @State private var itemSizes: [Item.ID: CGSize] = [:]
    /// 组件自适应总高。同样只经 .onPreferenceChange 更新（由内部撑杆上报）。
    @State private var fittedHeight: CGFloat = 0

    init(items: some RandomAccessCollection<Item>,
         horizontalSpacing: CGFloat = 8,
         rowSpacing: CGFloat = 8,
         alignment: WrappingHStackAlignment = .leading,
         @ViewBuilder content: @escaping (Item) -> Content) {
        // 统一转数组：断行下标定位与 ForEach 枚举都需要稳定的有序随机访问
        self.items = Array(items)
        self.horizontalSpacing = horizontalSpacing
        self.rowSpacing = rowSpacing
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            layoutBody(availableWidth: max(0, geo.size.width))
        }
        .frame(height: fittedHeight)  // 对外高度自适应：首趟 0，测量完成后贴合内容
        .onPreferenceChange(WrappingHStackItemSizeKey<Item.ID>.self) { itemSizes = $0 }
        .onPreferenceChange(WrappingHStackFittedHeightKey.self) { fittedHeight = $0 }
    }

    /// 布局主体：可用宽 + 已测尺寸 → 纯函数断行 → ZStack + offset 定位（只读计算值）。
    /// 未测量项按零尺寸兜底 → 首趟全部堆在原点、不占空间，测量回收后 body 自然重算。
    private func layoutBody(availableWidth: CGFloat) -> some View {
        let layout = WrappingHStackLayoutMath.layout(
            sizes: items.map { itemSizes[$0.id] ?? .zero },
            availableWidth: availableWidth,
            horizontalSpacing: horizontalSpacing,
            rowSpacing: rowSpacing,
            alignment: alignment
        )

        return ZStack(alignment: .topLeading) {
            // 高度撑杆：ZStack 报告尺寸是子项并集、offset 又不计入其中，
            // 若无撑杆总高会丢失；撑杆同时把总高经 preference 传给外层 .frame(height:)
            Color.clear
                .frame(width: availableWidth, height: layout.totalSize.height)
                .preference(key: WrappingHStackFittedHeightKey.self,
                            value: layout.totalSize.height)

            ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                content(pair.element)
                    // 按理想尺寸渲染：既让 background 测到"未被容器压缩"的尺寸，
                    // 也让超宽子项完整显示（独占一行不裁切）；双向 fixedSize 还能
                    // 保证首趟高度 0 的提议不会把子项压扁、测出错误高度
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: WrappingHStackItemSizeKey<Item.ID>.self,
                                value: [pair.element.id: geo.size])
                        }
                    )
                    .offset(x: layout.positions[pair.offset].x,
                            y: layout.positions[pair.offset].y)
            }
        }
    }
}

// MARK: - 预览（金融指标胶囊演示）

/// 预览用胶囊模型：文案即 id（演示数据无去重诉求，简单可靠）
private struct PreviewPill: Identifiable {
    let text: String
    var id: String { text }
}

/// 金融指标风格文案：对应模拟页指标行 / 账户卡的真实超宽场景
private let previewPills: [PreviewPill] = [
    "总资产 259,204", "可用 100,000", "持仓市值 159,204",
    "今日盈亏 +1,234", "保证金率 42.8%", "风险度 57.2%",
    "累计收益 +8,666", "年化收益 12.5%",
].map(PreviewPill.init)

private func pillView(_ pill: PreviewPill) -> some View {
    Text(pill.text)
        .font(.system(size: 12))
        .foregroundColor(.blue)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.blue.opacity(0.12))
        .cornerRadius(10)
}

#Preview("三档宽度 414 / 848 / 1024") {
    // 同一组指标：窄屏（iPhone 11 竖屏）自动折行、宽屏（iPad）单行铺开
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ForEach([414.0, 848.0, 1024.0], id: \.self) { width in
                VStack(alignment: .leading, spacing: 6) {
                    Text("可用宽 \(Int(width))pt")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    WrappingHStack(items: previewPills) { pillView($0) }
                        .frame(width: width)
                        .background(Color.gray.opacity(0.08))
                        .border(Color.gray.opacity(0.4))
                }
            }
        }
        .padding()
    }
}

#Preview("边界：超长项 / 空集合 / 不同间距") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            // 单个超长项：独占一行、不裁切（如实溢出容器右缘显示）
            WrappingHStack(items: [PreviewPill(text: "超长指标项：持仓加权平均成本 259,204.55（含今晨集合竞价与昨夜清算数据）")]) {
                pillView($0)
            }
            .frame(width: 300)
            .border(Color.red.opacity(0.5))

            // 空集合：不渲染任何内容、高度 0
            WrappingHStack(items: [PreviewPill]()) { pillView($0) }
                .frame(width: 300)
                .border(Color.gray.opacity(0.4))

            // 紧凑间距 4
            WrappingHStack(items: previewPills, horizontalSpacing: 4, rowSpacing: 4) { pillView($0) }
                .frame(width: 300)
                .border(Color.gray.opacity(0.4))

            // 宽松间距 16 + 居中对齐
            WrappingHStack(items: previewPills, horizontalSpacing: 16, rowSpacing: 16, alignment: .center) { pillView($0) }
                .frame(width: 300)
                .border(Color.gray.opacity(0.4))
        }
        .padding()
    }
}
