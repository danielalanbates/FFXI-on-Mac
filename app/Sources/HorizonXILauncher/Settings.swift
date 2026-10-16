import Foundation

/// Host-side performance knobs. Only things whose effect is real and explainable — no cargo cult.
struct PerfSettings: Codable {
    /// msync is the macOS-native fast synchronisation path in CX/Sikarugir wine. Falls back
    /// harmlessly if the build does not support it.
    var msync = true
    /// esync as a second-choice sync primitive; ignored when msync is active.
    var esync = false
    /// WINEDEBUG=-all. Wine's debug channels are extremely expensive even when nothing consumes
    /// them; leaving them on costs frames.
    var silenceWineDebug = true
    /// Metal HUD overlay. A measurement tool, not a feature: it belongs on the benchmark
    /// harness (`scripts/`, which sets `MTL_HUD_ENABLED` itself), not on top of somebody's
    /// game. Off by default; the toggle stays for when a number is actually wanted.
    var metalHUD = false
    /// Keep the game off macOS App Nap / timer coalescing when it loses focus.
    var disableAppNap = true
    /// Follow the Mac's Sound Output setting while the game is running.
    ///
    /// Wine's CoreAudio backend pins its AUHAL output unit to whichever device was default when
    /// the game started its audio, and macOS's Sound Output control only changes the *default* —
    /// so plugging in headphones mid-session used to leave FFXI talking to the speakers with no
    /// remedy short of quitting. `audiofollow.dylib` (see `audio/audiofollow.c`) is inserted into
    /// the wine process, watches `kAudioHardwarePropertyDefaultOutputDevice`, and re-points the
    /// unit when it changes. Verified A/B on both arm64 and x86_64/Rosetta —
    /// `scripts/tests/audiofollow-test.sh`. Harmless if it fails: the audio keeps playing exactly
    /// where it already was.
    var followSoundOutput = true
    /// Keep the game's picture in proportion when its window is resized.
    ///
    /// FFXI's back buffer is fixed at the profile's 0001 x 0002 and the renderer scales it to the
    /// window, so dragging the window to another shape squeezed or stretched the whole picture.
    /// `gamewindow.dylib` (see `window/gamewindow.c` and `GameWindow`) is inserted into wine and
    /// sets the window's content aspect ratio to the size the client was started at, so AppKit keeps
    /// every drag in proportion. Harmless if it fails: the window resizes freely, as before.
    /// The same dylib keeps the window's title "FFXI on Mac" (b69), so this one setting covers both.
    var keepWindowShape = true
    /// FFXI limits itself to 60/n fps, n=2 by default (30 fps) -- but under wine the limiter
    /// overshoots and the client spends more than the 33.3ms budget per frame even while only
    /// ~52% busy. Our d3d9.dll patches the divisor at start-up (see docs/PERFORMANCE.md);
    /// FFXI_FPS_DIVISOR=1 measured 28.5 -> 30.3 fps median in-world with x87sidecar already on.
    /// It does not help scenes that are genuinely compute-bound below the cap, only the
    /// self-throttling -- but it never hurts, so it is on by default.
    var fpsDivisorOne = true
    /// Do not block on FFXI's lens-flare occlusion read-back.
    ///
    /// The single largest cost in the frame, by a wide margin. FFXI renders a 16×16
    /// `D3DUSAGE_RENDERTARGET` surface and immediately locks it to read the result — about four
    /// times per frame — which drains the whole pipeline each time. Measured at 4K max on the
    /// local server: **26 ms of a 40 ms frame** spent with the client blocked inside those four
    /// locks, doing nothing. Skipping only the *wait* (the copy is still issued, so the surface
    /// keeps being refreshed) took the same scene from 18.6/24.9 fps to 42.9/46.8 fps.
    ///
    /// **Off by default: it glitches.** The claim that this costs only one frame of latency on a
    /// flare's brightness was wrong, and Daniel caught it in about a minute of play — NPCs blink
    /// in and out of existence roughly once a second. Measured with `blinkprobe.py`, which takes
    /// a burst of frames 0.25 s apart in a static scene and diffs consecutive ones: with this on,
    /// 17 of 39 frame pairs differ by ~50% of sampled pixels; with it off, 0 of 39, and the
    /// spread is flat (p90 0.023, max 0.026).
    ///
    /// The reason is that skipping the wait hands the game a buffer the GPU has not finished
    /// writing, so the visibility test reads whatever is in it and the entity is culled at
    /// random. A correct version reads a *completed* copy from an earlier frame rather than an
    /// in-flight one; see docs/MAX4K.md.
    var flareReadbackNoWait = false
    /// Read FFXI's cutscene and NPC dialogue aloud through VanaVoice (see Narration.swift).
    /// Off by default: it installs an addon into the game folder and starts a second app, and
    /// neither should happen to somebody who never asked for a narrator.
    var narrateCutscenes = false
    /// Install Vanaguide (quest / mission guide) into this world's addons folder (see Guide.swift).
    /// Off by default. The launcher will only honour this on unrestricted / unknown-policy worlds
    /// (local LandSandBoat); allowlist servers scrub it even if the toggle was left on.
    var enableVanaguide = false
    /// Large address aware heap hint for the 32-bit client.
    var largeAddressAware = true
    /// Extra environment, one KEY=VALUE per line, for experiments. It wins over every value the
    /// launcher sets itself; `KEY=` with nothing after the `=` takes KEY out of the game's
    /// environment, including one of the launcher's own defaults (see `extraEnvironment`).
    var extraEnv = ""
    /// Which renderer pathway to run. Metal/DXVK reaches FFXI's 30 fps cap with the world
    /// drawing correctly, so it is the default; Vulkan and Classic are fallbacks.
    var renderer: Renderer = .metal

