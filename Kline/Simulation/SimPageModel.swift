//
//  SimPageModel.swift
//  Kline
//
//  模拟页配置驱动渲染（JSON 布局）的页面模型与上下文。
//
//  与首页同构（见 HomeLayoutContext.swift / HomeView.swift）：
//  - 控件（sim.* widget）只读数据与状态，不持交互状态、不直接呈现浮层；
//  - 页面级 UI 状态（当前模块 / 搜索词 / 日志筛选 / 各浮层与弹窗 / 抽屉 / 轻提示）
//    统一收敛在 `SimulationPageModel`，由容器 SimulationView 的配置宿主
//    （SimConfigHost）统一挂 fullScreenCover / alert / toast 呈现；
//  - 数据一律读 `SimStore.shared`（各 widget 自行观察，与本模型无关）。
//
//  业务动作（下单 / 改价 / 新建账户 / 刷新 / 导出日志）从既有 A/B/C 布局视图
//  原样搬迁，行为口径不变，供 fallback（硬编码布局）与配置驱动两条路径共用。
//

import Foundation
import Combine
import SwiftUI

// MARK: - 配置驱动渲染的上下文

/// 模拟页配置驱动渲染的上下文：只携带页面状态模型（数据走 SimStore 单例）
struct SimLayoutContext {
    let model: SimulationPageModel
}

// MARK: - 页面状态模型

/// 模拟页配置驱动渲染的页面状态模型（容器 @StateObject 持有，下发给各 widget）
@MainActor
final class SimulationPageModel: ObservableObject {

    // MARK: 页面 UI 状态

    /// 当前业务模块（模块分段控件 / 业务表 / 日志筛选条共用）
    @Published var module: SimModuleTab = .position
    /// 搜索词（业务表标的过滤；日志模块时过滤操作内容）
    @Published var keyword: String = ""
    /// 操作日志模块筛选（nil = 全部；仅日志模块的筛选条用）
    @Published var logModule: ActionModule? = nil
    /// 工作区轻提示（2 秒后自动消失）
    @Published var toast: String? = nil
    /// 紧凑态账户抽屉开关（A 方案锚点行 / 抽屉 overlay 共用）
    @Published var accountDrawerActive = false
    /// 侧栏底部提示（交易规则 / 账户管理说明，A 方案侧栏用）
    @Published var sidebarHint: String? = nil

    // MARK: 浮层 / 弹窗（容器统一挂载）

    /// 全屏下单请求（每次新建都换新 UUID，保证可重复呈现）
    @Published var ticketRequest: SimTicketRequest? = nil
    /// 条件单呈现请求（工具栏入口 → 管理页；持仓行入口 → 编辑器）
    @Published var condPresentation: SimCondEntryRequest? = nil
    /// 全屏模块明细页（B 方案模块宫格 → 明细）
    @Published var detailModule: SimModuleTab? = nil
    /// 公式管理中心（「交易策略」段）开合
    @Published var showStrategyFormulas = false
    /// 「训练记录」管理页开合
    @Published var showTrainingRecords = false
    /// 新建账户弹窗
    @Published var showCreateAccount = false
    @Published var newAccountName = ""
    @Published var newAccountCapital = "100000"
    /// 交易规则弹窗（C 顶栏「设置」等入口）
    @Published var showRulesAlert = false
    /// 资金管理弹窗（B/C 顶栏「资金管理」入口）
    @Published var showWalletAlert = false
    /// 改价目标委托与输入
    @Published var amendTarget: SimOrder? = nil
    @Published var amendPriceText = ""

    private var db: DatabaseManager { DatabaseManager.shared }

    // MARK: - 常量文案（与既有 A/B/C 布局逐字一致）

    static let rulesText = """
    T+1：当日买入次日可卖
    佣金万 2.5，最低 5 元
    卖出印花税千一
    涨跌停 ±10%
    盘后委托转为待报
    """

    static let accountHelpText = "账户管理：点「＋ 新建账户」创建账户；选中账户后在右侧工作区下单、查看流水与日志。"

    // MARK: - 下单入口（搬迁自 A / B / C 布局视图，行为口径不变）

    /// 下单账户：具体账户优先；「全部账户汇总」时取第一个可用账户
    var orderAccountID: UUID? {
        let store = SimStore.shared
        if let id = store.queryAccountID, store.account(id: id) != nil { return id }
        return store.activeAccounts.first?.id
    }

    /// 下单标的：优先当前账户第一只持仓，无持仓时取数据库第一只可用标的
    func defaultTarget(accountID: UUID) -> (metaID: Int, code: String, name: String)? {
        if let position = SimStore.shared.positions(accountID: accountID).first {
            return (position.metaID, position.code, position.name)
        }
        if let meta = db.metaList.first(where: { !$0.code.isEmpty }) {
            return (meta.id, meta.code, meta.name)
        }
        return nil
    }

    func openTicket(accountID: UUID, metaID: Int, code: String, name: String,
                    direction: SimOrderDirection) {
        ticketRequest = SimTicketRequest(accountID: accountID, metaID: metaID,
                                         code: code, name: name, direction: direction)
    }

