import XCTest
@testable import Kline

final class KlineTests: XCTestCase {

    /// 占位测试：验证 KlineTests target 已接通主 App（BUNDLE_LOADER/TEST_HOST + @testable）。
    func testTargetWired() throws {
        XCTAssertTrue(true)
    }

    /// 占位测试：验证 synchronized group 下 Fixtures/*.json 会被作为资源打入测试 bundle 根目录。
    func testPlaceholderFixtureIsBundled() throws {
        let url = Bundle(for: Self.self).url(forResource: "placeholder", withExtension: "json")
        XCTAssertNotNil(url, "placeholder.json 应被打包进 KlineTests.xctest bundle")
    }
}
