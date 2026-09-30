import Combine
import CoreLocation
import Foundation
import WeatherKit
import BackgroundTasks
import Network
import UIKit

struct WeatherPlace: Codable, Equatable, Identifiable {
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZone: String
    var id: String { "\(latitude),\(longitude)" }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

enum WeatherUnits: String, Codable, CaseIterable {
    case system, celsius, fahrenheit
    var title: String { switch self { case .system: return "Match iPhone"; case .celsius: return "°C"; case .fahrenheit: return "°F" } }
    var usesFahrenheit: Bool {
        switch self {
        case .fahrenheit: return true
        case .celsius: return false
        case .system:
            if #available(iOS 26.0, *) { return UnitTemperature(forLocale: .current, usage: .weather) == .fahrenheit }
            return Locale.current.measurementSystem == .us
        }
    }
}

struct WeatherPreferences: Codable, Equatable {
    var enabled = false
    var place: WeatherPlace? // nil means current location
    var units = WeatherUnits.system
    static func key(_ id: String) -> String { "watch-weather." + id }
    static func load(_ id: String) -> Self {
        guard let data = UserDefaults.standard.data(forKey: key(id)),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(_ id: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(id)) }
    }
    static func remove(_ id: String) { UserDefaults.standard.removeObject(forKey: key(id)) }
}

/// Values stay in Celsius on disk. Conversion happens only at the device boundary.
struct WatchWeather: Codable, Equatable {
    var observedAt: Date
    var dayExpiresAt: Date
    var temperature: Double
    var high: Double
    var low: Double
    var code: UInt8
    var night: Bool
    var location: String
    var valid: Bool {
        [temperature, high, low].allSatisfy { $0.isFinite && (-90...65).contains($0) }
            && low <= high && code <= 99 && observedAt.timeIntervalSince1970 >= 1704067200
            && dayExpiresAt > observedAt && dayExpiresAt.timeIntervalSince1970 <= 3155759999
    }
    func usable(at now: Date) -> Bool { valid && observedAt <= now && now.timeIntervalSince(observedAt) < 10800 }
    func degrees(_ value: Double, fahrenheit: Bool) -> Int16 {
        Int16(clamping: Int((fahrenheit ? value * 9 / 5 + 32 : value).rounded()))
    }
}

enum WeatherLocationIssue: Equatable {
    case permissionNeeded, denied, restricted, unavailable
    static func resolve(preferences: WeatherPreferences, authorization: CLAuthorizationStatus, unavailable: Bool) -> Self? {
        guard preferences.enabled, preferences.place == nil else { return nil }
        switch authorization {
        case .notDetermined: return .permissionNeeded
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorizedAlways, .authorizedWhenInUse: return unavailable ? .unavailable : nil
        @unknown default: return .unavailable
        }
    }
    var summary: String {
        switch self {
        case .permissionNeeded, .denied: return "Location access needed"
        case .restricted: return "Location restricted"
        case .unavailable: return "Location unavailable"
        }
    }
    var guidance: String {
        switch self {
        case .permissionNeeded: return "Allow location access to use your current location."
        case .denied: return "Location access is off. Enable it in Settings or choose a place."
        case .restricted: return "Location access is restricted on this iPhone. Choose a place instead."
        case .unavailable: return "Location is unavailable. We’ll try again."
        }
    }
}

enum WeatherResponseFailure: String, Error {
    case timeZoneMissing, forecastDayMissing, conditionUnsupported, invalidValues, observationInFuture, observationExpired
}

enum WeatherDiagnostics {
    static func describe(_ error: Error) -> String {
        if let failure = error as? WeatherResponseFailure { return "Response rejected: " + failure.rawValue }
        if let failure = error as? WeatherError, failure == .permissionDenied { return "WeatherKit authorization denied" }
        let allowedDomains: Set<String> = [NSURLErrorDomain, NSCocoaErrorDomain, "kCLErrorDomain",
            "WeatherKit.WeatherError", "WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors",
            "WeatherDaemon.WDSJWTAuthenticator.Errors", "WeatherDaemon.WDSWeatherServiceListener.Errors"]
        var value = error as NSError
        var parts: [String] = []
        for _ in 0..<3 {
            let domain = allowedDomains.contains(value.domain) ? value.domain : "Unclassified error"
            parts.append("\(domain) (\(value.code))")
            guard let next = value.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            value = next
        }
        // Never expose localized descriptions, userInfo, URLs, coordinates or tokens.
        return parts.joined(separator: " → ")
    }
}

