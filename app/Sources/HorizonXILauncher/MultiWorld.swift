import Foundation
import Combine

/// Game clients running on this Mac, keyed by the login host their loader was given.
///
/// HorizonXI and the local world both run `horizon-loader.exe` out of the same folder, so a
/// process name says nothing about which world it is. The loader's `--server <host>` argument
/// does. See docs/MULTI_WORLD.md.
///
/// Which *session* a client belongs to is its process group, not its host: every process one
/// launch starts (injector, loader, the loader's x87 sidecar) keeps the group of the shell
/// `Detach.spawn` ran it from, while wine's own services each set up a group of their own.
/// Measured 2026-09-26 on a live HorizonXI client: loader and sidecar in group 57810, spawned
/// pid 57812, services/explorer/winedevice each their own leader.
///
/// That is an observation, not a guarantee: wine could `setsid()` a detached child, and then the
/// loader would lead a group of its own. `MultiWorld.sessionPIDs` falls back to the host for a
/// session whose group has never been seen holding its loader, so a moved loader is still found.
enum LiveClients {
    struct Client: Equatable {
        let pid: pid_t
        let group: pid_t
        /// "" when the command line names no `--server`, and always for an injector.
        let host: String
        /// Ashita's injector, in the seconds before the loader it starts exists. It holds the
        /// prefix just as much. Its command line names no host, only the boot profile.
        let injecting: Bool
        /// An injector's boot profile (`horizonxi.ini`, `eden.xml`), lowercased; "" otherwise.
        /// The profile's `--server` is the world the injector is starting. See
        /// `MultiWorld.refusal`.
        var bootFile: String = ""
        /// A Windows program that is neither a loader or injector this file knows nor one of
        /// wine's own (`wineSystemPrograms`): a loader under a name nobody listed, an installer,
        /// a tool. It holds the wineserver like any client, so it counts wherever the question
        /// is "is anything live in the prefix"; its world is known only if it was given
        /// `--server`.
        var other = false
        /// Its executable is one of this launcher's wine builds or the x87 sidecar (`OwnWine`).
        /// What `Leftovers.adoptable` asks before calling a client this launcher's own.
        var ownWine = true

        /// A loader whose world can be read: a known loader, or any program given `--server`.
        /// What the duplicate rule, the Running list and a session's group test go by.
        var knownLoader: Bool { !injecting && !(other && host.isEmpty) }
    }

    struct Snapshot: Equatable {
        var clients: [Client] = []
        /// Every process on the Mac: pid -> process group.
        var groups: [pid_t: pid_t] = [:]
        /// Every process running wine, the x87 sidecar, a wineserver or a Windows program,
        /// wine's own included. Stop signals nothing that is not in here. See
        /// `MultiWorld.signalable`.
        var wine: Set<pid_t> = []
        /// Every wineserver, whatever prefix it serves. See `runningSyncMode`.
        var wineservers: [pid_t] = []
        /// Every x87 sidecar process (the command itself is `x87sidecar…`). A cooperative
        /// sidecar lives exactly as long as the process it hooked, so a client launched with
        /// `ROSETTA_X87_PATH` and no sidecar left in its session was never accelerated.
        var sidecars: Set<pid_t> = []
        /// The wineservers, and wine's own programs (`wineSystemPrograms`), whose executable is
        /// this launcher's wine (`OwnWine`). See `Leftovers.serverless`.
        var ownWineservers: [pid_t] = []
        var ownSystemPrograms: [pid_t] = []

        var byHost: [String: [pid_t]] { LiveClients.byHost(clients) }

        /// Every process in `group`, whatever its name: a boot profile may name a loader this
        /// file has never heard of.
        func members(ofGroup group: pid_t) -> [pid_t] {
            groups.filter { $0.value == group }.map(\.key).sorted()
        }
    }

    static let loaderNames = ["horizon-loader.exe", "xiloader.exe", "gxiloader.exe",
                              "catseye-loader.exe", "pol.exe"]
    /// Ashita v4's and Eden's Ashita v3's.
    static let injectorNames = ["ashita-cli.exe", "injector.exe"]
    /// wine's own programs, which run for as long as the wineserver does whether or not any
    /// client is left, so they never count as one. Read on 2026-09-26 from `ps` under the live
    /// wineserver serving a HorizonXI client: services.exe, winedevice.exe (two), plugplay.exe,
    /// svchost.exe, rpcss.exe, explorer.exe, each `C:\windows\system32\<name>` and each the
    /// leader of its own group. The rest are the ones wine starts on demand and leaves running
    /// (tabtip, conhost, start, winemenubuilder). Only matched under `C:\windows\` (or with no
    /// folder at all), so a game program that happens to share a name still counts.
    /// Setup's own tools (regsvr32, reg, regedit, wineboot) are wine's too: one left hanging by
    /// an interrupted Setup (2026-10-15) otherwise read as a game "running elsewhere", which
    /// blocked the very Repair that ends it.
    static let wineSystemPrograms = ["services.exe", "explorer.exe", "winedevice.exe", "plugplay.exe",
                                     "svchost.exe", "rpcss.exe", "tabtip.exe", "conhost.exe",
                                     "start.exe", "winemenubuilder.exe",
                                     "regsvr32.exe", "reg.exe", "regedit.exe", "wineboot.exe"]

