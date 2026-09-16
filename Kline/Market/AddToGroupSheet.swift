//
//  AddToGroupSheet.swift
//  Kline
//
//  加自选/移动分组动作 sheet（从行情行或详情页右上角按钮触发）。
//

import SwiftUI
import UIKit


// MARK: - 加自选/选分组 sheet（从行情行或详情页右上角按钮触发）

struct AddToGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let meta: MetaItem
    @ObservedObject var fav: FavoritesStore
    /// 完成后刷新调用侧的按钮状态
    var onDone: (() -> Void)? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部栏
                HStack(spacing: 12) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("加入分组")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button(action: { onDone?(); dismiss() }) {
                        Text("完成")
                            .foregroundColor(.blue)
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()

                // 标的信息
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meta.name).font(.system(size: 16, weight: .medium))
                        Text(meta.displayCode).font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        fav.toggleFavorite(meta.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: fav.isFavorited(meta.id) ? "star.fill" : "star")
                                .foregroundColor(fav.isFavorited(meta.id) ? .yellow : .secondary)
                            Text(fav.isFavorited(meta.id) ? "已自选" : "一键加自选")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()

                // 新增分组快捷按钮
                HStack {
                    Button {
                        presentAddGroupAlert()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill").foregroundColor(.green)
                            Text("新建自定义分组")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                List {
                    Section {
                        let manualGroups = fav.groups.filter { $0.kind == .manual }
                        if manualGroups.isEmpty {
                            HStack {
                                Spacer()
                                Text("暂无自定义分组，点击上方「新建自定义分组」")
                                    .foregroundColor(.secondary).font(.footnote)
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 16)
                        } else {
                            ForEach(manualGroups) { g in
                                let member = g.manualMetaIDs.contains(meta.id)
                                Button {
                                    if member {
                                        fav.removeFromGroup(id: g.id, metaID: meta.id)
                                    } else {
                                        fav.addToGroup(id: g.id, metaID: meta.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(g.name).font(.system(size: 15))
                                            Text("\(g.manualMetaIDs.count) 只")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: member ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(member ? .green : .gray)
                                            .font(.system(size: 20))
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Text("自定义分组（多选）")
                    }
                }
                .listStyle(.insetGrouped)
            }
            .background(Color(.systemGroupedBackground))
        }
        // 用 @State 控 UIAlertController 弹窗
        .onAppear(perform: {})  // keep
    }

    /// 弹出"新建分组"输入框（用 UIKit bridge 更稳）
    private func presentAddGroupAlert() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
            .first else { return }
        // 本页本身以 sheet 形式 modal 盖在 root 上，直接用 root.present 在 iPad 上会被系统忽略
        // （"which is already presenting"），需沿呈现链找到当前最顶层控制器再弹窗
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        if top is UIAlertController { return }
        let vc = UIAlertController(title: "新建自定义分组", message: nil, preferredStyle: .alert)
        vc.addTextField { tf in
            tf.placeholder = "例如：科技龙头"
            tf.clearButtonMode = .whileEditing
        }
        vc.addAction(UIAlertAction(title: "取消", style: .cancel))
        vc.addAction(UIAlertAction(title: "创建", style: .default, handler: { _ in
            let name = (vc.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            fav.addGroup(.manual(name: name))
        }))
        top.present(vc, animated: true)
    }
}

