import SwiftUI

struct CompanionHome: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var monitoring: MonitoringCoordinator
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    var focusedSourceID: String? = nil
    let open: (FeedDestination) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var paired: Bool { presentation.preview ? presentation.previewHasComputer : !model.pairedSources.isEmpty }
    var hasWatch: Bool { presentation.preview ? presentation.previewHasWatch : model.watch.paired }
    var watchReady: Bool { presentation.preview ? presentation.previewHasWatch : model.watch.ready }
    private var prominentTint: Color {
        // Large marks and status text can use warmer amber; small labels keep the darker tint.
        presentation.themeFamily == .ayu && !theme.dark
            ? Color(companionHex: "B77800") : theme.tint
    }
    private var liveActivitiesStatus: String {
        presentation.preview
            ? MonitoringCoordinator.displayStatus(available: presentation.previewScreen != "live-activities-off",
                pairedCount: model.pairedSources.count, enabledCount: model.pairedSources.count)
            : monitoring.status
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        HStack(spacing: 8) {
                            PacemanMark().frame(width: 31, height: 31).foregroundStyle(prominentTint)
                            Text("PACEMAN")
                                .font(.custom("AvenirNext-BoldItalic", fixedSize: 21))
                                .tracking(0.3)
                                .accessibilityLabel("Paceman")
                        }
                        Spacer()
                        Button { open(.settings) } label: {
                            Image(systemName: "gearshape").font(.system(size: 19, weight: .regular)).frame(width: 44, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Settings")
                    }.padding(.bottom, 32)

                    if paired || hasWatch {
                        destinations.padding(.bottom, 28)
                    }

                    if paired {
                        computersHeading.padding(.bottom, 8)
                        ForEach(model.pairedSources, id: \.sourceID) { paired in
                            computerCard(paired)
                                .padding(.top, paired.sourceID == model.pairedSources.first?.sourceID ? 0 : 12)
                                .id(paired.sourceID)
                        }
                    } else { agentSetup }
                    if presentation.preview {
                        Text("Design preview · sample activity").font(.caption)
                            .foregroundStyle(theme.secondaryInk).padding(.top, 24)
                    }
                }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 32)
            }
            .refreshable { if !presentation.preview { await model.refreshAll() } }
            .onAppear {
                if let focusedSourceID { proxy.scrollTo(focusedSourceID, anchor: .top) }
            }
            .onChange(of: focusedSourceID) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) } }
            }
        }
        .foregroundStyle(theme.ink).background(CompanionCanvas(theme: theme))
        .navigationTitle("Paceman").toolbar(.hidden, for: .navigationBar)
    }

    private var computersHeading: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout())
        return layout {
            if typeSize.isAccessibilitySize {
                Text("Computers").font(.headline).accessibilityAddTraits(.isHeader)
            } else {
                Text("COMPUTERS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(theme.secondaryInk)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            Button { open(.pairing) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("Connect computer")
        }
    }

    private var destinations: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if paired {
                Button { open(.liveActivities) } label: {
                    destinationContent(
                        icon: AnyView(LiveActivityGlyph(theme: presentation.themeFamily.glance).frame(width: 37, height: 43)),
                        name: "Live Activities",
                        state: liveActivitiesStatus)
                }.buttonStyle(.plain).accessibilityLabel("Live Activities, \(liveActivitiesStatus)")
            }
            if hasWatch {
                Button { open(.watch) } label: {
                    destinationContent(
                        icon: AnyView(WatchGlyph(theme: presentation.themeFamily.glance, timeFormat: model.watch.timeFormat)),
                        name: "Paceman Watch",
                        state: presentation.preview ? "Connected" : model.watch.connectionPresentation.rawValue)
                }.buttonStyle(.plain)
            }
        }
    }

    private func destinationContent(icon: AnyView, name: String, state: String) -> some View {
        HStack(spacing: 8) {
            icon.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(state).font(.caption2).foregroundStyle(theme.secondaryInk)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(.horizontal, 12)
        .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    private var agentSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Connect a computer").font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !typeSize.isAccessibilitySize {
                        Image(systemName: "laptopcomputer").font(.system(size: 18, weight: .medium))
                            .foregroundStyle(theme.secondaryInk).accessibilityHidden(true)
                    }
                }
                Text("Install Paceman on the computer where you use Codex, then connect it here.")
                    .font(.subheadline).foregroundStyle(theme.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
            CompanionButton(title: "Connect computer", theme: theme, symbol: "plus") { open(.pairing) }
            CompanionExternalLink(title: "Setup guide", url: SetupGuide.url, theme: theme)
                .allowsHitTesting(!presentation.preview)
        }.padding(24).background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
    }

    private func computerCard(_ paired: PairedSource) -> some View {
        let id = paired.sourceID
        let firstPreview = presentation.preview && id == model.pairedSources.first?.sourceID
        let value = model.snapshots[id]
        let state = presentation.computerState(model: model, sourceID: id)
        let historical = state == .reconnecting || state == .checking
        let content: AgentFeedContent = firstPreview
            ? (["waiting", "offline-empty"].contains(presentation.previewScreen) ? .waiting
                : presentation.previewSessions.isEmpty ? .empty : .sessions(presentation.previewSessions))
            : AgentFeedContent.resolve(value)
        let rows: [AgentDisplayRow] = {
            if case .sessions(let sessions) = content { return AgentDisplayRow.rows(sessions) }
            return []
        }()
        return VStack(alignment: .leading, spacing: 0) {
            Button { open(.otherComputer(id)) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if !typeSize.isAccessibilitySize {
                        Image(systemName: "laptopcomputer")
                            .font(.caption).foregroundStyle(theme.secondaryInk).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.displayName(source: paired, snapshot: value))
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .multilineTextAlignment(.leading)
                        if model.pairedSources.filter({ presentation.displayName(source: $0, snapshot: model.snapshots[$0.sourceID]) == presentation.displayName(source: paired, snapshot: value) }).count > 1,
                           let host = paired.endpoint.host {
                            Text(host).font(.caption2).foregroundStyle(theme.secondaryInk)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    if !typeSize.isAccessibilitySize, case .sessions(let sessions) = content, rows.count > 1 {
                        Text("\(sessions.count) sessions").font(.caption2).foregroundStyle(theme.secondaryInk)
                    }
                    if !typeSize.isAccessibilitySize {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondaryInk)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Manage this computer's connection")
            if state != .current {
                HStack {
                    Text(state.rawValue).font(.caption).foregroundStyle(theme.secondaryInk)
                    if state == .revoked {
                        Spacer()
                        Button("Reconnect") { open(.otherComputer(id)) }
                            .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(theme.ink).frame(minHeight: 44)
                    }
                }.padding(.top, 3)
            }
            if content != .waiting && (firstPreview || model.lastContacts[id] != nil) {
                ComputerReceiptLabel(model: model, presentation: presentation, sourceID: id)
                    .font(.caption2).foregroundStyle(theme.secondaryInk).padding(.top, 5)
            }
            Rectangle().fill(theme.ink.opacity(0.14)).frame(height: 0.5).padding(.top, 16)
            if state == .revoked {
                Text("Reconnect to receive activity from this computer.")
                    .font(.subheadline).foregroundStyle(theme.secondaryInk).padding(.top, 18)
            } else {
                switch content {
                case .sessions:
                    if let leading = rows.first {
                        activityHeadline(leading.session.state, historical: historical)
                        if rows.count == 1 {
                            Text(leading.session.displayName)
                                .font(.subheadline.weight(.medium)).foregroundStyle(historical ? theme.secondaryInk : theme.ink)
                                .padding(.top, 10)
                            if !leading.detail.isEmpty {
                                Text(leading.detail).font(.caption).foregroundStyle(theme.secondaryInk).padding(.top, 3)
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { Rectangle().fill(theme.ink.opacity(0.14)).frame(height: 0.5) }
                                    activityRow(row, historical: historical)
                                }
                            }.padding(.top, 11)
                        }
                    }
                case .waiting:
                    emptyActivity("No activity received yet", detail: nil)
                case .empty:
                    emptyActivity(historical ? "Last known: No active sessions" : "No active sessions",
                                  detail: historical ? nil : "Activity appears when an agent starts.")
                case .summary(let activity):
                    activityHeadline(activity, historical: historical)
                }
            }
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
        .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
    }

    private func activityHeadline(_ state: ActivityState, historical: Bool) -> some View {
        let title = state == .idle ? "No active sessions" : state.title
        return HStack(spacing: 11) {
            if state != .idle && !typeSize.isAccessibilitySize {
                ActivityRobot(state: state, animate: !historical)
                    .frame(width: 31, height: 31)
                    .foregroundStyle(historical ? theme.secondaryInk : stateColor(state))
                    .accessibilityHidden(true)
            }
            Text(historical ? "Last known: \(title)" : title)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(historical ? theme.secondaryInk : stateColor(state))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(.top, 16)
    }

    private func activityRow(_ row: AgentDisplayRow, historical: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.session.displayName).font(.subheadline.weight(.medium))
                    .foregroundStyle(historical ? theme.secondaryInk : theme.ink)
                if !row.detail.isEmpty {
                    Text(row.detail).font(.caption).foregroundStyle(theme.secondaryInk)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            Text(row.session.state.title).font(.caption.weight(.medium))
                .foregroundStyle(historical ? theme.secondaryInk : stateColor(row.session.state))
                .fixedSize(horizontal: true, vertical: false)
        }.padding(.vertical, 10).accessibilityElement(children: .combine)
    }

    private func stateColor(_ state: ActivityState) -> Color {
        PhoneMonitoringStatusColor.color(for: state.rawValue, onDark: theme.dark, fallback: theme.ink)
    }

    private func emptyActivity(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(.title3, design: .rounded, weight: .semibold))
            if let detail { Text(detail).font(.caption).foregroundStyle(theme.secondaryInk) }
        }.padding(.top, 18)
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
            PacemanMark(expression: state == .finished ? .finished : state == .needsInput ? .needsInput : state == .failed ? .failed : .neutral)
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
            }.foregroundStyle(theme.secondaryInk)
            Group {
                if previewState == "connected" { Text("Last sent just now") }
                else if previewState != nil {
                    if previewState != "off" { Text("No updates sent yet") }
                } else if let date = watch.lastDelivered { ReceiptTimeLabel(prefix: "Last sent", date: date) }
                else if watch.updatesEnabled { Text("No updates sent yet") }
            }.font(.caption).foregroundStyle(theme.secondaryInk)
        }
    }
}