    static let key = "perf.settings"

    init() { }

    /// Decoded field by field rather than by the synthesised initialiser, which treats every key
    /// as required: adding a knob would then fail to decode the settings already on disk, and
    /// `load()`'s `try?` would quietly reset everything the user had chosen.
    ///
    /// **Every field added above must be listed below.** A field left out of this initialiser is
    /// not merely undecoded -- it silently reverts to its declared default on *every* load, so
    /// the toggle appears to work and then forgets. That is not hypothetical: `followSoundOutput`
    /// was missing here, which is why Daniel's menu sound could not be switched back on after
    /// 3.8 (see docs/AUDIO.md and docs/MOUSE.md).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) .flatMap { $0 } ?? d }
        msync = b(.msync, true)
        esync = b(.esync, false)
        silenceWineDebug = b(.silenceWineDebug, true)
        metalHUD = false
        disableAppNap = b(.disableAppNap, true)
        fpsDivisorOne = b(.fpsDivisorOne, true)
        followSoundOutput = b(.followSoundOutput, true)
        keepWindowShape = b(.keepWindowShape, true)
        flareReadbackNoWait = false   // option removed: NPCs blink with it on
        largeAddressAware = b(.largeAddressAware, true)
        narrateCutscenes = b(.narrateCutscenes, false)
        enableVanaguide = b(.enableVanaguide, false)
        extraEnv = ((try? c.decodeIfPresent(String.self, forKey: .extraEnv)) ?? nil) ?? ""
        renderer = ((try? c.decodeIfPresent(Renderer.self, forKey: .renderer)) ?? nil) ?? .metal
    }

    static func load() -> PerfSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(PerfSettings.self, from: d) else { return .init() }
        // The HUD used to default on, so every existing install has `true` saved. Clear it once
        // rather than leaving a measurement overlay pinned over the game forever.
        var s2 = s
        if !UserDefaults.standard.bool(forKey: "perf.hudDefaultCleared") {
            UserDefaults.standard.set(true, forKey: "perf.hudDefaultCleared")
            s2.metalHUD = false
            s2.save()
        }
        return s2
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// The patched game Wine's switch for keeping no-execute on; see `environment`.
    static let nxCompatKey = "WINE_DISABLE_NX_COMPAT"

    /// `extraEnv`, line by line, in order (a later line wins): `KEY=VALUE` sets KEY, `KEY=`
    /// removes it (nil). A line with no `=`, or no name before it, is ignored.
    var extraEnvironment: [(key: String, value: String?)] {
        extraEnv.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, value.isEmpty ? nil : value)
        }
    }

    /// Environment applied to the wine process.
    /// - Parameter x87: whether this world may use x87 acceleration (`Server.x87`).
    /// - Parameter world: names the default frame-rate log, so two clients never share one.
    /// - Parameter gameWine: the client runs under the patched game Wine (`X87Sidecar.patchedWine`),
    ///   not the wrapper's own.
    /// - Parameter gameSize: the size the client will be started at (`GameWindow.launchSize`), for
    ///   `HXI_GAME_ASPECT`; nil when unknown.
    func environment(for install: Install, x87: Bool = true, world: String = "",
                     gameWine: Bool = true, gameSize: WindowMemory.Size? = nil) -> [String: String] {
        var env: [String: String] = [:]
        env["WINEPREFIX"] = install.prefix.path
        env["D3DMETAL_FRAMEWORK_PATH"] = install.d3dMetal.path
        // Wine loads libMoltenVK and the rest of the wrapper's dylibs through this. The
        // wrapper's own launch script sets it; without it the Vulkan renderers come up to a
        // black window and sit there, which is a very confusing way to fail.
        env["DYLD_FALLBACK_LIBRARY_PATH"] = install.frameworks.path + ":/usr/lib"
        if silenceWineDebug { env["WINEDEBUG"] = "-all" }
        env["WINEMSYNC"] = msync ? "1" : "0"
        env["WINEESYNC"] = (esync && !msync) ? "1" : "0"
        // Measured 2026-08-11: these two, together with WINEMSYNC above, took the same scene
        // from 17.6 fps to 22.8 fps (~30%). Neither touches rendering logic -- fast math only
        // relaxes float precision in generated Metal shaders, and command pooling reuses
        // Metal command buffer objects rather than reallocating them per frame -- so neither
        // can produce visual glitches. Always on.
        env["MVK_CONFIG_FAST_MATH_ENABLED"] = "1"
        // FFXI locks a 16x16 visibility render target ~4x/frame; stock DXVK makes that lock
        // wait behind the retirement thread's one-at-a-time fence processing (~15
        // submissions/frame x ~0.85 ms measured 2026-08-20 = most of a 26 ms stall). The
        // vendored DXVK's fence fast path waits on the lock's own submission fence instead —
        // exact (same bytes as the slow path; it is NOT the broken NOWAIT approximation),
        // in-world wait fell 28.8 -> 9 ms/frame, best run 25.1 vs 23.7 fps. Bounded to
        // surfaces <= 32 px. See patches/dxvk-1.10.3-horizonxi-fencewait.patch.
        env["D3D9_RT_READBACK_FENCE"] = "32"
        env["MVK_CONFIG_USE_COMMAND_POOLING"] = "1"
        // The last macOS 27 session emitted thousands of identical DXVK/MoltenVK warnings
        // after login. They are still available when explicitly requested for diagnostics,
        // but routine play should not spend time writing them or redrawing the log pane.
        env["DXVK_LOG_LEVEL"] = ProcessInfo.processInfo.environment["DXVK_LOG_LEVEL"] ?? "error"
        env["MVK_CONFIG_LOG_LEVEL"] = ProcessInfo.processInfo.environment["MVK_CONFIG_LOG_LEVEL"] ?? "1"
        env.removeValue(forKey: "MTL_HUD_ENABLED")  // never on a player's game
        // Only our patched d3d9.dll reads this; harmless (silently ignored) on the other
        // renderer pathways.
        if fpsDivisorOne { env["FFXI_FPS_DIVISOR"] = "1" }
        // 32 px bounds it to the small visibility-test surfaces; anything the game reads back at
        // a size it could actually display still waits.
        if flareReadbackNoWait { env["D3D9_RT_READBACK_NOWAIT"] = "32" }
        // x87 acceleration, the way athei's patched wine actually wants to be told about it.
        //
        // `ROSETTA_X87_PATH` is read by wine's own loader (athei/wine commit 3804c30b, "ntdll:
        // HACK: Recognize ROSETTA_X87_PATH and attach x87sidecar cooperatively"): i386 wine
        // processes re-exec through the named sidecar. The client is an Ashita grandchild, so
        // the launcher must verify in-world speed before treating a handshake as acceleration.
        //
        // Wrapping the command instead — `x87sidecar-coop --cooperative wine Ashita-cli.exe` —
        // reaches only the short-lived injector. Do not set ROSETTA_DISABLE_AOT by hand: when
        // the x87 hook fails, that forced slow path caused the measured 19x regression.
        if x87, let sidecar = X87Sidecar.coopBinary() {
            env["ROSETTA_X87_PATH"] = sidecar.path
        }
        // Frame-rate log, on demand: FFXI_ON_MAC_FPSLOG=1 in the launcher's own environment
        // makes the vendored DXVK write one CSV row per second (fps, draws, passes, barriers,
        // submits) next to the client. Set FFXI_ON_MAC_FPSLOG_PATH to override the destination,
        // for example to a Z: path in Downloads when preserving an older in-prefix fps.csv.
        // This is how a launch on the *shipped* path gets measured
        // rather than a hand-built shell run -- which is how a 19x x87 regression went unnoticed:
        // every fps number came from a shell that did not match what Play actually did.
        if ProcessInfo.processInfo.environment["FFXI_ON_MAC_FPSLOG"] == "1" {
            env["DXVK_FPS_LOG"] = ProcessInfo.processInfo.environment["FFXI_ON_MAC_FPSLOG_PATH"]
                ?? MultiWorld.fpsLogPath(gameDirName: install.gameDir.lastPathComponent, world: world)
        }
        // Sound-output following. Only set when the dylib is really there and really has the
        // slice this Mac will run wine as — a DYLD_INSERT_LIBRARIES pointing at a missing or
        // wrong-architecture file makes dyld noisy at best and aborts the process at worst, and
        // nothing here is worth risking a launch over.
        //
        // GOTCHA for anyone reworking the launch: this variable does NOT survive an exec through
        // `arch(1)` or any other system binary — dyld strips DYLD_* across those. The wine
        // command has to be exec'd directly. The hardened x87 sidecar strips it too; see
        // InsertedLibrary and the carry in window/gamewindow.c.
        if followSoundOutput, let dylib = AudioFollow.dylib() {
            InsertedLibrary.insert(dylib.path, into: &env)
        }
        // The game window keeps its shape when resized and its title "FFXI on Mac" (b69):
        // gamewindow.dylib, same rules, the ratio the client is started at and the title. Joined
        // to audiofollow's with ':' when both are on.
        if keepWindowShape {
            GameWindow.apply(to: &env, dylib: GameWindow.dylib(), size: gameSize)
        }
        if disableAppNap { env["LSAppNapIsDisabled"] = "1" }
        if largeAddressAware { env["WINE_LARGE_ADDRESS_AWARE"] = "1" }
        for (k, v) in renderer.environment { env[k] = v }
        // DXVK 1.10.3 never wrote its state cache beside horizon-loader.exe (none existed on
        // 2026-09-26), so every session recompiled every pipeline: turning the camera stalled.
        // An explicit C:\ path is written; a lap on local LSB went 7.5 -> 13.2 fps as it filled.
        if env["DXVK_STATE_CACHE_PATH"] == nil { env["DXVK_STATE_CACHE_PATH"] = #"C:\dxvk-cache"# }
        // DXVK reads $DXVK_CONFIG_FILE, else dxvk.conf in the cwd at the moment its instance is
        // created. The 2026-10-02 session logged 5 compiler threads and no "Found config file"
        // although C:\HorizonXI\dxvk.conf (4 threads) was there, so the shipped settings never
        // applied. One explicit file for every world instead (vendor/dxvk.conf, put in place by
        // RendererSetup.syncDXVKConfig).
        if env["DXVK_CONFIG_FILE"] == nil { env["DXVK_CONFIG_FILE"] = RendererSetup.dxvkConfigWinePath }
        // Keep no-execute on: the fault storm (b66, docs/BETA-66.md). The game's Wine
        // (athei/wine-build cx-26.3.0-1) turns NX off for the whole process as soon as any module
        // without the PE NX_COMPAT flag loads (i386 ntdll alloc_module ->
        // NtSetInformationProcess(ProcessExecuteFlags, MEM_EXECUTE_OPTION_ENABLE)). The loaders
        // and Ashita carry the flag; Square Enix's FFXiMain.dll, FFXi.dll, polhook.dll, app.dll
        // and polcore.dll do not, in every world. With NX off every readable page is mapped
        // executable, and under Rosetta that measured 85-94k page faults/s, 50-84% kernel time,
        // 2-minute zone loads and multi-second freezes (2026-10-15); with this set, the same
        // character select ran at ~3k faults/s and the game played normally. That build only
        // asks whether the variable exists. Reported upstream as athei/wine-build#3 and fixed in
        // cx-26.3.0-6, where "0" brings the slow behaviour back -- so always "1". Only for the
        // game's Wine: the wrapper's own build was never measured with it. An explicit value in
        // extraEnv (below) wins; `WINE_DISABLE_NX_COMPAT=` there removes it.
        if gameWine { env[Self.nxCompatKey] = "1" }
        for (key, value) in extraEnvironment {
            if let value { env[key] = value } else { env.removeValue(forKey: key) }
        }
        return env
    }
}
