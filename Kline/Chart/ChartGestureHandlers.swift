//
//  ChartGestureHandlers.swift
//  Kline
//
//  图表手势处理：单指拖动状态机（光标/第二光标/副图滑动/平移缩放）、双指手势回调、
//  周期切换与退出窗口推算。从 KlineChartView.swift 拆分（方法平移，private 放宽 internal）。
//

import SwiftUI
import UIKit

extension KlineChartView {

    func chartDragGesture(width: CGFloat, candleSpacing: CGFloat,
                                  mainTop: CGFloat, mainBottom: CGFloat,
                                  s1Top: CGFloat, s1Bottom: CGFloat,
                                  s2Top: CGFloat, s2Bottom: CGFloat,
                                  s3Top: CGFloat, s3Bottom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                // 新触摸立即终止进行中的惯性滑动（含对齐归零）；未在惯性中时为空操作
                cancelPanInertia()
                guard !menuIsOpen else { return }
                // 双指手势进行中：平移/缩放由双指手势统一处理，单指手势跳过，避免重复平移/误触发
                if drag.twoFingerActive { return }
                // 手势作用域固定为起点所在区域：主图/副图1/副图2；滑出起点区域后仍以起点区域处理。
                // 副图3（最下方副图）面板触摸手势**整体禁用**（单指点击/拖动/平移都不响应）：
                // 该区域预留给后续类手游虚拟按钮使用。副图三仍正常显示指标曲线与贯穿光标竖线，
                // 其指标名称/参数按钮在面板外的 legend 行，不受影响（单图/联动多图均走同一图表，同时生效）。
                let sy = value.startLocation.y
                let startInMain = isInPanel(sy, mainTop, mainBottom)
                let startInS1 = isInPanel(sy, s1Top, s1Bottom)
                let startInS2 = isInPanel(sy, s2Top, s2Bottom)
                guard startInMain || startInS1 || startInS2 else { return }
                if !drag.beginLogged {
                    drag.beginLogged = true
                    DebugLogger.shared.log("[惯性手势] 开始 起点y=\(String(format: "%.0f", sy)) 面板=\(startInMain ? "主图" : (startInS1 ? "副图1" : "副图2")) twoFinger=\(drag.twoFingerActive) frozen=\(isLinkedFrozenView) 光标=\(selectedIndex != nil)")
                }
                // 联动会话中非来源的**同周期**视图：忽略一切单指操作
                // （不接管来源、不平移缩放、不放光标；双指平移/缩放在独立手势层，不受影响）
                if isLinkedFrozenView { return }
                // 联动会话中非来源的小周期范围框 / 大周期复盘视图：
                // - 本地第二光标**已存在** → 单指拖动只移动第二光标（不接管来源、不平移缩放）；
                // - 第二光标**不存在** → 不拦截，单指照常走下方 pan/zoom 与副图滑动逻辑（双指缩放在独立手势层，始终可用）。
                if isLinkedSecondCursorView && secondCursorIndex != nil {
                    drag.isDragging = true
                    drag.lastTouchX = value.location.x
                    if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 {
                        let col = Int((value.location.x / candleSpacing).rounded(.down))
                        let idx = startIndex + col
                        if idx >= startIndex && idx <= endIndex {
                            secondCursorIndex = idx
                            secondCursorY = value.location.y
                            drag.secondCursorDragging = true   // 注意：不能写 drag.cursorDragging，否则会隐藏范围框
                        }
                    }
                    return
                }
                drag.isDragging = true
                // 记录最近触摸位置，作为双指缩放时的锚点（双指质心）
                drag.lastTouchX = value.location.x

                // 副图左右滑动切换：起点在副图且无光标时实时更新拖动反馈动画（显示方向提示/滑轨/阈值）
                if (startInS1 || startInS2) && selectedIndex == nil {
                    let slot: SubSlot = startInS1 ? .top : .bottom
                    let (canL, canR) = subSwipeCanLeftRight(slot: slot)
                    let wasNil = swipeFeedback == nil
                    swipeFeedback = SwipeFeedback(slot: slot, offset: value.translation.width,
                                                  canLeft: canL, canRight: canR)
                    // 一次新手势开始（nil → 非 nil）解锁「一次切换只允许回调外层一次」的锁。
                    // 见 swipeSubSlotTriggered 注释。
                    if wasNil {
                        swipeSubSlotTriggered = false
                        DebugLogger.shared.log("[惯性手势] 进入副图滑动分支（该手势不产生横向平移惯性）slot=\(slot)")
                    }
                    return
                }

                if selectedIndex != nil {
                    // 仅当真正拖动（移动超过阈值）时光标跟随手指；纯点击不移动光标，
                    // 避免"点击取消光标"时先跳到触摸位置再消失
                    if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 {
                        let col = Int((value.location.x / candleSpacing).rounded(.down))
                        let idx = startIndex + col
                        if idx >= startIndex && idx <= endIndex {
                            linkUserDragging = true   // 用户直接拖动光标（用于联动来源标记）
                            selectedIndex = idx
                            crosshairY = value.location.y
                        }
                        drag.cursorDragging = true
                    }
                } else if startInMain && drag.dragMode == .none {
                    if abs(value.translation.height) > abs(value.translation.width) && abs(value.translation.height) > 4 {
                        drag.dragMode = .zoom
                        DebugLogger.shared.log("[惯性手势] 模式判定 → zoom（垂直主导 w=\(String(format: "%.1f", value.translation.width)) h=\(String(format: "%.1f", value.translation.height))，该手势不产生横向惯性）")
                    } else if abs(value.translation.width) > 4 {
                        drag.dragMode = .pan
                        drag.resetPanIntent()   // 抬手意图（最后移动时间/方向）从本次平移起点重新累计
                        DebugLogger.shared.log("[惯性手势] 模式判定 → pan（水平平移）")
                    }
                    drag.lastPanWidth = 0; drag.lastPanHeight = 0
                }

                if drag.dragMode == .zoom {
                    let deltaY = value.translation.height - drag.lastPanHeight
                    drag.lastPanHeight = value.translation.height
                    visibleCount = clamp(visibleCount + deltaY * 0.5, 20, CGFloat(capVisibleCount))
                } else if drag.dragMode == .pan {
                    let delta = value.translation.width - drag.lastPanWidth
                    drag.lastPanWidth = value.translation.width
                    // 记录轨迹（停顿计时 + 末段/峰值速度比较 + 净滑动距离）
                    drag.markPanMove(deltaX: delta, totalX: value.translation.width)
                    // 亚像素平滑平移：先累计像素偏移，累计满一根K线间距才进位移动窗口，保证缓慢拖动也平滑跟手
                    panOffset += delta
                    // 到达数据边界时最多滑出屏幕宽度 1/10 的空白，避免把 K 线拖出大片空白
                    let maxOver = width / 10
                    panOffset = clamp(panOffset, -maxOver, maxOver)
                    let shift = Int((panOffset / candleSpacing).rounded())
                    if shift != 0 {
                        let newOffset = clamp(endOffset + shift, 0, max(0, sortedData.count - count))
                        let applied = newOffset - endOffset
                        endOffset = newOffset
                        panOffset -= CGFloat(applied) * candleSpacing
                    }
                }
                // 手势不暂停后台预计算：进度条持续推进到消失；
                // 松开后 startPrefetch 会因 token 仍在（任务在跑）而直接跳过，不会重复启动
            }
            .onEnded { value in
                // 惯性判定：仅「主图区平移拖动」抬手时触发；四条件（停顿/距离/末段同向/末段未明显减速）见 releaseDirection。
                // 光标拖动（dragMode == .none）、副图滑动切换、垂直缩放均不产生惯性。
                let wasPan = drag.dragMode == .pan
                let flingDir: CGFloat = drag.releaseDirection(isPanGesture: wasPan, width: width, source: "单指")
                let endStartMain = isInPanel(value.startLocation.y, mainTop, mainBottom)
                DebugLogger.shared.log("[惯性手势] 抬手 pan=\(wasPan) 方向=\(flingDir) 起点主图=\(endStartMain) menu=\(menuIsOpen) frozen=\(isLinkedFrozenView) 光标=\(selectedIndex != nil) 副图滑动=\(swipeFeedback != nil) endOffset=\(endOffset) maxOffset=\(max(0, sortedData.count - count)) panOffset=\(String(format: "%.1f", panOffset)) count=\(count) data=\(sortedData.count)")
                drag.beginLogged = false
                drag.lastPanWidth = 0; drag.lastPanHeight = 0; drag.dragMode = .none
                // 兜底：无论手势如何结束（含双指手势被中断），都清除双指状态，避免残留拦截后续单指拖动
                drag.twoFingerActive = false
                // 联动非来源的**同周期**视图：单指手势全程忽略，不产生任何光标/窗口变化
                if isLinkedFrozenView {
                    drag.isDragging = false
                    drag.cursorDragging = false
                    drag.secondCursorDragging = false
                    return
                }
                // 联动非来源的小周期范围框 / 大周期复盘视图且本地第二光标**已存在**：
                // 拖动结束复位标记；轻点则只在本地取消第二光标（不发布、不影响来源视图的
                // 合成/范围框与其他视图；整组联动的取消仍由来源视图再点一下负责）。
                // 第二光标不存在时不走这里——复盘/范围框视图的拖动是正常 pan/zoom，轻点在下方放置第二光标。
                if isLinkedSecondCursorView && secondCursorIndex != nil {
                    let wasSecondDragging = drag.secondCursorDragging
                    drag.isDragging = false
                    drag.secondCursorDragging = false
                    panOffset = 0
                    guard !menuIsOpen, !suppressCrosshair else { return }
                    if !wasSecondDragging {
                        let y = value.location.y
                        let inPanel = isInPanel(y, mainTop, mainBottom)
                            || isInPanel(y, s1Top, s1Bottom) || isInPanel(y, s2Top, s2Bottom)
                        let isTap = abs(value.translation.width) < 6 && abs(value.translation.height) < 6
                        if isTap && inPanel { clearSecondCursor() }
                    }
                    return
                }
                // 关键：无论手势如何结束（含提前 return 的分支），都必须重置拖拽状态，
                // 否则 isDragging 一直为 true，后续切换/修改指标的重算都会被跳过
                drag.isDragging = false
                // 用户拖动结束，清除联动来源标记（之后的光标变化都是回声/联动，不再触发左侧居中）
                linkUserDragging = false
                // 平移/缩放会改变可见窗口，指标裁剪区间需跟随；这里无条件重算一次。
                // 无窗口变化（如轻点）时裁剪区间缓存键不变，直接复用缓存，开销几乎为零
                drag.needsRefreshAfterDrag = false
                // 四条件全部满足的甩动抬手 → 启动横向惯性滑动：沿滑动主方向匀速
                // 滑行 2 秒、走 2 屏K线，到点（或撞到数据边界）直接停在对齐位置。
                // 停顿/短距微调/末段减速或反向回位：不启动惯性（panOffset 立即对齐归零）。
                // 惯性期间平移推进与本 pan 分支同构；对齐归零/重算/预取延迟到惯性结束。
                if startPanInertia(direction: flingDir, width: width, candleSpacing: candleSpacing) { return }
                panOffset = 0
                refreshCurves()
                // 拖动结束，恢复后台历史预计算（从当前已覆盖区间继续向历史扩展）
                startPrefetch()
                guard !menuIsOpen else { drag.cursorDragging = false; return }
                // 副图滑动切换结算：超过阈值触发切换，否则回弹取消（动画由 overlay 呈现）
                if let fb = swipeFeedback {
                    // 非来源复盘/范围框视图在副图区的**轻点**（第二光标不存在时手势才会走到这里）：
                    // 第二光标只允许在主图区域放置，副图一/副图二区域轻点仅回弹滑动反馈，
                    // 不放置第二光标、不触发切周期/标的（副图三面板手势本就整体禁用）
                    if isLinkedSecondCursorView,
                       abs(value.translation.width) < 6, abs(value.translation.height) < 6 {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { swipeFeedback = nil }
                        return
                    }
                    let threshold: CGFloat = 70
                    let dir = fb.offset > 0 ? -1 : 1   // 右滑=更小周期/上一个标的，左滑=更大周期/下一个标的
                    // 副图一（上方副图）作用调转：往左=切换小级别/上一个标的，往右=切换大级别/下一个标的
                    let topDir = -dir
                    let triggeredSwitch: Bool
                    if abs(fb.offset) > threshold {
                        // 一次性锁：同一次 swipeFeedback 手势生命周期，外层回调只许一次
                        if !swipeSubSlotTriggered {
                            swipeSubSlotTriggered = true
                            selectedIndex = nil; crosshairY = nil
                            clearSecondCursor()
                            // 联动态：副图一切标的、副图二切周期（与常规模式交换角色的作用域）
                            if swapSubSwipeRoles {
                                if fb.slot == .top {
                                    onSwitchItem?(topDir)
                                } else {
                                    switchPeriod(direction: dir)
                                }
                            } else if fb.slot == .top {
                                switchPeriod(direction: topDir)
                            } else {
                                onSwitchItem?(dir)
                            }
                            triggeredSwitch = true
                        } else {
                            DebugLogger.shared.log("[副图滑动] 一次性锁生效，屏蔽重复回调 slot=\(fb.slot) dir=\(dir) offset=\(fb.offset) period=\(self.period.rawValue)")
                            triggeredSwitch = false
                        }
                    } else {
                        triggeredSwitch = false
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { swipeFeedback = nil }
                    // 若发生了真正的周期/标的切换，外层会立刻改 view.period → chartIdentity 变化 →
                    // 本 SwiftUI KlineChartView 实例即将被销毁。此时再清锁已经没有意义。
                    // 如果没有触发切换，仍然解锁下一次"新的 swipeFeedback 创建"时再清（见 onChanged）。
                    _ = triggeredSwitch
                    return
                }
                if drag.cursorDragging { drag.cursorDragging = false; return }
                let y = value.location.y
                // 轻点放置/取消光标的作用域同样不含副图3（面板手势已禁用，预留给虚拟按钮）
                let inPanel = isInPanel(y, mainTop, mainBottom) || isInPanel(y, s1Top, s1Bottom) || isInPanel(y, s2Top, s2Bottom)
                let isTap = abs(value.translation.width) < 6 && abs(value.translation.height) < 6
                // 「边」调节分割线时禁止产生/清除十字光标
                if suppressCrosshair { return }
                if isTap && inPanel {
                    let col = Int((value.location.x / candleSpacing).rounded(.down))
                    let idx = startIndex + col
                    if isLinkedSecondCursorView {
                        // 非来源复盘/范围框视图：轻点放置纯本地第二光标（走到这里时它必然不存在），
                        // 不设联动来源标记、不写 selectedIndex，因此不会接管来源/广播给其他视图，
                        // 复盘视图里再点也只取消本地第二光标，绝无可能取消整组联动。
                        // 仅限主图区域轻点放置：副图一/副图二区域轻点不放（副图三面板手势整体禁用）。
                        if isInPanel(y, mainTop, mainBottom), idx >= startIndex && idx <= endIndex {
                            secondCursorIndex = idx
                            secondCursorY = y
                        }
                    } else {
                        // 点击（无论放置还是清除光标）都视为用户直接操作（联动来源），
                        // 让本次取消/放置都能被联动到其它视图
                        linkUserDragging = true
                        if selectedIndex != nil {
                            selectedIndex = nil; crosshairY = nil
                        } else if idx >= startIndex && idx <= endIndex {
                            // 点击创建光标也视为用户直接操作（联动来源标记），使右视图点击能同步到左视图
                            selectedIndex = idx; crosshairY = value.location.y
                        }
                    }
                }
            }
    }