    /// `127.0.0.1` and `localhost` are the same world; hosts are case-insensitive.
    static func normalize(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h == "localhost" ? "127.0.0.1" : h
    }

    /// `ps -axww -o pid=,pgid=,command=` output -> clients and every process's group.
    ///
    /// The x87 sidecar wraps the loader (`x87sidecar-coop --cooperative …/wine …loader.exe`),
    /// so one client is usually two pids under one host. A line counts only when the Windows
    /// program is the command itself or follows a wine/sidecar executable, which keeps a shell
    /// or grep that merely mentions the name out of it.
    ///
    /// Every Windows program counts, not only the loaders and injectors named above:
    /// `Credentials.fixBootLoader` can boot any .exe in `bootloader/`, and a client whose name
    /// is unknown holds the wineserver just the same. Those are `other`; see `Client.knownLoader`.
    ///
    /// An `other` program counts only when `isOurs` says its executable is one of this
    /// launcher's wine builds or the x87 sidecar (`OwnWine`), so a game running under another
    /// wine install (XIV on Mac, CrossOver, Whisky) never holds this launcher's prefix up. The
    /// default, used by self-tests that are not about this, takes every program as ours.
    static func parse(_ text: String, isOurs: (pid_t) -> Bool = { _ in true }) -> Snapshot {
        var snap = Snapshot()
        for raw in text.split(whereSeparator: \.isNewline) {
            let fields = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = pid_t(fields[0]), let group = pid_t(fields[1]) else { continue }
            snap.groups[pid] = group
            guard fields.count == 3 else { continue }
            // The path has spaces on this Mac ("…/Application Support/…"), so match the tail.
            let command = String(fields[2])
            if command == "wineserver" || command.hasSuffix("/wineserver") || command.contains("/wineserver -") {
                snap.wineservers.append(pid)
                snap.wine.insert(pid)
                if isOurs(pid) { snap.ownWineservers.append(pid) }
                continue
            }
            let tokens = tokenize(command)
            if isSidecarCommand(tokens) { snap.sidecars.insert(pid) }
            guard let (at, program) = windowsProgram(in: tokens) else {
                if tokens.contains(where: isLauncherOfLoader) { snap.wine.insert(pid) }
                continue
            }
            snap.wine.insert(pid)
            let injecting = isInjector(program)
            let known = injecting || isLoader(program)
            if !known, isWineSystemProgram(program) {
                if isOurs(pid) { snap.ownSystemPrograms.append(pid) }
                continue
            }
            let ours = isOurs(pid)
            if !known, !ours { continue }
            var host = ""
            var bootFile = ""
            let rest = tokens[(at + 1)...]
            if injecting {
                // `Ashita-cli.exe <profile>.ini` / `injector.exe <profile>.xml`, as Runner.launch runs it.
                if let f = rest.first { bootFile = basename(f) }
            } else {
                for (n, t) in zip(rest.indices, rest) {
                    if t == "--server", n + 1 < tokens.count { host = tokens[n + 1]; break }
                    if t.hasPrefix("--server=") { host = String(t.dropFirst("--server=".count)); break }
                }
            }
            snap.clients.append(Client(pid: pid, group: group, host: normalize(host), injecting: injecting,
                                       bootFile: bootFile, other: !known, ownWine: ours))
        }
        snap.wineservers.sort()
        snap.ownWineservers.sort()
        snap.ownSystemPrograms.sort()
        snap.clients.sort { $0.pid < $1.pid }
        return snap
    }

