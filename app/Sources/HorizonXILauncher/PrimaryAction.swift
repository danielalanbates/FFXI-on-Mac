import Foundation
import AppKit

/// The big button under the account fields is always the next thing that has to happen, not
/// only PLAY. Daniel, 2026-10-15: "there should be a setup button in place of the text 'play'
/// when the game is not installed or dependencies aren't done" -- the user sets up, updates and
/// repairs HorizonXI from the main window, no menu digging. Before this the button said PLAY
/// (grey) while the fix lived in the collapsed Setup & Diagnostics panel -- and on 2026-10-15
/// the fix offered there (Repair) could not work at all, because the 'Games' drive was
/// ghost-mounted.
///
/// The button says one of Daniel's verbs: Setup, Update, Repair, Play, Stop (Play Another where
/// a world allows two clients), or what is running ("Setting up… 42%"). Anything else the user
/// needs to know is the one short line under it.
///
/// `Primary.decide` is pure: plain values in, one decision out, so `--selftest-primary-action`
/// and `--next-action` exercise exactly what the window shows. `PrimaryFixer` performs the jobs
/// that need no window, for the button and for `--fix` alike; the window runs Setup's chain
/// (ContentView.runSetup).
enum PrimaryAction: Equatable {
    /// A job is running; the button is its progress and cannot be pressed.
    case working(Work, progress: Double?)
    /// Something is not installed or a dependency is not done. One click runs every step still
    /// missing, in order (ContentView.runSetup).
    case setup(SetupNeed)
    /// A newer game client is published (HorizonXI), or the world's login server needs one.
    case update(world: String, to: String)
    /// Something that is installed is broken in a way one click fixes.
    case repair(RepairNeed)
    case stop
    case play
    case playAnother
    /// Play cannot start yet and there is nothing to press: PLAY, greyed, with the reason.
    case blocked(String)

    enum Work: String {
        case settingUp, updating, repairing, checking, starting, stopping

        var label: String {
            switch self {
            case .settingUp: return "Setting up…"
            case .updating: return "Updating…"
            case .repairing: return "Repairing…"
            case .checking: return "Checking…"
            case .starting: return "Starting…"
            case .stopping: return "Stopping…"
            }
        }
    }

    enum SetupNeed: Equatable {
        /// No wrapper anywhere: Wine and the Windows drive come first.
        case install
        /// The remembered wrapper sits on this drive, which is not there (ghost or unplugged).
        case wrapperDrive(String)
        /// The game files sit on (or link into) this drive, which is not there.
        case dataDrive(String)
        /// The wrapper is there but its Wine is not.
        case wine
        /// Not downloaded yet, or (partial) Ashita / the base game files are missing.
        case game(partial: Bool)
        /// The world has no download route, or its folder is not chosen / ambiguous.
        case chooseFolder
        /// The patched game Wine (wine-coop) is not on this Mac. See docs/WINE-BUILD.md.
        case gameWine
        /// The local world's server is not built yet. Disabled below its disk floor.
        case localServer(enabled: Bool)
    }

    enum RepairNeed: Equatable {
        /// Wine's library links (the rpath check).
        case wine
        /// The drive is known to macOS but not mounted: `diskutil mount`, no admin.
        case mount(drive: String, device: String)
        /// macOS refuses this app the game's drive: Full Disk Access (or Removable Volumes).
        case access
    }

    /// Stable name for `--next-action` output and scripts.
    var id: String {
        switch self {
        case .working: return "working"
        case .setup: return "setup"
        case .update: return "update"
        case .repair: return "repair"
        case .stop: return "stop"
        case .play: return "play"
        case .playAnother: return "play-another"
        case .blocked: return "blocked"
        }
    }

    /// What exactly is set up or repaired, for `--next-action` and logs.
    var detail: String {
        switch self {
        case .working(let w, _): return w.rawValue
        case .setup(let n):
            switch n {
            case .install: return "install"
            case .wrapperDrive: return "wrapper-drive"
            case .dataDrive: return "data-drive"
            case .wine: return "wine"
            case .game(let partial): return partial ? "game-files" : "game"
            case .chooseFolder: return "choose-folder"
            case .gameWine: return "game-wine"
            case .localServer: return "local-server"
            }
        case .repair(let n):
            switch n {
            case .wine: return "wine"
            case .mount: return "mount"
            case .access: return "access"
            }
        default: return ""
        }
    }
}

struct PrimaryDecision: Equatable {
    var action: PrimaryAction
    var label: String
    var enabled: Bool
    /// One short line under the button, only when the game is not ready.
    var reason: String?
    /// Never bound to Return (Stop).
    var destructive: Bool = false
    var progress: Double? = nil
}

