//
//  FavoritesStore.swift
//  Kline
//
//  Created by AI on 2026/09/01.
//
//  自选与分组的持久化：
//  - 支持「自定义分组」：用户手动增删、拖动排序
//  - 支持「指标公式自动分组」：用户编写通达信公式，打开分组时根据公式
//    最新一期输出值是否 > 0 动态组成分组（结果可手动刷新）
//  - 所有配置写入 Documents/Favorites/favorites.json，启动时自动加载
//

import Foundation
import SwiftUI
import Combine

// MARK: - 分组类型

enum FavoritesGroupKind: String, Codable, Hashable {
    case manual     // 自定义：手动增删
    case formula    // 公式自动：公式选股结果
}

struct FavoritesGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: FavoritesGroupKind
    /// manual 分组：组内标的 metaID 有序列表（用户拖放顺序）
    var manualMetaIDs: [Int]
    /// formula 分组：通达信公式文本（保存用户原始输入，区分大小写转大写交给引擎）
    var formula: String?
    /// formula 分组最近一次刷新缓存的命中 metaID（便于表格先显示，用户点刷新再重算）
    var cachedMatches: [Int]?
    /// formula 分组上次刷新时间
    var updatedAt: Date?
    /// 是否显示在自选 Tab（用户可"隐藏"某分组）
    var isHidden: Bool

    static func manual(name: String) -> FavoritesGroup {
        FavoritesGroup(id: UUID(), name: name, kind: .manual,
                       manualMetaIDs: [], formula: nil,
                       cachedMatches: nil, updatedAt: nil, isHidden: false)
    }

    static func formula(name: String, formula: String) -> FavoritesGroup {
        FavoritesGroup(id: UUID(), name: name, kind: .formula,
                       manualMetaIDs: [], formula: formula,
                       cachedMatches: nil, updatedAt: nil, isHidden: false)
    }
}

// MARK: - 根配置（对应 JSON 文件结构）

private struct FavoritesRoot: Codable {
    var groups: [FavoritesGroup]
    var selectedGroupID: UUID?
    var schemaVersion: Int
}

