//
//  AlertRecordView.swift
//  Kline
//
//  预警记录页（独立全屏二级页）：条件单「仅提醒」触发后写入的记录。
//  顶部 44pt 导航栏（‹ 返回 / 预警记录 / 清空全部）+ 分隔线 + 记录列表（时间 / 标的 / 触发价 / 文案 / 删除）+ 空态。
//  数据源：`SimStore.shared.alertRecordsSorted`（已按 occurredAt 倒序，本页不再二次排序）；
//  记录由引擎在触发时追加（`SimStore.appendAlertRecord`），上限 200 条、超出丢最旧。
//  约定：iOS 15 兼容（不用 List 默认样式 / NavigationStack / @Observable）；
//  配色一律语义色（支持深色模式）；行高固定 56、命中区 ≥ 44×44pt；
//  本页**不做任何自动弹窗 / 横幅**（预警不在 App 内提示是本次明确口径）。
//

import SwiftUI

struct AlertRecordView: View {
    /// 关闭回调（由呈现方置 nil）
    let onClose: () -> Void

    @ObservedObject private var store = SimStore.shared
    /// 「清空全部」二次确认
    @State private var showClearConfirm = false

    // 显式 init：本视图含 private 存储属性（与同目录 SimCondDetailView / SimCondEditorView 同惯例）
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            if store.alertRecords.isEmpty {
                emptyState
            } else {
                recordList
            }
        }
        // 空态与有数据态都在同一容器内铺满：切换时不引起布局抖动
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .confirmationDialog("清空全部预警记录？", isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清空全部", role: .destructive) { store.clearAlertRecords() }
            Button("取消", role: .cancel) { }
        }
    }

    // MARK: - 导航栏

    private var navBar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 15))
                }
                .foregroundColor(Color.blue)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // 清空全部：记录为空时置灰（避免无反应点击）
            Button(action: { showClearConfirm = true }) {
                Text("清空全部")
                    .font(.system(size: 15))
                    .foregroundColor(Color(.systemRed))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.alertRecords.isEmpty)
            .opacity(store.alertRecords.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .overlay {
            Text("预警记录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.primary)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: - 列表（行高固定 56）

    private var recordList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // 直接用 store 的倒序派生（不再本页二次排序）
                ForEach(store.alertRecordsSorted) { record in
                    recordRow(record)
                    Divider().padding(.leading, 12)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// 单条记录：左 = 时间 + 「名称 代码」；中 = 文案；右 = 触发价 + 删除
    private func recordRow(_ record: SimAlertRecord) -> some View {
        HStack(spacing: 10) {
            Text(SimFormat.dateTime(record.occurredAt))
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(record.name)
                        .font(.system(size: 15))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Text(record.code)
                        .font(.system(size: 12))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }
                // 文案单行：保证行高固定 56（超出省略）
                Text(record.message)
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(record.price.map { SimFormat.price($0) } ?? "—")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(priceColor(record))
                .lineLimit(1)

            deleteButton(record)
        }
        .padding(.leading, 12)
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 点整行（删除按钮自身会吞掉点击）→ 打开该标的 K 线详情
        .onTapGesture { openDetail(record) }
    }

    /// 删除单条（命中区 44×44）
    private func deleteButton(_ record: SimAlertRecord) -> some View {
        Button {
            store.deleteAlertRecord(id: record.id)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15))
                .foregroundColor(Color(.secondaryLabel))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 触发价着色：能查到来源条件单时按「上穿=涨红 / 下破=跌绿」着色；
    /// 条件单已删除或取不到方向时不臆造涨跌，用主色。
    private func priceColor(_ record: SimAlertRecord) -> Color {
        guard let condID = record.condID,
              let order = store.condOrder(id: condID),
              let compareUp = order.params.compareUp else { return Color.primary }
        return compareUp ? Color(.systemRed) : Color(.systemGreen)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 34))
                .foregroundColor(Color(.tertiaryLabel))
            Text("暂无预警记录")
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
            Text("在自选 / 行情页长按标的设置预警，触发后会记录在这里")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 行为

    /// 点记录打开该标的 K 线详情：meta 从本地库反查；取不到（标的已不在库中）则不响应点击
    private func openDetail(_ record: SimAlertRecord) {
        guard let meta = DatabaseManager.shared.metaList.first(where: { $0.id == record.metaID }) else { return }
        DetailRouter.shared.open(meta, in: [meta])
    }
}