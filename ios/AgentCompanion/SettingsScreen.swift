import SwiftUI
import UIKit

struct LiveActivitiesDetail: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var monitoring: MonitoringCoordinator
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    @State private var previewEnabled: [String: Bool] = [:]

    private var systemEnabled: Bool {
        presentation.previewScreen != "live-activities-off" && monitoring.available
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Show agent activity on your Lock Screen and Dynamic Island.")
                    .font(.subheadline).foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if !systemEnabled {
                    Text("Live Activities are off in iPhone Settings.")
                        .companionText(.body, theme: theme)
                    CompanionButton(title: "Open iPhone Settings", theme: theme, symbol: "gearshape") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                } else if model.pairedSources.isEmpty {
                    Text("Connect a computer to use Live Activities.")
                        .companionText(.body, theme: theme)
                    NavigationLink(value: FeedDestination.pairing) {
                        Label("Connect computer", systemImage: "plus").companionText(.label, theme: theme).frame(minHeight: 44)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.pairedSources.enumerated()), id: \.element.sourceID) { index, source in
                            if index > 0 { CompanionRule(theme: theme) }
                            VStack(alignment: .leading, spacing: 5) {
                                Toggle(isOn: setting(for: source.sourceID)) {
                                    Text(presentation.displayName(source: source,
                                        snapshot: model.snapshots[source.sourceID]))
                                        .font(.body).fixedSize(horizontal: false, vertical: true)
                                }
                                .tint(theme.tint)
                                .disabled(!presentation.preview && monitoring.changingSourceIDs.contains(source.sourceID))
                                .padding(.vertical, 16)
                                if !presentation.preview, let error = monitoring.settingErrors[source.sourceID] {
                                    Text(error).companionText(.body, theme: theme)
                                        .padding(.bottom, 16)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(theme.ink.opacity(0.07), lineWidth: 0.5))
                }
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 32)
        }.foregroundStyle(theme.ink).background(theme.canvas).tint(theme.tint)
            .navigationTitle("Live Activities").navigationBarTitleDisplayMode(.inline)
    }

    private func setting(for sourceID: String) -> Binding<Bool> {
        Binding(get: {
            presentation.preview ? previewEnabled[sourceID, default: true] : monitoring.isEnabled(sourceID)
        }, set: { enabled in
            if presentation.preview { previewEnabled[sourceID] = enabled }
            else { Task { await monitoring.setEnabled(enabled, for: sourceID) } }
        })
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
            }.listRowBackground(theme.panel)
            Section {
                NavigationLink(value: FeedDestination.watch) {
                    Label("Accessories", systemImage: "watch.analog")
                }
            } header: {
                Text("Experimental")
            }.listRowBackground(theme.panel)
            Section {
                NavigationLink(value: FeedDestination.diagnostics) {
                    Label("Diagnostics", systemImage: "doc.text.magnifyingglass")
                }.disabled(presentation.preview)
            }.listRowBackground(theme.panel)
        }.scrollContentBackground(.hidden).background(theme.canvas).foregroundStyle(theme.ink)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
    }
}

struct AppearanceSettings: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    @Environment(\.dynamicTypeSize) private var typeSize
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
                                    PaletteSwatches(family: family, outline: theme.ink)
                                }
                            } else {
                                HStack(spacing: 12) {
                                    themeName(family)
                                    Spacer(minLength: 8)
                                    PaletteSwatches(family: family, outline: theme.ink)
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
    let outline: Color

    private var colors: [Color] {
        let phone = family.phone(dark: true)
        let glance = family.glance
        let activity = family.activity
        switch family {
        case .osakaJade:
            return [phone.tint, activity.input, glance.ink]
        case .monochrome:
            return [phone.tint, activity.working, activity.finished]
        default:
            return [phone.tint, phone.accent == glance.accent ? activity.working : glance.tint, glance.ink]
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
                    credit("Osaka Jade", creator: "Justin Lowry", url: "https://github.com/Justikun/omarchy-osaka-jade-theme")
                    credit("Catppuccin", creator: "Catppuccin", url: "https://github.com/catppuccin/catppuccin")
                    credit("Sakura Mochi", creator: "OldJobobo", url: "https://github.com/OldJobobo/omarchy-sakura-mochi-theme")
                    credit("Miasma", creator: "xero", url: "https://github.com/xero/miasma.nvim")
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