private struct WeatherCache: Codable {
    var selection: String
    var fetchedAt: Date
    var weather: WatchWeather
    var place: WeatherPlace?
    var accuracy: Double?
    var expiresAt: Date?
}

enum WeatherRefreshPolicy {
    static func accepts(_ location: CLLocation, now: Date) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 20_000
            && now.timeIntervalSince(location.timestamp) >= -5
            && now.timeIntervalSince(location.timestamp) <= 300
    }
    static func moved(_ location: CLLocation, from previous: CLLocation, accuracy: Double) -> Bool {
        location.distance(from: previous) > max(5_000, location.horizontalAccuracy + accuracy)
    }
    static func mayRequest(now: Date, priority: Bool, foreground: Bool, retryAfter: Date?, lastBackgroundFetch: Date?) -> Bool {
        if priority { return true }
        if let retryAfter { return now >= retryAfter }
        return foreground || lastBackgroundFetch.map { now.timeIntervalSince($0) >= 900 } != false
    }
    static func retryDelay(failures: Int) -> TimeInterval {
        min(900, 60 * pow(2, Double(max(0, min(failures - 1, 4)))))
    }
    static func refreshDate(now: Date, currentExpiry: Date, dailyExpiry: Date, dayExpiry: Date) -> Date {
        // Provider expiry governs freshness. The floor only prevents request storms.
        min(dayExpiry, max(now.addingTimeInterval(300), min(currentExpiry, dailyExpiry, now.addingTimeInterval(1800))))
    }
}