    /// 底部买卖条 / 顶栏快捷下单：先解析账户与标的，无可用时轻提示
    func openBottomTicket(_ direction: SimOrderDirection) {
        guard let accountID = orderAccountID else {
            showToast("请先新建一个模拟账户")
            return
        }
        guard let target = defaultTarget(accountID: accountID) else {
            showToast("暂无可用标的，无法下单")
            return
        }
        openTicket(accountID: accountID, metaID: target.metaID, code: target.code,
                   name: target.name, direction: direction)
    }

    /// 持仓行「条件单」入口：默认止盈止损 / 卖出，数量取可卖整手，基准价预填成本价
    func openCondEditor(for position: SimPosition) {
        let projection = SimTradeRulesProjection.shared
        Task {
            // 可卖数量走引擎（动作路径直接 await，避免 `nil` 预填成 1 手）
            let qty = await projection.sellableQtyAsync(position: position) ?? 0
            condPresentation = .editor(SimCondEditorRequest(accountID: position.accountID,
                                                            metaID: position.metaID,
                                                            code: position.code,
                                                            name: position.name,
                                                            initialKind: .stopLoss,
                                                            initialDirection: .sell,
                                                            initialQty: qty > 0 ? qty : projection.lotSize,
                                                            initialPrice: position.costPrice,
                                                            editing: nil))
        }
    }

    // MARK: - 改价

    var amendBinding: Binding<Bool> {
        Binding(get: { [weak self] in self?.amendTarget != nil },
                set: { [weak self] newValue in
                    guard let self else { return }
                    if !newValue { self.amendTarget = nil }
                })
    }

    /// 改价弹窗正文（当前委托摘要）
    var amendMessage: String {
        amendTarget.map {
            "\($0.name) \($0.code) · 当前 \($0.price.map { SimFormat.price($0) } ?? "市价")"
        } ?? ""
    }

    func beginAmend(_ order: SimOrder) {
        amendPriceText = order.price.map { SimFormat.price($0) } ?? ""
        amendTarget = order
    }

    func confirmAmend() async {
        guard let order = amendTarget else { return }
        let price = Double(amendPriceText.filter { $0.isNumber || $0 == "." }) ?? 0
        guard price > 0 else {
            showToast("请输入有效的委托价")
            return
        }
        await SimStore.shared.amendOrderPrice(id: order.id, newPrice: price)
        amendTarget = nil
        showToast("已改价：\(order.name) → \(SimFormat.price(price))")
    }

    // MARK: - 账户与行情

    func createAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let capital = Double(newAccountCapital.filter { $0.isNumber || $0 == "." }) ?? 100_000
        guard capital > 0 else {
            showToast("初始资金需大于 0")
            return
        }
        Task {
            if let account = await SimStore.shared.createAccount(name: name.isEmpty ? "新账户" : name,
                                                                 initialCapital: capital) {
                SimStore.shared.selectedAccountID = account.id
                newAccountName = ""
                newAccountCapital = "100000"
                showToast("已创建账户「\(account.name)」")
            } else {
                showToast("创建账户失败，Python 引擎不可用")
            }
        }
    }

    func refreshQuotes() async {
        await SimStore.shared.prepareQuotes()
        showToast("已请求最新行情")
    }

    // MARK: - 日志导出

    /// 当前筛选条件下的日志（与业务表同一口径）
    var exportableLogs: [ActionLog] {
        let store = SimStore.shared
        var all = store.actionLogs(accountID: store.queryAccountID)
        if let filter = logModule {
            all = all.filter { $0.module == filter }
        }
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return all }
        return all.filter { $0.content.localizedCaseInsensitiveContains(key) }
    }

    /// 导出当前日志为 CSV 到 Documents/Simulation/
    func exportLogs() {
        let logs = exportableLogs
        guard !logs.isEmpty else {
            showToast("当前没有可导出的操作日志")
            return
        }
        let header = "时间,账户,模块,操作内容,结果"
        let lines = logs.map { log -> String in
            let cells = [SimFormat.dateTime(log.occurredAt),
                         logAccountName(log.accountID),
                         log.module.title,
                         log.content,
                         log.result]
            return cells.map(csvCell).joined(separator: ",")
        }
        let content = ([header] + lines).joined(separator: "\n")

        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            showToast("导出失败：无法访问 Documents 目录")
            return
        }
        let dir = docs.appendingPathComponent("Simulation", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "sim_logs_\(formatter.string(from: Date())).csv"
        do {
            try content.write(to: dir.appendingPathComponent(fileName),
                              atomically: true, encoding: .utf8)
            showToast("已导出 \(logs.count) 条日志 → Documents/Simulation/\(fileName)")
        } catch {
            showToast("导出失败：\(error.localizedDescription)")
        }
    }

    private func csvCell(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func logAccountName(_ id: UUID?) -> String {
        guard let id = id else { return "系统" }
        return SimStore.shared.accountName(id: id)
    }

    // MARK: - 轻提示

    /// 工作区轻提示：2 秒后自动消失
    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}
