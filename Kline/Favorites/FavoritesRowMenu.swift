//
//  FavoritesRowMenu.swift
//  Kline
//
//  自选页 / 行情页共用的「长按操作面板」与自选页的弹窗族（备注 / 预警 / 底部批量条），
//  用于替代系统 `.contextMenu`：
//  `.contextMenu` 走 `UIContextMenuInteraction` 的抬升快照管线，会把行**换宿主重排**，
//  而行内是「GeometryReader 实测宽 + 常量列宽 + offset(x:) + 多层 clipped()」，
//  换宿主后提案宽度变化 → 列错位 / 被裁；本文件的面板挂在页面容器层 overlay，
//  行与卡片自身样式（高度 / 列宽 / 缩放 / 位移 / 背景）零改动，长按前后几何逐值不变。
//  约定：iOS 15 兼容（不用 NavigationStack / @Observable / presentationDetents），
//  配色一律语义色（支持深色模式），所有可点元素命中区 ≥ 44pt，行高固定不抖动。
//

import SwiftUI

// MARK: - 目标上下文

/// 长按面板的上下文：标的 + 所在分组（行情页为 nil）+ 是否行情页
struct FavoritesRowMenuTarget: Identifiable, Equatable {
    let meta: MetaItem
    let groupID: UUID?
    let isMarketPage: Bool
    var id: Int { meta.id }
}

// MARK: - 动作

/// 面板动作（`.addToGroup` 自选页叫「加入其它分组」、行情页叫「加入指定分组」；
/// `.removeFromGroup` 仅编辑态手动分组列表用：只移出当前分组，保留其它分组）
enum FavoritesRowMenuAction: String, Identifiable {
    case togglePin
    case moveToFirst
    case moveToLast
    case addToGroup
    /// 进入批量编辑（多选）态：自选页进编辑态、行情页进批量态，并把当前长按的这只预选中。
    /// 已在批量态时该面板项不出现（冗余），由调用方通过 includeBatchEdit 控制
    case batchEdit
    case note
    case toggleAlert
    case toggleFavorite
    case removeFromGroup

    var id: String { rawValue }
}

// MARK: - 单项

/// 面板单项：标题 / 图标 / 是否可用 / 不可用原因 / 是否危险色 / 右侧摘要
struct FavoritesRowMenuItem: Identifiable {
    let action: FavoritesRowMenuAction
    let title: String
    let icon: String
    var enabled: Bool = true
    var reason: String? = nil
    var destructive: Bool = false
    var trailing: String? = nil

    var id: String { action.rawValue }

    /// 备注摘要：取首行并截断（面板右侧灰字预览，避免撑破 260 宽）
    static func noteSummary(_ text: String, limit: Int = 12) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        return first.count > limit ? String(first.prefix(limit)) + "…" : first
    }
}

// MARK: - 容器层浮层包装

/// 面板 / 弹窗的容器层包装：25% 黑遮罩（可点关闭）+ 居中卡片 + 统一转场与层级。
/// 自选页与行情页共用，避免两处各写一份遮罩 / 动画 / zIndex；
/// 卡片自身忽略键盘安全区（备注弹窗弹出键盘时不挤压面板）。
struct FavoritesOverlayCard<Content: View>: View {
    let onDismiss: () -> Void
    private let content: Content

    init(onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            content
        }
        .transition(.opacity)
        .zIndex(1000)
        .ignoresSafeArea(.keyboard)
    }
}

// MARK: - 长按操作面板

/// 长按操作面板：居中卡片（宽 260）= 标题行（名称 15 semibold + 代码 13 灰）+ 操作项 + 底部「取消」。
/// 每项行高 44（`contentShape` 撑满命中区）；不可用项置灰，并在其下方给一行 11pt 原因说明，
/// 避免「点了没反应」。项数多时套 `ScrollView` 并限制高度，卡片高度对同一组 items 恒定（不抖动）。
struct FavoritesRowMenuPanel: View {
    let title: String
    let subtitle: String
    let items: [FavoritesRowMenuItem]
    let onSelect: (FavoritesRowMenuAction) -> Void
    let onCancel: () -> Void

