import SwiftUI

struct CompanionCanvas: View {
    let theme: CompanionTheme
    var body: some View { theme.canvas.ignoresSafeArea() }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(2.0).opacity(0.55) }
}

struct CompanionButton: View {
    let title: String
    let theme: CompanionTheme
    var symbol: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol) }
                Text(title).font(.body.weight(.semibold))
            }.frame(maxWidth: .infinity).padding(.vertical, 18)
                .foregroundStyle(theme.canvas).background(theme.ink, in: RoundedRectangle(cornerRadius: 19))
        }.buttonStyle(.plain)
    }
}

struct CompanionSecondaryButton: View {
    let title: String
    let theme: CompanionTheme
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .foregroundStyle(theme.ink)
                .background(theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 19))
        }.buttonStyle(.plain)
    }
}

struct CompanionRule: View {
    let theme: CompanionTheme
    var body: some View { Rectangle().fill(theme.ink.opacity(0.14)).frame(height: 0.5) }
}

struct StatusPill: View {
    let text: String
    let theme: CompanionTheme
    var active = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(active ? theme.tint : theme.ink.opacity(0.35)).frame(width: 5, height: 5)
            Text(text).font(.system(size: 11, weight: .medium))
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(theme.ink.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.ink.opacity(0.08), lineWidth: 0.5))
    }
}

struct ComputerIllustration: View {
    let theme: CompanionTheme
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: w * 0.037).fill(Color(companionHex: "323632"))
                    RoundedRectangle(cornerRadius: w * 0.024).fill(theme.canvas).padding(w * 0.016)
                    HStack(spacing: w * 0.018) {
                        terminalPane(width: w, primary: true)
                        terminalPane(width: w, primary: false)
                    }.padding(w * 0.045)
                }.frame(width: w * 0.84, height: w * 0.53)
                ZStack(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: w * 0.06, bottomTrailingRadius: w * 0.06).fill(LinearGradient(colors: [Color(companionHex: "C1C4C0"), Color(companionHex: "7C827D")], startPoint: .top, endPoint: .bottom)).frame(height: w * 0.045)
                    Capsule().fill(Color.black.opacity(0.17)).frame(width: w * 0.17, height: w * 0.013)
                }.frame(width: w)
            }.frame(width: w, height: g.size.height)
        }.aspectRatio(1.7, contentMode: .fit).dynamicTypeSize(.medium).accessibilityElement(children: .ignore).accessibilityLabel("Computer illustration with two terminal panes")
    }
    private func terminalPane(width w: CGFloat, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: w * 0.022) {
            Text(">_").font(.system(size: w * 0.048, weight: .medium, design: .monospaced))
                .foregroundStyle(primary ? theme.tint : theme.ink.opacity(0.5))
            Rectangle().fill(theme.ink.opacity(0.28)).frame(width: w * (primary ? 0.21 : 0.17), height: w * 0.008)
            Rectangle().fill(theme.ink.opacity(0.14)).frame(width: w * 0.23, height: w * 0.008)
            Rectangle().fill(theme.ink.opacity(0.14)).frame(width: w * (primary ? 0.15 : 0.20), height: w * 0.008)
            Spacer(minLength: 0)
            HStack(spacing: w * 0.015) {
                Text(">").font(.system(size: w * 0.036, weight: .medium, design: .monospaced))
                Rectangle().frame(width: w * 0.014, height: w * 0.035)
            }.foregroundStyle(theme.tint.opacity(primary ? 0.85 : 0.45))
        }.padding(w * 0.022).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.ink.opacity(0.025))
            .overlay(Rectangle().strokeBorder(theme.ink.opacity(0.16), lineWidth: w * 0.003))
    }

}

