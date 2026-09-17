//
//  KlineTheme.swift
//  Kline
//
//  Kline 显示主题（日间 / 夜间 / 跟随系统）：主题定义 + 持久化仓库 +
//  个人中心用的下拉触发按钮 + 选择弹窗。
//
//  弹窗（KlineThemeOptionsPanel）样式严格对齐行情表设置里的字段筛选弹窗
//  （MarketColumnConfigPanel.swift 的 FilterOptionsPanel）：210pt 固定宽、
//  行内 padding(h:12,v:10) + Divider、底部「完成」、systemBackground 底、
//  圆角 12、阴影 black 20% / radius 12 / y 4，展示为容器层居中浮层 + 遮罩。
//

import SwiftUI
import Combine

// MARK: - 主题定义

enum KlineTheme: String, CaseIterable, Identifiable, Codable {
    case system   // 跟随系统
    case light    // 日间模式
    case dark     // 夜间模式

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "日间模式"
        case .dark:   return "夜间模式"
        }
    }

    /// nil = 不干预外观，交给系统（跟随系统）
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - 持久化仓库（UserDefaults，与 ChartConfigStore 同惯例）

final class KlineThemeStore: ObservableObject {
    static let shared = KlineThemeStore()

    private static let key = "kline.displayTheme"

    /// 当前主题：写入即持久化，@Published 驱动全 App 实时切换
    @Published var theme: KlineTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        theme = KlineTheme(rawValue: raw) ?? .system
    }
}

// MARK: - 下拉触发按钮（对齐 ColumnFilterButton 的字号/高度/配色）

/// 主题下拉触发按钮：显示当前主题名，点击开合选择弹窗
struct KlineThemeDropdownButton: View {
    let title: String
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundColor(.blue)
        }
        .buttonStyle(.plain)
        .frame(height: 28)
    }
}

// MARK: - 选择弹窗（样式对齐 FilterOptionsPanel）

/// 主题选择浮层面板（容器层居中显示，避免被 ScrollView 裁剪）
struct KlineThemeOptionsPanel: View {
    @Binding var theme: KlineTheme
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(KlineTheme.allCases) { item in
                        let on = theme == item
                        Button {
                            theme = item
                        } label: {
                            HStack {
                                Text(item.title)
                                    .foregroundColor(.primary)
                                Spacer()
                                if on {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)

            Button {
                withAnimation(.easeOut(duration: 0.15)) { onClose() }
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 210)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

// MARK: - 个人中心的主题设置行

/// 显示主题设置行：标题 + 右侧下拉触发按钮（弹窗由页面容器层负责呈现）
struct KlineThemeSettingRow: View {
    @ObservedObject private var store = KlineThemeStore.shared
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Kline 主题")
                .font(.system(size: 16))
            Spacer(minLength: 12)
            KlineThemeDropdownButton(title: store.theme.title, isOpen: $isOpen)
        }
        .frame(minHeight: 36)
    }
}