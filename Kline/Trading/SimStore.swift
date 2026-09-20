//
//  SimStore.swift
//  Kline
//
//  模拟交易总仓库：账户 / 持仓 / 委托 / 成交 / 资金流水 / 操作日志六类数据的
//  唯一写入口，负责落盘（Documents/Simulation/sim.json）、首次播种、下单撮合、
//  撤单改价、一键平仓与账户资金操作，并提供给视图的聚合查询与汇总口径。
//  约定：所有写操作先比较值再赋值（同值赋值同样会触发 @Published 发布风暴），
//  校验失败（SimTradingRules）一律不写任何数据。
//

import Foundation
import Combine

// MARK: - 持久化根结构

/// sim.json 的根结构（字段缺失或类型不符时逐项兜底为空，不使读档整体失败）
private struct SimRoot: Codable {
    var schemaVersion: Int
    var accounts: [SimAccount]
    var positions: [SimPosition]
    var orders: [SimOrder]
    var fills: [SimFill]
    var ledger: [LedgerEntry]
    var logs: [ActionLog]
    var conditionalOrders: [SimCondOrder]
    var selectedAccountID: UUID?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, accounts, positions, orders, fills, ledger, logs
        case conditionalOrders, selectedAccountID
    }

    init(schemaVersion: Int, accounts: [SimAccount], positions: [SimPosition],
         orders: [SimOrder], fills: [SimFill], ledger: [LedgerEntry],
         logs: [ActionLog], conditionalOrders: [SimCondOrder], selectedAccountID: UUID?) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.positions = positions
        self.orders = orders
        self.fills = fills
        self.ledger = ledger
        self.logs = logs
        self.conditionalOrders = conditionalOrders
        self.selectedAccountID = selectedAccountID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        accounts = (try? c.decode([SimAccount].self, forKey: .accounts)) ?? []
        positions = (try? c.decode([SimPosition].self, forKey: .positions)) ?? []
        orders = (try? c.decode([SimOrder].self, forKey: .orders)) ?? []
        fills = (try? c.decode([SimFill].self, forKey: .fills)) ?? []
        ledger = (try? c.decode([LedgerEntry].self, forKey: .ledger)) ?? []
        logs = (try? c.decode([ActionLog].self, forKey: .logs)) ?? []
        conditionalOrders = (try? c.decode([SimCondOrder].self, forKey: .conditionalOrders)) ?? []
        selectedAccountID = try? c.decode(UUID.self, forKey: .selectedAccountID)
    }
}

// MARK: - Store

@MainActor
final class SimStore: ObservableObject {
    static let shared = SimStore()

    /// 「全部账户汇总」虚拟账户 id（不是 accounts 里的实体，仅作选中标识）
    static let allAccountID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!

    // MARK: 数据（外部只读）

    @Published private(set) var accounts: [SimAccount] = []
    @Published private(set) var positions: [SimPosition] = []
    @Published private(set) var orders: [SimOrder] = []
    @Published private(set) var fills: [SimFill] = []
    @Published private(set) var ledger: [LedgerEntry] = []
    @Published private(set) var logs: [ActionLog] = []
    @Published private(set) var conditionalOrders: [SimCondOrder] = []

    /// 当前选中账户；nil 或 allAccountID 表示「全部账户汇总」
    @Published var selectedAccountID: UUID?

    // MARK: 内部状态

    private let fm = FileManager.default
    private let currentSchema = 2
    private let tPlus1Key = "kline.sim.lastTPlus1Refresh"

    /// 条件单结算重入保护（引擎在 SimCondEngine.swift 中读写）
    var condSweepInFlight = false

    /// 首次播种待办（仅当 sim.json 不存在时为 true）
    private var needsSeed = false
    /// 数据库就绪信号订阅
    private var databaseLoadedCancellable: AnyCancellable?

    // MARK: - Lifecycle

    private init() {
        // 只在「档案不存在」时播种；已存在（即便内容为空）绝不覆盖
        let existed = fm.fileExists(atPath: fileURL.path)
        if existed { _ = loadFromDisk() }
        needsSeed = !existed

        refreshTPlus1IfNeeded()
        observeDatabase()
    }

    // MARK: - 选中账户

    var isAllAccountsSelected: Bool {
        selectedAccountID == nil || selectedAccountID == Self.allAccountID
    }

    /// 当前选中账户对应的查询键：全部汇总时返回 nil，否则返回具体账户 id
    var queryAccountID: UUID? {
        isAllAccountsSelected ? nil : selectedAccountID
    }

    // MARK: - 读档 / 存档