// MARK: - Store

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    /// 分组列表（已按 group.index 排序）
    @Published var groups: [FavoritesGroup] = []

    /// 当前选中的分组
    @Published var selectedGroupID: UUID?

    /// 「全部」虚拟分组：所有 manual 分组的去重并集（不持久化，动态计算）
    var allGroup: FavoritesGroup {
        var ids: [Int] = []
        var seen: Set<Int> = []
        for g in groups where g.kind == .manual {
            for m in g.manualMetaIDs where !seen.contains(m) {
                seen.insert(m)
                ids.append(m)
            }
        }
        var g = FavoritesGroup.manual(name: "全部")
        g.manualMetaIDs = ids
        return g
    }

    private let fm = FileManager.default
    private let currentSchema = 1

    // MARK: - Lifecycle

    private init() {
        // 立即读档；档不存在则写入默认的"我的自选"分组
        if !loadFromDisk() {
            let def = FavoritesGroup.manual(name: "我的自选")
            groups = [def]
            selectedGroupID = def.id
            saveToDisk()
        }
    }

    // MARK: - 读档/存档

    private var fileURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Favorites", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("favorites.json")
    }

    @discardableResult
    private func loadFromDisk() -> Bool {
        let url = fileURL
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let root = try decoder.decode(FavoritesRoot.self, from: data)
            self.groups = root.groups.sorted { (a, b) -> Bool in
                // 保持原数组顺序（sorted 是稳定的）
                return true
            }
            // 保持原顺序（上面 sorted 不改变顺序，这里显式按原存储顺序）
            // （JSON 数组本身有顺序，decode 结果顺序已对）
            if let sel = root.selectedGroupID,
               groups.contains(where: { $0.id == sel }) {
                self.selectedGroupID = sel
            } else {
                self.selectedGroupID = groups.first?.id
            }
            return true
        } catch {
            DebugLogger.shared.log("[FavoritesStore] load failed \(error)")
            return false
        }
    }

    func saveToDisk() {
        let root = FavoritesRoot(groups: groups, selectedGroupID: selectedGroupID,
                                 schemaVersion: currentSchema)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(root)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DebugLogger.shared.log("[FavoritesStore] save failed \(error)")
        }
    }

    // MARK: - Group CRUD

    /// 添加一个新分组（默认末尾）
    @discardableResult
    func addGroup(_ group: FavoritesGroup) -> FavoritesGroup {
        groups.append(group)
        if selectedGroupID == nil { selectedGroupID = group.id }
        saveToDisk()
        return group
    }

    func removeGroup(id: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups.remove(at: idx)
        if selectedGroupID == id { selectedGroupID = groups.first?.id }
        saveToDisk()
    }

    func renameGroup(id: UUID, name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = name
        saveToDisk()
    }

    /// 更新 formula 分组的公式文本
    func updateFormula(id: UUID, formula: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        guard groups[idx].kind == .formula else { return }
        groups[idx].formula = formula
        groups[idx].cachedMatches = nil
        saveToDisk()
    }

    func moveGroup(fromOffsets: IndexSet, toOffset: Int) {
        groups.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveToDisk()
    }

    func toggleHidden(id: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].isHidden.toggle()
        saveToDisk()
    }

    var visibleGroups: [FavoritesGroup] {
        groups.filter { !$0.isHidden }
    }

    // MARK: - Manual 分组：标的 CRUD

    /// 是否任一 manual 分组已经包含此 metaID
    func isFavorited(_ metaID: Int) -> Bool {
        groups.contains { g in g.kind == .manual && g.manualMetaIDs.contains(metaID) }
    }

    /// 属于哪些 manual 分组（返回分组 ID）
    func memberships(of metaID: Int) -> [UUID] {
        groups.compactMap { g in
            guard g.kind == .manual else { return nil }
            return g.manualMetaIDs.contains(metaID) ? g.id : nil
        }
    }

    /// 加入某 manual 分组（若存在则忽略重复）
    func addToGroup(id: UUID, metaID: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        guard groups[idx].kind == .manual else { return }
        if !groups[idx].manualMetaIDs.contains(metaID) {
            groups[idx].manualMetaIDs.append(metaID)
            saveToDisk()
        }
    }

    /// 从某分组移除
    func removeFromGroup(id: UUID, metaID: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        guard groups[idx].kind == .manual else { return }
        groups[idx].manualMetaIDs.removeAll { $0 == metaID }
        saveToDisk()
    }

    /// 切换：若在则从全部 manual 分组移除（取消自选）；若不在则加入第一个 manual 分组
    func toggleFavorite(_ metaID: Int) {
        if isFavorited(metaID) {
            for g in groups where g.kind == .manual {
                removeFromGroup(id: g.id, metaID: metaID)
            }
        } else {
            guard let first = groups.first(where: { $0.kind == .manual }) else {
                let g = addGroup(.manual(name: "我的自选"))
                addToGroup(id: g.id, metaID: metaID)
                return
            }
            addToGroup(id: first.id, metaID: metaID)
        }
    }

    /// manual 分组内拖动排序列表
    func moveInGroup(id: UUID, fromOffsets: IndexSet, toOffset: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        guard groups[idx].kind == .manual else { return }
        groups[idx].manualMetaIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveToDisk()
    }

    // MARK: - Manual 分组：一键获取 metaID -> MetaItem 列表（从 DatabaseManager metaList 查找）

    func resolveMetaItems(groupID: UUID, allMeta: [MetaItem]) -> [MetaItem] {
        guard let g = groups.first(where: { $0.id == groupID }) else { return [] }
        switch g.kind {
        case .manual:
            var lookup: [Int: MetaItem] = [:]
            for m in allMeta { lookup[m.id] = m }
            return g.manualMetaIDs.compactMap { lookup[$0] }
        case .formula:
            guard let matches = g.cachedMatches else { return [] }
            var lookup: [Int: MetaItem] = [:]
            for m in allMeta { lookup[m.id] = m }
            return matches.compactMap { lookup[$0] }
        }
    }

    func selectedGroup(allMeta: [MetaItem]) -> (group: FavoritesGroup, items: [MetaItem])? {
        let id = selectedGroupID ?? groups.first?.id
        guard let gid = id, let g = groups.first(where: { $0.id == gid }) else { return nil }
        return (g, resolveMetaItems(groupID: gid, allMeta: allMeta))
    }

    // MARK: - Formula 分组：刷新缓存

    /// 对指定 formula 分组，按"候选池"逐只跑公式，更新 cachedMatches。
    ///
    /// - Parameters:
    ///   - id: formula 分组 ID
    ///   - candidates: 候选 meta 列表（沪深主板，全市场，或其他限制范围）
    ///   - cache: 行缓存，提供 matchFormula 能力
    ///   - progress: 每处理一只回传 (done, total)，可在 UI 上显示进度
    ///   - completion: 全部完成回调
    func refreshFormulaGroup(id: UUID,
                             candidates: [MetaItem],
                             cache: MarketRowCache,
                             progress: @escaping (Int, Int) -> Void = { _, _ in },
                             completion: @escaping (Int) -> Void) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { completion(0); return }
        guard groups[idx].kind == .formula else { completion(0); return }
        guard let formula = groups[idx].formula, !formula.isEmpty else { completion(0); return }

        let groupIdx = idx
        let total = candidates.count
        guard total > 0 else {
            groups[groupIdx].cachedMatches = []
            groups[groupIdx].updatedAt = Date()
            saveToDisk()
            completion(0)
            return
        }

        // 先把 rows 批量取出来，让每行都触发 bars 预取
        let rows = cache.rows(for: candidates)
        var matched: [Int] = []
        let lock = NSLock()
        var done = 0
        let group = DispatchGroup()

        for (i, r) in rows.enumerated() {
            group.enter()
            // 分批：每 20 只后暂停一下（防止 computeQueue 爆炸）
            let deadline: DispatchTime = .now() + 0.0001 * Double(i)
            cache.computeQueue.asyncAfter(deadline: deadline) {
                cache.matchFormula(metaID: r.metaID, formulaRaw: formula) { ok in
                    if ok {
                        lock.lock()
                        matched.append(r.metaID)
                        lock.unlock()
                    }
                    lock.lock()
                    done += 1
                    let d = done
                    lock.unlock()
                    DispatchQueue.main.async { progress(d, total) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            // 保持候选顺序（与 candidates 一致，用户观感一致）
            let orderMap: [Int: Int] = Dictionary(
                uniqueKeysWithValues: candidates.enumerated().map { ($0.element.id, $0.offset) }
            )
            matched.sort { (orderMap[$0] ?? Int.max) < (orderMap[$1] ?? Int.max) }
            self.groups[groupIdx].cachedMatches = matched
            self.groups[groupIdx].updatedAt = Date()
            self.saveToDisk()
            completion(matched.count)
        }
    }

    /// 清空某 formula 分组缓存（用户改了公式 / 想要强制重算）
    func invalidateFormulaGroup(id: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        guard groups[idx].kind == .formula else { return }
        groups[idx].cachedMatches = nil
        saveToDisk()
    }
}
