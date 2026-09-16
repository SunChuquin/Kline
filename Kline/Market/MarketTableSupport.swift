//
//  MarketTableSupport.swift
//  Kline
//
//  行情/自选表格共享基础设施：列宽布局、宿主宽度实测、刘海侧安全区适配（ContentView 全局唯一处）、空态视图。
//

import SwiftUI
import UIKit


// MARK: - 表格辅助：共享列宽与对齐

struct ColumnLayout: Identifiable {
    let field: MarketField
    let width: CGFloat
    /// 是否由「名称 + 代码」合并而来（名称在上、代码在下双行）
    let isNameCode: Bool
    /// 该列宽度对应的字段（边线拖改后写入 config 的 widthOverride 目标）；
    /// 合并列固定为 name，其余列即自身
    let overrideField: MarketField
    var id: String { "\(field.rawValue)_\(isNameCode ? "1" : "0")" }
}

// MARK: - 宿主宽度实测（异形屏安全区适配）

/// 回传宿主视图实际渲染宽度的 PreferenceKey
struct HostWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// 把宿主实际渲染宽度（自动扣除横屏刘海侧安全区 inset）写入绑定。
    /// 行情/自选表格用它计算横向滚动上限：不能用 UIScreen.main.bounds.width——
    /// 刘海屏横屏时左右安全区使实际可视宽度更小，用全屏宽会把滚动上限算短，
    /// 最右列永远滚不进可视区。
    func marketTableHostWidth(to width: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: HostWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(HostWidthKey.self) { w in
            if w > 0, width.wrappedValue != w { width.wrappedValue = w }
        }
    }
}

// MARK: - 异形屏横屏适配：仅刘海侧保留安全区，另一侧贴紧物理屏幕边缘

/// 回传宿主视图当前安全区 inset 的 PreferenceKey
private struct HostInsetsKey: PreferenceKey {
    static var defaultValue = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    static func reduce(value: inout EdgeInsets, nextValue: () -> EdgeInsets) {
        value = EdgeInsets(top: max(value.top, nextValue().top),
                           leading: max(value.leading, nextValue().leading),
                           bottom: max(value.bottom, nextValue().bottom),
                           trailing: max(value.trailing, nextValue().trailing))
    }
}

/// 系统在刘海屏横屏时左右两侧给对称 inset（如 iPhone 11 各 48pt，Apple 有意为之），
/// 但实际只有刘海那一侧有遮挡，另一侧应贴紧物理屏幕边缘（用户定版）。
/// 应用位置：ContentView 根布局（全 App 唯一一处，页面内禁止重复叠加——二次外扩会越过物理边缘）。
/// 刘海侧由界面方向决定（⚠️ UIInterfaceOrientation 与设备姿态命名相反，已实测验证）：
/// landscapeRight → 刘海在 leading；landscapeLeft → 刘海在 trailing；旋转时经通知回调自动换边。
/// 无刘海设备（iPad/Home 键机型）横向 inset=0，此修饰符为无操作。
/// ⚠️ 读 UIKit（interfaceOrientation）只发生在 onAppear/旋转通知回调中，
/// 禁止在 body 求值期读 UIApplication（会毒化视图更新事务导致 UI 永不刷新）。
struct NotchSideSafeArea: ViewModifier {
    /// 用作刘海侧安全区减量与另一侧留白，
    /// 在不同屏幕尺寸/分辨率下保持一致）。
    private let hanziWidth: CGFloat = 4
    @State private var notchOnLeading = true
    @State private var hInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    func body(content: Content) -> some View {
        content
            // 先在未加 padding 的原始几何上测 inset（避免 padding→测量→padding 反馈回路）；
            // 贴边后测量值变为非刘海侧 0/刘海侧 inset，padding 重算结果不变（收敛不动点）
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: HostInsetsKey.self, value: geo.safeAreaInsets)
                }
            )
            // 精确适配（刘海侧为基准，另一侧贴边）：
            // ① 刘海侧：保留系统 inset，再减一个中文字宽（内容探入 12pt，安全区 48→36）；
            // ② 另一侧：原贴物理边缘，改为留一个中文字宽（内容离边缘 12pt），
            //    两侧合计留白不变，界面整体更均衡；交互元素仍在可点击区域内
            .padding(.leading, notchOnLeading ? -hanziWidth : -hInsets.trailing + hanziWidth)
            .padding(.trailing, notchOnLeading ? -hInsets.leading + hanziWidth : -hanziWidth)
            .onPreferenceChange(HostInsetsKey.self) { hInsets = $0 }
            .onAppear { updateNotchSide() }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                updateNotchSide()
            }
    }

    private func updateNotchSide() {
        let orient = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation
        switch orient {
        // ⚠️ UIInterfaceOrientation 与设备姿态命名相反（已实测验证）：
        // landscapeRight = 设备顶部（刘海）朝左 → 刘海在 leading
        // landscapeLeft  = 设备顶部朝右 → 刘海在 trailing
        case .landscapeRight: notchOnLeading = true
        case .landscapeLeft:  notchOnLeading = false
        default: break                              // 其余状态保持现值
        }
    }
}

extension View {
    /// 异形屏横屏适配：仅刘海侧保留安全区 inset，另一侧贴紧物理屏幕边缘
    func notchSideOnlySafeArea() -> some View {
        modifier(NotchSideSafeArea())
    }
}

// MARK: - 通用「空态/加载态」视图（给行情/自选共用）

// MARK: - 通用「空态/加载态」视图（给行情/自选共用）

struct MarketEmptyStateView: View {
    let icon: String
    let message: String
    var subtitle: String? = nil
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46)).foregroundColor(.gray)
            Text(message).font(.system(size: 15)).foregroundColor(.primary)
            if let s = subtitle {
                Text(s).font(.system(size: 13)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

