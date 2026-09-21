//
//  HomeLayoutPreviewPane.swift
//  Kline
//
//  布局编辑器 - 页内常驻预览（只读）。
//  用 PageLayoutRenderer + HomeWidgetRegistry + 真实 HomePageModel 数据渲染当前草稿档位；
//  1:1 宽度（不缩放，所见即所得）；滚动区整体 allowsHitTesting(false)。
//

import SwiftUI

struct HomeLayoutPreviewPane: View {
    @ObservedObject var editor: PageLayoutEditorModel
    @ObservedObject var model: HomePageModel
    let onExpand: () -> Void

    private var renderer: PageLayoutRenderer<HomeLayoutContext> {
        PageLayoutRenderer(registry: HomeWidgetRegistry.shared.registry, context: context)
    }

    /// 业务回调全部空实现：预览只读，入口与 Tab 切换不生效
    private var context: HomeLayoutContext {
        HomeLayoutContext(model: model, onProfile: {}, onEntry: { _ in }, onSelectTab: { _ in })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolBar
            Divider()
            Group {
                if let root = editor.layoutRoot {
                    ScrollView {
                        renderer.view(for: root)
                    }
                    .allowsHitTesting(false)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
        }
    }

    // MARK: - 工具条

    private var toolBar: some View {
        HStack(spacing: 12) {
            Text("预览（只读）· 档位 \(editor.styleID)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: 3) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12))
                Text("全屏")
                    .font(.system(size: 12))
            }
            .foregroundColor(.blue)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture { onExpand() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.dashed")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("当前档位暂无可用布局")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }
}