@MainActor
final class PhoneWeather: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var preferences = WeatherPreferences()
    @Published private(set) var weather: WatchWeather?
    @Published private(set) var diagnostic = "No weather request yet"
    @Published private(set) var message: String?
    @Published private(set) var authorization = CLAuthorizationStatus.notDetermined
    @Published private(set) var locationUnavailable = false
    @Published private(set) var attribution: WeatherAttribution?
    var onChange: ((WatchWeather?, Bool) -> Void)?
    private var previewing = false
    private var watchID: String?
    private let locationManager = CLLocationManager()
    private var network: NWPathMonitor?
    private var online = true
    private var latestLocation: CLLocation?
    private var lastLocationAttempt: Date?
    private var lastBackgroundFetch: Date?
    private var inFlightLocation: CLLocation?
    private var failures = 0
    private var retryAfter: Date?
    private var monitoring = false
    private var scheduledRefresh: Date?
    private var locationPriority = false
    private var pendingPriority = false
    private var backgroundWork = UIBackgroundTaskIdentifier.invalid
    static let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "ai.paceman.app") + ".weather"
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastAttempt: Date?
    private var cache: WeatherCache?
    private var waitingForLocation = false
    private var locationTimeout: Task<Void, Never>?
    private var foreground = false
    private var updatesEnabled = false
    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("watch-weather.json")
    }
    private var selection: String { preferences.place?.id ?? "current" }
    var locationIssue: WeatherLocationIssue? {
        .resolve(preferences: preferences, authorization: authorization, unavailable: locationUnavailable)
    }
    var summary: String { locationIssue?.summary ?? (preferences.enabled ? preferences.place?.name ?? "Current location" : "Off") }

    override init() {
        super.init()
        authorization = locationManager.authorizationStatus
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        if let data = try? Data(contentsOf: cacheURL), let value = try? JSONDecoder().decode(WeatherCache.self, from: data), value.weather.valid { cache = value }
    }

    func bind(watchID: String?, updates: Bool) {
        let changed = self.watchID != watchID
        let resumed = !updatesEnabled && updates
        updatesEnabled = updates
        if changed {
            cancel()
            self.watchID = watchID
            message = nil
            preferences = watchID.map(WeatherPreferences.load) ?? WeatherPreferences()
            latestLocation = nil
            restoreCache()
        }
        reconcileMonitoring()
        if !updates { cancel() }
        if changed || resumed { refreshIfNeeded(priority: true) }
    }

    func setForeground(_ value: Bool) {
        let opening = value && !foreground
        foreground = value
        if opening {
            lastLocationAttempt = nil
            retryAfter = nil
            refreshIfNeeded(priority: true)
        } else if !value { scheduleBackgroundRefresh() }
    }

    deinit { network?.cancel() }

    var backgroundLocationAvailable: Bool { authorization == .authorizedAlways }
    func requestBackgroundLocation() {
        guard preferences.enabled, preferences.place == nil,
              authorization == .authorizedWhenInUse else { return }
        let key = "weather-background-location-requested"
        if UserDefaults.standard.bool(forKey: key) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } else {
            UserDefaults.standard.set(true, forKey: key)
            locationManager.requestAlwaysAuthorization()
        }
    }

    private var enabled: Bool { watchID != nil && preferences.enabled && updatesEnabled && !previewing }

    private func reconcileMonitoring() {
        if enabled && network == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let recovered = !self.online && available
                    self.online = available
                    if recovered { self.retryAfter = nil; self.refreshIfNeeded(priority: true) }
                }
            }
            monitor.start(queue: DispatchQueue(label: "paceman.weather.network"))
            network = monitor
        } else if !enabled {
            network?.cancel()
            network = nil
            online = true
        }
        let shouldMonitor = enabled && preferences.place == nil && authorization == .authorizedAlways
        if shouldMonitor != monitoring {
            monitoring = shouldMonitor
            if shouldMonitor {
                if CLLocationManager.significantLocationChangeMonitoringAvailable() { locationManager.startMonitoringSignificantLocationChanges() }
                locationManager.startMonitoringVisits()
            } else {
                locationManager.stopMonitoringSignificantLocationChanges()
                locationManager.stopMonitoringVisits()
            }
        }
        scheduleBackgroundRefresh()
    }

    private func beginWork() {
        guard backgroundWork == .invalid else { return }
        backgroundWork = UIApplication.shared.beginBackgroundTask(withName: "Watch weather") { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }
    private func endWork() {
        if backgroundWork != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundWork)
            backgroundWork = .invalid
        }
    }

    static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundIdentifier, using: .main) { task in
            Task { @MainActor in
                guard let weather = PushCoordinator.shared.model?.weather else { task.setTaskCompleted(success: false); return }
                let work = Task { @MainActor in
                    weather.scheduledRefresh = nil
                    weather.refreshIfNeeded()
                    while weather.task != nil || weather.waitingForLocation {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                    weather.scheduleBackgroundRefresh()
                    task.setTaskCompleted(success: weather.message == nil && !weather.locationUnavailable)
                }
                task.expirationHandler = {
                    work.cancel()
                    Task { @MainActor in weather.cancel(); task.setTaskCompleted(success: false) }
                }
            }
        }
    }

    private func scheduleBackgroundRefresh() {
        guard enabled else {
            scheduledRefresh = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundIdentifier)
            return
        }
        if let scheduledRefresh, scheduledRefresh > Date() { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundIdentifier)
        request.earliestBeginDate = max(Date().addingTimeInterval(900), cache?.expiresAt ?? Date())
        do { try BGTaskScheduler.shared.submit(request); scheduledRefresh = request.earliestBeginDate }
        catch { /* Existing foreground, Bluetooth and push opportunities remain available. */ }
    }

    func choose(enabled: Bool, place: WeatherPlace? = nil) {
        guard let watchID else { return }
        cancel()
        locationUnavailable = false
        preferences.enabled = enabled
        preferences.place = place
        preferences.save(watchID)
        // A location change never carries the previous place's weather forward.
        cache = nil
        try? FileManager.default.removeItem(at: cacheURL)
        lastAttempt = nil
        latestLocation = nil
        lastLocationAttempt = nil
        retryAfter = nil
        failures = 0
        weather = nil
        message = nil
        publish()
        reconcileMonitoring()
        if enabled, place == nil, locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else { refreshIfNeeded(priority: true) }
    }

    func requestLocationAccess() {
        guard preferences.enabled, preferences.place == nil else { return }
        if locationManager.authorizationStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        else { refreshIfNeeded() }
    }

    func setUnits(_ units: WeatherUnits) {
        guard let watchID else { return }
        preferences.units = units
        preferences.save(watchID)
        publish()
    }

    private func cancel() {
        inFlightLocation = nil
        pendingPriority = false
        endWork()
        generation = UUID()
        task?.cancel(); task = nil
        locationTimeout?.cancel(); locationTimeout = nil
        locationManager.stopUpdatingLocation()
        waitingForLocation = false
    }

    private func restoreCache() {
        // Current-location caches cannot establish where the phone is after restart.
        weather = preferences.enabled && preferences.place != nil && cache?.selection == selection && cache?.weather.usable(at: Date()) == true ? cache?.weather : nil
        publish()
    }

    private func publish() { onChange?(preferences.enabled ? weather : nil, preferences.units.usesFahrenheit) }

    func refreshIfNeeded(priority: Bool = false) {
        guard !previewing else { return }
        applyAuthorization(locationManager.authorizationStatus)
        guard enabled else { return }
        if let weather, !weather.usable(at: Date()) { self.weather = nil; publish() }
        guard locationIssue != .permissionNeeded, locationIssue != .denied, locationIssue != .restricted else { return }
        guard task == nil, !waitingForLocation else { pendingPriority = pendingPriority || priority; return }
        if let place = preferences.place { evaluate(place: place, location: nil, priority: priority); return }
        let now = Date()
        if foreground || authorization == .authorizedAlways {
            if (priority || lastLocationAttempt.map({ now.timeIntervalSince($0) >= 300 }) != false)
                && lastLocationAttempt.map({ now.timeIntervalSince($0) >= 30 }) != false {
                // Location acquisition is independent of whether the forecast cache is fresh.
                lastLocationAttempt = now
                waitingForLocation = true
                locationPriority = priority
                beginWork()
                diagnostic = "Requesting approximate location"
                locationManager.requestLocation()
                locationTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, let self, self.waitingForLocation else { return }
                    self.waitingForLocation = false
                    self.locationUnavailable = true
                    self.diagnostic = "Location request timed out"
                    self.endWork()
                }
                return
            }
        }
        if let location = latestLocation, WeatherRefreshPolicy.accepts(location, now: now) {
            accept(location, priority: priority)
        }
    }

    private func evaluate(place: WeatherPlace, location: CLLocation?, priority: Bool) {
        guard enabled, task == nil else { return }
        let now = Date()
        let sameArea = cache?.selection == selection && (location == nil || cache?.place.map {
            !WeatherRefreshPolicy.moved(location!, from: $0.location, accuracy: cache?.accuracy ?? 0)
        } == true)
        if !sameArea, weather != nil { weather = nil; publish() }
        if sameArea, let cache, cache.weather.usable(at: now), now < cache.weather.dayExpiresAt,
           now < (cache.expiresAt ?? cache.fetchedAt.addingTimeInterval(1800)) {
            if weather == nil { weather = cache.weather; publish() }
            endWork()
            return
        }
        guard online else { endWork(); return }
        guard WeatherRefreshPolicy.mayRequest(now: now, priority: priority, foreground: foreground,
            retryAfter: retryAfter, lastBackgroundFetch: lastBackgroundFetch) else { endWork(); return }
        if !foreground { lastBackgroundFetch = now }
        inFlightLocation = location
        fetch(place)
    }

    private func accept(_ location: CLLocation, priority: Bool) {
        guard enabled, preferences.place == nil, WeatherRefreshPolicy.accepts(location, now: Date()) else { return }
        latestLocation = location
        locationUnavailable = false
        if let active = inFlightLocation, WeatherRefreshPolicy.moved(location, from: active, accuracy: active.horizontalAccuracy) { cancel() }
        guard task == nil else { pendingPriority = pendingPriority || priority; return }
        if let place = cache?.place, !WeatherRefreshPolicy.moved(location, from: place.location, accuracy: cache?.accuracy ?? 0) {
            evaluate(place: place, location: location, priority: priority)
            return
        }
        // Once movement is confirmed, the old city's weather must not look current.
        if weather != nil { weather = nil; publish() }
        guard online else { endWork(); return }
        guard WeatherRefreshPolicy.mayRequest(now: Date(), priority: priority, foreground: foreground,
            retryAfter: retryAfter, lastBackgroundFetch: lastBackgroundFetch) else { endWork(); return }
        beginWork()
        inFlightLocation = location
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            guard epoch == self.generation, !Task.isCancelled else { return }
            self.task = nil
            guard let zone = placemark?.timeZone else {
                self.failed("Couldn’t find weather for this location. We’ll try again.")
                self.endWork()
                return
            }
            self.evaluate(place: WeatherPlace(name: placemark?.locality ?? placemark?.administrativeArea ?? "Current location",
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timeZone: zone.identifier), location: location, priority: priority)
        }
    }

    private func failed(_ text: String) {
        failures += 1
        retryAfter = Date().addingTimeInterval(WeatherRefreshPolicy.retryDelay(failures: failures))
        message = text
    }

    func applyAuthorization(_ status: CLAuthorizationStatus) {
        let changed = authorization != status
        if changed { authorization = status; reconcileMonitoring() }
        guard preferences.enabled, preferences.place == nil else { return }
        if status != .authorizedAlways && status != .authorizedWhenInUse {
            if changed || weather != nil || task != nil || waitingForLocation || cache != nil {
                cancel()
                weather = nil
                cache = nil
                try? FileManager.default.removeItem(at: cacheURL)
                lastAttempt = nil
                latestLocation = nil
                locationUnavailable = false
                message = nil
                publish()
            }
        } else if changed {
            lastAttempt = nil
            lastLocationAttempt = nil
            retryAfter = nil
            locationUnavailable = false
            message = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !previewing else { return }
        applyAuthorization(manager.authorizationStatus)
        refreshIfNeeded()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard waitingForLocation || monitoring else { return }
        let priority = waitingForLocation && locationPriority
        waitingForLocation = false; locationTimeout?.cancel()
        guard let location = locations.last, WeatherRefreshPolicy.accepts(location, now: Date()) else {
            locationUnavailable = true
            diagnostic = "Location fix was missing or too old"
            endWork()
            return
        }
        accept(location, priority: priority)
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard monitoring, visit.departureDate == .distantFuture,
              Date().timeIntervalSince(visit.arrivalDate) < 1800 else { return }
        // Confirm the arrival with a current fix instead of treating delayed visit coordinates as current.
        lastLocationAttempt = nil
        refreshIfNeeded(priority: true)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard waitingForLocation else { return }
        waitingForLocation = false; locationTimeout?.cancel()
        diagnostic = "Location: " + WeatherDiagnostics.describe(error)
        locationUnavailable = true
        endWork()
    }

    private func fetch(_ place: WeatherPlace) {
        beginWork()
        lastAttempt = Date()
        diagnostic = "Requesting current conditions and daily forecast"
        let epoch = generation
        let key = selection
        let requestLocation = inFlightLocation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == self.generation {
                    self.task = nil
                    self.inFlightLocation = nil
                    self.endWork()
                    self.scheduleBackgroundRefresh()
                    if self.pendingPriority {
                        self.pendingPriority = false
                        self.refreshIfNeeded(priority: true)
                    }
                }
            }
            do {
                let (current, daily) = try await WeatherService.shared.weather(for: place.location, including: .current, .daily)
                var calendar = Calendar(identifier: .gregorian)
                guard let zone = TimeZone(identifier: place.timeZone) else { throw WeatherResponseFailure.timeZoneMissing }
                calendar.timeZone = zone
                let now = Date()
                guard let day = daily.forecast.first(where: { calendar.isDate($0.date, inSameDayAs: now) }),
                      let expiry = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { throw WeatherResponseFailure.forecastDayMissing }
                guard let code = Self.code(current.condition) else { throw WeatherResponseFailure.conditionUnsupported }
                let value = WatchWeather(observedAt: current.date, dayExpiresAt: expiry,
                    temperature: current.temperature.converted(to: .celsius).value,
                    high: day.highTemperature.converted(to: .celsius).value, low: day.lowTemperature.converted(to: .celsius).value,
                    code: code, night: !current.isDaylight, location: place.name)
                guard value.valid else { throw WeatherResponseFailure.invalidValues }
                guard value.observedAt <= now else { throw WeatherResponseFailure.observationInFuture }
                guard value.usable(at: now) else { throw WeatherResponseFailure.observationExpired }
                guard epoch == self.generation, !Task.isCancelled else { return }
                self.diagnostic = "Weather received and validated"
                self.weather = value
                self.cache = WeatherCache(selection: key, fetchedAt: now, weather: value, place: place,
                    accuracy: requestLocation?.horizontalAccuracy,
                    expiresAt: WeatherRefreshPolicy.refreshDate(now: now, currentExpiry: current.metadata.expirationDate,
                        dailyExpiry: daily.metadata.expirationDate, dayExpiry: expiry))
                self.failures = 0
                self.retryAfter = nil
                self.message = nil
                if let data = try? JSONEncoder().encode(self.cache) {
                    try? FileManager.default.createDirectory(at: self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: self.cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                self.publish()
                if self.attribution == nil { self.attribution = try? await WeatherService.shared.attribution }
            } catch {
                guard epoch == self.generation, !Task.isCancelled else { return }
                self.diagnostic = WeatherDiagnostics.describe(error)
                self.failed("Couldn’t update weather. We’ll try again.")
            }
        }
    }

    func retryForDiagnostics() {
        guard task == nil, !waitingForLocation else { return }
        lastAttempt = nil
        cache = nil
        retryAfter = nil
        lastLocationAttempt = nil
        refreshIfNeeded(priority: true)
    }

    #if DEBUG
    func showPreview(_ state: String) {
        previewing = true
        preferences.enabled = state != "weather"
        if state == "weather-place" {
            preferences.place = WeatherPlace(name: "San Francisco, California", latitude: 37.77, longitude: -122.42, timeZone: "America/Los_Angeles")
        }
        authorization = .authorizedWhenInUse
        if state == "weather-current" {
            let now = Date()
            weather = WatchWeather(observedAt: now, dayExpiresAt: now.addingTimeInterval(3600), temperature: 15, high: 20, low: 10, code: 0, night: false, location: "Sample place")
            cache = WeatherCache(selection: "current", fetchedAt: now, weather: weather!)
        }
        if state == "weather-denied" { authorization = .denied }
        if state == "weather-permission" { authorization = .notDetermined }
        if state == "weather-unavailable" { locationUnavailable = true }
    }
    #endif

    // Firmware uses WMO weather codes, not WeatherKit's textual conditions.
    static func code(_ condition: WeatherCondition) -> UInt8? {
        switch condition {
        case .clear, .hot, .frigid: return 0
        case .mostlyClear: return 1
        case .partlyCloudy: return 2
        case .cloudy, .mostlyCloudy, .breezy, .windy: return 3
        case .foggy, .haze, .smoky, .blowingDust: return 45
        case .drizzle: return 51
        case .freezingDrizzle: return 56
        case .rain, .sunShowers: return 61
        case .heavyRain, .tropicalStorm, .hurricane: return 65
        case .freezingRain: return 66
        case .snow, .flurries, .sunFlurries: return 71
        case .heavySnow, .blizzard, .blowingSnow: return 75
        case .sleet, .wintryMix: return 77
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .strongStorms: return 95
        case .hail: return 99
        @unknown default: return nil
        }
    }
}
