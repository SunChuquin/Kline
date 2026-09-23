//
//  FloatingAccessoryCoordinator.swift
//  Kline
//
//  两个悬浮按钮共享的协调对象（单例）：记录当前正在手势中的按钮、是否处于转圈驱动期，
//  承载「新按钮转圈 → 图表光标」的命令通道，以及两按钮的耦合（同侧互斥 / 手势期间强制闲置）。
//  注：两个按钮都不 @ObservedObject 观察本对象（避免高频发布引发整树重算），
//  只订阅各自关心的 @Published 事件，并把「已知侧」当普通状态在 onChanged 里主动读取。
//

import Combine

/// 悬浮按钮归属：primary = 旧按钮，secondary = 新按钮
enum FloatingAccessoryOwner: Hashable {
    case primary
    case secondary

    /// 另一个按钮
    var other: FloatingAccessoryOwner { self == .primary ? .secondary : .primary }
}

/// 光标推进命令。带单调递增序号 `seq`：连续两次同值推进（例如各推进 1 根）也能被消费端
/// 区分成两条新命令；消费端只按 `seq` 判新鲜度，不与上一次的 candles 比较
struct FloatingAccessoryCursorAdvance: Equatable {
    /// 单调递增序号（同一次会话内唯一）
    let seq: Int
    /// 本次要推进的 K 线根数：正 = 向右（更晚），负 = 向左（更早）
    let candles: Int
}

/// 吸附请求：要求指定按钮立即吸附到某一侧（纵向保持）。
/// 带单调递增 `seq`：同一目标侧的连续两次请求也是两条不同请求，不会被按值去重
struct FloatingAccessorySnapRequest: Equatable {
    /// 单调递增序号
    let seq: Int
    /// 需要吸附的按钮
    let owner: FloatingAccessoryOwner
    /// 吸附到哪一侧
    let side: FloatingAccessoryPlacement.Side
}

/// 窗口平移命令（点击新按钮 B' 产生）。同样带 `seq`：订阅重放与「连续两次同值平移」都要能区分
struct FloatingAccessoryWindowNudge: Equatable {
    /// 单调递增序号（同一次会话内唯一）
    let seq: Int
    /// 平移根数：正 = 朝**更新**的方向（屏幕上 K 线整体左移、右缘进来一根更晚的）；负 = 朝更早方向
    let candles: Int
}

/// 两个悬浮按钮共享的协调对象
final class FloatingAccessoryCoordinator: ObservableObject {
    static let shared = FloatingAccessoryCoordinator()

    /// 当前正处于手势中的按钮（摁住 / 拖动 / 环上转圈）；nil = 无
    @Published private(set) var activeOwner: FloatingAccessoryOwner?
    /// 是否正处于「环上转圈」的驱动期（供图表判断程序化驱动期）
    @Published private(set) var isRotating = false
    /// 联动多图模式下「光标正在自动移动」（贴边自动滚动，**抬手后仍在继续**）：
    /// 为真时两个悬浮按钮一起隐藏、让出正在自动滚动的图表，滚动停止即恢复。
    /// 只由多图 tile 上报（见 KlineChartView 的 reportCursorAutoMoving），故单图模式的自动滚动不会隐藏按钮
    @Published private(set) var isCursorAutoMoving = false

    /// K 线详情页是否有任何弹窗打开（设置面板 / 搜索栏 / 公式编辑器 / confirmationDialog / 钻取等）：
    /// 为真时两个悬浮按钮一起隐藏、避免压在弹窗遮罩之上；弹窗全部关闭即恢复。
    /// 只由 KlineDetailView 通过 setDetailViewPopupActive 推送（聚合自身所有弹窗 state）
    @Published private(set) var isDetailViewPopupActive = false

    /// K 线详情页首屏是否已加载完成（单图 = 主 series 查询结束；联动 = 主 series + 全部 tile 首屏加载结束）。
    /// 为假时两个悬浮按钮一起隐藏 —— 页面还在转圈 / 白屏时按钮不该先露面，数据到位后再出现。
    /// 只由 KlineDetailView 通过 setDetailViewLoaded 推送；页面关闭即复位 false。
    @Published private(set) var isDetailViewLoaded = false
    /// 最新光标推进命令。订阅方建立订阅时会立即收到当前值，故消费端必须用 `seq` 去重。
    /// （不设 private(set)：图表需要订阅投影值 `$cursorAdvance`；只由 advanceCursor(by:) 写入）
    @Published var cursorAdvance: FloatingAccessoryCursorAdvance?

    /// 最新窗口平移命令。与 cursorAdvance 同样开放订阅投影值 `$windowNudge`，故不设 private(set)
    @Published var windowNudge: FloatingAccessoryWindowNudge?

    /// 「清除屏幕上全部视图所有光标」请求计数（点击 B' 的第 1 步）。
    /// 用自增 Int 而非 Bool：每次点击都是一次**新**请求，订阅方按值变化触发即可（配 dropFirst 挡掉订阅重放）。
    /// 由 `KlineDetailView` 消费 —— 它才是 `cursorClearToken` 与 `linkSync` 的持有者，能一次清掉**所有**格
    @Published private(set) var clearAllCursorsSeq = 0

