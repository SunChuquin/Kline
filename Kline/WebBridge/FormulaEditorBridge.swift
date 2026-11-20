//
//  FormulaEditorBridge.swift
//  Kline
//
//  公式编辑器桥（协议 v2 formulaEdit.*）：P2-8a tech 公式编辑器 Web 化的 Swift 侧。
//
//  呈现链（对齐原生公式中心编辑入口）：
//   Web 公式中心 tech 段「编辑/新建」（chart.formula.openEditor）→ 关弹层面板 →
//   WebPageBridge.open("formulaEditor") 全屏 Web 页。activePage 仍是单一事实源，
//   但呈现宿主在 SheetWebOverlayHost（zIndex 1002）——入口在图表详情页弹层里，
//   shell 层 WebFullscreenPageHost 会被详情页盖住；WebFullscreenPageHost 排除本页名。
//
//  编辑目标（requestOpen 暂存，Web 端 snapshot 拉取）：
//   - system(id, isMain)：系统指标公式（写回 Documents/indicator/<周期>/<id>.tdx；
//     周期取打开时刻 ChartConfigStore.selectedPeriod；可恢复编译时内容）
//   - custom(id?)：自定义技术指标（nil = 新建；UserDefaults 持久化 + USER_*.tdx 落地）
//
//  「测试公式」异步链：formulaEdit.test {formula} → {queued} → 后台线程
//   PyTDXFormulaBridge.evaluateText（样例行情 = 候选池首只标的，onOpen 加载）→
//   主线程推 formulaEdit.changed(testResult)（route:"page" 定向）。
//
//  保存成功即关页（WebPageBridge.close，对齐原生中心保存后关闭）；
//  取消由 Web 端 page.close（dirty 时 Web 本地确认，无需 closeHook）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import SwiftUI

/// 公式编辑器打开目标（原生侧暂存；Web 端经 formulaEdit.snapshot 读取）
enum FormulaEditorTarget {
    /// 系统指标公式（id 与文件名同名；isMain 仅用于上下文描述，写回按指标自身 SCOPE）
    case system(id: String, isMain: Bool)
    /// 自定义技术指标（nil = 新建）
    case custom(id: UUID?)
}

@MainActor
final class FormulaEditorBridge: ObservableObject {

    static let shared = FormulaEditorBridge()

    /// 待编辑目标（open 前设置；snapshot 每次按此组装）
    private(set) var target: FormulaEditorTarget = .custom(id: nil)

    /// 样例行情数据（候选池首只标的 K 线，供「测试公式」；onOpen 异步加载）
    private var sampleData: [KlineItem] = []
    /// 样例数据已加载的周期（切周期重开页时重新加载）
    private var sampleLoadedFor: KlinePeriod? = nil

    // MARK: - 打开 / 关闭

    /// Web 公式中心 tech 段「编辑/新建」入口：暂存目标 → 打开全屏 Web 编辑器页
    func requestOpen(_ target: FormulaEditorTarget) {
        self.target = target
        WebPageBridge.shared.open("formulaEditor")
        loadSampleDataIfNeeded()
    }

    /// 全屏页生命周期（WebPageBridge.onOpen 派发）：确保样例行情就绪
    func onOpen() {
        loadSampleDataIfNeeded()
    }

    /// 保存成功后由原生主动关页（对齐原生公式中心保存即关闭）
    private func closePage() {
        WebPageBridge.shared.close()
    }