    /// A command line split into words the way wine quotes them: a double-quoted run is one
    /// word, quotes removed, so `"Z:\Volumes\x10\Video Games\Eden\Ashita\injector.exe" eden.xml`
    /// is two words, not four. (wine's backslash-escaped quotes are not handled; no path or
    /// profile this launcher starts has one.)
    ///
    /// Only a quote at the start of a word opens a run; anywhere else it is an ordinary
    /// character. A run that is never closed means the quotes were not wine's (a password
    /// such as `ab"c` or `"abc`), and the whole line is split on spaces alone, so such a
    /// password can never swallow a later `--server` into one word.
    static func tokenize(_ command: String) -> [String] {
        var out: [String] = []
        var word = ""
        var quoted = false
        var started = false
        for ch in command {
            if ch == "\"", quoted { quoted = false; continue }
            if ch == "\"", !started { quoted = true; started = true; continue }
            if ch == " " || ch == "\t", !quoted {
                if started { out.append(word) }
                word = ""; started = false
                continue
            }
            word.append(ch); started = true
        }
        if quoted {
            return command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        if started { out.append(word) }
        return out
    }

    /// Where the Windows program is in `tokens`, and its path. It is the command itself, or
    /// follows a wine/sidecar executable. A Windows command line whose unquoted program path
    /// has spaces (`Z:\Volumes\x10\Video Games\…\injector.exe eden.xml`) is rejoined.
    private static func windowsProgram(in tokens: [String]) -> (Int, String)? {
        guard let at = tokens.firstIndex(where: { $0.lowercased().hasSuffix(".exe") || isLoader($0) || isInjector($0) })
        else { return nil }
        if at == 0 { return (0, tokens[0]) }
        if tokens[..<at].contains(where: isLauncherOfLoader) { return (at, tokens[at]) }
        if looksLikeWindowsPath(tokens[0]) { return (at, tokens[0...at].joined(separator: " ")) }
        return nil
    }

    /// `C:\…`, `Z:/…`, `.\…` or `\\…`: never how a Mac command line starts.
    private static func looksLikeWindowsPath(_ t: String) -> Bool {
        let c = Array(t)
        if c.count >= 3, c[0].isLetter, c[1] == ":", c[2] == "\\" || c[2] == "/" { return true }
        return t.hasPrefix(".\\") || t.hasPrefix("\\\\")
    }

    private static func isWineSystemProgram(_ t: String) -> Bool {
        guard wineSystemPrograms.contains(basename(t)) else { return false }
        let path = t.lowercased().replacingOccurrences(of: "/", with: "\\")
        return !path.contains("\\") || path.hasPrefix("c:\\windows\\")
    }

    static func byHost(_ clients: [Client]) -> [String: [pid_t]] {
        var out: [String: [pid_t]] = [:]
        for c in clients { out[c.host, default: []].append(c.pid) }
        return out.mapValues { $0.sorted() }
    }

    private static func basename(_ t: String) -> String {
        t.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { String($0).lowercased() } ?? ""
    }

    private static func isLoader(_ t: String) -> Bool {
        loaderNames.contains(basename(t)) || t.lowercased().contains("ffxi-bootmod")
    }

    private static func isInjector(_ t: String) -> Bool {
        injectorNames.contains(basename(t))
    }

    /// The command is the sidecar itself: its first word, or (an install path with spaces) a
    /// path split over the first words, none of them an option.
    private static func isSidecarCommand(_ tokens: [String]) -> Bool {
        guard let i = tokens.firstIndex(where: { basename($0).hasPrefix("x87sidecar") }) else { return false }
        return i == 0 || (tokens[0].hasPrefix("/") && tokens[i].contains("/")
                          && !tokens[1...i].contains { $0.hasPrefix("-") })
    }

    private static func isLauncherOfLoader(_ t: String) -> Bool {
        let b = basename(t)
        return b.hasPrefix("wine") || b.contains("preloader") || b.contains("x87sidecar")
    }

    static func snapshot() -> Snapshot {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,pgid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return Snapshot() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let own = OwnWine.current()
        // Most of these share one executable (wine's): resolve each path once per scan.
        var seen: [String: Bool] = [:]
        return parse(String(decoding: data, as: UTF8.self), isOurs: { pid in
            guard let e = executablePath(of: pid) else { return false }
            if let known = seen[e] { return known }
            let ours = own.owns(executable: e)
            seen[e] = ours
            return ours
        })
    }

    /// The file a process is running, as the kernel has it. Not `ps -o comm`: wine rewrites
    /// its argv, so for a Windows program comm is `.\bootloader\horizon-loader.exe` or
    /// `C:\windows\system32\services.exe`, while this is `…/wine-coop/wine/lib/wine/
    /// x86_64-unix/wine` (read both on the live client, 2026-09-26). nil when the process is
    /// gone or not this user's.
    static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Every client, injector and other Windows program, by host (injectors and hostless
    /// programs under "").
    static func scan() -> [String: [pid_t]] { snapshot().byHost }

    static func describe(_ live: [String: [pid_t]]) -> String {
        live.keys.sorted().map { "\($0.isEmpty ? "unknown host" : $0): pid "
            + (live[$0] ?? []).map(String.init).joined(separator: ",") }.joined(separator: "; ")
    }

    /// The msync/esync mode of the wineserver serving `prefix`, read from its environment
    /// (`ps -E`, which shows the variables of this user's own processes). nil when no
    /// wineserver in `pids` serves that prefix or its environment cannot be read.
    static func runningSyncMode(prefix: String, wineservers pids: [pid_t]) -> MultiWorld.SyncMode? {
        wineserver(serving: prefix, among: pids)?.sync
    }

    /// The wineserver in `pids` that serves `prefix`, and its msync/esync mode; see
    /// `runningSyncMode`. LiveAddons needs the pid too, for the wine it was started from.
    static func wineserver(serving prefix: String, among pids: [pid_t]) -> (pid: pid_t, sync: MultiWorld.SyncMode)? {
        for pid in pids {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-E", "-ww", "-o", "command=", "-p", String(pid)]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let m = MultiWorld.syncMode(wineserverEnv: String(decoding: data, as: UTF8.self), prefix: prefix) {
                return (pid, m)
            }
        }
        return nil
    }
}

/// The wine builds this launcher runs clients with: the patched wine (`X87Sidecar.patchedWine`,
/// at any of the places it is looked for) and the wrapper's own `SharedSupport/wine`, each
/// with its symlinks resolved (`/Volumes/Games/FFXI/wine-coop` is a link into Application
/// Support). A Windows program's executable is the wine binary under one of these roots
/// (`wine/lib/wine/x86_64-unix/wine`, the preloader), or the x87 sidecar wrapping it.
struct OwnWine: Equatable {
    /// Resolved folders, each ending in "/".
    let roots: [String]

