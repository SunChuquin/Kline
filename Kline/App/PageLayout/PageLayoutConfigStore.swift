//
//  PageLayoutConfigStore.swift
//  Kline
//
//  通用 JSON 布局引擎 - 配置仓库（与具体页面无关）。
//
//  职责：「读 + 写」。读为首启种入与沙盒变更即时生效；写供布局编辑器保存 / 恢复默认。
//
//  沙盒路径：Documents/Layouts/<page>.json（写入前自动创建 Layouts 目录）。
//  回退链（不变）：
//    1) 沙盒 JSON 可读且解码成功 → 直接用；
//    2) 沙盒缺失 / 解码失败 → 取「已注册的内置默认文本」解码，成功则原样写回沙盒并用它；
//    3) 内置默认也未注册 / 也解码失败 → 该页配置置为 nil（首页 home = nil），由页面退硬编码布局视图。
//  全程 try? / do-catch 兜底，任何环节失败只降级、不崩溃。
//  同值不写（不变）：缓存各页「上次生效的原始 JSON 文本」，文本未变时不重新赋值 @Published，避免同值发布。
//  写接口：`save` / `resetToBuiltIn` 会写沙盒并 `apply`，且**同步 `lastModDates`**（记下写入后的文件 mtime），
//  避免下次 onAppear 的 `reloadIfChanged` 因 mtime 变化再做一次多余重解码。
//  编解码统一走 `PageLayoutCodec`（本文件不再自带 JSONDecoder）。
//

import Foundation
import Combine

@MainActor
final class PageLayoutConfigStore: ObservableObject {
    static let shared = PageLayoutConfigStore()
    static let homePage = "home"

    /// 首页配置；nil 表示不可用（该页退硬编码布局视图）
    @Published private(set) var home: PageLayoutFile?

    /// 各页已解码的配置（nil 不在字典里，即不可用）
    private var files: [String: PageLayoutFile] = [:]
    /// 各页已注册的内置默认 JSON 文本
    private var builtInDefaults: [String: String] = [:]
    /// 各页「上次生效的原始 JSON 文本」，用于同值不写
    private var lastTexts: [String: String] = [:]
    /// 各页沙盒文件上次记录的修改时间
    private var lastModDates: [String: Date] = [:]

    private let fm = FileManager.default

    /// 不预加载任何页面：等 registerBuiltInDefaults 之后由 reloadIfChanged 触发
    private init() {}

    // MARK: - 注册内置默认

    /// 注册某页面的内置默认配置（幂等；由各页面模块自行提供，本类不引用任何页面类型）
    func registerBuiltInDefaults(page: String, json: String) {
        builtInDefaults[page] = json
    }

    // MARK: - 取用

    /// 取某页某档位定义：id 缺失 → 回退配置里的 default → 都没有 → nil
    func layout(id: String, for page: String) -> PageLayoutDefinition? {
        guard let file = files[page] else { return nil }
        if let definition = file.layouts[id] { return definition }
        if let fallbackID = file.defaultLayoutID, let fallback = file.layouts[fallbackID] {
            return fallback
        }
        return nil
    }

    /// 内部已解码的当前配置（供编辑器取草稿底本）；不可用时返回 nil
    func currentFile(page: String) -> PageLayoutFile? {
        files[page]
    }

    /// 某页已注册的内置默认 JSON 文本；未注册返回 nil
    func builtInText(page: String) -> String? {
        builtInDefaults[page]
    }

    // MARK: - 写接口

    /// 保存一份配置：编码 → 写沙盒 → 更新内存并发布（同值不写）→ 同步 mtime。
    /// 编码或写入失败返回 false（不崩溃）
    @discardableResult
    func save(_ file: PageLayoutFile, page: String) -> Bool {
        guard let text = PageLayoutCodec.encode(file) else { return false }
        let url = fileURL(for: page)
        guard write(text: text, to: url) else { return false }
        apply(page: page, file: file, text: text)
        syncModDate(page: page, url: url)
        return true
    }

    /// 恢复某页内置默认：内置默认文本写回沙盒并生效，同步 mtime。
    /// 未注册内置默认 / 内置默认解码失败 / 写入失败均返回 false（不崩溃）
    @discardableResult
    func resetToBuiltIn(page: String) -> Bool {
        guard let builtIn = builtInDefaults[page] else {
            print("[PageLayoutConfigStore] 未注册内置默认，无法恢复：page=\(page)")
            return false
        }
        guard let file = PageLayoutCodec.decode(builtIn) else {
            print("[PageLayoutConfigStore] 内置默认配置解码失败，无法恢复：page=\(page)")
            return false
        }
        let url = fileURL(for: page)
        guard write(text: builtIn, to: url) else { return false }
        apply(page: page, file: file, text: builtIn)
        syncModDate(page: page, url: url)
        return true
    }

    // MARK: - 重载

    /// 按文件修改时间判断是否需要重解码（页面 onAppear 调用）；沙盒文件不存在时也走一次完整 reload（首启种入）
    func reloadIfChanged(page: String) {
        let url = fileURL(for: page)
        let modDate = fileModificationDate(at: url)

        // 沙盒文件缺失（含首启）：必须走一次完整 reload，以触发内置默认种入
        guard let modDate = modDate else {
            reload(page: page)
            lastModDates.removeValue(forKey: page)
            return
        }

        // mtime 与文本都没变 → 直接返回，不重解码
        let currentText = sandboxText(at: url)
        if lastModDates[page] == modDate, lastTexts[page] == currentText {
            return
        }

        reload(page: page)
        lastModDates[page] = modDate
    }

    /// 完整重载：沙盒 → 内置默认（并种回沙盒）→ 不可用（nil）
    private func reload(page: String) {
        let url = fileURL(for: page)

        // 1) 优先沙盒
        if let text = sandboxText(at: url), let file = PageLayoutCodec.decode(text) {
            apply(page: page, file: file, text: text)
            return
        }

        // 2) 回退内置默认，并原样种回沙盒
        if let builtIn = builtInDefaults[page] {
            if let file = PageLayoutCodec.decode(builtIn) {
                write(text: builtIn, to: url)
                apply(page: page, file: file, text: builtIn)
                return
            }
            print("[PageLayoutConfigStore] 内置默认配置解码失败：page=\(page)")
        }

        // 3) 不可用 → 该页退硬编码布局视图
        apply(page: page, file: nil, text: nil)
        print("[PageLayoutConfigStore] 页面配置不可用，退硬编码布局：page=\(page)")
    }

    /// 应用结果（同值不写：文本未变时不重新赋值 @Published）
    private func apply(page: String, file: PageLayoutFile?, text: String?) {
        files[page] = file

        let changed = (lastTexts[page] != text)
        lastTexts[page] = text

        guard page == Self.homePage, changed else { return }
        home = file
    }

    // MARK: - 沙盒读写

    private func fileURL(for page: String) -> URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Layouts", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("\(page).json")
    }

    private func fileModificationDate(at url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func sandboxText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写入沙盒（原子写）；成功返回 true
    @discardableResult
    private func write(text: String, to url: URL) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[PageLayoutConfigStore] 配置写入沙盒失败：\(url.lastPathComponent) \(error)")
            return false
        }
    }

    /// 同步某页的沙盒文件 mtime（写入后调用）；取不到则清除记录
    private func syncModDate(page: String, url: URL) {
        if let modDate = fileModificationDate(at: url) {
            lastModDates[page] = modDate
        } else {
            lastModDates.removeValue(forKey: page)
        }
    }
}