    /// 内容预估高度：每项 45（44 + 1pt 分隔线），带原因说明的项再加 21 → 决定是否需要滚动容器
    private var estimatedHeight: CGFloat {
        items.reduce(0) { $0 + 45 + (($1.enabled || $1.reason == nil) ? 0 : 21) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题行：标的名称 + 代码
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            Divider()

            if estimatedHeight > 320 {
                // 项数多（或带原因说明的项多）：限高滚动
                ScrollView { itemColumn }
                    .frame(maxHeight: 320)
            } else {
                itemColumn
            }

            Divider()
            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    // 视觉高度约 40pt，命中区补到 44pt（项目既有约定）
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 260)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private var itemColumn: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                itemRow(item)
                // 项间 1pt 分隔线（最后一项不加）
                if item.id != items.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    /// 单项：主行固定 44 高（图标 20 宽对齐 + 标题 + 右侧灰字摘要）；不可用项在下方补原因行
    private func itemRow(_ item: FavoritesRowMenuItem) -> some View {
        Button {
            guard item.enabled else { return }
            onSelect(item.action)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 15))
                        .frame(width: 20)
                    Text(item.title)
                        .font(.system(size: 15))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let trailing = item.trailing {
                        Text(trailing)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                }
                .foregroundColor(mainColor(item))
                .frame(height: 44)

                if !item.enabled, let reason = item.reason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 30)
                        .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .accessibilityIdentifier("rowMenu.\(item.action.rawValue)")
    }

    /// 主行颜色：危险项红、可用项主色、不可用项置灰（原因行固定用 secondary）
    private func mainColor(_ item: FavoritesRowMenuItem) -> Color {
        guard item.enabled else { return Color(.tertiaryLabel) }
        return item.destructive ? Color(.systemRed) : Color.primary
    }
}

// MARK: - 备注弹窗

/// 备注弹窗（全局备注：手动分组 / 公式分组 /「全部」/ 行情页共用同一条）：
/// 标题「备注 · 名称 代码」+ 固定高 120 的输入区（TextEditor + 自绘边框 + 空态占位）
/// + 底部「清空 / 取消 / 保存」。清空 = 删除该 key（不存空串），保存 = 去首尾空白后落盘。
/// 批量备注复用同一套视觉，仅用 `titleOverride` 换标题（「批量备注 · N 只」）——不复制第二套弹窗。
struct FavoritesNoteSheet: View {
    let meta: MetaItem
    let initialText: String
    /// 非 nil = 覆盖标题（批量备注用）；nil = 「备注 · 名称 代码」
    let titleOverride: String?
    let onSave: (String) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(meta: MetaItem,
         initialText: String,
         titleOverride: String? = nil,
         onSave: @escaping (String) -> Void,
         onClear: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.meta = meta
        self.initialText = initialText
        self.titleOverride = titleOverride
        self.onSave = onSave
        self.onClear = onClear
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(titleOverride ?? "备注 · \(meta.name) \(meta.displayCode)")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Divider()

            // 输入区：固定高 120（行高不随内容变化），空备注显示占位提示
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .frame(height: 120)
                    .padding(6)
                if text.isEmpty {
                    Text("写点什么都行：买点 / 止损 / 关注理由")
                        .font(.system(size: 13))
                        .foregroundColor(Color(.tertiaryLabel))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(.separator), lineWidth: 1))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            HStack(spacing: 0) {
                dialogButton("清空", color: .secondary) { onClear() }
                Spacer(minLength: 0)
                dialogButton("取消", color: .secondary) { onCancel() }
                dialogButton("保存", color: .blue, bold: true) { onSave(text) }
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
        }
        .frame(width: 320)
        .background(Color(.systemBackground))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    /// 弹窗按钮：视觉内边距 + 44 高命中区
    private func dialogButton(_ title: String, color: Color, bold: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: bold ? .semibold : .regular))
                .foregroundColor(color)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 预警弹窗（单只「设置预警」与批量预警共用）

/// 预警设置弹窗：规则分段（上穿 / 下穿）+ 触发价输入（数字键盘），底部「设置预警 / 应用到 N 只」。
/// 数值非法（空 / 非数字 / ≤ 0）时按钮置灰；触发后不下单、不校验持仓，只在预警记录里查看。
/// 创建走 `FavoritesAlertKit.setAlerts` → `SimStore.createAlertOrder`（alertOnly = true），
/// 不复制第二套条件单表单 / 创建逻辑。
struct FavoritesBatchAlertSheet: View {
    /// 应用到的标的（1 只 = 面板单只「设置预警」；多只 = 批量预警）
    let metas: [MetaItem]
    let onApply: (_ compareUp: Bool, _ triggerPrice: Double) -> Void
    let onCancel: () -> Void

    @State private var compareUp = true
    @State private var valueText = ""

    private var count: Int { metas.count }

    /// 副标题：单只给「名称 代码」，批量给「共 N 只」
    private var subtitle: String {
        if count == 1, let one = metas.first { return "\(one.name) \(one.displayCode)" }
        return "共 \(count) 只"
    }