    /// 第一副图横向滑动切换周期：direction = 1 更大级别（右滑）/ -1 更小级别（左滑）；无对应周期时忽略
    func switchPeriod(direction: Int) {
        guard let onPeriodSwitch else { return }
        let cases = KlinePeriod.allCases
        guard let cur = cases.firstIndex(of: period) else { return }
        let target = cur + direction
        guard target >= 0, target < cases.count else { return }
        onPeriodSwitch(cases[target])
    }

    /// 记录当前图表的周期与指标配置状态到沙盒 debug_log.txt（供外部自动化校验）
    func logChartState() {
        let mains = config.mainIndicators(for: self.period).sorted().joined(separator: ",")
        let subs = config.subSelections(for: self.period)
            .map { sel in sel.customID.map { "\(sel.kind)#\(String($0.uuidString.prefix(8)))" } ?? sel.kind }
            .joined(separator: ",")
        let custom = config.activeCustomIndicatorID(for: self.period)
            .map { String($0.uuidString.prefix(8)) } ?? "无"
        DebugLogger.shared.log("图表出现 标的:\(metaId.map(String.init) ?? "无") 周期:\(self.period.rawValue) 主图:[\(mains)] 副图:[\(subs)] 自定义:\(custom)")
    }

    /// 某方向是否存在可切换的周期（-1 更小 / +1 更大），用于副图滑动方向提示
    func canSwitchPeriod(_ dir: Int) -> Bool {
        let cases = KlinePeriod.allCases
        guard let cur = cases.firstIndex(of: period) else { return false }
        let target = cur + dir
        return target >= 0 && target < cases.count
    }

