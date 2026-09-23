import SwiftUI

struct CompanionHome: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    let open: (FeedDestination) -> Void
    var paired: Bool { presentation.preview ? presentation.previewHasComputer : model.source != nil }
    var hasWatch: Bool { presentation.preview ? presentation.previewHasWatch : model.watch.paired }
    var watchReady: Bool { presentation.preview ? presentation.previewHasWatch : model.watch.ready }
    var offline: Bool { presentation.preview ? presentation.previewOffline : model.hasError }
    var stale: Bool { presentation.preview ? presentation.previewOffline : model.snapshot != nil && !model.fresh }
    var content: AgentFeedContent {
        if presentation.preview {
            if ["waiting", "offline-empty"].contains(presentation.previewScreen) { return .waiting }
            return presentation.previewSessions.isEmpty ? .empty : .sessions(presentation.previewSessions)
        }
        return AgentFeedContent.resolve(model.snapshot)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 9) {
                        PacemanMark().frame(width: 31, height: 31).foregroundStyle(theme.tint)
                        Text("Paceman").font(.system(size: 21, weight: .medium, design: .rounded)).tracking(-0.5)
                    }
                    Spacer()
                    Button { open(.settings) } label: {
                        Image(systemName: "gearshape").font(.system(size: 19, weight: .regular)).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Settings")
                }.padding(.bottom, 34)

                if paired {
                    agentContent
                    ForEach(model.additionalSources, id: \.sourceID) { paired in
                        additionalComputer(paired).padding(.top, 12)
                    }
                    if !presentation.preview {
                        Button { open(.pairing) } label: { Label("Connect another computer", systemImage: "plus") }
                            .font(.subheadline).padding(.top, 18)
                    }
                }
                else { agentSetup }

                watchRow.padding(.top, 22)
                if presentation.preview {
                    Text("Design preview · sample activity").font(.caption).foregroundStyle(theme.ink.opacity(0.5)).padding(.top, 22)
                }
            }.padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 34)
        }
        .refreshable { if !presentation.preview { await model.refreshAll() } }
        .foregroundStyle(theme.ink).background(CompanionCanvas(theme: theme))
        .navigationTitle("Paceman").toolbar(.hidden, for: .navigationBar)
    }
    private var agentSetup: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack {
                Eyebrow(text: "Agents")
                Spacer()
                Image(systemName: "laptopcomputer").font(.system(size: 18, weight: .medium)).foregroundStyle(theme.ink.opacity(0.65)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Connect your agents").font(theme.monospaced ? theme.font(25, emphasis: true) : .title2.weight(.semibold)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                Text("Connect the computer running your agents.").font(.subheadline).foregroundStyle(theme.ink.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            }
            CompanionButton(title: "Connect computer", theme: theme, symbol: "plus") { open(.pairing) }
        }.padding(23).background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
    }
    private var historical: Bool { offline || stale }
    private var connection: ComputerConnectionState { presentation.computerState(model: model) }
    private var agentContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open(.computer) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 24).foregroundStyle(theme.ink.opacity(0.65)).accessibilityHidden(true)
                    Text(presentation.displayName(source: model.source))
                        .font(theme.monospaced ? theme.font(15, emphasis: true) : .subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).opacity(0.45)
                }.frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Manage this computer's connection")

            if model.accessRevoked {
                HStack { connectionLabel; Spacer(); recoveryAction }.padding(.top, 3)
            } else if connection != .current {
                connectionLabel.padding(.top, 8)
            }
            if presentation.preview ? presentation.previewScreen != "waiting" && presentation.previewScreen != "offline-empty" : model.lastContact != nil {
                updateLabel.padding(.top, 5)
            }
            Color.clear.frame(height: 16)

            CompanionRule(theme: theme)
            if model.accessRevoked {
                Text("Reconnect to receive activity from this computer.")
                    .font(.subheadline).foregroundStyle(theme.ink.opacity(0.65)).padding(.top, 18)
            } else {
                if historical, content.hasActivity {
                    Text("Last known activity").font(.caption).foregroundStyle(theme.ink.opacity(0.55))
                        .padding(.top, 16)
                }
                switch content {
                case .sessions(let sessions):
                    let rows = AgentDisplayRow.rows(sessions)
                    if rows.count > 1 && !historical {
                        Text([content.headline, content.supportingStatus].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(theme.ink.opacity(0.65)).padding(.top, 16)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { CompanionRule(theme: theme) }
                        AgentFeedRow(session: row.session, theme: theme, animate: !historical, detailOverride: row.detail)
                    }
                case .waiting:
                    emptyActivity("No activity received yet", detail: nil)
                case .empty:
                    emptyActivity("No active sessions", detail: historical ? nil : "Activity appears when an agent starts.")
                case .summary(let state):
                    AgentFeedRow(session: AgentSession(id: "aggregate", provider: "", state: state, name: "Agent activity"), theme: theme, animate: !historical)
                }
            }
            if !presentation.preview && model.snapshot?.mode == "synthetic" {
                Text("Test source").font(.caption2).foregroundStyle(theme.ink.opacity(0.5))
            }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 6)
        .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
    }
    private func emptyActivity(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            if let detail { Text(detail).font(.caption).foregroundStyle(theme.ink.opacity(0.55)) }
        }.padding(.vertical, 20)
    }
    private func additionalComputer(_ paired: PairedSource) -> some View {
        let value = model.additionalSnapshots[paired.sourceID]
        let current = model.additionalFresh(paired.sourceID)
        let revoked = model.additionalRevoked.contains(paired.sourceID)
        let content = AgentFeedContent.resolve(value)
        return VStack(alignment: .leading, spacing: 0) {
            Button { open(.otherComputer(paired.sourceID)) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").frame(width: 24).accessibilityHidden(true)
                    Text(presentation.displayName(source: paired)).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).opacity(0.45)
                }.frame(minHeight: 32)
            }.buttonStyle(.plain)
            if revoked { Text("Access removed").font(.caption).foregroundStyle(theme.ink.opacity(0.65)) }
            else if model.additionalErrors[paired.sourceID] != nil { Text("Reconnecting…").font(.caption).foregroundStyle(theme.ink.opacity(0.65)) }
            else if !current { Text(value == nil ? "Connecting…" : "Checking…").font(.caption).foregroundStyle(theme.ink.opacity(0.65)) }
            if let contact = model.additionalLastContact[paired.sourceID] {
                ReceiptTimeLabel(prefix: "Last received", date: contact)
                    .font(.caption2).foregroundStyle(theme.ink.opacity(0.5))
            }
            Color.clear.frame(height: 16)
            CompanionRule(theme: theme)
            if revoked {
                Text("Reconnect to receive activity from this computer.")
                    .font(.subheadline).foregroundStyle(theme.ink.opacity(0.65)).padding(.vertical, 18)
            } else {
                if !current && content.hasActivity {
                    Text("Last known activity").font(.caption).foregroundStyle(theme.ink.opacity(0.55)).padding(.top, 16)
                }
                switch content {
                case .sessions(let sessions):
                    ForEach(AgentDisplayRow.rows(sessions)) { row in
                        AgentFeedRow(session: row.session, theme: theme, animate: current, detailOverride: row.detail)
                    }
                case .summary(let state):
                    AgentFeedRow(session: AgentSession(id: "aggregate", provider: "", state: state, name: "Agent activity"),
                                 theme: theme, animate: current)
                case .waiting: emptyActivity("No activity received yet", detail: nil)
                case .empty: emptyActivity("No active sessions", detail: current ? "Activity appears when an agent starts." : nil)
                }
            }
        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 6)
            .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
    }
    private var connectionLabel: some View {
        Text(presentation.computerState(model: model).rawValue)
            .font(.caption).foregroundStyle(theme.ink.opacity(0.7))
    }
    private var recoveryAction: some View {
        Button(model.accessRevoked ? "Reconnect" : "Retry") {
            if model.accessRevoked { open(.computer) }
            else if !presentation.preview { Task { await model.refresh() } }
        }.buttonStyle(.plain).font(.caption.weight(.semibold)).frame(minHeight: 44)
            .disabled(!model.accessRevoked && model.busy)
    }
    private var updateLabel: some View {
        ComputerReceiptLabel(model: model, presentation: presentation)
            .font(.caption2).foregroundStyle(theme.ink.opacity(0.5))
    }
    private var watchRow: some View {
        Button { open(.watch) } label: {
            HStack(spacing: 20) {
                WatchIllustration(theme: theme, paired: hasWatch, timeFormat: model.watch.timeFormat, state: presentation.preview ? .working : model.currentActivityState).frame(width: hasWatch ? 45 : 55, height: hasWatch ? 68 : 83)
                VStack(alignment: .leading, spacing: 7) {
                    Text(hasWatch ? "Omarchy Watch" : "Connect your watch")
                        .font(theme.monospaced ? theme.font(15, emphasis: true) : .subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                    if hasWatch {
                        WatchConnectionSummary(watch: model.watch, theme: theme, previewState: presentation.preview ? "connected" : nil)
                    } else {
                        Text("Show agent status on your wrist.").font(.subheadline).foregroundStyle(theme.ink.opacity(0.6)).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).opacity(0.45)
            }.padding(21).background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 23))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct AgentFeedRow: View {
    let session: AgentSession
    let theme: CompanionTheme
    var animate = true
    var detailOverride: String? = nil
    private var detail: String { detailOverride ?? session.detail }
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayName).font(theme.monospaced ? theme.font(15, emphasis: true) : .subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(theme.ink.opacity(0.55)).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                }
                if typeSize.isAccessibilitySize { stateLabel }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 7); stateLabel }
        }.padding(.vertical, 16).foregroundStyle(theme.ink.opacity(animate ? 1 : 0.6)).accessibilityElement(children: .combine)
    }
    private var stateLabel: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .center, spacing: 6) {
            if !typeSize.isAccessibilitySize {
                if session.state != .idle {
                    ActivityRobot(state: session.state, animate: animate)
                        .frame(width: 20, height: 20).foregroundStyle(animate ? theme.tint : theme.ink.opacity(0.4))
                }
            }
            Text(session.state.title).font(.caption2.weight(.medium)).foregroundStyle(animate && session.state == .needsInput ? theme.tint : theme.ink.opacity(0.6)).fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Motion matches watch_face_layout.c; historical activity and Reduce Motion stay still.
struct ActivityRobot: View {
    let state: ActivityState
    let animate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    private var moving: Bool { animate && !reduceMotion && scenePhase == .active && visible }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let time = moving ? context.date.timeIntervalSinceReferenceDate : 0
            let pulse = (1 - cos(time * .pi / 1.3)) / 2
            let bounceTime = time.truncatingRemainder(dividingBy: 1)
            let bounce = bounceTime < 0.64 ? (1 - cos(bounceTime * .pi / 0.32)) / 2 : 0
            let sway = sin(time * 2 * .pi / 4.2)
            Image(state == .finished ? "Robot-happy" : "Robot-excited")
                .resizable().scaledToFit()
                .opacity(state == .working ? 1 - pulse * (155.0 / 255) : 1)
                .rotationEffect(.degrees(state == .finished ? sway * 4 : 0))
                .offset(x: state == .finished ? sway * 2 : 0, y: state == .needsInput ? -bounce * 3 : 0)
        }
        .onAppear { visible = true }.onDisappear { visible = false }
        .accessibilityHidden(true)
    }
}

