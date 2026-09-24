//
//  WidgetParamCandidateProvider.swift
//  Kline
//
// 布局编辑器「动态候选」解析器：把有序多选 / 动态单选参数声明的候选源（WidgetParamCandidates）
// 在运行时解析成 ParamCandidate 列表。候选全部来自既有单例，不新增数据源：
// - entries：HomeEntryKind 全量（首页快捷入口）
// - indices：DatabaseManager.metaList 中的「沪深京指数」（约 119 只，按名称排序）
// - favoritesGroups：「全部」虚拟分组 + FavoritesStore.groups
// - simAccounts：「全部账户」+ SimStore.accounts
//
// 约定：
// - 候选首项为「默认项」（全部 / 全部账户），其 id 为对应固定虚拟 id 的 uuidString；
// - 只输出基础类型（id/title/subtitle/iconName），不依赖 SwiftUI，检查器直接据此渲染；
// - 调用方在主线程（@MainActor）：数据单例均为主线程发布。
//

import Foundation

@MainActor
enum WidgetParamCandidateProvider {

    /// 沪深京指数的 meta.type 口径（与 HomePageModel / MarketRowCache 一致）
    private static let indexType = "沪深京指数"

    /// 解析某候选源的全部候选（有序；首项即默认项）
    static func candidates(_ source: WidgetParamCandidates) -> [ParamCandidate] {
        switch source {
        case .entries:
            return HomeEntryKind.allCases.map {
                ParamCandidate(id: $0.rawValue, title: $0.title,
                               subtitle: $0.subtitle, iconName: $0.icon)
            }
        case .indices:
            return DatabaseManager.shared.metaList
                .lazy
                .filter { $0.type == indexType }
                .sorted { $0.name < $1.name }
                .map { ParamCandidate(id: String($0.id), title: $0.name, subtitle: $0.displayCode) }
        case .favoritesGroups:
            let fav = FavoritesStore.shared
            var result = [
                ParamCandidate(id: FavoritesStore.allGroupID.uuidString,
                               title: fav.allGroup.name,
                               subtitle: "所有手动分组合并")
            ]
            result.append(contentsOf: fav.groups.map { group in
                ParamCandidate(id: group.id.uuidString,
                               title: group.name,
                               subtitle: group.kind == .formula ? "公式分组" : "手动分组")
            })
            return result
        case .simAccounts:
            let sim = SimStore.shared
            var result = [
                ParamCandidate(id: SimStore.allAccountID.uuidString,
                               title: "全部账户",
                               subtitle: "汇总所有账户")
            ]
            result.append(contentsOf: sim.accounts.map { account in
                ParamCandidate(id: account.id.uuidString,
                               title: account.name,
                               subtitle: account.isArchived ? "已归档" : nil)
            })
            return result
        }
    }

    /// 候选源的默认项标题（动态单选「缺省」行展示用）
    static func defaultTitle(_ source: WidgetParamCandidates) -> String {
        switch source {
        case .entries: return "全部入口"
        case .indices: return "默认（前 4 只指数）"
        case .favoritesGroups: return "全部"
        case .simAccounts: return "全部账户"
        }
    }

    /// 缺省（键未写）时的生效顺序——必须与渲染侧回落口径一致：
    /// - entries：全部入口按枚举声明顺序；
    /// - indices：库顺序前 4 只「沪深京指数」（对齐 HomePageModel.refreshIndexQuotes，不按名称排序）；
    /// - groups / accounts：首项（全部虚拟分组 / 全部账户，这两个源只给动态单选用）。
    static func defaultOrder(for source: WidgetParamCandidates) -> [String] {
        switch source {
        case .entries:
            return HomeEntryKind.allCases.map(\.rawValue)
        case .indices:
            return Array(DatabaseManager.shared.metaList
                .lazy
                .filter { $0.type == indexType }
                .prefix(4)
                .map { String($0.id) })
        case .favoritesGroups:
            return [FavoritesStore.allGroupID.uuidString]
        case .simAccounts:
            return [SimStore.allAccountID.uuidString]
        }
    }
}