    init(roots: [String]) {
        self.roots = Array(Set(roots.flatMap { r -> [String] in
            let dir = r.hasSuffix("/") ? String(r.dropLast()) : r
            return [dir, OwnWine.resolve(dir)].map { $0 + "/" }
        })).sorted()
    }

    func owns(executable: String?) -> Bool {
        guard let e = executable, !e.isEmpty else { return false }
        let path = OwnWine.resolve(e)
        if (path as NSString).lastPathComponent.lowercased().hasPrefix("x87sidecar") { return true }
        return roots.contains { path.hasPrefix($0) || e.hasPrefix($0) }
    }

    /// realpath, or the path as given when it does not exist (a volume not mounted).
    static func resolve(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(r) }
        return String(cString: r)
    }

    /// Scans run on and off the main actor.
    private static let cacheLock = NSLock()
    private static var cache: (wrapper: String?, patched: [String], own: OwnWine)?

    /// This launcher's builds, from the remembered install and folder (read from defaults only,
    /// so no volume is touched to find them). Cached until either changes.
    static func current() -> OwnWine {
        let wrapper = Install.rememberedWrapper()?.path
        let patched = X87Sidecar.patchedWineCandidates
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cache, c.wrapper == wrapper, c.patched == patched { return c.own }
        let roots = patched.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
        let own = OwnWine(roots: roots + (wrapper.map { [$0 + "/Contents/SharedSupport/wine"] } ?? []))
        cache = (wrapper, patched, own)
        return own
    }
}

/// The rules for running several worlds side by side in one prefix.
enum MultiWorld {
    /// Why launching `world` now must be refused, or nil. Only more copies of one world than it
    /// allows are refused; different worlds always may run together.
    ///
    /// `hosts` is every spelling this world's clients may be filed under (the server's host and
    /// the `--server` its boot profile actually carries). `sessionGroups` are this launcher's
    /// own running sessions of this world, which count even while they are still injecting and
    /// so have no host yet.
    ///
    /// Another launcher process's sessions are invisible here except through the scan, and for
    /// the first seconds of a launch the scan sees only its injector. So an injector counts
    /// too: `injectorHost` turns its boot profile into the `--server` that profile carries.
    /// An injector whose world cannot be told that way, and that is not one of `ownGroups`
    /// (this launcher's sessions of any world), is assumed to be starting this world: a wait
    /// of a few seconds is cheaper than a second copy on a server that bans them.
    static func refusal(world: String, hosts: [String], maxClients: Int,
                        clients: [LiveClients.Client], sessionGroups: Set<pid_t> = [],
                        ownGroups: Set<pid_t> = [],
                        injectorHost: (String) -> String? = { _ in nil }) -> String? {
        let keys = Set(hosts.map(LiveClients.normalize)).subtracting([""])
        var resolved: [String: String] = [:]
        func host(of c: LiveClients.Client) -> String {
            guard c.injecting else { return c.host }
            if let h = resolved[c.bootFile] { return h }
            let h = c.bootFile.isEmpty ? "" : LiveClients.normalize(injectorHost(c.bootFile) ?? "")
            resolved[c.bootFile] = h
            return h
        }
        let mine = clients.filter { keys.contains(host(of: $0)) }
        let groups = Set(mine.map(\.group)).union(sessionGroups)
        let cap = max(maxClients, 1)
        if groups.count >= cap {
            let seen = (mine.first { !$0.injecting } ?? mine.first).map { "pid \($0.pid)" }
                ?? "started from this window"
            if maxClients <= 1 {
                return "\(world) is already running (\(seen)). \(world) does not allow a second client "
                     + "from the same player, so another copy is refused. Stop the running one first."
            }
            return "\(world) already has \(groups.count) clients running (\(seen)). \(world) allows at "
                 + "most \(maxClients) per player, so another copy is refused. Stop one first."
        }
        // A group that already shows a loader is that loader's world, not an unknown one.
        let known = Set(clients.filter(\.knownLoader).map(\.group)).union(groups).union(ownGroups)
        let unknown = clients.filter { $0.injecting && host(of: $0).isEmpty && !known.contains($0.group) }
        guard groups.count + Set(unknown.map(\.group)).count >= cap, let first = unknown.first else { return nil }
        return "A game client is starting (pid \(first.pid)) and which world it is cannot be told until "
             + "its loader appears. \(world) allows \(maxClients <= 1 ? "one client" : "at most \(maxClients) clients") "
             + "per player, so this launch waits for it: press Play again in a few seconds."
    }

