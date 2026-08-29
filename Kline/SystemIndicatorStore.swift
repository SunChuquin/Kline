//
//  SystemIndicatorStore.swift
//  Kline
//
//  系统指标定义存储：内置公式模板随 App 打包（bundle/Indicators/*.tdx），
//  首次启动复制到 Documents/indicator/*.tdx，之后优先从 Documents 加载，
//  可通过 Finder / 文件 App 替换 Documents/indicator/*.tdx 单独更新指标公式，无需重装 App。
//
//  Created by 孙楚昆 on 2026/8/29.
//

import Foundation
import Combine

/// 系统指标定义（公式模板，含 {参数} 占位符）
struct SystemIndicatorDef {
    let id: String                 // 与文件名同名，如 "MACD"
    let name: String
    let scope: IndicatorScope
    let formulaTemplate: String    // 含 {param} 占位符，运行期替换为参数值
}

/// 系统指标仓库：加载并解析 .tdx 定义文件
final class SystemIndicatorStore: ObservableObject {
    static let shared = SystemIndicatorStore()

    /// 已加载的定义（key = 指标 id）
    @Published var defs: [String: SystemIndicatorDef] = [:]

    /// Documents 下可写的指标目录
    static var writableDir: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("indicator", isDirectory: true).path
    }

    private let builtinSubdir = "Indicators"
    private let fileExt = "tdx"

    private init() {
        load()
    }

    /// 解析 .tdx 内容（NAME= / SCOPE= / FORMULA: 后为多行模板）
    private func parse(content: String, id: String) -> SystemIndicatorDef? {
        var name = id
        var scope = IndicatorScope.sub
        var template: [String] = []
        var inFormula = false
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inFormula {
                if !line.isEmpty { template.append(line) }
                continue
            }
            if line.hasPrefix("NAME=") {
                name = String(line.dropFirst(5))
            } else if line.hasPrefix("SCOPE=") {
                let v = String(line.dropFirst(6)).uppercased()
                scope = (v == "MAIN" || v == "主图") ? .main : .sub
            } else if line == "FORMULA:" || line == "FORMULA" {
                inFormula = true
            } else if line.hasPrefix("FORMULA=") {
                inFormula = true
                let rest = String(line.dropFirst(8))
                if !rest.isEmpty { template.append(rest) }
            }
        }
        guard !template.isEmpty else { return nil }
        return SystemIndicatorDef(id: id, name: name, scope: scope, formulaTemplate: template.joined(separator: "\n"))
    }

    private func load() {
        let fm = FileManager.default
        let dir = Self.writableDir
        // 目录不存在或为空时，把内置模板复制过去作为初始定义
        var needsSeed = true
        if fm.fileExists(atPath: dir) {
            let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            needsSeed = files.isEmpty
        }
        if needsSeed {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            copyBuiltin(to: dir)
        }
        // 解析 Documents/indicator/*.tdx
        var result: [String: SystemIndicatorDef] = [:]
        if let files = try? fm.contentsOfDirectory(atPath: dir) {
            for f in files where f.hasSuffix(".\(fileExt)") {
                let id = (f as NSString).deletingPathExtension
                let path = dir + "/" + f
                if let content = try? String(contentsOfFile: path, encoding: .utf8),
                   let def = parse(content: content, id: id) {
                    result[id] = def
                }
            }
        }
        defs = result
    }

    /// 复制内置模板到 Documents/indicator
    private func copyBuiltin(to dir: String) {
        let fm = FileManager.default
        // 兼容两种打包方式：打包进 Indicators/ 子目录，或按通配符扁平化到 bundle 根目录
        var urls = Bundle.main.urls(forResourcesWithExtension: fileExt, subdirectory: builtinSubdir) ?? []
        if urls.isEmpty {
            urls = Bundle.main.urls(forResourcesWithExtension: fileExt, subdirectory: nil) ?? []
        }
        for src in urls {
            let dst = dir + "/" + src.lastPathComponent
            if !fm.fileExists(atPath: dst) {
                try? fm.copyItem(at: src, to: URL(fileURLWithPath: dst))
            }
        }
    }

    /// 用参数替换公式模板中的 {key} 占位符，返回可直接求值的公式
    func formula(for id: String, values: [String: String]) -> String? {
        guard let def = defs[id] else { return nil }
        var s = def.formulaTemplate
        for (k, v) in values {
            s = s.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return s
    }
}