    /// 加载样例行情：候选池首只标的按当前周期读全量 K 线并升序排序。
    /// 已就绪同周期 no-op；就绪后推 formulaEdit.changed(dataReady)（Web 端刷新 hasData）。
    private func loadSampleDataIfNeeded() {
        let period = ChartConfigStore.shared.selectedPeriod
        guard sampleLoadedFor != period else { return }
        guard let meta = DatabaseManager.shared.metaList.first else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // fetchBars 返回 date DESC，按既有惯例排序为升序
            let bars = DatabaseManager.shared.fetchBars(metaId: meta.id, period: period)
                .sorted { $0.date < $1.date }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampleData = bars
                self.sampleLoadedFor = period
                WebMessageRouter.shared.pushEvent("formulaEdit.changed",
                                                  payload: ["reason": "dataReady"],
                                                  route: "page")
            }
        }
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return snapshot(request)
        case "test":
            return test(request)
        case "save":
            return save(request)
        case "restoreBuiltin":
            return restoreBuiltin(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "formulaEdit.\(request.action) 未实现")
        }
    }

    // MARK: 快照

    /// formulaEdit.snapshot：按 target 组装编辑对象初始字段与上下文。
    /// system 模式只编辑公式（名称/作用域/适用范围/线条样式隐藏，可恢复编译时内容）；
    /// custom 模式全字段可编辑（palette 由原生下发，Web 端点击插入 COLORXXX 选项）。
    private static func snapshot(_ request: WebBridgeRequest) -> [String: Any] {
        let sys = SystemIndicatorStore.shared
        let customs = CustomIndicatorStore.shared
        let period = ChartConfigStore.shared.selectedPeriod

        // 颜色板：中文名 + 色值 + COLORXXX 选项名（对齐 FormulaEditorView.itemOption 映射）
        let optionMap: [String: String] = [
            "黑色": "BLACK", "蓝色": "BLUE", "绿色": "GREEN", "青色": "CYAN", "红色": "RED",
            "洋红": "MAGENTA", "橙色": "ORANGE", "棕色": "BROWN", "淡灰": "LIGRAY",
            "深灰": "GRAY", "淡蓝": "LILUE", "淡绿": "LIGREEN", "淡青": "LICYAN",
            "淡红": "LIRED", "淡洋红": "LIMAGENTA", "黄色": "YELLOW", "白色": "WHITE",
        ]
        let palette: [[String: Any]] = TDXFormulaColor.palette.map {
            ["name": $0.0, "hex": $0.1, "option": "COLOR\(optionMap[$0.0] ?? "RED")"]
        }

        switch shared.target {
        case .system(let id, let isMain):
            guard let template = sys.template(for: id, period: period) else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                              message: "指标 \(id) 在当前周期没有公式模板")
            }
            return WebBridgeResponse.ok(request.id, data: [
                "mode": "system",
                "displayName": id,
                "isMain": isMain,
                "name": id,
                "formula": template,
                "canRestoreBuiltin": true,
                "period": period.rawValue,
                "periodOptions": KlinePeriod.allCases.map(\.rawValue),
                "hasData": shared.sampleData.count > 0,
                "palette": palette,
            ])

        case .custom(let id):
            let ind = id.flatMap { uid in customs.indicators.first { $0.id == uid } }
            if id != nil && ind == nil {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                              message: "自定义指标不存在")
            }
            return WebBridgeResponse.ok(request.id, data: [
                "mode": ind == nil ? "new" : "edit",
                "displayName": ind?.name ?? "新建指标",
                "name": ind?.name ?? "",
                "formula": ind?.formula ?? "",
                "scope": (ind?.scope ?? .sub) == .main ? "main" : "sub",
                "colorHex": ind?.colorHex ?? "1E88E5",
                // null = 全周期（对齐原生 applicablePeriods = nil；必须保留 nil 语义，
                // 不能展开成全周期数组——否则「全周期」chip 不亮、保存写回也丢 nil）
                "periods": ind?.applicablePeriods.map { $0.map(\.rawValue) } ?? NSNull(),
                "canRestoreBuiltin": false,
                "period": period.rawValue,
                "periodOptions": KlinePeriod.allCases.map(\.rawValue),
                "hasData": shared.sampleData.count > 0,
                "palette": palette,
            ])
        }
    }

    // MARK: 测试公式（异步）

    /// formulaEdit.test {formula}：响应 {queued}；后台引擎求值完成后推
    /// formulaEdit.changed(testResult)（message 原生拼好，Web 端原样展示）。
    private static func test(_ request: WebBridgeRequest) -> [String: Any] {
        guard let formula = request.payload["formula"] as? String else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要 formula")
        }
        let data = shared.sampleData
        DispatchQueue.global(qos: .userInitiated).async {
            let payload: [String: Any]
            guard !data.isEmpty else {
                payload = ["reason": "testResult", "ok": false, "isError": true,
                           "message": "暂无行情数据用于测试"]
                WebMessageRouter.shared.pushEvent("formulaEdit.changed", payload: payload, route: "page")
                return
            }
            switch PyTDXFormulaBridge.evaluateText(formulas: [formula], data: data).first {
            case .some(.success(let lines)):
                let desc = lines.map { line in
                    let last = line.values.last(where: { !$0.isNaN }).map { String(format: "%.3f", $0) } ?? "-"
                    return "\(line.name): \(last)"
                }.joined(separator: "   ")
                payload = ["reason": "testResult", "ok": true, "isError": false,
                           "message": "✓ 解析成功\n\(desc)"]
            case .some(.failure(let msg)):
                payload = ["reason": "testResult", "ok": false, "isError": true, "message": "✗ \(msg)"]
            case .none:
                payload = ["reason": "testResult", "ok": false, "isError": true, "message": "✗ 内部错误"]
            }
            WebMessageRouter.shared.pushEvent("formulaEdit.changed", payload: payload, route: "page")
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    // MARK: 保存（成功即关页）

    /// formulaEdit.save {formula, name?, scope?, colorHex?, periods?}：
    /// - system 模式：写回该周期 .tdx（name/scope/colorHex/periods 忽略）
    /// - custom 模式：name/formula/scope/colorHex/periods 全量写回（periods null = 全周期）
    private static func save(_ request: WebBridgeRequest) -> [String: Any] {
        let p = request.payload
        guard let formula = p["formula"] as? String,
              !formula.trimmingCharacters(in: .whitespaces).isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "公式正文不能为空")
        }
        let period = ChartConfigStore.shared.selectedPeriod

        switch shared.target {
        case .system(let id, _):
            if SystemIndicatorStore.shared.saveTemplate(formula, for: id, period: period) {
                DebugLogger.shared.log("[FormulaEditorBridge] saveSystem \(id)@\(period.rawValue)")
                shared.closePage()
                return WebBridgeResponse.ok(request.id)
            }
            return WebBridgeResponse.fail(request.id, code: "internal_error",
                                          message: "写回指标模板失败")

        case .custom(let id):
            let trimmedName = ((p["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !trimmedName.isEmpty else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "名称不能为空")
            }
            let scope: IndicatorScope = (p["scope"] as? String) == "main" ? .main : .sub
            let colorHex = (p["colorHex"] as? String) ?? "1E88E5"
            // periods null / 缺失 = 全周期（nil）；数组 = 指定周期集合
            let applicable: [KlinePeriod]?
            if let list = p["periods"] as? [String] {
                applicable = list.compactMap(KlinePeriod.init(rawValue:))
            } else {
                applicable = nil
            }
            let customs = CustomIndicatorStore.shared
            if let id, let existing = customs.indicators.first(where: { $0.id == id }) {
                var ind = existing
                ind.name = trimmedName
                ind.formula = formula
                ind.scope = scope
                ind.colorHex = colorHex
                ind.applicablePeriods = applicable
                customs.update(ind)
                DebugLogger.shared.log("[FormulaEditorBridge] updateCustom \(trimmedName)")
            } else {
                var ind = CustomIndicator(name: trimmedName, formula: formula)
                ind.scope = scope
                ind.colorHex = colorHex
                ind.applicablePeriods = applicable
                customs.add(ind)
                DebugLogger.shared.log("[FormulaEditorBridge] addCustom \(trimmedName)")
            }
            shared.closePage()
            return WebBridgeResponse.ok(request.id)
        }
    }

    // MARK: 恢复编译时内容（仅系统指标）

    /// formulaEdit.restoreBuiltin：内置模板复制回该周期 .tdx 并返回恢复后的公式（同步）。
    private static func restoreBuiltin(_ request: WebBridgeRequest) -> [String: Any] {
        guard case .system(let id, _) = shared.target else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "仅系统指标可恢复编译时内容")
        }
        let period = ChartConfigStore.shared.selectedPeriod
        guard SystemIndicatorStore.shared.restoreBuiltin(for: id, period: period),
              let template = SystemIndicatorStore.shared.template(for: id, period: period) else {
            return WebBridgeResponse.fail(request.id, code: "internal_error",
                                          message: "恢复编译时内容失败")
        }
        DebugLogger.shared.log("[FormulaEditorBridge] restoreBuiltin \(id)@\(period.rawValue)")
        return WebBridgeResponse.ok(request.id, data: ["formula": template])
    }
}
