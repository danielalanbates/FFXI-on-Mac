import Foundation

/// `--selftest-perf`: the play-time performance rules, headless. The x87 guard's decision and
/// failure markers, sidecar detection in a process scan, dxvk.conf placement, the play-time
/// warnings, the local world's graphics seed, the registry values pre-launch setup skips.
/// Nothing is
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
                // A sidecar merely gone a minute in can be timing: two sessions in a row count.
                d.removeObject(forKey: X87Guard.defaultsKey)
                let first = X87Guard.timingFailure(sidecar: sidecar, defaults: d)
                let firstBroken = X87Guard.isBroken(sidecar: sidecar, defaults: d)
                X87Guard.clearSuspect(defaults: d)
                let afterLive = X87Guard.timingFailure(sidecar: sidecar, defaults: d)
                let second = X87Guard.timingFailure(sidecar: sidecar, defaults: d)
                X87Guard.markBroken(sidecar: sidecar, defaults: d)
                checks.append(("x87 guard: one session with no sidecar is only noted",
                               !first && !firstBroken))
                checks.append(("x87 guard: a live sidecar in between starts the count again", !afterLive))
                checks.append(("x87 guard: the second session in a row records it, and the note is cleared",
                               second && d.string(forKey: X87Guard.suspectKey) == nil
                                   && X87Guard.isBroken(sidecar: sidecar, defaults: d)))
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

        // Stop's wineserver wait is bounded, so the launch lock it holds is always let go.
        checks.append(("Stop's wineserver wait: done at once when quick, gives up at its limit",
                       Runner.finishes(within: 2) {}
                           && !Runner.finishes(within: 0.1) { Thread.sleep(forTimeInterval: 1) }))

        // Play-time checks: nothing when fine, one short line when real.
        checks.append(("Low Power Mode: one line when on, nothing when off",
                       PlayCheck.lowPower(true) == PlayCheck.lowPowerLine && PlayCheck.lowPower(false) == nil))
        checks.append(("heat: a line only when macOS throttles (serious/critical)",
                       PlayCheck.thermal(.nominal) == nil && PlayCheck.thermal(.fair) == nil
                           && PlayCheck.thermal(.serious) != nil && PlayCheck.thermal(.critical) != nil))
        let gb: UInt64 = 1 << 30
        checks.append(("memory, single client: silent at 2.5 GB swap (81% of 3 GB) with 53% free",
                       MultiWorld.memoryWarning(swapUsedFraction: 0.81, freePercent: 53,
                                                swapUsedBytes: gb * 5 / 2, othersRunning: false) == nil))
        checks.append(("memory, single client: a line at 4.6 GB swap, or under 20% free",
                       MultiWorld.memoryWarning(swapUsedFraction: 0.9, freePercent: 40,
                                                swapUsedBytes: gb * 46 / 10, othersRunning: false)
                           == "Memory is low (4.6 GB in swap) — the game may stutter."
                           && MultiWorld.memoryWarning(swapUsedFraction: 0.1, freePercent: 15,
                                                       swapUsedBytes: 0, othersRunning: false) != nil))
        checks.append(("memory, second client: the existing thresholds, second-client wording",
                       MultiWorld.memoryWarning(swapUsedFraction: 0.64, freePercent: 46)?.contains("second client") == true
                           && MultiWorld.memoryWarning(swapUsedFraction: 0.6, freePercent: 20) == nil))
        checks.append(("every play-time line is one short line",
                       [PlayCheck.lowPowerLine, PlayCheck.thermalLine, PlayCheck.localServerLine,
                        MultiWorld.memoryWarning(swapUsedFraction: 0.9, freePercent: 10) ?? ""]
                           .allSatisfy { !$0.contains("\n") && $0.count <= 80 }))

        // Log strip: a bounded tail, starting on a line.
        let many = (1...300).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let tail = Runner.uiTail(many, maxBytes: Runner.uiLogMaxBytes, maxLines: Runner.uiLogMaxLines)
        checks.append(("log strip keeps the last 200 lines",
                       Runner.lineBreaks(in: tail) == 200 && tail.hasPrefix("line 101\n") && tail.hasSuffix("line 300\n")))
        let wide = (1...100).map { "\($0) " + String(repeating: "é", count: 150) }.joined(separator: "\n")
        let wideTail = Runner.uiTail(wide, maxBytes: Runner.uiLogMaxBytes, maxLines: Runner.uiLogMaxLines)
        checks.append(("log strip keeps at most 16 KB, cut at a line start, multi-byte text intact",
                       wideTail.utf8.count <= Runner.uiLogMaxBytes && wideTail.hasSuffix(String(repeating: "é", count: 150))
                           && wideTail.split(separator: "\n").allSatisfy { $0.hasSuffix(String(repeating: "é", count: 150)) }
                           && !wideTail.contains("\u{FFFD}")))
        checks.append(("log strip leaves short text alone",
                       Runner.uiTail("a\nb\n", maxBytes: 100, maxLines: 10) == "a\nb\n"))

        // Graphics: the local world's small default is a window size, never lower quality.
        var lowQuality = GraphicsSettings.lowSpec
        lowQuality.width = GraphicsSettings.max4K.width
        lowQuality.height = GraphicsSettings.max4K.height
        checks.append(("the local world's seed is max quality at 640x480 (4096 textures, 20 channels)",
                       lowQuality == GraphicsSettings.max4K && GraphicsSettings.lowSpec.width == 640
                           && GraphicsSettings.lowSpec.textureResolution == 4096
                           && GraphicsSettings.lowSpec.soundChannels == 20))

        // Idempotent pre-launch setup: what user.reg already holds is not written again.
        let hive = RendererSetup.hiveValues("""
            WINE REGISTRY Version 2
            ;; All keys relative to REGISTRY\\User\\S-1-5-21-0-0-0-1000

            [Software\\\\Wine\\\\Direct3D] 1786416352\r
            #time=1dd293b86547c74\r
            "MaxVersionGL"=dword:00040001\r
            "renderer"="gl"\r

            [Software\\\\Wine\\\\DllOverrides] 1787329915
            #time=1dd318a94531662
            "*d3d8"="native"
            "*d3d9"="native"
            "concrt140"="native,builtin"
            """)
        let d3d = #"HKCU\Software\Wine\Direct3D"#, dll = #"HKCU\Software\Wine\DllOverrides"#
        checks.append(("registry: values already in user.reg are recognised (REG_SZ, REG_DWORD, CRLF)",
                       RendererSetup.hiveHas(hive, key: d3d, name: "renderer", type: "REG_SZ", data: "gl")
                           && RendererSetup.hiveHas(hive, key: d3d, name: "MaxVersionGL", type: "REG_DWORD",
                                                    data: String(format: "0x%x", RendererSetup.maxVersionGL))
                           && RendererSetup.hiveHas(hive, key: dll, name: "*d3d8", type: "REG_SZ", data: "native")
                           && RendererSetup.hiveHas(hive, key: dll, name: "*d3d9", type: "REG_SZ", data: "native")))
        checks.append(("registry: a different or missing value is written",
                       !RendererSetup.hiveHas(hive, key: d3d, name: "renderer", type: "REG_SZ", data: "vulkan")
                           && !RendererSetup.hiveHas(hive, key: d3d, name: "MaxVersionGL", type: "REG_DWORD", data: "0x40000")
                           && !RendererSetup.hiveHas(hive, key: dll, name: "*d3d10", type: "REG_SZ", data: "native")
                           && !RendererSetup.hiveHas(hive, key: #"HKCU\Software\Wine\Other"#, name: "renderer",
                                                     type: "REG_SZ", data: "gl")
                           && !RendererSetup.hiveHas(hive, key: dll, name: "concrt140", type: "REG_SZ", data: "native")))
        checks.append(("registry: the prefix's renderer still reads as Metal from the same text",
                           RendererSetup.renderer(fromUserReg: """
                               [Software\\\\Wine\\\\DllOverrides] 1
                               "*d3d8"="native"
                               """) == .metal))

        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        // Read-only, for the record: what Play's renderer step would still write on this Mac.
        if let i = Install.remembered(), let real = RendererSetup.userHive(i) {
            let wanted: [(String, String, String, String)] = [
                (d3d, "renderer", "REG_SZ", Renderer.metal.wineRendererKey),
                (d3d, "MaxVersionGL", "REG_DWORD", String(format: "0x%x", RendererSetup.maxVersionGL)),
                (dll, "*d3d8", "REG_SZ", "native"), (dll, "*d3d9", "REG_SZ", "native")]
            let missing = wanted.filter { !RendererSetup.hiveHas(real, key: $0.0, name: $0.1, type: $0.2, data: $0.3) }
            print("  i    this Mac's prefix (\(i.prefixName)): Metal setup would write "
                  + (missing.isEmpty ? "no registry values" : missing.map(\.1).joined(separator: ", ")))
        }
        let now = PlayCheck.current(othersRunning: false)
        print("  i    play-time lines on this Mac right now: \(now.isEmpty ? "none" : now.joined(separator: " | "))")
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
