import Foundation

@main
struct WatchUsageTransitions {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let source = "aaaaaaaa-2222-4333-8444-555555555555"
        func reading(_ provider: String, _ left: Int, _ updated: Double = 1800000000) -> [String: Any] {
            ["provider":provider,"remaining":left,"window":1,"updatedAt":updated,"resetsAt":1800086400.0,"windowDurationMins":10080]
        }
        func decode(_ value: [String:Any]) throws -> WatchAllowanceSnapshot {
            try JSONDecoder().decode(WatchAllowanceSnapshot.self, from: JSONSerialization.data(withJSONObject:value))
        }
        var cache = WatchUsageState()
        // Old phones remain decodable, but a saved Claude choice never becomes a Codex reading.
        assert(cache.receive(["schema":1,"selectedProvider":"claude","selectionRevision":1,"sourceID":source,
            "allowances":[reading("codex",70),reading("claude",20)]],authoritative:true,now:now))
        assert(cache.selected(at:now) == nil)
        assert(cache.reading(for:"claude",at:now) == nil)
        assert(cache.summaries(at:now).map(\.provider) == ["codex"])
        assert(cache.readings.count == 1)
        assert(!cache.receive(["schema":1,"selectionRevision":1,"sourceID":source,
            "allowance":reading("claude",19,1800000001)],authoritative:false,now:now))
        assert(cache.receive(["schema":1,"selectedProvider":"codex","selectionRevision":2,"sourceID":source,
            "allowances":[reading("codex",70)]],authoritative:true,now:now))
        assert(cache.selected(at:now)?.remaining == 70)
        assert(!cache.receive(["schema":1,"selectedProvider":"claude","selectionRevision":1,"sourceID":source,
            "allowances":[reading("claude",99)]],authoritative:true,now:now))
        assert(!cache.receive(["schema":1,"selectionRevision":1,"sourceID":source,
            "allowance":reading("codex",99)],authoritative:false,now:now))
        let other = "bbbbbbbb-2222-4333-8444-555555555555"
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":other,
            "allowance":reading("codex",99)],authoritative:false,now:now))
        assert(cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,
            "allowance":reading("codex",60,1800000001)],authoritative:false,now:now))
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,
            "allowance":reading("codex",99,1799999900)],authoritative:false,now:now))
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,
            "allowance":reading("codex",99,1800001000)],authoritative:false,now:now))
        var session = reading("codex",1,1800000002)
        session["window"] = 2; session["windowDurationMins"] = 300
        assert(cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,
            "allowance":session],authoritative:false,now:now))
        assert(cache.selected(at:now.addingTimeInterval(2))?.remaining == 1)
        session["remaining"] = 80; session["updatedAt"] = 1800000003.0; session["windowDurationMins"] = 60
        assert(cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,
            "allowance":session],authoritative:false,now:now))
        assert(cache.readings.count == 2)
        assert(cache.readings.first { $0.window == 2 }?.windowDurationMins == 60)
        assert(cache.selected(at:now.addingTimeInterval(3))?.remaining == 60)
        session["updatedAt"] = 1800000001.0; session["windowDurationMins"] = 300
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,
            "allowance":session],authoritative:false,now:now))
        let later = now.addingTimeInterval(10)
        let bundle: [String:Any] = ["schema":2,"selectionRevision":2,"sourceID":source,
            "observedAt":1800000010.0,"allowances":[reading("codex",50,1800000010),reading("claude",10,1800000010)]]
        assert(cache.receive(bundle,authoritative:false,now:later))
        assert(cache.readings.count == 1 && cache.selected(at:later)?.remaining == 50)
        assert(!cache.receive(["schema":2,"selectionRevision":2,"sourceID":source,
            "observedAt":1800000011.0,"allowances":"malformed"],authoritative:false,now:later))
        assert(!cache.receive(["schema":2,"selectionRevision":2,"sourceID":source,"allowances":[]],authoritative:false,now:later))
        assert(!cache.receive(["schema":2,"selectionRevision":2,"sourceID":source,
            "observedAt":1800001000.0,"allowances":[]],authoritative:false,now:later))
        // A newer envelope cannot roll back a fresher reading from phone fallback.
        assert(cache.receive(["schema":2,"selectionRevision":2,"sourceID":source,
            "observedAt":1800000011.0,"allowances":[reading("codex",99)]],authoritative:false,now:later))
        assert(cache.selected(at:later)?.remaining == 50)
        // A complete clear still removes signed-out windows, and rejects delayed data.
        assert(cache.receive(["schema":2,"selectionRevision":2,"sourceID":source,
            "observedAt":1800000012.0,"allowances":[]],authoritative:false,now:later))
        assert(cache.readings.isEmpty)
        assert(!cache.receive(bundle,authoritative:false,now:later))
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,
            "allowance":reading("codex",99)],authoritative:false,now:later))
        var fiveHour = reading("codex",1)
        fiveHour["window"] = 2; fiveHour["windowDurationMins"] = 300; fiveHour["resetsAt"] = 1800000005.0
        let windows = WatchUsageState(readings:[try decode(reading("codex",70)),try decode(fiveHour)])
        assert(windows.reading(for:"codex",at:now)?.remaining == 1)
        assert(windows.reading(for:"codex",at:later)?.remaining == 70)
        assert(windows.selected(at:now.addingTimeInterval(90000))?.available(at:now.addingTimeInterval(90000)) == false)
        let name = "paceman-usage-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let legacy = WatchUsageState(selectedProvider:"claude", readings:[try decode(reading("codex",70)),try decode(reading("claude",20))])
        defaults.set(try JSONEncoder().encode(legacy),forKey:WatchUsageState.storageKey)
        let migrated = WatchUsageState.load(defaults:defaults)
        assert(migrated.selected(at:now) == nil && migrated.readings.map(\.provider) == ["codex"])
        let saved = try JSONDecoder().decode(WatchUsageState.self,from:defaults.data(forKey:WatchUsageState.storageKey)!)
        assert(saved == migrated)
        assert(cache.receive(["schema":1,"selectedProvider":"codex","selectionRevision":3,"sourceID":other,
            "observedAt":1800000000.0,"allowances":[]],authoritative:true,now:later))
        assert(!cache.receive(bundle,authoritative:false,now:later))
        print("watch usage transitions passed")
    }
}