    /// wine's fast-synchronisation mode. It belongs to the wineserver, which every client in the
    /// prefix shares: a client whose WINEMSYNC/WINEESYNC disagree with the running server's
    /// exits at start-up ("Server is running with WINEESYNC but this process is not…").
    enum SyncMode: String { case msync, esync, off }

    static func syncMode(msync: Bool, esync: Bool) -> SyncMode { msync ? .msync : esync ? .esync : .off }

    /// A wineserver's `ps -E` line: the command, then its environment as `KEY=value` words.
    /// nil unless it serves `prefix`.
    static func syncMode(wineserverEnv text: String, prefix: String) -> SyncMode? {
        let line = " " + text.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        guard !prefix.isEmpty, line.contains(" WINEPREFIX=\(prefix) ") || line.contains(" WINEPREFIX=\(prefix)/ ")
        else { return nil }
        if line.contains(" WINEMSYNC=1 ") { return .msync }
        if line.contains(" WINEESYNC=1 ") { return .esync }
        return .off
    }

    /// The sync mode a launch must use when a wineserver is already running: the server's,
    /// since a mismatch kills the new client. A world that must not run with msync (Gaia XI)
    /// is refused when the running server has it on.
    static func syncDecision(want: SyncMode, running: SyncMode?, msyncAllowed: Bool,
                             world: String) -> (use: SyncMode, refusal: String?) {
        guard let running, running != want else { return (want, nil) }
        if running == .msync, !msyncAllowed {
            return (want, "\(world) must run with msync off, but the world already running shares a "
                        + "wineserver that has it on, and one wineserver cannot do both. "
                        + "Stop the other world first.")
        }
        return (running, nil)
    }

    /// Why Repair or a client update must not start now, or nil. Both run wine in the prefix or
    /// rewrite the shared client folder, so any client, any session of this launcher that is
    /// playing (even one not visible to a scan yet), and any launch holding the lock block them.
    static func maintenanceBlocker(_ live: [String: [pid_t]], sessionsPlaying: Int,
                                   lockHeldElsewhere: Bool) -> String? {
        if !live.isEmpty { return "a game is running in this prefix (\(LiveClients.describe(live)))" }
        if sessionsPlaying > 0 { return "a game is starting from this window" }
        if lockHeldElsewhere { return "another launcher window is starting a game, repairing or updating" }
        return nil
    }

    /// Does anything hold the shared prefix? An injector counts, so does any Windows program
    /// that is not one of wine's own (`Client.other`: a loader under a name nobody listed,
    /// whatever its world), and so does a session of this launcher that has spawned but whose
    /// client the scan has not caught yet. This decides `wineserver -k` at launch and at the
    /// last Stop, the renderer step and the sync mode, so it errs towards "live".
    ///
    /// `ps` cannot tell which prefix a Windows program runs in (wine rewrites its command line
    /// and `ps -E` shows no environment for it; measured 2026-09-26), so an installer running in
    /// the installer prefix counts as well. The cost is a renderer change waiting for it.
    static func clientsLive(_ clients: [LiveClients.Client], otherSessionsPlaying: Int) -> Bool {
        !clients.isEmpty || otherSessionsPlaying > 0
    }

