//
//  WebBridgeProtocolTests.swift
//  KlineTests
//
//  Web↔Swift 桥接协议 v2 解析契约测试：fixtures（bridge_protocol.json）驱动，
//  锁定信封字段与 TS 事实源（Web/src/types/protocol.ts）一致。
//  协议演进规则：改动作/事件/错误码清单时，先改 protocol.ts 与本 fixtures，两端同步。
//

import XCTest
@testable import Kline

final class WebBridgeProtocolTests: XCTestCase {

    private func loadFixture() throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        var url = bundle.url(forResource: "bridge_protocol", withExtension: "json", subdirectory: "Fixtures")
        if url == nil { url = bundle.url(forResource: "bridge_protocol", withExtension: "json") }
        let data = try Data(contentsOf: try XCTUnwrap(url, "fixture bridge_protocol.json 不在测试 bundle"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 请求信封解析：fixtures 逐条过 WebBridgeRequest.parse，id/module/action 对拍
    func testRequestEnvelopeParsing() throws {
        let fixture = try loadFixture()
        let requests = try XCTUnwrap(fixture["requests"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(requests.count, 5, "fixtures 请求样例过少")
        for req in requests {
            let body = try JSONSerialization.data(withJSONObject: req)
            let text = String(data: body, encoding: .utf8) ?? ""
            let parsed = try XCTUnwrap(WebBridgeRequest.parse(text), "请求解析失败: \(text.prefix(80))")
            XCTAssertEqual(parsed.id, req["id"] as? String)
            XCTAssertEqual(parsed.module, req["module"] as? String)
            XCTAssertEqual(parsed.action, req["action"] as? String)
        }
    }

    /// 信封不完整 → parse 返回 nil（bad_request 路径的前提）
    func testMalformedRequestRejected() throws {
        XCTAssertNil(WebBridgeRequest.parse("{\"id\":\"x\"}"), "缺 module/action 应解析失败")
        XCTAssertNil(WebBridgeRequest.parse("not json"), "非 JSON 应解析失败")
        XCTAssertNil(WebBridgeRequest.parse(123 as NSNumber), "非字符串 body 应解析失败")
    }

    /// theme.set payload → KlineTheme 枚举（写回动作核心映射）
    func testThemeSetPayloadMapping() throws {
        let fixture = try loadFixture()
        let requests = try XCTUnwrap(fixture["requests"] as? [[String: Any]])
        let themeSet = try XCTUnwrap(requests.first {
            ($0["module"] as? String) == "theme" && ($0["action"] as? String) == "set"
        }, "fixtures 缺 theme.set 样例")
        let payload = try XCTUnwrap(themeSet["payload"] as? [String: Any])
        let raw = try XCTUnwrap(payload["preference"] as? String)
        let theme = try XCTUnwrap(KlineTheme(rawValue: raw), "preference=\(raw) 无法映射 KlineTheme")
        XCTAssertEqual(theme.rawValue, raw)
    }

    /// 错误信封：error.code 必须在协议 v2 错误码表内
    func testErrorEnvelopeCodes() throws {
        let fixture = try loadFixture()
        let errors = try XCTUnwrap(fixture["errors"] as? [[String: Any]])
        let knownCodes: Set<String> = ["bad_request", "unknown_module", "unknown_action",
                                       "invalid_payload", "store_not_ready", "internal_error"]
        XCTAssertGreaterThanOrEqual(errors.count, 3, "fixtures 错误样例过少")
        for err in errors {
            let inner = try XCTUnwrap(err["error"] as? [String: Any])
            let code = try XCTUnwrap(inner["code"] as? String)
            XCTAssertTrue(knownCodes.contains(code), "未知错误码 \(code)（协议 v2 错误码表外）")
        }
    }

    /// 事件信封：event 名必须在协议 v2 事件清单内
    func testEventEnvelopeNames() throws {
        let fixture = try loadFixture()
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        let knownEvents: Set<String> = ["theme.changed", "app.memory", "nav.tab",
                                        "favorites.changed", "market.changed",
                                        "home.changed", "sim.changed", "sheet.open",
                                        "page.open", "lan.changed", "update.changed", "lab.changed"]
        for ev in events {
            let name = try XCTUnwrap(ev["event"] as? String)
            XCTAssertTrue(knownEvents.contains(name), "未知事件 \(name)（协议 v2 事件清单外）")
        }
    }

    /// P2-5b 预留形状锁定（指标控制面板/快捷面板属下一批）
    func testReservedSheetActions() throws {
        let fixture = try loadFixture()
        let reserved = try XCTUnwrap(fixture["reserved"] as? [String: Any])
        XCTAssertNotNil(reserved["chart.indicators.snapshot"] as? [String: Any], "预留缺指标面板形状")
        XCTAssertNotNil(reserved["quick.snapshot"] as? [String: Any], "预留缺快捷面板形状")
    }

    /// chart.settings.snapshot 响应形状锁定（P2-5a K线设置页）：选项带 value/label，显示组开关齐备
    func testChartSettingsShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_chart_settings_snapshot"
        }, "fixtures 缺 chart.settings.snapshot 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        for key in ["period", "periodOptions", "chartStyle", "styleOptions", "linkedViewCount",
                    "viewCountOptions", "showGap", "gapDisappearAfterFill",
                    "showLatestPriceLine", "indicatorNotSqueezeKline", "showBareK"] {
            XCTAssertNotNil(data[key], "chart.settings.snapshot 缺 \(key)")
        }
        for key in ["periodOptions", "styleOptions", "viewCountOptions"] {
            let opts = try XCTUnwrap(data[key] as? [[String: Any]])
            for opt in opts {
                XCTAssertNotNil(opt["value"], "\(key) 选项缺 value")
                XCTAssertNotNil(opt["label"], "\(key) 选项缺 label")
            }
        }
    }

    /// chart.search.query 响应形状锁定
    func testChartSearchShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_chart_search_query"
        }, "fixtures 缺 chart.search.query 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        let results = try XCTUnwrap(data["results"] as? [[String: Any]])
        for row in results {
            for key in ["file", "code", "name", "type"] {
                XCTAssertNotNil(row[key], "搜索结果行缺 \(key)")
            }
        }
    }

    /// chart.indicators.snapshot 响应形状锁定（P2-5b 指标面板）：主图定义 on 态 / 三副图槽位分组 / 自定义行
    func testChartIndicatorsShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_chart_ind_snapshot"
        }, "fixtures 缺 chart.indicators.snapshot 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        for key in ["period", "mainDefs", "mainCustoms", "subSlots"] {
            XCTAssertNotNil(data[key], "chart.indicators.snapshot 缺 \(key)")
        }
        let mainDefs = try XCTUnwrap(data["mainDefs"] as? [[String: Any]])
        for d in mainDefs {
            for key in ["id", "name", "on"] { XCTAssertNotNil(d[key], "主图指标缺 \(key)") }
        }
        let slots = try XCTUnwrap(data["subSlots"] as? [[String: Any]])
        for slot in slots {
            for key in ["slot", "title", "kind", "customID", "hasTemplate", "groups", "customs"] {
                XCTAssertNotNil(slot[key], "副图槽位缺 \(key)")
            }
            let groups = try XCTUnwrap(slot["groups"] as? [[String: Any]])
            for g in groups {
                XCTAssertNotNil(g["group"], "副图分组缺 group")
                XCTAssertNotNil(g["kinds"], "副图分组缺 kinds")
            }
        }
    }

    /// chart.indicators 写回动作 payload 形状锁定（slot 枚举 / direction-like 取值合法）
    func testChartIndicatorsActionsShape() throws {
        let fixture = try loadFixture()
        let requests = try XCTUnwrap(fixture["requests"] as? [[String: Any]])
        let find: (String) -> [String: Any]? = { id in
            requests.first { ($0["id"] as? String) == id }
        }
        let toggle = try XCTUnwrap(find("req_chart_ind_toggle_main"), "缺 toggleMain 样例")
        let togglePayload = try XCTUnwrap(toggle["payload"] as? [String: Any])
        XCTAssertNotNil(togglePayload["id"] as? String)
        XCTAssertNotNil(togglePayload["on"] as? Bool)

        let select = try XCTUnwrap(find("req_chart_ind_select_sub"), "缺 selectSub 样例")
        let selectPayload = try XCTUnwrap(select["payload"] as? [String: Any])
        let slot = try XCTUnwrap(selectPayload["slot"] as? String)
        XCTAssertTrue(["top", "bottom", "third"].contains(slot), "非法 slot \(slot)")
        XCTAssertNotNil(selectPayload["kind"] as? String, "selectSub 需 kind 或 customID 之一")
    }

    /// sim.snapshot 响应形状锁定（P2-4）：五模块业务表 + 摘要口径 + 委托行 active 标记
    func testSimSnapshotShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_sim_snapshot"
        }, "fixtures 缺 sim.snapshot 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        for key in ["selectedID", "accountName", "accounts", "summary", "netValue", "module",
                    "positions", "orders", "fills", "ledger", "logs"] {
            XCTAssertNotNil(data[key], "sim.snapshot 缺 \(key)")
        }
        // 摘要八项口径
        let summary = try XCTUnwrap(data["summary"] as? [String: Any])
        for key in ["totalAssets", "cash", "marketValue", "positionPct",
                    "dayProfit", "dayProfitPct", "totalProfit", "totalProfitPct"] {
            XCTAssertNotNil(summary[key], "sim 摘要缺 \(key)")
        }
        // 委托行：active 标记（可撤单判定）+ 枚举取值合法
        let orders = try XCTUnwrap(data["orders"] as? [[String: Any]])
        for order in orders {
            XCTAssertNotNil(order["active"], "sim 委托行缺 active")
            let direction = try XCTUnwrap(order["direction"] as? String)
            XCTAssertNotNil(SimOrderDirection(rawValue: direction), "非法 direction \(direction)")
            let status = try XCTUnwrap(order["status"] as? String)
            XCTAssertNotNil(SimOrderStatus(rawValue: status), "非法 status \(status)")
        }
        // 模块取值合法
        let module = try XCTUnwrap(data["module"] as? String)
        XCTAssertNotNil(SimModuleTab(rawValue: module), "非法 module \(module)")
    }

    /// home.snapshot 响应形状锁定（P2-3）：入口清单含 tint、自选行含迷你走势 closes、模拟摘要含四个口径
    func testHomeSnapshotShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_home_snapshot"
        }, "fixtures 缺 home.snapshot 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        for key in ["loaded", "hasMainBoard", "entries", "indices", "breadth",
                    "favorites", "sim", "simPositions", "gainers", "gainersReady"] {
            XCTAssertNotNil(data[key], "home.snapshot 缺 \(key)")
        }
        // 入口形状：id/title/subtitle/tint（layoutEditor 退役不返回——由实现侧裁剪）
        let entries = try XCTUnwrap(data["entries"] as? [[String: Any]])
        for e in entries {
            for key in ["id", "title", "subtitle", "tint"] {
                XCTAssertNotNil(e[key], "home 入口缺 \(key)")
            }
        }
        // 自选行形状：迷你走势 closes 恒在
        let favs = try XCTUnwrap(data["favorites"] as? [[String: Any]])
        for row in favs {
            XCTAssertNotNil(row["closes"], "home 自选行缺 closes（迷你走势）")
        }
        // 模拟摘要口径
        let sim = try XCTUnwrap(data["sim"] as? [String: Any])
        for key in ["totalAssets", "dayProfit", "dayProfitPct", "positionPct"] {
            XCTAssertNotNil(sim[key], "home 模拟摘要缺 \(key)")
        }
    }

    /// home.openEntry payload 形状锁定：kind 必须可映射 HomeEntryKind
    func testHomeOpenEntryKind() throws {
        let fixture = try loadFixture()
        let requests = try XCTUnwrap(fixture["requests"] as? [[String: Any]])
        let req = try XCTUnwrap(requests.first {
            ($0["module"] as? String) == "home" && ($0["action"] as? String) == "openEntry"
        }, "fixtures 缺 home.openEntry 样例")
        let payload = try XCTUnwrap(req["payload"] as? [String: Any])
        let raw = try XCTUnwrap(payload["kind"] as? String)
        XCTAssertNotNil(HomeEntryKind(rawValue: raw), "kind=\(raw) 无法映射 HomeEntryKind")
    }

    /// market.snapshot 响应形状锁定（P2-2）：渲染列含 isNameCode/width、行含 fav/pinned/pct/values
    func testMarketSnapshotShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_mkt_snapshot"
        }, "fixtures 缺 market.snapshot 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        // 顶层键
        for key in ["loaded", "topMenu", "seconds", "columns", "rows"] {
            XCTAssertNotNil(data[key], "market.snapshot 缺 \(key)")
        }
        // 渲染列形状：合并列 + 数值列均带宽度
        let cols = try XCTUnwrap(data["columns"] as? [[String: Any]])
        let merged = cols.first { ($0["isNameCode"] as? Bool) == true }
        XCTAssertNotNil(merged, "渲染列缺名称/代码合并列")
        XCTAssertEqual(merged?["title"] as? String, "名称/代码")
        XCTAssertNotNil(merged?["width"] as? Int)
        // 行形状：着色基准 pct 恒发（可见列不含 changePct 时也要）
        let rows = try XCTUnwrap(data["rows"] as? [[String: Any]])
        for row in rows {
            for key in ["file", "code", "name", "fav", "pinned", "pct", "values"] {
                XCTAssertNotNil(row[key], "market 行缺 \(key)")
            }
        }
    }

    /// market.configSet payload 形状锁定：columns 含 visible/filterLabels，排序带 field/order
    func testMarketConfigSetShape() throws {
        let fixture = try loadFixture()
        let requests = try XCTUnwrap(fixture["requests"] as? [[String: Any]])
        let req = try XCTUnwrap(requests.first {
            ($0["module"] as? String) == "market" && ($0["action"] as? String) == "configSet"
        }, "fixtures 缺 market.configSet 样例")
        let payload = try XCTUnwrap(req["payload"] as? [String: Any])
        let cols = try XCTUnwrap(payload["columns"] as? [[String: Any]])
        for col in cols {
            XCTAssertNotNil(col["field"] as? String)
            XCTAssertNotNil(col["visible"] as? Bool)
            XCTAssertNotNil(col["filterLabels"] as? [String])
        }
        let rule = try XCTUnwrap(payload["sortRule"] as? [String: Any])
        XCTAssertEqual(rule["order"] as? String, "descending")
        let frozen = try XCTUnwrap(payload["frozenCount"] as? Int)
        XCTAssertTrue((1...3).contains(frozen), "frozenCount 必须在 1~3")
    }

    /// theme.set 幂等语义：同值写入无害（直接驱动 KlineThemeStore，写入后偏好与期望一致）
    func testThemeSetIdempotent() {
        let store = KlineThemeStore.shared
        let original = store.theme
        defer { store.theme = original }   // 还原，避免污染其他用例

        store.theme = .dark
        store.theme = .dark   // 幂等：同值重复写入
        XCTAssertEqual(store.theme, .dark)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "kline.displayTheme"), "dark")
    }

    /// lan.snapshot 响应形状锁定（P2-6c-1 联机同步页）：服务/暴露/扫描/对端/传输引擎/配置数据
    func testLANSSnapshotShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_lan_snapshot"
        }, "fixtures 缺 lan.snapshot 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        for key in ["serverOnline", "probing", "port", "deviceName", "isExposed",
                    "isBrowsing", "connecting", "peers", "busy", "transfer", "configure"] {
            XCTAssertNotNil(data[key], "lan.snapshot 缺 \(key)")
        }
        let peers = try XCTUnwrap(data["peers"] as? [[String: Any]])
        for p in peers {
            for key in ["id", "name", "host", "port"] { XCTAssertNotNil(p[key], "lan 对端行缺 \(key)") }
        }
        let transfer = try XCTUnwrap(data["transfer"] as? [String: Any])
        for key in ["phase", "progress", "bytesPerSecond", "currentFile",
                    "resultSummary", "backupDir", "needsRestart", "failMessage"] {
            XCTAssertNotNil(transfer[key], "lan 传输状态缺 \(key)")
        }
        let phase = try XCTUnwrap(transfer["phase"] as? String)
        XCTAssertTrue(["idle", "pairing", "transferring", "done", "failed"].contains(phase),
                      "非法 lan 传输 phase \(phase)")
    }

    /// lan.start payload 形状锁定：selections 的 category/mode 必须可映射传输引擎选择模型
    func testLanStartSelectionsShape() throws {
        let fixture = try loadFixture()
        let requests = try XCTUnwrap(fixture["requests"] as? [[String: Any]])
        let req = try XCTUnwrap(requests.first {
            ($0["module"] as? String) == "lan" && ($0["action"] as? String) == "start"
        }, "fixtures 缺 lan.start 样例")
        let payload = try XCTUnwrap(req["payload"] as? [String: Any])
        let selections = try XCTUnwrap(payload["selections"] as? [[String: Any]])
        XCTAssertFalse(selections.isEmpty, "lan.start selections 不能为空")
        for sel in selections {
            let cat = try XCTUnwrap(sel["category"] as? String)
            XCTAssertNotNil(LANSyncCategory(rawValue: cat), "非法同步类别 \(cat)")
            let mode = try XCTUnwrap(sel["mode"] as? String)
            XCTAssertTrue(["all", "children"].contains(mode), "非法选择粒度 \(mode)")
            XCTAssertNotNil(sel["childKeys"] as? [String], "selections 缺 childKeys（整类传空数组）")
        }
    }

    /// update.snapshot 响应形状锁定（P2-6c-1 本地更新页）：App 行/引擎行同构 + 清单自动更新 + 补缺口
    func testUpdateSnapshotShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_update_snapshot"
        }, "fixtures 缺 update.snapshot 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        for key in ["server", "app", "engine", "watchlist", "gap", "baseline"] {
            XCTAssertNotNil(data[key], "update.snapshot 缺 \(key)")
        }
        let validStates: Set<String> = ["idle", "checking", "latest", "outdated", "downloading", "failed"]
        for rowKey in ["app", "engine"] {
            let row = try XCTUnwrap(data[rowKey] as? [String: Any])
            for key in ["state", "remoteBuild", "currentBuild", "percent", "title"] {
                XCTAssertNotNil(row[key], "update.\(rowKey) 行缺 \(key)")
            }
            let state = try XCTUnwrap(row["state"] as? String)
            XCTAssertTrue(validStates.contains(state), "非法远程更新状态 \(state)")
        }
        let watch = try XCTUnwrap(data["watchlist"] as? [String: Any])
        for key in ["enabled", "isRunning", "stateText", "stateTone", "lastResultText",
                    "unionCount", "requestText", "lastTradeDate", "slots", "note"] {
            XCTAssertNotNil(watch[key], "update.watchlist 缺 \(key)")
        }
        let gap = try XCTUnwrap(data["gap"] as? [String: Any])
        for key in ["statusText", "coverageText", "baselineText", "baselineStale",
                    "fetchText", "verdictText", "isRunning", "baselineLoading", "detailLines"] {
            XCTAssertNotNil(gap[key], "update.gap 缺 \(key)")
        }
    }

    /// lab.snapshot 响应形状锁定（P2-6c-1 引擎实验室）：状态/操作/输出行
    func testLabSnapshotShape() throws {
        let fixture = try loadFixture()
        let responses = try XCTUnwrap(fixture["responses"] as? [[String: Any]])
        let snap = try XCTUnwrap(responses.first {
            ($0["id"] as? String) == "req_lab_snapshot"
        }, "fixtures 缺 lab.snapshot 响应样例")
        let data = try XCTUnwrap(snap["data"] as? [String: Any])
        for key in ["status", "apiVersion", "statusText", "source", "appPath", "manifest",
                    "isLoaded", "isBusy", "busyText", "downloadPercent", "runningExp", "outputLines"] {
            XCTAssertNotNil(data[key], "lab.snapshot 缺 \(key)")
        }
        let status = try XCTUnwrap(data["status"] as? String)
        XCTAssertTrue(["notInstalled", "installed", "versionMismatch", "corrupted"].contains(status),
                      "非法引擎状态 \(status)")
    }

    /// lab.runExp payload 形状锁定：实验编号 1~4
    func testLabRunExpShape() throws {
        let fixture = try loadFixture()
        let requests = try XCTUnwrap(fixture["requests"] as? [[String: Any]])
        let req = try XCTUnwrap(requests.first {
            ($0["module"] as? String) == "lab" && ($0["action"] as? String) == "runExp"
        }, "fixtures 缺 lab.runExp 样例")
        let payload = try XCTUnwrap(req["payload"] as? [String: Any])
        let id = try XCTUnwrap((payload["id"] as? NSNumber)?.intValue)
        XCTAssertTrue((1...4).contains(id), "实验编号必须在 1~4（实际 \(id)）")
    }
}
