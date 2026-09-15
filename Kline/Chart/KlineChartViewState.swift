//
//  KlineChartViewState.swift
//  Kline
//
//  KlineChartView 按域划分的自定义状态模型（ObservableObject）。
//  从 KlineChartView.swift 的状态属性区拆分而来，按"低频离散 + 无 .onChange 挂钩"原则封装，
//  收敛视图属性区；写入仍触发本视图 body 重绘（与原 @State 行为一致，性能中性）。
//

import Foundation
import Combine

/// 编辑器 / 指标面板的 UI 瞬时状态：sheet 开关、编辑器目标、精度修改后的挂起重算。
/// 全部为低频离散状态（用户点按钮/面板交互时变化），无 .onChange 挂钩，安全独立成 model。
final class ChartEditorUIState: ObservableObject {
    /// 主图指标选择 sheet 打开
    @Published var showMainSheet = false
    /// 副图指标选择 sheet 打开
    @Published var showSubSheet = false
    /// 重置内置指标确认对话框打开
    @Published var showResetBuiltinConfirm = false
    /// 当前编辑的副图槽位（.top/.bottom/.third）
    @Published var editingSlot: SubSlot = .top
    /// 自定义指标编辑器目标（.main 或 .sub）
    @Published var editorTarget: EditorTarget = .main
    /// 系统指标编辑器目标：true=主图（可切换）/false=副图（编辑 initialSubId）
    @Published var systemEditorIsMain: Bool? = nil
    /// 系统编辑器副图目标 id
    @Published var systemEditorSubId: String = ""
    /// 面板打开期间挂起的主图指标重算标记
    @Published var pendingMainRefresh = false
    /// 面板打开期间挂起的待重算副图列表（只重算被改的；@Published 触发重绘，写入处应 removeAll 而非原地改）
    @Published var pendingSubCharts: [SubChartModel] = []
}