struct ReceiptTimeLabel: View {
    let prefix: String
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: date, by: 1)) { context in
            if context.date.timeIntervalSince(date) < 10 {
                Text("\(prefix) just now")
            } else {
                Text("\(prefix) \(date, style: .relative) ago")
            }
        }
    }
}

/// Shared by the home card and the watch detail header.
struct WatchConnectionSummary: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var watch: WatchLink
    let theme: CompanionTheme
    var previewState: String? = nil
    var centered = false
    private var ready: Bool { previewState.map { $0 == "connected" || $0 == "empty" } ?? watch.ready }
    private var status: String {
        switch previewState {
        case "connected", "empty": return "Connected"
        case "off": return "Updates off"
        case "disconnected": return "Reconnecting…"
        case "bluetooth-off": return "Bluetooth off"
        default: return watch.connectionStatus
        }
    }
    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 7) {
            HStack(spacing: 5) {
                if !typeSize.isAccessibilitySize {
                    Circle().fill(ready ? theme.tint : theme.ink.opacity(0.3)).frame(width: 5, height: 5)
                }
                Text(status).font(.footnote)
            }.foregroundStyle(theme.ink.opacity(0.65))
            Group {
                if previewState == "connected" { Text("Last sent just now") }
                else if previewState != nil {
                    if previewState != "off" { Text("No updates sent yet") }
                } else if let date = watch.lastDelivered { ReceiptTimeLabel(prefix: "Last sent", date: date) }
                else if watch.updatesEnabled { Text("No updates sent yet") }
            }.font(.caption).foregroundStyle(theme.ink.opacity(0.5))
        }
    }
}
