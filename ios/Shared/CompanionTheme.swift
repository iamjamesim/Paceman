import Foundation
import SwiftUI

struct CompanionTheme: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var background: String
    var foreground: String
    var accent: String
    var monospaced: Bool
    var surface: String? = nil

    // Retained as a protocol fixture for older watch profile tests.
    static let solitude = Self(id: "solitude", name: "Solitude", background: "101315", foreground: "CACCCC", accent: "A4B4BB", monospaced: true)
    var canvas: Color { Color(companionHex: background, fallback: "F5F4F0") }
    var ink: Color { Color(companionHex: foreground, fallback: "242823") }
    var tint: Color { Color(companionHex: accent, fallback: "456554") }
    var panel: Color { Color(companionHex: surface ?? background, fallback: background) }
    var secondaryInk: Color { ink.opacity(secondaryOpacity) }
    /// Keep small secondary labels legible on both the canvas and the list/card
    /// surface. Fixed opacity made light Ayu and Latte labels too faint.
    var secondaryOpacity: Double {
        guard let foreground = Self.hex(foreground),
              let canvas = Self.hex(background),
              let panel = Self.hex(surface ?? background) else { return 1 }
        for percent in 50...100 {
            let alpha = Double(percent) / 100
            if [canvas, panel].allSatisfy({ Self.contrast(foreground, $0, alpha: alpha) >= 4.5 }) {
                return alpha
            }
        }
        return 1
    }
    private static func contrast(_ foreground: UInt64, _ background: UInt64, alpha: Double) -> Double {
        func components(_ value: UInt64) -> [Double] {
            [16, 8, 0].map { Double((value >> $0) & 255) / 255 }
        }
        func luminance(_ values: [Double]) -> Double {
            zip(values, [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
                let channel = pair.0 <= 0.04045 ? pair.0 / 12.92 : pow((pair.0 + 0.055) / 1.055, 2.4)
                return sum + channel * pair.1
            }
        }
        let back = components(background)
        let blended = zip(components(foreground), back).map { $0.0 * alpha + $0.1 * (1 - alpha) }
        let a = luminance(blended), b = luminance(back)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    var dark: Bool {
        let n = Self.hex(background) ?? 0xF5F4F0
        return (Double((n >> 16) & 255) * 0.2126 + Double((n >> 8) & 255) * 0.7152 + Double(n & 255) * 0.0722) < 128
    }
    func font(_ size: CGFloat, emphasis: Bool = false) -> Font {
        monospaced ? .custom(emphasis ? "JetBrainsMono-SemiBold" : "JetBrainsMono-Regular", size: size, relativeTo: .body)
            : .system(size: size, weight: emphasis ? .semibold : .regular, design: .default)
    }
    static func hex(_ value: String) -> UInt64? {
        let s = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return UInt64(s, radix: 16)
    }
    var valid: Bool { [background, foreground, accent].allSatisfy { Self.hex($0) != nil } && !name.isEmpty && name.count <= 60 }
}

extension Color {
    init(companionHex value: String, fallback: String = "242823") {
        let n = CompanionTheme.hex(value) ?? CompanionTheme.hex(fallback) ?? 0
        self.init(.sRGB, red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, opacity: 1)
    }
}

/// Stable family IDs belong to the phone. Source-provided `appearance` remains
/// decodable for older snapshots, but never selects the user's palette.
enum ThemeFamily: String, CaseIterable, Identifiable {
    case paceman, monochrome, ayu, sakuraMochi = "sakura-mochi", miasma, catppuccin

    var id: String { rawValue }
    var name: String {
        switch self {
        case .paceman: "Paceman"
        case .monochrome: "Monochrome"
        case .ayu: "Ayu"
        case .sakuraMochi: "Sakura Mochi"
        case .miasma: "Miasma"
        case .catppuccin: "Catppuccin"
        }
    }
    var supportsLight: Bool { self != .sakuraMochi && self != .miasma }

    private func colors(_ background: String, _ surface: String, _ foreground: String, _ accent: String) -> CompanionTheme {
        CompanionTheme(id: rawValue, name: name, background: background,
                       foreground: foreground, accent: accent, monospaced: false, surface: surface)
    }

    func phone(dark: Bool) -> CompanionTheme {
        switch self {
        case .paceman:
            dark ? colors("151C18", "202A23", "E9EDE7", "A8D2B6")
                 : colors("F5F4F0", "EAEDE7", "242823", "456554")
        case .monochrome:
            dark ? colors("111111", "222222", "F1F1F1", "F1F1F1")
                 : colors("F4F4F4", "E6E6E6", "191919", "191919")
        case .ayu:
            dark ? colors("1F2430", "282E3B", "CCCAC2", "FFCC66")
                 : colors("F8F9FA", "EBEEF0", "5C6166", "8A5700")
        case .sakuraMochi: colors("0B0D11", "201620", "F0B7CA", "FC0594")
        case .miasma: colors("222222", "242D1D", "C2C2B0", "D7C483")
        case .catppuccin:
            dark ? colors("1E1E2E", "313244", "CDD6F4", "CBA6F7")
                 : colors("EFF1F5", "E6E9EF", "4C4F69", "8839EF")
        }
    }

    var glance: CompanionTheme {
        switch self {
        case .paceman: colors("0A100C", "0A100C", "E9EDE7", "A8D2B6")
        case .monochrome: colors("050505", "050505", "F1F1F1", "F1F1F1")
        case .ayu: colors("181C26", "181C26", "CCCAC2", "FFCC66")
        case .sakuraMochi: phone(dark: true)
        case .miasma: phone(dark: true)
        case .catppuccin: colors("11111B", "11111B", "CDD6F4", "CBA6F7")
        }
    }

    var activity: MonitoringPalette {
        let base = glance
        switch self {
        case .paceman: return MonitoringPalette(base: base, muted: "A5B2A8", input: "D6B86D", working: "A8D2B6", finished: "8C9B90")
        case .monochrome: return MonitoringPalette(base: base, muted: "B9B9B9", input: "F1F1F1", working: "C5C5C5", finished: "8E8E8E")
        case .ayu: return MonitoringPalette(base: base, muted: "AAAAB0", input: "FFCC66", working: "80BFFF", finished: "9098A7")
        case .sakuraMochi: return MonitoringPalette(base: base, muted: "BD9AA9", input: "FC0594", working: "50DE89", finished: "8E8490")
        case .miasma: return MonitoringPalette(base: base, muted: "A7AA98", input: "D7C483", working: "A6B66E", finished: "858B78")
        case .catppuccin: return MonitoringPalette(base: base, muted: "A6ADC8", input: "CBA6F7", working: "89B4FA", finished: "8992AC")
        }
    }
}

enum ThemePreference {
    static let appGroup = "group.com.apselabs.agentcompanion.prototype"
    static let key = "selected-theme-family"
    static var sharedDefaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    static func load(from defaults: UserDefaults) -> ThemeFamily {
        ThemeFamily(rawValue: defaults.string(forKey: key) ?? "") ?? .paceman
    }
    static var current: ThemeFamily { load(from: sharedDefaults) }
    static func save(_ family: ThemeFamily) { sharedDefaults.set(family.rawValue, forKey: key) }
}

struct MonitoringPalette {
    let background: Color
    let ink: Color
    let accent: Color
    let muted: Color
    let input: Color
    let working: Color
    let finished: Color

    init(base: CompanionTheme, muted: String, input: String, working: String, finished: String) {
        background = base.canvas
        ink = base.ink
        accent = base.tint
        self.muted = Color(companionHex: muted)
        self.input = Color(companionHex: input)
        self.working = Color(companionHex: working)
        self.finished = Color(companionHex: finished)
    }

    func robotColor(for state: String) -> Color {
        state == "finished" ? accent.opacity(0.75) : accent
    }
}
