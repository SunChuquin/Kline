//
//  SystemIndicatorStore.swift
//  Kline
//
//  系统指标定义存储：内置公式模板随 App 打包（bundle/Indicators/*.tdx）。
//  按周期分目录存储：Documents/indicator/<周期目录名>/*.tdx，每个周期目录内都有一份内置模板的
//  独立克隆副本（目录名取数据库周期表英文名：daily/weekly/monthly/quarterly/yearly）。
//  这样不同周期即使选择同一指标，也能各自维护不同的指标参数（数据驱动：参数即 .tdx 模板内容）。
//  每个周期的首启会用 bundle 内置模板初始化该周期目录；用户可通过文件 App 单独改某周期的 .tdx。
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

/// 系统指标仓库：按周期分目录加载并解析 .tdx 定义文件
final class SystemIndicatorStore: ObservableObject {
    static let shared = SystemIndicatorStore()

    /// 副图分组展示顺序（内置，用于选择页排序；分组归属由 .tdx 的 GROUP= 决定）
    static let subGroupOrder: [String] = ["量能", "趋向", "超买超卖"]

    /// 主图指标展示顺序（内置，用于选择页排序；是否为主图由 .tdx 的 SCOPE= 决定）
    static let mainOrder: [String] = ["MA", "EMA", "BOLL", "CMK", "SAR"]

    /// 已加载的定义：key = 周期目录名（daily...），value = 该周期的 {指标 id: 定义}
    @Published var defs: [String: [String: SystemIndicatorDef]] = [:]

