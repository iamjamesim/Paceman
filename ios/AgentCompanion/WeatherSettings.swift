import SwiftUI
import MapKit
import Combine

struct WeatherSettings: View {
    @ObservedObject var weather: PhoneWeather
    let theme: CompanionTheme
    var finishSetup: (() -> Void)? = nil
    @State private var choosingPlace = false

    private var location: String {
        weather.preferences.enabled ? weather.preferences.place?.name ?? "Current location" : "Off"
    }

    var body: some View {
        Form {
            Section {
                if finishSetup != nil {
                    Text("Choose your current location or a place to show weather on your watch.")
                        .foregroundStyle(theme.secondaryInk)
                }
                Menu {
                    Button { weather.choose(enabled: false) } label: {
                        choice("Off", selected: !weather.preferences.enabled)
                    }
                    Button { weather.choose(enabled: true) } label: {
                        choice("Current location", selected: weather.preferences.enabled && weather.preferences.place == nil)
                    }
                    if let place = weather.preferences.place, weather.preferences.enabled {
                        Label(place.name, systemImage: "checkmark")
                    }
                    Button("Choose a place…") { choosingPlace = true }
                } label: {
                    HStack {
                        Text("Location").foregroundStyle(theme.ink)
                        Spacer(minLength: 16)
                        Text(location).multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let issue = weather.locationIssue {
                        if issue == .denied {
                            Text(settingsGuidance)
                        } else {
                            Text(issue.guidance)
                        }
                        if issue == .permissionNeeded {
                            Button("Allow location access") { weather.requestLocationAccess() }.foregroundStyle(theme.tint)
                        }
                    } else if weather.preferences.enabled {
                        if let message = weather.message {
                            Text(message)
                        } else if weather.preferences.place == nil {
                            if weather.backgroundLocationAvailable {
                                Text("Weather follows your location, including in the background.")
                            } else {
                                Text("Open Paceman to update your location, or [enable background updates](paceman-weather://background-location).")
                                    .environment(\.openURL, OpenURLAction { _ in
                                        weather.requestBackgroundLocation()
                                        return .handled
                                    })
                            }
                        }
                    }
                }.foregroundStyle(theme.secondaryInk)
            }
            if weather.preferences.enabled {
                Section {
                    Picker("Temperature", selection: Binding(get: { weather.preferences.units }, set: { weather.setUnits($0) })) {
                        ForEach(WeatherUnits.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    attribution
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden).background(theme.canvas).foregroundStyle(theme.ink)
        .navigationTitle(finishSetup == nil ? "Weather" : "Watch weather")
        .navigationBarTitleDisplayMode(.inline).tint(theme.tint)
        .safeAreaInset(edge: .bottom) {
            if let finishSetup {
                CompanionButton(title: weather.preferences.enabled ? "Finish setup" : "Skip weather",
                                theme: theme, action: finishSetup)
                    .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 12)
                    .background(theme.canvas)
            }
        }
        .sheet(isPresented: $choosingPlace) {
            WeatherPlaceSearch(weather: weather, theme: theme)
        }
    }

    private var settingsGuidance: AttributedString {
        var text = AttributedString("Location access is off. Enable it in Settings or choose a place.")
        if let range = text.range(of: "Settings") {
            text[range].link = URL(string: UIApplication.openSettingsURLString)
            text[range].foregroundColor = theme.tint
        }
        return text
    }

    private var attribution: some View {
        Link(destination: weather.attribution?.legalPageURL ?? URL(string: "https://weatherkit.apple.com/legal-attribution.html")!) {
            VStack(spacing: 4) {
                if let attribution = weather.attribution {
                    AsyncImage(url: theme.dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL) { image in
                        image.resizable().scaledToFit().frame(height: 16)
                    } placeholder: { Text("Weather").font(.system(size: 16, weight: .medium)) }
                } else {
                    Text("Weather").font(.system(size: 16, weight: .medium))
                }
                Text("Other data sources").font(.caption2).underline()
            }
            .foregroundStyle(theme.dark ? Color.white : Color.black)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Apple Weather attribution")
    }

    @ViewBuilder private func choice(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

private struct WeatherPlaceSearch: View {
    @ObservedObject var weather: PhoneWeather
    let theme: CompanionTheme
    @StateObject private var search = WeatherPlaceSearchModel()
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(search.results, id: \.self) { result in
                    Button {
                        search.select(result) { place in
                            weather.choose(enabled: true, place: place)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).foregroundStyle(theme.ink)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle).font(.subheadline).foregroundStyle(theme.secondaryInk)
                            }
                        }.padding(.vertical, 4)
                    }
                    .disabled(search.resolving)
                    .listRowBackground(Color.clear)
                }
                if let message = search.message {
                    Text(message).font(.subheadline).foregroundStyle(theme.secondaryInk)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(theme.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                if search.searching || search.resolving {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Searching places")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City or place")
            .searchFocused($searchFocused)
            .autocorrectionDisabled()
            .onChange(of: query) { _, value in search.update(value) }
            .onSubmit(of: .search) { search.update(query, immediately: true) }
            .navigationTitle("Choose a place").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .tint(theme.tint)
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .onDisappear { search.cancel() }
    }
}

@MainActor
final class WeatherPlaceSearchModel: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var searching = false
    @Published private(set) var resolving = false
    @Published private(set) var message: String?
    private var completer: MKLocalSearchCompleter?
    private var pending: Task<Void, Never>?
    private var resolution: MKLocalSearch?
    private var generation = UUID()

    static func normalizedQuery(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count >= 2 ? value : nil
    }

    func cancel() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        completer?.delegate = nil
        completer?.cancel()
        completer = nil
        resolution?.cancel()
        resolution = nil
        searching = false
        resolving = false
    }

    func update(_ text: String, immediately: Bool = false) {
        cancel()
        results = []
        message = nil
        guard let query = Self.normalizedQuery(text) else { return }
        pending = Task { [weak self] in
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(350)) }
                try Task.checkCancellation()
                guard let self else { return }
                let completer = MKLocalSearchCompleter()
                completer.resultTypes = .address
                completer.addressFilter = MKAddressFilter(including: [.locality, .subLocality])
                completer.delegate = self
                self.completer = completer
                self.searching = true
                completer.queryFragment = query
            } catch { }
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard completer === self.completer else { return }
        results = completer.results
        searching = false
        message = results.isEmpty ? "No places found." : nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard completer === self.completer else { return }
        searching = false
        message = "Couldn’t search places. Try again."
    }

    func select(_ completion: MKLocalSearchCompletion, onSelect: @escaping (WeatherPlace) -> Void) {
        guard !resolving else { return }
        message = nil
        resolving = true
        let epoch = generation
        let request = MKLocalSearch.Request(completion: completion)
        let lookup = MKLocalSearch(request: request)
        resolution = lookup
        pending = Task { [weak self] in
            do {
                let response = try await lookup.start()
                guard let self, self.generation == epoch, !Task.isCancelled else { return }
                guard let item = response.mapItems.first, let zone = item.timeZone else {
                    self.resolving = false
                    self.message = "Couldn’t load that place. Try again."
                    return
                }
                let coordinate = item.placemark.coordinate
                let name = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
                self.resolving = false
                onSelect(WeatherPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude, timeZone: zone.identifier))
            } catch {
                guard let self, self.generation == epoch, !Task.isCancelled else { return }
                self.resolving = false
                self.message = "Couldn’t load that place. Try again."
            }
        }
    }
}
