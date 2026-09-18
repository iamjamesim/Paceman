import Foundation
import SwiftUI
import WidgetKit

struct CompanionTheme: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var background: String
    var foreground: String
    var accent: String
    var monospaced: Bool

    static let companion = Self(id: "companion", name: "Companion", background: "F5F4F0", foreground: "242823", accent: "456554", monospaced: false)
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

struct CompanionWidgetState: Codable, Equatable {
    var paired: Bool
    var sourceName: String
    var state: String
    var updatedAt: Date?
    var freshUntil: Date?
    var theme: CompanionTheme
    var synthetic: Bool
    var sessionCount: Int
    static let empty = Self(paired: false, sourceName: "Your computer", state: "idle", theme: .companion, synthetic: false, sessionCount: 0)
    static let sample = Self(paired: true, sourceName: "Omarchy", state: "needs_input", updatedAt: Date(), freshUntil: Date().addingTimeInterval(30), theme: .rose, synthetic: true, sessionCount: 3)
    var title: String { shortTitle }
    var shortTitle: String {
        guard paired else { return "Connect computer" }
        switch state { case "working": return "Working"; case "needs_input": return "Needs input"; case "finished": return "Finished"; case "idle": return "Idle"; default: return "Waiting for update" }
    }
    func isFresh(at date: Date) -> Bool { paired && freshUntil.map { date < $0 } == true }
}

enum CompanionSharedStore {
    static let group = "group.com.apselabs.agentcompanion.prototype"
    static let kind = "AgentCompanionActivity"
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var stateURL: URL? { container?.appendingPathComponent("activity.json") }
    static func load() -> CompanionWidgetState {
        guard let url = stateURL, let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(CompanionWidgetState.self, from: data), value.theme.valid else { return .empty }
        return value
    }
    @discardableResult static func save(_ value: CompanionWidgetState, reload: Bool) -> Bool {
        guard let url = stateURL, let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if reload { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
            return true
        } catch { return false }
    }
}

/// The same simple silhouette remains recognizable in full color and tinted widgets.
struct AgentMark: View {
    var state: String = "working"
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.22).stroke(lineWidth: w * 0.038).frame(width: w * 0.70, height: w * 0.56)
                HStack(spacing: w * 0.17) {
                    Capsule().frame(width: w * 0.055, height: state == "idle" ? w * 0.025 : w * 0.12)
                    Capsule().frame(width: w * 0.055, height: state == "idle" ? w * 0.025 : w * 0.12)
                }.offset(y: -w * 0.025)
                if state == "finished" {
                    Capsule().frame(width: w * 0.14, height: w * 0.025).offset(y: w * 0.12)
                }
                Capsule().frame(width: w * 0.035, height: w * 0.13).offset(y: -w * 0.34)
                Circle().frame(width: w * 0.09).offset(y: -w * 0.43)
                HStack { Capsule().frame(width: w * 0.045, height: w * 0.15); Spacer(); Capsule().frame(width: w * 0.045, height: w * 0.15) }.frame(width: w * 0.87)
            }.frame(width: w, height: g.size.height)
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}

struct ActivityWidgetFace: View {
    let state: CompanionWidgetState
    var compact = false
    var accented = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 5) {
                Image(systemName: "laptopcomputer").font(.system(size: 10, weight: .medium))
                Text(state.sourceName).font(state.theme.font(10, emphasis: true)).lineLimit(1)
                Spacer(minLength: 0)
                if !compact { Text("COMPANION").font(.system(size: 8, weight: .semibold)).tracking(1.5).opacity(0.55) }
            }.opacity(0.7)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(compact ? state.shortTitle : state.title).font(state.theme.font(compact ? 22 : 25, emphasis: true)).lineLimit(2).minimumScaleFactor(0.8).widgetAccentable()
                    if !compact {
                        Text(state.paired ? (state.synthetic ? "Test source" : state.sessionCount > 0 ? "\(state.sessionCount) agent\(state.sessionCount == 1 ? "" : "s")" : "Agent status") : "Open Companion to begin.")
                            .font(.system(size: 11)).opacity(0.65)
                    }
                }
                if !compact { Spacer(minLength: 0); AgentMark(state: state.state).frame(width: 55, height: 55).foregroundStyle(accented ? .primary : state.theme.tint).widgetAccentable() }
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                if let date = state.updatedAt {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text("Updated").font(.system(size: 10))
                    Text("\(date, style: .relative) ago").font(.system(size: 10)).lineLimit(1)
                } else { Text("OPEN COMPANION").font(.system(size: 9, weight: .semibold)).tracking(1) }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10))
            }.opacity(0.6)
        }.foregroundStyle(accented ? .primary : state.theme.ink)
    }
}
