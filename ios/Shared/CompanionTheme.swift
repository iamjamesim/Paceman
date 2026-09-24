import Foundation
import SwiftUI

struct CompanionTheme: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var background: String
    var foreground: String
    var accent: String
    var monospaced: Bool

    static let companion = Self(id: "companion", name: "Paceman", background: "F5F4F0", foreground: "242823", accent: "456554", monospaced: false)
    static let solitude = Self(id: "solitude", name: "Solitude", background: "101315", foreground: "CACCCC", accent: "A4B4BB", monospaced: true)
    static let rose = Self(id: "rose", name: "Rosé Pine", background: "191724", foreground: "E0DEF4", accent: "EBBCBA", monospaced: true)
    static let presets = [companion, solitude, rose]
    var canvas: Color { Color(companionHex: background, fallback: "F5F4F0") }
    var ink: Color { Color(companionHex: foreground, fallback: "242823") }
    var tint: Color { Color(companionHex: accent, fallback: "456554") }
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

/// A fixed watch-face palette for ActivityKit. The Lock Screen uses a matte
/// surface; the Island stays system black. Warm ink and state lights echo the
/// watch without making each computer's source appearance a separate theme.
enum MonitoringPalette {
    static let background = Color(companionHex: "121212")
    static let ink = Color(companionHex: "E7E3D8")
    static let muted = Color(companionHex: "A8ADA7")
    static let input = Color(companionHex: "DBBC7F")
    static let working = Color(companionHex: "A7C080")
    static let finished = Color(companionHex: "8F9892")

    static func robotColor(for state: String) -> Color {
        switch state {
        case "needs_input": input
        case "working": working
        default: finished
        }
    }
}
