//
//  PickerEditBridge.swift
//  Kline
//
//  选股公式编辑桥（协议 v2 pickerEdit.*）：P2-9c 选股公式编辑 Web 化的 Swift 侧。
//
//  呈现链：原生 FormulaCenterView 选股段「编辑/新建」→ requestOpen(doc) →
//  WebPageBridge.open("pickerEditor") 全屏 Web 页（route:"page"，shell 层呈现——
//  入口只在 Home/Sim shell 的公式中心与个人中心）。
//  关闭后原生中心仍在其宿主层级（被 zIndex 1002 盖住），编辑器关闭即回到中心，
//  公式库 @Published 刷新后列表自动更新。
//
//  保存是纯 Swift 同步链路（FormulaLibraryStore.save 不涉引擎，落盘 + reload）：
//  save 动作同步返回 ok 并原生关页，无 changed(saveResult) 异步推送。
//  测试公式走 FormulaLibraryStore.testPicker（Python 引擎，后台回调），
//  结果经 pickerEdit.changed(pickTest) 推送——strategyEdit.testPick 同款。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import Foundation

@MainActor
final class PickerEditBridge: ObservableObject {

    static let shared = PickerEditBridge()

    /// 编辑中的选股公式文档（打开前暂存；id 空串 = 新建）
    private(set) var doc: FormulaDoc = FormulaDoc(id: "", kind: .picker, name: "")

    /// 样例行情数据（候选池首只标的 K 线，供测试公式；onOpen 异步加载，FormulaCenterView 同款）
    private var sampleData: [KlineItem] = []
    private var sampleLoaded = false

    // MARK: - 打开

    /// 原生公式中心选股段「编辑/新建」入口：暂存文档 → 打开全屏 Web 编辑器页
    func requestOpen(initialDoc: FormulaDoc) {
        doc = initialDoc
        WebPageBridge.shared.open("pickerEditor")
        loadSampleDataIfNeeded()
    }

    func onOpen() {
        loadSampleDataIfNeeded()
    }

    /// 样例行情加载（同 StrategyEditorBridge：候选池首只日线，就绪后推 dataReady）
    private func loadSampleDataIfNeeded() {
        guard !sampleLoaded, !DatabaseManager.shared.metaList.isEmpty else { return }
        guard let meta = DatabaseManager.shared.metaList.first else { return }
        sampleLoaded = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bars = DatabaseManager.shared.fetchBars(metaId: meta.id, period: .daily)
                .sorted { $0.date < $1.date }
            DispatchQueue.main.async {
                self?.sampleData = bars
                WebMessageRouter.shared.pushEvent("pickerEdit.changed",
                                                  payload: ["reason": "dataReady"], route: "page")
            }
        }
    }

    /// 测试公式是否有样例数据
    private var hasData: Bool { sampleData.count > 0 }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return snapshot(request)
        case "testPick":
            return testPick(request)
        case "save":
            return save(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "pickerEdit.\(request.action) 未实现")
        }
    }

    // MARK: 快照

    /// pickerEdit.snapshot：编辑对象（id/name/pickBody）+ 样例数据就绪标记
    private static func snapshot(_ request: WebBridgeRequest) -> [String: Any] {
        let d = shared.doc
        return WebBridgeResponse.ok(request.id, data: [
            "id": d.id,
            "name": d.name,
            "pickBody": d.pickBody,
            "hasData": shared.hasData,
        ])
    }

    // MARK: 测试公式（异步）

    /// pickerEdit.testPick {pickBody}：样例行情试算（FormulaLibraryStore.testPicker，后台回调），
    /// 结果推 pickerEdit.changed(pickTest)：{syntaxError, testMessage, testIsError}。
    /// 样例数据未就绪 / 空公式 → syntaxError 空（语法校验旁路，与原生编辑器一致）。
    private static func testPick(_ request: WebBridgeRequest) -> [String: Any] {
        let body = (request.payload["pickBody"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let data = shared.sampleData
        FormulaLibraryStore.shared.testPicker(formula: body, data: data) { result in
            DispatchQueue.main.async {
                var payload: [String: Any] = ["reason": "pickTest",
                                              "syntaxError": "", "testMessage": "", "testIsError": false]
                if let err = result.error {
                    payload["syntaxError"] = err
                    payload["testMessage"] = "✗ \(err)"
                    payload["testIsError"] = true
                } else {
                    let verdict = result.hit ? "命中：最后一根输出值 > 0" : "未命中：最后一根输出值 ≤ 0"
                    payload["testMessage"] = "✓ 解析成功\n\(result.display)\n\(verdict)"
                }
                WebMessageRouter.shared.pushEvent("pickerEdit.changed", payload: payload, route: "page")
            }
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    // MARK: 保存（同步）

    /// pickerEdit.save {id, name, pickBody}：名称非空校验 → FormulaLibraryStore.save 同步落盘
    /// （id 空串 = 新建生成 PICK_<n>；重载走 @Published 刷新原生中心列表）→ ok 原生关页。
    /// 公式语法不在此校验（原生同口径：语法问题由「测试公式」发现）。
    private static func save(_ request: WebBridgeRequest) -> [String: Any] {
        let p = request.payload
        let name = (p["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let pickBody = p["pickBody"] as? String ?? ""
        guard !name.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "请填写公式名称")
        }
        guard !pickBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "请填写公式正文")
        }
        let id = (p["id"] as? String) ?? shared.doc.id
        guard let saved = FormulaLibraryStore.shared.save(
            FormulaDoc(id: id, kind: .picker, name: name, pickBody: pickBody)) else {
            return WebBridgeResponse.fail(request.id, code: "internal_error", message: "保存失败，请检查公式内容")
        }
        DebugLogger.shared.log("[PickerEditBridge] saved \(saved.name) id=\(saved.id)")
        shared.closePage()
        return WebBridgeResponse.ok(request.id, data: ["id": saved.id])
    }

    private func closePage() {
        WebPageBridge.shared.close()
    }
}
