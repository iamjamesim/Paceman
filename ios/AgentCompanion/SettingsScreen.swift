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
                        LiveActivityIllustration(palette: presentation.themeFamily.activity,
                            outline: theme.secondaryInk.opacity(0.3))
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
                        }.foregroundStyle(theme.secondaryInk)
                    }
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(.top, 20).padding(.bottom, 12)
                if !enabled {
                    Text("Turn on Live Activities to see agent activity on your Lock Screen and Dynamic Island.")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                    CompanionButton(title: "Open iPhone Settings", theme: theme, symbol: "gearshape") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                } else if model.pairedSources.isEmpty {
                    Text("Connect a computer to see agent activity on your Lock Screen and Dynamic Island.")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                    NavigationLink(value: FeedDestination.pairing) {
                        Label("Connect computer", systemImage: "plus").font(.subheadline).frame(minHeight: 44)
                    }
                } else {
                    CompanionRule(theme: theme)
                    Text("Showing now").font(.headline)
                    if activeSources.isEmpty {
                        Text("No Live Activities now. They appear when agents start work.")
                            .font(.subheadline).foregroundStyle(theme.secondaryInk)
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
                            Text("Checking").foregroundStyle(theme.secondaryInk)
                        }.font(.subheadline).accessibilityElement(children: .combine)
                    }
                    if !checkingSources.isEmpty {
                        Text("Paceman retries automatically. If a computer stays here, check its Sharing and connection.")
                            .font(.footnote).foregroundStyle(theme.secondaryInk)
                    }
                }
            }.padding(.horizontal, 26).padding(.bottom, 30)
        }.foregroundStyle(theme.ink).background(theme.canvas).tint(theme.tint)
            .navigationTitle("Live Activities").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LiveActivityIllustration: View {
    let palette: MonitoringPalette
    let outline: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer")
                Text("MacBook Pro")
                Spacer()
                Text("PREVIEW").tracking(1.4).font(.system(size: 8, weight: .semibold, design: .rounded))
            }.font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(palette.muted)
            HStack(spacing: 10) {
                Image("Robot-excited")
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(palette.robotColor(for: "working"))
                Text("Working").font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.headlineColor(for: "working"))
            }
        }
        .padding(19)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(outline, lineWidth: 1))
    }
}

struct CompanionSettings: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    var body: some View {
        List {
            Section {
                NavigationLink(value: FeedDestination.appearance) {
                    HStack {
                        Label("Appearance", systemImage: "paintpalette")
                        Spacer()
                        Text(presentation.themeFamily.name).foregroundStyle(theme.secondaryInk)
                    }
                }
                NavigationLink(value: FeedDestination.notifications) { Label("Notifications", systemImage: "bell") }
            }.listRowBackground(theme.panel)
            Section {
                NavigationLink(value: FeedDestination.diagnostics) {
                    Label("Developer tools", systemImage: "wrench.and.screwdriver")
                }.disabled(presentation.preview)
            } footer: { Text("Paceman · Prototype") }.listRowBackground(theme.panel)
        }.scrollContentBackground(.hidden).background(theme.canvas).foregroundStyle(theme.ink)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
    }
}

struct AppearanceSettings: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingCredits = false

    var body: some View {
        List {
            Section {
                ForEach(ThemeFamily.allCases) { family in
                    Button {
                        presentation.selectTheme(family, model: model)
                    } label: {
                        Group {
                            if typeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 10) {
                                    themeName(family)
                                    PaletteSwatches(family: family, dark: colorScheme == .dark, outline: theme.ink)
                                }
                            } else {
                                HStack(spacing: 12) {
                                    themeName(family)
                                    Spacer(minLength: 8)
                                    PaletteSwatches(family: family, dark: colorScheme == .dark, outline: theme.ink)
                                }
                            }
                        }
                        .padding(.vertical, typeSize.isAccessibilitySize ? 7 : 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(family.name)
                    .accessibilityValue(presentation.themeFamily == family ? "Selected" : "")
                    .listRowBackground(theme.panel)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .foregroundStyle(theme.ink)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Palette credits", systemImage: "info.circle") { showingCredits = true }
                    .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $showingCredits) {
            PaletteCredits(theme: theme)
        }
    }

    private func themeName(_ family: ThemeFamily) -> some View {
        HStack(spacing: 8) {
            Text(family.name).font(.body)
            if presentation.themeFamily == family {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.tint)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct PaletteSwatches: View {
    let family: ThemeFamily
    let dark: Bool
    let outline: Color

    private var colors: [Color] {
        let phone = family.phone(dark: dark || !family.supportsLight)
        let glance = family.glance
        let activity = family.activity
        if phone.accent != glance.accent {
            return [phone.tint, glance.tint, family == .paceman ? activity.input : activity.working]
        }
        switch family {
        case .paceman:
            return [phone.tint, activity.input, glance.ink]
        case .monochrome:
            return [phone.tint, activity.working, activity.finished]
        default:
            return [phone.tint, activity.working, glance.ink]
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors.indices, id: \.self) { index in
                Circle()
                    .fill(colors[index])
                    .overlay(Circle().strokeBorder(outline.opacity(0.22), lineWidth: 0.5))
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PaletteCredits: View {
    let theme: CompanionTheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            List {
                Section {
                    credit("Ayu", creator: "ayu-theme", url: "https://github.com/ayu-theme/ayu-colors")
                    credit("Sakura Mochi", creator: "OldJobobo", url: "https://github.com/OldJobobo/omarchy-sakura-mochi-theme")
                    credit("Miasma", creator: "xero", url: "https://github.com/xero/miasma.nvim")
                    credit("Catppuccin", creator: "Catppuccin", url: "https://github.com/catppuccin/catppuccin")
                } footer: {
                    Text("Palettes adapted for Paceman.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .foregroundStyle(theme.ink)
            .navigationTitle("Palette Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(theme.tint)
        .presentationDetents([.medium, .large])
    }

    private func credit(_ name: String, creator: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                        Text(creator).foregroundStyle(theme.secondaryInk)
                    }
                } else {
                    HStack {
                        Text(name)
                        Spacer()
                        Text(creator).foregroundStyle(theme.secondaryInk)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(theme.secondaryInk)
                    }
                }
            }
        }
        .listRowBackground(theme.panel)
    }
}
