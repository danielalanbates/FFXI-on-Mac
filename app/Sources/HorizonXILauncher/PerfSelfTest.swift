import Foundation

/// `--selftest-perf`: the play-time performance rules, headless. The x87 guard's decision and
/// failure markers, sidecar detection in a process scan, dxvk.conf placement. Nothing is
/// launched; files go to a temporary folder and defaults writes to a scratch domain, both deleted
/// afterwards, never the launcher's own.
extension Headless {
    @MainActor static func runPerfSelfTest() -> Never {
        let fm = FileManager.default
        var checks: [(String, Bool)] = []

        // x87: on by default everywhere; the environment override and a recorded failure.
        checks.append(("x87 on by default on every macOS version",
                       X87Guard.enabled(worldAllows: true, override: nil, brokenHere: false)))
        checks.append(("FFXI_ON_MAC_X87=0 forces x87 off",
                       !X87Guard.enabled(worldAllows: true, override: "0", brokenHere: false)))
        checks.append(("FFXI_ON_MAC_X87=1 forces x87 on past a recorded failure",
                       X87Guard.enabled(worldAllows: true, override: "1", brokenHere: true)))
        checks.append(("a recorded failure turns x87 off without an override",
                       !X87Guard.enabled(worldAllows: true, override: nil, brokenHere: true)))
        checks.append(("a world that cannot take x87 never gets it, override or not",
                       !X87Guard.enabled(worldAllows: false, override: "1", brokenHere: false)))

        checks.append(("x87 failure markers: the sidecar's own failure lines are caught",
                       X87Guard.failure(in: "x\n[rosettax87] bootstrap_register2(x87sidecar.1) failed: 0x44c\n")
                           == "[rosettax87] bootstrap_register2(x87sidecar.1) failed: 0x44c"
                           && X87Guard.failure(in: "Failed to attach to parent process\n") != nil
                           && X87Guard.failure(in: "Failed to find Rosetta runtime by signature\n") != nil
                           && X87Guard.failure(in: "M2: failed to write handler blob\n") != nil))
        checks.append(("x87 failure markers: a normal session's output is not a failure",
                       X87Guard.failure(in: "info:  OpenVR: Failed to locate module\nDXVK: v1.10.3\n"
                                        + "Successfully logged in as x!\n[rosettax87] sidecar: idle (total 4)\n") == nil))
        checks.append(("x87 failure markers: a handshake timeout alone is left to the live-sidecar check",
                       X87Guard.failure(in: X87Guard.timeoutMarker + ": 0x10004003 (timed out)\n") == nil))
        checks.append(("macOS build is read (kern.osversion)", !X87Guard.osBuild().isEmpty))

        // The recorded pairing: same build + same sidecar is broken; a changed sidecar is not.
        let suite = "org.batesai.horizonxi-on-mac.selftest-perf-\(UUID().uuidString)"
        let dir = fm.temporaryDirectory.appendingPathComponent("hxi-perf-\(UUID().uuidString)", isDirectory: true)
        if let d = UserDefaults(suiteName: suite) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let sidecar = dir.appendingPathComponent("x87sidecar-coop")
                try Data("sidecar one".utf8).write(to: sidecar)
                let before = X87Guard.isBroken(sidecar: sidecar, defaults: d)
                X87Guard.markBroken(sidecar: sidecar, defaults: d)
                let stored = d.string(forKey: X87Guard.defaultsKey) ?? ""
                let after = X87Guard.isBroken(sidecar: sidecar, defaults: d)
                // A rebuilt sidecar (different bytes, different size) must be tried again.
                try Data("sidecar number two".utf8).write(to: sidecar)
                let rebuilt = X87Guard.isBroken(sidecar: sidecar, defaults: d)
                d.set("00A000|" + (X87Guard.sha256(of: sidecar) ?? ""), forKey: X87Guard.defaultsKey)
                let otherBuild = X87Guard.isBroken(sidecar: sidecar, defaults: d)
                checks.append(("x87 guard: nothing recorded means not broken", !before))
                checks.append(("x87 guard: stores macOS build + sidecar SHA-256",
                               stored.hasPrefix(X87Guard.osBuild() + "|") && stored.count == X87Guard.osBuild().count + 65))
                checks.append(("x87 guard: same build and sidecar stays off", after))
                checks.append(("x87 guard: a changed sidecar is tried again", !rebuilt))
                checks.append(("x87 guard: a different macOS build is tried again", !otherBuild))
            } catch {
                checks.append(("x87 guard fixture", false))
            }
            UserDefaults.standard.removePersistentDomain(forName: suite)
        } else {
            checks.append(("x87 guard scratch defaults", false))
        }
        try? fm.removeItem(at: dir)

        // Sidecar detection: the command is the sidecar itself, not a mention of it.
        let snap = LiveClients.parse("""
            57992 57810 .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user f --pass f
            57994 57810 /Applications/FFXI-on-Mac.app/Contents/Resources/x87sidecar-coop --cooperative /x/wine/lib/wine/x86_64-unix/wine .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user f --pass f
            58001 58000 /Applications/FFXI on Mac.app/Contents/Resources/x87sidecar-coop --cooperative /x/wine C:\\\\Other\\\\xiloader.exe --server 127.0.0.1
            58010 58010 /usr/bin/grep x87sidecar
            58020 58020 /bin/sh -c x87sidecar-coop --cooperative /x/wine
            """)
        checks.append(("process scan: the sidecar is found, also under an install path with spaces",
                       snap.sidecars == [57994, 58001]))
        checks.append(("process scan: the sidecar still files under its loader's host",
                       snap.byHost["play.horizonxi.com"] == [57992, 57994]))

        // dxvk.conf: shipped with the current effective settings only, placed once, read by name.
        if let conf = RendererSetup.bundledDXVKConfig(), let text = try? String(contentsOf: conf, encoding: .utf8) {
            let keys = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            checks.append(("dxvk.conf ships only dxvk.enableStateCache = True (current behaviour)",
                           keys == ["dxvk.enableStateCache = True"]))
        } else {
            checks.append(("dxvk.conf found (bundle or vendor/)", false))
        }
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-perf-conf-\(UUID().uuidString)", isDirectory: true)
        let install = Install(wrapper: root.appendingPathComponent("wrapper.app"), prefixName: "prefix",
                              gameDirOverride: root.appendingPathComponent("game", isDirectory: true))
        let first = RendererSetup.syncDXVKConfig(install)
        let second = RendererSetup.syncDXVKConfig(install)
        let placed = RendererSetup.bundledDXVKConfig().map {
            fm.contentsEqual(atPath: $0.path, andPath: RendererSetup.dxvkConfigFile(install).path) } ?? false
        try? "d3d9.maxFrameLatency = 1\n".write(to: RendererSetup.dxvkConfigFile(install), atomically: true, encoding: .utf8)
        let repaired = RendererSetup.syncDXVKConfig(install)
        let leftovers = (try? fm.contentsOfDirectory(atPath: RendererSetup.dxvkConfigFile(install)
                            .deletingLastPathComponent().path)) ?? []
        checks.append(("dxvk.conf is copied into C:\\dxvk-cache once, then left alone while it matches",
                       first && !second && placed))
        checks.append(("a dxvk.conf that differs is replaced, leaving no temp file",
                       repaired && leftovers == ["dxvk.conf"]))
        try? fm.removeItem(at: root)
        let env = PerfSettings().environment(for: install)
        checks.append(("every client gets DXVK_CONFIG_FILE next to DXVK_STATE_CACHE_PATH",
                       env["DXVK_CONFIG_FILE"] == #"C:\dxvk-cache\dxvk.conf"#
                           && env["DXVK_STATE_CACHE_PATH"] == #"C:\dxvk-cache"#))

        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
