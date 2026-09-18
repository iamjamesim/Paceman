import SwiftUI

struct CompanionHome: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    @ObservedObject private var push = PushCoordinator.shared
    let theme: CompanionTheme
    let open: (FeedDestination) -> Void
    var paired: Bool { presentation.preview ? presentation.previewHasComputer : model.source != nil }
    var hasWatch: Bool { presentation.preview ? presentation.previewHasWatch : model.watch.paired }
    var watchReady: Bool { presentation.preview ? presentation.previewHasWatch : model.watch.ready }
    var offline: Bool { presentation.preview ? presentation.previewOffline : model.hasError }
    var content: AgentFeedContent {
        if presentation.preview {
            if presentation.previewScreen == "waiting" { return .waiting }
            return presentation.previewSessions.isEmpty ? .empty : .sessions(presentation.previewSessions)
        }
        return AgentFeedContent.resolve(model.snapshot)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 9) {
                        CompanionBrandMark().frame(width: 31, height: 31).foregroundStyle(theme.tint)
                        Text("companion").font(.system(size: 21, weight: .medium, design: .rounded)).tracking(-0.5)
                    }
                    Spacer()
                    Button { open(.settings) } label: {
                        Image(systemName: "gearshape").font(.system(size: 19, weight: .regular)).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Settings")
                }.padding(.bottom, 34)

                if paired { agentContent }
                else { agentSetup }

                if paired && !presentation.preview && !model.accessRevoked && push.setupStep.needsAttention {
                    feedNotice(title: "Finish notification setup", detail: push.setupStep == .blocked ? "Notifications are off in iOS Settings." : "Enable agent updates when you're away from your computer.", symbol: "bell", action: push.setupStep == .blocked ? "Open Settings" : "Continue") {
                        if push.setupStep == .blocked { push.openSettings() } else { open(.notifications) }
                    }.padding(.top, 20)
                }
                watchRow.padding(.top, 22)
                if presentation.preview {
                    Text("Design preview · sample activity").font(.caption).foregroundStyle(theme.ink.opacity(0.5)).padding(.top, 22)
                }
            }.padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 34)
        }
        .refreshable { if !presentation.preview { await model.refresh() } }
        .foregroundStyle(theme.ink).background(CompanionCanvas(theme: theme))
        .navigationTitle("Companion").toolbar(.hidden, for: .navigationBar)
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
    private var agentContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open(.computer) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.ink.opacity(0.65)).accessibilityHidden(true)
                    Text(presentation.displayName(source: model.source))
                        .font(theme.monospaced ? theme.font(13, emphasis: true) : .subheadline.weight(.medium))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).opacity(0.45)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Manage this computer's connection")

            VStack(alignment: .leading, spacing: 8) {
                Text(model.accessRevoked ? "Access removed" : offline ? "Computer unavailable" : content.headline)
                    .font(theme.monospaced ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
                    .tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                if offline {
                    Text(model.accessRevoked ? "Open this computer’s connection to scan a new pairing code." : model.snapshot != nil || presentation.preview ? "Last received: \(content.headline.lowercased())" : "Check that your computer is awake and Tailscale is connected.")
                        .font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                } else if let detail = content.supportingStatus {
                    Text(detail).font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                } else {
                    switch content {
                    case .waiting:
                        Text("Your agents will appear when the computer responds.").font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                    case .empty:
                        Text("Activity will appear here when an agent starts.").font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                    case .summary:
                        Text("Individual agent details aren't available yet.").font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                    case .sessions: EmptyView()
                    }
                }
            }.padding(.top, 12).padding(.bottom, 18)

            if case .sessions(let sessions) = content {
                ForEach(sessions) { session in
                    CompanionRule(theme: theme)
                    AgentFeedRow(session: session, theme: theme)
                }
            }
            CompanionRule(theme: theme)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { updateLabel; Spacer(minLength: 0); sourceBadge }
                VStack(alignment: .leading, spacing: 8) { updateLabel; sourceBadge }
            }.padding(.top, 14)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 20)
        .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
    }
    private var updateLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: offline ? "wifi.slash" : "clock").accessibilityHidden(true)
            if presentation.preview {
                Text(presentation.previewScreen == "waiting" ? "No updates yet" : offline ? "Updated 12 minutes ago" : "Updated just now")
            } else if let snapshot = model.snapshot {
                Text("Updated \(Date(timeIntervalSince1970: snapshot.observedAt), style: .relative) ago")
            } else { Text("No updates yet") }
        }.font(.caption).foregroundStyle(theme.ink.opacity(0.55))
    }
    @ViewBuilder private var sourceBadge: some View {
        if model.accessRevoked {
            Button("Reconnect") { open(.computer) }.font(.caption.weight(.semibold)).frame(minHeight: 44)
        } else if offline {
            Button("Try again") { if !presentation.preview { Task { await model.refresh() } } }
                .font(.caption.weight(.semibold)).frame(minHeight: 44).disabled(model.busy)
        } else if !presentation.preview && model.snapshot?.mode == "synthetic" {
            Text("TEST SOURCE").font(.system(size: 8, weight: .semibold)).tracking(0.8).foregroundStyle(theme.ink.opacity(0.5))
        }
    }
    private func feedNotice(title: String, detail: String, symbol: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                Button(action, action: perform).font(.footnote.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 17))
    }
    private var watchRow: some View {
        Button { open(.watch) } label: {
            HStack(spacing: 20) {
                WatchIllustration(theme: theme, paired: hasWatch).frame(width: hasWatch ? 45 : 55, height: hasWatch ? 68 : 83)
                VStack(alignment: .leading, spacing: 7) {
                    Text(hasWatch ? "Omarchy Watch" : "Connect your watch")
                        .font(theme.monospaced ? theme.font(17, emphasis: true) : .headline).multilineTextAlignment(.leading)
                    if hasWatch {
                        HStack(spacing: 5) {
                            Circle().fill(watchReady ? theme.tint : theme.ink.opacity(0.3)).frame(width: 5, height: 5)
                            Text(watchReady ? "Connected" : model.watch.enabled ? "Reconnecting" : "Paused").font(.footnote)
                        }.foregroundStyle(theme.ink.opacity(0.65))
                        if presentation.preview { Text("Last update 12s ago").font(.caption).foregroundStyle(theme.ink.opacity(0.5)) }
                        else if let date = model.watch.lastDelivered {
                            Text("Last update \(date, style: .relative) ago").font(.caption).foregroundStyle(theme.ink.opacity(0.5))
                        }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: session.provider == "claude" ? "asterisk" : "terminal")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(theme.ink.opacity(0.65))
                .frame(width: 23, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayName).font(theme.monospaced ? theme.font(13, emphasis: true) : .subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(session.detail).font(.caption).foregroundStyle(theme.ink.opacity(0.55)).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                if typeSize.isAccessibilitySize { stateLabel }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 7); stateLabel }
        }.padding(.vertical, 17).accessibilityElement(children: .combine)
    }
    private var stateLabel: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 6) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: session.state == .needsInput ? "arrow.turn.down.right" : session.state == .finished ? "checkmark" : session.state == .working ? "ellipsis" : "minus")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.tint).accessibilityHidden(true)
            }
            Text(session.state.title).font(.caption2.weight(.medium)).foregroundStyle(session.state == .needsInput ? theme.tint : theme.ink.opacity(0.6)).fixedSize(horizontal: true, vertical: false)
        }
    }
}
