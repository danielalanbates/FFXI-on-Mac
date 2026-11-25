import Foundation

/// Transactional prefix setup against tiny Downloads fixtures. Never runs Wine or a game.
/// Copyright (c) 2026 Bates LLC. All rights reserved.
extension Headless {
    @MainActor static func runWorldPrefixSelfTest() -> Never {
        var result: [(String, Bool)]?
        Task { result = await WorldPrefixFixtures.run() }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let checks = result ?? []
        for (name, ok) in checks { print("  \(ok ? "ok  " : "FAIL") \(name)") }
        let failures = checks.filter { !$0.1 }.count
        print("\(checks.count) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}

private enum WorldPrefixFixtures {
    static func boot(_ install: Install) async -> Bool {
        let fm = FileManager.default
        do {
            let windows = install.driveC.appendingPathComponent("windows/syswow64")
            try fm.createDirectory(at: windows, withIntermediateDirectories: true)
            try Data("new Windows".utf8).write(to: windows.appendingPathComponent("ntdll.dll"))
            try Data("fresh registry".utf8).write(to: install.systemReg)
            try Data("disable\n".utf8).write(to: install.prefix.appendingPathComponent(".update-timestamp"))
            return true
        } catch { return false }
    }

    static func run() async -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        func check(_ title: String, _ value: Bool) { checks.append((title, value)) }
        let fm = FileManager.default
        let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let tmp = downloads.appendingPathComponent("world-prefix-selftest-" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        do {
            let base = Install(wrapper: tmp.appendingPathComponent("Wine.app"), prefixName: "prefix10")
            let windows = base.driveC.appendingPathComponent("windows/syswow64")
            try fm.createDirectory(at: windows, withIntermediateDirectories: true)
            try fm.createDirectory(at: base.gameDir, withIntermediateDirectories: true)
            try Data("existing game".utf8).write(to: base.gameDir.appendingPathComponent("Ashita-cli.exe"))
            try Data("existing registry".utf8).write(to: base.systemReg)
            try Data("runtime".utf8).write(to: windows.appendingPathComponent("api-ms-win-crt-test-l1-1-0.dll"))
            try Data("renderer".utf8).write(to: windows.appendingPathComponent("d3d8.dll"))
            let lockURL = tmp.appendingPathComponent("launch.lock")
            var server = Server(name: "Example / ../ World", host: "example.test", bootProfile: "example.ini", verified: false, note: "")
            check("ordinary installs are ready without a managed-prefix marker", WorldPrefix.ready(base))
            check("opting out keeps the existing Windows drive", base.forServer(server).prefix == base.prefix)
            server.multiServerPlay = true
            let isolated = base.forServer(server)
            let twice = isolated.forServer(server)
            check("opting in reuses game files and routes one stable independent drive",
                  isolated.prefix != base.prefix && isolated.gameDir == base.gameDir
                    && isolated.basePrefixName == base.prefixName && twice == isolated
                    && isolated.gameDirWine.hasPrefix("Z:\\") && !WorldPrefix.ready(isolated))
            check("world names cannot inject a directory into the prefix name",
                  isolated.prefixName.hasPrefix(WorldPrefix.namePrefix)
                    && !isolated.prefixName.contains("/") && !isolated.prefixName.contains("..")
                    && isolated.prefix.deletingLastPathComponent() == base.sharedSupport)
            var other = server; other.host = "another.test"
            var profile = server; profile.bootProfile = "other.ini"
            let anotherBase = Install(wrapper: base.wrapper, prefixName: "prefix11")
            check("different hosts, profiles and base drives cannot collide",
                  Set([WorldPrefix.prefixName(base: base, server: server),
                       WorldPrefix.prefixName(base: base, server: other),
                       WorldPrefix.prefixName(base: base, server: profile),
                       WorldPrefix.prefixName(base: anotherBase, server: server)]).count == 4)
            var disabled = server; disabled.multiServerPlay = false
            let restored = isolated.forServer(disabled)
            check("opting out restores the base drive even from an already routed install",
                  restored.prefix == base.prefix && restored.gameDir == base.gameDir && restored.basePrefixName == nil)
            var refusedLowSpace = false
            do {
                try await WorldPrefix.prepare(base: base, server: server, log: { _ in },
                                              availableBytes: { _ in 2_000_000_000 }, boot: boot, lockURL: lockURL)
            } catch { refusedLowSpace = true }
            check("low free space refuses setup before creating a separate drive",
                  refusedLowSpace && !fm.fileExists(atPath: isolated.prefix.path))
            var refusedBoot = false
            do {
                try await WorldPrefix.prepare(base: base, server: server, log: { _ in },
                                              availableBytes: { _ in 10_000_000_000 }, boot: { _ in false }, lockURL: lockURL)
            } catch { refusedBoot = true }
            let leftovers = (try? fm.contentsOfDirectory(atPath: base.sharedSupport.path)) ?? []
            check("a failed boot removes only its staging drive and never falls back to the shared drive",
                  refusedBoot && !WorldPrefix.ready(isolated) && isolated.prefix != base.prefix
                    && !leftovers.contains(where: { $0.contains(".preparing-") })
                    && (try? String(contentsOf: base.systemReg, encoding: .utf8)) == "existing registry")
            try await WorldPrefix.prepare(base: base, server: server, log: { _ in },
                                          availableBytes: { _ in 10_000_000_000 }, boot: boot, lockURL: lockURL)
            check("a complete boot publishes one ready drive with a fresh registry",
                  WorldPrefix.ready(isolated)
                    && (try? String(contentsOf: isolated.systemReg, encoding: .utf8)) == "fresh registry")
            check("runtime supplementation copies CRT forwarders while reusing the client and renderer data",
                  fm.fileExists(atPath: isolated.driveC.appendingPathComponent("windows/syswow64/api-ms-win-crt-test-l1-1-0.dll").path)
                    && !fm.fileExists(atPath: isolated.driveC.appendingPathComponent("windows/syswow64/d3d8.dll").path)
                    && !fm.fileExists(atPath: isolated.driveC.appendingPathComponent("HorizonXI").path)
                    && (try? String(contentsOf: base.systemReg, encoding: .utf8)) == "existing registry")
            try await WorldPrefix.prepare(base: base, server: server, log: { _ in },
                                          availableBytes: { _ in 0 }, boot: { _ in false }, lockURL: lockURL)
            check("a prepared drive is reused without allocating or booting again", WorldPrefix.ready(isolated))
            let incomplete = base.forServer(other)
            try fm.createDirectory(at: incomplete.prefix, withIntermediateDirectories: false)
            let sentinel = incomplete.prefix.appendingPathComponent("keep-me")
            try Data("untouched".utf8).write(to: sentinel)
            var refusedIncomplete = false
            do {
                try await WorldPrefix.prepare(base: base, server: other, log: { _ in },
                                              availableBytes: { _ in 10_000_000_000 }, boot: boot, lockURL: lockURL)
            } catch { refusedIncomplete = true }
            check("an existing incomplete drive is refused and left intact",
                  refusedIncomplete && (try? String(contentsOf: sentinel, encoding: .utf8)) == "untouched")
            let held = LaunchLock.acquire(at: lockURL)
            var refusedBusy = false
            do {
                try await WorldPrefix.prepare(base: base, server: profile, log: { _ in },
                                              availableBytes: { _ in 10_000_000_000 }, boot: boot, lockURL: lockURL)
            } catch { refusedBusy = true }
            if let held { LaunchLock.release(held) }
            check("setup respects the launch lock without changing another world's drive",
                  held != nil && refusedBusy && !WorldPrefix.ready(base.forServer(profile))
                    && WorldPrefix.ready(isolated))
        } catch {
            checks.append(("fixture setup: \(error.localizedDescription)", false))
        }
        return checks
    }
}
