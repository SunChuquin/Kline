//
//  FavoritesLayoutDView.swift
//  Kline
//
//  自选页 D 档布局：分组看板 + 统计条 + 紧凑表格。
//  顶部 = 页标题 + 图标按钮组；其下为横向分组看板（每卡：组名 / 只数 / 涨跌家数 / 平均涨跌幅，当前组高亮蓝边）,
//  再下为当前分组统计条（总数 / 涨跌平 / 平均涨跌幅 / 组内成交额），最后是 34pt 行高的紧凑表。
//
//  ⚠️ 统计口径与性能：
//  - 只统计 `MarketRow.number(.changePct)` 非 nil 的行（涨/跌/平按 pct > 0 / < 0 / == 0），
//    平均涨跌幅 = 这些行的 pct 算术平均（无有效数据 → 显示「—」）；
//  - 所有统计在**数据快照阶段**算好写进 @State（onAppear 首次 + 对数据源 objectWillChange 做 0.3s 防抖重算），
//    body 内只做字典查表，绝不遍历全表。
//

import SwiftUI
import Combine

// MARK: - 一组分组的统计快照（数据快照阶段算好，body 内只读）

/// 单个分组的统计快照：只数 / 涨跌平家数 / 平均涨跌幅 / 组内成交额。
struct FavoritesGroupStat: Equatable {
    var itemCount: Int = 0
    var upCount: Int = 0
    var downCount: Int = 0
    var flatCount: Int = 0
    /// 平均涨跌幅（仅统计 changePct 非 nil 的行）；nil = 无有效数据
    var avgPct: Double? = nil
    /// 组内成交额合计（changePct 有效的行的成交额之和）
    var turnover: Double = 0

    /// 遍历行算一次快照（调用方保证在数据快照阶段、不在 body 内调用）
    static func compute(rows: [MarketRow]) -> FavoritesGroupStat {
        var s = FavoritesGroupStat()
        s.itemCount = rows.count
        var sum = 0.0
        var valid = 0
        for r in rows {
            guard let pct = r.number(.changePct) else { continue }
            valid += 1
            if pct > 0 { s.upCount += 1 } else if pct < 0 { s.downCount += 1 } else { s.flatCount += 1 }
            sum += pct
            s.turnover += r.number(.turnover) ?? 0
        }
        s.avgPct = valid > 0 ? sum / Double(valid) : nil
        return s
    }

    var avgPctText: String {
        guard let v = avgPct else { return "—" }
        return "\(v > 0 ? "+" : "")\(String(format: "%.2f", v))%"
    }

    var avgPctColor: Color {
        guard let v = avgPct else { return .secondary }
        if v > 0 { return Color(.systemRed) }
        if v < 0 { return Color(.systemGreen) }
        return .secondary
    }

    var turnoverText: String {
        turnover > 0 ? MarketRow.formatTurnover(turnover) : "—"
    }
}

// MARK: - D 档布局

struct FavoritesLayoutDView: View {
    @ObservedObject var model: FavoritesPageModel

    /// 各分组统计快照（快照阶段写入，body 内只查表）
    @State private var groupStats: [UUID: FavoritesGroupStat] = [:]
    /// 防抖令牌：每次数据源变化自增，使在途的 0.3s 重算作废（比持有 DispatchWorkItem 更简单可靠）
    @State private var statToken = 0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            board
            Divider()
            statBar
            Divider()
            // 紧凑表：34pt 行高 / 15pt 字号，经 heightOverride / fontSizeOverride 落到行内部
            FavoritesTableBody(model: model, rowHeight: 34, fontSize: 15)
        }
        .onAppear { recomputeStats() }
        // 数据源变化 → 0.3s 防抖后重算快照（不逐帧重算、不在 body 内遍历）
        .onReceive(model.rowCache.objectWillChange) { _ in scheduleRecompute() }
        .onReceive(model.fav.objectWillChange) { _ in scheduleRecompute() }
        .onReceive(model.dbm.objectWillChange) { _ in scheduleRecompute() }
    }

    // MARK: 顶部工具条

    private var topBar: some View {
        HStack(spacing: 4) {
            Text("自选")
                .font(.system(size: 18, weight: .bold))
                .accessibilityIdentifier("favorites.title")
                .padding(.leading, 16)
            Spacer(minLength: 8)
            // 编辑态开关：与 A/B/C 档同一按钮（文案「编辑」→「完成」，退出时清空多选）
            FavoritesEditToggleButton(model: model)
            iconButton("slider.horizontal.3") { model.showColumnPanel = true }
            iconButton("folder") { model.showManageSheet = true }
            iconButton("plus", color: .blue) { model.showAddSheet = true }
                .padding(.trailing, 4)
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    /// 顶部图标按钮：统一 44x44 命中区
    private func iconButton(_ systemName: String, color: Color = .secondary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundColor(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 分组看板

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.tabs) { g in
                    boardCard(g)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 80)
        .background(Color(.systemBackground))
    }

    /// 看板卡（150x64）：组名 + N 只 + 涨/跌家数 + 组内平均涨跌幅；当前分组蓝边高亮
    private func boardCard(_ g: FavoritesGroup) -> some View {
        let active = g.id == model.currentGroup.id
        let stat = groupStats[g.id] ?? FavoritesGroupStat()
        return Button {
            if model.fav.selectedGroupID != g.id { model.fav.selectedGroupID = g.id }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(g.name)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(active ? .blue : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(stat.itemCount) 只")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    Text("涨 \(stat.upCount)")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(.systemRed))
                    Text("跌 \(stat.downCount)")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(.systemGreen))
                    Spacer(minLength: 0)
                }
                Text(stat.avgPctText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(stat.avgPctColor)
            }
            .padding(.horizontal, 10)
            .frame(width: 150, height: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(active ? Color.blue.opacity(0.08) : Color(.systemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(active ? Color.blue : Color(.separator), lineWidth: active ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 统计条（当前分组）

    private var statBar: some View {
        let s = groupStats[model.currentGroup.id] ?? FavoritesGroupStat()
        return HStack(spacing: 0) {
            statItem("自选总数", "\(s.itemCount)", color: .primary)
            statDivider
            statItem("上涨", "\(s.upCount)", color: Color(.systemRed))
            statDivider
            statItem("下跌", "\(s.downCount)", color: Color(.systemGreen))
            statDivider
            statItem("平盘", "\(s.flatCount)", color: .secondary)
            statDivider
            statItem("平均涨跌幅", s.avgPctText, color: s.avgPctColor)
            statDivider
            statItem("组内成交额", s.turnoverText, color: .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Color(.secondarySystemBackground))
    }

    private func statItem(_ key: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.trailing, 16)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 0.5, height: 22)
            .padding(.trailing, 16)
    }

    // MARK: 统计快照（防抖重算）

    /// 数据源变化后 0.3s 静默再重算：公式刷新 / 行数据批量到达时避免逐条重算
    @MainActor
    private func scheduleRecompute() {
        statToken += 1
        let token = statToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // 期间又有数据源变化（令牌已自增）→ 本次作废，由后一次承担重算
            if token == statToken { recomputeStats() }
        }
    }

    /// 一次算清所有分组的统计快照（只读缓存，不触发预取，避免与行缓存形成刷新回环）
    @MainActor
    private func recomputeStats() {
        var out: [UUID: FavoritesGroupStat] = [:]
        for g in model.tabs {
            out[g.id] = FavoritesGroupStat.compute(rows: model.sortedRows(groupID: g.id, prefetch: false))
        }
        if out != groupStats { groupStats = out }
    }
}

#Preview {
    FavoritesLayoutDView(model: FavoritesPageModel())
}