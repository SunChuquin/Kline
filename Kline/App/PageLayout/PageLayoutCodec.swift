//
//  PageLayoutCodec.swift
//  Kline
//
//  通用 JSON 布局引擎 - 编解码口径（与具体页面无关）。
//
//  本文件是配置文本的**唯一编解码口径**：落盘、JSON 原文页签、脏标记（规范化文本比较）
//  以及「由当前树生成」全部走这里，避免各处 `JSONEncoder/JSONDecoder` 参数不一致。
//
//  编码口径：JSONEncoder + [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
//  解码口径：JSONDecoder（未知 type 由模型白名单拦截并抛错）
//

import Foundation

enum PageLayoutCodec {

    /// 解析配置文本；失败（含未知节点 type）返回 nil
    static func decode(_ text: String) -> PageLayoutFile? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PageLayoutFile.self, from: data)
    }

    /// 编码为落盘 / 展示用文本；失败返回 nil
    static func encode(_ file: PageLayoutFile) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 规范化文本（与 `encode` 同一口径）：作为脏标记与「由当前树生成」的统一来源
    static func canonicalText(_ file: PageLayoutFile) -> String? {
        encode(file)
    }
}