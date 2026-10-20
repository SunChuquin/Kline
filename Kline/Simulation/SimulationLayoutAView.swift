//
//  SimulationLayoutAView.swift
//  Kline
//
//  模拟页布局方案 A：账户侧栏 + 工作区。
//  regular（≥600，iPad / iPhone 横屏 848）：左栏 216pt 固定宽（账户列表 / 新建账户 /
//  交易规则与账户管理入口），右栏自适应工作区；横屏工作区 ~632 放不下七项指标单行
//  （~700pt）与「整条分段 + 工具入口」，靠指标 WrappingHStack 自然折行 + 分段横滚 +
//  买卖条收提示把工作区需求压进 632（iPad ≥808 单行放得下自动 1 行，形态不变）。
//  紧凑宽（<600，iPhone 竖屏 414）：侧栏 + 工作区固有宽 ~1022 超出屏宽（侧栏整列出屏、
//  指标行两端出屏、买卖条出屏），侧栏收纳为工作区顶部「账户」抽屉（SidebarDrawer，
//  与自选 B 完全同款交互），工作区占满整页；账户行 / 底部入口与侧栏共用同一份视图，
//  切账户 / 新建 / 管理路径一条不丢。模块行拆两行收敛（分段横滚 + 搜索框弹性宽）。
//  全屏下单页由 .simFullScreenTicket 呈现。iOS 15 兼容，背景一律语义色。
//

import SwiftUI

struct SimulationLayoutAView: View {
    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var db = DatabaseManager.shared

    /// 当前业务模块
    @State private var module: SimModuleTab = .position
    /// 全屏下单请求（每次新建都换新 UUID，保证可重复呈现）
    @State private var ticketRequest: SimTicketRequest? = nil
    /// 条件单呈现请求（工具栏入口 → 管理页；持仓行入口 → 编辑器，二者共用一个呈现状态）
    @State private var condPresentation: SimCondEntryRequest? = nil
    /// 公式管理中心（「交易策略」段）开合：由工具栏「策略公式」入口触发
    @State private var showStrategyFormulas = false
    /// 「训练记录」管理页开合：由工具栏「训练记录」入口触发
    @State private var showTrainingRecords = false
    /// 新建账户
    @State private var showCreateAccount = false
    @State private var newAccountName = ""
    @State private var newAccountCapital = "100000"
    /// 侧栏底部提示（交易规则 / 账户管理说明）
    @State private var sidebarHint: String? = nil
    /// 日志搜索词
    @State private var logKeyword = ""
    /// 日志模块筛选（nil = 全部）
    @State private var logModule: ActionModule? = nil
    /// 其他模块搜索词（标的名称 / 代码）
    @State private var tableKeyword = ""
    /// 改价目标委托
    @State private var amendTarget: SimOrder? = nil
    @State private var amendPriceText = ""
    /// 工作区轻提示（刷新 / 导出 / 拦截提示，2 秒后自动消失）
    @State private var toast: String? = nil

    /// 页面可用宽度：由顶层 WidthReader 上报。0 表示尚未上报——此时按 regular（侧栏常驻）
    /// 形态渲染，保证 iPad 首帧与既有布局完全一致（与自选 B / 行情 B 同一范式）
    @State private var availableWidth: CGFloat = 0

    /// 紧凑宽度形态（可用宽 < 600，iPhone 竖屏 414 命中）：侧栏折叠为抽屉，工作区占满整页
    private var isCompact: Bool {
        availableWidth > 0 && availableWidth < CompactWidth.threshold
    }

    /// 紧凑态账户抽屉开关（工作区顶部「账户」入口按钮 toggle）
    @State private var accountDrawerActive = false

    private let sidebarWidth: CGFloat = 216

    private static let rulesText = """
    T+1：当日买入次日可卖
    佣金万 2.5，最低 5 元
    卖出印花税千一
    涨跌停 ±10%
    盘后委托转为待报
    """

    private static let accountHelpText = "账户管理：点「＋ 新建账户」创建账户；选中账户后在右侧工作区下单、查看流水与日志。"

    // MARK: - Body