    /// 副图滑动方向可切换提示：尊重 swapSubSwipeRoles（联动态副图一切标的、副图二切周期）
    func subSwipeCanLeftRight(slot: SubSlot) -> (Bool, Bool) {
        if swapSubSwipeRoles {
            // 副图一(上)切标的，副图二(下)切周期
            if slot == .top {
                return (canSwitchItem?(-1) ?? false, canSwitchItem?(1) ?? false)
            } else {
                return (canSwitchPeriod(-1), canSwitchPeriod(1))
            }
        } else {
            if slot == .top {
                return (canSwitchPeriod(-1), canSwitchPeriod(1))
            } else {
                return (canSwitchItem?(-1) ?? false, canSwitchItem?(1) ?? false)
            }
        }
    }

    // MARK: - 双指手势（由 TwoFingerGestureHook 回调驱动）

    /// 双指手势开始：以双指质心起始位置对应K线为缩放锚点，初始化缩放基准
    func handleTwoFingerBegin(centroidX: CGFloat, width: CGFloat) {
        drag.twoFingerActive = true
        // 双指接管：终止进行中的惯性滑动，并取消单指 pan 状态（否则抬手时会用
        // 双指接管前的陈旧移动记录误触发一次惯性）；抬手意图状态清零，从双指质心重新累计
        cancelPanInertia()
        drag.dragMode = .none
        drag.lastPanWidth = 0
        drag.resetPanIntent()
        // 双指手势接管：复位单指光标拖动状态，避免粘滞导致联动被忽略
        linkUserDragging = false
        drag.cursorDragging = false
        selectedIndex = nil; crosshairY = nil
        clearSecondCursor()
        zoomBase = visibleCount
        zoomAnchorIndex = nil
        let spacing = width / CGFloat(max(1, count))
        let anchor = startIndex + Int((max(0, centroidX) / spacing).rounded(.down))
        zoomAnchorIndex = clamp(anchor, 0, max(0, sortedData.count - 1))
        zoomAnchorOffset = (CGFloat(zoomAnchorIndex! - startIndex) + 0.5) * spacing
        // 手势不暂停后台预计算：进度条持续推进到消失
    }