    /// 序号自增源（只增不减，保证同值命令也能被识别为新命令）
    private var advanceSeq = 0
    private var nudgeSeq = 0

    /// 最新吸附请求（订阅方按 owner 认领；带 seq 区分同目标侧的连续请求）
    @Published private(set) var snapRequest: FloatingAccessorySnapRequest?
    /// 各按钮「已知所在侧」：普通内存态、不发布 —— 只需被拖方在 onChanged 每帧主动读取，
    /// 这样即使每帧判定也不会引发任何视图重算
    private var knownSides: [FloatingAccessoryOwner: FloatingAccessoryPlacement.Side] = [:]
    /// 吸附请求序号自增源
    private var snapSeq = 0

    private init() {}

    // MARK: - 手势占用

    /// 手势开始（含环上转圈）。值未变化时不赋值 —— @Published 每次赋值都会发布，
    /// onChanged 每帧调用它，无此守卫会造成发布风暴
    func beginGesture(_ owner: FloatingAccessoryOwner) {
        if activeOwner != owner { activeOwner = owner }
    }

    /// 手势结束
    func endGesture(_ owner: FloatingAccessoryOwner) {
        if activeOwner == owner { activeOwner = nil }
    }

    /// 转圈手势起止（幂等，仅在实际变化时发布）
    func setRotating(_ rotating: Bool) {
        if isRotating != rotating { isRotating = rotating }
    }

    /// 上报「光标正在自动移动」起止（幂等，仅在实际变化时发布）
    func setCursorAutoMoving(_ on: Bool) {
        if isCursorAutoMoving != on { isCursorAutoMoving = on }
    }

    /// 上报「K 线详情页有弹窗打开」起止（幂等，仅在实际变化时发布）。
    /// 由 KlineDetailView 聚合所有弹窗 state 后推送（避免让 ContentView 观察一堆细节）
    func setDetailViewPopupActive(_ on: Bool) {
        if isDetailViewPopupActive != on { isDetailViewPopupActive = on }
    }

    /// 上报「K 线详情页首屏是否已加载完成」起止（幂等，仅在实际变化时发布）。
    /// 由 KlineDetailView 锁存推送：一旦为真不再回退（后续切周期 / 静默热刷新不重新隐藏按钮），
    /// 页面关闭时复位 false，保证下次打开仍是「先隐藏、加载完再出现」
    func setDetailViewLoaded(_ on: Bool) {
        if isDetailViewLoaded != on { isDetailViewLoaded = on }
    }

    // MARK: - 同侧互斥（实时，不等抬手）

    /// 读取某按钮已知所在侧（nil = 尚未上报：此时不做互斥判定，避免误发请求）
    func knownSide(of owner: FloatingAccessoryOwner) -> FloatingAccessoryPlacement.Side? {
        knownSides[owner]
    }

    /// 上报某按钮当前所在侧（值未变时不写、不发布，可安全在每帧调用）
    func reportSide(_ owner: FloatingAccessoryOwner, _ side: FloatingAccessoryPlacement.Side) {
        if knownSides[owner] != side { knownSides[owner] = side }
    }

    /// 拖动中每帧调用：上报本按钮所在侧；若另一方与它同侧，则请求另一方反向吸附。
    /// 幂等：`requestSnap` 会把另一方的已知侧**乐观**改写成目标侧，故同一状态每帧只发一次请求
    /// （不会重复对同一属性赋动画值）；越过中线再拖回时已知侧来回翻转，于是能反向吸附两次
    func reportDrag(owner: FloatingAccessoryOwner, side: FloatingAccessoryPlacement.Side) {
        reportSide(owner, side)
        let other = owner.other
        guard knownSides[other] == side else { return }
        requestSnap(other, to: side.opposite)
    }

    /// 请求「把 owner 立即吸附到 side」：已知侧已是目标侧则忽略（幂等）；
    /// 否则乐观上报目标侧并发布一次请求 —— 乐观上报让被拖方的幂等判定立即成立
    func requestSnap(_ owner: FloatingAccessoryOwner, to side: FloatingAccessoryPlacement.Side) {
        guard knownSides[owner] != side else { return }
        knownSides[owner] = side
        snapSeq += 1
        snapRequest = FloatingAccessorySnapRequest(seq: snapSeq, owner: owner, side: side)
    }

    // MARK: - 光标命令

    /// 发布「推进 candles 根」；candles == 0 不发（避免无意义的空命令）
    func advanceCursor(by candles: Int) {
        guard candles != 0 else { return }
        advanceSeq += 1
        cursorAdvance = FloatingAccessoryCursorAdvance(seq: advanceSeq, candles: candles)
    }

    // MARK: - 窗口平移命令（点击 B'）

    /// 第 1 步：请求清除屏幕上全部视图的所有光标（由 KlineDetailView 统一清）
    func clearAllCursors() {
        clearAllCursorsSeq += 1
    }

    /// 第 2 步：发布「把被驱动那一格的可见窗口平移 candles 根」；candles == 0 不发
    func nudgeWindow(by candles: Int) {
        guard candles != 0 else { return }
        nudgeSeq += 1
        windowNudge = FloatingAccessoryWindowNudge(seq: nudgeSeq, candles: candles)
    }
}