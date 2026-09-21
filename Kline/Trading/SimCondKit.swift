//
//  SimCondKit.swift
//  Kline
//
//  条件单纯展示原子件：类型 chip / 「仅提醒」标记 / 状态标签 / 多触发进度条 / 概览三段计数条。
//  约定：不持有业务状态，供管理页 SimCondListView 与编辑器 SimCondEditorView 复用；
//  iOS 15 兼容（不用 Table / Chart / NavigationStack / @Observable），
//  配色一律语义色（支持深色模式），买入红 / 卖出绿沿用 SimSharedViews 的惯例。
//

import SwiftUI

// MARK: - 类型 chip

/// 类型 chip：蓝字 + 蓝底 12% + 圆角 6，固定高 17（宽自适应）
struct SimCondKindChip: View {
    let kind: SimCondKind

    var body: some View {
        Text(kind.title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(.blue)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.12)))
    }
}

// MARK: - 「仅提醒」标记

/// 「仅提醒」标记：告知这条条件单触发时**不下单**（只写预警记录）。
/// 与状态标签同风格（高 17 / 圆角 4 / 10.5 bold），底色用 `systemGray5` + 蓝色字，
/// 与状态标签（橙/红/绿/灰，按状态着色）在语义上区分开。
struct SimCondAlertBadge: View {
    var body: some View {
        Text("提醒")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(.blue)
            .frame(width: 34, height: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)))
    }
}

// MARK: - 状态标签

/// 状态标签：监控中橙 / 已触发红 / 已完成绿 / 已失效·已撤销灰 / 已拒绝红
struct SimCondStatusTag: View {
    let status: SimCondStatus

    private var tint: Color {
        switch status {
        case .monitoring:
            return Color(.orange)
        case .triggered, .rejected:
            return Color(.systemRed)
        case .completed:
            return Color(.systemGreen)
        case .expired, .cancelled:
            return Color(.secondaryLabel)
        }
    }

    var body: some View {
        Text(status.title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(tint)
            .frame(width: 46, height: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12)))
    }
}

// MARK: - 多触发进度

/// 进度条：文案「N/M 档 · 已成交 K 笔」+ 高 3pt 细条
/// 注意：`unit` 必须是带默认值的 var（let 会被 memberwise init 剔除）
struct SimCondProgressBar: View {
    let done: Int
    let total: Int
    let triggered: Int
    /// 进度单位：网格用「档」，分批用「批」
    var unit: String = "档"

    private var ratio: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(done) / Double(total), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(done)/\(total) \(unit) · 已成交 \(triggered) 笔")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.secondaryLabel).opacity(0.2))
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: geo.size.width * CGFloat(ratio))
                }
            }
            .frame(height: 3)
        }
    }
}

// MARK: - 概览条

/// 概览条：三段等分计数（监控中 / 已触发 / 已失效），数值 16 bold、标签 11
struct SimCondOverviewStrip: View {
    let monitoring: Int
    let triggered: Int
    let invalid: Int

    var body: some View {
        HStack(spacing: 0) {
            cell(title: "监控中", value: monitoring, tint: Color(.orange))
            separator
            cell(title: "已触发", value: triggered, tint: Color(.systemRed))
            separator
            cell(title: "已失效", value: invalid, tint: Color(.secondaryLabel))
        }
        .frame(height: 56)
    }

    private func cell(title: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 0.5, height: 24)
    }
}