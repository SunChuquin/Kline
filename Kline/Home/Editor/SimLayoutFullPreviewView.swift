//
//  SimLayoutFullPreviewView.swift
//  Kline
//
//  布局编辑器 - 模拟页全屏预览。
//  用 PageLayoutRenderer + SimWidgetRegistry + 真实 SimStore 数据渲染当前草稿档位；
//  与首页全屏预览（HomeLayoutFullPreviewView）同构。预览模式**可交互**：
//  模块切换 / 账户切换生效；浮层（下单页 / 条件单等）不挂载、入口动作空转。
//

import SwiftUI

struct SimLayoutFullPreviewView: View {
    @ObservedObject var editor: PageLayoutEditorModel
    @ObservedObject var model: SimulationPageModel
    let onClose: () -> Void

    private var renderer: PageLayoutRenderer<SimLayoutContext> {
        PageLayoutRenderer(registry: SimWidgetRegistry.shared.registry,
                           context: SimLayoutContext(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if let root = editor.layoutRoot {
                    // 与运行时同构直出（不额外包 ScrollView，保持 widget 的
                    // 撑满语义与底部买卖条钉底行为一致）
                    renderer.view(for: root)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
        // 紧凑态账户抽屉（A 方案锚点行可切换查看）
        .overlay {
            if model.accountDrawerActive {
                SimAccountDrawerView(model: model)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.accountDrawerActive)
        .overlay(alignment: .top) {
            if let text = model.toast {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
                    .padding(.top, 6)
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    Text("返回").font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.gray.opacity(0.12)).cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)

            Spacer(minLength: 8)

            Text("预览 · 模拟 · 档位 \(editor.styleID)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("预览模式 · 浮层入口不生效")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 320, alignment: .trailing)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
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
