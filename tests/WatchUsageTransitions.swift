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
        // Only Codex quota is accepted; activity providers are unrelated.
        assert(!cache.receive(["schema":1,"selectionRevision":1,"sourceID":source,
            "allowances":[reading("claude",20)]],authoritative:true,now:now))
        assert(cache.receive(["schema":1,"selectionRevision":2,"sourceID":source,
            "allowances":[reading("codex",70)]],authoritative:true,now:now))
        assert(cache.selected(at:now)?.remaining == 70)
        assert(!cache.receive(["schema":1,"selectionRevision":1,"sourceID":source,
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
            "observedAt":1800000010.0,"allowances":[reading("codex",50,1800000010)]]
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
        assert(windows.selected(at:now)?.remaining == 1)
        assert(windows.selected(at:later)?.remaining == 70)
        assert(windows.selected(at:now.addingTimeInterval(90000))?.available(at:now.addingTimeInterval(90000)) == false)
        let name = "paceman-usage-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        // Preserve the Codex cache written by the released Watch app.
        let saved = try decode(reading("codex",70))
        defaults.set(try JSONEncoder().encode(saved),forKey:WatchAllowanceSnapshot.storageKey)
        assert(WatchUsageState.load(defaults:defaults).selected(at:now) == saved)
        assert(cache.receive(["schema":1,"selectionRevision":3,"sourceID":other,
            "observedAt":1800000000.0,"allowances":[]],authoritative:true,now:later))
        assert(!cache.receive(bundle,authoritative:false,now:later))
        // After configuration, both computers deliver directly to the Watch;
        // there are no further phone callbacks in this offline-first scenario.
        func configuration(_ ids: [String], revision: Int, snapshots: [String: Any] = [:]) -> [String: Any] {
            ["schema":1, "selectionRevision":revision,  "sourceIDs":ids, "sources":snapshots]
        }
        func push(_ id: String, revision: Int = 4, at: Double, values: [[String: Any]]) -> [String: Any] {
            ["schema":2, "selectionRevision":revision, "sourceID":id, "observedAt":at, "allowances":values]
        }
        var multi = WatchUsageState()
        assert(multi.receive(configuration([source,other],revision:4),authoritative:true,now:now))
        assert(multi.receive(push(source,at:1800000000,values:[reading("codex",70)]),authoritative:false,now:later))
        assert(multi.receive(push(other,at:1800000010,values:[reading("codex",40,1800000010)]),authoritative:false,now:later))
        assert(multi.selected(at:later)?.remaining == 40)
        // A reconnecting computer's newer envelope carries an older quota.
        assert(multi.receive(push(source,at:1800000011,values:[reading("codex",99)]),authoritative:false,now:later))
        assert(multi.selected(at:later)?.remaining == 40)
        assert(multi.receive(push(source,at:1800000012,values:[]),authoritative:false,now:later))
        assert(multi.selected(at:later)?.remaining == 40)
        assert(!multi.receive(push(other,at:1800000001,values:[reading("codex",99,1800000001)]),authoritative:false,now:later))
        // A delayed phone snapshot cannot roll back the Watch's newer direct reading.
        assert(multi.receive(configuration([source,other],revision:4,snapshots:[source:["observedAt":1800000013.0,"allowances":[]],other:["observedAt":1800000000.0,"allowances":[reading("codex",99)]]]),authoritative:true,now:later))
        assert(multi.selected(at:later)?.remaining == 40)
        let unpaired = "cccccccc-2222-4333-8444-555555555555"
        assert(!multi.receive(push(unpaired,at:1800000014,values:[reading("codex",1,1800000014)]),authoritative:false,now:later))
        assert(!multi.receive(push(other,revision:3,at:1800000014,values:[reading("codex",1,1800000014)]),authoritative:false,now:later))
        assert(!multi.receive(configuration([source],revision:4),authoritative:true,now:later))
        multi.save(defaults:defaults)
        assert(WatchUsageState.load(defaults:defaults) == multi)
        assert(multi.receive(push(source,at:1800000015,values:[reading("codex",30,1800000015)]),authoritative:false,now:later))
        assert(multi.selected(at:now.addingTimeInterval(15))?.remaining == 30)
        // Removing the freshest source exposes the other source's cache and
        // prevents delayed pushes from restoring removed data.
        assert(multi.receive(configuration([other],revision:5),authoritative:true,now:later))
        assert(multi.selected(at:later)?.remaining == 40)
        assert(!multi.receive(push(source,revision:5,at:1800000016,values:[reading("codex",1,1800000016)]),authoritative:false,now:later))
        assert(multi.receive(configuration([],revision:6),authoritative:true,now:later))
        assert(multi.selected(at:later) == nil)
        assert(!multi.receive(push(other,revision:6,at:1800000016,values:[reading("codex",1,1800000016)]),authoritative:false,now:later))
        // Migration keeps a newer legacy Watch cache when phone history is absent.
        var upgrade = WatchUsageState(sourceID:source, readings:[try decode(reading("codex",33))])
        assert(upgrade.receive(configuration([source,other],revision:4),authoritative:true,now:now))
        assert(upgrade.selected(at:now)?.remaining == 33)
        // Window expiry can move to a different cached source without a new push.
        assert(upgrade.receive(push(other,at:1800000001,values:[fiveHour.merging(["updatedAt":1800000001.0]) { _, new in new }]),authoritative:false,now:later))
        assert(upgrade.selected(at:now.addingTimeInterval(2))?.remaining == 1)
        assert(upgrade.selected(at:later)?.remaining == 33)
        let beforeInvalid = upgrade
        assert(!upgrade.receive(configuration([source,other],revision:4,snapshots:[other:["observedAt":1800001000.0,"allowances":[]]]),authoritative:true,now:later))
        assert(upgrade == beforeInvalid)
        print("watch usage transitions passed")
    }
}