    /// 触发价：必须为 > 0 的数字
    private var triggerPrice: Double? {
        let raw = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(raw), value > 0 else { return nil }
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(count > 1 ? "批量设置预警" : "设置预警")
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("触发规则")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                HStack(spacing: 2) {
                    segment("上穿", active: compareUp) { compareUp = true }
                    segment("下穿", active: !compareUp) { compareUp = false }
                }
                .background(Color(.systemGray6))
                .cornerRadius(10)

                Text("触发价")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
                TextField("如 15.80", text: $valueText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 15, design: .monospaced))
                    .frame(height: 44)
                    .padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(.separator), lineWidth: 1))

                Text("触发后不下单、不校验持仓，只在「预警记录」里查看")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                dialogButton("取消", color: .secondary) { onCancel() }
                dialogButton(count > 1 ? "应用到 \(count) 只" : "设置预警",
                             color: triggerPrice == nil ? Color(.tertiaryLabel) : .blue,
                             bold: true) {
                    guard let price = triggerPrice else { return }
                    onApply(compareUp, price)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
        }
        .frame(width: 320)
        .background(Color(.systemBackground))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    /// 分段按钮：与行情页 / 自选页同类分段切换一致（视觉 36pt，纵向补 4pt → 命中 44pt）
    private func segment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(active ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.blue : Color.clear))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 弹窗按钮：合法数值才可点（非法时置灰 + 不用 disabled 避免吞掉命中区）
    private func dialogButton(_ title: String, color: Color, bold: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: bold ? .semibold : .regular))
                .foregroundColor(color)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 批量编辑：底部批量条

/// 批量动作（10 项，与 figma 屏 2 的动作序列一致）
enum FavoritesBatchAction: String, Identifiable {
    case removeFromGroup     // 手动组 =「移出」；「全部」虚拟组 =「取消自选」
    case moveToGroup
    case pin
    case unpin
    case setNote
    case clearNote
    case setAlert
    case cancelAlert
    case selectAll
    case deselectAll

    var id: String { rawValue }
}

/// 批量条单项：动作 / 标题 / 图标 / 是否可用 / 不可用原因（不可用原因在条上统一显示一行）
struct FavoritesBatchItem: Identifiable {
    let action: FavoritesBatchAction
    let title: String
    let icon: String
    var enabled: Bool = true
    var reason: String? = nil

    var id: String { action.rawValue }
}

/// 批量备注弹窗载体：打开瞬间快照选中标的（弹窗期间的列表 / 选择变化不影响本次动作）
struct BatchNoteTarget: Identifiable {
    let metas: [MetaItem]
    var id: Int { metas.first?.id ?? -1 }
    var count: Int { metas.count }
}

/// 批量预警弹窗载体（面板单只「设置预警」也走它，count == 1）
struct BatchAlertTarget: Identifiable {
    let metas: [MetaItem]
    var id: Int { metas.first?.id ?? -1 }
    var count: Int { metas.count }
}

/// 批量条通用条目（自选页 / 行情页共用同一套视觉）：id 由各页的动作 rawValue 提供，
/// 点击后原样回传，调用方再映射回自己的动作枚举 —— 这样两页只共用「画法」、不共用动作类型
struct BatchBarEntry: Identifiable {
    let id: String
    let title: String
    let icon: String
    var enabled: Bool = true
    /// 不可用原因（只取首个带原因项在条上显示一行说明）
    var reason: String? = nil
}

/// 底部批量条（纯展示，自选页 / 行情页共用）：左侧可选「完成」+「已选 N 只」（固定宽，
/// 数量位数变化不推挤按钮）+ 右侧横向可滚动作按钮。
/// 高 56 + 1pt 分隔线；另加一行 11pt 原因说明（与上下文绑定，不随选择数量抖动）。
/// 按钮观感与行情页 `MarketToolButton` 同款（`systemGray6` 胶囊 + 蓝色前景、命中区 44pt），
/// 不可用时置灰并 `.disabled`。挂在批量列表下方 → 四档布局与 C 档卡片形态共用同一处。
struct BatchActionBar: View {
    let entries: [BatchBarEntry]
    let countText: String
    /// 是否在计数左侧常驻一个「完成」按钮（行情页批量态没有工具栏开关，靠它退出）
    var showsDone: Bool = false
    var onDone: () -> Void = {}
    let onSelect: (String) -> Void