/// Everything `decide` looks at. Plain values only; defaults describe a ready, idle install.
struct PrimaryInputs {
    var world = "HorizonXI"
    var isLocal = false
    var canDownload = true          // the world has a download route (installKind != .none)
    var hostEmpty = false
    var allowsMultipleClients = false
    /// The world's loader window asks for (or creates) the account, so Play needs none typed.
    var accountInLoader = false

    var hasInstall = true
    var scanning = false
    /// No install found, but the remembered wrapper lives on this drive, which is missing.
    var rememberedDrive: String? = nil
    var checks: [Check] = []
    var checksPending = false
    var driveStates: [String: Preflight.DriveState] = [:]
    var hasGame = true
    var patchedWineMissing = false

    var restartingLauncher = false
    /// Setup's chain is running (it shows progress even between its jobs).
    var setupRunning = false
    var setupProgress: Double? = nil
    var ownJob: String? = nil
    var ownProgress: Double? = nil
    var otherJob: String? = nil
    var runningHere = false
    var starting = false
    var runningElsewhere = false
    var wineStuck = false

    var horizonInstalled: String? = nil
    var horizonLatest: String? = nil
    var updateDeferred = false
    var clientInstalled: String? = nil
    var clientRequired: String = ""
    var canUpdateClient = false     // HorizonXI (update script) or CatsEyeXI (their launcher)

    var localReady: Bool? = nil     // nil: still loading
    var localBelowFloor = false
    var localForce = false
    var accountNeeded = false
}

enum Primary {
    /// Checks Play fixes by itself on the way in (GameRegistry.point, Sandbox.repair): they
    /// must not grey PLAY, and say nothing.
    static let fixedByPlay: Set<String> = ["reg32", "reglayout", "com", "sandbox"]
    /// What only Repair fixes.
    static let fixedByRepair: Set<String> = ["rpath"]
    static let gameFiles: Set<String> = ["client", "squareenix", "ashita"]
    /// What Setup's chain repairs right after a download (install.sh): a fresh prefix has none
    /// of it, and Play would otherwise stop for it on the first launch.
    static let configuredAfterDownload: Set<String> = ["rpath", "reg32", "reglayout", "com"]

    /// Every label the button may show when nothing is running. The progress labels are
    /// `Work.label`, with " 42%" when the job reports how far it is.
    static let verbs: Set<String> = ["Setup", "Update", "Repair", "Play", "Stop", "Play Another"]

    /// The one line Setup ends with when the patched game Wine is missing: no download for it is
    /// pinned in this project yet (docs/BETA-60.md, "Game Wine").
    static let gameWineUnavailable = "The game's Wine can't be installed from here yet."

    static func decide(_ x: PrimaryInputs) -> PrimaryDecision {
        if x.restartingLauncher { return make(.working(.updating, progress: nil), x) }
        if x.setupRunning { return make(.working(.settingUp, progress: x.setupProgress), x) }
        if let job = x.ownJob { return make(.working(work(forJob: job), progress: x.ownProgress), x) }
        if x.starting { return make(.working(.starting, progress: nil), x) }
        if x.runningHere, !x.allowsMultipleClients { return make(.stop, x) }
        if x.runningElsewhere, !x.allowsMultipleClients {
            return make(.blocked("Already running from another launcher."), x)
        }
        if x.otherJob != nil { return make(.blocked("Waiting for another job to finish."), x) }

        guard x.hasInstall else {
            if x.scanning { return make(.working(.checking, progress: nil), x) }
            if let d = x.rememberedDrive { return make(driveAction(d, x.driveStates[d], wrapper: true), x) }
            return make(.setup(.install), x)
        }
        if x.checksPending { return make(.working(.checking, progress: nil), x) }

        let bad = x.checks.filter { $0.state == .bad }
        // A missing drive first: it is also why the game looks "not installed", and Repair can
        // do nothing about it (2026-10-15: Repair against a ghost-mounted 'Games' exited 3).
        if let c = bad.first(where: { $0.drive != nil }), let d = c.drive {
            return make(driveAction(d, x.driveStates[d], wrapper: c.id == "volume"), x)
        }
        if bad.contains(where: { $0.id == "fda" }) { return make(.repair(.access), x) }
        if bad.contains(where: { $0.id == "wine" }) { return make(.setup(.wine), x) }
        if !x.hasGame || bad.contains(where: { gameFiles.contains($0.id) }) {
            return make(x.canDownload ? .setup(.game(partial: x.hasGame)) : .setup(.chooseFolder), x)
        }
        if bad.contains(where: { $0.id == "worldclient" }) { return make(.setup(.chooseFolder), x) }
        if x.patchedWineMissing { return make(.setup(.gameWine), x) }
        if bad.contains(where: { fixedByRepair.contains($0.id) }) { return make(.repair(.wine), x) }
        if let other = bad.first(where: { !fixedByPlay.contains($0.id) }) {
            return make(.blocked(other.footer), x)
        }
        if x.isLocal {
            guard let ready = x.localReady else { return make(.working(.checking, progress: nil), x) }
            if !ready { return make(.setup(.localServer(enabled: !x.localBelowFloor || x.localForce)), x) }
        }
        if x.hostEmpty, !x.isLocal { return make(.blocked("This world has no login address."), x) }
        if !x.clientRequired.isEmpty, let have = x.clientInstalled,
           ClientVersion.isOlder(have, than: x.clientRequired) {
            return make(x.canUpdateClient
                        ? .update(world: x.world, to: x.clientRequired)
                        : .blocked("Needs client \(x.clientRequired); you have \(have)."), x)
        }
        if x.world == "HorizonXI", !x.updateDeferred, let have = x.horizonInstalled,
           let latest = x.horizonLatest, isNewer(latest, than: have) {
            return make(.update(world: x.world, to: latest), x)
        }
        // HorizonXI's loader cannot ask for the account (its console is never shown), so Play
        // without one would sit at a prompt nobody sees. Worlds whose loader window creates the
        // account need nothing typed.
        if x.accountNeeded, !x.isLocal, !x.accountInLoader {
            return make(.blocked("Type your account name and password above."), x)
        }
        if x.wineStuck { return make(.blocked("Wine is still closing from the last game."), x) }
        return make(x.runningHere || x.runningElsewhere ? .playAnother : .play, x)
    }