    /// A session's pids: its own process group when it has one. Without one (the spawned
    /// process was gone before its group could be read), its host's clients that were not
    /// there before it started and belong to no other session.
    ///
    /// The group rests on the loader staying in the group it was spawned in (measured, see
    /// LiveClients). Until the group has been seen holding a loader (`groupHeldLoader`), the
    /// host's new clients are added to it, so a loader that wine moved into a group of its own
    /// is still watched and stopped. Once it has, an empty group means the client exited.
    static func sessionPIDs(group: pid_t?, groupHeldLoader: Bool = false, host: String,
                            preexisting: Set<pid_t>, otherGroups: Set<pid_t>,
                            in snap: LiveClients.Snapshot) -> [pid_t] {
        var pids: Set<pid_t> = []
        if let g = group {
            pids.formUnion(snap.members(ofGroup: g))
            if groupHeldLoader { return pids.sorted() }
        }
        pids.formUnion(snap.clients.filter {
            !$0.injecting && $0.host == host && !preexisting.contains($0.pid) && !otherGroups.contains($0.group)
        }.map(\.pid))
        return pids.sorted()
    }

    /// Has `group` been seen holding a loader (not just the injector) in this scan?
    static func groupHoldsLoader(_ group: pid_t?, in snap: LiveClients.Snapshot) -> Bool {
        guard let g = group else { return false }
        return snap.clients.contains { $0.knownLoader && $0.group == g }
    }

    /// Of `pids`, the ones Stop may still signal, with the group each is in now: a process
    /// running wine, the sidecar or a Windows program (`Snapshot.wine`) that is in this
    /// session's `group`, or, for the no-group fallback, a loader of this session's `host` in
    /// no other session's group. Anything else (a pid the injector left behind and the system
    /// has since handed to another program) is left alone. The group is kept so a later
    /// SIGKILL can check again that the pid is still the same process (`stillSignalable`).
    static func signalable(_ pids: [pid_t], group: pid_t?, host: String, otherGroups: Set<pid_t>,
                           in snap: LiveClients.Snapshot) -> [pid_t: pid_t] {
        var out: [pid_t: pid_t] = [:]
        for pid in pids {
            guard snap.wine.contains(pid), let g = snap.groups[pid] else { continue }
            if let group, g == group { out[pid] = g; continue }
            if !host.isEmpty, !otherGroups.contains(g),
               snap.clients.contains(where: { $0.pid == pid && $0.knownLoader && $0.host == host }) {
                out[pid] = g
            }
        }
        return out
    }

    /// Is `pid` still the wine process that was in `group` when Stop signalled it?
    static func stillSignalable(_ pid: pid_t, group: pid_t, in snap: LiveClients.Snapshot) -> Bool {
        snap.wine.contains(pid) && snap.groups[pid] == group
    }

    /// The wineserver is every client's. Stop it only when no client or injector is left, no
    /// session of this launcher is playing, and no launch (from any launcher) is under way.
    static func mayStopWineserver(_ clients: [LiveClients.Client], otherSessionsPlaying: Int,
                                  launchUnderWay: Bool) -> Bool {
        clients.isEmpty && otherSessionsPlaying == 0 && !launchUnderWay
    }

    /// Clients this launcher did not start (another launcher process, a hand-run): not in any
    /// of `ownGroups`, and not on a host a group-less session of ours is playing.
    static func elsewhere(_ clients: [LiveClients.Client], ownGroups: Set<pid_t>,
                          ownHostsWithoutGroup: Set<String>) -> [String: [pid_t]] {
        LiveClients.byHost(clients.filter {
            $0.knownLoader && !ownGroups.contains($0.group) && !ownHostsWithoutGroup.contains($0.host)
        })
    }

    /// Default DXVK frame-rate log, one per world so two clients never write the same file.
    static func fpsLogPath(gameDirName: String, world: String) -> String {
        let slug = world.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "C:\\" + gameDirName + "\\" + (slug.isEmpty ? "fps.csv" : "fps-\(slug).csv")
    }

    /// 8 GB Mac: two clients plus LSB took HorizonXI to 0.4 fps on 2026-09-25/26. A warning,
    /// never a block.
    ///
    /// With no other client running the same thresholds apply, plus a floor on the swap clause:
    /// macOS grows swap a gigabyte at a time to fit what is in it, so the used fraction sits
    /// above 60% whenever anything is swapped (2.5 of 3 GB, 53% free, on an idle 2026-10-14
    /// launcher). The single-client collapses on record were at 4.6-6.7 GB of swap
    /// (CHECKPOINT-2026-09-26, MACOS-27-PERFORMANCE), so below 4 GB the line would be noise.
    static func memoryWarning(swapUsedFraction: Double, freePercent: Int,
                              swapUsedBytes: UInt64 = .max, othersRunning: Bool = true) -> String? {
        let swapHeavy = swapUsedFraction > 0.6 && (othersRunning || swapUsedBytes >= 4 << 30)
        guard swapHeavy || freePercent < 20 else { return nil }
        if othersRunning {
            return "Memory is low (swap \(Int((swapUsedFraction * 100).rounded()))% used) — "
                 + "a second client may run at a few fps."
        }
        let gb = swapUsedBytes == .max ? "" : String(format: " (%.1f GB in swap)", Double(swapUsedBytes) / Double(1 << 30))
        return "Memory is low\(gb) — the game may stutter."
    }

