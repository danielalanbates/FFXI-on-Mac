// All rights reserved. Copyright (c) 2026 Bates LLC / Daniel Bates.
import Foundation

extension Headless {
    /// Offline values only: no install discovery, account reads, windows or network requests.
    @MainActor static func runServerCatalogSelfTest() -> Never {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { results.append((name, ok)) }
        let phoenix = Server.builtins.first { $0.name == "Phoenix XI" }
        check("Phoenix is catalogued once as unverified LSB", Server.builtins.filter { $0.name == "Phoenix XI" }.count == 1
              && phoenix?.codebase == .landSandBoat && phoenix?.verified == false)
        check("Phoenix official signup and install information; one client only", phoenix?.accountURL == "https://phoenix-xi.com/register"
              && phoenix?.installURL == "https://phoenix-xi.com/getting-started" && phoenix?.maxClients == 1
              && phoenix?.createsAccountAtLogin == false)
        let a = Server(name: "Alpha", host: "example.invalid", bootProfile: "a.ini", verified: false, note: "", population: 10, pinned: true)
        var b = a; b.name = "Beta"; b.population = 20; b.pinned = false
        var c = a; c.name = "Charlie"; c.population = 0; c.pinned = false
        var local = a; local.name = "Local"; local.local = true; local.population = 99999
        let list = [local, c, a, b]
        func names(_ live: [String: Int] = [:]) -> [String] { Server.ordered(list, populations: live).map(\.name) }
        check("descending offline estimates, pin ignored, local last", names() == ["Beta", "Alpha", "Charlie", "Local"])
        check("live count overrides larger offline estimate", names(["Alpha": 30]) == ["Alpha", "Beta", "Charlie", "Local"])
        check("live zero replaces estimate; ties alphabetical", names(["Beta": 0]) == ["Alpha", "Beta", "Charlie", "Local"])
        check("bad live counts fall back instead of corrupting order", names(["Alpha": -1, "Beta": 1000001]) == names())
        check("built-in fallback begins Horizon, Phoenix, CatsEye", Array(Server.ordered(Server.builtins, populations: [:]).prefix(3)).map(\.name)
              == ["HorizonXI", "Phoenix XI", "CatsEyeXI"])
        var edited = Server.builtins.first { $0.name == "HorizonXI" }!
        edited.host = "edited.example.invalid"; edited.dataPath = "/synthetic/world"; edited.population = 999999; edited.pinned = true
        let merged = ServerStore.merge(saved: [edited])
        check("upgrade inserts Phoenix without losing edited hosts or paths", merged.filter { $0.name == "Phoenix XI" }.count == 1
              && merged.first { $0.name == "HorizonXI" }?.host == edited.host
              && merged.first { $0.name == "HorizonXI" }?.dataPath == edited.dataPath)
        check("upgrade refreshes old Discord-sized ranking", merged.first { $0.name == "HorizonXI" }?.population == 1496)
        if let phoenix {
            var x = PrimaryInputs(); x.world = phoenix.name; x.launchUnavailableReason = phoenix.launchUnavailableReason
            let d = Primary.decide(x)
            check("ready files cannot offer Phoenix Play", d.action == .serverInfo && d.enabled && d.label == "Server Info")
            x.hasInstall = false; x.accountNeeded = true
            check("no install cannot offer unsupported setup or account prompt", Primary.decide(x).action == .serverInfo)
            check("headless fixer cannot bypass pending integration", !PrimaryFixer.isHeadlessFixable(d.action))
            check("Phoenix guide and voice are not implicitly allowed", !Guide.allowed(by: AddonPolicies.policy(for: phoenix))
                  && !Narration.allowed(by: AddonPolicies.policy(for: phoenix)))
            let saved = try? JSONEncoder().encode(phoenix)
            let restored = saved.flatMap { try? JSONDecoder().decode(Server.self, from: $0) }
            check("persisted Phoenix retains launch restriction", restored?.launchUnavailableReason != nil)
            x.hasInstall = true; x.runningHere = true
            check("existing session still offers Stop", Primary.decide(x).action == .stop)
        }
        func parse(_ text: String, _ key: String? = nil) -> Int? { ServerFeeds.parsePopulation(Data(text.utf8), key: key) }
        check("integer and nested public counters", parse(" 1496\n") == 1496 && parse(#"{"stats":{"online":21}}"#, "stats.online") == 21)
        check("zero online is valid", parse(#"{"playerCount":0}"#, "playerCount") == 0)
        check("error pages and absent keys rejected", parse("<html>403</html>") == nil && parse("{}", "playerCount") == nil)
        check("booleans, fractions, negative and huge counters rejected", parse(#"{"n":true}"#, "n") == nil
              && parse(#"{"n":1.5}"#, "n") == nil && parse("-1") == nil && parse("1000001") == nil)
        for (name, ok) in results { print("\(ok ? "PASS" : "FAIL") \(name)") }
        let failures = results.filter { !$0.1 }.count
        print("\(results.count - failures)/\(results.count) server catalog checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