    /// What a running job is, from its busy reason ("Repairing", "Updating Wine",
    /// "Downloading", "Installing Eden", …).
    static func work(forJob reason: String) -> PrimaryAction.Work {
        let r = reason.lowercased()
        if r.hasPrefix("repair") { return .repairing }
        if r.hasPrefix("updat") { return .updating }
        if r.hasPrefix("start") { return .starting }
        if r.hasPrefix("stop") { return .stopping }
        if r.hasPrefix("check") || r.hasPrefix("look") { return .checking }
        return .settingUp
    }

    /// "2.0.5" > "2.0.4", numerically per part (same rule as Updater.isNewer, off the main actor).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for k in 0..<max(pa.count, pb.count) {
            let x = k < pa.count ? pa[k] : 0, y = k < pb.count ? pb[k] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A drive that is merely unmounted is one `diskutil mount` away (Repair). Ghost or
    /// unplugged is Setup: reconnect it, or press Setup and put the game somewhere else.
    static func driveAction(_ d: String, _ s: Preflight.DriveState?, wrapper: Bool) -> PrimaryAction {
        if case .unmounted(let dev)? = s { return .repair(.mount(drive: d, device: dev)) }
        return .setup(wrapper ? .wrapperDrive(d) : .dataDrive(d))
    }

    /// Label, enabled state and the one reason line for each action.
    static func make(_ a: PrimaryAction, _ x: PrimaryInputs) -> PrimaryDecision {
        let w = x.world
        switch a {
        case .working(let work, let p):
            let pct = p.map { " \(Int((min(max($0, 0), 1) * 100).rounded(.down)))%" } ?? ""
            return .init(action: a, label: work.label + pct, enabled: false, reason: nil, progress: p)
        case .setup(let need):
            switch need {
            case .install:
                return .init(action: a, label: "Setup", enabled: true, reason: "\(w) isn't installed yet.")
            case .wrapperDrive(let d), .dataDrive(let d):
                return .init(action: a, label: "Setup", enabled: true, reason: Preflight.driveLine(d, .absent))
            case .wine:
                return .init(action: a, label: "Setup", enabled: true, reason: "Wine isn't installed yet.")
            case .game(let partial):
                return .init(action: a, label: "Setup", enabled: true,
                             reason: partial ? "Some of \(w)'s files are missing." : "\(w) isn't installed yet.")
            case .chooseFolder:
                return .init(action: a, label: "Setup", enabled: true, reason: "Choose where \(w)'s game files are.")
            case .gameWine:
                return .init(action: a, label: "Setup", enabled: true, reason: "The game's Wine isn't installed yet.")
            case .localServer(let enabled):
                return .init(action: a, label: "Setup", enabled: enabled,
                             reason: enabled ? "The local server isn't set up yet."
                                             : "Not enough free space for the local server.")
            }
        case .update(let world, let to):
            return .init(action: a, label: "Update", enabled: true,
                         reason: world == "HorizonXI" ? "HorizonXI \(to) is available." : "\(world) needs a client update.")
        case .repair(let need):
            switch need {
            case .wine:
                return .init(action: a, label: "Repair", enabled: true, reason: "Wine needs a quick repair.")
            case .mount(let d, _):
                return .init(action: a, label: "Repair", enabled: true, reason: Preflight.driveLine(d, .unmounted(device: "")))
            case .access:
                return .init(action: a, label: "Repair", enabled: true, reason: "Allow FFXI on Mac in Full Disk Access.")
            }
        case .stop:
            return .init(action: a, label: "Stop", enabled: true, reason: nil, destructive: true)
        case .blocked(let why):
            return .init(action: a, label: "Play", enabled: false, reason: why)
        case .play:
            return .init(action: a, label: "Play", enabled: true, reason: nil)
        case .playAnother:
            return .init(action: a, label: "Play Another", enabled: true, reason: nil)
        }
    }

