//
//  FloatingAccessoryCoordinator.swift
//  Kline
//
//  两个悬浮按钮共享的协调对象（单例）：记录当前正在手势中的按钮、是否处于转圈驱动期，
//  并承载「新按钮转圈 → 图表光标」的命令通道。
//  本阶段只落地命令通道与基础 API：同侧互斥 / 手势期间强制闲置（第 6 阶段）、
//  贴边反向滚动与多图联动语义（第 4 / 5 阶段）后续接入，届时复用这里的同一组状态。
//

import Combine

/// 悬浮按钮归属：primary = 旧按钮，secondary = 新按钮
enum FloatingAccessoryOwner: Hashable {
    case primary
    case secondary
}

/// 光标推进命令。带单调递增序号 `seq`：连续两次同值推进（例如各推进 1 根）也能被消费端
/// 区分成两条新命令；消费端只按 `seq` 判新鲜度，不与上一次的 candles 比较
struct FloatingAccessoryCursorAdvance: Equatable {
    /// 单调递增序号（同一次会话内唯一）
    let seq: Int
    /// 本次要推进的 K 线根数：正 = 向右（更晚），负 = 向左（更早）
    let candles: Int
}

/// 两个悬浮按钮共享的协调对象
final class FloatingAccessoryCoordinator: ObservableObject {
    static let shared = FloatingAccessoryCoordinator()

    /// 当前正处于手势中的按钮（摁住 / 拖动 / 环上转圈）；nil = 无
    @Published private(set) var activeOwner: FloatingAccessoryOwner?
    /// 是否正处于「环上转圈」的驱动期（供图表判断程序化驱动期）
    @Published private(set) var isRotating = false
    /// 最新光标推进命令。订阅方建立订阅时会立即收到当前值，故消费端必须用 `seq` 去重。
    /// （不设 private(set)：图表需要订阅投影值 `$cursorAdvance`；只由 advanceCursor(by:) 写入）
    @Published var cursorAdvance: FloatingAccessoryCursorAdvance?

    /// 序号自增源（只增不减，保证同值命令也能被识别为新命令）
    private var advanceSeq = 0

    private init() {}

    // MARK: - 手势占用

    /// 手势开始（本阶段只是登记；强制对方闲置等效果属第 6 阶段）
    func beginGesture(_ owner: FloatingAccessoryOwner) {
        activeOwner = owner
    }

    /// 手势结束
    func endGesture(_ owner: FloatingAccessoryOwner) {
        if activeOwner == owner { activeOwner = nil }
    }

    /// 转圈手势起止（幂等，仅在实际变化时发布）
    func setRotating(_ rotating: Bool) {
        if isRotating != rotating { isRotating = rotating }
    }

    // MARK: - 光标命令

    /// 发布「推进 candles 根」；candles == 0 不发（避免无意义的空命令）
    func advanceCursor(by candles: Int) {
        guard candles != 0 else { return }
        advanceSeq += 1
        cursorAdvance = FloatingAccessoryCursorAdvance(seq: advanceSeq, candles: candles)
    }
}