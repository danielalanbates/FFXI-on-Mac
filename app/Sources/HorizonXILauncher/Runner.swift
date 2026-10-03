import Foundation
import Darwin
import Combine
import AppKit

/// Runs the repair script and the game itself, streaming output back to the UI. One per world
/// session (see `Sessions`): several worlds can play at once in the same prefix.
@MainActor
final class Runner: ObservableObject {
    @Published var log: String = ""
    @Published var running = false {
        didSet {
            if !running { Runner.playing[ObjectIdentifier(self)] = nil; starting = false }
            else if !oldValue {
                // Wine boots its prefix before the game window appears; after a Repair that takes
                // ~30-60s and looks like a hang unless the UI says so.
                starting = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    self?.starting = false
                }
            }
        }
    }
    @Published var starting = false
    /// True while update-client.sh is applying HorizonXI updates; lets the UI offer Stop.
    @Published var updatingHorizon = false
    /// 0...1 across every pending update zip, and a short label ("2.0.4 · 1 of 2").
    @Published var updateProgress: Double = 0
    @Published var updateLabel = ""
    private var updateStep = (n: 1, total: 1)
    @Published var busy = false {
        didSet { if busy != oldValue { Runner.busyCount += busy ? 1 : -1 } }
    }
    /// The world, or "<world> #2" for a further client of a world that allows several.
    let session: String

    init(session: String = "") { self.session = session }

    /// Read by the app delegate on quit. Downloads and installs are child processes of this app,
    /// so quitting kills them -- a 7.7 GB download that was 6 GB in simply vanished, and the card
    /// went back to saying "Download…" with nothing to say why. Quitting mid-download now asks.
    /// Counted across every session: installers share one installer prefix, so one at a time.
    private static var busyCount = 0
    static var workInFlight: Bool { busyCount > 0 }

    /// Every session of this launcher that is playing, from the moment its launch passes the
    /// checks. A scan cannot see a launch until its injector exists; this can.
    private struct Playing {
        var world: String; var host: String; var group: pid_t?
        /// The group has been seen holding the loader; see `MultiWorld.sessionPIDs`.
        var groupHeldLoader = false
    }
    private static var playing: [ObjectIdentifier: Playing] = [:]

    private func othersPlaying() -> Int { Runner.playing.keys.filter { $0 != ObjectIdentifier(self) }.count }

    /// A session whose group has not yet held its loader is also known by its host, in case
    /// the loader turns up in a group of its own.
    static var playingGroups: (groups: Set<pid_t>, hostsWithoutGroup: Set<String>) {
        (Set(playing.values.compactMap(\.group)),
         Set(playing.values.filter { $0.group == nil || !$0.groupHeldLoader }.map(\.host)))
    }

    /// Why another client of `world` must not start now, counting this launcher's own sessions
    /// of it (even ones still injecting), every client the scan can see, and every injector
    /// the scan can see, by the world its boot profile names in `install` (another launcher
    /// process's launch is visible only that way for its first seconds).
    static func duplicateRefusal(world: String, hosts: [String], maxClients: Int,
                                 clients: [LiveClients.Client], install: Install?) -> String? {
        var own: Set<pid_t> = []
        for (n, p) in playing.values.enumerated() where p.world == world {
            // A session whose group is unknown still counts once; negative ids never collide.
            own.insert(p.group ?? pid_t(-1 - n))
        }
        return MultiWorld.refusal(world: world, hosts: hosts, maxClients: maxClients,
                                  clients: clients, sessionGroups: own,
                                  ownGroups: Set(playing.values.compactMap(\.group)),
                                  injectorHost: { file in
                                      install.flatMap { Credentials.bootServer(in: $0, profile: file) }
                                  })
    }

    /// Every long-running action refuses to start while another one is going. That refusal used
    /// to be a silent `return`, so pressing Download on a second world did nothing at all and
    /// said nothing about why -- which is exactly what "I pressed Download on all the servers and
    /// they still say Download" looked like. Now it says so in the log.
    private func refuseWhileBusy(_ what: String) -> Bool {
        guard Runner.workInFlight || running else { return false }
        appendLine("!! not starting \(what): something else is already running in the wrapper. "
                 + "Wait for it to finish (or press Stop), then try again.")
        return true
    }

    /// Repair runs wine in the game prefix and an update rewrites the shared client folder;
    /// neither belongs under a client that is playing or starting, from this window or another
    /// launcher. On success the launch lock is held until `endMaintenance`, so no launch in any
    /// launcher process can start underneath it.
    private func claimForMaintenance(_ what: String) -> Bool {
        let lock = LaunchLock.acquire()
        if let why = MultiWorld.maintenanceBlocker(LiveClients.scan(), sessionsPlaying: Runner.playing.count,
                                                   lockHeldElsewhere: lock == nil) {
            if let lock { LaunchLock.release(lock) }
            appendLine("!! not starting \(what): \(why). Wait for it to finish or stop it first.")
            return false
        }
        maintenanceLock = lock   // never nil here: a held lock is a blocker
        return true
    }

    private var maintenanceLock: Int32?

    private func endMaintenance() {
        if let l = maintenanceLock { LaunchLock.release(l) }
        maintenanceLock = nil
    }

    static func describe(_ live: [String: [pid_t]]) -> String { LiveClients.describe(live) }

    private var proc: Process?
    /// Executable Ashita boots the game in for the current launch (the boot profile's
    /// `[ashita.boot] file`): horizon-loader.exe on HorizonXI, pol.exe on CatsEyeXI, xiloader.exe
    /// elsewhere. Both the exit watcher and the x87 sidecar look for this, by name.
    private var gameExe = "horizon-loader.exe"
    static var currentGameExe = "horizon-loader.exe"

    /// Every FFXI graphics setting at max, 4K resolution. Registry keys documented in
    /// `[ffxi.registry]` of any Ashita boot .ini; mirrors `scripts/max4k.json`, which is the
    /// version the benchmark harness actually validated (25.6 fps in-world, up from an 11.3 fps
    /// pre-x87sidecar baseline). 0001/0002 are screen width/height; the rest are background and
    /// texture resolution, sound channels and mip mapping -- see max4k.json's own comment.
    /// Superseded by `GraphicsSettings.lowSpec`, which the local world is seeded with once
    /// rather than force-fed on every launch. Kept as the record of what this used to do.
    ///
    /// What the local test world runs at: as small as FFXI allows.
    ///
    /// This profile used to be pinned to 4K with everything maxed, because it was the benchmark
    /// harness's world and the point was to measure the ceiling. It is not that any more -- it is
    /// where addons and quests get tested, often with the launcher, a narrator and a second
    /// client alive on an 8 GB machine, and a 3840x2160 framebuffer costs real memory, bandwidth
    /// and battery for a window nobody is admiring.
    ///
    /// Only the resolutions are turned down. docs/SETTINGS-SWEEP.md measured the quality knobs on
    /// this Mac and they do not help -- "all low" was the *slowest* variant of the lot (9.71 fps
    /// against a 12.85 baseline) because the client is CPU-bound and mip mapping off makes the
    /// GPU sample full-size textures for distant geometry. So: fewer pixels, same quality per
    /// pixel. Expect this to cost less power and memory, not to raise the frame rate.
    ///   0001/0002 window, 0037/0038 menu, 0003/0004 background and map textures.
    private static let lowSpecRegistry: [String: String] = [
        "0001": "640", "0002": "480",
        "0037": "640", "0038": "480",
        "0003": "1024", "0004": "1024",
    ]

    private static let max4KRegistry: [String: String] = [
        "0000": "6", "0001": "3840", "0002": "2160", "0003": "4096", "0004": "4096",
        "0011": "2", "0018": "2", "0019": "1", "0021": "1", "0029": "20",
        "0007": "1", "0035": "1",
    ]

    /// Raw stream text, which arrives mid-line and unbounded — a whole session of wine and Ashita
    /// output is megabytes, and SwiftUI re-lays-out the entire string on every change, so the cap
    /// matters for responsiveness as much as for memory.
    /// Everything that reaches the log pane also goes to disk, so a failed launch can be read
    /// after the fact (and pasted into a bug report) without scrolling a UI. Overwritten per
    /// app run; the previous run is kept as launcher.log.1.
    static let logFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("launcher.log")
        let prev = dir.appendingPathComponent("launcher.log.1")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: f, to: prev)
        FileManager.default.createFile(atPath: f.path, contents: nil)
        return f
    }()
    private lazy var logHandle: FileHandle? = try? FileHandle(forWritingTo: Self.logFile)

    /// A line for the launcher log from outside any session (a forwarded request dropped while
    /// no window was open), and stderr.
    static func appendToLogFile(_ s: String) {
        let line = s.hasSuffix("\n") ? s : s + "\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard let h = try? FileHandle(forWritingTo: logFile) else { return }
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    }

    private func tee(_ s: String) {
        // A headless run (--play/--check) has no log strip to read, and its silence is exactly
        // what made --play look like it did nothing for weeks. Mirror to stderr there.
        if Headless.isHeadlessRun, let d = s.data(using: .utf8) {
            FileHandle.standardError.write(d)
        }
        guard let h = logHandle, let d = s.data(using: .utf8) else { return }
        h.seekToEndOfFile(); h.write(d)
    }

    /// The boot loader's verdict when a login is refused ("Failed to login. Invalid username or
    /// password." / "…Account already logged in." / "…xiloader version mismatch…"). Every xiloader
    /// fork prints one of these and then sits at an interactive menu that no window ever shows,
    /// so the launcher would otherwise look hung. Surfaced to the UI and the loader is stopped.
    @Published var loginFailure: String = ""
    private var currentInstall: Install?
    private var currentProfile = "horizonxi.ini"
    private var currentWorld = ""

    func appendChunk(_ s: String) {
        var s = s
        if updatingHorizon {
            // aria2's readout becomes the progress bar instead of hundreds of log lines.
            for line in s.split(whereSeparator: \.isNewline) {
                let l = String(line)
                if let m = l.range(of: #"==> update (\S+) \((\d+)/(\d+)\)"#, options: .regularExpression) {
                    let parts = l[m].dropFirst(11).split(separator: " ")
                    let nums = parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: "/") ?? []
                    if nums.count == 2, let n = Int(nums[0]), let t = Int(nums[1]) {
                        updateStep = (n, max(t, 1))
                        updateLabel = "\(parts.first ?? "") · \(n) of \(t)"
                    }
                    updateProgress = Double(updateStep.n - 1) / Double(updateStep.total)
                } else if let m = l.range(of: #"\((\d+)%\)"#, options: .regularExpression),
                          let pct = Double(l[m].dropFirst().dropLast(2)) {
                    updateProgress = (Double(updateStep.n - 1) + pct / 100 * 0.9) / Double(updateStep.total)
                } else if l.contains("==> extracting") {
                    updateProgress = (Double(updateStep.n - 1) + 0.9) / Double(updateStep.total)
                }
            }
            s = s.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { l in let t = l.trimmingCharacters(in: .whitespaces)
                          return !(t.hasPrefix("[#") || t.hasPrefix("***") || t.hasPrefix("====") || t.hasPrefix("FILE:") || t.hasPrefix("----")) }
                .joined(separator: "\n")
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        }
        tee(s)
        // Every xiloader fork prints one of these and drops to an interactive menu no window shows.
        let failMarkers = ["Failed to login", "Bad json reply from remote", "Error from remote",
                           "version mismatch", "xi_connect", "Account already logged in"]
        if loginFailure.isEmpty, let hit = failMarkers.first(where: { s.contains($0) }),
           let r = s.range(of: hit) {
            let raw = String(s[r.lowerBound...]).split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? hit
            let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \u{1b}[m")).trimmingCharacters(in: .whitespaces)
            loginFailure = hit == "Bad json reply from remote"
                ? "The login server sent a reply this client could not read. Usually the wrong password, an account that does not exist, or a client-version mismatch."
                : (clean.isEmpty ? hit : clean)
            appendLine("!! login refused: \(loginFailure) — stopping the loader")
            if let i = currentInstall { stop(i) }
        }
        log += s
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    func appendLine(_ s: String) {
        tee(s.hasSuffix("\n") ? s : s + "\n")
        log += s.hasSuffix("\n") ? s : s + "\n"
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    /// Working directory for bundled scripts. Never the bundle itself: wine tools (regsvr32)
    /// drop log files into their cwd, and one stray file inside the .app breaks its signature.
    static var scratchDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac/work", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// install.sh ships inside the app bundle; fall back to the repo copy when running from
    /// `swift run`.
    static func repairScript() -> URL? {
        if let u = Bundle.main.url(forResource: "install", withExtension: "sh") { return u }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HorizonXILauncher
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // app
            .appendingPathComponent("scripts/install.sh")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    func repair(_ install: Install) {
        guard claimForMaintenance("Repair") else { return }
        guard let script = Self.repairScript() else {
            endMaintenance()
            appendLine("!! install.sh not found in the bundle"); return
        }
        busy = true
        appendLine("==> repairing \(install.wrapper.path) [\(install.prefixName)]")
        // Cheap, local, and the difference between "logs in then quits" and a playable game.
        Sandbox.repair(install) { [weak self] in self?.appendLine($0) }
        spawn(URL(fileURLWithPath: "/bin/zsh"),
              args: [script.path, install.wrapper.path, install.prefixName],
              env: [:], cwd: Self.scratchDir) { [weak self] code in
            self?.endMaintenance()
            self?.busy = false
            self?.appendLine("==> repair exited \(code)")
            if code == 0, let self { Task { await self.syncPrefixIfStale(install) } }
        }
    }

    /// `scripts/update-client.sh` ships next to install.sh in the bundle.
    static func updateScript() -> URL? {
        if let u = Bundle.main.url(forResource: "update-client", withExtension: "sh") { return u }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/update-client.sh")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    /// Apply every pending HorizonXI game update (torrent, so it can take a while), then report.
    func updateHorizon(_ install: Install, done: @escaping (Bool) -> Void) {
        guard !Runner.workInFlight, !running else { appendLine("!! something else is running in the wrapper — try again when it finishes"); done(false); return }
        guard claimForMaintenance("the HorizonXI update") else { done(false); return }
        guard let script = Self.updateScript() else {
            endMaintenance()
            appendLine("!! update-client.sh not found in the bundle"); done(false); return
        }
        busy = true
        updatingHorizon = true
        updateProgress = 0; updateLabel = ""; updateStep = (1, 1)
        appendLine("==> updating HorizonXI game files in \(install.gameDir.path)")
        var env: [String: String] = [:]
        // aria2c comes from Homebrew; a bundled app's PATH does not include it.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        spawn(URL(fileURLWithPath: "/bin/zsh"),
              args: [script.path, "horizon", install.gameDir.path],
              env: env, cwd: Self.scratchDir) { [weak self] code in
            self?.endMaintenance()
            self?.busy = false
            self?.updatingHorizon = false
            self?.appendLine("==> update exited \(code)")
            done(code == 0)
        }
    }

    /// Stop a running HorizonXI update. aria2c resumes from its .aria2 file next time, and a zip
    /// is only extracted once fully downloaded, so stopping mid-download leaves the client as it was.
    func stopHorizonUpdate() {
        guard updatingHorizon, let p = proc, p.isRunning else { return }
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-TERM", "-P", String(p.processIdentifier)]
        try? k.run(); k.waitUntilExit()
        p.terminate()
        appendLine("==> update stopped")
    }

    /// Run CatsEyeXI's own launcher inside the prefix (scripts/catseye-launcher.sh). Their
    /// client only comes from that launcher; running it under wine is the whole integration.
    /// Make `C:\Games\<name>` inside the prefix point at the folder the user chose, so a Windows
    /// installer's default path lands the files where the launcher will look for them.
    static func linkGamesFolder(_ name: String, to dataPath: String, in install: Install) {
        guard !dataPath.isEmpty else { return }
        let games = install.driveC.appendingPathComponent("Games")
        try? FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        let link = games.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: dataPath))
    }

    /// Wine compares the prefix's `.update-timestamp` with `wine.inf`'s mtime at every start and,
    /// when they differ (a new wrapper, a Repair, a copied drive), stops to "update the Wine
    /// configuration" -- with Mono/Gecko install prompts -- in front of the game. Do that update
    /// here, quietly, while nothing is running, so Play never meets it.
    nonisolated static func prefixStale(_ install: Install) -> Bool {
        // The wine Play really runs (see launch): its wine.inf is the one it compares against.
        let inf = playWine(install).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/wine/wine.inf")
        guard let m = (try? FileManager.default.attributesOfItem(atPath: inf.path))?[.modificationDate] as? Date
        else { return false }
        let ts = install.prefix.appendingPathComponent(".update-timestamp")
        guard let txt = try? String(contentsOf: ts, encoding: .utf8) else { return true }
        // Wine writes CRLF here. Splitting only on "\n" leaves a trailing "\r", so Int fails
        // and we run wineboot -u again on every launch, bringing its progress window forward.
        let first = txt.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if first == "disable" { return false }
        return Int(first) != Int(m.timeIntervalSince1970)
    }

    nonisolated static func playWine(_ install: Install) -> URL { X87Sidecar.patchedWine() ?? install.wine }

    /// Runs `wineboot -u` with Mono and Gecko disabled (their installers are what ask questions).
    nonisolated static func updatePrefix(_ install: Install) -> Bool {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = install.prefix.path; env["WINEDEBUG"] = "-all"
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        env.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH"); env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        let wine = playWine(install)
        let p = Process(); p.executableURL = wine; p.arguments = ["wineboot", "-u"]; p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let k = Process(); k.executableURL = wine.deletingLastPathComponent().appendingPathComponent("wineserver"); k.arguments = ["-w"]
        k.environment = ["WINEPREFIX": install.prefix.path]
        k.standardOutput = FileHandle.nullDevice; k.standardError = FileHandle.nullDevice
        guard (try? k.run()) != nil else { return false }
        k.waitUntilExit()
        return p.terminationStatus == 0 && k.terminationStatus == 0
    }

    /// Background check at launcher start and after a Repair. Skipped while any client runs.
    func syncPrefixIfStale(_ install: Install) async {
        guard !running, LiveClients.snapshot().clients.isEmpty else { return }
        guard await Task.detached(operation: { Self.prefixStale(install) }).value else { return }
        // A stale prefix is shared maintenance. Hold the same lock as Play and Repair so a
        // click during wineboot cannot start the client against half-updated registry files.
        guard claimForMaintenance("Wine prefix update") else { return }
        busy = true
        defer { busy = false; endMaintenance() }
        guard await Task.detached(operation: { Self.prefixStale(install) }).value else { return }
        appendLine("==> updating Wine's configuration (one time, about 20 s)")
        // Wine's update progress is a native Wine window. Hide only Wine processes launched for
        // this update, once each; never hide Terminal or any unrelated application.
        let wineRoot = Self.playWine(install).deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL.path + "/"
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let path = app.executableURL?.standardizedFileURL.path,
                  path.hasPrefix(wineRoot) else { return }
            app.hide()
        }
        let ok = await Task.detached { Self.updatePrefix(install) }.value
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        appendLine(ok ? "==> Wine is up to date" : "!! Wine prefix update did not finish")
    }

    /// Make sure the wrapper's installer prefix exists (see `Install.installerPrefix`). Slow the
    /// first time only; runs off the main actor and calls back on it.
    func ensureInstallerPrefix(_ install: Install, then: @escaping (Install) -> Void) {
        let ip = install.installerPrefix
        if FileManager.default.fileExists(atPath: ip.systemReg.path) { then(ip); return }
        appendLine("==> creating \(ip.prefixName) (a second wine prefix for installers, so a download is never killed by Play) — about 30 s")
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = ip.prefix.path; env["WINEDEBUG"] = "-all"
        env.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH"); env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        Task.detached {
            let p = Process()
            p.executableURL = ip.wine; p.arguments = ["wineboot", "-u"]; p.environment = env
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let k = Process(); k.executableURL = ip.wineserver; k.arguments = ["-k"]; k.environment = ["WINEPREFIX": ip.prefix.path]
            try? k.run(); k.waitUntilExit()
            await MainActor.run { then(ip) }
        }
    }

    /// Download a server's Windows installer and run it inside the *installer* prefix. The user
    /// drives the installer's own UI; `dataPath` is pre-linked as `C:\Games\<name>` for it to
    /// install into (and the same link is made in the game prefix, so a path the installer wrote
    /// into a config file resolves at play time too).
    func runInstaller(from url: URL, in gameInstall: Install, dataPath: String, name: String = "") {
        if refuseWhileBusy("the installer for \(name.isEmpty ? url.lastPathComponent : name)") { return }
        busy = true
        let nm = name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
        Self.linkGamesFolder(nm, to: dataPath, in: gameInstall)
        ensureInstallerPrefix(gameInstall) { [weak self] install in
            guard let self else { return }
            Self.linkGamesFolder(nm, to: dataPath, in: install)
            self.runInstallerNow(from: url, in: install, name: nm)
        }
    }

    private func runInstallerNow(from url: URL, in install: Install, name nm: String) {
        // Installers are big (Eden's is 5.8 GB) and served from places that support ranges, so
        // fetch with curl: resumable (-C -), retried, and its progress bar streams into the log.
        // Saved next to the world's data rather than in the prefix -- that is where the space is.
        let dl = install.driveC.appendingPathComponent("Games/\(nm)/installer-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        let file = dl.appendingPathComponent(Self.downloadName(for: url, world: nm))
        appendLine("==> downloading \(url.absoluteString)\n    to \(file.path)")
        spawn(URL(fileURLWithPath: "/usr/bin/curl"),
              args: ["-fL", "--retry", "5", "--retry-delay", "3", "-C", "-", "--progress-bar",
                     "-A", "FFXI-on-Mac", "-o", file.path, url.absoluteString],
              env: [:], cwd: dl) { [weak self] code in
            guard let self else { return }
            // curl 33 = server refused the range because the file is already complete.
            guard code == 0 || (code == 33 && FileManager.default.fileExists(atPath: file.path)) else {
                self.appendLine("!! download failed (curl \(code)). If \(nm) has moved its installer, get it from their site and use Run installer….")
                self.busy = false
                if let page = self.installPageFallback { NSWorkspace.shared.open(page) }
                return
            }
            self.appendLine("==> downloaded \(file.lastPathComponent)")
            self.runDownloadedInstaller(file, in: install, name: nm)
        }
    }

    /// Download a plain client archive and unpack it into the world's data folder. No Windows
    /// installer is involved, so nothing has to be driven and no second prefix is needed.
    /// Resumable: a part-downloaded archive is continued, and the size is checked against what
    /// the server reports before unpacking, because a truncated archive that is never verified is
    /// how "Eden didn't work" happened (3.30 GB of 5.77 GB, silently).
    func installClientZip(from url: URL, into dataPath: String, name nm: String) {
        if refuseWhileBusy("the \(nm) client download") { return }
        guard !dataPath.isEmpty else { appendLine("!! no folder chosen for \(nm)"); return }
        busy = true
        let dest = URL(fileURLWithPath: dataPath, isDirectory: true)
        let dl = dest.appendingPathComponent("installer-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        let file = dl.appendingPathComponent(Self.downloadName(for: url, world: nm))
        appendLine("==> downloading \(nm)'s client\n    \(url.absoluteString)\n    to \(file.path)")
        spawn(URL(fileURLWithPath: "/usr/bin/curl"),
              args: ["-fL", "--retry", "5", "--retry-delay", "3", "-C", "-", "--progress-bar",
                     "-A", "FFXI-on-Mac", "-o", file.path, url.absoluteString],
              env: [:], cwd: dl) { [weak self] code in
            guard let self else { return }
            guard code == 0 || (code == 33 && FileManager.default.fileExists(atPath: file.path)) else {
                self.appendLine("!! download failed (curl \(code)).")
                self.busy = false
                if let page = self.installPageFallback { NSWorkspace.shared.open(page) }
                return
            }
            self.appendLine("==> unpacking \(file.lastPathComponent) into \(dest.path) — this takes a while for a client-sized archive")
            self.spawn(URL(fileURLWithPath: "/usr/bin/ditto"),
                       args: ["-x", "-k", file.path, dest.path], env: [:], cwd: dest) { [weak self] rc in
                guard let self else { return }
                self.busy = false
                if rc == 0 {
                    self.appendLine("==> \(nm) unpacked. Press ↻ — the checks re-run against the new files.")
                } else {
                    self.appendLine("!! unpacking failed (ditto \(rc)). The archive is kept at \(file.path); a truncated download is the usual cause — run this again and it resumes.")
                }
            }
        }
    }

    /// Where to send the user if the direct download for the world dies (set by the caller).
    var installPageFallback: URL? = nil

    /// A sensible file name for a download whose URL may end in a query string (Google Drive).
    static func downloadName(for url: URL, world: String) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/", last.contains(".") { return last }
        return world.replacingOccurrences(of: " ", with: "") + "-installer.zip"
    }

    /// Unpack a zip if it is one, find the installer .exe, run it.
    private func runDownloadedInstaller(_ file: URL, in install: Install, name nm: String) {
        var exe = file
        let isZip = file.pathExtension.lowercased() == "zip" || Self.looksLikeZip(file)
        if isZip {
            let out = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-unpacked", isDirectory: true)
            appendLine("==> unpacking \(file.lastPathComponent)")
            try? FileManager.default.removeItem(at: out)
            let d = Process(); d.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); d.arguments = ["-x", "-k", file.path, out.path]
            d.standardOutput = Pipe(); d.standardError = Pipe()
            try? d.run(); d.waitUntilExit()
            guard d.terminationStatus == 0, let found = Self.firstExe(under: out) else {
                appendLine("!! could not unpack \(file.lastPathComponent) or no .exe inside it"); busy = false; return
            }
            exe = found
        }
        launchInstaller(exe: exe, in: install, name: nm)
    }

    static func looksLikeZip(_ file: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 4)
        return d.count == 4 && d[0] == 0x50 && d[1] == 0x4B
    }

    /// Run an installer the user already has on disk (their server's site, Discord, a USB stick)
    /// inside the installer prefix. Zips are unpacked first and the first .exe inside is run.
    func runLocalInstaller(_ file: URL, in gameInstall: Install, dataPath: String, name: String) {
        if refuseWhileBusy("the installer for \(name)") { return }
        busy = true
        Self.linkGamesFolder(name, to: dataPath, in: gameInstall)
        ensureInstallerPrefix(gameInstall) { [weak self] install in
            guard let self else { return }
            Self.linkGamesFolder(name, to: dataPath, in: install)
            self.runDownloadedInstaller(file, in: install, name: name)
        }
    }

    static func firstExe(under dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var hits: [URL] = []
        for case let u as URL in e where u.pathExtension.lowercased() == "exe" { hits.append(u) }
        // Prefer a launcher/installer/setup name at the shallowest depth.
        return hits.sorted { a, b in
            let da = a.pathComponents.count, db = b.pathComponents.count
            if da != db { return da < db }
            let sa = a.lastPathComponent.lowercased(), sb = b.lastPathComponent.lowercased()
            let ka = ["launcher", "install", "setup"].contains { sa.contains($0) }, kb = ["launcher", "install", "setup"].contains { sb.contains($0) }
            if ka != kb { return ka }
            return sa < sb
        }.first
    }

    /// Does this PE identify itself as a Nullsoft (NSIS) installer? Those take `/S` (silent) and
    /// `/D=<dir>` (target), which is the difference between a world that installs unattended and
    /// one that needs somebody sitting in front of a wine window clicking Next. Verified
    /// 2026-08-21 on Eden's `Installer.exe` (NSIS 3.06.1) and FFEra's `FFEraInstaller-Jan2023.exe`
    /// (NSIS 3.08). Note `/D=` is advisory: Eden's script overrides it and installs to its own
    /// `C:\Eden` regardless, which is why `findInstalledClient` runs afterwards.
    static func isNSIS(_ exe: URL) -> Bool {
        guard let d = try? Data(contentsOf: exe, options: .mappedIfSafe) else { return false }
        let needle = Array("Nullsoft.NSIS.exehead".utf8)
        // The marker sits in the manifest near the front of the file; a few MB is plenty and
        // beats mapping a 157 MB installer's worth of pages through a search.
        let window = d.prefix(4 << 20)
        return window.range(of: Data(needle)) != nil
    }

    /// Where a just-run installer actually put the client: the newest folder under the prefix's
    /// `drive_c` (or under the world's own folder) holding an Ashita launcher. Needed because an
    /// NSIS script may ignore `/D=` entirely.
    static func findInstalledClient(in install: Install, world: String) -> URL? {
        let roots = [install.driveC, install.driveC.appendingPathComponent("Games")]
        let fm = FileManager.default
        for root in roots {
            guard let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for kid in kids {
                for probe in ["Ashita-cli.exe", "Ashita/Ashita-cli.exe", "Ashita.exe", "Ashita/Ashita.exe"]
                where fm.fileExists(atPath: kid.appendingPathComponent(probe).path) {
                    return kid
                }
            }
        }
        return nil
    }

    /// Called with the folder an installer left the client in, when one is found.
    var onClientInstalled: ((URL) -> Void)? = nil

    /// Start `exe` under wine in `install` and stream its output. `busy` clears when it exits.
    private func launchInstaller(exe: URL, in install: Install, name nm: String) {
        var args = [Install.winePath(exe, driveC: install.driveC)]
        let silent = Self.isNSIS(exe)
        if silent {
            // /D must be last and unquoted -- that is NSIS's rule, not a preference.
            args += ["/S", "/D=C:\\Games\\" + nm]
            appendLine("==> running \(exe.lastPathComponent) in \(install.prefixName) — Nullsoft installer, running it unattended (/S). Nothing to click; this takes a while for a client-sized payload.")
        } else {
            appendLine("==> running \(exe.lastPathComponent) in \(install.prefixName) — install into C:\\Games\\\(nm)")
        }
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = install.prefix.path; env["WINEDEBUG"] = "-all"
        env.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH"); env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        spawn(install.wine, args: args,
              env: env, cwd: exe.deletingLastPathComponent()) { [weak self] code in
            guard let self else { return }
            self.busy = false
            self.appendLine("==> installer exited \(code)")
            guard let found = Self.findInstalledClient(in: install, world: nm) else {
                if silent { self.appendLine("!! \(nm)'s installer finished but no client folder was found under \(install.driveC.path). Check the log above.") }
                return
            }
            self.appendLine("==> \(nm)'s client is at \(found.path)")
            self.onClientInstalled?(found)
        }
    }

    /// `scripts/retail-client.sh`: Square Enix's free client + PlayOnline update + Ashita/xiloader
    /// (+ the world's patch/DATs) into the world's folder. Bring-your-own-retail worlds only.
    func installRetail(for s: Server, in gameInstall: Install) {
        if refuseWhileBusy("the retail client install for \(s.name)") { return }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/retail-client.sh")
        guard let script = Bundle.main.url(forResource: "retail-client", withExtension: "sh")
                ?? (FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil) else {
            appendLine("!! retail-client.sh not found in the bundle"); return
        }
        busy = true
        Self.linkGamesFolder(s.name, to: s.dataPath, in: gameInstall)
        ensureInstallerPrefix(gameInstall) { [weak self] ip in
            guard let self else { return }
            Self.linkGamesFolder(s.name, to: s.dataPath, in: ip)
            self.appendLine("==> retail client for \(s.name) into \(s.dataPath) (Square Enix's 7.7 GB download, then PlayOnline's update — leave this running)")
            var env: [String: String] = [:]
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            self.spawn(URL(fileURLWithPath: "/bin/zsh"),
                       args: [script.path, ip.wrapper.path, ip.prefixName, s.dataPath, s.name],
                       env: env, cwd: Self.scratchDir) { [weak self] code in
                self?.busy = false
                self?.appendLine("==> retail install exited \(code)")
            }
        }
    }

    /// Stop whatever is running in the installer prefix.
    func cancelInstaller(_ gameInstall: Install) {
        let ip = gameInstall.installerPrefix
        let k = Process(); k.executableURL = ip.wineserver; k.arguments = ["-k"]; k.environment = ["WINEPREFIX": ip.prefix.path]
        try? k.run()
        appendLine("==> installer prefix stopped")
    }

    /// Fresh HorizonXI client into `dir` via their published torrent + updates (update-client.sh install).
    func installHorizon(into dir: URL) {
        if refuseWhileBusy("the HorizonXI client install") { return }
        guard let script = Self.updateScript() else { return }
        busy = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        appendLine("==> installing HorizonXI into \(dir.path) (9.4 GB torrent — leave this running)")
        var env: [String: String] = [:]
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        spawn(URL(fileURLWithPath: "/bin/zsh"), args: [script.path, "install", dir.path],
              env: env, cwd: Self.scratchDir) { [weak self] code in
            self?.busy = false; self?.appendLine("==> install exited \(code)")
        }
    }

    func runCatsEyeLauncher(_ gameInstall: Install, dataPath: String = "") {
        Self.linkGamesFolder("CatsEyeXI", to: dataPath, in: gameInstall)
        if refuseWhileBusy("the CatsEyeXI launcher") { return }
        busy = true
        ensureInstallerPrefix(gameInstall) { [weak self] ip in
            self?.busy = false
            Self.linkGamesFolder("CatsEyeXI", to: dataPath, in: ip)
            self?.runCatsEyeLauncherNow(ip)
        }
    }

    private func runCatsEyeLauncherNow(_ install: Install) {
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/catseye-launcher.sh")
        guard let script = Bundle.main.url(forResource: "catseye-launcher", withExtension: "sh")
                ?? (FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil) else {
            appendLine("!! catseye-launcher.sh not found in the bundle"); return
        }
        busy = true
        appendLine("==> CatsEyeXI launcher in \(install.prefixName)")
        spawn(URL(fileURLWithPath: "/bin/zsh"),
              args: [script.path, install.wrapper.path, install.prefixName],
              env: [:], cwd: Self.scratchDir) { [weak self] code in
            self?.busy = false
            self?.appendLine("==> CatsEyeXI launcher exited \(code)")
        }
    }

    struct LaunchGate {
        var refusal: String?
        var snapshot = LiveClients.Snapshot()
        var clientsLive = false
        var rendererStep = RendererSetup.Step.stopAndApply
        /// The sync mode the client must use: the running wineserver's when there is one.
        var sync = MultiWorld.SyncMode.off
    }

    /// Everything that would refuse a launch, checked before anything is written. The caller
    /// runs it first, for an early answer; `launch` runs it again under the launch lock and only
    /// then makes the caller's writes to shared client files (pivot.ini, the boot profile; its
    /// `beforeLaunch`).
    /// `sync` is the mode this world would like; `msyncAllowed` is false for a world whose
    /// client dies with msync on (Server.msync).
    func gate(_ install: Install, renderer: Renderer, sync: MultiWorld.SyncMode = .off,
              msyncAllowed: Bool = true, profile: String, world: String, host: String,
              maxClients: Int) -> LaunchGate {
        if running { return LaunchGate(refusal: "\(session.isEmpty ? world : session) is already running.") }
        // Every client shares this prefix and, usually, this game folder. Everything that would
        // stop the wineserver or pull files out from under a running client is gated on this.
        var g = LaunchGate(snapshot: LiveClients.snapshot(), sync: sync)
        let hosts = [host] + [Credentials.bootServer(in: install, profile: profile)].compactMap { $0 }
        if let why = Self.duplicateRefusal(world: world, hosts: hosts, maxClients: maxClients,
                                           clients: g.snapshot.clients, install: install) {
            g.refusal = why; return g
        }
        g.clientsLive = MultiWorld.clientsLive(g.snapshot.clients, otherSessionsPlaying: othersPlaying())
        // msync/esync belong to the wineserver every client shares; see MultiWorld.SyncMode.
        if g.clientsLive {
            let running = LiveClients.runningSyncMode(prefix: install.prefix.path,
                                                      wineservers: g.snapshot.wineservers)
            let d = MultiWorld.syncDecision(want: sync, running: running, msyncAllowed: msyncAllowed, world: world)
            if let why = d.refusal { g.refusal = why; return g }
            g.sync = d.use
        }
        g.rendererStep = RendererSetup.step(for: renderer,
                                            current: g.clientsLive ? RendererSetup.current(install) : nil,
                                            clientsLive: g.clientsLive)
        if case .refuse(let why) = g.rendererStep { g.refusal = why; return g }
        // GameRegistry.point re-registers through wine and then stops the wineserver.
        if g.clientsLive, GameRegistry.current(install) != install.squareEnixWine {
            g.refusal = "\(world) plays from \(install.squareEnixWine), but the running world's "
                      + "registry names \(GameRegistry.current(install) ?? "another folder"). "
                      + "Stop the other world first; the game folder cannot change under a running client."
        }
        return g
    }

    /// Returns why the launch was refused, or nil once it is under way.
    @discardableResult
    func launch(_ install: Install, perf: PerfSettings, profile: String = "horizonxi.ini",
                useX87: Bool = true, world: String = "", host: String = "",
                maxClients: Int = 1, msyncAllowed: Bool = true,
                addonPolicy: AddonPolicy = .unknown,
                beforeLaunch: () -> Void = {}) -> String? {
        let worldName = world.isEmpty ? "Vana'diel" : world
        guard let lock = LaunchLock.acquire() else {
            let why = "Another game is still starting, or the client is being repaired or updated "
                    + "(in this window or another launcher). Press Play again in a few seconds."
            appendLine("!! " + why)
            return why
        }
        // Handed off once the game is spawned: see LaunchLock.release(_:whenVisible:).
        var lockHandedOff = false
        defer { if !lockHandedOff { LaunchLock.release(lock) } }
        let wantSync = MultiWorld.syncMode(msync: perf.msync, esync: perf.esync)
        let g = gate(install, renderer: perf.renderer, sync: wantSync, msyncAllowed: msyncAllowed,
                     profile: profile, world: worldName, host: host, maxClients: maxClients)
        if let why = g.refusal {
            appendLine("!! " + why)
            return why
        }
        // The caller's writes to shared client files (pivot.ini branding, the boot profile's
        // account line), now that the lock is held and the gate has passed: a refused launch
        // rewrites nothing another world is using. Before `hostKey`, which reads the `--server`
        // this writes.
        beforeLaunch()
        let clientsLive = g.clientsLive
        let rendererStep = g.rendererStep
        let live = g.snapshot.byHost
        running = true
        launchGeneration += 1
        // What the loader will really be given, for the fallback in `sessionPIDs`.
        hostKey = LiveClients.normalize(Credentials.bootServer(in: install, profile: profile) ?? host)
        Runner.playing[ObjectIdentifier(self)] = Playing(world: worldName, host: hostKey)
        loginFailure = ""
        currentInstall = install
        currentProfile = profile
        currentWorld = worldName
        sessionGroup = nil
        groupHeldLoader = false
        preexistingPIDs = Set(live[hostKey] ?? [])
        if !live.isEmpty { appendLine("==> also running: \(Self.describe(live))") }
        // The renderer lives in the prefix's registry and DLLs, not in the environment, so it has
        // to be written before the process starts — and after any wineserver holding the old copy
        // of the registry has exited.
        // A wrapper that has been copied or moved still has its dylib links aimed at the old
        // copy; fix that before anything tries to load one. See relinkStrayDylibs.
        RendererSetup.relinkStrayDylibs(install) { [weak self] in self?.appendLine($0) }
        if rendererStep == .stopAndApply {
            RendererSetup.apply(perf.renderer, to: install) { [weak self] in self?.appendLine($0) }
            // Same moment, same reason: the registry has to name *this* world's SquareEnix folder.
            GameRegistry.point(install) { [weak self] in self?.appendLine($0) }
        } else {
            appendLine("renderer: \(perf.renderer.title) already set up; left alone for the running world")
            RendererSetup.ensureFiles(perf.renderer, for: install) { [weak self] in self?.appendLine($0) }
        }
        Self.cleanStaleWineSockets()
        gameExe = Credentials.bootLoaderName(in: install, profile: profile) ?? "horizon-loader.exe"
        Self.currentGameExe = gameExe
        Credentials.applyIniOverrides(perf.renderer.iniOverrides, to: install, profile: profile)
        // Launching with Sandbox loaded and its interface bypass off produces the worst failure
        // this project has: a clean login followed by a silent exit, no window, no error. Put it
        // back rather than letting the user hit that. See Sandbox.swift.
        if Sandbox.isBroken(install, profile: profile) {
            Sandbox.repair(install) { [weak self] in self?.appendLine($0) }
        }
        // The local server is the one everything else here is a test against (see
        // docs/X87-WALL.md and scripts/max4k.json, which this mirrors) -- 4K, every graphics
        // setting maxed. Never applied to a live server profile: that would silently change
        // someone's real account's display settings out from under them.
        // The local world starts small -- but only if nobody has said otherwise. Forcing it on
        // every launch (which is what the old max-4K line did) means the graphics panel silently
        // does nothing on this world: you set it, press Play, and the launcher writes over you.
        if profile == "lsb.ini", GraphicsSettings.read(from: install, profile: profile) == nil {
            GraphicsSettings.lowSpec.write(to: install, profile: profile)
            appendLine("==> local world: no graphics settings yet, seeding 640x480 "
                       + "(change them in Graphics; they will be kept)")
        }
        // Cutscene narration, if the user asked for it: install VanaVoice's addon and start the
        // narrator. Never fatal -- a failure here leaves the game exactly as silent as before.
        Narration.prepare(install, enabled: perf.narrateCutscenes, policy: addonPolicy,
                          profile: profile, othersLive: clientsLive) { [weak self] in self?.appendLine($0) }
        // Quest guide, same policy gate as narration: LSB / unrestricted only; scrubbed on
        // allowlist worlds. Never fatal.
        Guide.prepare(install, enabled: perf.enableVanaguide, policy: addonPolicy,
                      profile: profile, othersLive: clientsLive) { [weak self] in self?.appendLine($0) }
        CursorFix.prepare(install, policy: addonPolicy, profile: profile,
                          othersLive: clientsLive) { [weak self] in
            self?.appendLine($0)
        }
        // Frame-rate monitors never load on a hosted world, even if they were switched on earlier.
        if addonPolicy.isRestricting {
            var items = AddonSuite.scan(install, profile: profile)
            let off = items.indices.filter {
                items[$0].enabled && AddonPolicy.localOnly.contains(AddonPolicy.normalize(items[$0].name))
            }
            if !off.isEmpty {
                for k in off { items[k].enabled = false }
                if AddonSuite.write(items, to: install, profile: profile) {
                    appendLine("==> fps monitor: off on this world (local server only)")
                }
            }
        }
        // Every launch: make sure no allowed addon can take the LuaJIT trace-patch fault that Ashita 4.3
        // hits on this Mac (see LuaJITGuard). Idempotent, so this is cheap after the first run.
        LuaJITGuard.apply(install, policy: addonPolicy) { [weak self] in self?.appendLine($0) }
        appendLine("==> launching \(install.bootProfileName(profile)) (Ashita \(install.ashitaGeneration.rawValue))")
        // Make the Dock tile say which world is running, under this project's own icon. The
        // wrapper is one bundle for every world, so with several playing it names them all.
        let playingWorlds = Set(Runner.playing.values.map(\.world)).sorted().joined(separator: " + ")
        DockIcon.apply(to: install, world: playingWorlds) { [weak self] in self?.appendLine($0) }
        // Cooperative x87 has not been shown to install its JIT hook on macOS 27. On 26.5.2
        // this exact failure cost 19x in the measured rules scene (docs/X87-WALL.md). Keep the
        // last playable fallback, stock Rosetta, until a local-world A/B proves the new helper.
        let x87Enabled = useX87 && (ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
                                    || ProcessInfo.processInfo.environment["FFXI_ON_MAC_X87"] == "1")
        var env = perf.environment(for: install, x87: x87Enabled, world: worldName)
        if !x87Enabled {
            env.removeValue(forKey: "ROSETTA_X87_PATH")
            env.removeValue(forKey: "ROSETTA_DISABLE_AOT")
        }
        if useX87 && !x87Enabled {
            appendLine("i  macOS 27: x87 sidecar off until its in-world speed is verified")
        }
        if g.sync != wantSync {
            env["WINEMSYNC"] = g.sync == .msync ? "1" : "0"
            env["WINEESYNC"] = g.sync == .esync ? "1" : "0"
            appendLine("i  sync: \(g.sync.rawValue), not \(wantSync.rawValue), to match the wineserver "
                       + "the running world already started (a client that disagrees with it exits at start-up)")
        }
        // The tile the *wine process* wears: CrossOver wine's CX_ROOT icon fallback, since the
        // loader has no icon resource of its own. See DockIcon.cxRoot.
        if env["CX_ROOT"] == nil, let cx = DockIcon.cxRoot(for: world.isEmpty ? "Vana'diel" : world,
                                                          log: { [weak self] in self?.appendLine($0) }) {
            env["CX_ROOT"] = cx.path
        }
        // The patched wine can re-exec i386 children through the cooperative sidecar via
        // ROSETTA_X87_PATH. A live sidecar only proves that it launched, not that the client's
        // x87 hook engaged; the failed-hook measurements in docs/X87-WALL.md are severe.
        // Keep macOS 27 on stock Rosetta until a local-world A/B validates acceleration.
        if !useX87 {
            appendLine("i  x87 acceleration is off for this world — its client exits at boot with it on.")
        } else if x87Enabled && X87Sidecar.coopBinary() == nil {
            appendLine("!! x87sidecar-coop missing from the bundle — the client will run at "
                       + "Rosetta's stock x87 speed (single-digit fps in-world).")
        }
        // Spawned through a shell with a *file* redirect, not Foundation.Process pipes.
        // 2026-08-19: after the wrapper moved to the x10, every game launched the old way died
        // one second after "Connected to server!" — while a byte-identical spawn (same exe,
        // args, cwd, and the full 58-variable environment, verified via last-spawn.txt) from a
        // shell with stdout on a file ran to character select every single time. Sidecar off,
        // wineserver stopped, strays killed — the only surviving difference was how Foundation
        // wires the child. So launch the way that demonstrably works and tail the file for the
        // log pane.
        let exe: URL
        let args: [String]
        // Ashita v4 injects with `Ashita-cli.exe <profile>.ini`; Eden's v3 client with
        // `injector.exe <profile>.xml`. Same shape, different names — see Install.AshitaGeneration.
        let injector = install.gameDirWine + "\\" + install.ashitaCLI.lastPathComponent
        let bootFile = install.bootProfileName(profile)
        if let wine = X87Sidecar.patchedWine() {
            // Not about x87: the wrapper's own wine exits one second after login. See
            // X87Sidecar.patchedWine.
            exe = wine
            args = [injector, bootFile]
            appendLine("==> wine: \(wine.path)"
                       + (x87Enabled && X87Sidecar.coopBinary() != nil ? " + x87 sidecar" : ""))
        } else {
            exe = install.wine
            args = [injector, bootFile]
            appendLine("!! falling back to the wrapper's own wine — expect the client to exit "
                       + "about a second after login (docs/WINE-BUILD.md)")
        }
        // Registry edits now use this same wine build, so they do not bounce the prefix between
        // two wine.inf versions. Still wait for its server to flush before launching the client;
        // never stop it when another client is running.
        if !clientsLive, RendererSetup.stopWineserver(install) {
            appendLine("==> wineserver stopped; the game starts its own")
        }
        let spawned = spawnViaShell(exe,
              args: args,
              env: env,
              cwd: install.gameDir) { [weak self] code in
            // This is Ashita-cli.exe, the *injector*. It exits within seconds of a successful
            // injection, while the game carries on in horizon-loader.exe -- so its exit is not
            // the game's exit, and tearing down the sidecar here killed the client roughly ten
            // seconds after every launch ("connects to nothing, window never appears"). Wait for
            // the actual client process instead.
            self?.appendLine("==> injector exited \(code)")
            self?.watchGameProcess()
        }
        // Keep other launches out until a scan can see this one.
        if let pid = spawned {
            lockHandedOff = true
            LaunchLock.release(lock, whenVisible: pid, group: sessionGroup)
        }
        return nil
    }

    /// The loader's `--server`, normalised; what this session's pids are filed under.
    private var hostKey = ""
    /// The process group this launch's spawn started in; see LiveClients. nil until the spawn,
    /// and for good if the spawned process was gone before its group could be read.
    private var sessionGroup: pid_t? {
        didSet { Runner.playing[ObjectIdentifier(self)]?.group = sessionGroup }
    }
    /// `sessionGroup` has been seen holding this session's loader. Until then the session is
    /// also tracked by host; see MultiWorld.sessionPIDs.
    private var groupHeldLoader = false {
        didSet { Runner.playing[ObjectIdentifier(self)]?.groupHeldLoader = groupHeldLoader }
    }
    /// Only for the no-group fallback: clients of the same host already running when this
    /// session started. Never this session's to watch or stop.
    private var preexistingPIDs: Set<pid_t> = []
    /// Bumped by every launch, so a Stop that is still waiting can tell the session has since
    /// been started again.
    private var launchGeneration = 0

    /// Other sessions' groups: never this session's to watch or stop.
    private var otherGroups: Set<pid_t> {
        Set(Runner.playing.filter { $0.key != ObjectIdentifier(self) }.values.compactMap(\.group))
    }

    /// This session's client pids (injector, loader, sidecar), and nobody else's.
    private func sessionPIDs(in scanned: LiveClients.Snapshot? = nil) -> [pid_t] {
        let others = otherGroups
        let snap = scanned ?? LiveClients.snapshot()
        if !groupHeldLoader, MultiWorld.groupHoldsLoader(sessionGroup, in: snap) { groupHeldLoader = true }
        return MultiWorld.sessionPIDs(group: sessionGroup, groupHeldLoader: groupHeldLoader, host: hostKey,
                                      preexisting: preexistingPIDs, otherGroups: others, in: snap)
    }

    /// Poll for the client itself. Ashita-cli.exe exits seconds after a successful injection
    /// while the game carries on in horizon-loader.exe, so the injector's exit is not the game's.
    private func watchGameProcess() {
        Task { [weak self] in
            // Give the injector's child a moment to appear before deciding it never did.
            // Sample the window on the way: the last size seen is what the next launch opens
            // at (WindowMemory). Sampled on the main actor, since it reads the window server.
            let scale = self?.currentInstall.map(WindowMemory.scale(for:)) ?? 1
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let pids = self?.sessionPIDs() ?? []
                if pids.isEmpty { break }
                if let s = await MainActor.run(body: { WindowMemory.currentSize(pids: pids, scale: scale) }) {
                    if self?.firstWindowSize == nil { self?.firstWindowSize = s }
                    self?.lastWindowSize = s
                }
            }
            // Two consecutive misses, because pgrep can miss the process for a beat while wine
            // re-execs it during start-up.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !(self?.sessionPIDs() ?? []).isEmpty { self?.watchGameProcess(); return }
            await MainActor.run {
                guard let self else { return }
                self.running = false
                self.appendLine("==> game exited")
                if let f = self.firstWindowSize, let s = self.lastWindowSize, let i = self.currentInstall,
                   let line = WindowMemory.remember(first: f, last: s, install: i,
                                                    profile: self.currentProfile, world: self.currentWorld) {
                    self.appendLine(line)
                    self.windowSizeRemembered += 1
                }
                self.lastWindowSize = nil
                self.firstWindowSize = nil
            }
        }
    }

    /// First and last sampled client window sizes (game pixels) for this run; see WindowMemory.
    private var firstWindowSize: WindowMemory.Size?
    private var lastWindowSize: WindowMemory.Size?
    /// Bumped whenever a size was written back, so the Graphics panel can reload.
    @Published var windowSizeRemembered = 0

    /// `RendererSetup.apply` just did `wineserver -k` and waited for it to actually exit, so any
    /// `server-*` socket directory left under `/tmp/.wine-<uid>/` at this point belongs to a
    /// wineserver that is no longer running -- not necessarily this launch's, since the same
    /// crash or force-kill that orphans one can orphan others. A stale socket there makes the
    /// *next* launch's injection intermittently corrupt itself ("wine client error: write: Bad
    /// file descriptor", "Injection failed!") without ever touching wine's own cleanup path,
    /// because Ashita-cli connects to whatever socket file it finds rather than starting fresh.
    /// This app is the only wine user on the machine, so clearing all of them here is safe.
    private static func cleanStaleWineSockets() {
        // Only when no wineserver is alive: deleting the socket dir of a *live* server (one the
        // user's own manual wine session started, say) orphans every process attached to it.
        let chk = Process()
        chk.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        chk.arguments = ["-x", "wineserver"]
        chk.standardOutput = Pipe(); chk.standardError = Pipe()
        if (try? chk.run()) != nil { chk.waitUntilExit(); if chk.terminationStatus == 0 { return } }
        let dir = URL(fileURLWithPath: "/tmp/.wine-\(getuid())")
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for kid in kids where kid.lastPathComponent.hasPrefix("server-") {
            try? FileManager.default.removeItem(at: kid)
        }
    }

    /// Stop this session's own client, in the prefix it was launched in.
    func stop() {
        if let i = currentInstall { stop(i) }
    }

    /// Ends this session's client only. The wineserver is shared by every world in the prefix,
    /// so it is stopped only once no client at all is left.
    func stop(_ install: Install) {
        let snap = LiveClients.snapshot()
        var pids = running ? sessionPIDs(in: snap) : []
        // The injector: it exits seconds after launch and its pid is cleared then, but until
        // that is noticed it may already belong to somebody else. `signalable` checks.
        if let pid = gamePID { pids.append(pid) }
        // Only what is provably still this session's: a wine process in its group (or, with no
        // group, a loader of its host in no other session's group). pid -> group.
        let mine = MultiWorld.signalable(pids, group: sessionGroup, host: hostKey,
                                         otherGroups: otherGroups, in: snap)
        for pid in mine.keys { kill(pid, SIGTERM) }
        proc?.terminate()
        if !mine.isEmpty { appendLine("==> stopping \(currentWorld) (pid \(mine.keys.sorted().map(String.init).joined(separator: ",")))") }
        let generation = launchGeneration
        Task.detached {
            // wine usually honours SIGTERM within a second or two; a client wedged in a
            // cutscene or a dead socket may not, and a Stop that does nothing is worse.
            for _ in 0..<16 {
                if !mine.keys.contains(where: { Detach.isAlive($0) }) { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // Eight seconds on, check again that each pid is still the same wine process in the
            // same group before the signal that cannot be ignored.
            let now = LiveClients.snapshot()
            for (pid, group) in mine where Detach.isAlive(pid)
                && MultiWorld.stillSignalable(pid, group: group, in: now) {
                kill(pid, SIGKILL)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // Decided on the main actor, where no launch of this launcher can be half-way, and
            // under the launch lock, so no other launcher's can either. A launch that began
            // while this Stop waited is playing, injecting or holding the lock, and keeps its
            // wineserver.
            await MainActor.run { [weak self] in
                // The lock first, then the scan: taken the other way round, another launcher
                // could finish a launch and let go of the lock in between, and its client would
                // be neither in the scan nor under way.
                let lock = LaunchLock.acquire()
                defer { if let lock { LaunchLock.release(lock) } }
                let left = LiveClients.snapshot().clients
                let relaunched = self.map { $0.launchGeneration != generation } ?? false
                let others = self?.othersPlaying() ?? Runner.playing.count
                if !relaunched, MultiWorld.mayStopWineserver(left, otherSessionsPlaying: others,
                                                             launchUnderWay: lock == nil) {
                    RendererSetup.stopWineserver(install)
                } else if !left.isEmpty {
                    self?.appendLine("==> wineserver left up: still running \(Runner.describe(LiveClients.byHost(left)))")
                } else {
                    self?.appendLine("==> wineserver left up: another launch is under way")
                }
            }
        }
    }

    /// See the call site in `launch`: the game must be started the way a shell starts it.
    /// stdout/stderr go to a temp file that a DispatchSource tails into the log pane, so the
    /// child never holds a Foundation pipe. The tail keeps reading until the file stops growing
    /// *and* the game is gone, because horizon-loader outlives the injector this spawns.
    /// Single-quote one word for /bin/sh. The cooperative launch builds a small shell command
    /// (run the injector, then idle while the client lives), and every path in it can contain
    /// spaces -- the wine wrapper lives under "/Volumes/Video Games/…" on this Mac.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Returns the spawned pid, or nil when the spawn failed.
    @discardableResult
    private func spawnViaShell(_ exe: URL, args: [String], env: [String: String], cwd: URL,
                               done: @escaping (Int32) -> Void) -> pid_t? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffxi-on-mac-game-\(getpid())-\(Self.fileSafe(session)).log")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        if env["ROSETTA_X87_PATH"] == nil {
            e.removeValue(forKey: "ROSETTA_X87_PATH")
            e.removeValue(forKey: "ROSETTA_DISABLE_AOT")
        }
        // The RetroAchievements key never reaches the game (or last-spawn.txt).
        e.removeValue(forKey: RetroAchievements.envKey)
        // Record the launch path and relevant performance settings. Diffing these against a
        // hand-run helped bisect launch failures without retaining the full inherited environment.
        // last-spawn.txt is always the newest launch; each session also keeps its own.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac", isDirectory: true)
        // Record only launch settings useful for a renderer comparison. Inheriting the whole
        // environment wrote unrelated session identifiers and could write user-supplied secrets
        // from extraEnv into a world-readable diagnostics file.
        let diagnosticKeys: Set<String> = [
            "CX_ROOT", "D3D9_RT_READBACK_FENCE", "D3DMETAL_FRAMEWORK_PATH",
            "DXVK_STATE_CACHE_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
            "FFXI_FPS_DIVISOR", "LSAppNapIsDisabled", "MVK_CONFIG_FAST_MATH_ENABLED",
            "MVK_CONFIG_USE_COMMAND_POOLING", "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS",
            "ROSETTA_X87_PATH", "WINEDEBUG", "WINEESYNC", "WINEMSYNC", "WINEPREFIX",
            "WINE_LARGE_ADDRESS_AWARE"
        ]
        let dump = "exe: \(exe.path)\nargs: \(args)\ncwd: \(cwd.path)\n"
            + diagnosticKeys.sorted().compactMap { key in e[key].map { "\(key)=\($0)" } }
                .joined(separator: "\n") + "\n"
        for name in ["last-spawn.txt", "last-spawn-\(Self.fileSafe(session)).txt"] {
            let file = support.appendingPathComponent(name)
            Self.writePrivateDiagnostic(dump, to: file)
        }
        // Detached, in its own session, so quitting the launcher does not take the game with
        // it. That means no Process object and no terminationHandler -- the child is not ours
        // any more -- so the injector's exit is noticed by polling instead. See Detach.
        guard let pid = Detach.spawn(exe, args: args, env: e, cwd: cwd, stdoutPath: out.path) else {
            appendLine("!! could not start the game (posix_spawn failed)")
            Task { @MainActor in done(-1) }
            return nil
        }
        // Read now, while the spawned shell is certainly alive: everything it starts keeps this
        // group. Never our own group, which would make Stop signal the launcher.
        let pg = getpgid(pid)
        sessionGroup = pg > 1 && pg != getpgrp() ? pg : nil
        appendLine("==> started detached, pid \(pid)"
                   + (sessionGroup.map { ", process group \($0)" } ?? "; process group unknown, tracking by host"))
        Task.detached {
            while Detach.isAlive(pid) { try? await Task.sleep(nanoseconds: 500_000_000) }
            // The injector is gone and its pid is free for the system to hand to anything, so
            // Stop must not signal it any more.
            await MainActor.run { [weak self] in
                if self?.gamePID == pid { self?.gamePID = nil }
                done(0)
            }
        }
        // Tail the file: poll is plenty (the pane is human-read), and unlike a pipe it cannot
        // block the writer.
        let handle = try? FileHandle(forReadingFrom: out)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in
            guard let d = try? handle?.read(upToCount: 1 << 16), !d.isEmpty,
                  let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendChunk(s) }
        }
        timer.resume()
        tailTimer?.cancel()
        tailTimer = timer
        // The game was already started above, detached. Nothing to run here any more; the
        // detached pid is remembered so `stop` can still end the session on request.
        gamePID = pid
        return pid
    }

    /// Keep launch diagnostics private from their first byte, including on the first launch.
    /// Foundation's atomic String.write creates a replacement file with default permissions
    /// before the following chmod, briefly exposing paths and user-supplied settings.
    private static func writePrivateDiagnostic(_ text: String, to file: URL) {
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".last-spawn-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { return }
        defer { unlink(temp.path) }
        guard fchmod(fd, mode_t(0o600)) == 0 else { close(fd); return }
        let data = Data(text.utf8)
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, base.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard close(fd) == 0, written else { return }
        _ = rename(temp.path, file.path)
    }

    /// Two sessions tailing one stdout file would each show the other's output.
    private static func fileSafe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// The detached injector's pid, for `stop`, until it exits (seconds after launch; the
    /// client carries on in the loader). Not a Process: it is not our child any more. Cleared
    /// when it exits, and `stop` signals it only while it is still a wine process in this
    /// session's group (`MultiWorld.signalable`).
    private var gamePID: pid_t?

    private var tailTimer: DispatchSourceTimer?

    private func spawn(_ exe: URL, args: [String], env: [String: String], cwd: URL,
                       done: @escaping (Int32) -> Void) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        // The RetroAchievements key never reaches the game (or last-spawn.txt).
        e.removeValue(forKey: RetroAchievements.envKey)
        p.environment = e
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // The pipe has to keep being drained for as long as *anything* is writing to it, and
        // that outlives this process: horizon-loader.exe inherits these descriptors from
        // Ashita-cli.exe and keeps logging into them for the whole session. Dropping the reader
        // when the injector exited left the game writing into a pipe nobody emptied -- 64 KB
        // later it blocked in write() forever, which looked exactly like the client freezing on
        // the HorizonXI splash screen. Read to EOF instead, which is when the last writer has
        // closed, and never key it off a process exit.
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }   // EOF
            guard let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.appendChunk(s) }
        }
        p.terminationHandler = { pr in
            Task { @MainActor in done(pr.terminationStatus) }
        }
        do {
            try p.run()
            proc = p
        } catch {
            appendLine("!! failed to start \(exe.path): \(error.localizedDescription)")
            done(-1)
        }
    }
}
