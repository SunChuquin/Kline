//
//  PageLayoutEditorView.swift
//  Kline
//
//  布局编辑器 - 全屏页面。
//  宽屏（≥600，iPad/横屏）：顶部单行（返回 / 标题 / 四档切换 / 全屏预览）→ 页签行（表单 / JSON 原文 + 保存 / 恢复默认）
//  → 编辑区（树列表 + 检查器，或 JSON 通栏编辑器，占满剩余高度）→ 底部状态条。
//  紧凑宽（<600，iPhone 竖屏）：header 拆两行、页签收窄、编辑区改上下结构（见各处注释）。
//  浮层：HomeLayoutFullPreviewView（全屏预览）。
//  呈现方式：编辑器要盖住底部导航栏，故由 `ContentView` 根 ZStack 用
//  `HomeLayoutEditorRouter` 呈现（与 K线详情页 DetailRouter 同做法）；页面自带「返回」，不设遮罩。
//  页内**不再**放常驻预览（预览只在全屏预览页看），把纵向空间全部留给编辑区。
//

import Combine
import SwiftUI

/// 布局编辑器呈现路由器：编辑器是全屏页面（必须盖住底部导航栏），
/// 挂在 `ContentView` 根 ZStack 上呈现；首页入口与个人中心入口都只置位此开关。
final class HomeLayoutEditorRouter: ObservableObject {
    static let shared = HomeLayoutEditorRouter()
    @Published var isPresented = false
}

struct PageLayoutEditorView: View {
    let onClose: () -> Void

    @StateObject private var editor = PageLayoutEditorModel()
    /// 全屏预览用真实数据
    @StateObject private var previewModel = HomePageModel()
    @State private var showFullPreview = false
    @State private var showResetConfirm = false
    @State private var showDirtyAlert = false

    /// 页面可用宽度：由顶层 WidthReader 上报。0 表示尚未上报——
    /// 此时按宽屏形态渲染，保证 iPad 首帧与既有布局/UITest 场景完全一致。
    @State private var availableWidth: CGFloat = 0

    /// 紧凑宽度形态（可用宽 < 600，即 iPhone 竖屏 ~414pt）：
    /// 单行 header 需 ~459pt、树+检查器左右分栏需 ~618pt，均超屏宽，
    /// 故紧凑态下 header 拆两行、编辑区改上下结构；宽屏（≥600）一律保持现状。
    private var isCompact: Bool {
        availableWidth > 0 && availableWidth < CompactWidth.threshold
    }

    var body: some View {
        // 顶层测宽（WidthReader 只允许在页面顶层包裹，见其文档）
        WidthReader(onChange: { availableWidth = $0 }) {
            VStack(spacing: 0) {
                header
                Divider()
                tabRow
                Divider()

                editArea
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
    }

    // MARK: - 顶部（返回 / 标题 / 四档切换 / 全屏预览）
    // 宽屏：单行（四档切换并入标题行，省一整行高度给编辑区）；
    // 紧凑态（iPhone 竖屏 ~414pt）：单行实测需 ~459pt，全屏预览会被压成文字竖排，
    // 故拆两行——第一行 返回+标题+全屏预览（保证「全屏预览」文字水平完整），
    // 第二行四档 Picker 拉满宽度，杜绝截断与竖排。命中区尺寸两种形态完全一致。

    @ViewBuilder
    private var header: some View {
        if isCompact {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    backButton
                    titleText
                    Spacer(minLength: 8)
                    fullPreviewButton
                }
                stylePicker
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        } else {
            HStack(spacing: 10) {
                backButton
                titleText
                stylePicker
                    .frame(width: 220)
                Spacer(minLength: 8)
                fullPreviewButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }

    /// 返回按钮：有未保存改动时先弹确认，再走 onClose
    private var backButton: some View {
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
        .accessibilityIdentifier("layoutEditor.back")
    }

    /// 标题：fixedSize 保持不截断（紧凑两行下第一行空间充裕，无需放开）
    private var titleText: some View {
        Text("布局编辑器")
            .accessibilityIdentifier("layoutEditor.title")
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.primary)
            .fixedSize()
    }

    /// 四档风格切换（宽度由调用方按形态给：宽屏固定 220，紧凑态拉满）
    private var stylePicker: some View {
        Picker("", selection: $editor.styleID) {
            ForEach(HomeLayoutStyle.allCases) { style in
                Text(style.rawValue).tag(style.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("layoutEditor.stylePicker")
    }

    /// 全屏预览入口（紧凑态必须保持文字水平完整显示，命中区不缩小）
    private var fullPreviewButton: some View {
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
        .accessibilityIdentifier("layoutEditor.fullPreview")
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
            // 紧凑态收窄到 150（「JSON 原文」段 + segmented 边距可容）：
            // iPhone 竖屏下 240 会把「表单」页签顶出屏 −6.5pt；宽屏保持 240 不变。
            .frame(maxWidth: isCompact ? 150 : 240)

            Spacer(minLength: 8)

            pillButton("保存") { editor.save() }
                .accessibilityIdentifier("layoutEditor.save")
            pillButton("恢复默认") { showResetConfirm = true }
                .accessibilityIdentifier("layoutEditor.resetDefault")
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
        } else if isCompact {
            // 紧凑态改上下结构：左右分栏需 树 320 + 检查器参数行 ~298 ≈ 618 > 414，
            // 树行按钮会被挤出左缘、参数行挤出右缘。树列表在上（自身是 ScrollView，
            // 固定 260 高内自行滚动，底部增删工具条保持可见），检查器在下占余高
            // （其内部 maxWidth infinity，全宽 ~414 下参数行不再出右）。
            VStack(spacing: 0) {
                LayoutNodeTreeList(editor: editor)
                    .frame(height: 260)
                Divider()
                LayoutNodeInspector(editor: editor)
            }
        } else {
            // 宽屏（≥600）保持左右分栏现状，iPad 视觉与行为完全不变。
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