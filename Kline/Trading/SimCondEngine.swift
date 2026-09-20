//
//  SimCondEngine.swift
//  Kline
//
//  条件单触发引擎：SimStore 的扩展。统一结算入口 sweepConditions(trigger:) 在
//  「行情刷新 / 手动检查 / 数据重载」时机结算全部监控中的条件单：
//  重入保护 → 有效期判定 → 取行情快照 → 纯函数判定 → 组装 SimOrderDraft 走既有 submit
//  （不新增旁路下单逻辑，生成的委托带 originCondID 回链）。
//  约定：整轮结算只在结尾写盘一次；写回一律先比较再赋值（沿用 @Published 写入守卫）；
//  单次类型触发成功置 triggered、失败置 rejected（不重试）；多触发类型（网格 / 分批）
//  失败保持 monitoring 并记因，走完全部档位 / 批次后置 completed。
//

import Foundation

// MARK: - 触发源与结果

/// 结算触发源
enum SimCondTrigger {
    case quoteRefresh
    case manual
    case dataReload
}

/// 单轮结算结果（供「立即检查」就地提示）
struct SimCondSweepResult {
    var evaluated = 0
    var fired = 0
    var rejected = 0
    var expired = 0

    var message: String {
        var parts: [String] = []
        if fired > 0 { parts.append("触发 \(fired) 笔") }
        if rejected > 0 { parts.append("被拒 \(rejected) 笔") }
        if expired > 0 { parts.append("失效 \(expired) 笔") }
        guard !parts.isEmpty else { return "本次检查无触发" }
        return "本次检查" + parts.joined(separator: " · ")
    }
}

// MARK: - 引擎

extension SimStore {

    /// 统一结算入口：先判有效期 → 取快照 → 判定 → 下发委托。
    /// 已在结算中直接返回空结果（不重入）。
    @discardableResult
    func sweepConditions(trigger: SimCondTrigger) -> SimCondSweepResult {
        var result = SimCondSweepResult()
        guard !condSweepInFlight else { return result }
        condSweepInFlight = true
        defer { condSweepInFlight = false }

        let monitoring = conditionalOrders.filter { $0.status == .monitoring }
        guard !monitoring.isEmpty else { return result }

        var list = conditionalOrders
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var dirty = false

        for candidate in monitoring {
            guard let idx = list.firstIndex(where: { $0.id == candidate.id }) else { continue }
            guard list[idx].status == .monitoring else { continue }
            result.evaluated += 1

            // 1) 有效期优先判定
            if let reason = expiredReason(of: list[idx], today: today, calendar: calendar) {
                list[idx].status = .expired
                list[idx].updatedAt = now
                list[idx].runtime.lastEvaluatedAt = now
                list[idx].runtime.lastMessage = reason
                result.expired += 1
                dirty = true
                appendLog(conditionLog(order: list[idx],
                                       content: "条件单失效 \(list[idx].name) · \(list[idx].kind.title)：\(reason)",
                                       result: list[idx].status.title, at: now))
                continue
            }

            // 2) 取快照 → 3) 纯函数判定 → 4) 下发
            let snapshot = SimCondSnapshotCenter.snapshot(for: list[idx])
            switch SimCondRule.evaluate(order: list[idx], snapshot: snapshot) {

            case .hold(let runtime):
                // 值未变则不写（避免 @Published 发布风暴）
                if list[idx].runtime != runtime {
                    list[idx].runtime = runtime
                    list[idx].updatedAt = now
                    dirty = true
                }

            case .abort(let reason):
                list[idx].status = .expired
                list[idx].updatedAt = now
                list[idx].runtime.lastEvaluatedAt = now
                list[idx].runtime.lastMessage = reason
                result.expired += 1
                dirty = true
                appendLog(conditionLog(order: list[idx],
                                       content: "条件单失效 \(list[idx].name) · \(list[idx].kind.title)：\(reason)",
                                       result: list[idx].status.title, at: now))

            case .fire(let qty, let at):
                list[idx] = fireCondOrder(list[idx], qty: qty, at: at,
                                          snapshot: snapshot, now: now, result: &result)
                dirty = true
            }
        }

        // 5) 整轮结算只写盘一次，且确实有写入时才写
        if dirty {
            assignConditionalOrders(list)
            saveToDisk()
        }
        return result
    }

    // MARK: - 触发分支

