import SwiftUI

struct CompanionSettings: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    var body: some View {
        List {
            Section {
                NavigationLink(value: FeedDestination.widgets) { Label("Widgets", systemImage: "square.grid.2x2") }
            }.listRowBackground(theme.ink.opacity(0.04))
            Section {
                NavigationLink { TransportDiagnostics(model: model) } label: {
                    Label("Developer tools", systemImage: "wrench.and.screwdriver")
                }.disabled(presentation.preview)
            } footer: { Text("Agent Companion · Prototype") }.listRowBackground(theme.ink.opacity(0.04))
        }.scrollContentBackground(.hidden).background(theme.canvas).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
    }
}

struct WidgetGuide: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var presentation: PresentationModel
    let theme: CompanionTheme
    private var state: CompanionWidgetState {
        var value = presentation.preview ? CompanionWidgetState.sample : model.widgetState
        value.theme = theme
        if presentation.preview { value.sourceName = presentation.displayName(source: nil) }
        return value
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ActivityWidgetFace(state: state).padding(22).frame(height: 176)
                    .background(theme.canvas, in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(theme.ink.opacity(0.17), lineWidth: 0.7))
                    .dynamicTypeSize(.medium)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Widget preview: \(state.shortTitle)")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Home Screen").font(.headline)
                    Text("Touch and hold your Home Screen, choose Edit → Add Widget, then search for Agent Companion. Choose the small or medium widget.")
                        .font(.body).lineSpacing(4).foregroundStyle(theme.ink.opacity(0.65))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Lock Screen").font(.headline)
                    Text("Touch and hold your Lock Screen, choose Customize, then tap the widget area and add Agent Companion.")
                        .font(.body).lineSpacing(4).foregroundStyle(theme.ink.opacity(0.65))
                }
                Text("Widgets show the last received state. iOS controls refresh timing, so they can lag behind the app.")
                    .font(.footnote).lineSpacing(3).foregroundStyle(theme.ink.opacity(0.5))
            }.padding(.horizontal, 26).padding(.vertical, 24)
        }.foregroundStyle(theme.ink).background(theme.canvas).navigationTitle("Widgets").navigationBarTitleDisplayMode(.inline)
    }
}