    /// 双指手势中：质心横向位移 dx → 平移（锚点K线随双指移动）；缩放 scale → 围绕锚点缩放
    func handleTwoFingerChange(scale: CGFloat, centroidDeltaX: CGFloat, width: CGFloat) {
        guard drag.twoFingerActive else { return }
        // 记录轨迹（与单指同源；纯缩放 deltaX=0 时不刷新不计轨迹）
        drag.twoFingerTravelX += centroidDeltaX
        drag.markPanMove(deltaX: centroidDeltaX, totalX: drag.twoFingerTravelX)
        // 平移：锚点屏幕位置随双指质心整体横向位移移动
        zoomAnchorOffset += centroidDeltaX
        // 缩放：围绕锚点缩放（锚点K线保持在同一屏幕位置）
        let newCountF = clamp(zoomBase / scale, 20, CGFloat(capVisibleCount))
        let newCount = max(1, Int(newCountF.rounded()))
        visibleCount = newCountF
        if let anchor = zoomAnchorIndex {
            let spacing1 = width / CGFloat(newCount)
            let newStartF = CGFloat(anchor) - zoomAnchorOffset / spacing1 + 0.5
            let newStart = Int(newStartF.rounded())
            let newEnd = newStart + newCount - 1
            let maxEnd = sortedData.count - 1
            let minEnd = max(0, newCount - 1)
            let clampedEnd = min(maxEnd, max(minEnd, newEnd))
            endOffset = maxEnd - clampedEnd
        }
    }

