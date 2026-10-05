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
        assert(cache.receive(["schema":1,"selectedProvider":"codex","selectionRevision":1,"sourceID":source,
            "allowances":[reading("codex",70),reading("claude",20)]],authoritative:true,now:now))
        assert(cache.selected(at:now)?.remaining == 70)
        assert(cache.summaries(at:now).count == 2)
        assert(cache.receive(["schema":1,"selectedProvider":"claude","selectionRevision":2,"sourceID":source,
            "allowances":[reading("codex",70),reading("claude",20)]],authoritative:true,now:now))
        assert(cache.selected(at:now)?.provider == "claude")
        assert(!cache.receive(["schema":1,"selectedProvider":"codex","selectionRevision":1,"sourceID":source,
            "allowances":[reading("codex",99)]],authoritative:true,now:now))
        assert(!cache.receive(["schema":1,"selectionRevision":1,"sourceID":source,"allowance":reading("codex",99)],authoritative:false,now:now))
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,"allowance":reading("codex",99)],authoritative:false,now:now))
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":"bbbbbbbb-2222-4333-8444-555555555555", "allowance":reading("claude",99)],authoritative:false,now:now))
        assert(cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,"allowance":reading("claude",19,1800000001)],authoritative:false,now:now))
        assert(cache.readings.first { $0.provider == "codex" }?.remaining == 70)
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,"allowance":reading("claude",99,1799999900)],authoritative:false,now:now))
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,"allowance":reading("claude",99,1800001000)],authoritative:false,now:now))
        var session = reading("claude",1,1800000002)
        session["window"] = 2; session["windowDurationMins"] = 300
        assert(cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,"allowance":session],authoritative:false,now:now))
        assert(cache.selected(at:now.addingTimeInterval(2))?.remaining == 1)
        session["remaining"] = 80; session["updatedAt"] = 1800000003.0; session["windowDurationMins"] = 60
        assert(cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,"allowance":session],authoritative:false,now:now))
        assert(cache.readings.count == 3)
        assert(cache.readings.first { $0.provider == "claude" && $0.window == 2 }?.windowDurationMins == 60)
        assert(cache.selected(at:now.addingTimeInterval(3))?.remaining == 19)
        session["updatedAt"] = 1800000001.0; session["windowDurationMins"] = 300
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,"allowance":session],authoritative:false,now:now))
        assert(cache.selected(at:now.addingTimeInterval(90000))?.available(at:now.addingTimeInterval(90000)) == false)
        assert(cache.receive(["schema":1,"selectedProvider":"claude","selectionRevision":3,"sourceID":source,"clear":true],authoritative:true,now:now))
        assert(cache.readings.isEmpty)
        assert(!cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,"allowance":reading("claude",99)],authoritative:false,now:now))
        let name = "paceman-usage-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        cache.save(defaults:defaults)
        assert(WatchUsageState.load(defaults:defaults) == cache)
        var independent = WatchUsageState()
        assert(independent.receive(["schema":1,"selectedProvider":"claude","selectionRevision":10,"sourceID":source,
            "observedAt":1800000000.0,"allowances":[reading("codex",70),reading("claude",20)]],authoritative:true,now:now))
        assert(independent.reading(for:"codex",at:now)?.remaining == 70)
        assert(independent.reading(for:"claude",at:now)?.remaining == 20)
        let later = now.addingTimeInterval(10)
        let bundle: [String:Any] = ["schema":2,"selectionRevision":10,"sourceID":source,
            "observedAt":1800000010.0,"allowances":[reading("codex",60,1800000010),reading("claude",10,1800000010)]]
        assert(independent.receive(bundle,authoritative:false,now:later))
        assert(independent.selectedProvider == "claude")
        assert(independent.reading(for:"codex",at:later)?.remaining == 60)
        assert(independent.reading(for:"claude",at:later)?.remaining == 10)
        assert(!independent.receive(["schema":1,"selectedProvider":"claude","selectionRevision":10,"sourceID":source,
            "observedAt":1800000000.0,"allowances":[reading("codex",99)]],authoritative:true,now:later))
        assert(independent.readings.count == 2)
        assert(!independent.receive(["schema":2,"selectionRevision":10,"sourceID":source,
            "observedAt":1800000011.0,"allowances":"malformed"],authoritative:false,now:later))
        assert(!independent.receive(["schema":2,"selectionRevision":10,"sourceID":source,"allowances":[]],authoritative:false,now:later))
        assert(!independent.receive(["schema":2,"selectionRevision":10,"sourceID":source,
            "observedAt":1800001000.0,"allowances":[]],authoritative:false,now:later))
        // Sign-out is a full snapshot removal; delayed phone or push data cannot resurrect it.
        assert(independent.receive(["schema":2,"selectionRevision":10,"sourceID":source,
            "observedAt":1800000011.0,"allowances":[reading("codex",60,1800000010)]],authoritative:false,now:later))
        assert(independent.reading(for:"claude",at:later) == nil)
        assert(!independent.receive(bundle,authoritative:false,now:later))
        assert(!independent.receive(["schema":1,"selectionRevision":10,"sourceID":source,
            "allowance":reading("claude",99)],authoritative:false,now:later))
        independent.save(defaults:defaults)
        assert(WatchUsageState.load(defaults:defaults) == independent)
        var fiveHour = reading("codex",1)
        fiveHour["window"] = 2; fiveHour["windowDurationMins"] = 300; fiveHour["resetsAt"] = 1800000005.0
        let windows = WatchUsageState(readings:[try decode(reading("codex",70)),try decode(fiveHour),try decode(reading("claude",20))])
        assert(windows.reading(for:"codex",at:now)?.remaining == 1)
        assert(windows.reading(for:"codex",at:later)?.remaining == 70)
        assert(windows.reading(for:"claude",at:later)?.remaining == 20)
        assert(windows.reading(for:"other",at:later) == nil)
        let newSource = "bbbbbbbb-2222-4333-8444-555555555555"
        assert(independent.receive(["schema":1,"selectedProvider":"codex","selectionRevision":11,"sourceID":newSource,
            "observedAt":1800000000.0,"allowances":[]],authoritative:true,now:later))
        assert(independent.readings.isEmpty)
        assert(!independent.receive(bundle,authoritative:false,now:later))
        print("watch usage transitions passed")
    }
}