    /// Swap used as a fraction of swap in use, swap used in bytes, and the kernel's free-memory
    /// percentage (what `memory_pressure` prints as "System-wide memory free percentage").
    static func memorySnapshot() -> (swapUsedFraction: Double, swapUsedBytes: UInt64, freePercent: Int) {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let ok = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        let swapFraction = ok && swap.xsu_total > 0 ? Double(swap.xsu_used) / Double(swap.xsu_total) : 0
        var level: Int32 = 100
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &lsize, nil, 0) != 0 { level = 100 }
        return (swapFraction, ok ? swap.xsu_used : 0, Int(level))
    }

    static func currentMemoryWarning(othersRunning: Bool = true) -> String? {
        let m = memorySnapshot()
        return memoryWarning(swapUsedFraction: m.swapUsedFraction, freePercent: m.freePercent,
                             swapUsedBytes: m.swapUsedBytes, othersRunning: othersRunning)
    }
}

/// Held for the whole of a launch, from the first check to the spawn, and while the last Stop
/// decides to take the wineserver down. Until the injector exists no scan can see a launch, so
/// without this a second launcher process could pass every check and `wineserver -k` it.
/// flock, so a crashed holder releases it.
enum LaunchLock {
    static let defaultPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HorizonXI-on-Mac/launch.lock")

    /// An fd to pass to `release`, or nil when another holder has it.
    static func acquire(at url: URL = defaultPath) -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Close-on-exec: an flock lasts while any copy of the fd is open, and a game spawned
        // while the lock is held must not carry it off and hold it for the whole session.
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
        return fd
    }

    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// Release once a scan can see the launch `pid` started: `Detach.spawn` returns while the
    /// spawned shell is still a shell, and until it has exec'd wine on the injector, no other
    /// launcher's scan can tell a launch is there. Released anyway once `pid` is gone, or after
    /// `timeout` seconds, so a launch that never shows cannot hold every other launch off.
    static func release(_ fd: Int32, whenVisible pid: pid_t, group: pid_t?, timeout: Double = 10) {
        Task.detached {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let snap = LiveClients.snapshot()
                if snap.clients.contains(where: { $0.pid == pid || (group != nil && $0.group == group) }) { break }
                if snap.groups[pid] == nil { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            release(fd)
        }
    }
}

/// One `Runner` per world session. The selected world's session drives Play, Stop and the log
/// pane; `live` feeds the Running list.
@MainActor
final class Sessions: ObservableObject {
    /// Not @Published: `runner(for:)` creates sessions while a view body reads it, and a new
    /// session is idle, so nothing on screen changes. Runner changes are forwarded below.
    private(set) var ids: [String] = []
    private var runners: [String: Runner] = [:]
    private var worldOf: [String: String] = [:]
    /// Which session a world's Play/Stop/log currently mean: the newest one started for it.
    private var current: [String: String] = [:]
    private var forwards: [String: AnyCancellable] = [:]
    /// Live clients this launcher did not start, by host. See `refreshElsewhere`.
    @Published private(set) var elsewhere: [String: [pid_t]] = [:]

    func runner(for world: String) -> Runner {
        if let id = current[world], let r = runners[id] { return r }
        return make(id: world, world: world)
    }

    /// A further session for a world that allows several clients. Idle extras are reused.
    func newSession(for world: String) -> Runner {
        if let id = ids.first(where: { worldOf[$0] == world && runners[$0]?.running == false
                                       && runners[$0]?.busy == false }),
           let r = runners[id] {
            current[world] = id
            return r
        }
        var n = 2
        while runners["\(world) #\(n)"] != nil { n += 1 }
        return make(id: "\(world) #\(n)", world: world)
    }

    var live: [(id: String, world: String, runner: Runner)] {
        ids.compactMap { id in
            guard let r = runners[id], r.running, let w = worldOf[id] else { return nil }
            return (id, w, r)
        }
    }

    var anyBusy: Bool { runners.values.contains { $0.busy } }

    /// The `--server` each world's boot profile carries, normalised, by world name. The
    /// duplicate refusal checks it as well as the Host field, so PLAY/RUNNING must too.
    @Published private(set) var bootHosts: [String: String] = [:]

    private var cleaning = false