    /// 双指手势结束：复位缩放状态；双指快速横向滑动抬手 → 与单指一致的惯性滑动，
    /// 恢复后台历史预计算（惯性启动时延迟到惯性结束再做）
    func handleTwoFingerEnd(width: CGFloat) {
        zoomBase = visibleCount
        zoomAnchorIndex = nil
        zoomAnchorOffset = 0
        drag.twoFingerActive = false
        // 与单指同一判定（停顿/距离/末段同向/末段未明显减速），方向取滑动主方向
        let dir = drag.releaseDirection(isPanGesture: true, width: width, source: "双指")
        drag.resetPanIntent()
        // 联动冻结视图（非来源同周期）不产生惯性
        if !isLinkedFrozenView {
            let spacing = width / CGFloat(max(1, count))
            if startPanInertia(direction: dir, width: width, candleSpacing: spacing, source: "双指") { return }
        }
        startPrefetch()
    }

    /// 退出放大时按十字光标设定可见窗口：
    /// - 两个光标 A/B：显示 A前10根 + A + A与B之间 + B + B后10根
    /// - 一个光标：以光标为中心显示 100 根（前49 + 光标 + 后50）
    /// - 无光标：保持最新 100 根
    func applyExitWindowFromCursors() {
        let maxEnd = max(0, sortedData.count - 1)
        // 两个光标（固定光标 + 活动光标）：A=左、B=右，显示 [A-10 ... B+10]
        if let aIdx = pinnedIndex, let bIdx = renderCursorIndex, aIdx != bIdx {
            let left = min(aIdx, bIdx)
            let right = max(aIdx, bIdx)
            let start = max(0, left - 10)
            let end = min(maxEnd, right + 10)
            visibleCount = CGFloat(max(20, end - start + 1))
            endOffset = max(0, maxEnd - end)
            return
        }
        // 一个光标：以光标所在K线为中心，前 49 + 1 + 后 50 = 100 根
        if let center = renderCursorIndex ?? pinnedIndex {
            let start = clamp(center - 49, 0, max(0, maxEnd - 99))
            let end = min(maxEnd, start + 99)
            visibleCount = 100
            endOffset = max(0, maxEnd - end)
            return
        }
        // 无光标：恢复最新 100 根
        visibleCount = 100
        endOffset = 0
    }

    /// 生成覆盖单个图表面板区域的双指手势层（按面板分片，不覆盖 legend 行的按钮）
    func twoFingerLayer(width: CGFloat, rect: CGRect) -> some View {
        TwoFingerGestureHook(
            onBegin: { cx in handleTwoFingerBegin(centroidX: cx, width: width) },
            onChange: { scale, dx in handleTwoFingerChange(scale: scale, centroidDeltaX: dx, width: width) },
            onEnd: { handleTwoFingerEnd(width: width) }
        )
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

}
