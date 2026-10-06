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
    let coord: Int?                // COORD= 可选字段：nil=未声明（显示坐标值）；0=隐藏图左侧顶底坐标值；其他值=显示
    let formulaTemplate: String    // 公式模板（固定值，不含占位符）

    /// 该指标所在图是否隐藏左侧顶底坐标值（仅 COORD=0 隐藏）
    var hideCoord: Bool { coord == 0 }
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

    /// 解析 .tdx 内容（KIND= / NAME= / SCOPE= / GROUP= / COORD= / FORMULA: 后为多行模板）
    func parse(content: String, id: String) -> SystemIndicatorDef? {
        var name = id
        var scope = IndicatorScope.sub
        var group = ""
        var coord: Int? = nil
        var template: [String] = []
        var inFormula = false
        // 头部预扫描：兜住 KIND= 被写在 FORMULA: 之后的手工粘贴场景——
        // 遍历所有行，只要出现 KIND= 且取值不是 TECH（含无法解析的未知值），一律不装载
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("KIND=") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).uppercased()
                if FormulaKind(rawValue: value) != .tech { return nil }
            }
        }
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inFormula {
                if !line.isEmpty { template.append(line) }
                continue
            }
            if line.hasPrefix("KIND=") {
                // KIND= 类型头：仅 TECH 在此装载；选股/策略或未知取值一律不装载，保证与选股/策略目录零交叉
                let kindValue = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).uppercased()
                guard FormulaKind(rawValue: kindValue) == .tech else { return nil }
            } else if line.hasPrefix("NAME=") {
                name = String(line.dropFirst(5))
            } else if line.hasPrefix("SCOPE=") {
                let v = String(line.dropFirst(6)).uppercased()
                scope = (v == "MAIN" || v == "主图") ? .main : .sub
            } else if line.hasPrefix("GROUP=") {
                group = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("COORD=") {
                coord = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
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
                                  coord: coord,
                                  formulaTemplate: template.joined(separator: "\n"))
    }

    /// 为所有周期建立目录、同步内置模板并加载各自的定义。
    /// 迁移策略：每个周期目录直接用 bundle 内置模板初始化（忽略旧的扁平 Documents/indicator 副本）。
    private func loadAllPeriods() {
        let fm = FileManager.default
        var result: [String: [String: SystemIndicatorDef]] = [:]
        // 校准输入收集（纯追加，不影响解析行为）：本轮实际解析过的 .tdx 原文，按周期组织
        var calibContents: [String: [(id: String, content: String)]] = [:]
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
                    calibContents[period.folderName, default: []].append((id: id, content: content))
                    if let def = parse(content: content, id: id) {
                        section[id] = def
                    }
                }
            }
            result[period.folderName] = section
        }
        defs = result
        // 触发点：本轮加载完成后异步派发权威校准（不阻塞、不等待；reloadAllPeriods 经由本函数同样覆盖）
        calibrateWithPythonIfNeeded(calibContents)
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

    /// 外部（如自定义指标增删改落地 USER_*.tdx 后）触发重载所有周期的定义
    func reloadAllPeriods() {
        loadAllPeriods()
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
    /// COORD 行原样保留（否则公式编辑保存会丢失坐标值显隐配置）。
    @discardableResult
    func saveTemplate(_ template: String, for id: String, period: KlinePeriod) -> Bool {
        guard let def = defs(for: period)[id] else { return false }
        let scopeStr = def.scope == .main ? "main" : "sub"
        let groupLine = def.group.isEmpty ? "" : "GROUP=\(def.group)\n"
        let coordLine = def.coord.map { "COORD=\($0)\n" } ?? ""
        let content = "KIND=TECH\nNAME=\(def.name)\nSCOPE=\(scopeStr)\n\(groupLine)\(coordLine)FORMULA:\n\(template)"
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

    // MARK: - Python 后台权威校准（候选 1：指标模板解析）

    /// 校准防重入：loadAllPeriods/reloadAllPeriods 可能连续触发，简单串行化——in-flight 期间新轮次直接跳过
    private let calibrateLock = NSLock()
    private var calibrateInFlight = false

    /// 后台权威校准：把本轮 Swift 解析过的 .tdx 原文交给 Python（template_parse.py）对拍并修正 defs。
    /// - 同步路径零依赖：仅异步派发；isReady 为纯只读检查，引擎未就绪（如首帧）静默跳过，绝不触发引擎初始化；
    /// - 输入条目顺序与 keys 平行数组一致，脚本契约保证输出顺序与输入一致，按索引对齐回周期；
    /// - 失败（超时/脚本错误/解码失败）只记日志，defs 保持 Swift 解析结果持续服务。
    private func calibrateWithPythonIfNeeded(_ contents: [String: [(id: String, content: String)]]) {
        calibrateLock.lock()
        if calibrateInFlight {
            calibrateLock.unlock()
            return
        }
        calibrateInFlight = true
        calibrateLock.unlock()

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            // 前置：引擎未就绪只读跳过（首启必然走到，静默不刷日志）；惰性激活后台加载一次
            guard KlinePythonBridge.shared.isReady else {
                KlinePythonBridge.shared.ensureOnce()
                self.calibrateLock.lock()
                self.calibrateInFlight = false
                self.calibrateLock.unlock()
                return
            }
            var items: [[String: Any]] = []
            var keys: [(period: String, id: String)] = []
            for (period, list) in contents {
                for entry in list {
                    items.append(["id": entry.id, "content": entry.content])
                    keys.append((period: period, id: entry.id))
                }
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            KlinePythonBridge.shared.call(script: "template_parse", input: ["items": items], timeout: 5.0) { [weak self] r in
                guard let self else { return }
                self.calibrateLock.lock()
                self.calibrateInFlight = false
                self.calibrateLock.unlock()
                // defs 为 @Published：对拍与变更一律回主线程（call 的早期前置失败可能同步回调在后台线程）
                let work = { self.applyTemplateCalibration(result: r, keys: keys,
                                                           inputCount: items.count,
                                                           elapsed: CFAbsoluteTimeGetCurrent() - t0) }
                if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
            }
        }
    }

    /// 把 Python 校准结果对拍进 defs（必须在主线程执行）：以 Python accepted 结果为权威
    private func applyTemplateCalibration(result: Result<Data, PyBridgeError>,
                                          keys: [(period: String, id: String)],
                                          inputCount: Int,
                                          elapsed: TimeInterval) {
        let data: Data
        switch result {
        case .failure(let e):
            let reason: String
            switch e {
            case .engineNotReady(let m): reason = "引擎未就绪：\(m)"
            case .timeout:               reason = "超时"
            case .scriptError(let m):    reason = "脚本错误：\(m)"
            }
            DebugLogger.shared.log("[PyBridge] 模板校准失败（\(Int(elapsed * 1000))ms），沿用 Swift 解析结果——\(reason)")
            return
        case .success(let d):
            data = d
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let entries = dict["result"] as? [[String: Any]] else {
            DebugLogger.shared.log("[PyBridge] 模板校准失败（\(Int(elapsed * 1000))ms），沿用 Swift 解析结果——输出解码失败")
            return
        }
        guard entries.count == keys.count else {
            DebugLogger.shared.log("[PyBridge] 模板校准失败（\(Int(elapsed * 1000))ms），沿用 Swift 解析结果——结果条数 \(entries.count) ≠ 输入 \(keys.count)")
            return
        }
        var all = defs
        var diffCount = 0
        var details: [String] = []
        for (i, e) in entries.enumerated() {
            let period = keys[i].period
            let id = keys[i].id
            guard all[period] != nil else { continue }
            let accepted = (e["accepted"] as? Bool) ?? false
            let existing = all[period]?[id]
            if accepted {
                guard let name = e["name"] as? String,
                      let scopeStr = e["scope"] as? String,
                      let template = e["formulaTemplate"] as? String else {
                    details.append("[\(period)] \(id)：Python 条目字段缺失（防御跳过，不做变更）")
                    continue
                }
                let group = e["group"] as? String ?? ""
                let coord = e["coord"] as? Int
                let scope: IndicatorScope = (scopeStr == "main") ? .main : .sub
                guard let def = existing else {
                    // Swift parse 返回 nil（拒载）而 Python 通过 → 补挂定义
                    diffCount += 1
                    all[period]?[id] = SystemIndicatorDef(id: id, name: name, scope: scope, group: group,
                                                          coord: coord, formulaTemplate: template)
                    details.append("[\(period)] \(id)：Swift 无此定义而 Python 通过 → 新增")
                    continue
                }
                var fieldDiffs: [String] = []
                if def.name != name { fieldDiffs.append("name「\(def.name)」→「\(name)」") }
                if def.scope != scope { fieldDiffs.append("scope \(def.scope)→\(scope)") }
                if def.group != group { fieldDiffs.append("group「\(def.group)」→「\(group)」") }
                if def.coord != coord { fieldDiffs.append("coord \(String(describing: def.coord))→\(String(describing: coord))") }
                if def.formulaTemplate != template {
                    fieldDiffs.append("formulaTemplate \(Self.preview(def.formulaTemplate))→\(Self.preview(template))")
                }
                if !fieldDiffs.isEmpty {
                    diffCount += 1
                    all[period]?[id] = SystemIndicatorDef(id: def.id, name: name, scope: scope, group: group,
                                                          coord: coord, formulaTemplate: template)
                    details.append("[\(period)] \(id)：\(fieldDiffs.joined(separator: "；"))")
                }
            } else if existing != nil {
                // Python 拒载而 Swift defs 中存在 → 移除
                diffCount += 1
                all[period]?.removeValue(forKey: id)
                details.append("[\(period)] \(id)：Python 拒载而 Swift 存在 → 移除")
            }
        }
        if diffCount > 0 { defs = all }
        DebugLogger.shared.log(String(format: "[PyBridge] 模板校准完成：输入 %d 条，差异 %d 条（%.0fms）",
                                      inputCount, diffCount, elapsed * 1000))
        for d in details {
            DebugLogger.shared.log("[PyBridge] 模板校准差异——\(d)")
        }
    }

    /// 差异日志的长文本预览（模板全文防刷屏，超 120 字截断）
    private static func preview(_ s: String) -> String {
        s.count > 120 ? "\(s.prefix(120))…（共\(s.count)字）" : s
    }
}