    /// The scan and the boot-profile reads (which may sit on an external volume) run off the
    /// main actor; only a change is published.
    ///
    /// Also takes on what an earlier run of this launcher left behind (`Leftovers`): a client of
    /// its own, in `install`'s prefix and of a listed world, becomes a session with its Stop;
    /// wine's own programs left with no wineserver are ended quietly, in a task of their own.
    /// Neither happens while another launcher is alive, a job of this one is under way, or
    /// without `install`; a launch of this one keeps its client by group or host (`playingGroups`)
    /// and, for the cleanup, by `anyPlaying` and the launch lock.
    func refreshElsewhere(install: Install? = nil, profiles: [(world: String, profile: String)] = [],
                          servers: [Server] = []) async {
        let before = Runner.playingGroups
        let prefix = install.map { $0.prefix.path } ?? ""
        let (snap, boot, evidence, prefixPath, serverless) = await Task.detached {
            () -> (LiveClients.Snapshot, [String: String], (groups: [pid_t: String], servers: [pid_t: String?]), String, [pid_t]) in
            var boot: [String: String] = [:]
            if let install {
                for p in profiles {
                    if let h = Credentials.bootServer(in: install, profile: p.profile) {
                        boot[p.world] = LiveClients.normalize(h)
                    }
                }
            }
            let snap = LiveClients.snapshot()
            guard !prefix.isEmpty else { return (snap, boot, ([:], [:]), "", []) }
            let ev = Leftovers.evidence(snap, ownGroups: before.groups, ownHostsWithoutGroup: before.hostsWithoutGroup)
            // The prefix is touched (realpath, stat; it may sit on a sleeping drive) only when
            // there is something to decide: almost every refresh has nothing left over.
            let left = snap.ownWineservers.isEmpty && !snap.ownSystemPrograms.isEmpty
                ? Leftovers.serverless(snap, parentOf: Leftovers.parentPID,
                                       prefixSocketExists: Leftovers.prefixSocketExists(prefix))
                : []
            let resolved = ev.groups.isEmpty && ev.servers.isEmpty ? prefix : OwnWine.resolve(prefix)
            return (snap, boot, ev, resolved, left)
        }.value
        if boot != bootHosts { bootHosts = boot }

        // A job of this launcher (Repair, an update, CatsEyeXI's launcher) may be the very
        // session an adoption would take over, or have started what looks left over: later.
        if let install, !prefixPath.isEmpty, !Runner.workInFlight, !SingleInstance.otherLauncherAlive() {
            // Against this launcher's sessions as they are now, not as they were before the scan.
            let own = Runner.playingGroups
            let orphans = Leftovers.adoptable(snap, ownGroups: own.groups, ownHostsWithoutGroup: own.hostsWithoutGroup,
                                              prefix: prefixPath, prefixOfGroup: evidence.groups,
                                              serverPrefixes: evidence.servers, otherLauncherAlive: false)
            for o in orphans {
                // The world whose Host field or boot profile's --server the loader was given. A
                // client of no listed world stays elsewhere: its session would write its window
                // size into some other world's boot profile when it ended.
                guard let w = servers.first(where: { s in
                    Set([LiveClients.normalize(s.host), self.bootHosts[s.name] ?? ""]).subtracting([""]).contains(o.host)
                }) else { continue }
                // The world's own session when it is idle, else a further one (a world that
                // allows several clients, one of them running here already).
                let idle = runner(for: w.name)
                let r = !idle.running && !idle.busy ? idle : newSession(for: w.name)
                // Pointed at that world's folder only now, for the one world adopted: finding a
                // world's client can walk its drive, which no refresh should do for every world.
                r.adopt(group: o.group, host: o.host, world: w.name, install: install.forServer(w),
                        profile: w.bootProfile, pids: o.pids)
            }
            if !serverless.isEmpty, !cleaning, !Runner.anyPlaying {
                cleaning = true
                // Its own task: the seconds it waits (one, then up to three for SIGTERM) never
                // hold up this refresh, the RUNNING list, or start-up's forwarded --play.
                Task { [weak self] in
                    let ended = await Task.detached { await Leftovers.endServerless(serverless, prefix: prefix) }.value
                    self?.cleaning = false
                    if !ended.isEmpty {
                        Runner.appendToLogFile("i  ended \(ended.count) wine program(s) left with no wineserver (pid "
                                               + ended.map(String.init).joined(separator: ",") + ")")
                    }
                }
            }
        }

        let own = Runner.playingGroups
        let found = MultiWorld.elsewhere(snap.clients, ownGroups: own.groups,
                                         ownHostsWithoutGroup: own.hostsWithoutGroup)
        if found != elsewhere { elsewhere = found }
    }

    /// Is `world` playing in a client this window did not start, under its Host field or the
    /// `--server` of its boot profile?
    func runningElsewhere(world: String, host: String) -> Bool {
        let keys = Set([LiveClients.normalize(host), bootHosts[world] ?? ""]).subtracting([""])
        return keys.contains { elsewhere[$0] != nil }
    }

    private func make(id: String, world: String) -> Runner {
        let r = Runner(session: id)
        runners[id] = r
        worldOf[id] = world
        current[world] = id
        ids.append(id)
        forwards[id] = r.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return r
    }
}