    var body: some View {
        // 顶层测宽（WidthReader 只允许在页面顶层包裹，见其文档）
        WidthReader(onChange: { availableWidth = $0 }) {
            Group {
                if isCompact {
                    compactBody
                } else {
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: sidebarWidth)
                        Rectangle()
                            .fill(Color(.separator))
                            .frame(width: 0.5)
                        workspace
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                }
            }
            .onChange(of: isCompact) { compact in
                // 旋转跨过 600 阈值（竖屏 ↔ 横屏）：抽屉随紧凑态消失，
                // 复位开关避免转回窄屏时抽屉残留展开
                if !compact { accountDrawerActive = false }
            }
            // 公式管理中心（「交易策略」段）：全屏页面挂在根视图最外层 overlay，
            // 避免被工作区的表格 ScrollView / 侧栏裁剪；关闭走页内「返回」
            .overlay {
                if showStrategyFormulas {
                    ZStack {
                        FormulaCenterView(initialKind: .strategy,
                                          onClose: { showStrategyFormulas = false })
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
            .simFullScreenTicket($ticketRequest)
            // 「训练记录」管理页：独立宿主，与全屏下单页分开挂，避免同视图多 cover 压制
            .simTrainingRecordPresentation($showTrainingRecords)
        }
    }

    // MARK: - 左栏：账户侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("账户")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 5, trailing: 16))

            ScrollView {
                LazyVStack(spacing: 2) {
                    allAccountsRow()
                    ForEach(store.activeAccounts) { accountRow($0) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            newAccountRow

            if let hint = sidebarHint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            sidebarBottomActions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .alert("新建账户", isPresented: $showCreateAccount) {
            TextField("账户名称", text: $newAccountName)
            TextField("初始资金", text: $newAccountCapital)
                .keyboardType(.decimalPad)
            Button("创建") { createAccount() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("初始资金默认 100000 元，创建后自动选中该账户。")
        }
    }

    /// 「全部账户汇总」行（聚合视图）：常驻侧栏与紧凑抽屉共用同一份视图；
    /// 抽屉行经 then 先收抽屉（行本身是 Button，优先于抽屉外层 onTapGesture，
    /// 点行即「切账户 + 收抽屉」，不会误触外层手势造成二次收起）
    private func allAccountsRow(then: (() -> Void)? = nil) -> some View {
        let selected = store.isAllAccountsSelected
        let summary = store.summary(accountID: nil)
        return Button(action: {
            store.selectedAccountID = SimStore.allAccountID
            then?()
        }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "globe")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("全部账户汇总")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Text("\(store.activeAccounts.count) 个账户 · 聚合视图")
                        .font(.system(size: 10))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(SimFormat.pct(summary.dayProfitPct * 100))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(profitColor(summary.dayProfit))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color(.systemBackground) : Color.clear))
            .shadow(color: selected ? Color.black.opacity(0.08) : Color.clear,
                    radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.all")
    }

    /// 单个账户行（色块 + 名称 + 总资产 + 当日盈亏%）：常驻侧栏与紧凑抽屉共用同一份视图
    private func accountRow(_ account: SimAccount, then: (() -> Void)? = nil) -> some View {
        let selected = store.selectedAccountID == account.id
        let summary = store.summary(accountID: account.id)
        return Button(action: {
            store.selectedAccountID = account.id
            then?()
        }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorFromHex(account.colorHex))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(account.badge)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Text(SimFormat.amount0(summary.totalAssets))
                        .font(.system(size: 10))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(SimFormat.pct(summary.dayProfitPct * 100))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(profitColor(summary.dayProfit))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color(.systemBackground) : Color.clear))
            .shadow(color: selected ? Color.black.opacity(0.08) : Color.clear,
                    radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.\(account.name)")
    }

    private var newAccountRow: some View {
        Button(action: { showCreateAccount = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.system(size: 12))
                Text("新建账户").font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.new")
    }

    private var sidebarBottomActions: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            bottomActionRow(icon: "gear", title: "交易规则设置") {
                sidebarHint = Self.rulesText
            }
            bottomActionRow(icon: "doc.text", title: "账户管理") {
                sidebarHint = Self.accountHelpText
            }
        }
    }

    private func bottomActionRow(icon: String, title: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundColor(Color(.secondaryLabel))
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 紧凑态主体（<600：侧栏收纳为抽屉）

    /// 紧凑态：无侧栏，工作区占满整页。顶部补一行「账户」抽屉入口（承接侧栏职责），
    /// 其余与工作区同构：资产总览（流式换行）→ 模块行（两行收敛）→ 业务表（横滚）→ 买卖条
    private var compactBody: some View {
        VStack(spacing: 0) {
            accountAnchorRow
            SimSummaryBand(accountID: store.queryAccountID)
            moduleRow
            if module == .log {
                SimLogModuleFilterBar(selected: $logModule)
            }
            SimModuleTable(module: module,
                           accountID: store.queryAccountID,
                           onTrade: { position, direction in
                               openTicket(accountID: position.accountID,
                                          metaID: position.metaID,
                                          code: position.code,
                                          name: position.name,
                                          direction: direction)
                           },
                           onAmend: { order in beginAmend(order) },
                           onCondition: { position in openCondEditor(for: position) },
                           keyword: module == .log ? logKeyword : tableKeyword,
                           logModuleFilter: module == .log ? logModule : nil,
                           isCompact: true)
                .frame(maxHeight: .infinity)
                // 抽屉 overlay 挂在业务表上（入口行下方）：面板从入口行下缘下拉展开，
                // 锚点按钮不被遮罩盖住、保持可点（再点一次即收起）。
                // 抽屉仅展开态挂树：收起态条件移除——容器级与元素级 accessibilityHidden
                // 对本组件的直接子 Button 均不生效（真机探针实测），条件渲染是唯一
                // 确定的移除手段；滑动/淡入转场补回抽屉原本的滑入感
                .overlay {
                    if accountDrawerActive {
                        accountDrawer
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: accountDrawerActive)
            SimBottomActionBar(onTrade: { direction in openBottomTicket(direction) },
                               hint: bottomHint,
                               isCompact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { toastView }
        .alert("修改委托价", isPresented: amendBinding) {
            TextField("委托价", text: $amendPriceText)
                .keyboardType(.decimalPad)
            Button("确认") { Task { await confirmAmend() } }
            Button("取消", role: .cancel) { amendTarget = nil }
        } message: {
            Text(amendTarget.map {
                "\($0.name) \($0.code) · 当前 \($0.price.map { SimFormat.price($0) } ?? "市价")"
            } ?? "")
        }
    }

    /// 紧凑态「账户」抽屉入口行：侧栏图标 + 当前账户名 + 下拉箭头（与自选 B 分组入口同一形态）。
    /// 「新建账户」弹窗挂在本行（与工作区的「修改委托价」弹窗分开宿主，避免同视图多 alert 冲突）
    private var accountAnchorRow: some View {
        HStack(spacing: 8) {
            Button {
                accountDrawerActive.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                    Text(store.accountName(id: store.queryAccountID))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 低布局优先级：空间不足时优先压缩账户名（截断显示），行内其余内容保持完整
            .layoutPriority(-1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        .alert("新建账户", isPresented: $showCreateAccount) {
            TextField("账户名称", text: $newAccountName)
            TextField("初始资金", text: $newAccountCapital)
                .keyboardType(.decimalPad)
            Button("创建") { createAccount() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("初始资金默认 100000 元，创建后自动选中该账户。")
        }
    }

    /// 账户抽屉（紧凑态）：行与底部入口复用常驻侧栏同一份（全部汇总行 / 账户行 / 新建 /
    /// 交易规则设置 / 账户管理），切换 / 新建 / 管理路径一条不丢
    private var accountDrawer: some View {
        SidebarDrawer(
            isPresented: $accountDrawerActive,
            title: "账户",
            options: drawerOptions,
            selection: currentDrawerSelection,
            onSelect: { option in
                switch option {
                case .all: store.selectedAccountID = SimStore.allAccountID
                case .one(let id): store.selectedAccountID = id
                }
            },
            rowContent: { option, _ in
                // 选中高亮由行内部按 store 状态自算（与侧栏同一判定源），第二个参数不用
                switch option {
                case .all:
                    allAccountsRow { accountDrawerActive = false }
                case .one(let id):
                    if let account = store.account(id: id) {
                        accountRow(account) { accountDrawerActive = false }
                    }
                }
            },
            footer: {
                drawerFooter
            }
        )
    }

    /// 抽屉选项（SidebarDrawer 的 Selection 约束要 Hashable）：「全部账户汇总」置顶 + 各账户
    private enum AccountDrawerOption: Hashable {
        case all
        case one(UUID)
    }

    private var drawerOptions: [AccountDrawerOption] {
        [.all] + store.activeAccounts.map { .one($0.id) }
    }

    private var currentDrawerSelection: AccountDrawerOption {
        if store.isAllAccountsSelected { return .all }
        if let id = store.selectedAccountID { return .one(id) }
        return .all
    }

    /// 抽屉底部操作区：新建账户（与侧栏同一弹窗）+ 交易规则设置 / 账户管理。
    /// 紧凑态没有侧栏提示区，后两项以工作区轻提示呈现同一份文案（路径与文案都保留）
    private var drawerFooter: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                footerButton("新建账户", icon: "plus") { showCreateAccount = true }
                    .accessibilityIdentifier("sim.account.new")
                HStack(spacing: 6) {
                    footerButton("交易规则设置", icon: "gear") { showToast(Self.rulesText) }
                    footerButton("账户管理", icon: "doc.text") { showToast(Self.accountHelpText) }
                }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
        }
    }

    /// 抽屉底部操作按钮（与自选 B 抽屉底部入口同一形态）
    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右栏：工作区

    private var workspace: some View {
        VStack(spacing: 0) {
            SimSummaryBand(accountID: store.queryAccountID)
            moduleRow
            if module == .log {
                SimLogModuleFilterBar(selected: $logModule)
            }
            SimModuleTable(module: module,
                           accountID: store.queryAccountID,
                           onTrade: { position, direction in
                               openTicket(accountID: position.accountID,
                                          metaID: position.metaID,
                                          code: position.code,
                                          name: position.name,
                                          direction: direction)
                           },
                           onAmend: { order in beginAmend(order) },
                           onCondition: { position in openCondEditor(for: position) },
                           keyword: module == .log ? logKeyword : tableKeyword,
                           logModuleFilter: module == .log ? logModule : nil,
                           // 窄工作区整表包横滚：不包的话表格固有列宽 ~806 会把整个工作区
                           // 撑宽（模块行 / 买卖条跟着出屏）；宽工作区直排、原样
                           isCompact: workspaceNarrow)
                .frame(maxHeight: .infinity)
            SimBottomActionBar(onTrade: { direction in openBottomTicket(direction) },
                               hint: bottomHint,
                               isCompact: bottomBarCompact)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { toastView }
        .alert("修改委托价", isPresented: amendBinding) {
            TextField("委托价", text: $amendPriceText)
                .keyboardType(.decimalPad)
            Button("确认") { Task { await confirmAmend() } }
            Button("取消", role: .cancel) { amendTarget = nil }
        } message: {
            Text(amendTarget.map {
                "\($0.name) \($0.code) · 当前 \($0.price.map { SimFormat.price($0) } ?? "市价")"
            } ?? "")
        }
    }

    /// 买卖条是否收左侧提示文案：提示 + 双按钮一行固有宽 ~735，工作区放不下时收掉文案保
    /// 「买入 / 卖出」入屏（紧凑 414 / 横屏去侧栏 ~632 / iPad 竖屏 ~552 都收）；
    /// iPad 横屏工作区 ≥808 放得下、形态不变。未测宽（0）先按宽屏（与侧栏约定一致）
    private var bottomBarCompact: Bool {
        if isCompact { return true }
        guard availableWidth > 0 else { return false }
        return availableWidth - sidebarWidth < 740
    }

    /// 工作区是否过窄（< ~760）：iPhone 横屏 848−216≈632 / iPad 竖屏 552~618。
    /// 业务表固有列宽 ~806 会把工作区整体撑到 806（表格在容器里不参与压缩，
    /// 真机探针实测：表格不收，模块行 / 买卖条跟着一起出屏）——窄工作区必须整表包
    /// 横滚让最小宽收敛；iPad 横屏工作区 ≥808 放得下整表 → 直排、原样不变
    private var workspaceNarrow: Bool {
        availableWidth > 0 && availableWidth - sidebarWidth < 760
    }

    /// 模块行是否拆两行（分段独占横滚行 + 入口行搜索框弹性宽，与模拟 C 同款收敛）：
    /// 紧凑宽（<600），或工作区放不下单行——「整条分段 + 入口 + 搜索框」单行约需 ~795pt，
    /// 窄工作区都放不下（分段条在 HStack 内不参与压缩、按内容理想宽取宽）。
    /// iPad 横屏工作区 ≥808 放得下 → 保持单行原样
    private var moduleRowSplits: Bool {
        isCompact || workspaceNarrow
    }

    /// 模块行：分段控件 + 右侧工具条（日志模块为筛选/导出，其余为搜索/刷新）
    private var moduleRow: some View {
        Group {
            if moduleRowSplits {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        SimModuleSegmentedBar(module: $module, accountID: store.queryAccountID)
                            .frame(height: 44)
                    }
                    .frame(height: 44)
                    HStack(spacing: 8) {
                        condEntryButton
                        SimStrategyFormulaEntryButton { showStrategyFormulas = true }
                        SimTrainingRecordEntryButton { showTrainingRecords = true }
                        if module == .log {
                            logToolbar
                        } else {
                            standardToolbar
                        }
                    }
                    .frame(height: 44)
                }
            } else {
                HStack(spacing: 10) {
                    SimModuleSegmentedBar(module: $module, accountID: store.queryAccountID)
                    Spacer(minLength: 8)
                    condEntryButton
                    SimStrategyFormulaEntryButton { showStrategyFormulas = true }
                    SimTrainingRecordEntryButton { showTrainingRecords = true }
                    if module == .log {
                        logToolbar
                    } else {
                        standardToolbar
                    }
                }
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        // 条件单全屏呈现挂在本行（与根视图的全屏下单页分开宿主，避免同视图多个 fullScreenCover）
        .simCondEntryPresentation($condPresentation, accountID: store.queryAccountID)
    }

    /// 工具栏「条件单」入口（文字右上角叠监控中数量角标）
    private var condEntryButton: some View {
        let monitoring = store.condCounts(accountID: store.queryAccountID).monitoring
        return Button(action: { condPresentation = .list(UUID()) }) {
            Text("条件单")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.blue)
                .overlay(alignment: .topTrailing) {
                    if monitoring > 0 {
                        Text("\(monitoring)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(.systemRed)))
                            .offset(x: 12, y: -8)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.cond.entry")
    }

    private var standardToolbar: some View {
        HStack(spacing: 8) {
            searchBox(text: $tableKeyword, placeholder: "搜索标的名称/代码")
            toolbarButton(icon: "arrow.clockwise", title: "刷新") {
                Task { await refreshQuotes() }
            }
        }
    }

    /// 日志工具栏（模块筛选条在下一行；此处保留范围 / 搜索 / 导出）
    private var logToolbar: some View {
        HStack(spacing: 8) {
            toolbarButton(icon: "calendar", title: "近 30 天") {
                showToast("日志范围：近 30 天（更早记录请继续向下滚动加载）")
            }
            searchBox(text: $logKeyword, placeholder: "搜索操作内容")
            toolbarButton(icon: "square.and.arrow.down", title: "导出") {
                exportLogs()
            }
        }
    }

    /// 搜索框：单行形态固定 148pt；拆行形态（紧凑 / 窄工作区）改弹性宽
    ///（maxWidth .infinity 吃行内剩余空间）——固定 148 与行内固定入口共存必然把
    ///「刷新 / 导出」挤出屏（与模拟 C 同因同解）
    private func searchBox(text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
            TextField(placeholder, text: text)
                .font(.system(size: 11.5))
                .foregroundColor(Color.primary)
                .frame(width: moduleRowSplits ? nil : 148)
                .frame(maxWidth: moduleRowSplits ? .infinity : nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
    }

    private func toolbarButton(icon: String?, title: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon).font(.system(size: 11))
                }
                Text(title).font(.system(size: 11.5))
            }
            .foregroundColor(Color(.secondaryLabel))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var toastView: some View {
        if let text = toast {
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

    // MARK: - 下单入口

    /// 下单账户：具体账户优先；「全部账户汇总」时取第一个可用账户
    private var orderAccountID: UUID? {
        if let id = store.queryAccountID, store.account(id: id) != nil { return id }
        return store.activeAccounts.first?.id
    }

    /// 下单标的：优先当前账户第一只持仓，无持仓时取数据库第一只可用标的
    private func defaultTarget(accountID: UUID) -> (metaID: Int, code: String, name: String)? {
        if let position = store.positions(accountID: accountID).first {
            return (position.metaID, position.code, position.name)
        }
        if let meta = db.metaList.first(where: { !$0.code.isEmpty }) {
            return (meta.id, meta.code, meta.name)
        }
        return nil
    }

    private func openTicket(accountID: UUID, metaID: Int, code: String, name: String,
                            direction: SimOrderDirection) {
        ticketRequest = SimTicketRequest(accountID: accountID, metaID: metaID,
                                         code: code, name: name, direction: direction)
    }

    /// 持仓行「条件单」入口：默认止盈止损 / 卖出，数量取可卖整手，基准价预填成本价
    private func openCondEditor(for position: SimPosition) {
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

    private func openBottomTicket(_ direction: SimOrderDirection) {
        guard let accountID = orderAccountID else {
            showToast("请先在左侧新建一个模拟账户")
            return
        }
        guard let target = defaultTarget(accountID: accountID) else {
            showToast("暂无可用标的，无法下单")
            return
        }
        openTicket(accountID: accountID, metaID: target.metaID, code: target.code,
                   name: target.name, direction: direction)
    }

    /// 底部提示：聚合视图下明确下单账户
    private var bottomHint: String {
        guard store.isAllAccountsSelected else {
            return "T+1：当日买入次日可卖 ｜ 佣金万 2.5、最低 5 元 ｜ 卖出印花税千一"
        }
        let name = store.activeAccounts.first?.name ?? "—"
        return "下单账户：\(name)（切换请点左侧账户） ｜ T+1：当日买入次日可卖 ｜ 佣金万 2.5、最低 5 元"
    }

    // MARK: - 改价

    private var amendBinding: Binding<Bool> {
        Binding(get: { amendTarget != nil },
                set: { if !$0 { amendTarget = nil } })
    }

    private func beginAmend(_ order: SimOrder) {
        amendPriceText = order.price.map { SimFormat.price($0) } ?? ""
        amendTarget = order
    }

    private func confirmAmend() async {
        guard let order = amendTarget else { return }
        let price = Double(amendPriceText.filter { $0.isNumber || $0 == "." }) ?? 0
        guard price > 0 else {
            showToast("请输入有效的委托价")
            return
        }
        await store.amendOrderPrice(id: order.id, newPrice: price)
        amendTarget = nil
        showToast("已改价：\(order.name) → \(SimFormat.price(price))")
    }

    // MARK: - 账户与行情

    private func createAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let capital = Double(newAccountCapital.filter { $0.isNumber || $0 == "." }) ?? 100_000
        guard capital > 0 else {
            showToast("初始资金需大于 0")
            return
        }
        Task {
            if let account = await store.createAccount(name: name.isEmpty ? "新账户" : name,
                                                       initialCapital: capital) {
                store.selectedAccountID = account.id
                newAccountName = ""
                newAccountCapital = "100000"
                showToast("已创建账户「\(account.name)」")
            } else {
                showToast("创建账户失败，Python 引擎不可用")
            }
        }
    }

    private func refreshQuotes() async {
        await store.prepareQuotes()
        showToast("已请求最新行情")
    }

    // MARK: - 日志导出

    /// 当前筛选条件下的日志（与表格同一口径）
    private var exportableLogs: [ActionLog] {
        var all = store.actionLogs(accountID: store.queryAccountID)
        if let filter = logModule {
            all = all.filter { $0.module == filter }
        }
        let key = logKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return all }
        return all.filter { $0.content.localizedCaseInsensitiveContains(key) }
    }

    /// 导出当前日志为 CSV 到 Documents/Simulation/
    private func exportLogs() {
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
        return store.accountName(id: id)
    }

    // MARK: - 助手

    /// 账户色块颜色：解析 "#RRGGBB"，失败回退 systemGray
    private func colorFromHex(_ hex: String) -> Color {
        Color(hex: hex) ?? Color(.systemGray)
    }

    /// 盈亏配色（涨红跌绿）
    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    /// 工作区轻提示：2 秒后自动消失
    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if toast == text { toast = nil }
        }
    }
}