struct WatchIllustration: View {
    let theme: CompanionTheme
    var paired = true
    var timeFormat = WatchTimeFormat.system
    var state = ActivityState.idle
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.16).fill(Color(companionHex: "303330")).frame(width: w * 0.53)
                RoundedRectangle(cornerRadius: w * 0.25).fill(LinearGradient(colors: [Color(companionHex: "626763"), Color(companionHex: "202321"), Color(companionHex: "525750")], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: w * 0.86, height: w * 1.02)
                RoundedRectangle(cornerRadius: w * 0.20).fill(theme.canvas).frame(width: w * 0.76, height: w * 0.92)
                if paired {
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: w * 0.08) {
                            Text(formatted(context.date, "EEE d MMM")).font(.custom("JetBrainsMono-Regular", size: w * 0.065))
                            HStack(alignment: .top, spacing: w * 0.025) {
                                Text(formatted(context.date, timeFormat.hours() == 12 ? "hh:mm" : "HH:mm"))
                                    .font(.custom("JetBrainsMono-Regular", size: w * 0.19)).tracking(-w * 0.016)
                                if timeFormat.hours() == 12 {
                                    Text(formatted(context.date, "a")).font(.custom("JetBrainsMono-Regular", size: w * 0.055))
                                        .padding(.top, w * 0.025)
                                }
                            }.foregroundStyle(theme.tint)
                            Rectangle().fill(theme.ink.opacity(0.22)).frame(height: 0.5)
                            HStack {
                                if state != .idle {
                                    ActivityRobot(state: state, animate: false).frame(width: w * 0.13, height: w * 0.13)
                                        .foregroundStyle(theme.tint)
                                }
                                Spacer(minLength: 0)
                                Text(state.title.uppercased()).font(.custom("JetBrainsMono-Regular", size: w * 0.058))
                            }.frame(height: w * 0.13)
                        }.foregroundStyle(theme.ink).frame(width: w * 0.58)
                    }
                } else {
                    VStack(spacing: w * 0.10) {
                        Image(systemName: "link").font(.system(size: w * 0.22, weight: .medium))
                        Text("PAIR").font(.custom("JetBrainsMono-Regular", size: w * 0.07))
                    }.foregroundStyle(theme.tint)
                }
            }.frame(width: w, height: g.size.height)
        }.aspectRatio(0.68, contentMode: .fit).dynamicTypeSize(.medium).accessibilityElement(children: .ignore).accessibilityLabel("Watch appearance preview, illustrative")
    }
    private func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

}

struct DetailRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title).font(.subheadline)
            Spacer(minLength: 6)
            content.font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.padding(.vertical, 12)
    }
}

/// The app icon's robot geometry, cropped to the artwork for a legible small mark.
struct CompanionBrandMark: View {
    var body: some View {
        GeometryReader { g in
            let scale = g.size.width / 720
            let offset = CGPoint(x: -152, y: -167)
            let transform = CGAffineTransform(translationX: offset.x, y: offset.y)
            ZStack {
                Path(roundedRect: CGRect(x: 232, y: 316, width: 560, height: 448), cornerRadius: 154)
                    .applying(transform).applying(CGAffineTransform(scaleX: scale, y: scale))
                    .stroke(style: StrokeStyle(lineWidth: 28 * scale))
                Path { path in
                    for x in [404.0, 576.0] {
                        path.addRoundedRect(in: CGRect(x: x, y: 481, width: 44, height: 98), cornerSize: CGSize(width: 22, height: 22))
                    }
                    path.addRoundedRect(in: CGRect(x: 498, y: 233, width: 28, height: 83), cornerSize: CGSize(width: 14, height: 14))
                    path.addEllipse(in: CGRect(x: 479, y: 179, width: 66, height: 66))
                    for x in [168.0, 824.0] {
                        path.addRoundedRect(in: CGRect(x: x, y: 483, width: 32, height: 115), cornerSize: CGSize(width: 16, height: 16))
                    }
                }.applying(transform).applying(CGAffineTransform(scaleX: scale, y: scale))
            }.frame(width: g.size.width, height: g.size.height)
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}
