// Copyright (c) 2026 Bates LLC. All rights reserved.
import Foundation

/// `--selftest-prefix-scope`: synthetic process groups only. No Wine, process scan, files,
/// accounts or signals. Prefix filtering protects drive-wide operations; client caps continue
/// to count the full list even when a same-world client belongs to another Windows drive.
extension Headless {
    @MainActor static func runPrefixScopeSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        let a = "/fixture/FFXI/Shared Drive"
        let b = "/fixture/FFXI/World Drives/AscensionXI"
        let c = "/fixture/FFXI/World Drives/Gaia XI"
        let snap = LiveClients.parse("""
            991101 991100 .\\bootloader\\horizon-loader.exe --server same.example
            991102 991100 /fixture/x87sidecar-coop --cooperative /fixture/wine .\\bootloader\\horizon-loader.exe --server same.example
            991201 991200 .\\bootloader\\xiloader.exe --server same.example
            991301 991300 .\\Ashita-cli.exe unknown.ini
            991401 991400 C:\\tools\\unknown.exe
            """)
        func infer(_ known: [pid_t: String] = [:], _ env: [pid_t: String] = [:],
                   _ maps: [pid_t: Set<String>] = [:]) -> [pid_t: String] {
            PrefixScope.infer(snap, knownGroups: known, environmentPrefixes: env, mappedPrefixes: maps)
        }
        func scope(_ prefix: String, _ found: [pid_t: String]) -> [LiveClients.Client] {
            PrefixScope.clients(snap.clients, prefix: URL(fileURLWithPath: prefix), groupPrefixes: found)
        }
        checks.append(("unreadable evidence keeps every loader, sidecar, injector and unknown program in safety checks",
                       scope(a, infer()) == snap.clients && snap.clients.count == 5))
        let known = infer([991100: a, 991200: b])
        checks.append(("registered groups exclude only the positively different prefix",
                       scope(a, known).map(\.pid) == [991101, 991102, 991301, 991401]
                           && scope(b, known).map(\.pid) == [991201, 991301, 991401]))
        let sidecar = infer([:], [991102: a, 991201: b])
        checks.append(("a readable sidecar assigns the whole loader group without using its login host",
                       sidecar[991100] == a && sidecar[991200] == b
                           && scope(a, sidecar).filter { $0.host == "same.example" }.count == 2))
        let mapped = infer([:], [:], [991101: [a], 991201: [b], 991301: [c]])
        checks.append(("wineserver mappings attribute loaders and injectors after Wine erases their environment",
                       mapped[991100] == a && mapped[991200] == b && mapped[991300] == c
                           && scope(a, mapped).map(\.pid) == [991101, 991102, 991401]))
        checks.append(("agreement among registration, environment and mapping stays attributable",
                       infer([991100: a], [991102: a], [991101: [a]])[991100] == a))
        checks.append(("conflicting environments in one group keep the entire group unknown",
                       infer([:], [991101: a, 991102: b])[991100] == nil))
        checks.append(("a mapping that contradicts the registered or environment prefix fails closed",
                       infer([991100: a], [:], [991102: [b]])[991100] == nil
                           && infer([:], [991102: a], [991101: [b]])[991100] == nil))
        checks.append(("multiple mapped prefixes in one group fail closed",
                       infer([:], [:], [991101: [a, b]])[991100] == nil
                           && infer([:], [:], [991101: [a], 991102: [b]])[991100] == nil))
        checks.append(("evidence from another group or unrelated process is never borrowed",
                       infer([991999: b], [991999: b], [991999: [b]]).isEmpty))
        let canonical = infer([991100: a + "/"], [991102: a + "/../Shared Drive"], [991101: [a]])
        checks.append(("trailing slashes and standardized paths identify the same prefix",
                       canonical[991100] == a && scope(a + "/", canonical).count == 5))
        checks.append(("empty, relative and root paths provide no permission to exclude clients",
                       infer([991100: "", 991200: "relative/drive"], [991301: "/"]).isEmpty
                           && PrefixScope.clients(snap.clients, prefix: URL(fileURLWithPath: a),
                                                  groupPrefixes: [991200: "relative/drive"]) == snap.clients))
        let invalid = LiveClients.Snapshot(clients: [.init(pid: 991999, group: 0, host: "", injecting: true)])
        checks.append(("an invalid process group is never attributed",
                       PrefixScope.infer(invalid, knownGroups: [0: b], environmentPrefixes: [991999: b]).isEmpty))
        let refusal = MultiWorld.refusal(world: "Fixture world", hosts: ["same.example"], maxClients: 2,
                                         clients: snap.clients, ownGroups: [991300])
        checks.append(("same-world clients in different prefixes still hit the global server cap",
                       known[991100] != known[991200] && refusal?.contains("at most 2") == true))
        checks.append(("mapped wineserver folders use whole path components, including tmp's canonical spelling",
                       Leftovers.isUnder("/private/tmp/.wine-501/server-a-b/tmpmap-1", dir: "/tmp/.wine-501/server-a-b")
                           && !Leftovers.isUnder("/tmp/.wine-501/server-a-b2/tmpmap-1", dir: "/tmp/.wine-501/server-a-b")))
        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
