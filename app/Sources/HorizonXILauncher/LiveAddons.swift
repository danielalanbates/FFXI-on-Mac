import Foundation

/// An Addons… change reaches a client that is already running, without a restart.
///
/// Applying the sheet still writes `scripts/default.txt` first (AddonSuite.write), so the next
/// Play is right whatever happens here. Then, if that world's client is running from the selected
/// install, exactly the lines that changed -- `/addon load|unload <name>`, `/load|/unload
/// <plugin>` -- are handed to Ashita's Thirdparty plugin, which HorizonXI's own default script
/// loads. Thirdparty runs them through ChatManager::ParseCommand, the path a typed command takes,
/// on the game's next keyboard read: the addon appears or disappears within a frame or two.
///
/// The hand-over is `ashita-send.exe` (tools/ashita-send.c), run under the running game's own
/// wine, in its prefix, with its wineserver's msync/esync mode, because the plugin's shared memory
/// exists only inside that wineserver. The game's memory is never read, and nothing is signalled
/// or attached to; the helper only opens the plugin's named block, as any Windower-era tool does.
///
/// Rules (the helper enforces the second and third again on its own):
/// - only names the world's AddonPolicy allows are ever loaded;
/// - never `/unload` or `/reload` of `thirdparty` (the plugin would free itself in the middle of
///   running the command) or `addons` (every Lua addon would end at once);
/// - a name with anything outside `A-Z a-z 0-9 _ - .` is not sent at all (a `;` would be split
///   into a second command by the plugin; stripping it would name a different addon);
/// - no wineserver for the prefix means no client to reach, and the helper is not run: wine would
///   start a fresh wineserver for it. (A wineserver that exits in the moment between the scan
///   and the helper's start is the one window left; such a server ends itself seconds later.)
///
/// Every outcome is one line in launcher.log. Nothing is shown on success; when it could not be
/// delivered, the change still loads at the next Play, as before.
enum LiveAddons {
    /// What the helper's exit status means (see the comment at the top of tools/ashita-send.c).
    enum Outcome: Equatable {
        case delivered, refused, noClient, ambiguous, busy, pending
        /// wine or the helper ended some other way (wine's own failure codes, a crash).
        case failed(Int32)
        /// The helper was still running after the launcher's limit and was stopped.
        case timedOut

        init(exitCode: Int32) {
            switch exitCode {
            case 0: self = .delivered
            case 1: self = .refused
            case 2: self = .noClient
            case 3: self = .ambiguous
            case 4: self = .busy
            case 5: self = .pending
            default: self = .failed(exitCode)
            }
        }

        var exitCode: Int32 {
            switch self {
            case .delivered: return 0
            case .refused: return 1
            case .noClient: return 2
            case .ambiguous: return 3
            case .busy: return 4
            case .pending: return 5
            case .failed(let c): return c == 0 ? 70 : c
            case .timedOut: return 75
            }
        }

        /// For launcher.log, after the list of commands.
        var text: String {
            switch self {
            case .delivered: return "delivered"
            case .refused: return "refused by the helper"
            case .noClient: return "not sent: no client in this prefix has the Thirdparty plugin loaded"
            case .ambiguous: return "not sent: more than one client has the Thirdparty plugin, and which is this world's cannot be told"
            case .busy: return "not sent: the plugin was still busy with an earlier change"
            case .pending: return "handed over, not taken yet: the game has not read its keyboard for 5 s; it runs when it does"
            case .failed(let c): return "not sent: the helper exited \(c)"
            case .timedOut: return "not sent: the helper was still running after the time limit and was stopped"
            }
        }
    }

    // MARK: - What to send

    /// The plugin is the channel itself; `winefix` is this project's shim and never offered.
    private static let neverSent: Set<String> = ["thirdparty", "winefix"]
    /// The launcher loads these itself, by its own toggles, outside the managed block.
    private static let launcherManaged: Set<String> = ["vanavoice", "vanaguide"]
    private static let nameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")