    /// 触发：组装草稿 → 走既有 submit → 回写状态；返回更新后的条件单
    private func fireCondOrder(_ order: SimCondOrder, qty: Int, at triggerPrice: Double,
                               snapshot: SimCondSnapshot, now: Date,
                               result: inout SimCondSweepResult) -> SimCondOrder {
        var target = order
        let direction = fireDirection(order: order, triggerPrice: triggerPrice)
        let price = executionPrice(directive: order.directive, triggerPrice: triggerPrice)

        var draft = SimOrderDraft(accountID: order.accountID, metaID: order.metaID,
                                  code: order.code, name: order.name, direction: direction,
                                  priceType: order.directive.priceType, price: price, qty: qty)
        draft.originCondID = order.id

        target.runtime.lastEvaluatedAt = now
        target.runtime.lastPrice = snapshot.last ?? target.runtime.lastPrice
        target.runtime.lastTriggerPrice = triggerPrice
        target.updatedAt = now
        target.triggeredCount += 1

        switch submit(draft) {
        case .success(let generated):
            target.originOrderID = generated.id
            result.fired += 1
            if target.kind.repeatable {
                // 多触发：档位 / 批次推进后继续监控，走完则已完成
                target.runtime = advanceRepeatable(order: target, triggerPrice: triggerPrice)
                if repeatableFinished(order: target) {
                    target.status = .completed
                    target.runtime.lastMessage = target.kind == .grid ? "已完成全部档位" : "已完成全部批次"
                } else if target.kind == .grid {
                    target.runtime.lastMessage = "已成交第 \(target.runtime.gridLevel ?? 0) 档"
                } else {
                    target.runtime.lastMessage = "已成交第 \(target.runtime.batchDone) 批"
                }
            } else {
                target.status = .triggered
                target.triggeredAt = now
                target.runtime.lastMessage = "已触发并生成委托"
            }
            appendLog(conditionLog(order: target,
                                   content: "条件单触发 \(target.name) · \(target.kind.title)："
                                       + SimCondRule.directiveCore(target),
                                   result: generated.status.title, at: now))

        case .failure(let rejection):
            result.rejected += 1
            target.runtime.lastMessage = rejection.message
            // 单次类型触发后被拒 → 置 rejected，不重试；多触发类型保持监控继续下一档
            if !target.kind.repeatable {
                target.status = .rejected
            }
            appendLog(conditionLog(order: target,
                                   content: "条件单触发被拒 \(target.name) · \(target.kind.title)："
                                       + rejection.message,
                                   result: target.status.title, at: now))
        }
        return target
    }

    // MARK: - 有效期

    /// 有效期判定：返回非 nil 即为失效原因（长期有效不因时间失效）
    private func expiredReason(of order: SimCondOrder, today: Date, calendar: Calendar) -> String? {
        switch order.validity {
        case .longTerm:
            return nil
        case .day:
            return calendar.startOfDay(for: order.createdAt) < today ? "当日有效条件单已跨日失效" : nil
        case .untilDate:
            guard let expiresAt = order.expiresAt else { return nil }
            return calendar.startOfDay(for: expiresAt) < today ? "已超过指定有效期" : nil
        }
    }

    // MARK: - 触发辅助

    /// 触发方向：网格按「相对上一次触发价下移买入 / 上移卖出」双向推进，其余类型用用户设定方向
    private func fireDirection(order: SimCondOrder, triggerPrice: Double) -> SimOrderDirection {
        guard order.kind == .grid else { return order.directive.direction }
        let base = order.runtime.gridLastPrice ?? order.params.gridBase ?? triggerPrice
        return triggerPrice < base ? .buy : .sell
    }

    /// 触发价 → 委托价：市价单不带价；限价单 = 触发价 + N 档（下限 0.01）
    private func executionPrice(directive: SimCondDirective, triggerPrice: Double) -> Double? {
        guard directive.priceType == .limit else { return nil }
        let tick = SimTradingRules.default.priceTick
        return max(triggerPrice + Double(directive.offsetTicks) * tick, 0.01)
    }

    /// 多触发类型的档位 / 批次推进（网格记档位与本次触发价，分批记笔数）
    private func advanceRepeatable(order: SimCondOrder, triggerPrice: Double) -> SimCondRuntime {
        var runtime = order.runtime
        switch order.kind {
        case .grid:
            runtime.gridLevel = (runtime.gridLevel ?? 0) + 1
            runtime.gridLastPrice = triggerPrice
        case .batch:
            runtime.batchDone += 1
        default:
            break
        }
        return runtime
    }

    /// 多触发类型是否已走完全部档位 / 批次
    private func repeatableFinished(order: SimCondOrder) -> Bool {
        switch order.kind {
        case .grid:
            return (order.runtime.gridLevel ?? 0) >= SimCondRule.gridLevelCount(order: order)
        case .batch:
            return order.runtime.batchDone >= (order.params.batchCount ?? 0)
        default:
            return false
        }
    }

    /// 条件单操作日志（module = .condition）
    private func conditionLog(order: SimCondOrder, content: String,
                              result: String, at date: Date) -> ActionLog {
        ActionLog(id: UUID(), accountID: order.accountID, module: .condition,
                  content: content, result: result, occurredAt: date)
    }
}