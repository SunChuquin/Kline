//
//  ToolbarIconButton.swift
//  Kline
//
//  全局工具栏按钮唯一实现（IconButton）。
//
//  规范（用户 2026-11-24 定稿）：
//    · 视觉尺寸 40×40pt，实际点击区域 44×44pt
//    · 图标 20pt，圆角 10pt
//    · 默认无背景；按下显示轻微背景反馈
//    · 普通操作 = 次级文字色；重要操作 = 强调色；选中 = 强调色 + 选中底色；禁用 = 禁用色
//    · 必须有 accessibilityLabel / tooltip；不得为单个按钮另写样式
//
//  全 App 工具栏只允许使用本组件（含「更多」收纳菜单 ToolbarOverflowMenu），
//  禁止再出现「图标 + 文字 + 背景」或纯文字工具栏按钮。
//

import SwiftUI

// MARK: - 唯一 IconButton

struct ToolbarIconButton: View {
    /// 语义样式：普通 / 重要（强调色）/ 危险操作
    enum Style {
        case normal
        case accent
        case destructive
    }

    let icon: String
    /// 无障碍标签 / tooltip（必填）
    let label: String
    var style: Style = .normal
    /// 选中态（如编辑模式、边线调整）
    var isActive: Bool = false
    /// 进行中：显示进度圈替代图标（如刷新）
    var isBusy: Bool = false
    /// 右上角角标数字（如条件单监控数）
    var badgeCount: Int = 0
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                iconLayer

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppColors.marketUp))
                        .offset(x: 6, y: -4)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarIconPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(badgeCount > 0 ? "\(badgeCount)" : "")
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .help(label)
    }

    /// 40×40 视觉层（图标 / 进度圈 + 选中底色）
    private var iconLayer: some View {
        Group {
            if isBusy {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: resolvedColor))
                    .scaleEffect(0.75)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .regular))
            }
        }
        .foregroundColor(resolvedColor)
        .frame(width: 40, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? AppColors.selectedBackground : Color.clear)
        )
    }

    /// 统一的语义色解析：禁用 > 选中 > 样式
    private var resolvedColor: Color {
        guard isEnabled else { return AppColors.statusIdle.opacity(0.55) }
        if isActive { return AppColors.accent }
        switch style {
        case .normal:      return AppColors.textSecondary
        case .accent:      return AppColors.accent
        case .destructive: return AppColors.statusError
        }
    }
}

// MARK: - 按下反馈

private struct ToolbarIconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? AppColors.cardHoverBackground : Color.clear)
                    .frame(width: 40, height: 40)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 窄屏「更多」收纳菜单

/// 窄屏工具栏低频率操作的收纳入口：视觉与 ToolbarIconButton 完全一致（40×40 / 20pt / 圆角 10）。
/// 菜单内部使用带文字的 Label（系统菜单弹层不属于工具栏视觉）。
struct ToolbarOverflowMenu<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.clear)
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .help(label)
    }
}