    /// `raw` as it can go into a command, or nil when it cannot be sent faithfully.
    static func sendableName(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 64,
              raw.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }) else { return nil }
        return raw
    }

    /// The commands that take a running client from what the script loaded (`before`, read just
    /// before Apply rewrote it) to what the sheet now writes (`after`). Items only in `before`
    /// are not touched: the sheet hides what the world's policy does not allow, and those are
    /// neither written nor sent. Order: addon unloads, plugin unloads, plugin loads (the Lua host
    /// `addons` among them), addon loads.
    static func commands(from before: [AddonSuite.Item], to after: [AddonSuite.Item],
                         policy: AddonPolicy) -> [String] {
        var was: [String: Bool] = [:]
        for item in before where was[item.id] == nil { was[item.id] = item.enabled }
        var addonOff: [String] = [], pluginOff: [String] = [], pluginOn: [String] = [], addonOn: [String] = []
        var seen = Set<String>()
        for item in after {
            guard seen.insert(item.id).inserted else { continue }
            guard (was[item.id] ?? false) != item.enabled else { continue }
            guard let name = sendableName(item.name) else { continue }
            let key = AddonPolicy.normalize(name)
            if item.enabled, !policy.allows(name) { continue }
            if item.isPlugin {
                if neverSent.contains(key) { continue }
                if !item.enabled, key == "addons" { continue }
                if item.enabled { pluginOn.append(name) } else { pluginOff.append(name) }
            } else {
                if launcherManaged.contains(key) { continue }
                if item.enabled { addonOn.append(name) } else { addonOff.append(name) }
            }
        }
        return addonOff.map { "/addon unload \($0)" } + pluginOff.map { "/unload \($0)" }
             + pluginOn.map { "/load \($0)" } + addonOn.map { "/addon load \($0)" }
    }

    /// A plugin or addon name as Ashita matches it: lowercased, no quotes, no `.dll`.
    private static func targetKey(_ word: String) -> String {
        var s = word.lowercased().filter { $0 != "\"" && $0 != "'" }
        if s.hasSuffix(".dll"), s.count > 4 { s.removeLast(4) }
        return s
    }

    /// `--send-ashita`: why `command` must not go to a client of a world with `policy`, or nil.
    /// On a hosted world (`hosted`), anything that loads must be on the world's published
    /// allowlist; a hosted world with no sourced policy has no allowlist, so nothing loads there
    /// from here. `/exec`, `/alias` and `/bind` can run any command, so they are not sent to a
    /// hosted world either.
    static func refusal(_ command: String, policy: AddonPolicy, hosted: Bool) -> String? {
        // Checked on the command as given, which is what is sent: a tab is a control character
        // to the helper, not whitespace to trim.
        if command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value >= 0x7f }) {
            return "only printable ASCII is sent"
        }
        let t = command.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        if t.isEmpty { return "nothing to send" }
        if t.contains(";") { return "';' would split it into two commands; send them one at a time" }
        if t.utf8.count > 2047 { return "longer than the plugin's 2047 bytes" }
        let words = t.drop(while: { $0 == "/" || $0 == " " })
            .split(separator: " ", omittingEmptySubsequences: true).map { String($0).lowercased() }
        guard let verb = words.first else { return "nothing to send" }
        func word(_ i: Int) -> String { i < words.count ? targetKey(words[i]) : "" }
        func notAllowed(_ name: String) -> String? {
            if name.isEmpty { return "/\(verb) needs a name" }
            guard hosted else { return nil }
            if policy.isRestricting, policy.allows(name) { return nil }
            return policy.isRestricting
                ? "\(name) is not on this world's approved list"
                : "this world publishes no approved list, so nothing is loaded on it from here"
        }
        switch verb {
        case "unload", "reload":
            let target = word(1)
            if target.isEmpty { return "/\(verb) needs a plugin name" }
            if target == "thirdparty" { return "never: Thirdparty would free itself in the middle of the command" }
            if target == "addons" { return "never: that ends every Lua addon at once" }
            if verb == "reload" { return notAllowed(target) }
        case "load":
            return notAllowed(word(1))
        case "addon", "addons":
            let sub = words.count > 1 ? words[1] : ""
            if sub == "load" || sub == "reload" { return notAllowed(word(2)) }
        case "exec", "alias", "bind":
            if hosted { return "/\(verb) can run any command; type it in the game instead" }
        default:
            break
        }
        return nil
    }

    // MARK: - Where to send it

    /// The running game's wine, prefix and sync mode.
    struct Target: Equatable {
        var wine: URL
        var prefix: URL
        var sync: MultiWorld.SyncMode
        var wineserver: pid_t
    }

    enum Resolution: Equatable {
        case target(Target)
        /// Why nothing is sent now; the change loads at the next Play.
        case skip(String)
    }

    /// Is `world`'s client running from the install whose prefix is `prefix`, and with which wine?
    ///
    /// - Every client the scan sees must be this world's (`hosts`): with another world's client
    ///   in the prefix too, the helper would find two plugins and which is which cannot be told
    ///   from here. An injector means a launch is under way: wait for it.
    /// - A wineserver must serve `prefix`; `server(prefix, pids)` reads which one and its sync
    ///   mode (LiveClients.wineserver). None means the client runs from another install.
    /// - The wine is the one whose `bin/wineserver` is that running wineserver's executable, so
    ///   the helper speaks the same wine protocol. A wineserver from a wine this launcher does
    ///   not run (`wines`) is not used.
    static func resolve(world: String, hosts: [String], prefix: String, snapshot: LiveClients.Snapshot,
                        server: (String, [pid_t]) -> (pid: pid_t, sync: MultiWorld.SyncMode)?,
                        executable: (pid_t) -> String?, wines: [URL]) -> Resolution {
        let keys = Set(hosts.map(LiveClients.normalize)).subtracting([""])
        let clients = snapshot.clients
        if clients.contains(where: \.injecting) { return .skip("a game is starting") }
        guard clients.contains(where: { keys.contains($0.host) }) else {
            return .skip("no \(world) client is running")
        }
        if clients.contains(where: { !keys.contains($0.host) }) {
            return .skip("another world's client is running too")
        }
        guard let s = server(prefix, snapshot.wineservers) else {
            return .skip("no wineserver serves this install's prefix; the client runs from another install")
        }
        guard let exe = executable(s.pid) else { return .skip("the wineserver's executable could not be read") }
        let running = OwnWine.resolve(exe)
        guard let wine = wines.first(where: {
            OwnWine.resolve($0.deletingLastPathComponent().appendingPathComponent("wineserver").path) == running
        }) else {
            return .skip("the running wineserver is not from a wine this launcher runs")
        }
        return .target(Target(wine: wine, prefix: URL(fileURLWithPath: prefix), sync: s.sync, wineserver: s.pid))
    }

    /// The wines a client of `install` may be running under: the game's (every place it is
    /// looked for) and the wrapper's own.
    static func wines(for install: Install) -> [URL] {
        var out: [URL] = []
        if let w = X87Sidecar.patchedWine() { out.append(w) }
        for p in X87Sidecar.patchedWineCandidates where FileManager.default.isExecutableFile(atPath: p) {
            out.append(URL(fileURLWithPath: p))
        }
        out.append(install.wine)
        return out
    }

    /// The helper's whole environment. Only what wine needs to join the running wineserver: its
    /// prefix and its sync mode (a client that disagrees with the server exits at start-up), no
    /// display driver, no Mono/Gecko, no debug output. Nothing of the game's own environment.
    static func environment(for t: Target, home: String) -> [String: String] {
        [
            "WINEPREFIX": t.prefix.path,
            "WINEMSYNC": t.sync == .msync ? "1" : "0",
            "WINEESYNC": t.sync == .esync ? "1" : "0",
            "WINEDLLOVERRIDES": "mscoree,mshtml=;winemac.drv=d",
            "WINEDEBUG": "-all",
            "HOME": home,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }

    /// The bundled helper, or `vendor/ashita-send.exe` in a checkout (`swift run`, self-tests).
    static func helperURL() -> URL? {
        if let u = Bundle.main.url(forResource: "ashita-send", withExtension: "exe") { return u }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("vendor/ashita-send.exe")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // MARK: - Sending

    /// Run the helper with `commands` as its arguments (no stdin pipe to break). Its output goes
    /// to a file, not a pipe: a process wine might leave behind can never hold the read open.
    /// The helper's own waits are bounded (3 s busy + 5 s delivery); `limit` covers a wine that
    /// hangs on start-up, after which the helper (this launcher's own child, never the game) is
    /// stopped.
    static func run(_ commands: [String], target t: Target, helper: URL, limit: TimeInterval = 30,
                    home: String = NSHomeDirectory()) -> (outcome: Outcome, output: String, seconds: Double) {
        let fm = FileManager.default
        let outFile = fm.temporaryDirectory.appendingPathComponent("ffxi-ashita-send-\(UUID().uuidString).txt")
        guard fm.createFile(atPath: outFile.path, contents: nil),
              let out = try? FileHandle(forWritingTo: outFile) else { return (.failed(-1), "", 0) }
        defer { try? out.close(); try? fm.removeItem(at: outFile) }

        let p = Process()
        p.executableURL = t.wine
        p.arguments = [helper.path, "--"] + commands
        p.environment = environment(for: t, home: home)
        p.currentDirectoryURL = fm.temporaryDirectory
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        let start = Date()
        do { try p.run() } catch { return (.failed(-1), error.localizedDescription, 0) }
        var outcome: Outcome
        if done.wait(timeout: .now() + limit) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            outcome = .timedOut
        } else {
            outcome = Outcome(exitCode: p.terminationStatus)
        }
        let seconds = Date().timeIntervalSince(start)
        let text = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let firstLines = text.split(whereSeparator: \.isNewline).prefix(4).joined(separator: " / ")
        return (outcome, String(firstLines.prefix(300)), seconds)
    }

    /// One line for launcher.log about sending `commands` to `world`'s running client.
    static func logLine(_ commands: [String], world: String, outcome: Outcome?, skip: String? = nil,
                        output: String = "", seconds: Double = 0, tries: Int = 1) -> String {
        let list = commands.count <= 8 ? commands.joined(separator: ", ")
            : commands.prefix(8).joined(separator: ", ") + " and \(commands.count - 8) more"
        if let skip { return "i  addons, live in \(world): \(list): not sent (\(skip)); they load at the next Play" }
        guard let outcome else { return "i  addons, live in \(world): \(list)" }
        let took = String(format: "%.1f s", seconds)
        switch outcome {
        case .delivered:
            let after = tries > 1 ? ", after \(tries) tries: an earlier change was still waiting for the game" : ""
            return "==> addons, live in \(world): \(list): delivered (\(took)\(after))"
        case .pending:
            return "i  addons, live in \(world): \(list): \(outcome.text)"
        default:
            let detail = output.isEmpty ? "" : " [\(output)]"
            return "!! addons, live in \(world): \(list): \(outcome.text)\(detail); they load at the next Play"
        }
    }

    /// Sends run one at a time: the plugin's block has no lock, so two helpers must never write
    /// it together.
    private static let queue = DispatchQueue(label: "org.batesai.horizonxi-on-mac.live-addons", qos: .utility)

    /// The Apply path, off the main thread. `log` gets exactly one line.
    ///
    /// Busy means the plugin has not yet taken an earlier batch -- typically the previous Apply's,
    /// pending because the game, in the background behind the launcher, has not read its keyboard
    /// since. That batch runs as soon as it does, and this one is tried again (a fresh scan and a
    /// fresh helper each time, about every 3 s) for up to `busyRetry` seconds, so a second
    /// change made meanwhile is not left for the next Play.
    static func apply(_ commands: [String], world: String, host: String, profile: String,
                      install: Install, busyRetry: TimeInterval = 120,
                      log: @escaping (String) -> Void) {
        guard !commands.isEmpty else { return }
        queue.async {
            let hosts = [host] + [Credentials.bootServer(in: install, profile: profile)].compactMap { $0 }
            log(deliver(commands, world: world, hosts: hosts, prefix: install.prefix.path,
                        wines: wines(for: install), busyRetry: busyRetry))
        }
    }

    /// `apply`'s work, blocking: scan, find, send, retry while busy. Returns the log line.
    static func deliver(_ commands: [String], world: String, hosts: [String], prefix: String,
                        wines: [URL], busyRetry: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(busyRetry)
        let start = Date()
        var tries = 0
        while true {
            tries += 1
            let r = resolve(world: world, hosts: hosts, prefix: prefix, snapshot: LiveClients.snapshot(),
                            server: { LiveClients.wineserver(serving: $0, among: $1) },
                            executable: { LiveClients.executablePath(of: $0) }, wines: wines)
            switch r {
            case .skip(let why):
                return logLine(commands, world: world, outcome: nil, skip: why)
            case .target(let t):
                guard let helper = helperURL() else {
                    return logLine(commands, world: world, outcome: nil, skip: "ashita-send.exe is missing from the app")
                }
                let sent = run(commands, target: t, helper: helper)
                if sent.outcome == .busy, Date() < deadline { continue }
                return logLine(commands, world: world, outcome: sent.outcome, output: sent.output,
                               seconds: tries > 1 ? Date().timeIntervalSince(start) : sent.seconds, tries: tries)
            }
        }
    }
}
