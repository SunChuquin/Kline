//
//  PresetBridge.swift
//  Kline
//
//  指标组合桥（协议 v2 preset.*）：K 线设置面板「指标组合」配置组与组合编辑页的 Swift 侧。
//  呈现域：sheet（入口在 K 线设置弹层内，弹层宿主 SheetWebOverlayHost 挂详情页之上）。
//
//  动作：
//  - preset.snapshot：完整下发生效模式 + 五套组合（编辑页需要全部周期的配置）；
//  - preset.setMode {id}：切换生效组合（"local" = 局部独立配置）；幂等；写回后图表即时重算
//    （ChartPresetStore.setActiveMode → configModeRevision bump → 指纹变化缓存失效）。
//  - preset.editCommit：期2 组合编辑页整包提交（本文件已备好，编辑页交付时接通 Web 端）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Foundation

@MainActor
final class PresetBridge {

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return snapshot(request)
        case "setMode":
            return setMode(request)
        case "editCommit":
            return editCommit(request)
        case "openEditor":
            // 设置面板「编辑五套组合」→ 切 sheet 面板到 presetEditor（SheetPage activeName 切换）
            SheetBridge.shared.openPresetEditor()
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "preset.\(request.action) 未实现")
        }
    }

    // MARK: 快照

    /// preset.snapshot：生效模式 + 五套组合完整配置 + 指标目录（编辑页按周期渲染可选项）
    private static func snapshot(_ request: WebBridgeRequest) -> [String: Any] {
        let store = ChartPresetStore.shared
        let presetsAny: [[String: Any]] = store.presets.map { presetAny($0) }
        return WebBridgeResponse.ok(request.id, data: [
            "mode": store.activeMode,
            "modeOptions": modeOptions(),
            "presets": presetsAny,
            "catalog": catalog(),
        ])
    }

    /// 指标目录：全周期 × 可选主图指标 / 副图分组 / 自定义指标（编辑页渲染选项用，配置只存启用集合）
    private static func catalog() -> [String: Any] {
        let sys = SystemIndicatorStore.shared
        let customs = CustomIndicatorStore.shared
        var periodsAny: [[String: Any]] = []
        for period in KlinePeriod.allCases {
            let mainDefs: [[String: Any]] = sys.mainIndicatorDefs(period: period).map {
                ["id": $0.id, "name": $0.name]
            }
            var subMap: [String: [String]] = ["量能": ["VOL", "AMO"]]
            for def in sys.subIndicatorDefs(period: period) {
                let g = def.group.isEmpty ? "其他" : def.group
                subMap[g, default: []].append(def.id)
            }
            var groups: [[String: Any]] = []
            for g in SystemIndicatorStore.subGroupOrder where subMap[g] != nil {
                groups.append(["group": g, "kinds": subMap[g]!])
            }
            for (g, kinds) in subMap where !SystemIndicatorStore.subGroupOrder.contains(g) {
                groups.append(["group": g, "kinds": kinds])
            }
            let customsAny: [[String: Any]] = customs.indicators
                .filter { CustomIndicatorStore.applicablePeriods(of: $0).contains(period) }
                .map {
                    ["id": $0.id.uuidString, "name": $0.name, "colorHex": $0.colorHex,
                     "scope": $0.scope == .main ? "main" : "sub"]
                }
            periodsAny.append(["period": period.rawValue, "mainDefs": mainDefs,
                               "subGroups": groups, "customs": customsAny])
        }
        return ["periods": periodsAny]
    }

    private static func modeOptions() -> [[String: Any]] {
        [["value": ChartPresetStore.localMode, "label": "局部独立配置"]]
            + ChartPresetSlots.ids.map { ["value": $0, "label": defaultLabel($0)] }
    }

    /// 组合展示名：用户改名后的 name（默认槽名兜底）
    private static func defaultLabel(_ id: String) -> String {
        ChartPresetStore.shared.preset(id: id)?.name ?? ChartPresetSlots.defaultName(id)
    }

    private static func presetAny(_ p: ChartPreset) -> [String: Any] {
        ["id": p.id,
         "name": p.name,
         "mainIndicatorsByPeriod": p.mainIndicatorsByPeriod,
         "activeCustomByPeriod": p.activeCustomByPeriod,
         "subSelectionsByPeriod": Dictionary(uniqueKeysWithValues: p.subSelectionsByPeriod.map {
             ($0.key, $0.value.map { ["kind": $0.kind, "customID": $0.customID?.uuidString ?? ""] })
         })]
    }

    // MARK: 切换生效组合

    /// preset.setMode {id}：id = "local" 或组合槽位；幂等（同模式 no-op）
    private static func setMode(_ request: WebBridgeRequest) -> [String: Any] {
        let id = request.payload["id"] as? String ?? ""
        guard id == ChartPresetStore.localMode || ChartPresetStore.shared.preset(id: id) != nil else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "id 必须为 local 或组合槽位（p1..p5）")
        }
        ChartPresetStore.shared.setActiveMode(id)
        // 推送让其他 sheet 实例（设置面板/编辑页）同步下拉态
        WebMessageRouter.shared.pushEvent("preset.changed",
                                          payload: ["reason": "mode", "mode": id],
                                          route: "sheet")
        return WebBridgeResponse.ok(request.id)
    }

    // MARK: 整包提交（期2 组合编辑页）

    /// preset.editCommit {presets:[{id,name,mainIndicatorsByPeriod,activeCustomByPeriod,subSelectionsByPeriod}]}
    /// 五套组合批量写回（数量须为 5）；生效中的组合被改 → 图表即时重算。
    private static func editCommit(_ request: WebBridgeRequest) -> [String: Any] {
        guard let arr = request.payload["presets"] as? [[String: Any]], arr.count == ChartPresetSlots.ids.count else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "presets 必须为 5 套组合")
        }
        var presets: [ChartPreset] = []
        for item in arr {
            guard let id = item["id"] as? String, ChartPresetSlots.ids.contains(id),
                  let name = item["name"] as? String else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                              message: "组合 id/name 非法")
            }
            let main = (item["mainIndicatorsByPeriod"] as? [String: [String]]) ?? [:]
            let custom = (item["activeCustomByPeriod"] as? [String: String]) ?? [:]
            var subByPeriod: [String: [SubChartSelection]] = [:]
            if let subAny = item["subSelectionsByPeriod"] as? [String: [[String: Any]]] {
                for (key, selsAny) in subAny {
                    let sels = selsAny.compactMap { s -> SubChartSelection? in
                        guard let kind = s["kind"] as? String else { return nil }
                        let customID = (s["customID"] as? String).flatMap(UUID.init(uuidString:))
                        return SubChartSelection(kind: kind, customID: customID)
                    }
                    if sels.count == 3 { subByPeriod[key] = sels }
                }
            }
            presets.append(ChartPreset(id: id, name: name,
                                       mainIndicatorsByPeriod: main,
                                       activeCustomByPeriod: custom,
                                       subSelectionsByPeriod: subByPeriod))
        }
        ChartPresetStore.shared.replacePresets(presets)
        WebMessageRouter.shared.pushEvent("preset.changed",
                                          payload: ["reason": "presets"],
                                          route: "sheet")
        return WebBridgeResponse.ok(request.id)
    }
}
