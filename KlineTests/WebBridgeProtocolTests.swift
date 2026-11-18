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
                                        "favorites.changed", "market.changed"]
        for ev in events {
            let name = try XCTUnwrap(ev["event"] as? String)
            XCTAssertTrue(knownEvents.contains(name), "未知事件 \(name)（协议 v2 事件清单外）")
        }
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

    /// P2-5 预留形状锁定（sheet.open/close 属图表弹层批次）
    func testReservedSheetActions() throws {
        let fixture = try loadFixture()
        let reserved = try XCTUnwrap(fixture["reserved"] as? [String: Any])
        let open = try XCTUnwrap(reserved["sheet.open"] as? [String: Any])
        XCTAssertNotNil(open["name"], "sheet.open 预留缺 name 字段")
        XCTAssertNotNil(reserved["sheet.close"] as? [String: Any])
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
}