    // MARK: - Reading the state (off the main actor)

    struct Probe {
        var checks: [Check] = []
        var driveStates: [String: Preflight.DriveState] = [:]
        var hasGame = false
        var horizonInstalled: String?
        var clientInstalled: String?
        var patchedWineMissing = false
        var profileHasAccount = false
    }

    /// Everything the decision needs from disk. Read-only; may be slow on a sleeping drive.
    static func probe(_ i: Install, profile: String, horizon: Bool, requiredClient: String) -> Probe {
        var p = Probe()
        p.checks = Preflight.run(i, profile: profile)
        for d in Set(p.checks.filter { $0.state == .bad }.compactMap(\.drive)) {
            p.driveStates[d] = Preflight.driveState(d)
        }
        let driveMissing = !p.driveStates.isEmpty
        p.hasGame = i.hasGame
        if !driveMissing {
            p.horizonInstalled = horizon ? ClientVersion.horizonVersion(in: i) : nil
            p.clientInstalled = requiredClient.isEmpty ? nil : ClientVersion.installed(in: i)
            p.profileHasAccount = profileHasAccount(i, profile: profile)
        }
        p.patchedWineMissing = X87Sidecar.patchedWine() == nil
        return p
    }

    /// The boot profile's `command` line already carries `--user` (the launcher never
    /// rewrites it without an account typed in, so that one is used).
    static func profileHasAccount(_ i: Install, profile: String) -> Bool {
        let url = i.gameDir.appendingPathComponent("config/boot/\(profile)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { raw in
            let l = raw.trimmingCharacters(in: .whitespaces)
            return !l.hasPrefix(";") && l.hasPrefix("command") && l.range(of: #"--user\s+\S"#, options: .regularExpression) != nil
        }
    }

    /// The drive the remembered (but now unfindable) wrapper lives on, when that drive is gone.
    static func rememberedDrive() -> (String, Preflight.DriveState)? {
        guard let w = Install.rememberedWrapper(), let d = Preflight.unavailableDrive(for: w.path) else { return nil }
        return (d, Preflight.driveState(d))
    }
}

/// Performs the jobs that need no window. The button and `--fix` both come here; Setup's
/// steps that need a person (where things go, a sheet, a panel) are the window's
/// (ContentView.runSetup), and so is opening System Settings.
@MainActor enum PrimaryFixer {
    /// Actions `--fix` may run. Everything else needs a person (a location, a permission, a
    /// folder, an account) or would launch the game.
    static func isHeadlessFixable(_ a: PrimaryAction) -> Bool {
        switch a {
        case .repair(.wine), .repair(.mount), .update, .setup(.game): return true
        default: return false
        }
    }

    /// False when this is not a job it performs (the window handles the rest).
    @discardableResult
    static func perform(_ a: PrimaryAction, install i: Install, server s: Server, runner: Runner,
                        done: @escaping (Bool) -> Void) -> Bool {
        switch a {
        case .repair(.wine):
            runner.repair(i, done: done)
        case .setup(.game) where s.installKind == .horizonTorrent || s.local:
            // The local server plays HorizonXI's client: its download is HorizonXI's.
            runner.installHorizon(into: i.gameDir, done: done)
        case .update where s.name == "HorizonXI":
            runner.updateHorizon(i, done: done)
        case .repair(.mount(let d, let dev)):
            runner.appendLine("==> mounting '\(d)' (\(dev))")
            Task.detached {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                p.arguments = ["mount", dev]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                let ok: Bool
                if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 } else { ok = false }
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                await MainActor.run {
                    runner.logFileOnly(out)
                    if !ok { runner.appendLine("!! The '\(d)' drive wouldn't mount. Reconnect it, or press Setup to put the game somewhere else.") }
                    done(ok)
                }
            }
        default:
            return false
        }
        return true
    }

    /// Privacy & Security › Full Disk Access. Turning the app on there also covers Removable
    /// Volumes; macOS asks to quit and reopen the app afterwards.
    static let fullDiskAccessPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
