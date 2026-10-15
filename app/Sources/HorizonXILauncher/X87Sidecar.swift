import Foundation
import CryptoKit

/// x87sidecar: patches Rosetta's x87 floating-point emulation with a native ARM64 JIT. FFXI's
/// 32-bit client runs its math through x87, which Rosetta emulates at roughly 1% of native
/// speed -- that is the actual bottleneck, not the renderer (see docs/X87-WALL.md), and fixing
/// it took in-world from 11.3 to 28.5 fps at max settings. Vendored and re-signed separately
/// from the app; see vendor/NOTICE.md for why.
enum X87Sidecar {
    /// Ships in the bundle; falls back to the repo's vendor/ copy under `swift run`.
    static func binary() -> URL? {
        if let u = Bundle.main.url(forResource: "x87sidecar_entitled", withExtension: nil) {
            return u
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HorizonXILauncher
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // app
            .appendingPathComponent("vendor/x87sidecar_entitled")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    /// Rosetta only calls the hook this patches if AOT compilation is disabled for the target --
    /// without it, everything is already translated before the sidecar can attach and there is
    /// nothing left to hook. Belongs on the *game's* environment, set before it launches.
    static let requiredEnvironment = ["ROSETTA_DISABLE_AOT": "1"]

    /// The patched CrossOver wine from athei/wine-build (`wine-cx-26.3.0-1`, "wine-coop"), per
    /// machine, never in the app bundle.
    ///
    /// It arrived here for x87 cooperative mode, but it matters on its own: **the wrapper's own
    /// wine kills the client one second after login.** Measured 2026-08-21, same prefix, same
    /// profile, same environment, twice each -- `siku.app/Contents/SharedSupport/wine/bin/wine`
    /// reaches "Successfully logged in", prints "Closing..." a second later and exits (it starts
    /// Ashita-cli "in experimental wow64 mode"), while this wine runs on indefinitely. So this is
    /// the launch wine whenever it is present, sidecar or no sidecar. See docs/WINE-BUILD.md.
    /// Where the patched wine is looked for, in order. `OwnWine` counts a Windows program
    /// running under any of them as this launcher's.
    ///
    /// First the "FFXI on Mac" folder the user chose, where Setup installs it since b60
    /// (scripts/game-wine.sh; read from defaults only, no volume is touched to list it), and the
    /// ones chosen before it, then the places it was installed by hand before that, so those
    /// installs keep the copy they have.
    static var patchedWineCandidates: [String] {
        ((InstallLocation.remembered.map { [$0] } ?? []) + InstallLocation.earlier).map { InstallLocation.gameWine(in: $0).path }
            + fixedWineCandidates
    }

    static let fixedWineCandidates = [
        "/Volumes/Games/FFXI/wine-coop/wine/bin/wine",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BatesAI/ffxi-runtime/wine-coop/wine/bin/wine").path,
        "/Volumes/x10/Video Games/Mac/FFXI/wine-coop/wine/bin/wine",
        "/Volumes/x10/Daniel Backup/Mac Offload/ffxi-runtime/wine-coop/wine/bin/wine"
    ]

    static func patchedWine() -> URL? {
        // Tests (`--fix` on a fixture prefix) point this at a stub so no real wine ever runs.
        if let o = ProcessInfo.processInfo.environment["FFXI_ON_MAC_WINE"], !o.isEmpty {
            return FileManager.default.isExecutableFile(atPath: o) ? URL(fileURLWithPath: o) : nil
        }
        for p in patchedWineCandidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    /// The cooperative sidecar binary alone, for `ROSETTA_X87_PATH`.
    ///
    /// This — not wrapping the command — is how the patched wine wants to be told about the
    /// sidecar. See `Settings.environment`.
    static func coopBinary() -> URL? {
        if let u = Bundle.main.url(forResource: "x87sidecar-coop", withExtension: nil) { return u }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/x87sidecar-coop")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    /// Cooperative-mode pieces: the unentitled sidecar (bundled, or vendor/ under `swift run`)
    /// plus the handshake-patched CX wine from athei/wine-build. Both must exist; the wine is
    /// a per-machine install because it is 700 MB unpacked. See docs/X87-WALL.md.
    static func cooperative() -> (sidecar: URL, wine: URL)? {
        guard let wine = patchedWine() else { return nil }
        if let u = Bundle.main.url(forResource: "x87sidecar-coop", withExtension: nil) {
            return (u, wine)
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/x87sidecar-coop")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? (dev, wine) : nil
    }

    /// Poll for horizon-loader.exe -- the process Ashita actually runs the client in, not the
    /// injector (Ashita-cli.exe) that launches it and exits within a second or two. Attaching to
    /// the injector is a silent no-op: it installs, logs success, and patches a process that
    /// renders nothing, which cost hours to notice the first time. See docs/X87-WALL.md.
    private static func findGamePID(timeout: TimeInterval = 40) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = await Task.detached(priority: .userInitiated, operation: {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                p.arguments = ["-f", await MainActor.run { Runner.currentGameExe }]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { return Int32?.none }
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8),
                      let first = text.split(separator: "\n").first
                else { return Int32?.none }
                return Int32(first)
            }).value {
                return pid
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    /// Wait for the game process, then attach. Returns the sidecar process so the caller can
    /// terminate it when the game exits -- unlike the game, it does not exit on its own.
    static func attachWhenReady(log: @escaping @MainActor (String) -> Void) async -> Process? {
        guard let bin = binary() else {
            await log("!! x87sidecar_entitled missing from the bundle -- "
                      + "running at Rosetta's stock x87 speed")
            return nil
        }
        guard let pid = await findGamePID() else {
            await log("!! x87sidecar: \(await MainActor.run { Runner.currentGameExe }) never appeared, gave up after 40s")
            return nil
        }
        // Ashita-cli.exe is still writing into this same process's memory for a moment after
        // the pid first appears -- attaching immediately races its injection and intermittently
        // corrupts it ("wine client error: write: Bad file descriptor", "Injection failed!").
        // Ashita's own injection is quick; giving it a few seconds' head start avoids the race
        // without meaningfully delaying the JIT (Rosetta has not finished cold-JITing the first
        // blocks in this window anyway).
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let p = Process()
        p.executableURL = bin
        p.arguments = ["--attach", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in log("[x87sidecar] " + s) }
        }
        do {
            try p.run()
            await log("==> x87sidecar attached to pid \(pid)")
            return p
        } catch {
            await log("!! x87sidecar failed to launch: \(error.localizedDescription)")
            return nil
        }
    }
}

/// x87 acceleration is on by default on every macOS version; this remembers where it did not
/// attach, so Play falls back to stock Rosetta instead of paying for a JIT that is not there.
///
/// Why a guard and not a version gate: every best max-settings figure this project has
/// (37.9-51 fps median in-world, 2026-09-25..27) was taken on macOS 27.0 with the sidecar on,
/// and stock Rosetta measured ~11 fps in-world. The real risk is narrower: the sidecar sets
/// `ROSETTA_DISABLE_AOT=1` for its target before exec, so a target whose hook never installs
/// runs Rosetta's slow JIT path with no x87 JIT behind it (the 19x loss in docs/X87-SIDECAR.md).
/// When that is seen (once for the sidecar's own failure lines, in two sessions in a row for a
/// sidecar simply gone, which can be timing), the pairing of this macOS build and this sidecar
/// binary is recorded and later launches leave `ROSETTA_X87_PATH` off until either changes. The
/// running client is never touched.
enum X87Guard {
    static let defaultsKey = "x87.brokenFor"

    /// Lines the sidecar prints when it cannot hook the process it was started for (all from
    /// rosetta_loader/src/main.cpp; each is followed by `return 1`, so the sidecar exits). Every
    /// one of these is decided by the Rosetta runtime and the sidecar binary, not by timing,
    /// which is exactly what the fingerprint records. A normal session prints none of them
    /// (launcher.log, 2026-10-02, x87 on: zero `[rosettax87]` lines).
    static let failureMarkers = [
        "[rosettax87] bootstrap_register2(",
        "[rosettax87] cooperative reply failed",
        "Failed to attach",
        "Failed to find Rosetta runtime by signature",
        "Failed to locate translate_insn by signature scan",
        "Failed to arm thread-level breakpoint catcher",
        "M2: failed", "M2: sidecar::installPortInParent failed",
        "M2: stub_asm::buildDecodeHook refused",
    ]
    /// The one failure that depends on timing: no handshake inside the sidecar's 30 s window.
    /// Any i386 wine process that dies before its handshake prints it, so on its own it says
    /// nothing about the client. The client's own case is caught by its sidecar being gone
    /// (`Runner`'s check a minute after the loader appears), which this only notes in the log.
    /// That check is timing too (a client that needs over 30 s to reach the handshake under
    /// heavy swap looks the same), so it counts only in two sessions in a row: `suspectKey`.
    static let timeoutMarker = "[rosettax87] cooperative handshake receive failed"
    /// The fingerprint whose last checked session had no sidecar a minute in. Cleared when a
    /// session sees its sidecar alive.
    static let suspectKey = "x87.suspectFor"

    /// The first failure line in `text`, if any.
    static func failure(in text: String) -> String? {
        guard text.contains("[rosettax87]") || text.contains("Failed to") || text.contains("M2: ") else { return nil }
        for m in failureMarkers {
            if let r = text.range(of: m) {
                let line = text[r.lowerBound...].split(whereSeparator: \.isNewline).first.map(String.init) ?? m
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// macOS build, e.g. "26A434" (`sysctl kern.osversion`); the marketing version is not enough,
    /// a point update can change libRosettaRuntime.
    static func osBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buf, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        return String(cString: buf)
    }

    private static let hashLock = NSLock()
    private static var hashCache: [String: String] = [:]

    /// SHA-256 of the sidecar binary, cached per path, size and mtime (470 KB, read once).
    static func sha256(of url: URL) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\((attrs?[.size] as? NSNumber)?.intValue ?? -1)|"
            + "\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        hashLock.lock()
        if let h = hashCache[stamp] { hashLock.unlock(); return h }
        hashLock.unlock()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        hashLock.lock(); hashCache[stamp] = h; hashLock.unlock()
        return h
    }

    /// "<macOS build>|<sidecar sha256>", or nil when the sidecar cannot be read.
    static func fingerprint(sidecar: URL) -> String? {
        sha256(of: sidecar).map { osBuild() + "|" + $0 }
    }

    /// Did the sidecar fail to attach on this exact macOS build with this exact binary?
    static func isBroken(sidecar: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let stored = defaults.string(forKey: defaultsKey), !stored.isEmpty else { return false }
        return stored == fingerprint(sidecar: sidecar)
    }

    static func markBroken(sidecar: URL, defaults: UserDefaults = .standard) {
        guard let f = fingerprint(sidecar: sidecar) else { return }
        defaults.set(f, forKey: defaultsKey)
        defaults.removeObject(forKey: suspectKey)
    }

    /// A session with no sidecar a minute in. True when the previous checked session of this
    /// same pairing showed it too (the caller then records it); otherwise it is only noted.
    static func timingFailure(sidecar: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let f = fingerprint(sidecar: sidecar) else { return false }
        if defaults.string(forKey: suspectKey) == f { return true }
        defaults.set(f, forKey: suspectKey)
        return false
    }

    /// The sidecar was seen alive: a single earlier timing failure was not the pairing's fault.
    static func clearSuspect(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: suspectKey)
    }

    /// Whether this launch uses the sidecar. `override` is `FFXI_ON_MAC_X87` from the launcher's
    /// environment: "0" forces it off, "1" forces it on past a recorded failure (for an A/B).
    /// A world whose client cannot take the sidecar (`Server.x87` false) never gets it.
    static func enabled(worldAllows: Bool, override: String?, brokenHere: Bool) -> Bool {
        guard worldAllows else { return false }
        switch override {
        case "0": return false
        case "1": return true
        default: return !brokenHere
        }
    }
}