    private var fileURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Simulation", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("sim.json")
    }

    @discardableResult
    private func loadFromDisk() -> Bool {
        let url = fileURL
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let root = try decoder.decode(SimRoot.self, from: data)

            assignAccounts(root.accounts)
            assignPositions(root.positions)
            assignOrders(root.orders)
            assignFills(root.fills)
            assignLedger(root.ledger)
            assignLogs(root.logs)
            assignConditionalOrders(root.conditionalOrders)

            if let sel = root.selectedAccountID,
               sel == Self.allAccountID || accounts.contains(where: { $0.id == sel }) {
                selectedAccountID = sel
            } else {
                selectedAccountID = accounts.first(where: { !$0.isArchived })?.id
            }
            return true
        } catch {
            DebugLogger.shared.log("[SimStore] load failed \(error)")
            return false
        }
    }

    func saveToDisk() {
        let root = SimRoot(schemaVersion: currentSchema,
                           accounts: accounts,
                           positions: positions,
                           orders: orders,
                           fills: fills,
                           ledger: ledger,
                           logs: logs,
                           conditionalOrders: conditionalOrders,
                           selectedAccountID: selectedAccountID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(root)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DebugLogger.shared.log("[SimStore] save failed \(error)")
        }
    }

    // MARK: - @Published 写入守卫

    private func assignAccounts(_ value: [SimAccount]) {
        if accounts != value { accounts = value }
    }

    private func assignPositions(_ value: [SimPosition]) {
        if positions != value { positions = value }
    }

    private func assignOrders(_ value: [SimOrder]) {
        if orders != value { orders = value }
    }

    private func assignFills(_ value: [SimFill]) {
        if fills != value { fills = value }
    }

    private func assignLedger(_ value: [LedgerEntry]) {
        if ledger != value { ledger = value }
    }

    private func assignLogs(_ value: [ActionLog]) {
        if logs != value { logs = value }
    }

    func assignConditionalOrders(_ value: [SimCondOrder]) {
        if conditionalOrders != value { conditionalOrders = value }
    }

    // MARK: - 首次播种

    /// 订阅 DatabaseManager 就绪信号：metaList 就绪后执行一次性播种。
    /// （init 时数据库可能尚未加载，此时 metaList 为空，无法按 code 反查 metaID）
    private func observeDatabase() {
        if DatabaseManager.shared.isLoaded && needsSeed {
            performSeed()
            needsSeed = false
        }
        databaseLoadedCancellable = DatabaseManager.shared.$isLoaded
            .filter { $0 }
            .first()
            .sink { [weak self] _ in
                guard let self = self, self.needsSeed else { return }
                self.performSeed()
                self.needsSeed = false
            }
    }

    /// 按标的代码反查 metaID（先精确匹配，再按纯数字归一化匹配，兼容 "600519.SH" / "SH600519" / "600519"）
    private func resolveMetaID(code: String) -> Int? {
        let list = DatabaseManager.shared.metaList
        if let exact = list.first(where: { $0.code == code }) { return exact.id }
        let digits = code.filter { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return list.first(where: { $0.code.filter { ch in ch.isNumber } == digits })?.id
    }

    /// 今天指定时刻（播种数据的日期锚点）
    private func todayAt(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return cal.date(from: comps) ?? Date()
    }

    /// 播种示例数据（仅在首次运行时执行一次）
    private func performSeed() {
        guard accounts.isEmpty else { return }
        let today = Calendar.current.startOfDay(for: Date())

        // ---- 账户 ----
        let main = SimAccount(id: UUID(), name: "主策略账户", badge: "主", colorHex: "#1E5FA8",
                              initialCapital: 1_000_000, cash: 259_203.50,
                              createdAt: today, isArchived: false)
        let da = SimAccount(id: UUID(), name: "打板账户", badge: "板", colorHex: "#B4282E",
                            initialCapital: 200_000, cash: 201_070.00,
                            createdAt: today, isArchived: false)
        let di = SimAccount(id: UUID(), name: "低吸账户", badge: "吸", colorHex: "#1F6E4F",
                            initialCapital: 100_000, cash: 80_280.00,
                            createdAt: today, isArchived: false)
        assignAccounts([main, da, di])

        // ---- 持仓（metaID 反查不到则跳过该行，绝不写 metaID = 0）----
        var seedPositions: [SimPosition] = []
        func addPosition(_ account: SimAccount, code: String, name: String,
                         qty: Int, available: Int, cost: Double) {
            guard let metaID = resolveMetaID(code: code) else { return }
            seedPositions.append(SimPosition(id: UUID(), accountID: account.id, metaID: metaID,
                                             code: code, name: name, qty: qty,
                                             availableQty: available, costPrice: cost, openedAt: today))
        }
        addPosition(main, code: "600519.SH", name: "贵州茅台", qty: 500, available: 500, cost: 1452.30)
        addPosition(main, code: "300750.SZ", name: "宁德时代", qty: 100, available: 100, cost: 218.40)
        addPosition(main, code: "300059.SZ", name: "东方财富", qty: 1000, available: 1000, cost: 14.92)
        addPosition(da, code: "002703.SZ", name: "浙江世宝", qty: 1000, available: 1000, cost: 13.05)
        addPosition(da, code: "600895.SH", name: "张江高科", qty: 600, available: 600, cost: 31.20)
        addPosition(di, code: "002037.SZ", name: "保利联合", qty: 2000, available: 2000, cost: 8.40)
        assignPositions(seedPositions)

        // ---- 委托 ----
        var seedOrders: [SimOrder] = []
        var maotaiOrderID: UUID?
        var eastMoneyOrderID: UUID?
        var zjsbOrderID: UUID?

        if let metaID = resolveMetaID(code: "600519.SH") {
            let t = todayAt(9, 35, 2)
            let o = SimOrder(id: UUID(), accountID: main.id, metaID: metaID, code: "600519.SH",
                             name: "贵州茅台", direction: .buy, priceType: .limit, price: 1460.00,
                             qty: 200, filledQty: 200, status: .filled, createdAt: t, updatedAt: t)
            maotaiOrderID = o.id
            seedOrders.append(o)
        }
        if let metaID = resolveMetaID(code: "300750.SZ") {
            let t = todayAt(14, 51, 8)
            seedOrders.append(SimOrder(id: UUID(), accountID: main.id, metaID: metaID, code: "300750.SZ",
                                       name: "宁德时代", direction: .sell, priceType: .limit, price: 203.00,
                                       qty: 100, filledQty: 0, status: .reported, createdAt: t, updatedAt: t))
        }
        if let metaID = resolveMetaID(code: "300059.SZ") {
            let t = todayAt(14, 52, 30)
            let o = SimOrder(id: UUID(), accountID: main.id, metaID: metaID, code: "300059.SZ",
                             name: "东方财富", direction: .buy, priceType: .market, price: nil,
                             qty: 500, filledQty: 300, status: .partial, createdAt: t, updatedAt: t)
            eastMoneyOrderID = o.id
            seedOrders.append(o)
        }
        if let metaID = resolveMetaID(code: "002703.SZ") {
            let t = todayAt(10, 2, 11)
            let o = SimOrder(id: UUID(), accountID: da.id, metaID: metaID, code: "002703.SZ",
                             name: "浙江世宝", direction: .buy, priceType: .limit, price: 13.05,
                             qty: 1000, filledQty: 1000, status: .filled, createdAt: t, updatedAt: t)
            zjsbOrderID = o.id
            seedOrders.append(o)
        }
        assignOrders(seedOrders)

        // ---- 成交 ----
        var seedFills: [SimFill] = []
        if let metaID = resolveMetaID(code: "600519.SH") {
            let t = todayAt(9, 35, 2)
            seedFills.append(SimFill(id: UUID(), orderID: maotaiOrderID ?? UUID(),
                                     accountID: main.id, metaID: metaID, code: "600519.SH",
                                     name: "贵州茅台", direction: .buy, price: 1460.00, qty: 200,
                                     amount: 292_000.00, fee: 5.00, tradedAt: t,
                                     contractNo: "20260919-001"))
        }
        if let metaID = resolveMetaID(code: "300059.SZ") {
            let t1 = todayAt(13, 20, 44)
            seedFills.append(SimFill(id: UUID(), orderID: UUID(),
                                     accountID: main.id, metaID: metaID, code: "300059.SZ",
                                     name: "东方财富", direction: .sell, price: 15.60, qty: 2000,
                                     amount: 31_200.00, fee: 37.44, tradedAt: t1,
                                     contractNo: "20260919-002"))
            let t2 = todayAt(14, 52, 30)
            seedFills.append(SimFill(id: UUID(), orderID: eastMoneyOrderID ?? UUID(),
                                     accountID: main.id, metaID: metaID, code: "300059.SZ",
                                     name: "东方财富", direction: .buy, price: 15.86, qty: 300,
                                     amount: 47_580.00, fee: 5.00, tradedAt: t2,
                                     contractNo: "20260919-003"))
        }
        if let metaID = resolveMetaID(code: "002703.SZ") {
            let t = todayAt(10, 2, 11)
            seedFills.append(SimFill(id: UUID(), orderID: zjsbOrderID ?? UUID(),
                                     accountID: da.id, metaID: metaID, code: "002703.SZ",
                                     name: "浙江世宝", direction: .buy, price: 13.05, qty: 1000,
                                     amount: 13_050.00, fee: 5.00, tradedAt: t,
                                     contractNo: "20260919-004"))
        }
        assignFills(seedFills)

        // ---- 资金流水 ----
        assignLedger([
            LedgerEntry(id: UUID(), accountID: main.id, kind: .deposit, note: "银证转账入金",
                        amount: 1_000_000.00, balanceAfter: 1_000_000.00,
                        occurredAt: todayAt(9, 31, 0)),
            LedgerEntry(id: UUID(), accountID: main.id, kind: .buy,
                        note: "买入成交 贵州茅台 200 股（含费）",
                        amount: -292_005.00, balanceAfter: 707_995.00,
                        occurredAt: todayAt(9, 35, 2)),
            LedgerEntry(id: UUID(), accountID: main.id, kind: .sell,
                        note: "卖出成交 东方财富 2,000 股（扣费 37.44）",
                        amount: 31_162.56, balanceAfter: 739_157.56,
                        occurredAt: todayAt(13, 20, 44)),
            LedgerEntry(id: UUID(), accountID: main.id, kind: .buy,
                        note: "买入成交 东方财富 300 股（含费）",
                        amount: -47_585.00, balanceAfter: 691_572.56,
                        occurredAt: todayAt(14, 52, 30)),
            LedgerEntry(id: UUID(), accountID: da.id, kind: .deposit,
                        note: "新建「打板账户」初始资金",
                        amount: 200_000.00, balanceAfter: 200_000.00,
                        occurredAt: todayAt(9, 30, 0)),
            LedgerEntry(id: UUID(), accountID: da.id, kind: .buy,
                        note: "买入成交 浙江世宝 1,000 股",
                        amount: -13_055.00, balanceAfter: 186_945.00,
                        occurredAt: todayAt(10, 2, 11))
        ])

        // ---- 操作日志 ----
        assignLogs([
            ActionLog(id: UUID(), accountID: main.id, module: .order,
                      content: "买入 东方财富 500 股 · 市价", result: "部成 300 股",
                      occurredAt: todayAt(14, 52, 30)),
            ActionLog(id: UUID(), accountID: main.id, module: .order,
                      content: "卖出 宁德时代 100 股 · 限价 203.00", result: "已报",
                      occurredAt: todayAt(14, 51, 8)),
            ActionLog(id: UUID(), accountID: main.id, module: .cancel,
                      content: "撤回「买入 东方财富 800 股 · 15.80」", result: "成功",
                      occurredAt: todayAt(14, 30, 0)),
            ActionLog(id: UUID(), accountID: main.id, module: .fill,
                      content: "卖出 东方财富 2,000 股 · 15.60，费用 37.44", result: "已成交",
                      occurredAt: todayAt(13, 20, 44)),
            ActionLog(id: UUID(), accountID: main.id, module: .fill,
                      content: "买入 贵州茅台 200 股 · 1460.00", result: "全部成交",
                      occurredAt: todayAt(9, 35, 2)),
            ActionLog(id: UUID(), accountID: da.id, module: .account,
                      content: "新建账户「打板账户」，初始资金 200,000", result: "成功",
                      occurredAt: todayAt(9, 30, 0)),
            ActionLog(id: UUID(), accountID: di.id, module: .alert,
                      content: "箱体二次探底提醒触发：保利联合 8.40（未破前低）", result: "已触发",
                      occurredAt: todayAt(10, 15, 0))
        ])

        // ---- 条件单（metaID 反查不到则跳过该条，绝不写 metaID = 0）----
        let seedNow = Date()
        var seedConds: [SimCondOrder] = []

        // 主账户 · 贵州茅台：止盈止损（OCO，长期有效）
        if let metaID = resolveMetaID(code: "600519.SH") {
            var params = SimCondParams()
            params.basePrice = 1462.30
            params.baseMode = .price
            params.takeProfitPrice = 1480.00
            params.stopLossPrice = 1420.00
            seedConds.append(SimCondOrder(id: UUID(), accountID: main.id, metaID: metaID,
                                          code: "600519.SH", name: "贵州茅台",
                                          kind: .stopLoss, params: params,
                                          directive: SimCondDirective(direction: .sell,
                                                                      priceType: .market,
                                                                      offsetTicks: 0, qty: 500),
                                          validity: .longTerm, expiresAt: nil,
                                          createdAt: seedNow, updatedAt: seedNow,
                                          status: .monitoring, runtime: SimCondRuntime(),
                                          triggeredCount: 0, triggeredAt: nil, originOrderID: nil))
        }

        // 主账户 · 宁德时代：回落卖出（当日有效，触发价 -2 档限价卖出）
        if let metaID = resolveMetaID(code: "300750.SZ") {
            var params = SimCondParams()
            params.breakoutPrice = 210.00
            params.trailPct = 3.0
            params.floorEnabled = true
            params.floorPrice = 206.00
            seedConds.append(SimCondOrder(id: UUID(), accountID: main.id, metaID: metaID,
                                          code: "300750.SZ", name: "宁德时代",
                                          kind: .trailing, params: params,
                                          directive: SimCondDirective(direction: .sell,
                                                                      priceType: .limit,
                                                                      offsetTicks: -2, qty: 100),
                                          validity: .day, expiresAt: nil,
                                          createdAt: seedNow, updatedAt: seedNow,
                                          status: .monitoring, runtime: SimCondRuntime(),
                                          triggeredCount: 0, triggeredAt: nil, originOrderID: nil))
        }

        // 打板账户 · 东方财富：网格交易（长期有效，已推进 3 档）
        if let metaID = resolveMetaID(code: "300059.SZ") {
            var params = SimCondParams()
            params.gridBase = 14.92
            params.gridUpper = 15.80
            params.gridLower = 13.50
            params.gridStepPct = 1.5
            params.gridQtyPerLevel = 300
            params.gridMultiplier = 1
            var runtime = SimCondRuntime()
            runtime.gridLevel = 3
            runtime.gridLastPrice = 14.50
            runtime.lastMessage = "已成交第 3 档"
            seedConds.append(SimCondOrder(id: UUID(), accountID: da.id, metaID: metaID,
                                          code: "300059.SZ", name: "东方财富",
                                          kind: .grid, params: params,
                                          directive: SimCondDirective(direction: .buy,
                                                                      priceType: .market,
                                                                      offsetTicks: 0, qty: 300),
                                          validity: .longTerm, expiresAt: nil,
                                          createdAt: seedNow, updatedAt: seedNow,
                                          status: .monitoring, runtime: runtime,
                                          triggeredCount: 3, triggeredAt: nil, originOrderID: nil))
        }

        // 主账户 · 东方财富：已触发的价格条件（让「已触发」分段非空）
        if let metaID = resolveMetaID(code: "300059.SZ") {
            var params = SimCondParams()
            params.compareUp = true
            params.triggerPrice = 15.60
            var runtime = SimCondRuntime()
            runtime.lastTriggerPrice = 15.60
            runtime.lastMessage = "已触发并生成委托"
            seedConds.append(SimCondOrder(id: UUID(), accountID: main.id, metaID: metaID,
                                          code: "300059.SZ", name: "东方财富",
                                          kind: .price, params: params,
                                          directive: SimCondDirective(direction: .sell,
                                                                      priceType: .market,
                                                                      offsetTicks: 0, qty: 500),
                                          validity: .day, expiresAt: nil,
                                          createdAt: todayAt(9, 46, 0), updatedAt: todayAt(14, 52, 30),
                                          status: .triggered, runtime: runtime,
                                          triggeredCount: 1, triggeredAt: todayAt(14, 52, 30),
                                          originOrderID: eastMoneyOrderID))
        }
        assignConditionalOrders(seedConds)

        selectedAccountID = main.id
        saveToDisk()
        DebugLogger.shared.log("[SimStore] seed done: accounts=\(accounts.count) positions=\(positions.count) orders=\(orders.count) fills=\(fills.count) conds=\(conditionalOrders.count)")
    }

    // MARK: - 账户

    var activeAccounts: [SimAccount] {
        accounts.filter { !$0.isArchived }
    }

    func account(id: UUID) -> SimAccount? {
        accounts.first { $0.id == id }
    }

    /// 账户展示名（nil / 全部汇总 id → "全部账户汇总"）
    func accountName(id: UUID?) -> String {
        guard let id = id, id != Self.allAccountID else { return "全部账户汇总" }
        return account(id: id)?.name ?? "全部账户汇总"
    }

    @discardableResult
    func createAccount(name: String, initialCapital: Double) -> SimAccount {
        let palette = ["#1E5FA8", "#B4282E", "#1F6E4F"]
        let account = SimAccount(id: UUID(),
                                 name: name,
                                 badge: String(name.prefix(1)),
                                 colorHex: palette[accounts.count % palette.count],
                                 initialCapital: initialCapital,
                                 cash: initialCapital,
                                 createdAt: Date(),
                                 isArchived: false)
        assignAccounts(accounts + [account])

        let now = Date()
        appendLedger(LedgerEntry(id: UUID(), accountID: account.id, kind: .deposit,
                                 note: "新建「\(name)」初始资金",
                                 amount: initialCapital, balanceAfter: initialCapital,
                                 occurredAt: now))
        appendLog(ActionLog(id: UUID(), accountID: account.id, module: .account,
                            content: "新建账户「\(name)」，初始资金 \(SimFormat.amount0(initialCapital))",
                            result: "成功", occurredAt: now))
        saveToDisk()
        return account
    }

    func renameAccount(id: UUID, name: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts[idx].name != name else { return }
        var arr = accounts
        arr[idx].name = name
        assignAccounts(arr)
        saveToDisk()
    }

    func archiveAccount(id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard !accounts[idx].isArchived else { return }
        var arr = accounts
        arr[idx].isArchived = true
        assignAccounts(arr)
        saveToDisk()
    }

    /// 重置账户：清空持仓 / 委托 / 成交 / 流水，资金回到初始资金
    func resetAccount(id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        var arr = accounts
        arr[idx].cash = arr[idx].initialCapital
        assignAccounts(arr)
        assignPositions(positions.filter { $0.accountID != id })
        assignOrders(orders.filter { $0.accountID != id })
        assignFills(fills.filter { $0.accountID != id })
        assignLedger(ledger.filter { $0.accountID != id })
        assignConditionalOrders(conditionalOrders.filter { $0.accountID != id })
        appendLog(ActionLog(id: UUID(), accountID: id, module: .account,
                            content: "重置账户「\(arr[idx].name)」", result: "成功",
                            occurredAt: Date()))
        saveToDisk()
    }

    func deposit(accountID: UUID, amount: Double) {
        guard amount > 0, let idx = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        var arr = accounts
        arr[idx].cash += amount
        assignAccounts(arr)
        let now = Date()
        appendLedger(LedgerEntry(id: UUID(), accountID: accountID, kind: .deposit,
                                 note: "银证转账入金", amount: amount,
                                 balanceAfter: arr[idx].cash, occurredAt: now))
        appendLog(ActionLog(id: UUID(), accountID: accountID, module: .cash,
                            content: "入金 \(SimFormat.amount(amount))", result: "成功",
                            occurredAt: now))
        saveToDisk()
    }

    func withdraw(accountID: UUID, amount: Double) {
        guard amount > 0, let idx = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        // 出金上限为可用资金，避免账户出现负余额
        let real = min(amount, accounts[idx].cash)
        guard real > 0 else { return }
        var arr = accounts
        arr[idx].cash -= real
        assignAccounts(arr)
        let now = Date()
        appendLedger(LedgerEntry(id: UUID(), accountID: accountID, kind: .withdraw,
                                 note: "银证转账出金", amount: -real,
                                 balanceAfter: arr[idx].cash, occurredAt: now))
        appendLog(ActionLog(id: UUID(), accountID: accountID, module: .cash,
                            content: "出金 \(SimFormat.amount(real))", result: "成功",
                            occurredAt: now))
        saveToDisk()
    }

    // MARK: - 交易：下单

    @discardableResult
    func submit(_ draft: SimOrderDraft) -> Result<SimOrder, SimOrderRejection> {
        guard let account = account(id: draft.accountID) else {
            return .failure(.emptyAccount)
        }
        let rules = SimTradingRules.default
        let pos = position(accountID: draft.accountID, metaID: draft.metaID)
        let lastPrice = SimQuoteCenter.lastPrice(metaID: draft.metaID)
        let prevClose = SimQuoteCenter.prevClose(metaID: draft.metaID)

        // 校验不通过 → 不写任何数据
        if let rejection = rules.validate(draft: draft, account: account, position: pos,
                                          lastPrice: lastPrice, prevClose: prevClose) {
            return .failure(rejection)
        }

        let now = Date()
        // 校验已保证：限价单 draft.price > 0；市价单 lastPrice > 0
        let execPrice: Double = draft.priceType == .limit ? (draft.price ?? lastPrice ?? 0)
                                                          : (lastPrice ?? 0)

        var order = SimOrder(id: UUID(),
                             accountID: draft.accountID,
                             metaID: draft.metaID,
                             code: draft.code,
                             name: draft.name,
                             direction: draft.direction,
                             priceType: draft.priceType,
                             price: draft.priceType == .limit ? draft.price : nil,
                             qty: draft.qty,
                             filledQty: 0,
                             status: .pending,
                             createdAt: now,
                             updatedAt: now,
                             originCondID: draft.originCondID)

        if rules.isTradingSession(at: now) {
            // 盘中：立即全部成交
            order.status = .filled
            order.filledQty = draft.qty

            let amount = execPrice * Double(draft.qty)
            let fee = rules.fee(amount: amount, direction: draft.direction)

            assignFills(fills + [SimFill(id: UUID(), orderID: order.id,
                                         accountID: draft.accountID, metaID: draft.metaID,
                                         code: draft.code, name: draft.name,
                                         direction: draft.direction, price: execPrice,
                                         qty: draft.qty, amount: amount, fee: fee,
                                         tradedAt: now, contractNo: makeContractNo(at: now))])

            applyPositionChange(draft: draft, execPrice: execPrice, amount: amount, at: now)

            let newCash = applyCashChange(accountID: draft.accountID, direction: draft.direction,
                                          amount: amount, fee: fee)
            appendLedger(LedgerEntry(id: UUID(), accountID: draft.accountID,
                                     kind: draft.direction.isBuy ? .buy : .sell,
                                     note: ledgerNote(name: draft.name, qty: draft.qty,
                                                      direction: draft.direction, fee: fee),
                                     amount: draft.direction.isBuy ? -(amount + fee) : (amount - fee),
                                     balanceAfter: newCash, occurredAt: now))
        } else {
            // 非交易时段：挂为待报，不动资金、不写成交与流水
            order.status = .pending
        }

        assignOrders(orders + [order])
        appendLog(ActionLog(id: UUID(), accountID: draft.accountID, module: .order,
                            content: orderContent(name: draft.name, direction: draft.direction,
                                                  qty: draft.qty, priceType: draft.priceType,
                                                  price: draft.price),
                            result: order.status.title, occurredAt: now))
        saveToDisk()
        return .success(order)
    }

    /// 买入：加权成本 + 加仓（可卖不变，T+1）；卖出：减仓并同步扣减可卖，清零则移除
    private func applyPositionChange(draft: SimOrderDraft, execPrice: Double,
                                     amount: Double, at date: Date) {
        if let idx = positions.firstIndex(where: {
            $0.accountID == draft.accountID && $0.metaID == draft.metaID
        }) {
            var arr = positions
            if draft.direction.isBuy {
                let newQty = arr[idx].qty + draft.qty
                let oldCost = arr[idx].costPrice
                let oldQty = arr[idx].qty
                arr[idx].qty = newQty
                arr[idx].costPrice = newQty > 0
                    ? (Double(oldQty) * oldCost + amount) / Double(newQty)
                    : oldCost
            } else {
                arr[idx].qty -= draft.qty
                arr[idx].availableQty -= draft.qty
            }
            if arr[idx].qty <= 0 {
                arr.remove(at: idx)
            }
            assignPositions(arr)
        } else if draft.direction.isBuy {
            assignPositions(positions + [SimPosition(id: UUID(), accountID: draft.accountID,
                                                     metaID: draft.metaID, code: draft.code,
                                                     name: draft.name, qty: draft.qty,
                                                     availableQty: 0, costPrice: execPrice,
                                                     openedAt: date)])
        }
    }

    /// 买入：cash -= 金额 + 费用；卖出：cash += 金额 - 费用。返回变动后可用资金
    private func applyCashChange(accountID: UUID, direction: SimOrderDirection,
                                 amount: Double, fee: Double) -> Double {
        guard let idx = accounts.firstIndex(where: { $0.id == accountID }) else { return 0 }
        var arr = accounts
        arr[idx].cash += direction.isBuy ? -(amount + fee) : (amount - fee)
        assignAccounts(arr)
        return arr[idx].cash
    }

    /// 成交编号：yyyyMMdd- 三位当日序号（按当日已有成交数 + 1）
    private func makeContractNo(at date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd"
        let day = fmt.string(from: date)
        let prefix = day + "-"
        let seq = fills.filter { $0.contractNo.hasPrefix(prefix) }.count + 1
        return String(format: "%@%03d", prefix, seq)
    }

    private func orderContent(name: String, direction: SimOrderDirection, qty: Int,
                              priceType: SimPriceType, price: Double?) -> String {
        var text = "\(direction.title) \(name) \(SimFormat.shares(qty)) 股 · \(priceType.title)"
        if priceType == .limit, let price = price {
            text += " " + SimFormat.price(price)
        }
        return text
    }

    private func ledgerNote(name: String, qty: Int, direction: SimOrderDirection, fee: Double) -> String {
        if direction.isBuy {
            return "买入成交 \(name) \(SimFormat.shares(qty)) 股（含费）"
        }
        return "卖出成交 \(name) \(SimFormat.shares(qty)) 股（扣费 \(SimFormat.amount(fee))）"
    }

    // MARK: - 交易：撤单 / 改价 / 一键操作

    func cancelOrder(id: UUID) {
        guard let idx = orders.firstIndex(where: { $0.id == id }) else { return }
        guard orders[idx].status.isActive else { return }
        let now = Date()
        var target = orders[idx]
        target.status = .cancelled
        target.updatedAt = now
        var arr = orders
        arr[idx] = target
        assignOrders(arr)
        appendLog(ActionLog(id: UUID(), accountID: target.accountID, module: .cancel,
                            content: cancelContent(target), result: "成功", occurredAt: now))
        saveToDisk()
    }

    func amendOrderPrice(id: UUID, newPrice: Double) {
        guard let idx = orders.firstIndex(where: { $0.id == id }) else { return }
        guard orders[idx].status.isActive else { return }
        let now = Date()
        var target = orders[idx]
        let oldText = target.price.map { SimFormat.price($0) } ?? "市价"
        target.price = newPrice
        target.priceType = .limit
        target.updatedAt = now
        var arr = orders
        arr[idx] = target
        assignOrders(arr)
        appendLog(ActionLog(id: UUID(), accountID: target.accountID, module: .amend,
                            content: "委托价格 \(oldText) → \(SimFormat.price(newPrice))",
                            result: "成功", occurredAt: now))
        saveToDisk()
    }

    /// 批量撤单（nil = 全部账户），返回撤单笔数
    @discardableResult
    func cancelAll(accountID: UUID?) -> Int {
        let targets = orders.filter {
            $0.status.isActive && matches(accountID, $0.accountID)
        }
        guard !targets.isEmpty else { return 0 }
        let now = Date()
        let ids = Set(targets.map { $0.id })
        var arr = orders
        for i in arr.indices where ids.contains(arr[i].id) {
            arr[i].status = .cancelled
            arr[i].updatedAt = now
        }
        assignOrders(arr)
        var newLogs = logs
        for t in targets {
            newLogs.append(ActionLog(id: UUID(), accountID: t.accountID, module: .cancel,
                                     content: cancelContent(t), result: "成功", occurredAt: now))
        }
        assignLogs(newLogs)
        saveToDisk()
        return targets.count
    }

    /// 一键平仓：按可卖数量生成一笔市价卖出委托，返回生成笔数（0 或 1）
    @discardableResult
    func closeAll(accountID: UUID, metaID: Int) -> Int {
        guard let pos = position(accountID: accountID, metaID: metaID) else { return 0 }
        let qty = SimTradingRules.default.sellableQty(position: pos)
        guard qty > 0 else {
            appendLog(ActionLog(id: UUID(), accountID: accountID, module: .order,
                                content: "一键平仓 \(pos.name)", result: "无可卖数量",
                                occurredAt: Date()))
            saveToDisk()
            return 0
        }
        let draft = SimOrderDraft(accountID: accountID, metaID: metaID, code: pos.code,
                                  name: pos.name, direction: .sell, priceType: .market,
                                  price: nil, qty: qty)
        switch submit(draft) {
        case .success:
            return 1
        case .failure:
            return 0
        }
    }

    private func cancelContent(_ order: SimOrder) -> String {
        let priceText = order.priceType == .limit
            ? (order.price.map { SimFormat.price($0) } ?? "限价")
            : "市价"
        return "撤回「\(order.direction.title) \(order.name) \(SimFormat.shares(order.qty)) 股 · \(priceText)」"
    }

    // MARK: - T+1 日切

    /// 跨日刷新可卖数量：与上次刷新日期不同则把所有 availableQty 置为 qty
    func refreshTPlus1IfNeeded() {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        guard UserDefaults.standard.string(forKey: tPlus1Key) != today else { return }
        UserDefaults.standard.set(today, forKey: tPlus1Key)

        guard !positions.isEmpty else { return }
        var arr = positions
        for i in arr.indices { arr[i].availableQty = arr[i].qty }
        assignPositions(arr)
        saveToDisk()
    }

    // MARK: - 查询（accountID == nil 表示全部账户聚合）

    /// 账户过滤：nil 或「全部汇总」id → 命中全部
    private func matches(_ filter: UUID?, _ accountID: UUID) -> Bool {
        guard let filter = filter, filter != Self.allAccountID else { return true }
        return filter == accountID
    }

    func positions(accountID: UUID?) -> [SimPosition] {
        guard let filter = accountID, filter != Self.allAccountID else { return positions }
        return positions.filter { $0.accountID == filter }
    }

    func position(accountID: UUID, metaID: Int) -> SimPosition? {
        positions.first { $0.accountID == accountID && $0.metaID == metaID }
    }

    func orders(accountID: UUID?) -> [SimOrder] {
        orders.filter { matches(accountID, $0.accountID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func activeOrders(accountID: UUID?) -> [SimOrder] {
        orders.filter { $0.status.isActive && matches(accountID, $0.accountID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func fills(accountID: UUID?) -> [SimFill] {
        fills.filter { matches(accountID, $0.accountID) }
            .sorted { $0.tradedAt > $1.tradedAt }
    }

    func ledgerEntries(accountID: UUID?) -> [LedgerEntry] {
        ledger.filter { matches(accountID, $0.accountID) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    func actionLogs(accountID: UUID?) -> [ActionLog] {
        let result: [ActionLog]
        if let filter = accountID, filter != Self.allAccountID {
            result = logs.filter { $0.accountID == filter }
        } else {
            result = logs
        }
        return result.sorted { $0.occurredAt > $1.occurredAt }
    }

    func order(id: UUID) -> SimOrder? {
        orders.first { $0.id == id }
    }

    // MARK: - 条件单（查询与写入口；落盘在方法内部完成，与 createAccount / deposit 风格一致）

    /// 条件单列表（accountID == nil 表示全部账户聚合），按创建时间倒序
    func condOrders(accountID: UUID?) -> [SimCondOrder] {
        conditionalOrders.filter { matches(accountID, $0.accountID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func condOrder(id: UUID) -> SimCondOrder? {
        conditionalOrders.first { $0.id == id }
    }

    /// 按分段过滤（监控中 / 已触发含已完成 / 已失效含撤销·过期·被拒）
    func condOrders(accountID: UUID?, segment: SimCondSegment) -> [SimCondOrder] {
        condOrders(accountID: accountID).filter { $0.segment == segment }
    }

    /// 三段计数（监控中 / 已触发 / 已失效）
    func condCounts(accountID: UUID?) -> (monitoring: Int, triggered: Int, invalid: Int) {
        let list = condOrders(accountID: accountID)
        let monitoring = list.reduce(0) { $0 + ($1.segment == .monitoring ? 1 : 0) }
        let triggered = list.reduce(0) { $0 + ($1.segment == .triggered ? 1 : 0) }
        return (monitoring, triggered, list.count - monitoring - triggered)
    }

    /// 新增或整体替换（调用方传入完整 SimCondOrder，引擎维护的字段不做级别合并），并刷新 updatedAt
    func upsertCondOrder(_ order: SimCondOrder) {
        var target = order
        target.updatedAt = Date()
        var arr = conditionalOrders
        if let idx = arr.firstIndex(where: { $0.id == target.id }) {
            guard arr[idx] != target else { return }
            arr[idx] = target
        } else {
            arr.append(target)
        }
        assignConditionalOrders(arr)
        saveToDisk()
    }

    /// 撤销条件单（仅「监控中」可撤）
    func cancelCondOrder(id: UUID) {
        guard let idx = conditionalOrders.firstIndex(where: { $0.id == id }) else { return }
        guard conditionalOrders[idx].status == .monitoring else { return }
        var arr = conditionalOrders
        let now = Date()
        arr[idx].status = .cancelled
        arr[idx].updatedAt = now
        arr[idx].runtime.lastMessage = "用户撤销"
        assignConditionalOrders(arr)
        appendLog(ActionLog(id: UUID(), accountID: arr[idx].accountID, module: .condition,
                            content: "撤销条件单 \(arr[idx].name) · \(arr[idx].kind.title)",
                            result: arr[idx].status.title, occurredAt: now))
        saveToDisk()
    }

    func deleteCondOrder(id: UUID) {
        guard conditionalOrders.contains(where: { $0.id == id }) else { return }
        assignConditionalOrders(conditionalOrders.filter { $0.id != id })
        saveToDisk()
    }

    // MARK: - 汇总

    struct SimAccountSummary {
        var initialCapital: Double
        var totalAssets: Double       // cash + 持仓市值
        var cash: Double
        var marketValue: Double
        var positionPct: Double       // 0...1，市值 / 总资产
        var dayProfit: Double         // Σ 持仓 qty * (lastPrice - prevClose)
        var dayProfitPct: Double
        var totalProfit: Double       // totalAssets - initialCapital
        var totalProfitPct: Double
    }

    func summary(accountID: UUID?) -> SimAccountSummary {
        let scope: [SimAccount]
        if let filter = accountID, filter != Self.allAccountID, let one = account(id: filter) {
            scope = [one]
        } else {
            scope = activeAccounts
        }
        let initialCapital = scope.reduce(0) { $0 + $1.initialCapital }
        let cash = scope.reduce(0) { $0 + $1.cash }
        let scopeIDs = Set(scope.map { $0.id })

        var marketValue = 0.0
        var dayProfit = 0.0
        for p in positions where scopeIDs.contains(p.accountID) {
            let last = SimQuoteCenter.lastPrice(metaID: p.metaID)
            let prev = SimQuoteCenter.prevClose(metaID: p.metaID)
            marketValue += Double(p.qty) * (last ?? p.costPrice)
            let current = last ?? prev ?? p.costPrice
            let base = prev ?? last ?? p.costPrice
            dayProfit += Double(p.qty) * (current - base)
        }

        let totalAssets = cash + marketValue
        let positionPct = totalAssets > 0 ? marketValue / totalAssets : 0
        let prevAssets = totalAssets - dayProfit
        let dayProfitPct = prevAssets > 0 ? dayProfit / prevAssets : 0
        let totalProfit = totalAssets - initialCapital
        let totalProfitPct = initialCapital > 0 ? totalProfit / initialCapital : 0

        return SimAccountSummary(initialCapital: initialCapital,
                                 totalAssets: totalAssets,
                                 cash: cash,
                                 marketValue: marketValue,
                                 positionPct: positionPct,
                                 dayProfit: dayProfit,
                                 dayProfitPct: dayProfitPct,
                                 totalProfit: totalProfit,
                                 totalProfitPct: totalProfitPct)
    }

    struct SimPositionSnapshot {
        var lastPrice: Double
        var marketValue: Double
        var profit: Double            // (lastPrice - costPrice) * qty
        var profitPct: Double
    }

    func snapshot(for position: SimPosition) -> SimPositionSnapshot {
        let last = SimQuoteCenter.lastPrice(metaID: position.metaID) ?? position.costPrice
        let marketValue = Double(position.qty) * last
        let profit = (last - position.costPrice) * Double(position.qty)
        let profitPct = position.costPrice > 0
            ? (last - position.costPrice) / position.costPrice
            : 0
        return SimPositionSnapshot(lastPrice: last, marketValue: marketValue,
                                   profit: profit, profitPct: profitPct)
    }

    /// 近 N 日净值曲线：由资金流水按日聚合 balanceAfter（升序）；
    /// 点数不足 2 时用「初始资金 → 当前总资产」补足
    func netValueSeries(accountID: UUID?, days: Int) -> [Double] {
        let count = max(days, 1)
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .day, value: -(count - 1), to: todayStart) else {
            return fallbackSeries(accountID: accountID)
        }
        // ledgerEntries 为倒序，故同一日先遇到的即当日最后一笔
        var byDay: [Date: Double] = [:]
        for entry in ledgerEntries(accountID: accountID) {
            guard entry.occurredAt >= windowStart else { continue }
            let day = cal.startOfDay(for: entry.occurredAt)
            if byDay[day] == nil { byDay[day] = entry.balanceAfter }
        }
        var series = byDay.keys.sorted().compactMap { byDay[$0] }
        if series.count < 2 {
            series = fallbackSeries(accountID: accountID)
        }
        return series
    }

    private func fallbackSeries(accountID: UUID?) -> [Double] {
        let initial: Double
        if let filter = accountID, filter != Self.allAccountID, let one = account(id: filter) {
            initial = one.initialCapital
        } else {
            initial = activeAccounts.reduce(0) { $0 + $1.initialCapital }
        }
        return [initial, summary(accountID: accountID).totalAssets]
    }

    // MARK: - 行情预取

    /// 注册所有持仓标的到 MarketRowCache（触发行情预取）。
    /// 视图在 onAppear 调用一次，避免在 body 里调用 row(for:) 造成「视图更新期间改状态」
    func prepareQuotes() {
        refreshTPlus1IfNeeded()
        for p in positions {
            if let meta = SimQuoteCenter.meta(metaID: p.metaID) {
                _ = MarketRowCache.shared.row(for: meta)
            }
        }
    }

    // MARK: - 日志写入（internal：条件单引擎在另一文件中也需写日志）

    func appendLog(_ log: ActionLog) {
        assignLogs(logs + [log])
    }

    func appendLedger(_ entry: LedgerEntry) {
        assignLedger(ledger + [entry])
    }
}