    /// Documents 下某个周期的可写指标目录（Documents/indicator/<周期目录名>）
    static func writableDir(for period: KlinePeriod) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("indicator", isDirectory: true)
            .appendingPathComponent(period.folderName, isDirectory: true).path
    }

    private let builtinSubdir = "Indicators"
    private let fileExt = "tdx"

    private init() {
        loadAllPeriods()
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

    /// 为所有周期建立目录、同步内置模板并加载各自的定义。
    /// 迁移策略：每个周期目录直接用 bundle 内置模板初始化（忽略旧的扁平 Documents/indicator 副本）。
    private func loadAllPeriods() {
        let fm = FileManager.default
        var result: [String: [String: SystemIndicatorDef]] = [:]
        for period in KlinePeriod.allCases {
            let dir = Self.writableDir(for: period)
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            // 每次加载都同步 bundle 中该周期目录尚缺的模板：新增的 .tdx 也会被复制进来；
            // copyBuiltin 只复制不存在的文件，已存在的用户修改副本不会被覆盖。
            copyBuiltin(to: dir)
            var section: [String: SystemIndicatorDef] = [:]
            if let files = try? fm.contentsOfDirectory(atPath: dir) {
                for f in files where f.hasSuffix(".\(fileExt)") {
                    let id = (f as NSString).deletingPathExtension
                    let path = dir + "/" + f
                    let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                    if let def = parse(content: content, id: id) {
                        section[id] = def
                    }
                }
            }
            result[period.folderName] = section
        }
        defs = result
    }

    /// 复制内置模板到指定周期目录
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

    /// 读取 bundle 内内置模板内容（用于恢复编译时内容）
    private func builtinContent(for id: String) -> String? {
        var url = Bundle.main.url(forResource: id, withExtension: fileExt, subdirectory: builtinSubdir)
        if url == nil { url = Bundle.main.url(forResource: id, withExtension: fileExt, subdirectory: nil) }
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 某周期的全部定义
    func defs(for period: KlinePeriod) -> [String: SystemIndicatorDef] {
        defs[period.folderName] ?? [:]
    }

    /// 用参数替换公式模板中的 {key} 占位符，返回可直接求值的公式（只查该周期的定义）
    func formula(for id: String, values: [String: String], period: KlinePeriod) -> String? {
        guard let def = defs(for: period)[id] else { return nil }
        var s = def.formulaTemplate
        for (k, v) in values {
            s = s.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return s
    }

    /// 某周期可写副本的（仅 FORMULA 部分）公式模板
    func template(for id: String, period: KlinePeriod) -> String? {
        defs(for: period)[id]?.formulaTemplate
    }

    /// 该周期所有副图 .tdx 定义（SCOPE=sub），按组序 + id 排序
    func subIndicatorDefs(period: KlinePeriod) -> [SystemIndicatorDef] {
        defs(for: period).values
            .filter { $0.scope == .sub }
            .sorted { a, b in
                let ia = Self.subGroupOrder.firstIndex(of: a.group) ?? Int.max
                let ib = Self.subGroupOrder.firstIndex(of: b.group) ?? Int.max
                if ia != ib { return ia < ib }
                return a.id < b.id
            }
    }

    /// 该周期所有主图 .tdx 定义（SCOPE=main），按 mainOrder + id 排序
    func mainIndicatorDefs(period: KlinePeriod) -> [SystemIndicatorDef] {
        defs(for: period).values
            .filter { $0.scope == .main }
            .sorted { a, b in
                let ia = Self.mainOrder.firstIndex(of: a.id) ?? Int.max
                let ib = Self.mainOrder.firstIndex(of: b.id) ?? Int.max
                if ia != ib { return ia < ib }
                return a.id < b.id
            }
    }

    /// 把新公式模板写回该周期的 Documents/indicator/<周期目录>/<id>.tdx，并重载。
    @discardableResult
    func saveTemplate(_ template: String, for id: String, period: KlinePeriod) -> Bool {
        guard let def = defs(for: period)[id] else { return false }
        let scopeStr = def.scope == .main ? "main" : "sub"
        let groupLine = def.group.isEmpty ? "" : "GROUP=\(def.group)\n"
        let content = "NAME=\(def.name)\nSCOPE=\(scopeStr)\n\(groupLine)FORMULA:\n\(template)"
        return write(content, for: id, period: period)
    }

    /// 恢复该指标在该周期的「编译时内容」：把内置打包模板复制回该周期目录的 .tdx，并重载。
    @discardableResult
    func restoreBuiltin(for id: String, period: KlinePeriod) -> Bool {
        guard let content = builtinContent(for: id) else { return false }
        return write(content, for: id, period: period)
    }

    /// 重置该周期所有内置指标为「编译时内容」：把 bundle 内每个内置 .tdx 覆盖写回该周期目录。
    @discardableResult
    func restoreAllBuiltin(period: KlinePeriod) -> Bool {
        var urls = Bundle.main.urls(forResourcesWithExtension: fileExt, subdirectory: builtinSubdir) ?? []
        if urls.isEmpty { urls = Bundle.main.urls(forResourcesWithExtension: fileExt, subdirectory: nil) ?? [] }
        var ok = true
        for src in urls {
            guard let content = try? String(contentsOf: src, encoding: .utf8) else { ok = false; continue }
            let id = src.deletingPathExtension().lastPathComponent
            if !write(content, for: id, period: period) { ok = false }
        }
        return ok
    }

    /// 写入某周期目录的 .tdx 并重载该周期定义
    private func write(_ content: String, for id: String, period: KlinePeriod) -> Bool {
        let fm = FileManager.default
        let dir = Self.writableDir(for: period)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(id).tdx"
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        reload(period: period)
        return defs(for: period)[id] != nil
    }

    /// 重新加载单个周期的定义
    private func reload(period: KlinePeriod) {
        let fm = FileManager.default
        let dir = Self.writableDir(for: period)
        var section: [String: SystemIndicatorDef] = [:]
        if let files = try? fm.contentsOfDirectory(atPath: dir) {
            for f in files where f.hasSuffix(".\(fileExt)") {
                let id = (f as NSString).deletingPathExtension
                let path = dir + "/" + f
                let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                if let def = parse(content: content, id: id) {
                    section[id] = def
                }
            }
        }
        var all = defs
        all[period.folderName] = section
        defs = all
    }
}