import Foundation

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

    /// The patched CrossOver wine from athei/wine-build, installed per machine at this path.
    ///
    /// It arrived here for x87 cooperative mode, but it matters on its own: **the wrapper's own
    /// wine kills the client one second after login.** Measured 2026-08-21, same prefix, same
    /// profile, same environment, twice each -- `siku.app/Contents/SharedSupport/wine/bin/wine`
    /// reaches "Successfully logged in", prints "Closing..." a second later and exits (it starts
    /// Ashita-cli "in experimental wow64 mode"), while this wine runs on indefinitely. So this is
    /// the launch wine whenever it is present, sidecar or no sidecar. See docs/WINE-BUILD.md.
    /// Where the patched wine is looked for, in order. `OwnWine` counts a Windows program
    /// running under any of them as this launcher's.
    static let patchedWineCandidates = [
        "/Volumes/Games/FFXI/wine-coop/wine/bin/wine",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BatesAI/ffxi-runtime/wine-coop/wine/bin/wine").path,
        "/Volumes/x10/Video Games/Mac/FFXI/wine-coop/wine/bin/wine",
        "/Volumes/x10/Daniel Backup/Mac Offload/ffxi-runtime/wine-coop/wine/bin/wine"
    ]

    static func patchedWine() -> URL? {
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
