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
    /// 旧档遗留的内嵌文本；新档只存 `formulaID` 引用（二者互斥）
    var formula: String?
    /// formula 分组：选股公式库条目 id，与内嵌 `formula` 互斥
    var formulaID: String?
    /// formula 分组最近一次刷新缓存的命中 metaID（便于表格先显示，用户点刷新再重算）
    var cachedMatches: [Int]?
    /// formula 分组上次刷新时间
    var updatedAt: Date?
    /// 是否显示在自选 Tab（用户可"隐藏"某分组）
    var isHidden: Bool

    static func manual(name: String) -> FavoritesGroup {
        FavoritesGroup(id: UUID(), name: name, kind: .manual,
                       manualMetaIDs: [], formula: nil, formulaID: nil,
                       cachedMatches: nil, updatedAt: nil, isHidden: false)
    }

    static func formula(name: String, formula: String) -> FavoritesGroup {
        FavoritesGroup(id: UUID(), name: name, kind: .formula,
                       manualMetaIDs: [], formula: formula, formulaID: nil,
                       cachedMatches: nil, updatedAt: nil, isHidden: false)
    }

    /// 引用式构造：只存选股公式库条目 id（新档使用）
    static func formula(name: String, formulaID: String?) -> FavoritesGroup {
        FavoritesGroup(id: UUID(), name: name, kind: .formula,
                       manualMetaIDs: [], formula: nil, formulaID: formulaID,
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

    /// 「全部」虚拟分组的固定 id：它不是 groups 里的实体，但 Tab 选中、计数、取数都要靠
    /// 一个稳定标识反查。若用 `UUID()` 每次新建，`resolveMetaItems` 永远查不到 → 计数恒为 0、
    /// 内容恒为空、选中态与重启后的选中都会失配
    static let allGroupID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

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
        return FavoritesGroup(id: Self.allGroupID, name: "全部", kind: .manual,
                              manualMetaIDs: ids, formula: nil, formulaID: nil,
                              cachedMatches: nil, updatedAt: nil, isHidden: false)
    }

    private let fm = FileManager.default
    /// 档结构版本：2 起公式分组只存 `formulaID` 引用（1 为内嵌 formula 文本的旧档）
    private let currentSchema = 2
    /// 读到的档版本低于 `currentSchema` 时为 true：即使没有任何分组改动也要回写一次
    private var needsSchemaRewrite = false

    // MARK: - Lifecycle

    private init() {
        // 立即读档；档不存在则写入默认的"我的自选"分组
        if loadFromDisk() {
            // 迁移发生在读档后、写档前，因此只写一次
            let migrated = migrateFormulaGroupsIfNeeded()
            // 读到旧版本档即无条件回写一次，把 schemaVersion 落到 2（即便是无需迁移的手动分组档）
            if migrated || needsSchemaRewrite { saveToDisk() }
        } else {
            let def = FavoritesGroup.manual(name: "我的自选")
            groups = [def]
            selectedGroupID = def.id
            saveToDisk()
        }
    }

    // MARK: - 迁移

    /// 幂等迁移：把旧档中「内嵌公式文本」的公式分组改为「引用选股公式库条目」。
    ///
    /// 迁移只在读档成功后执行一次（读档后、写档前）：`formulaID != nil` 的分组直接
    /// 跳过，已迁移的档（schemaVersion 2）不会再重复导入。
    /// 返回值表示本次迁移是否对分组数据做了改动（有改动则由调用方统一写盘一次）。
    @discardableResult
    private func migrateFormulaGroupsIfNeeded() -> Bool {
        var changed = false
        for i in groups.indices where groups[i].kind == .formula {
            // 已有引用 → 已完成迁移，跳过
            guard groups[i].formulaID == nil else { continue }
            guard let text = groups[i].formula else { continue }

            if text.isEmpty {
                // 内嵌文本为空：不建库条目，只清字段，表现为「未选择公式」
                groups[i].formula = nil
                changed = true
                continue
            }

            // 以分组名在选股公式库建条目（重名自动加序号后缀）
            if let newID = FormulaLibraryStore.shared.importPicker(name: groups[i].name,
                                                                   formula: text) {
                groups[i].formulaID = newID
                groups[i].formula = nil
                groups[i].cachedMatches = nil
                changed = true
            } else {
                // 导入失败：宁可保留旧文本也不要丢公式（下次启动会再尝试）
                DebugLogger.shared.log("[FavoritesStore] migrate formula group failed: \(groups[i].name)")
            }
        }
        // 迁移结果交给调用方统一写盘（把 schemaVersion 写成 2，只写一次）
        return changed
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
            // 旧版本档（schemaVersion < 当前版本）打上回写标记：由 init 读档后无条件写回一次
            if root.schemaVersion < currentSchema { needsSchemaRewrite = true }
            self.groups = root.groups.sorted { (a, b) -> Bool in
                // 保持原数组顺序（sorted 是稳定的）
                return true
            }
            // 保持原顺序（上面 sorted 不改变顺序，这里显式按原存储顺序）
            // （JSON 数组本身有顺序，decode 结果顺序已对）
            if let sel = root.selectedGroupID,
               sel == Self.allGroupID || groups.contains(where: { $0.id == sel }) {
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

    // MARK: - Formula 分组：选股公式引用（自选页 / 公式管理页展示引用状态）

    /// 分组的选股公式引用状态：nil 表示正常；否则返回可直接展示的中文提示
    func formulaIssue(groupID: UUID) -> String? {
        guard let g = groups.first(where: { $0.id == groupID }) else { return nil }
        guard g.kind == .formula, let fid = g.formulaID else { return nil }
        // 引用的选股公式库条目已不存在 → 提示重新选择
        return FormulaLibraryStore.shared.doc(kind: .picker, id: fid) == nil ? "公式已删除，请重新选择" : nil
    }

    /// 分组引用到的选股公式名称（取不到返回 nil）
    func formulaName(groupID: UUID) -> String? {
        guard let g = groups.first(where: { $0.id == groupID }) else { return nil }
        return FormulaLibraryStore.shared.pickerName(id: g.formulaID)
    }

    /// 绑定 / 解绑公式引用（清空旧内嵌文本与旧结果）
    func bindFormula(groupID: UUID, formulaID: String?) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard groups[idx].kind == .formula else { return }
        groups[idx].formulaID = formulaID
        groups[idx].formula = nil
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
        // 「全部」虚拟分组不在 groups 里：直接取所有 manual 分组的去重并集
        let g = groupID == Self.allGroupID ? allGroup : groups.first(where: { $0.id == groupID })
        guard let g = g else { return [] }
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

        // 取公式文本：优先引用选股公式库条目；取不到再回退读旧的内嵌文本（迁移未完成的兜底）
        var resolved = FormulaLibraryStore.shared.formulaText(id: groups[idx].formulaID)
        if resolved == nil { resolved = groups[idx].formula }

        let groupIdx = idx
        guard let formula = resolved, !formula.isEmpty else {
            // 公式不可用（引用为空 / 引用已被删除 / 内嵌文本为空）：置空缓存并回调 0，不崩溃
            groups[groupIdx].cachedMatches = []
            groups[groupIdx].updatedAt = Date()
            saveToDisk()
            completion(0)
            return
        }

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
