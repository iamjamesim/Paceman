import SwiftUI

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
