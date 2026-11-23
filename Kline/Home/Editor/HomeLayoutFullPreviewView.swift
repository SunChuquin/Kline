//
//  HomeLayoutFullPreviewView.swift
//  Kline
//
//  布局编辑器 - 全屏预览页。
//  铺满页面，用 PageLayoutRenderer + HomeWidgetRegistry + 真实 HomePageModel 数据渲染当前草稿档位；
//  与页内预览不同，这里**可交互**（点行情行可打开 K 线详情），故不设 allowsHitTesting(false)。
//

import SwiftUI

struct HomeLayoutFullPreviewView: View {
    @ObservedObject var editor: PageLayoutEditorModel
    @ObservedObject var model: HomePageModel
    let onClose: () -> Void

    private var renderer: PageLayoutRenderer<HomeLayoutContext> {
        PageLayoutRenderer(registry: HomeWidgetRegistry.shared.registry, context: context)
    }

    /// 入口与 Tab 切换不生效（预览模式），业务回调空实现
    private var context: HomeLayoutContext {
        HomeLayoutContext(model: model, onProfile: {}, onEntry: { _ in }, onSelectTab: { _ in })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if let root = editor.layoutRoot {
                    ScrollView {
                        renderer.view(for: root)
                    }
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.pageBackground)
        }
        .background(AppColors.pageBackground.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            ToolbarIconButton(icon: "chevron.left", label: "返回") {
            onClose()
        }
        .padding(.leading, 8)

            Spacer(minLength: 8)

            Text("预览 · 档位 \(editor.styleID)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("预览模式 · 入口与 Tab 切换不生效")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 320, alignment: .trailing)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(AppColors.pageBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.dashed")
                .font(.system(size: 28))
                .foregroundColor(AppColors.textSecondary)
            Text("当前档位暂无可用布局")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
        }
    }
}