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

/// 系统指标定义（公式模板）
struct SystemIndicatorDef {
    let id: String                 // 与文件名同名，如 "MACD"
    let name: String
    let scope: IndicatorScope
    let group: String              // 副图分组（如 量能/趋向/超买超卖；主图或未定义时为空）
    let formulaTemplate: String    // 公式模板（固定值，不含占位符）
}

/// 系统指标仓库：加载并解析 .tdx 定义文件
final class SystemIndicatorStore: ObservableObject {
    static let shared = SystemIndicatorStore()

    /// 副图分组展示顺序（内置，用于选择页排序；分组归属由 .tdx 的 GROUP= 决定）
    static let subGroupOrder: [String] = ["量能", "趋向", "超买超卖"]

    /// 主图指标展示顺序（内置，用于选择页排序；是否为主图由 .tdx 的 SCOPE= 决定）
    static let mainOrder: [String] = ["MA", "EMA", "BOLL", "CMK", "SAR"]

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

    /// 解析 .tdx 内容（NAME= / SCOPE= / GROUP= / FORMULA: 后为多行模板）
    private func parse(content: String, id: String) -> SystemIndicatorDef? {
        var name = id
        var scope = IndicatorScope.sub
        var group = ""
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
            } else if line.hasPrefix("GROUP=") {
                group = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line == "FORMULA:" || line == "FORMULA" {
                inFormula = true
            } else if line.hasPrefix("FORMULA=") {
                inFormula = true
                let rest = String(line.dropFirst(8))
                if !rest.isEmpty { template.append(rest) }
            }
        }
        guard !template.isEmpty else { return nil }
        return SystemIndicatorDef(id: id, name: name, scope: scope, group: group,
                                  formulaTemplate: template.joined(separator: "\n"))
    }

    private func load() {
        let fm = FileManager.default
        let dir = Self.writableDir
        // 目录不存在时创建
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // 每次加载都同步 bundle 中沙盒尚缺的模板：新增的 .tdx 也会被复制进来；
        // copyBuiltin 只复制沙盒不存在的文件，已存在的用户修改副本不会被覆盖。
        copyBuiltin(to: dir)
        // 解析 Documents/indicator/*.tdx
        var result: [String: SystemIndicatorDef] = [:]
        if let files = try? fm.contentsOfDirectory(atPath: dir) {
            for f in files where f.hasSuffix(".\(fileExt)") {
                let id = (f as NSString).deletingPathExtension
                let path = dir + "/" + f
                var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                // 迁移旧版模板：若沙盒副本仍含 {占位符}，或副图模板缺少 GROUP 分组行，
                // 用内置固定值模板覆盖，保证新逻辑生效且用户可在此基础上继续编辑
                let isSub = content.contains("SCOPE=sub") || content.contains("SCOPE=SUB")
                let needsRefresh = content.contains("{") || (isSub && !content.contains("GROUP="))
                if needsRefresh, let builtin = builtinContent(for: id) {
                    try? builtin.write(toFile: path, atomically: true, encoding: .utf8)
                    content = builtin
                }
                if let def = parse(content: content, id: id) {
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

    /// 读取 bundle 内内置模板内容（用于恢复编译时内容 / 旧占位符模板迁移）
    private func builtinContent(for id: String) -> String? {
        var url = Bundle.main.url(forResource: id, withExtension: fileExt, subdirectory: builtinSubdir)
        if url == nil { url = Bundle.main.url(forResource: id, withExtension: fileExt, subdirectory: nil) }
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
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

    /// 当前（Documents 中可写副本的）公式模板（仅 FORMULA 部分）
    func template(for id: String) -> String? {
        defs[id]?.formulaTemplate
    }

    /// 所有副图 .tdx 定义（SCOPE=sub），按组序 + id 排序，供选择页数据驱动展示分组
    func subIndicatorDefs() -> [SystemIndicatorDef] {
        defs.values
            .filter { $0.scope == .sub }
            .sorted { a, b in
                let ia = Self.subGroupOrder.firstIndex(of: a.group) ?? Int.max
                let ib = Self.subGroupOrder.firstIndex(of: b.group) ?? Int.max
                if ia != ib { return ia < ib }
                return a.id < b.id
            }
    }

    /// 所有主图 .tdx 定义（SCOPE=main），按 mainOrder + id 排序，供主图选择页数据驱动展示
    func mainIndicatorDefs() -> [SystemIndicatorDef] {
        defs.values
            .filter { $0.scope == .main }
            .sorted { a, b in
                let ia = Self.mainOrder.firstIndex(of: a.id) ?? Int.max
                let ib = Self.mainOrder.firstIndex(of: b.id) ?? Int.max
                if ia != ib { return ia < ib }
                return a.id < b.id
            }
    }

    /// 把所有新公式模板写回 Documents/indicator/<id>.tdx（保留 NAME/SCOPE/GROUP 头），并重载。
    /// 保存成功后 defs 立即更新，图表重算即可生效。
    @discardableResult
    func saveTemplate(_ template: String, for id: String) -> Bool {
        guard let def = defs[id] else { return false }
        let scopeStr = def.scope == .main ? "main" : "sub"
        let groupLine = def.group.isEmpty ? "" : "GROUP=\(def.group)\n"
        let content = "NAME=\(def.name)\nSCOPE=\(scopeStr)\n\(groupLine)FORMULA:\n\(template)"
        return write(content, for: id)
    }

    /// 恢复该指标的「编译时内容」：把内置打包模板复制回 Documents/indicator/<id>.tdx，并重载。
    @discardableResult
    func restoreBuiltin(for id: String) -> Bool {
        var src = Bundle.main.url(forResource: id, withExtension: fileExt, subdirectory: builtinSubdir)
        if src == nil { src = Bundle.main.url(forResource: id, withExtension: fileExt, subdirectory: nil) }
        guard let src,
              let content = try? String(contentsOf: src, encoding: .utf8) else { return false }
        return write(content, for: id)
    }

    /// 写入 Documents/indicator/<id>.tdx 并重载（重载成功后 defs 更新）
    private func write(_ content: String, for id: String) -> Bool {
        let fm = FileManager.default
        let dir = Self.writableDir
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(id).tdx"
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        load()
        return defs[id] != nil
    }
}
