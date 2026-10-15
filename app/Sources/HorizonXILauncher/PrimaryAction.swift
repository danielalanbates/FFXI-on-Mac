import Foundation
import AppKit

/// The big button under the account fields is always the next thing that has to happen, not
/// only PLAY. Daniel, 2026-10-15: a user sets up and repairs HorizonXI from the main window,
/// no menu digging. Before this the button said PLAY (grey) while the fix lived in the
/// collapsed Setup & Diagnostics panel -- and on 2026-10-15 the fix offered there (Repair) could
/// not work at all, because the 'Games' drive was ghost-mounted.
///
/// `Primary.decide` is pure: plain values in, one decision out, so `--selftest-primary-action`
/// and `--next-action` exercise exactly what the window shows. `PrimaryFixer` performs the
/// actions that need no window, for the button and for `--fix` alike.
enum PrimaryAction: Equatable {
    case working(String, progress: Double?)
    case checking
    case restartingLauncher
    case stop
    case runningElsewhere
    case restartMac(drive: String)
    case mountDrive(drive: String, device: String)
    case connectDrive(drive: String)
    case allowAccess
    case installWine
    /// The patched game Wine (wine-coop) is not on this Mac and no pinned download exists yet.
    case needGameWine
    case downloadGame(world: String)
    case chooseFolder(world: String)
    case repair
    case updateGame(world: String, to: String)
    case clientTooOld(have: String, need: String)
    case setUpLocalServer
    case enterAccount
    case wait(String)
    case blocked(String)
    case play
    case playAnother

    /// Stable name for `--next-action` output and scripts.
    var id: String {
        switch self {
        case .working: return "working"
        case .checking: return "checking"
        case .restartingLauncher: return "restarting-launcher"
        case .stop: return "stop"
        case .runningElsewhere: return "running-elsewhere"
        case .restartMac: return "restart-mac"
        case .mountDrive: return "mount-drive"
        case .connectDrive: return "connect-drive"
        case .allowAccess: return "allow-access"
        case .installWine: return "install-wine"
        case .needGameWine: return "need-game-wine"
        case .downloadGame: return "download-game"
        case .chooseFolder: return "choose-folder"
        case .repair: return "repair"
        case .updateGame: return "update-game"
        case .clientTooOld: return "client-too-old"
        case .setUpLocalServer: return "set-up-local-server"
        case .enterAccount: return "enter-account"
        case .wait: return "wait"
        case .blocked: return "blocked"
        case .play: return "play"
        case .playAnother: return "play-another"
        }
    }
}

struct PrimaryDecision: Equatable {
    var action: PrimaryAction
    var label: String
    var enabled: Bool
    /// One short line under the button, only when the game is not ready.
    var reason: String?
    /// Never bound to Return (Stop, Restart Mac).
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
    var accountNeeded = false
}

enum Primary {
    /// Checks Play fixes by itself on the way in (GameRegistry.point, Sandbox.repair): they
    /// must not grey PLAY.
    static let fixedByPlay: Set<String> = ["reg32", "reglayout", "com", "sandbox"]
    /// What only Repair fixes.
    static let fixedByRepair: Set<String> = ["rpath"]
    static let gameFiles: Set<String> = ["client", "squareenix", "ashita"]

