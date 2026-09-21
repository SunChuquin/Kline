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
//  - schema 3：分组内固顶（pinnedMetaIDs，纯显示层）+ 全局备注（notes，key = String(metaID)）
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
    /// schema 3：分组内固顶的 metaID（数组顺序 = 固顶顺序，可多只；纯显示层，
    /// 与 `cachedMatches` 无关，公式分组刷新选股后固顶保持）。
    /// 必须是可选：本结构没有自定义 `init(from:)`，非可选新增字段会让旧档 decode 失败 → 整档丢
    var pinnedMetaIDs: [Int]? = nil

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
    /// schema 3：全局备注，key = `String(metaID)`，顺序无关；nil / 缺字段 = 无备注。
    /// 禁止改成 `[Int: String]`：Swift 对非 String key 的字典会被 `JSONEncoder` 编码成交替数组
    var notes: [String: String]? = nil
}

// MARK: - Store

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    /// 分组列表（已按 group.index 排序）
    @Published var groups: [FavoritesGroup] = []

    /// 当前选中的分组
    @Published var selectedGroupID: UUID?

    /// schema 3：全局备注（同一标的在手动分组 / 公式分组 /「全部」/ 行情页内容一致）。
    /// key = `String(metaID)`；空 / 不存在的 key = 无备注（空串一律按删除处理，不存空串）
    @Published private(set) var notes: [String: String] = [:]

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
    /// 档结构版本：2 起公式分组只存 `formulaID` 引用（1 为内嵌 formula 文本的旧档）；
    /// 3 起新增「分组内固顶」与「全局备注」（二者都是可选字段，旧档解码即为 nil / 空）
    private let currentSchema = 3
    /// 读到的档版本低于 `currentSchema` 时为 true：即使没有任何分组改动也要回写一次
    private var needsSchemaRewrite = false

    // MARK: - Lifecycle

    private init() {
        // 立即读档；档不存在则写入默认的"我的自选"分组
        if loadFromDisk() {
            // 迁移发生在读档后、写档前，因此只写一次
            let migratedFormula = migrateFormulaGroupsIfNeeded()
            let migratedItemOps = migrateItemOpsIfNeeded()
            // 读到旧版本档即无条件回写一次，把 schemaVersion 落到 3（即便是无需迁移的手动分组档）
            if migratedFormula || migratedItemOps || needsSchemaRewrite { saveToDisk() }
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

    /// 幂等迁移（schema 3）：新增「分组内固顶」与「全局备注」两个可选字段。
    ///
    /// 二者都是可选字段：旧档里没有这两个 key，synthesized Codable 走 `decodeIfPresent`
    /// 得到 nil，读取侧一律按「无固顶 / 无备注」处理，因此这里不需要逐条补值 —— 只做两件事：
    /// 1) 固顶列表去重（只清理列表自身，**绝不触碰** `manualMetaIDs` / `cachedMatches`
    /// 的成员与顺序，也不按 `manualMetaIDs` 过滤固顶，否则公式分组的固顶会被误清）；
    /// 2) 回传本次是否有实际改动（是否需要把 schemaVersion 回写成 3，由调用方结合
    ///    `needsSchemaRewrite` 决定，口径与 `migrateFormulaGroupsIfNeeded` 一致）。
    @discardableResult
    private func migrateItemOpsIfNeeded() -> Bool {
        var changed = false
        for i in groups.indices {
            guard let pinned = groups[i].pinnedMetaIDs, !pinned.isEmpty else { continue }
            var seen = Set<Int>()
            let deduped = pinned.filter { seen.insert($0).inserted }
            if deduped != pinned {
                groups[i].pinnedMetaIDs = deduped
                changed = true
            }
        }
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
            // schema 3 全局备注（旧档无该字段 → 空）
            let loadedNotes = root.notes ?? [:]
            if notes != loadedNotes { notes = loadedNotes }
            return true
        } catch {
            DebugLogger.shared.log("[FavoritesStore] load failed \(error)")
            return false
        }
    }

    func saveToDisk() {
        // 写档前兜底：内存里若还残留旧结构（如绕过 init 的写入路径），先迁移再写；
        // 写出的 schemaVersion 恒为 currentSchema，即本次写入顺便把旧档升到 3
        _ = migrateItemOpsIfNeeded()
        let root = FavoritesRoot(groups: groups, selectedGroupID: selectedGroupID,
                                 schemaVersion: currentSchema,
                                 notes: notes.isEmpty ? nil : notes)
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

    // MARK: - 分组内固顶（纯显示层：手动分组与公式分组都可固顶）

    /// 是否已在该分组固顶。
    /// 「全部」是虚拟分组（没有实体、`groups` 里查不到），因此恒为 false。
    func isPinned(groupID: UUID, metaID: Int) -> Bool {
        guard groupID != Self.allGroupID,
              let g = groups.first(where: { $0.id == groupID }) else { return false }
        return (g.pinnedMetaIDs ?? []).contains(metaID)
    }

    /// 该分组的固顶顺序（数组顺序 = 展示顺序，可多只）；无固顶 / 虚拟分组返回空
    func pinnedIDs(groupID: UUID) -> [Int] {
        guard groupID != Self.allGroupID,
              let g = groups.first(where: { $0.id == groupID }) else { return [] }
        return g.pinnedMetaIDs ?? []
    }

    /// 固顶 / 取消固顶：固顶 = 追加到 `pinnedMetaIDs` 尾部（多只按加入顺序排列），
    /// 取消 = 移除该 id。
    ///
    /// 语义：固顶是纯显示层，与 `cachedMatches` 无关 —— 公式分组刷新选股后固顶依然保持；
    /// 「全部」虚拟分组没有实体，直接 no-op（与 addToGroup / removeFromGroup 的 guard 风格一致）。
    func togglePin(groupID: UUID, metaID: Int) {
        guard groupID != Self.allGroupID,
              let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var pinned = groups[idx].pinnedMetaIDs ?? []
        if let at = pinned.firstIndex(of: metaID) {
            pinned.remove(at: at)
        } else {
            pinned.append(metaID)
        }
        // 空列表归一化为 nil（JSON 里不写空数组）
        let next: [Int]? = pinned.isEmpty ? nil : pinned
        guard groups[idx].pinnedMetaIDs != next else { return }   // 同值不写
        groups[idx].pinnedMetaIDs = next
        saveToDisk()
    }

    // MARK: - 移到最前 / 移到最后（仅 manual 实体分组）

    /// 移到分组最前：只重排该分组的 `manualMetaIDs`（该 id 提到首位，其它成员相对顺序不变）
    func moveToFirst(groupID: UUID, metaID: Int) {
        reorderMember(groupID: groupID, metaID: metaID, toFront: true)
    }

    /// 移到分组最后：只重排该分组的 `manualMetaIDs`（该 id 挪到末位，其它成员相对顺序不变）
    func moveToLast(groupID: UUID, metaID: Int) {
        reorderMember(groupID: groupID, metaID: metaID, toFront: false)
    }

    /// 重排实现。
    ///
    /// 关键：只在 `manualMetaIDs` 上做「取出一只 → 插入首 / 末」的原地重排，
    /// **绝对不能**用 `resolveMetaItems` / `items()` 的 `compactMap` 结果整组覆写 ——
    /// `resolveMetaItems` 会丢掉不在 `db.metaList` 里的历史 metaID（停牌 / 退市 / 库未就绪），
    /// 整组覆写等于永久删除分组成员。
    ///
    /// 生效条件（不满足则静默 no-op）：非「全部」虚拟组（`allGroup` 的 id 是固定常量、
    /// 不在 `groups` 里）、且在 `groups` 中的实体分组必须是 `kind == .manual`
    /// （公式分组的顺序由公式结果决定，不接受手动定位）。
    private func reorderMember(groupID: UUID, metaID: Int, toFront: Bool) {
        guard groupID != Self.allGroupID else { return }
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard groups[idx].kind == .manual else { return }

        var ids = groups[idx].manualMetaIDs
        guard let at = ids.firstIndex(of: metaID) else { return }   // 不在组内：no-op
        let target = toFront ? 0 : ids.count - 1
        guard at != target else { return }                          // 已就位：同值不写
        ids.remove(at: at)
        ids.insert(metaID, at: toFront ? 0 : ids.count)
        groups[idx].manualMetaIDs = ids
        saveToDisk()
    }

    // MARK: - 全局备注（同一标的跨分组 / 跨页面共用一份）

    /// 备注 key：`String(metaID)`（禁用 `[Int: String]`，避免 JSONEncoder 编成交替数组）
    private static func noteKey(_ metaID: Int) -> String { String(metaID) }

    /// 读备注；未设置（或已被清空）返回 nil
    func note(for metaID: Int) -> String? {
        guard let text = notes[Self.noteKey(metaID)], !text.isEmpty else { return nil }
        return text
    }

    /// 写备注：传入空串（或去空白后为空）= 删除该 key（不存空串）；否则存入去首尾空白后的文本
    func setNote(metaID: Int, text: String) {
        let key = Self.noteKey(metaID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = notes
        if trimmed.isEmpty {
            guard next[key] != nil else { return }          // 同值不写
            next.removeValue(forKey: key)
        } else {
            guard next[key] != trimmed else { return }      // 同值不写
            next[key] = trimmed
        }
        notes = next
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
