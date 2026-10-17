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
        // A GPU reset elsewhere must not leave MoltenVK's VkDevice lost for good (2026-10-16 21:31).
        checks.append(("every client gets MVK_CONFIG_RESUME_LOST_DEVICE=1, and last-spawn.txt records it",
                       env["MVK_CONFIG_RESUME_LOST_DEVICE"] == "1"
                           && PerfSettings().environment(for: install, gameWine: false)["MVK_CONFIG_RESUME_LOST_DEVICE"] == "1"
                           && Runner.spawnDiagnosticKeys.contains("MVK_CONFIG_RESUME_LOST_DEVICE")))

        // No-execute stays on under the game's Wine (the b66 fault storm): by default, for every
        // world; an explicit extraEnv value wins; `KEY=` takes it out; the wrapper's Wine is left alone.
        let nx = PerfSettings.nxCompatKey
        func nxEnv(_ extra: String, gameWine: Bool = true) -> [String: String] {
            var p = PerfSettings()
            p.extraEnv = extra
            return p.environment(for: install, gameWine: gameWine)
        }
        checks.append(("WINE_DISABLE_NX_COMPAT=1 by default under the game's Wine",
                       nx == "WINE_DISABLE_NX_COMPAT" && env[nx] == "1"))
        checks.append(("WINE_DISABLE_NX_COMPAT=1 for every built-in world (x87 on or off, any name)",
                       Server.all.allSatisfy {
                           PerfSettings().environment(for: install, x87: $0.x87, world: $0.name)[nx] == "1" }))
        checks.append(("an explicit WINE_DISABLE_NX_COMPAT in extra environment wins",
                       nxEnv("\(nx)=0")[nx] == "0" && nxEnv(" \(nx) = 2 \nFOO=bar")[nx] == "2"
                           && nxEnv("FOO=bar")["FOO"] == "bar" && nxEnv("FOO=bar")[nx] == "1"))
        checks.append(("WINE_DISABLE_NX_COMPAT= (empty) in extra environment removes it",
                       nxEnv("\(nx)=")[nx] == nil && !nxEnv("\(nx)=\r\nFOO=1").keys.contains(nx)
                           && nxEnv("\(nx)=\n\(nx)=1")[nx] == "1"))
        checks.append(("the wrapper's own Wine gets no WINE_DISABLE_NX_COMPAT unless asked",
                       nxEnv("", gameWine: false)[nx] == nil && nxEnv("\(nx)=1", gameWine: false)[nx] == "1"))
        checks.append(("extra environment: KEY= drops a launcher default; no '=' or no name is ignored",
                       nxEnv("DXVK_CONFIG_FILE=")["DXVK_CONFIG_FILE"] == nil
                           && nxEnv("JUSTAWORD\n=x")["JUSTAWORD"] == nil && nxEnv("=x")[""] == nil
                           && nxEnv("A==b")["A"] == "=b"))

        // The game window keeps its shape (b69): gamewindow.dylib plus HXI_GAME_ASPECT.
        let gw = GameWindow.aspectKey
        checks.append(("window shape: on by default, and a setting saved before b69 keeps it on",
                       PerfSettings().keepWindowShape
                           && (try? JSONDecoder().decode(PerfSettings.self, from: Data("{\"msync\":true}".utf8)))?
                               .keepWindowShape == true))
        let off = { () -> PerfSettings in var p = PerfSettings(); p.keepWindowShape = false; return p }()
        let offData = try? JSONEncoder().encode(off)
        checks.append(("window shape: switched off stays off across save and load",
                       offData.flatMap { try? JSONDecoder().decode(PerfSettings.self, from: $0) }?.keepWindowShape == false))
        let fakeFollow = "/fake/Resources/audiofollow.dylib"
        let fakeWindow = URL(fileURLWithPath: "/fake/Resources With Space/gamewindow.dylib")
        var gwEnv: [String: String] = [:]
        GameWindow.apply(to: &gwEnv, dylib: nil, size: .init(width: 1920, height: 1080))
        checks.append(("window shape: dylib missing => nothing inserted, no ratio, environment untouched",
                       gwEnv.isEmpty))
        gwEnv = [InsertedLibrary.key: fakeFollow]
        GameWindow.apply(to: &gwEnv, dylib: fakeWindow, size: .init(width: 1920, height: 1080))
        checks.append(("window shape: joined after audiofollow with ':' and HXI_GAME_ASPECT=1920x1080",
                       gwEnv[InsertedLibrary.key] == fakeFollow + ":" + fakeWindow.path && gwEnv[gw] == "1920x1080"))
        GameWindow.apply(to: &gwEnv, dylib: fakeWindow, size: .init(width: 1920, height: 1080))
        checks.append(("window shape: inserting twice does not list the dylib twice",
                       gwEnv[InsertedLibrary.key] == fakeFollow + ":" + fakeWindow.path))
        gwEnv = [:]
        GameWindow.apply(to: &gwEnv, dylib: fakeWindow, size: nil)
        checks.append(("window shape: launch size unknown => dylib inserted alone, no ratio",
                       gwEnv[InsertedLibrary.key] == fakeWindow.path && gwEnv[gw] == nil))
        checks.append(("window title: HXI_WINDOW_TITLE=FFXI on Mac wherever the dylib goes, ratio or not",
                       gwEnv[GameWindow.titleKey] == "FFXI on Mac"))
        checks.append(("window shape: the ratio is refused exactly where the dylib refuses it",
                       GameWindow.aspect(.init(width: 640, height: 480)) == "640x480"
                           && GameWindow.aspect(.init(width: 2074, height: 784)) == "2074x784"
                           && GameWindow.aspect(.init(width: 0, height: 1080)) == nil
                           && GameWindow.aspect(.init(width: 1920, height: -2)) == nil
                           && GameWindow.aspect(.init(width: 4001, height: 1000)) == nil
                           && GameWindow.aspect(.init(width: 40000, height: 20000)) == nil))
        // The size is the boot profile's own 0001/0002; a profile without both gives none.
        let gwRoot = fm.temporaryDirectory.appendingPathComponent("hxi-perf-gw-\(UUID().uuidString)", isDirectory: true)
        let gwInstall = Install(wrapper: gwRoot.appendingPathComponent("wrapper.app"), prefixName: "prefix",
                                gameDirOverride: gwRoot.appendingPathComponent("game", isDirectory: true))
        let boot = gwInstall.gameDir.appendingPathComponent("config/boot", isDirectory: true)
        try? fm.createDirectory(at: boot, withIntermediateDirectories: true)
        try? "[ffxi.registry]\r\n0001 = 2560\r\n0002 = 1440\r\n0003 = 4096\r\n".write(
            to: boot.appendingPathComponent("both.ini"), atomically: true, encoding: .utf8)
        try? "[ffxi.registry]\n0001 = 2560\n0003 = 4096\n".write(
            to: boot.appendingPathComponent("width-only.ini"), atomically: true, encoding: .utf8)
        try? "[ffxi.registry]\n0001 = 2560\n0002 = 0\n".write(
            to: boot.appendingPathComponent("zero.ini"), atomically: true, encoding: .utf8)
        checks.append(("window shape: launch size is the profile's 0001 x 0002",
                       GameWindow.launchSize(gwInstall, profile: "both.ini") == WindowMemory.Size(width: 2560, height: 1440)))
        checks.append(("window shape: no launch size when the profile lacks 0002, has 0002 = 0, or is missing",
                       GameWindow.launchSize(gwInstall, profile: "width-only.ini") == nil
                           && GameWindow.launchSize(gwInstall, profile: "zero.ini") == nil
                           && GameWindow.launchSize(gwInstall, profile: "absent.ini") == nil))
        let size1440 = GameWindow.launchSize(gwInstall, profile: "both.ini")
        try? fm.removeItem(at: gwRoot)
        let offEnv = off.environment(for: install, gameSize: size1440)
        checks.append(("window shape off: no gamewindow.dylib, no HXI_GAME_ASPECT, no HXI_WINDOW_TITLE",
                       offEnv[gw] == nil && offEnv[GameWindow.titleKey] == nil
                           && !(offEnv[InsertedLibrary.key] ?? "").contains("gamewindow")))
        var bothOn = PerfSettings()
        bothOn.followSoundOutput = true
        let onEnv = bothOn.environment(for: install, gameSize: size1440)
        if let dylib = GameWindow.dylib() {
            let list = (onEnv[InsertedLibrary.key] ?? "").split(separator: ":").map(String.init)
            let expected = [AudioFollow.dylib()?.path, dylib.path].compactMap { $0 }
            checks.append(("window shape on: gamewindow.dylib (x86_64 slice) and HXI_GAME_ASPECT=2560x1440 in the game's environment",
                           list.contains(dylib.path) && onEnv[gw] == "2560x1440"))
            checks.append(("window shape on: HXI_WINDOW_TITLE=FFXI on Mac in the game's environment",
                           onEnv[GameWindow.titleKey] == "FFXI on Mac"))
            checks.append(("window shape on: DYLD_INSERT_LIBRARIES is audiofollow:gamewindow when both are on",
                           list == expected))
        } else {
            checks.append(("gamewindow.dylib found (bundle or app/Resources) with an x86_64 slice", false))
        }
        var noAspect = PerfSettings()
        noAspect.extraEnv = "\(gw)="
        checks.append(("window shape: HXI_GAME_ASPECT= in extra environment removes the ratio",
                       noAspect.environment(for: install, gameSize: size1440)[gw] == nil))
        if GameWindow.dylib() != nil {
            var noTitle = PerfSettings()
            noTitle.extraEnv = "\(GameWindow.titleKey)="
            let e = noTitle.environment(for: install, gameSize: size1440)
            checks.append(("window title: HXI_WINDOW_TITLE= in extra environment removes the title only",
                           e[GameWindow.titleKey] == nil && e[gw] == "2560x1440"))
        }
        checks.append(("last-spawn.txt records HXI_GAME_ASPECT, HXI_WINDOW_TITLE and DYLD_INSERT_LIBRARIES",
                       Runner.spawnDiagnosticKeys.isSuperset(of: [gw, GameWindow.titleKey, InsertedLibrary.key])))
        let notMachO = fm.temporaryDirectory.appendingPathComponent("hxi-perf-notmacho-\(UUID().uuidString).dylib")
        try? Data("not a Mach-O file at all".utf8).write(to: notMachO)
        checks.append(("a file without an x86_64 Mach-O slice is never inserted",
                       !InsertedLibrary.hasX86Slice(notMachO)
                           && !InsertedLibrary.hasX86Slice(notMachO.appendingPathExtension("missing"))))
        try? fm.removeItem(at: notMachO)

        // Stop's wineserver wait is bounded, so the launch lock it holds is always let go.
        checks.append(("Stop's wineserver wait: done at once when quick, gives up at its limit",
                       Runner.finishes(within: 2) {}
                           && !Runner.finishes(within: 0.1) { Thread.sleep(forTimeInterval: 1) }))
        // Past its limit a wait counts as stuck (Play refuses rather than hang the window on the
        // same wineserver) until it returns; one that returned in time never counts.
        let late = WineserverStopWait()
        let lateStuck = late.markStuck(), whileStuck = WineserverStopWait.anyStuck
        late.finish()
        let quick = WineserverStopWait()
        quick.finish()
        checks.append(("Stop's wineserver wait: Play is refused only while one is stuck past its limit",
                       lateStuck && whileStuck && !quick.markStuck() && !WineserverStopWait.anyStuck))

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
        let memoryLine = "Memory is low (4.6 GB in swap) — the game may stutter."
        checks.append(("play-time lines clear when Low Power Mode or the heat ends, memory stays",
                       PlayCheck.stillTrue([PlayCheck.lowPowerLine, memoryLine, PlayCheck.thermalLine],
                                           lowPower: false, thermal: .fair) == [memoryLine]
                           && PlayCheck.stillTrue([PlayCheck.lowPowerLine, PlayCheck.thermalLine],
                                                  lowPower: true, thermal: .serious).count == 2))
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