    /// 置灰项的说明（只取首个带原因项，避免重复多行）
    private var reasonText: String? { entries.compactMap { $0.reason }.first }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let reason = reasonText {
                HStack(spacing: 0) {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 20)
            }
            HStack(spacing: 10) {
                // 「完成」槽位：不显示时留空分支，不占位、不产生额外 spacing
                if showsDone {
                    Button(action: onDone) {
                        Text("完成")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color(.systemGray6))
                            .cornerRadius(7)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityIdentifier("market.batchBar.done")
                }
                Text(countText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    // 固定宽：数量从 1 位变 3 位时右侧按钮不位移（不抖动）
                    .frame(width: 86, alignment: .leading)
                    .accessibilityIdentifier("batch.count")
                Divider().frame(height: 22)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(entries) { entry in
                            barButton(entry)
                        }
                    }
                    .padding(.trailing, 12)
                }
                .accessibilityIdentifier("batch.actions")
            }
            .padding(.leading, 12)
            .frame(height: 56)
        }
        .background(Color(.systemBackground))
    }

    /// 动作按钮：图标 + 文字 12pt、systemGray6 胶囊、44pt 命中区（观感对齐 MarketToolButton）
    private func barButton(_ entry: BatchBarEntry) -> some View {
        Button {
            onSelect(entry.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: entry.icon).font(.system(size: 12, weight: .medium))
                Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundColor(entry.enabled ? .blue : Color(.tertiaryLabel))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(.systemGray6))
            .cornerRadius(7)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.enabled)
        .fixedSize()
        .accessibilityIdentifier("batch.\(entry.id)")
    }
}

/// 自选页批量条：`BatchActionBar` 的薄适配层（对外 API 与调用点零改动）
struct FavoritesBatchBar: View {
    @ObservedObject var model: FavoritesPageModel

    private var items: [FavoritesBatchItem] { model.batchBarItems() }

    private var countText: String {
        model.batchSelection.isEmpty ? "未选择" : "已选 \(model.batchSelection.count) 只"
    }

    var body: some View {
        BatchActionBar(entries: items.map {
            BatchBarEntry(id: $0.action.rawValue, title: $0.title, icon: $0.icon,
                          enabled: $0.enabled, reason: $0.reason)
        }, countText: countText) { raw in
            guard let action = FavoritesBatchAction(rawValue: raw) else { return }
            model.performBatch(action)
        }
    }
}

// MARK: - 预警胶水（自选页 / 行情页共用）

/// 预警相关胶水：账户选择、已有预警查询、取消与创建（创建走 `SimStore.createAlertOrder` 薄封装）。
/// 约定：只在 @MainActor 上下文调用（SimStore 为 @MainActor 类型）。
@MainActor
enum FavoritesAlertKit {

    /// 预警用账户：优先当前选中账户，其次首个未归档账户（都为 nil 则无法创建预警）
    static var accountID: UUID? {
        let store = SimStore.shared
        if let selected = store.selectedAccountID, store.account(id: selected) != nil {
            return selected
        }
        return store.activeAccounts.first?.id
    }

    /// 该标的当前监控中的「仅提醒」条件单（nil = 未设置预警）
    static func activeAlert(metaID: Int) -> SimCondOrder? {
        SimStore.shared.conditionalOrders.first {
            $0.metaID == metaID && $0.directive.isAlertOnly && $0.status == .monitoring
        }
    }

    static func hasAlert(metaID: Int) -> Bool {
        activeAlert(metaID: metaID) != nil
    }

    /// 取消预警：删除该标的的提醒型条件单（仅监控中的；已触发 / 已失效的不再纳入）
    static func cancelAlerts(metaID: Int) {
        let store = SimStore.shared
        let ids = store.conditionalOrders
            .filter { $0.metaID == metaID && $0.directive.isAlertOnly && $0.status == .monitoring }
            .map(\.id)
        for id in ids { store.deleteCondOrder(id: id) }
    }

    /// 设置预警：为每只标的创建同规则的 alertOnly 条件单（价格上穿 / 下穿）；
    /// 单个标的失败只记日志并继续处理其余标的（批量动作不因个别失败中断），
    /// 返回首个失败原因（全部成功返回 nil）供调用方按需使用。
    @discardableResult
    static func setAlerts(metas: [MetaItem], compareUp: Bool, triggerPrice: Double) -> String? {
        guard let accID = accountID else { return "请先创建模拟账户" }
        let store = SimStore.shared
        var firstError: String?
        for meta in metas {
            let result = store.createAlertOrder(accountID: accID, metaID: meta.id,
                                                code: meta.code, name: meta.name,
                                                compareUp: compareUp, triggerPrice: triggerPrice)
            if case .failure(let rejection) = result {
                DebugLogger.shared.log("[FavoritesAlert] \(meta.name) 预警创建失败：\(rejection.message)")
                if firstError == nil { firstError = rejection.message }
            }
        }
        return firstError
    }
}

