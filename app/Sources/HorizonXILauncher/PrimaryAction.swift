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
/// a world allows two clients; Force Stop once Wine has died under the running game, b70), or
/// what is running ("Setting up… 42%", "Stopping…"). Anything else the user needs to know is
/// the one short line under it.
///
/// Never a greyed-out PLAY (Daniel, 2026-10-15: "the user should never encounter a greyed out
/// play button"). A game that cannot start is an enabled Setup, Update or Repair whose click
/// starts the fix or opens the exact place it is made; a wait is a progress label ("Waiting…",
/// "Wine is closing…"). The one PLAY that does not start the game is the missing account on a
/// world whose loader cannot ask for it: still enabled, its click puts the cursor in the field.
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
    /// No account typed, and the world's loader cannot ask for one (HorizonXI). PLAY, enabled:
    /// the click puts the cursor in the account fields.
    case enterAccount
    /// Catalogued world whose Mac login is not implemented yet. Opens official setup info.
    case serverInfo

    enum Work: String {
        case settingUp, updating, repairing, checking, starting, stopping, moving
        /// Something the user did not start here: another world's job, a client another
        /// launcher started, Wine still closing after a Stop.
        case waiting, runningElsewhere, closing

        var label: String {
            switch self {
            case .settingUp: return "Setting up…"
            case .updating: return "Updating…"
            case .repairing: return "Repairing…"
            case .checking: return "Checking…"
            case .starting: return "Starting…"
            case .stopping: return "Stopping…"
            case .moving: return "Moving…"
            case .waiting: return "Waiting…"
            case .runningElsewhere: return "Running…"
            case .closing: return "Wine is closing…"
            }
        }

        /// The line under a wait the user did not start here; their own jobs need none.
        var reason: String? {
            switch self {
            case .waiting: return "Waiting for another job to finish."
            case .runningElsewhere: return "Already running from another launcher."
            default: return nil
            }
        }
    }

    enum SetupNeed: Equatable {
        /// No wrapper anywhere: Wine and the Windows drive come first.
        case install
        /// Rosetta 2 is not installed: no Wine here (all x86_64) can run. macOS's own
        /// administrator prompt installs it (Bootstrap.ensureRosetta).
        case rosetta
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
        /// The patched game Wine (wine-coop) is not on this Mac: Setup downloads it
        /// (scripts/game-wine.sh). See docs/WINE-BUILD.md.
        case gameWine
        /// An enabled world needs its own Windows environment before it can play alongside others.
        case multiServer
        /// The local world's server is not built yet. `lowSpace`: the disk is below its floor
        /// and "Set up anyway" is not ticked, so the click asks first.
        case localServer(lowSpace: Bool)
    }

    enum RepairNeed: Equatable {
        /// Wine's library links (the rpath check).
        case wine
        /// The drive is known to macOS but not mounted: `diskutil mount`, no admin.
        case mount(drive: String, device: String)
        /// macOS refuses this app the game's drive: Full Disk Access (or Removable Volumes).
        case access
        /// The world has no login address: the click opens its settings at the host field.
        case host
        /// Any other failing check: Repair (install.sh), with the checks shown.
        case check(id: String, line: String)
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
        case .enterAccount: return "account"
        case .serverInfo: return "server-info"
        }
    }

    /// What exactly is set up or repaired, for `--next-action` and logs.
    var detail: String {
        switch self {
        case .working(let w, _): return w.rawValue
        case .setup(let n):
            switch n {
            case .install: return "install"
            case .rosetta: return "rosetta"
            case .wrapperDrive: return "wrapper-drive"
            case .dataDrive: return "data-drive"
            case .wine: return "wine"
            case .game(let partial): return partial ? "game-files" : "game"
            case .chooseFolder: return "choose-folder"
            case .gameWine: return "game-wine"
            case .multiServer: return "multi-server"
            case .localServer: return "local-server"
            }
        case .repair(let n):
            switch n {
            case .wine: return "wine"
            case .mount: return "mount"
            case .access: return "access"
            case .host: return "host"
            case .check(let id, _): return "check-" + id
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
    var launchUnavailableReason: String? = nil
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
    var rosettaMissing = false
    var multiServerNeeded = false

    var restartingLauncher = false
    /// Setup's chain is running (it shows progress even between its jobs).
    var setupRunning = false
    var setupProgress: Double? = nil
    /// The step Setup's chain is on, named on the button instead of "Setting up".
    var setupStage: SetupStage? = nil
    var ownJob: String? = nil
    var ownProgress: Double? = nil
    var otherJob: String? = nil
    var runningHere = false
    var starting = false
    var runningElsewhere = false
    var wineStuck = false
    /// The selected world's session lost its Wine under the running client (b70,
    /// `Runner.serverLost`): Force Stop.
    var serverLost = false
    /// Its Stop is under way and the client not gone yet (b70, `Runner.stoppingGame`).
    var stopping = false
    /// When its GPU device was lost, "21:31:07" (b70, `Runner.renderStuckSince`): Stop, with
    /// the line under it.
    var renderStuckAt: String? = nil

    var horizonInstalled: String? = nil
    var horizonLatest: String? = nil
    var updateDeferred = false
    var clientInstalled: String? = nil
    var clientRequired: String = ""

    var localReady: Bool? = nil     // nil: still loading
    var localBelowFloor = false
    var localForce = false
    var accountNeeded = false
}

enum Primary {
    /// Checks Play fixes by itself on the way in (GameRegistry.point, Sandbox.repair,
    /// Credentials.prepareProfile): they
    /// must not grey PLAY, and say nothing.
    static let fixedByPlay: Set<String> = ["reg32", "reglayout", "com", "sandbox", "bootprofile"]
    /// What only Repair fixes.
    static let fixedByRepair: Set<String> = ["rpath"]
    static let gameFiles: Set<String> = ["client", "squareenix", "ashita"]
    /// What Setup's chain repairs right after a download (install.sh): a fresh prefix has none
    /// of it, and Play would otherwise stop for it on the first launch.
    static let configuredAfterDownload: Set<String> = ["rpath", "reg32", "reglayout", "com"]

    /// Every label the button may show when nothing is running. The progress labels are
    /// `Work.label`, with " 42%" when the job reports how far it is.
    static let verbs: Set<String> = ["Setup", "Update", "Repair", "Play", "Stop", "Force Stop", "Play Another", "Server Info", "Connect Phoenix (Beta)"]

    static func decide(_ x: PrimaryInputs) -> PrimaryDecision {
        if x.restartingLauncher { return make(.working(.updating, progress: nil), x) }
        if x.setupRunning { return make(.working(.settingUp, progress: x.setupProgress), x) }
        if let job = x.ownJob { return make(.working(work(forJob: job), progress: x.ownProgress), x) }
        // Stop pressed, the client not gone yet (b70): ahead of everything it would otherwise be.
        if x.runningHere, x.stopping { return make(.working(.stopping, progress: nil), x) }
        // Wine or the graphics gone under this world's client: its one way out, ahead of
        // "Starting…" and of Play Another (a second client would start beside the frozen one).
        if x.runningHere, x.serverLost || x.renderStuckAt != nil { return make(.stop, x) }
        if x.starting { return make(.working(.starting, progress: nil), x) }
        if x.runningHere, !x.allowsMultipleClients { return make(.stop, x) }
        if x.runningElsewhere, !x.allowsMultipleClients {
            return make(.working(.runningElsewhere, progress: nil), x)
        }
        if x.otherJob != nil { return make(.working(.waiting, progress: nil), x) }

        if x.launchUnavailableReason != nil { return make(.serverInfo, x) }

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
        // Setup's order from here: Rosetta, Wine, the game's Wine, the game, its configuration.
        if x.rosettaMissing { return make(.setup(.rosetta), x) }
        if bad.contains(where: { $0.id == "wine" }) { return make(.setup(.wine), x) }
        if x.patchedWineMissing { return make(.setup(.gameWine), x) }
        if x.multiServerNeeded { return make(.setup(.multiServer), x) }
        if !x.hasGame || bad.contains(where: { gameFiles.contains($0.id) }) {
            // Partial: Ashita or the base data is there, so this is a repair of the download, not
            // a first one.
            let partial = x.hasGame || !bad.contains(where: { $0.id == "squareenix" || $0.id == "client" })
            return make(x.canDownload ? .setup(.game(partial: partial)) : .setup(.chooseFolder), x)
        }
        if bad.contains(where: { $0.id == "worldclient" }) { return make(.setup(.chooseFolder), x) }
        if bad.contains(where: { fixedByRepair.contains($0.id) }) { return make(.repair(.wine), x) }
        if let other = bad.first(where: { !fixedByPlay.contains($0.id) }) {
            return make(.repair(.check(id: other.id, line: other.footer)), x)
        }
        if x.isLocal {
            guard let ready = x.localReady else { return make(.working(.checking, progress: nil), x) }
            if !ready { return make(.setup(.localServer(lowSpace: x.localBelowFloor && !x.localForce)), x) }
        }
        if x.hostEmpty, !x.isLocal { return make(.repair(.host), x) }
        // A world without an in-launcher updater still gets Update: its click opens that world's
        // own route (their installer, client zip or download page).
        if !x.clientRequired.isEmpty, let have = x.clientInstalled,
           ClientVersion.isOlder(have, than: x.clientRequired) {
            return make(.update(world: x.world, to: x.clientRequired), x)
        }
        if x.world == "HorizonXI", !x.updateDeferred, let have = x.horizonInstalled,
           let latest = x.horizonLatest, isNewer(latest, than: have) {
            return make(.update(world: x.world, to: latest), x)
        }
        // HorizonXI's loader cannot ask for the account (its console is never shown), so Play
        // without one would sit at a prompt nobody sees. Worlds whose loader window creates the
        // account need nothing typed.
        if x.wineStuck { return make(.working(.closing, progress: nil), x) }
        if x.accountNeeded, !x.isLocal, !x.accountInLoader { return make(.enterAccount, x) }
        return make(x.runningHere || x.runningElsewhere ? .playAnother : .play, x)
    }

    /// What a running job is, from its busy reason ("Repairing", "Updating Wine",
    /// "Downloading", "Installing Eden", "Moving", …).
    static func work(forJob reason: String) -> PrimaryAction.Work {
        let r = reason.lowercased()
        if r.hasPrefix("repair") { return .repairing }
        if r.hasPrefix("updat") { return .updating }
        if r.hasPrefix("start") { return .starting }
        if r.hasPrefix("stop") { return .stopping }
        if r.hasPrefix("mov") { return .moving }
        if r.hasPrefix("check") || r.hasPrefix("look") { return .checking }
        return .settingUp
    }

    /// The line under Stop once the game's GPU device is lost (b70): when, and what to press.
    static func renderStuckReason(_ time: String) -> String { "The game's graphics stopped at \(time) — press Stop." }

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
            // Under 1% says no figure at all: "Setting up… 0%" read as stuck (Daniel, 2026-10-15).
            let pct = p.flatMap { $0 >= 0.01 ? " \(Int((min($0, 1) * 100).rounded(.down)))%" : nil } ?? ""
            let name = work == .settingUp ? x.setupStage.map { $0.rawValue + "…" } ?? work.label : work.label
            return .init(action: a, label: name + pct, enabled: false, reason: work.reason, progress: p)
        case .setup(let need):
            switch need {
            case .install:
                return .init(action: a, label: "Setup", enabled: true, reason: "\(w) isn't installed yet.")
            case .rosetta:
                return .init(action: a, label: "Setup", enabled: true, reason: "Apple's Rosetta isn't installed yet.")
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
            case .multiServer:
                return .init(action: a, label: "Setup", enabled: true,
                             reason: "Set up multi-server play (about 1 GB extra).")
            case .localServer(let lowSpace):
                return .init(action: a, label: "Setup", enabled: true,
                             reason: lowSpace ? "Not enough free space for the local server."
                                              : "The local server isn't set up yet.")
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
            case .host:
                return .init(action: a, label: "Repair", enabled: true, reason: "This world has no login address.")
            case .check(_, let line):
                return .init(action: a, label: "Repair", enabled: true, reason: line)
            }
        case .stop:
            return .init(action: a, label: x.serverLost ? "Force Stop" : "Stop", enabled: true,
                         reason: x.serverLost ? nil : x.renderStuckAt.map(renderStuckReason), destructive: true)
        case .serverInfo:
            return .init(action: a, label: x.world == "Phoenix XI" ? "Connect Phoenix (Beta)" : "Server Info", enabled: true, reason: x.world == "Phoenix XI" ? "Sign in to verify Phoenix account access. Game setup and Play are still pending." : x.launchUnavailableReason)
        case .enterAccount:
            return .init(action: a, label: "Play", enabled: true, reason: "Type your account name and password above.")
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
        var rosettaMissing = false
        var multiServerNeeded = false
        var profileHasAccount = false
        /// The game's files are on (or link to) another drive than Wine, and every drive is there:
        /// the Setup line offers Move… (InstallMove.offered).
        var dataElsewhere = false
    }

    /// Everything the decision needs from disk. Read-only; may be slow on a sleeping drive.
    static func probe(_ i: Install, profile: String, horizon: Bool, requiredClient: String,
                      loader: String = "", template: String = "") -> Probe {
        var p = Probe()
        p.checks = Preflight.run(i, profile: profile, loader: loader, template: template)
        p.multiServerNeeded = !WorldPrefix.ready(i)
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
        p.rosettaMissing = Bootstrap.rosettaMissing()
        p.dataElsewhere = InstallMove.offered(i)
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
        case .repair(.wine), .repair(.check), .repair(.mount), .update, .setup(.game): return true
        default: return false
        }
    }

    /// False when this is not a job it performs (the window handles the rest).
    @discardableResult
    static func perform(_ a: PrimaryAction, install i: Install, server s: Server, runner: Runner,
                        done: @escaping (Bool) -> Void) -> Bool {
        switch a {
        case .repair(.wine), .repair(.check):
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
