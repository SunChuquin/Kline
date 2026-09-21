//
//  PageLayoutEditorView.swift
//  Kline
//
//  布局编辑器 - 全屏页面。
//  自上而下：顶部栏（返回 / 标题 / 全屏预览）→ 档位行 → 页签行（表单 / JSON 原文 + 保存 / 恢复默认）
//  → 上半编辑区（树列表 + 检查器，或 JSON 通栏编辑器）→ 下半常驻只读预览 → 底部状态条。
//  浮层：HomeLayoutFullPreviewView（全屏预览）。
//  呈现方式沿用 FormulaCenterView 的容器层 overlay 惯例（页面自带「返回」，不设遮罩）。
//

import SwiftUI

struct PageLayoutEditorView: View {
    let onClose: () -> Void

    @StateObject private var editor = PageLayoutEditorModel()
    /// 两处预览共用同一份真实数据
    @StateObject private var previewModel = HomePageModel()
    @State private var showFullPreview = false
    @State private var showResetConfirm = false
    @State private var showDirtyAlert = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            styleRow
            tabRow
            Divider()

            editArea
                .frame(maxHeight: .infinity)

            Divider()

            HomeLayoutPreviewPane(editor: editor,
                                  model: previewModel,
                                  onExpand: { showFullPreview = true })
                .frame(maxHeight: .infinity)

            Divider()
            statusBar
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay {
            if showFullPreview {
                HomeLayoutFullPreviewView(editor: editor,
                                          model: previewModel,
                                          onClose: { showFullPreview = false })
                    .zIndex(1000)
            }
        }
        .onAppear { editor.loadFromStore() }
        .alert("有未保存改动", isPresented: $showDirtyAlert) {
            Button("放弃改动并返回", role: .destructive) { onClose() }
            Button("继续编辑", role: .cancel) { }
        } message: {
            Text("返回后未保存的改动将丢失。")
        }
    }

    // MARK: - 顶部栏（对齐 FormulaCenterView.header 的胶囊样式）

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if editor.isDirty {
                    showDirtyAlert = true
                } else {
                    onClose()
                }
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

            Text("布局编辑器")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Spacer(minLength: 8)

            Button {
                showFullPreview = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                    Text("全屏预览").font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.gray.opacity(0.12)).cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 档位行

    private var styleRow: some View {
        HStack(spacing: 12) {
            Picker("", selection: $editor.styleID) {
                ForEach(HomeLayoutStyle.allCases) { style in
                    Text(style.rawValue).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            Text(editor.styleTitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - 页签行

    private var tabRow: some View {
        HStack(spacing: 12) {
            Picker("", selection: tabBinding) {
                Text("表单").tag(false)
                Text("JSON 原文").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            Spacer(minLength: 8)

            pillButton("保存") { editor.save() }
            pillButton("恢复默认") { showResetConfirm = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .alert("恢复为内置默认布局？", isPresented: $showResetConfirm) {
            Button("恢复默认", role: .destructive) { editor.resetToDefault() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("沙盒中的首页配置会被内置默认覆盖。")
        }
    }

    /// 切到 JSON 页签时自动「由当前树生成」，避免显示过期文本
    private var tabBinding: Binding<Bool> {
        Binding(get: { editor.showsJSONTab },
                set: { newValue in
                    editor.showsJSONTab = newValue
                    if newValue { editor.generateJSONFromTree() }
                })
    }

    // MARK: - 上半编辑区

    @ViewBuilder
    private var editArea: some View {
        if editor.showsJSONTab {
            jsonEditor
        } else {
            HStack(spacing: 0) {
                LayoutNodeTreeList(editor: editor)
                    .frame(width: 320)
                Divider()
                LayoutNodeInspector(editor: editor)
            }
        }
    }

    private var jsonEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $editor.jsonText)
                .font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.separator), lineWidth: 1)
                )
                .padding(12)

            Divider()

            HStack(spacing: 12) {
                pillButton("由当前树生成") { editor.generateJSONFromTree() }
                pillButton("应用到树") { editor.applyJSONToTree() }

                Spacer(minLength: 12)

                if let error = editor.jsonError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 底部状态条

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error = editor.jsonError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .lineLimit(1)
            } else if editor.isDirty {
                Text("● 未保存改动")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
            } else {
                Text(editor.banner ?? "已同步")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Color(.systemBackground))
    }

    // MARK: - 通用胶囊按钮

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}