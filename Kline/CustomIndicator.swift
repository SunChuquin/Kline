//
//  CustomIndicator.swift
//  Kline
//
//  用户自定义指标模型与持久化存储（UserDefaults）。
//
//  Created by 孙楚昆 on 2026/8/16.
//

import SwiftUI
import Combine

/// 公式指标作用域：主图叠加 / 副图
enum IndicatorScope: String, Codable, CaseIterable, Identifiable {
    case main = "主图指标"
    case sub = "副图指标"
    var id: String { rawValue }
}

/// 用户自定义的主图叠加指标
struct CustomIndicator: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var formula: String
    /// 作用域（主图或副图）
    var scope: IndicatorScope = .sub
    /// 线条颜色（十六进制字符串，如 "1E88E5"）
    var colorHex: String = "1E88E5"
    /// 适用范围：该自定义指标可用的周期。nil = 全周期（所有周期都可用）。
    /// 选中周期决定该指标会被落地为哪些周期目录里的 USER_<名称>.tdx。
    var applicablePeriods: [KlinePeriod]?

    var color: Color {
        Color(hex: colorHex) ?? .blue
    }
}

/// 自定义指标仓库：负责增删改查与 UserDefaults 持久化
final class CustomIndicatorStore: ObservableObject {
    static let shared = CustomIndicatorStore()

    @Published var indicators: [CustomIndicator] = []

    private let storageKey = "custom_indicators_v1"

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CustomIndicator].self, from: data) else {
            indicators = []
            return
        }
        indicators = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(indicators) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func add(_ indicator: CustomIndicator) {
        indicators.append(indicator)
        materializeTDX(indicator)
        save()
    }

    func update(_ indicator: CustomIndicator) {
        guard let idx = indicators.firstIndex(where: { $0.id == indicator.id }) else { return }
        let old = indicators[idx]
        // 名称可能变了：先移除旧名称在所有周期的 USER_*.tdx，再按新适用范围落地
        dematerializeTDX(old)
        indicators[idx] = indicator
        materializeTDX(indicator)
        save()
    }

    func delete(_ id: UUID) {
        guard let ind = indicators.first(where: { $0.id == id }) else { return }
        dematerializeTDX(ind)
        indicators.removeAll { $0.id == id }
        save()
    }

    // MARK: - 沙盒 .tdx 落地（USER_<名称>.tdx）

    /// 某自定义指标适用的周期（nil = 全周期）
    static func applicablePeriods(of ind: CustomIndicator) -> [KlinePeriod] {
        ind.applicablePeriods ?? KlinePeriod.allCases
    }

    /// 该自定义指标可能已经以旧名称落地过：删除旧名称所有周期的文件
    private func dematerializeTDX(_ ind: CustomIndicator) {
        let fileNameBase = "USER_" + Self.sanitized(ind.name)
        let fm = FileManager.default
        for period in KlinePeriod.allCases {
            let path = SystemIndicatorStore.writableDir(for: period) + "/\(fileNameBase).tdx"
            if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
        }
    }

    /// 按适用范围把该自定义指标写为各周期目录里的 USER_<名称>.tdx；不适用周期则删除旧副本
    private func materializeTDX(_ ind: CustomIndicator) {
        let applicable = Set(Self.applicablePeriods(of: ind))
        let fileName = Self.tdxFileName(for: ind)
        let fm = FileManager.default
        let scopeStr = ind.scope == .main ? "main" : "sub"
        let content = "NAME=\(ind.name)\nSCOPE=\(scopeStr)\nFORMULA:\n\(ind.formula)"
        for period in KlinePeriod.allCases {
            let dir = SystemIndicatorStore.writableDir(for: period)
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/" + fileName
            if applicable.contains(period) {
                try? content.write(toFile: path, atomically: true, encoding: .utf8)
            } else if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
        // 周期文件变化后，重载所有周期定义，使图表能读到最新的 USER_*.tdx
        SystemIndicatorStore.shared.reloadAllPeriods()
    }

    /// 该自定义指标的沙盒文件名（隐式前缀 USER_ 区分自定义；界面显示仍用原名）
    static func tdxFileName(for ind: CustomIndicator) -> String {
        "USER_" + sanitized(ind.name)
    }

    /// 文件名安全化：仅保留字母数字、下划线、点、连字符与中文（防止非法文件名字符）
    static func sanitized(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. ")
        return String(s.unicodeScalars.compactMap { allowed.contains($0) ? Character($0) : nil })
    }
}

extension Color {
    /// 从 "#RRGGBB" 或 "RRGGBB" 十六进制字符串创建颜色
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return "1E88E5" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}