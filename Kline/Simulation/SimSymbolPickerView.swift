//
//  SimSymbolPickerView.swift
//  Kline
//
//  条件单「搜索全部标的」选择器：让空仓也能对任意标的建条件单。
//
//  背景：条件单页「新建」原先只列已有持仓标的（`SimCondListView.startCreate`），
//  但建单校验层（`SimCondRule.validateCreate` / 引擎 `cond_validate_create`）**只对卖出方向
//  要求持仓**，买入（建仓）本就允许空仓——限制纯在 UI 入口，非业务规则。
//
//  元素定位全部走 accessibilityIdentifier（供 KlineUITests 使用），不依赖中文文本与坐标。
//

import SwiftUI
import Combine

// MARK: - 搜索模型

/// 关键字搜索模型（class 持有搜索序号：快速输入时后发查询可能先返回，需丢弃过期回调）。
/// `DatabaseManager.metaList` 为全量标的快照，空关键字时按序展示前 `browseLimit` 条供浏览。
@MainActor
final class SimSymbolPickerModel: ObservableObject {

    /// 当前展示的标的（浏览或搜索结果）
    @Published var shown: [MetaItem] = []
    /// 关键字搜索是否已回调（决定空态是「搜索中…」还是「未找到匹配的标的」）
    @Published var searched = false

    /// 空关键字时的浏览条数上限（全库标的数量级大，不做无界渲染）
    static let browseLimit = 50

    private let db = DatabaseManager.shared
    private var token = 0
    private var browsing = false

    /// 关键字是否为「浏览态」（用于视图区分空态文案）
    var isBrowsing: Bool { browsing }

    /// 空关键字：按全量快照顺序展示前 N 条（数据库刚就绪时会被 `isLoaded` 回调再补算一次）
    func browse() {
        token += 1
        browsing = true
        searched = false
        shown = Array(db.metaList.prefix(Self.browseLimit))
    }

    /// 关键字搜索：空关键字回落浏览态
    func search(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            browse()
            return
        }
        token += 1
        let my = token
        browsing = false
        searched = false
        db.searchMetaAsync(keyword: kw) { [weak self] results in
            // 回调本身在主线程，但模型是 @MainActor：显式跳回主 actor 再写状态
            Task { @MainActor in
                guard let self, my == self.token else { return }
                self.shown = results
                self.searched = true
            }
        }
    }
}

// MARK: - 选择器页面

/// 全量标的搜索选择器（全屏 overlay）：搜索/浏览 → 回调选中标的。
/// 调用方（`SimCondListView`）负责把选中标的落成条件单编辑器请求。
struct SimSymbolPickerView: View {
    /// 选中标的回调
    var onPick: (MetaItem) -> Void
    /// 关闭回调（由呈现方 dismiss）
    var onClose: () -> Void

    @StateObject private var model = SimSymbolPickerModel()
    /// 只用于「数据库刚就绪」时补算浏览列表
    @ObservedObject private var databaseManager = DatabaseManager.shared

    @State private var keyword = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { model.browse() }
        .onChange(of: keyword) { model.search($0) }
        .onReceive(databaseManager.$isLoaded) { _ in
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.browse() }
        }
    }

    // MARK: 页头

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Text("取消")
                    .font(.system(size: 15))
                    .foregroundColor(Color.blue)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("simSymbolPicker.close")

            Spacer(minLength: 4)

            Text("选择标的")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.primary)

            Spacer(minLength: 4)

            // 与左侧「取消」等宽占位，保证标题视觉居中
            Text("取消")
                .font(.system(size: 15))
                .foregroundColor(.clear)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .background(Color(.systemBackground))
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(Color(.tertiaryLabel))
            TextField("输入名称或代码", text: $keyword)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("simSymbolPicker.search")
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: 列表 / 空态

    @ViewBuilder
    private var content: some View {
        if model.shown.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundColor(Color(.tertiaryLabel))
                Text(emptyHintText)
                    .font(.system(size: 13))
                    .foregroundColor(Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.isBrowsing {
                        Text("以下为全部标的（前 \(SimSymbolPickerModel.browseLimit) 条），输入关键字精确搜索")
                            .font(.system(size: 11))
                            .foregroundColor(Color(.tertiaryLabel))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    ForEach(model.shown) { meta in
                        Button {
                            onPick(meta)
                        } label: {
                            row(meta)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("simSymbolPicker.row.\(meta.id)")
                        Divider().padding(.leading, 16)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var emptyHintText: String {
        if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "暂无标的可浏览（数据库加载中…）"
        }
        return model.searched ? "未找到匹配的标的" : "搜索中…"
    }

    /// 行：名称 + 代码 + 类型（命中区 ≥ 44pt）
    private func row(_ meta: MetaItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color.primary)
                Text(meta.displayCode)
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
            }
            Spacer(minLength: 8)
            Text(meta.type)
                .font(.system(size: 11))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