// MARK: - 「无分组上下文」行菜单（行情页 / 搜索页共用）

/// 没有分组上下文的长按面板逻辑：行情页与搜索页共用同一份口径
/// （面板项与顺序、不可用原因、动作落点），避免两处各写一份。
/// 自选页有分组口径（固顶 / 移前移后 / 从分组移除），仍走 `FavoritesPageKit.rowMenuItems`。
@MainActor
enum MetaRowMenuKit {

    /// 面板项：加自选 / 取消自选、固定 / 取消固定、加入指定分组、（可选）批量编辑、备注…、设置 / 取消预警
    /// - Parameter includeBatchEdit: 是否出现「批量编辑」。默认 false —— 搜索页与行情页共用本方法，
    ///   而搜索页没有批量态（出现即点了没反应）；行情页传 true，且已在批量态时传 false（冗余项）
    static func items(for meta: MetaItem, includeBatchEdit: Bool = false) -> [FavoritesRowMenuItem] {
        let fav = FavoritesStore.shared
        let faved = fav.isFavorited(meta.id)
        let pinned = fav.isPinned(meta.id)
        var items: [FavoritesRowMenuItem] = [
            FavoritesRowMenuItem(action: .togglePin,
                                 title: pinned ? "取消固定" : "固定",
                                 icon: pinned ? "pin.slash" : "pin.fill"),
            FavoritesRowMenuItem(action: .toggleFavorite,
                                 title: faved ? "取消自选" : "加自选",
                                 icon: faved ? "star.slash" : "star"),
            FavoritesRowMenuItem(action: .addToGroup, title: "加入指定分组",
                                 icon: "folder.badge.plus")
        ]
        // 批量编辑入口：插在「加入指定分组」之后、备注之前 —— 面板项多时会进 320pt 滚动容器，
        // 放末尾可能要先滚动才看得见
        if includeBatchEdit {
            items.append(FavoritesRowMenuItem(action: .batchEdit, title: "批量编辑",
                                              icon: "checklist"))
        }
        let note = fav.note(for: meta.id)
        items.append(FavoritesRowMenuItem(action: .note, title: "备注…", icon: "note.text",
                                          trailing: note.map { FavoritesRowMenuItem.noteSummary($0) }))
        let hasAlert = FavoritesAlertKit.hasAlert(metaID: meta.id)
        let canAlert = hasAlert || FavoritesAlertKit.accountID != nil
        items.append(FavoritesRowMenuItem(action: .toggleAlert,
                                          title: hasAlert ? "取消预警" : "设置预警",
                                          icon: hasAlert ? "bell.slash" : "bell",
                                          enabled: canAlert,
                                          reason: canAlert ? nil : "请先在模拟页创建账户"))
        return items
    }

    /// 需要弹窗 / 需要调用方接管状态的动作交回调用方（调用方据此写自己的浮层目标）
    enum Outcome {
        case addToGroup(MetaItem)
        case note(FavoritesRowMenuTarget)
        case alert(MetaItem)
        /// 进入批量编辑态并预选该标的（携带 metaID）
        case batchEdit(Int)
    }

    /// 执行面板动作（面板已在调用处关闭）；就地完成的动作返回 nil
    static func perform(_ action: FavoritesRowMenuAction,
                        for target: FavoritesRowMenuTarget) -> Outcome? {
        let meta = target.meta
        switch action {
        case .togglePin:
            let fav = FavoritesStore.shared
            if fav.isPinned(meta.id) {
                fav.unpin(meta.id)
            } else {
                fav.pin(meta.id)
            }
            return nil
        case .toggleFavorite:
            FavoritesStore.shared.toggleFavorite(meta.id)
            return nil
        case .addToGroup:
            return .addToGroup(meta)
        case .batchEdit:
            return .batchEdit(meta.id)
        case .note:
            return .note(target)
        case .toggleAlert:
            if FavoritesAlertKit.hasAlert(metaID: meta.id) {
                FavoritesAlertKit.cancelAlerts(metaID: meta.id)
                return nil
            }
            return .alert(meta)
        case .moveToFirst, .moveToLast, .removeFromGroup:
            // 无分组上下文：这几项不会出现在面板里，防御性忽略
            return nil
        }
    }
}