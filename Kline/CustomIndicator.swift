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
        save()
    }

    func update(_ indicator: CustomIndicator) {
        guard let idx = indicators.firstIndex(where: { $0.id == indicator.id }) else { return }
        indicators[idx] = indicator
        save()
    }

    func delete(_ id: UUID) {
        indicators.removeAll { $0.id == id }
        save()
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