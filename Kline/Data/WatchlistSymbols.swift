//
//  WatchlistSymbols.swift
//  Kline
//
//  Created by AI on 2026/09/22.
//
//  「App 内 6 类清单标的并集」的唯一入口：
//  自选 / 分组 / 置顶 / 预警 / 条件单 / 委托 → file 集合（形如 SH#600000）。
//
//  用途：盘中自动拉取、差分包范围计算等，凡是要「用户真正关心的标的」都从这里取。
//
//  映射基准 = 主库 meta 表（DatabaseManager.metaList 的 id / file / code）。
//  ⚠️ 主库 code 有重复（例如 62#000995 与 SZ#000995 同为 000995），
//     因此 code → file 只能作 fallback，且重复键一律丢弃（宁缺勿错）。
//

import Foundation

enum WatchlistSymbols {

    // MARK: - meta 映射字典

    /// 映射基准：metaID → file 与 code → file 两张字典
    struct MetaMaps {
        /// metaID → file（权威映射）
        var fileByMetaID: [Int: String] = [:]
        /// code（仅数字归一化）→ file；**仅作 fallback**：同码不同 file 的重复键一律丢弃
        var fileByCode: [String: String] = [:]
        /// 被丢弃的重复 code（供日志 / 自检）
        var ambiguousCodes: [String] = []
    }

    /// 代码归一化：只保留数字，兼容 "600519.SH" / "SH600519" / "600519" / "000995"
    static func normalizedCode(_ code: String) -> String {
        code.filter { $0.isNumber }
    }

    /// 用主库 meta 表建字典。纯数据操作，不读 Store，可在任意线程调用。
    static func buildMaps(from metaList: [MetaItem]) -> MetaMaps {
        var maps = MetaMaps()
        maps.fileByMetaID.reserveCapacity(metaList.count)
        var ambiguous = Set<String>()

        for m in metaList {
            maps.fileByMetaID[m.id] = m.file

            let key = normalizedCode(m.code)
            guard !key.isEmpty else { continue }
            if ambiguous.contains(key) { continue }     // 已判定重复：直接跳过

            if let existing = maps.fileByCode[key], existing != m.file {
                // 同码指向不同 file：该键作废（先到的那条也移除），并记一条日志
                ambiguous.insert(key)
                maps.fileByCode.removeValue(forKey: key)
                DebugLogger.shared.log("[WatchlistSymbols] code 重复已丢弃 key=\(key) file1=\(existing) file2=\(m.file)")
                continue
            }
            maps.fileByCode[key] = m.file
        }

        maps.ambiguousCodes = ambiguous.sorted()
        return maps
    }

    // MARK: - 并集
    //
    // 清单来源：
    //   自选 / 分组：FavoritesStore 各组 manualMetaIDs + 公式组 cachedMatches
    //   置顶：各组 pinnedMetaIDs
    //   预警 / 条件单：SimStore.conditionalOrders（其中 directive.isAlertOnly 为预警）
    //   委托：SimStore.orders

    /// 一条「清单标的」引用：metaID + 可选 code（sim.json 的 code 形如 "600519.SH"）
    private struct SymbolRef {
        let source: String
        let metaID: Int
        let code: String?
    }

    /// 收集 6 类清单的原始引用（FavoritesStore / SimStore 均为 @MainActor，故本方法需主线程）
    @MainActor
    private static func collectRefs() -> [SymbolRef] {
        var refs: [SymbolRef] = []

        for g in FavoritesStore.shared.groups {
            switch g.kind {
            case .manual:
                for id in g.manualMetaIDs {
                    refs.append(SymbolRef(source: "自选", metaID: id, code: nil))
                }
            case .formula:
                for id in g.cachedMatches ?? [] {
                    refs.append(SymbolRef(source: "分组", metaID: id, code: nil))
                }
            }
            for id in g.pinnedMetaIDs ?? [] {
                refs.append(SymbolRef(source: "置顶", metaID: id, code: nil))
            }
        }

        let sim = SimStore.shared
        for o in sim.conditionalOrders {
            let source = o.directive.isAlertOnly ? "预警" : "条件单"
            refs.append(SymbolRef(source: source, metaID: o.metaID, code: o.code))
        }
        for o in sim.orders {
            refs.append(SymbolRef(source: "委托", metaID: o.metaID, code: o.code))
        }

        return refs
    }

    /// 单条引用 → file：优先 metaID，取不到再用 code 字典兜底
    private static func resolve(_ ref: SymbolRef, maps: MetaMaps) -> String? {
        if ref.metaID > 0, let file = maps.fileByMetaID[ref.metaID] { return file }
        if let code = ref.code {
            let key = normalizedCode(code)
            if !key.isEmpty, let file = maps.fileByCode[key] { return file }
        }
        return nil
    }

    /// **唯一入口**：6 类清单并集 → file 集合。
    /// 清单为空 / 主库未就绪 / 全部无法映射 → 返回空集合，不报错、不抛异常。
    @MainActor
    static func unionFiles() -> Set<String> {
        unionFiles(maps: buildMaps(from: DatabaseManager.shared.metaList))
    }

    /// 同上，允许注入已建好的字典（避免重复建表）
    @MainActor
    static func unionFiles(maps: MetaMaps) -> Set<String> {
        var files = Set<String>()
        for ref in collectRefs() {
            if let file = resolve(ref, maps: maps) {
                files.insert(file)
            }
        }
        return files
    }

    // MARK: - 自检摘要

    /// file 的前缀（"SH#600000" → "SH"，"27#xxx" → "27"；无 "#" 时返回原串）
    private static func prefix(of file: String) -> String {
        guard let i = file.firstIndex(of: "#") else { return file }
        return String(file[file.startIndex..<i])
    }

    /// 自检摘要：并集标的数、前缀分布、code 重复丢弃数、无法映射样例（最多 10 条）
    @MainActor
    static func debugSummary() -> String {
        let maps = buildMaps(from: DatabaseManager.shared.metaList)
        let refs = collectRefs()

        var files = Set<String>()
        var unmapped: [SymbolRef] = []
        for ref in refs {
            if let file = resolve(ref, maps: maps) {
                files.insert(file)
            } else {
                unmapped.append(ref)
            }
        }

        var buckets: [String: Int] = [:]
        for f in files { buckets[prefix(of: f), default: 0] += 1 }

        let order = ["SH", "SZ", "BJ", "27", "62", "102"]
        var known = 0
        var parts: [String] = []
        for p in order {
            let n = buckets[p] ?? 0
            known += n
            parts.append("\(p)=\(n)")
        }
        parts.append("其他=\(files.count - known)")

        var lines: [String] = []
        lines.append("[WatchlistSymbols] 并集标的数=\(files.count)（清单引用 \(refs.count) 条）")
        lines.append("[WatchlistSymbols] 前缀分布：\(parts.joined(separator: " "))")
        lines.append("[WatchlistSymbols] code 重复已丢弃 \(maps.ambiguousCodes.count) 个键")
        lines.append("[WatchlistSymbols] 无法映射 \(unmapped.count) 条")
        for ref in unmapped.prefix(10) {
            lines.append("[WatchlistSymbols]   未映射 source=\(ref.source) metaID=\(ref.metaID) code=\(ref.code ?? "-")")
        }
        return lines.joined(separator: "\n")
    }
}