//
//  SimulationView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/20 改为按布局偏好分发（A / B / C），A 为账户侧栏 + 工作区。
//  2026/10 改为「JSON 配置优先」：按 `TradingLayoutStore.simulationLayout` 档位，
//  取 `PageLayoutConfigStore` 中该档位的节点树渲染（与首页 HomeView 同一范式）；
//  配置不可用（或该档位缺失且无 default）时回落 A/B/C 硬编码布局视图（保底）。
//  内置默认配置在 SimulationLayoutDefaults.swift，首启种入沙盒 Documents/Layouts/simulation.json。
//  页面级 UI 状态与浮层由 SimulationPageModel + SimConfigHost 统一持有与呈现。
//

import SwiftUI

struct SimulationView: View {
    @ObservedObject private var layoutStore = TradingLayoutStore.shared
    /// 页面 JSON 布局配置仓库（已解码好的结果，body 内不做解码 / 遍历）
    @ObservedObject private var layoutConfig = PageLayoutConfigStore.shared
    /// 配置驱动渲染共享的页面状态模型（浮层 / 弹窗 / 模块切换等）
    @StateObject private var model = SimulationPageModel()

    var body: some View {
        VStack(spacing: 0) {
            // 顶部菜单栏
            HStack {
                Spacer()
                // 当前布局指示（同时是既有 UITest 的锚点，标识不可改）
                Text("模拟页 · 方案 \(layoutStore.simulationLayout.shortTitle)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.tertiaryLabel))
                    .accessibilityIdentifier("simulation.subtitle")
            }
            .background(Color(.systemBackground))
            .frame(height: 56)
            .padding(.top, -5)
            .padding(.trailing, 16)

            // 分隔线
            Divider()

            Group {
                if let root = configRoot() {
                    // JSON 配置优先：按当前档位的节点树渲染
                    SimConfigHost(model: model, root: root)
                } else {
                    // 配置不可用 → 回落硬编码布局视图（保底）：
                    // A 账户侧栏 / B 账户卡片宫格 / C 券商经典顶栏
                    switch layoutStore.simulationLayout {
                    case .a: SimulationLayoutAView()
                    case .b: SimulationLayoutBView()
                    case .c: SimulationLayoutCView()
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        // 内容延伸到物理屏幕底边 + 背景铺满（避免底部露出下层导航栏）
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            // 注册内置默认（幂等）后按需重载：沙盒 Documents/Layouts/simulation.json 变化即时生效
            PageLayoutConfigStore.shared.registerBuiltInDefaults(
                page: PageLayoutConfigStore.simulationPage,
                json: simulationLayoutDefaultsJSON)
            PageLayoutConfigStore.shared.reloadIfChanged(page: PageLayoutConfigStore.simulationPage)
            Task { await SimStore.shared.prepareQuotes() }
        }
    }

    /// 当前档位在 JSON 配置里对应的节点树根；
    /// 配置不可用 / 档位缺失（且配置里没有 default 兜底）时返回 nil，交给硬编码布局视图
    private func configRoot() -> PageLayoutNode? {
        layoutConfig.layout(id: layoutStore.simulationLayout.rawValue,
                            for: PageLayoutConfigStore.simulationPage)?.root
    }
}

// MARK: - 配置驱动渲染宿主

/// 按节点树渲染模拟页 + 统一挂载页面级浮层（fullScreenCover / alert / 抽屉 / 轻提示）。
/// widget 只回调模型，不自己呈现浮层；本宿主是配置分支唯一的浮层挂载点。
private struct SimConfigHost: View {
    @ObservedObject var model: SimulationPageModel
    let root: PageLayoutNode

    @ObservedObject private var store = SimStore.shared

    /// 顶层测宽（WidthReader 只允许在页面顶层包裹，见其文档）：
    /// 主要是为了把实测可用宽注入 `\.klineAvailableWidth` 环境，
    /// 供各 sim.* widget 的 `@CompactWidthValue` 统一判定紧凑形态。
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        WidthReader(onChange: { availableWidth = $0 }) {
            Group {
                PageLayoutRenderer(registry: SimWidgetRegistry.shared.registry,
                                   context: SimLayoutContext(model: model))
                    .view(for: root)
            }
            // 紧凑态账户抽屉（A 方案侧栏收纳）：容器 overlay 呈现，
            // 与原 A 布局同款交互；宽屏或非 A 配置不会置位开关，无副作用
            .overlay {
                if model.accountDrawerActive {
                    SimAccountDrawerView(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.accountDrawerActive)
            .overlay(alignment: .top) { toastView }
            // 公式管理中心（「交易策略」段）：全屏页面挂在宿主最外层 overlay，
            // 避免被工作区表格 / 侧栏裁剪；关闭走页内「返回」
            .overlay {
                if model.showStrategyFormulas {
                    ZStack {
                        FormulaCenterView(initialKind: .strategy,
                                          onClose: { model.showStrategyFormulas = false })
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
            .simFullScreenTicket($model.ticketRequest)
            .fullScreenCover(item: $model.detailModule) { module in
                SimModuleDetailSheet(module: module,
                                     accountID: store.queryAccountID,
                                     onClose: { model.detailModule = nil })
            }
            // 条件单呈现（工具栏入口 → 管理页；持仓行入口 → 编辑器）：单一呈现状态收敛
            .simCondEntryPresentation($model.condPresentation, accountID: store.queryAccountID)
            // 「训练记录」管理页：独立宿主，与全屏下单页 / 明细页分开挂载
            .simTrainingRecordPresentation($model.showTrainingRecords)
            // 弹窗统一挂宿主（新建账户 / 改价 / 交易规则 / 资金管理），与原布局同文案
            .alert("新建账户", isPresented: $model.showCreateAccount) {
                TextField("账户名称", text: $model.newAccountName)
                TextField("初始资金", text: $model.newAccountCapital)
                    .keyboardType(.decimalPad)
                Button("创建") { model.createAccount() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("初始资金默认 100000 元，创建后自动选中该账户。")
            }
            .alert("修改委托价", isPresented: model.amendBinding) {
                TextField("委托价", text: $model.amendPriceText)
                    .keyboardType(.decimalPad)
                Button("确认") { Task { await model.confirmAmend() } }
                Button("取消", role: .cancel) { model.amendTarget = nil }
            } message: {
                Text(model.amendMessage)
            }
            .alert("交易规则", isPresented: $model.showRulesAlert) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(SimulationPageModel.rulesText)
            }
            .alert("资金管理", isPresented: $model.showWalletAlert) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(walletMessage)
            }
            // 旋转跨过 600 阈值（竖屏 ↔ 横屏）：抽屉随紧凑态消失，
            // 复位开关避免转回窄屏时抽屉残留展开（与原 A 布局同口径）
            .onChange(of: availableWidth) { width in
                if !CompactWidth.isCompact(width) { model.accountDrawerActive = false }
            }
        }
    }

    /// 资金管理弹窗文案：当前选中口径的资产概览（与 B 布局顶栏同款）
    private var walletMessage: String {
        let summary = store.summary(accountID: store.queryAccountID)
        let name = store.accountName(id: store.queryAccountID)
        return """
        \(name)
        总资产 \(SimFormat.amount0(summary.totalAssets)) 元
        可用资金 \(SimFormat.amount0(summary.cash)) 元
        持仓市值 \(SimFormat.amount0(summary.marketValue)) 元
        持仓占比 \(SimFormat.pct(summary.positionPct * 100))
        当日盈亏 \(SimFormat.signed0(summary.dayProfit)) 元
        累计盈亏 \(SimFormat.signed0(summary.totalProfit)) 元
        """
    }

    /// 工作区轻提示（2 秒后自动消失；model.showToast 负责消失）
    @ViewBuilder
    private var toastView: some View {
        if let text = model.toast {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
                .padding(.top, 6)
        }
    }
}

#Preview {
    SimulationView()
}
