import SwiftUI
import UIKit

struct LiveActivitiesDetail: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var monitoring: MonitoringCoordinator
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var enabled: Bool {
        presentation.previewScreen != "live-activities-off" && monitoring.available
    }
    private var displayStatus: String {
        if presentation.preview {
            return MonitoringCoordinator.displayStatus(available: enabled, hasComputer: !model.pairedSources.isEmpty)
        }
        return monitoring.status
    }

    private var activeSources: [PairedSource] {
        if presentation.preview { return presentation.previewScreen == "live-activities" ? Array(model.pairedSources.prefix(1)) : [] }
        return model.pairedSources.filter { monitoring.activeSourceIDs.contains($0.sourceID) }
    }
    private var checkingSources: [PairedSource] {
        if presentation.preview { return [] }
        return model.pairedSources.filter { !model.isRevoked($0.sourceID) && !monitoring.readySourceIDs.contains($0.sourceID) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 20) {
                    if !typeSize.isAccessibilitySize {
                        LiveActivityIllustration()
                            .frame(width: 260, height: 126)
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: 9) {
                        Text("Live Activities")
                            .font(theme.monospaced && !typeSize.isAccessibilitySize
                                ? theme.font(24, emphasis: true) : .title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Circle().fill(enabled && !model.pairedSources.isEmpty ? theme.tint : theme.ink.opacity(0.3))
                                .frame(width: 5, height: 5)
                            Text(displayStatus).font(.footnote)
                        }.foregroundStyle(theme.ink.opacity(0.65))
                    }
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(.top, 20).padding(.bottom, 12)
                if !enabled {
                    Text("Turn on Live Activities to see agent activity on your Lock Screen and Dynamic Island.")
                        .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                    CompanionButton(title: "Open iPhone Settings", theme: theme, symbol: "gearshape") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                } else if model.pairedSources.isEmpty {
                    Text("Connect a computer to see agent activity on your Lock Screen and Dynamic Island.")
                        .font(.footnote).foregroundStyle(theme.ink.opacity(0.65))
                    NavigationLink(value: FeedDestination.pairing) {
                        Label("Connect computer", systemImage: "plus").font(.subheadline).frame(minHeight: 44)
                    }
                } else {
                    CompanionRule(theme: theme)
                    Text("Showing now").font(.headline)
                    if activeSources.isEmpty {
                        Text("No Live Activities now. They appear when agents start work.")
                            .font(.subheadline).foregroundStyle(theme.ink.opacity(0.65))
                    } else {
                        ForEach(activeSources, id: \.sourceID) { source in
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer").frame(width: 26).accessibilityHidden(true)
                                Text(presentation.displayName(source: source)).lineLimit(2)
                            }.font(.subheadline)
                        }
                    }
                    if !checkingSources.isEmpty {
                        CompanionRule(theme: theme)
                        Text("Checking automatic start").font(.headline)
                    }
                    ForEach(checkingSources, id: \.sourceID) { source in
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer").frame(width: 26).accessibilityHidden(true)
                            Text(presentation.displayName(source: source)).lineLimit(2)
                            Spacer(minLength: 8)
                            Text("Checking").foregroundStyle(theme.ink.opacity(0.65))
                        }.font(.subheadline).accessibilityElement(children: .combine)
                    }
                    if !checkingSources.isEmpty {
                        Text("Paceman retries automatically. If a computer stays here, check its Sharing and connection.")
                            .font(.footnote).foregroundStyle(theme.ink.opacity(0.62))
                    }
                }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.foregroundStyle(theme.ink).background(theme.canvas).tint(theme.tint)
            .navigationTitle("Live Activities").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LiveActivityIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer")
                Text("MacBook Pro")
                Spacer()
                Text("PREVIEW").tracking(1.4).font(.system(size: 8, weight: .semibold, design: .rounded))
            }.font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(MonitoringPalette.muted)
            HStack(spacing: 10) {
                Image("Robot-excited")
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(MonitoringPalette.robotColor(for: "working"))
                Text("Working").font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitoringPalette.ink)
            }
        }
        .padding(19)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MonitoringPalette.background, in: RoundedRectangle(cornerRadius: 26))
    }
}

struct CompanionSettings: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    var body: some View {
        List {
            Section {
                NavigationLink(value: FeedDestination.notifications) { Label("Notifications", systemImage: "bell") }
            }.listRowBackground(theme.ink.opacity(0.04))
            Section {
                NavigationLink(value: FeedDestination.diagnostics) {
                    Label("Developer tools", systemImage: "wrench.and.screwdriver")
                }.disabled(presentation.preview)
            } footer: { Text("Paceman · Prototype") }.listRowBackground(theme.ink.opacity(0.04))
        }.scrollContentBackground(.hidden).background(theme.canvas).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
    }
}