    static func decide(_ x: PrimaryInputs) -> PrimaryDecision {
        if x.restartingLauncher { return make(.restartingLauncher, x) }
        if let job = x.ownJob { return make(.working(job, progress: x.ownProgress), x) }
        if x.starting { return make(.working("Starting", progress: nil), x) }
        if x.runningHere, !x.allowsMultipleClients { return make(.stop, x) }
        if x.runningElsewhere, !x.allowsMultipleClients { return make(.runningElsewhere, x) }
        if let other = x.otherJob { return make(.wait(other), x) }

        guard x.hasInstall else {
            if x.scanning { return make(.working("Looking for your install", progress: nil), x) }
            if let d = x.rememberedDrive { return make(driveAction(d, x.driveStates[d]), x) }
            return make(.installWine, x)
        }
        if x.checksPending { return make(.checking, x) }

        let bad = x.checks.filter { $0.state == .bad }
        if let d = bad.first(where: { $0.drive != nil })?.drive {
            return make(driveAction(d, x.driveStates[d]), x)
        }
        if bad.contains(where: { $0.id == "fda" }) { return make(.allowAccess, x) }
        if bad.contains(where: { $0.id == "wine" }) { return make(.installWine, x) }
        if !x.hasGame || bad.contains(where: { gameFiles.contains($0.id) }) {
            return make(x.canDownload ? .downloadGame(world: x.world) : .chooseFolder(world: x.world), x)
        }
        if bad.contains(where: { $0.id == "worldclient" }) { return make(.chooseFolder(world: x.world), x) }
        if bad.contains(where: { fixedByRepair.contains($0.id) }) { return make(.repair, x) }
        if let other = bad.first(where: { !fixedByPlay.contains($0.id) && $0.id != "volume" }) {
            return make(.blocked(other.footer), x)
        }
        if x.patchedWineMissing { return make(.needGameWine, x) }
        if x.hostEmpty, !x.isLocal { return make(.blocked("This world has no login address."), x) }
        if !x.clientRequired.isEmpty, let have = x.clientInstalled,
           ClientVersion.isOlder(have, than: x.clientRequired) {
            return make(x.canUpdateClient ? .updateGame(world: x.world, to: x.clientRequired)
                                          : .clientTooOld(have: have, need: x.clientRequired), x)
        }
        if x.world == "HorizonXI", !x.updateDeferred, let have = x.horizonInstalled,
           let latest = x.horizonLatest, isNewer(latest, than: have) {
            return make(.updateGame(world: x.world, to: latest), x)
        }
        if x.isLocal {
            guard let ready = x.localReady else { return make(.working("Checking the server", progress: nil), x) }
            if !ready { return make(.setUpLocalServer, x) }
        }
        if x.accountNeeded, !x.isLocal { return make(.enterAccount, x) }
        if x.wineStuck { return make(.wait("Wine is still closing."), x) }
        return make(x.runningHere || x.runningElsewhere ? .playAnother : .play, x)
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

    static func driveAction(_ d: String, _ s: Preflight.DriveState?) -> PrimaryAction {
        switch s {
        case .ghost?: return .restartMac(drive: d)
        case .unmounted(let dev)?: return .mountDrive(drive: d, device: dev)
        default: return .connectDrive(drive: d)
        }
    }

    /// Label, enabled state and the one reason line for each action.
    static func make(_ a: PrimaryAction, _ x: PrimaryInputs) -> PrimaryDecision {
        let w = x.world
        switch a {
        case .working(let r, let p):
            let pct = p.map { " \(Int(($0 * 100).rounded()))%" } ?? "…"
            return .init(action: a, label: r + pct, enabled: false, reason: nil, progress: p)
        case .checking:
            return .init(action: a, label: "Checking…", enabled: false, reason: nil)
        case .restartingLauncher:
            return .init(action: a, label: "Restarting…", enabled: false, reason: nil)
        case .stop:
            return .init(action: a, label: "Stop", enabled: true, reason: nil, destructive: true)
        case .runningElsewhere:
            return .init(action: a, label: "Running", enabled: false, reason: "Started from another launcher.")
        case .restartMac(let d):
            return .init(action: a, label: "Restart Mac", enabled: true,
                         reason: Preflight.driveLine(d, .ghost), destructive: true)
        case .mountDrive(let d, _):
            return .init(action: a, label: "Mount \(d)", enabled: true, reason: Preflight.driveLine(d, .unmounted(device: "")))
        case .connectDrive(let d):
            return .init(action: a, label: "Connect \(d)", enabled: false, reason: Preflight.driveLine(d, .absent))
        case .allowAccess:
            return .init(action: a, label: "Allow Access", enabled: true,
                         reason: "Turn on FFXI on Mac in Full Disk Access, then reopen.")
        case .installWine:
            return .init(action: a, label: "Install Wine", enabled: true, reason: "Wine isn't installed yet.")
        case .needGameWine:
            return .init(action: a, label: "Game Wine Needed", enabled: false,
                         reason: "The game's Wine isn't on this Mac yet.")
        case .downloadGame:
            return .init(action: a, label: "Download \(w)", enabled: true,
                         reason: w == "HorizonXI" ? "About 9.4 GB. Resumes if stopped." : "\(w) isn't installed yet.")
        case .chooseFolder:
            return .init(action: a, label: "Choose Game Folder", enabled: true, reason: "Pick \(w)'s game folder.")
        case .repair:
            return .init(action: a, label: "Repair", enabled: true, reason: "Wine needs a quick repair.")
        case .updateGame(_, let to):
            return .init(action: a, label: "Update \(w)", enabled: true, reason: "\(w) \(to) is out.")
        case .clientTooOld(let have, let need):
            return .init(action: a, label: "Update Needed", enabled: false, reason: "Needs client \(need); you have \(have).")
        case .setUpLocalServer:
            return .init(action: a, label: "Set Up Server", enabled: true, reason: "The local server isn't set up yet.")
        case .enterAccount:
            return .init(action: a, label: "Add Account", enabled: true, reason: "Enter your account name and password.")
        case .wait(let why):
            return .init(action: a, label: "Play", enabled: false, reason: why.hasSuffix(".") ? why : why + "…")
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
        return text.split(separator: "\n").contains { raw in
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

/// Performs the actions that need no window. The button and `--fix` both come here.
@MainActor enum PrimaryFixer {
    /// Actions `--fix` may run. Everything else needs a person (a restart, a permission, a
    /// folder, an account) or would launch the game.
    static func isHeadlessFixable(_ a: PrimaryAction) -> Bool {
        switch a {
        case .repair, .downloadGame, .updateGame, .mountDrive: return true
        default: return false
        }
    }

    /// False when this is not an action it performs (the window handles the rest).
    @discardableResult
    static func perform(_ a: PrimaryAction, install i: Install, server s: Server, runner: Runner,
                        done: @escaping (Bool) -> Void) -> Bool {
        switch a {
        case .repair:
            runner.repair(i, done: done)
        case .downloadGame where s.installKind == .horizonTorrent:
            runner.installHorizon(into: i.gameDir, done: done)
        case .updateGame where s.name == "HorizonXI":
            runner.updateHorizon(i, done: done)
        case .mountDrive(let d, let dev):
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
                    if !ok { runner.appendLine("!! The '\(d)' drive wouldn't mount. Try Disk Utility.") }
                    done(ok)
                }
            }
        default:
            return false
        }
        return true
    }

    /// The system's own restart, after one confirmation. Only offered when nothing is running.
    static func restartMac() {
        let a = NSAlert()
        a.messageText = "Restart your Mac?"
        a.informativeText = "macOS lost track of a drive. A restart brings it back."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Restart")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to restart"]
        try? p.run()
    }

    static let fullDiskAccessPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
