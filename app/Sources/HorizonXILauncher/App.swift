import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Quitting the launcher kills every download and install it started, because they are its child
/// processes. Silently, and with the UI reverting to its "nothing installed yet" state -- so the
/// only evidence a 6 GB download ever happened was the folder on disk. Ask first.
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    /// One launcher window (docs/MULTI_WORLD.md, One launcher): no window tabs, whose "+"
    /// would open a second one.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// #27: started by `open … --args` without being activated, the launcher could come up with
    /// no window at all -- and `--play` runs from the window, so nothing happened. A second
    /// `open -a` fixed it: that is a reopen event, which makes SwiftUI create the window. If no
    /// window is up a second after launch, send that same event to ourselves (SingleInstance
    /// keeps it from starting a second process). Also bring back a window whose saved frame is
    /// on a display that is no longer connected.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        watchSleep()
        DispatchQueue.main.async { Self.recenterOffscreenWindows() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !SingleInstance.terminating else { return }
            Self.recenterOffscreenWindows()
            if NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) { return }
            if Self.showMainWindow() { return }
            NSApp.activate(ignoringOtherApps: true)
            // Only from a bundle: under `swift run` there is no app to reopen.
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            let c = NSWorkspace.OpenConfiguration()
            c.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { _, _ in }
        }
    }

    private static func recenterOffscreenWindows() {
        for w in NSApp.windows where w.canBecomeMain
            && !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) {
            w.center()
        }
    }

    // MARK: - Stop from the Dock (b70)

    /// Stop without the launcher window. 2026-10-16: the game froze at character select when
    /// its drive dropped, its own window could not be closed, and Stop lived only in the
    /// launcher's window, behind the game. One item per session of this launcher that is
    /// playing ("Force Stop …" once its Wine is gone); nothing for a client another launcher
    /// started. No alert: choosing it from the menu is the decision, as in the RUNNING list. A
    /// Stop under way is a disabled "Stopping …".
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let items = Sessions.shared.stopItems
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let m = NSMenuItem(title: item.title, action: #selector(stopFromDock(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = item.session
            m.isEnabled = !item.stopping
            menu.addItem(m)
        }
        return menu
    }

    @MainActor @objc private func stopFromDock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Sessions.shared.stop(session: id)
    }

    // MARK: - Sleep, wake and unmount (b70)

    /// When the Mac went to sleep, for the wake line.
    private var sleptAt: Date?

    /// One line each in launcher.log when the Mac sleeps and wakes, and on waking the server
    /// check of every playing session at once (`Runner.checkServerNow`): 2026-10-16's freeze
    /// was blamed on the lid, and the log had nothing to say either way. Logging only: sleep is
    /// never held up or delayed, and no game is ever stopped for it. Also a line each when the
    /// displays go off and on with the Mac awake (nothing else is done then), and each unmount,
    /// here rather than in the window, so it is seen with the window closed.
    @MainActor private func watchSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(macWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(macDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(displaysDidSleep(_:)), name: NSWorkspace.screensDidSleepNotification,
                       object: nil)
        nc.addObserver(self, selector: #selector(displaysDidWake(_:)), name: NSWorkspace.screensDidWakeNotification,
                       object: nil)
        nc.addObserver(self, selector: #selector(volumeDidUnmount(_:)), name: NSWorkspace.didUnmountNotification,
                       object: nil)
    }

    /// The displays off and on with the Mac awake (a lid closed on AC): a line each, nothing else.
    @MainActor @objc private func displaysDidSleep(_ n: Notification) {
        Runner.appendToLogFile(Runner.displayLine(on: false, at: Date(), sessions: Sessions.shared.live.map(\.id)))
    }

    @MainActor @objc private func displaysDidWake(_ n: Notification) {
        Runner.appendToLogFile(Runner.displayLine(on: true, at: Date(), sessions: Sessions.shared.live.map(\.id)))
    }

    @MainActor @objc private func macWillSleep(_ n: Notification) {
        let now = Date()
        sleptAt = now
        Runner.appendToLogFile(Runner.sleepLine(at: now, sessions: Sessions.shared.live.map(\.id)))
    }

    @MainActor @objc private func macDidWake(_ n: Notification) {
        Runner.appendToLogFile(Runner.wakeLine(at: Date(), sleptAt: sleptAt))
        sleptAt = nil
        for s in Sessions.shared.live { s.runner.checkServerNow() }
    }

    /// The drive a playing session's Wine or prefix is on has gone; that client is frozen for
    /// good. Said once, Force Stop offered, nothing ended (`Sessions.volumeGone`).
    @MainActor @objc private func volumeDidUnmount(_ n: Notification) {
        guard let v = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        Sessions.shared.volumeGone(v.path, name: n.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String)
    }

    /// A Dock click with the window minimised or hidden shows that window rather than letting
    /// SwiftUI open a second one. Only with no window at all is one created.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !LauncherDelegate.showMainWindow()
    }

    /// Bring the existing launcher window to the front. False when there is none.
    @discardableResult
    static func showMainWindow() -> Bool {
        // A closed window SwiftUI has not let go of yet is not one to bring back.
        guard let w = NSApp.windows.first(where: {
            $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized || NSApp.isHidden)
        }) else { return false }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if w.isMiniaturized { w.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        SingleInstance.terminating = true
        SingleInstance.stopListening()
        // "Quit anyway": the jobs end here, with everything they started and their Wine
        // sessions, rather than running on with nobody to finish them (JobKill). Never a game:
        // it is detached, and no job runs Wine in a prefix a game is using.
        JobKill.endAll()
    }

    /// Names the work in flight (the start-up Wine update is not a download); the resume hint
    /// only where it is true.
    static func quitQuestion(_ reason: String?) -> (message: String, info: String?) {
        let what = reason ?? "Downloading"
        let resumable = what.hasPrefix("Downloading") || what.hasPrefix("Installing")
        return ("Quit while " + what.prefix(1).lowercased() + what.dropFirst() + "?",
                resumable ? "Press Download again later and it picks up where it left off." : nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // No more handed-over requests from here on: one taken now would never be acted on.
        SingleInstance.terminating = true
        guard Runner.workInFlight || LocalServer.workInFlight else { return .terminateNow }
        let a = NSAlert()
        let q = Self.quitQuestion(Runner.workInFlightReason ?? LocalServer.workInFlightReason)
        a.messageText = q.message
        if let info = q.info { a.informativeText = info }
        a.addButton(withTitle: "Quit anyway")
        a.addButton(withTitle: "Keep running")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { return .terminateNow }
        SingleInstance.terminating = false
        return .terminateCancel
    }
}

@main
struct HorizonXILauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherDelegate.self) private var delegate
    init() {
        // Before anything can spawn a child: a key in the environment is kept in memory only.
        RetroAchievements.adoptEnvironmentKey()
        Headless.runIfAsked()
        // Before any window, scan or file: a second launch hands its --world/--play to the
        // running launcher and exits here. See SingleInstance.
        SingleInstance.enforce()
    }

    var body: some Scene {
        WindowGroup("FFXI on Mac") {
            ContentView()
                .frame(minWidth: 940, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // One launcher window: File > New Window would open a second ContentView with
            // sessions of its own. This shows the one there is instead.
            CommandGroup(replacing: .newItem) {
                Button("Show Launcher Window") { LauncherDelegate.showMainWindow() }
                    .keyboardShortcut("n")
            }
            GameCommands()
        }
    }
}

/// The Game menu (b70): the Dock menu's Stop items, from the menu bar while the launcher is in
/// front. No keyboard shortcut: Stop is never one key away (see `playButton`).
struct GameCommands: Commands {
    /// The process's sessions, so the menu works with the launcher window closed too.
    @ObservedObject private var sessions = Sessions.shared

    var body: some Commands {
        CommandMenu("Game") {
            let items = sessions.stopItems
            if items.isEmpty {
                Button("Stop") {}.disabled(true)
            } else {
                ForEach(items, id: \.session) { item in
                    Button(item.title) { sessions.stop(session: item.session) }
                        .disabled(item.stopping)
                }
            }
        }
    }
}

// MARK: - Palette
//
// Vana'diel by way of the crystal: deep indigo night, crystal cyan, and the warm gold the game
// uses for every selected menu item. Deliberately not macOS-grey — this is a game launcher.

enum Vana {
    static let night     = Color(red: 0.05, green: 0.05, blue: 0.12)
    static let indigo    = Color(red: 0.11, green: 0.10, blue: 0.26)
    static let violet    = Color(red: 0.20, green: 0.14, blue: 0.36)
    static let crystal   = Color(red: 0.55, green: 0.83, blue: 0.95)
    static let crystalDim = Color(red: 0.33, green: 0.55, blue: 0.70)
    static let gold      = Color(red: 0.93, green: 0.79, blue: 0.44)
    static let goldDim   = Color(red: 0.66, green: 0.55, blue: 0.29)
    static let ember     = Color(red: 0.90, green: 0.45, blue: 0.35)
    static let panel     = Color(red: 0.08, green: 0.08, blue: 0.17).opacity(0.85)
    static let stroke    = Color.white.opacity(0.14)
    static let text      = Color(red: 0.94, green: 0.95, blue: 0.99)
    static let muted     = Color(red: 0.64, green: 0.68, blue: 0.80)

    /// The blue-violet wash behind everything, with a crystal glow up top.
    static var backdrop: some View {
        ZStack {
            LinearGradient(colors: [violet, indigo, night],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [crystal.opacity(0.22), .clear],
                           center: .init(x: 0.22, y: 0.08), startRadius: 8, endRadius: 460)
            RadialGradient(colors: [gold.opacity(0.10), .clear],
                           center: .init(x: 0.85, y: 0.95), startRadius: 8, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

struct ContentView: View {
    @AppStorage(Guide.autoOpenKey) private var guideWithPlay = false
    /// Every install the last scan found, the one in use included: what DXVK's cache is seeded from.
    @State private var installs: [Install] = []
    /// The install in use: `install.last`, nil while it is not on disk (InstallSelection).
    @State private var selected: Install?
    /// The wrapper/prefix in `selected`, pointed at the chosen world's game folder.
    private var active: Install? {
        guard let i = selected else { return nil }
        return i.forServer(store.selected ?? Server.builtins[0])
    }
    @State private var checks: [Check] = []
    @State private var perf = PerfSettings.load()
    /// One for the whole process (see Sessions.shared): closing this window leaves every
    /// session, its Stop and its watch loop running.
    @ObservedObject private var sessions = Sessions.shared
    /// The selected world's session: what Play, Stop and the log pane act on.
    private var runner: Runner { sessions.runner(for: store.selectedID) }

    @StateObject private var store = ServerStore()
    @StateObject private var local = LocalServer()
    @StateObject private var feeds = ServerFeeds()
    /// One for the whole process (see Updater.shared), not one per window.
    @ObservedObject private var updater = Updater.shared
    @StateObject private var ra = RAProgress()
    /// One timer for the life of the view: built inline in `body`, which re-evaluates on every
    /// runner change, a timer was a new publisher each time and game output could keep
    /// restarting it (seen as a banner frozen for 28 s).
    private let populationTick = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    /// Clients started by another launcher. Every 15 s, and only while the window can be seen:
    /// each refresh is a whole-Mac `ps`, CPU taken from a running game on an 8 GB M1.
    private let elsewhereTick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    /// The world's news feed, every 15 minutes while the window can be seen (one small GET).
    private let newsTick = Timer.publish(every: 900, on: .main, in: .common).autoconnect()
    @State private var worldHover = false
    /// The account and local-server cards' own height, measured: what they keep beside the news.
    @State private var cardsHeight: CGFloat?
    @State private var forceSetup = false
    @State private var newServer = false
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newProfile = ""

    @State private var user = Credentials.username
    @State private var pass = ""
    @State private var remember = Credentials.remember
    @State private var showDetails = false
    /// Where the main button sends the cursor: the account fields (no account typed) or the
    /// world's login host in Setup & Diagnostics (no login address).
    enum Field: Hashable { case account, password, host }
    @FocusState private var focus: Field?
    @State private var showGraphics = false
    @State private var graphics = GraphicsSettings.load(world: nil)
    @State private var showAddons = false
    @State private var addonItems: [AddonSuite.Item] = []
    @State private var hiddenAddonCount = 0
    @State private var installingExtra = ""
    @State private var addonWarning = ""
    /// The Addons… sheet is open and its scan has not come back yet (spinner, Apply disabled).
    @State private var addonsScanning = false
    /// Bumped by every scan the sheet starts: a result for an older one is dropped.
    @State private var addonScanGeneration = 0
    @State private var notice = ""
    /// What about the Mac slows the game just started (PlayCheck), one line each. Shown only while
    /// true: cleared when that game exits, on a world change, and when Low Power Mode or the heat
    /// ends; memory stays until the game exits (re-measuring it is a scan, not a property read).
    @State private var playWarnings: [String] = []
    /// Play was pressed on a hosted world while the local server runs: one line and a button.
    @State private var localServerSlowing = false
    /// Bumped by every recheck, so a slow Preflight (a world on a spinning or missing drive)
    /// that finishes after a newer one cannot put the previous world's verdict on screen.
    @State private var checksGeneration = 0
    /// When switching back to the launcher last re-ran the checks; see `.didBecomeActive`.
    @State private var lastActivationRecheck = Date.distantPast
    /// Preflights still running, and whether an automatic recheck arrived meanwhile. A hung
    /// drive can stall Preflight; mount/activation rechecks then wait for it instead of piling up.
    @State private var checksInFlight = 0
    @State private var recheckPending = false
    /// One update attempt per Play press chain; a second Play retries.
    @State private var updateChecked = false
    @State private var scanning = false
    /// The start-up task has handled this launch's own --world/--play; handed-over requests
    /// may run from now on. See `runForwarded`.
    @State private var commandsReady = false
    @State private var forwardRunning = false
    @State private var showSetup = false
    /// The installed HorizonXI client's version (version.json on the game drive), read off the
    /// main actor in `recheckAsync`, never in `body`.
    @State private var horizonInstalled: String?
    /// The rest of what the main button looks at, read off the main actor with the checks.
    @State private var probe = Primary.Probe()
    /// Which world `checks` belong to; anything else shows "Checking…" rather than a stale verdict.
    @State private var checksWorld: String?
    /// No install found, and the remembered one sits on this missing drive.
    @State private var rememberedDrive: (name: String, state: Preflight.DriveState)?
    /// A HorizonXI update failed or was stopped: Play this session anyway (its login server
    /// accepts a client one version behind).
    @State private var updateDeferred = false
    /// Setup's chain (runSetup) is running, and how far, for the button: the whole chain as one
    /// figure that only rises (SetupMeter), the step it is on, and the setup sheet's own step.
    @State private var setupRunning = false
    @State private var preparingMultiServer = false
    final class MeterBox { var meter = SetupMeter() }
    @State private var setupMeter = MeterBox()
    @State private var setupAt: SetupMeter.Step?
    @State private var bootstrapStep: Bootstrap.Step?
    /// The chain waits on the setup sheet through this.
    @State private var setupSheetWaiter = SheetWaiter()
    /// Worlds whose download page Setup opened this session: the next press runs the installer.
    @State private var websiteOpened: Set<String> = []
    /// Move… is measuring what it would copy (the button says "Checking…").
    @State private var moveChecking = false
    /// Where a new install's macros and settings may come from (CarryOver): HorizonXI's client in
    /// the install in use and in every install found, as they were when Setup was pressed, and a
    /// client found in the chosen folder that the user chose not to use.
    @State private var carryHints: [URL] = []
    /// A carry-over is copying; Play waits for it.
    @State private var carryingOver = false
    /// Create account (LoginAccount): running, and its one line of result, for the world it was for.
    @State private var creatingAccount = false
    @State private var accountResult: (world: String, ok: Bool, text: String)? = nil
    /// Play already said once that a pending carry-over could not run: the next press plays
    /// anyway, so a process that never ends can't hold Play up for good.
    @State private var carryOverWarned = false
    private var fdaBlocked: Bool { checks.contains(where: { $0.id == "fda" && $0.state == .bad }) }

    /// The drive the selected world's files are on (or link to), when it is not there.
    private var missingDrive: String? { checks.first { $0.state == .bad && $0.drive != nil }?.drive }

    /// The main button: the next thing that has to happen. See PrimaryAction.swift.
    private var primary: PrimaryDecision { Primary.decide(primaryInputs) }

    private var primaryInputs: PrimaryInputs {
        var x = PrimaryInputs()
        let s = store.selected
        x.world = s?.name ?? "The game"
        x.isLocal = s?.local == true
        x.launchUnavailableReason = s?.launchUnavailableReason
        x.canDownload = x.isLocal || (s?.installKind ?? Server.InstallKind.none) != .none
        x.hostEmpty = s.map { !$0.local && $0.host.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        x.allowsMultipleClients = s?.allowsMultipleClients == true
        x.accountInLoader = s.map { $0.accountURL.isEmpty && $0.accountHow.contains("loader window") } == true
        x.hasInstall = selected != nil
        x.scanning = scanning
        if let r = rememberedDrive { x.rememberedDrive = r.name; x.driveStates[r.name] = r.state }
        x.checks = checks
        x.checksPending = selected != nil && checksWorld != s?.name
        x.driveStates.merge(probe.driveStates) { $1 }
        x.hasGame = probe.hasGame
        x.patchedWineMissing = probe.patchedWineMissing
        x.rosettaMissing = probe.rosettaMissing
        x.multiServerNeeded = probe.multiServerNeeded
        x.restartingLauncher = updateInstalling
        x.setupRunning = setupRunning
        if setupRunning {
            x.setupProgress = setupMeter.meter.overall(setupLive)
            x.setupStage = setupStage
        }
        if runner.busy { x.ownJob = runner.busyReason.isEmpty ? "Working" : runner.busyReason }
        else if x.isLocal, local.busy { x.ownJob = local.activity.isEmpty ? "setting up" : local.activity }
        else if moveChecking { x.ownJob = "Checking" }
        x.ownProgress = runner.updatingHorizon ? runner.updateProgress : runner.moveProgress ?? runner.ascensionProgress
        if !runner.busy, Runner.workInFlight { x.otherJob = Runner.workInFlightReason ?? "Another job is running" }
        x.runningHere = runner.running
        x.serverLost = runner.serverLost
        x.stopping = runner.stoppingGame
        x.renderStuckAt = runner.renderStuckSince.map(Runner.timeOfDay)
        x.starting = runner.starting
        x.runningElsewhere = s.map { sessions.runningElsewhere(world: $0.name, host: $0.host) } == true
        x.wineStuck = WineserverStopWait.anyStuck && sessions.live.isEmpty
        x.horizonInstalled = horizonInstalled
        x.horizonLatest = feeds.horizonLatest
        x.updateDeferred = updateDeferred
        x.clientRequired = s.map { feeds.requiredClients[$0.name] ?? $0.requiredClient } ?? ""
        x.clientInstalled = probe.clientInstalled
        x.localReady = x.isLocal ? local.status?.ready : nil
        x.localBelowFloor = local.status?.belowFloor == true
        x.localForce = forceSetup
        // An account typed without its password is not applied to the boot profile (launchClient).
        x.accountNeeded = (user.trimmingCharacters(in: .whitespaces).isEmpty || pass.isEmpty) && !probe.profileHasAccount
        return x
    }

    /// A notice that is not an error clears itself; errors stay until the next Play.
    private func info(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if notice == text { notice = "" }
        }
    }

    var body: some View {
        ZStack {
            Vana.backdrop
            HStack(spacing: 0) {
                hero
                Rectangle().fill(Vana.stroke).frame(width: 1)
                sidebar.frame(width: 372)
            }
        }
        // The window opens with no field focused when an account name is remembered, and with
        // the empty account field focused when there is none; never with text selected for a
        // stray keystroke to replace (2026-10-15: the remembered name became "de"). See OpenFocus.
        .background(OpenFocusAnchor {
            if focus == nil, OpenFocus.focusAccount(accountName: user, fieldsDisabled: store.selected?.local == true) {
                focus = .account
            }
        }.frame(width: 0, height: 0))
        .onAppear {
            // Server-Safe's Server list is this launcher's list.
            Guide.shareSession(worlds: orderedServers.map(\.name))
            // What builds up to b63 stored for the graphics panel, in Ashita's keys (b64).
            for line in GraphicsSettings.migrateStored() { runner.logFileOnly("==> " + line) }
            if store.selected?.local == true { local.refresh() }
            // Off the main actor so credential-file access and possible external-volume reads
            // cannot delay the first window.
            if let name = store.selected?.name, store.selected?.local != true {
                user = Credentials.username(forWorld: name)
            }
            guard remember, !user.isEmpty else { return }
            let account = user
            let install = selected
            let profile = store.selected?.bootProfile ?? "horizonxi.ini"
            let worldName = store.selected?.name ?? ""
            Task.detached(priority: .userInitiated) {
                if let i = install {
                    Credentials.adoptPasswordFromProfile(user: account, world: worldName,
                                                         install: i, profile: profile)
                }
                let found = Credentials.password(for: account, world: worldName)
                await MainActor.run { pass = found }
            }
        }
        .onChange(of: store.selectedID) { _ in
            // The page's population line: a world without a counter shows its Discord's.
            Task { await feeds.refreshDiscord(for: store.selected) }
            // Notices and play-time lines belong to the world they were said about.
            notice = ""
            playWarnings = []
            localServerSlowing = false
            if store.selected?.local == true { local.refresh() }
            // Recall the account last used on this world — accounts are per server, so the
            // HorizonXI login is wrong the moment CatsEye (or any other world) is picked.
            if let name = store.selected?.name, store.selected?.local != true {
                user = Credentials.username(forWorld: name)
                pass = remember ? Credentials.password(for: user, world: name) : ""
            }
            // The preflight checks are per world now (each has its own game folder): CatsEye's
            // "no client" verdict must not keep Play grey after switching back to HorizonXI.
            recheck()
            // A world picked while Addons… is open (a forwarded --world): the sheet lists the new
            // world's addons, never the old one's, which Apply would write into the new world.
            rescanAddons()
        }
        // Every job ends with fresh checks: a Download, Repair or Update that finished must turn
        // the button into the next step (or PLAY) without anyone pressing ↻.
        .onChange(of: runner.busy) { busy in if !busy { recheck() } }
        .onChange(of: local.busy) { busy in if !busy { recheck() } }
        // A session started, stopped or exited (any world's): look again at what runs
        // elsewhere at once, rather than on the next tick.
        .onChange(of: sessions.live.map(\.id)) { _ in Task { await refreshElsewhere() } }
        // The selected world's game has exited: what was said about it is over.
        .onChange(of: runner.running) { running in
            guard !running else { return }
            playWarnings = []
            localServerSlowing = false
        }
        .onChange(of: local.status?.running) { running in
            if running == false { localServerSlowing = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                    .receive(on: DispatchQueue.main)) { _ in prunePlayWarnings() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                    .receive(on: DispatchQueue.main)) { _ in prunePlayWarnings() }
        // A drive coming back (or going) changes the checks; "reconnect it" must not stay on
        // screen, PLAY grey, until somebody thinks of ↻.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
                    .receive(on: DispatchQueue.main)) { _ in autoRecheck() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
                    .receive(on: DispatchQueue.main)) { _ in autoRecheck() }
        // Coming back to the launcher, too, at most every 5 s and never while a game is starting
        // (Preflight reads the game drive, which the starting client is busy with).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // What runs elsewhere, every time: a "Running…" left from a game that has since
            // ended must not wait for the next tick (one `ps`).
            Task { await refreshElsewhere() }
            guard !launchUnderWay, Date().timeIntervalSince(lastActivationRecheck) >= 5 else { return }
            lastActivationRecheck = Date()
            autoRecheck()
        }
        // News: the cached copy at once, then the feed, then every 15 minutes while visible.
        // Its own task, so it does not wait for the volume scan below.
        .task {
            await feeds.loadCachedNews(servers: store.servers)
            await feeds.refreshNews(servers: store.servers, minInterval: 0)
        }
        .onReceive(newsTick) { _ in
            guard NSApplication.shared.occlusionState.contains(.visible) else { return }
            Task { await feeds.refreshNews(servers: store.servers, minInterval: 600) }
        }
        // Keep the players-online line current: on launch, whenever the world changes, and
        // every two minutes while the window is open. The fetch is three tiny GETs and silent
        // on failure, so this costs nothing when offline.
        .task { await feeds.refreshPopulations(); await feeds.refreshDiscord(for: store.selected) }
        .onReceive(populationTick) { _ in
            Task { await feeds.refreshPopulations(); await feeds.refreshDiscord(for: store.selected) }
            // RetroAchievements: gated to once per 10 minutes inside; a no-op until set up.
            ra.refresh(.automatic, gameDir: active?.gameDir, log: { runner.appendLine($0) })
        }
        // A later launch's --world/--play, handed over by SingleInstance.
        .onReceive(NotificationCenter.default.publisher(for: SingleInstance.arrived)) { _ in
            guard commandsReady else { return }   // the start-up task takes them in turn
            Task { await runForwarded() }
        }
        // Clients started by another launcher are only visible to a process scan. One `ps`.
        .task { await refreshElsewhere() }
        .onReceive(elsewhereTick) { _ in
            guard NSApplication.shared.occlusionState.contains(.visible) else { return }
            Task { await refreshElsewhere() }
        }
        // And at once when the window comes back into view, so the list is never 15 s stale.
        // News too, when it was last asked for more than 15 minutes ago.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeOcclusionStateNotification)) { _ in
            guard NSApplication.shared.occlusionState.contains(.visible) else { return }
            Task { await refreshElsewhere() }
            Task { await feeds.refreshNews(servers: store.servers, minInterval: 900) }
        }
        // Discovery walks /Volumes, and an external drive can make that take tens of seconds.
        // Doing it on the main thread means the window never appears at all — which looked
        // exactly like the app failing to launch. Scan off the main actor and fill the UI in.
        .task {
            // `--play` used to wait for the full volume scan below. After the game data moved
            // to the x10 (2.4 TB, spinning), that scan can run for many minutes, and the
            // launcher sat with no window and no log line — "it says it's running but it's
            // not". The remembered install is enough to play with, and the scan never changes it
            // (InstallSelection). So: fast path first, Play immediately, full scan afterwards.
            if selected == nil, let remembered = Install.remembered() {
                selected = remembered
                installs = [remembered]
                // A game the previous launcher left running is this one's before any --play
                // (Leftovers): Play then sees it as this window's, not a stranger's.
                await refreshElsewhere()
                // A forwarded --play must not reach Wine before its prefix is current.
                // This normally returns immediately; a stale prefix is updated once
                // under Runner's maintenance lock before commands are consumed.
                await runner.syncPrefixIfStale(remembered)
            }
            // Press Play as soon as the install is known. For Shortcuts/Stream Deck users, and
            // for this project's own unattended tests (see docs/SERVERS-WORKLOG.md).
            // Once per process: a window opened later (Dock reopen) must not play it again.
            if let own = SingleInstance.takeOwnCommand() { await handleCommand(own, forwarded: false) }
            // Then whatever other launches handed over while this one was starting.
            commandsReady = true
            await runForwarded()
            await refreshAsync()
            // Pick up each server's own published addon list, so the app's compiled-in snapshot
            // does not go stale between releases. Silent on failure -- offline must still launch.
            await feeds.refreshAsync(servers: store.servers)
            // Check GitHub Releases and, if there is a newer build, download it silently. The
            // update is only *applied* when the user presses Restart (updateBanner).
            updater.start()
        }
    }

    // MARK: - Left: title, server, status

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text((store.selected?.name ?? "FINAL FANTASY XI").uppercased())
                    .font(.system(size: 46, weight: .light, design: .serif))
                    .tracking(10)
                    .foregroundStyle(
                        LinearGradient(colors: [Vana.text, Vana.crystal],
                                       startPoint: .top, endPoint: .bottom))
                    .shadow(color: Vana.crystal.opacity(0.35), radius: 12, y: 2)
                multiServerControl
                Text("FINAL FANTASY XI ON APPLE SILICON")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(3.5)
                    .foregroundStyle(Vana.gold)
                updateBanner
                populationLine
            }
            .padding(.horizontal, 34).padding(.top, 34).padding(.bottom, 20)

            // The world's own news (ServerFeeds.news): only when it publishes a feed and there
            // are posts. It takes what the cards and the details below leave, up to its cap, and
            // gives way (to its minimum) before they do: "Getting an account" is what a new
            // player needs, and in a 600pt window a panel sized first left it 30pt.
            if let items = newsItems, let s = store.selected {
                NewsPanel(items: items, pageTemplate: s.newsPageURL)
                    .frame(maxWidth: 500, alignment: .leading)
                    .padding(.horizontal, 34).padding(.top, -8).padding(.bottom, 4)
                    .layoutPriority(1)
            }

            // Scrolled rather than clipped: the cards below already overflow a 632pt window once
            // the signup list is open, and an overflowing VStack pushes the game's title off the
            // top of the window instead of cutting the bottom off. Beside the news, held to their
            // own height and laid out first, so the panel is what shrinks.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    accountCard
                    localServerCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: CardsHeightKey.self, value: g.size.height)
                })
            }
            .onPreferenceChange(CardsHeightKey.self) { cardsHeight = $0 }
            .scrollIndicators(.hidden)
            .frame(maxHeight: newsItems != nil ? (cardsHeight ?? .infinity) : .infinity)
            .layoutPriority(newsItems != nil ? 2 : 0)
            Spacer(minLength: 0)

            if showDetails {
                ScrollView { statusList.padding(.horizontal, 34) }
                    .frame(maxHeight: 200)
                    .layoutPriority(newsItems != nil ? 2 : 0)
            }
            logStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A separate Windows environment is optional: selecting this alone downloads nothing.
    /// Setup is the explicit action that creates it, after the extra space is shown here.
    private var multiServerControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Toggle("Enable multi-server play", isOn: Binding(
                    get: { store.selected?.multiServerPlay == true },
                    set: { setMultiServerPlay($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Vana.text)
                    .disabled(store.selected == nil || multiServerToggleBlocked)
                    .help("Allows this world to play alongside other worlds. Server client and account limits still apply. Changing this never closes a game; unchecking keeps its extra files for reuse.")
                if preparingMultiServer { ProgressView().controlSize(.small) }
            }
            if store.selected?.multiServerPlay == true {
                Text("About 1 GB extra per server on \(selected?.volume?.lastPathComponent == "/" ? "this Mac" : selected?.volume?.lastPathComponent ?? "the Wine drive"). Existing game files are reused.")
                    .font(.system(size: 11)).foregroundStyle(Vana.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var multiServerToggleBlocked: Bool {
        guard let s = store.selected else { return true }
        return setupRunning || preparingMultiServer || Runner.workInFlight || LocalServer.workInFlight
            || launchUnderWay || sessions.live.contains { $0.world == s.name }
            || sessions.runningElsewhere(world: s.name, host: s.host)
            || sessions.elsewhere.keys.contains("")
    }

    /// The launch lock makes the final process check and setting change one operation. A launch
    /// that has not yet appeared in `ps` holds that same lock, so it cannot be missed here.
    private func setMultiServerPlay(_ enabled: Bool) {
        guard var s = store.selected, s.multiServerPlay != enabled else { return }
        guard !multiServerToggleBlocked else {
            notice = "Wait for this world's game and any setup work to finish before changing multi-server play."
            return
        }
        guard let lock = LaunchLock.acquire() else {
            notice = "A game is starting or setup is running. Try changing multi-server play again when it finishes."
            return
        }
        defer { LaunchLock.release(lock) }
        let hosts = Set(([s.host] + [active.flatMap { Credentials.bootServer(in: $0, profile: s.bootProfile) }]
            .compactMap { $0 }).map(LiveClients.normalize).filter { !$0.isEmpty })
        let live = LiveClients.snapshot().clients
        guard !live.contains(where: { $0.host.isEmpty || hosts.contains(LiveClients.normalize($0.host)) }) else {
            notice = "This world or an unidentified Wine client is running. Finish it before changing multi-server play."
            return
        }
        s.multiServerPlay = enabled
        store.update(s)
        notice = ""
        checksGeneration += 1
        checksWorld = nil
        probe = Primary.Probe()
        Task {
            await refreshElsewhere()
            await recheckAsync()
        }
    }

    /// The selected world's posts, when it publishes a feed and has any: the news panel's rows.
    private var newsItems: [NewsItem]? {
        guard let s = store.selected, !s.newsURL.isEmpty, let items = feeds.news[s.name], !items.isEmpty else { return nil }
        return items
    }

    private var orderedServers: [Server] { store.ordered(populations: feeds.populations) }

    /// Worlds by online population, with dated estimates offline and the local world last.
    private var serverPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WORLD").font(.system(size: 12)).tracking(2.5).foregroundStyle(Vana.gold)
                Spacer()
                if store.selected?.verified == true {
                    Label("verified", systemImage: "checkmark.seal.fill")
                        .labelStyle(.iconOnly).font(.system(size: 12))
                        .foregroundStyle(Vana.crystal)
                        .help("This project logs into this server successfully.")
                } else {
                    Image(systemName: "questionmark.circle").font(.system(size: 12))
                        .foregroundStyle(Vana.muted)
                        .help("This project has not logged into this server itself yet.")
                }
            }

            // `.borderlessButton` renders a custom Menu label as bare text (no pill, no border,
            // no hover), which is why the world name never looked clickable. A plain-styled
            // button menu draws the label exactly as declared.
            Menu {
                ForEach(orderedServers) { s in
                    Button { store.select(s) } label: {
                        if s.era.isEmpty { Text(s.name) }
                        else { Text("\(s.name)  ·  \(s.era)") }
                    }
                }
                Divider()
                Button("Add a server…") { newServer = true }
            } label: {
                worldRow
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            // b60: no login host, missing game data and the rest are the main button's reason
            // line now (PrimaryAction); nothing about them sits up here any more.
        }
        .sheet(isPresented: $newServer) { addServerSheet }
        .sheet(isPresented: $showGraphics) { graphicsSheet }
        .sheet(isPresented: $showAddons) { addonsSheet }
        // Setup's chain waits on this sheet; closed any other way, the chain stops there.
        .sheet(isPresented: $showSetup, onDismiss: { setupSheetWaiter.finish(false) }) {
            SetupSheet(onFinished: { ok in
                if !setupSheetWaiter.finish(ok), ok { refresh() }
            }, onStep: { s in
                guard setupRunning else { return }
                bootstrapStep = s
                if setupAt != .wine { setupStep(.wine) }
            })
        }
    }

    /// What the selected server permits. See `AddonPolicy` for why an unsourced policy shows
    /// everything rather than guessing at a list. A list fetched from the server's own page this
    /// launch beats the snapshot compiled into the app.
    private var addonPolicy: AddonPolicy {
        guard let s = store.selected else { return .unknown }
        return AddonPolicies.policy(for: s, fetched: feeds.fetchedAddonLists)
    }

    /// Why the narration toggle is on, off, or greyed out. The addon-rules case is the one
    /// that matters: VanaVoice is on nobody's published allowlist, and on a server that runs
    /// one -- HorizonXI, CatsEyeXI -- loading it risks the account, so the launcher will not
    /// offer it there at all.
    private var narrationHelp: String {
        if !Narration.allowed(by: addonPolicy) {
            return "\(store.selected?.name ?? "This server") doesn't allow this addon."
        }
        if !Narration.narratorAvailable {
            return "VanaVoice.app not found: github.com/danielalanbates/vanavoice"
        }
        return "Reads NPC and cutscene dialogue aloud."
    }

    /// Why the Vanaguide toggle is on, off, or greyed out. Same allowlist rule as narration:
    /// Vanaguide is on nobody's published list, so HorizonXI / CatsEyeXI / FFEra never get it.
    private var vanaguideHelp: String {
        if !Guide.isAvailable {
            return "VanaGuide not found."
        }
        if !Guide.allowed(by: addonPolicy) {
            return "\(store.selected?.name ?? "This server") doesn't allow this addon."
        }
        return "Loads VanaGuide in this world."
    }

    /// The launcher's own update: one line, and only when there is something to act on (see
    /// Updater). Checking, downloading and staging show nothing.
    @ViewBuilder private var updateBanner: some View {
        switch updater.state {
        case .ready(let release), .installing(let release):
            updateRow(icon: "arrow.down.circle.fill", tint: Vana.gold,
                      text: "Launcher \(release.label) ready") { restartButton }
        case .restartFailed(let release, let why):
            updateRow(icon: "exclamationmark.circle.fill", tint: Vana.ember, text: why.message) {
                if why.canRetry { restartButton } else { EmptyView() }
            }
            .help(why.detail ?? "Launcher \(release.label)")
        case .manual(let release):
            updateRow(icon: "arrow.down.circle", tint: Vana.gold,
                      text: "Launcher \(release.label) available") {
                Link("Download", destination: release.pageURL).font(.system(size: 12))
            }
        case .idle:
            EmptyView()
        }
    }

    private func updateRow<Action: View>(icon: String, tint: Color, text: String,
                                         @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(Vana.text).lineLimit(1)
            Spacer()
            action()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Vana.gold.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Vana.gold.opacity(0.35), lineWidth: 1))
        .padding(.top, 6)
    }

    /// Off while a game is running here or elsewhere, while a download, install or local-server
    /// job is running, and once pressed. Updater.restartToUpdate refuses the same cases.
    private var restartButton: some View {
        let gameLive = !sessions.live.isEmpty || !sessions.elsewhere.isEmpty
        let job = Runner.workInFlight ? Runner.workInFlightReason ?? "A download"
            : local.busy || LocalServer.workInFlight ? LocalServer.workInFlightReason ?? "The local server"
            : nil
        return Button("Restart") { updater.restartToUpdate() }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(gameLive || job != nil || updateInstalling)
            .help(gameLive ? "Close the game first."
                  : job.map { "\($0) is running. Restart when it finishes." }
                  ?? "Install the update and reopen the launcher.")
    }

    /// Restart was pressed: nothing may start under a launcher about to quit and a bundle about
    /// to be replaced (Updater.install).
    private var updateInstalling: Bool {
        if case .installing = updater.state { return true }
        return false
    }

    /// Live players-online for the selected world: the server's own counter (its website's number)
    /// when it publishes one; otherwise its Discord's people online and members, said to be the
    /// Discord's (ServerFeeds.discordCounts). Neither, no line — never a 0 made up.
    @ViewBuilder
    private var populationLine: some View {
        if let name = store.selected?.name, let n = feeds.populations[name] {
            HStack(spacing: 8) {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text("\(n.formatted()) online")
                    .font(.callout).foregroundStyle(Vana.muted)
            }
            .padding(.top, 2)
        } else if let name = store.selected?.name, let d = feeds.discordCounts[name] {
            HStack(spacing: 8) {
                Circle().fill(Vana.crystal.opacity(0.8)).frame(width: 6, height: 6)
                Text(Self.discordLine(d))
                    .font(.callout).foregroundStyle(Vana.muted)
            }
            .padding(.top, 2)
            .help("\(name) publishes no players-online count, so this is their Discord's, live: people online there, not in the game.")
        }
    }

    static func discordLine(_ d: ServerFeeds.DiscordCount) -> String {
        "\(d.online.formatted()) online in their Discord · \(d.members.formatted()) members"
    }

    // Built outside the view body: as interpolated expressions inline, the type-checker gave up
    // on them ("unable to type-check this expression in reasonable time").
    private static func unknownPolicyNote(_ server: String) -> String {
        "This server's addon rules are not published anywhere this launcher could source them, "
        + "so nothing below is filtered. Check what \(server) allows before you use it — on most "
        + "private servers an unapproved addon is a bannable offence."
    }

    private static func allowlistNote(_ server: String, hidden: Int, source: String) -> String {
        var s = "Showing only what \(server) approves"
        if hidden > 0 {
            let noun = hidden == 1 ? "item is" : "items are"
            s += " — \(hidden) installed \(noun) hidden because they are not on the list"
        }
        return s + ". Source: \(source)."
    }

    /// Why the addon list came back empty. Named paths, because the answer is usually a folder
    /// that is not there.
    private var emptyAddonReason: String {
        let world = store.selected?.name ?? "this world"
        guard let i = active else {
            return "No install is selected, so there is nothing to scan."
        }
        let dir = i.gameDir.path
        if !FileManager.default.fileExists(atPath: dir) {
            return "\(world) has no client here yet: \(dir) does not exist. Download the world's "
                 + "client, or point the launcher at the folder you already have it in."
        }
        return "Nothing installed under \(dir) — no plugins/*.dll and no addons/<name>/<name>.lua. "
             + "If that folder is on a drive that is not mounted, mount it and press Addons… again."
    }

    /// Said once, above the unlisted section, rather than per row.
    private var unlistedNote: String {
        "Not approved by \(store.selected?.name ?? "this server"); may be bannable."
    }

    @ViewBuilder
    private var addonPolicyNote: some View {
        let policy = addonPolicy
        let serverName = store.selected?.name ?? "this server"
        let hidden = hiddenAddonCount
        switch policy {
        case .unknown:
            Text(Self.unknownPolicyNote(serverName))
                .font(.system(size: 12)).foregroundStyle(Vana.ember)
                .fixedSize(horizontal: false, vertical: true)
        case let .unrestricted(reason):
            Text(reason).font(.system(size: 12)).foregroundStyle(Vana.muted)
                .fixedSize(horizontal: false, vertical: true)
        case let .allowlist(_, source):
            Text(Self.allowlistNote(serverName, hidden: hidden, source: source))
                .font(.system(size: 12)).foregroundStyle(Vana.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One addon, with what it says about itself underneath. The description comes out of the
    /// addon's own Lua header (see `AddonSuite.metadata`), so it always matches what is installed.
    @ViewBuilder
    private func addonRow(_ item: Binding<AddonSuite.Item>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(item.wrappedValue.name, isOn: item.enabled)
            let detail = item.wrappedValue.desc
            let byline = item.wrappedValue.byline
            if !detail.isEmpty || !byline.isEmpty {
                Text(detail.isEmpty ? byline
                                    : (byline.isEmpty ? detail : "\(detail)  ·  \(byline)"))
                    .font(.system(size: 12)).foregroundStyle(Vana.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 2)
    }

    /// Ashita's plugins and Lua addons, the same set HorizonXI's own launcher manages.
    private var addonsSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Addons & plugins").font(.headline)
                .help("Written to scripts/default.txt, between the launcher-managed markers. Anything "
                      + "you added by hand outside those blocks is left alone.")

            addonPolicyNote

            if !addonWarning.isEmpty {
                Text(addonWarning).font(.system(size: 12)).foregroundStyle(Vana.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Not an addon: a separate app that loads nothing into the game, so it is offered on
            // every world, allowlist or not. Players look for it here, not in Performance.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VanaGuide Server-Safe (Beta)").font(.system(size: 12)).bold()
                    Text("Quests, gear, skills and server notes in their own window. Loads nothing into the game and reads nothing from the server.")
                        .font(.system(size: 12)).foregroundStyle(Vana.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Open") { Guide.openCompanion(world: store.selected?.name ?? "", worlds: orderedServers.map(\.name)) }
                    Toggle("Open with Play", isOn: $guideWithPlay)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                        .help("Open VanaGuide Server-Safe behind the game every time you press Play.")
                }
                .disabled(Guide.companionURL == nil)
                .help(Guide.companionSupported ? "" : "Needs macOS 14 or later.")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Vana.panel.opacity(0.6)))

            // Extras this project can fetch for the local world. Never shown for a live server
            // — nothing here is on any published approved list.
            if case .unrestricted = addonPolicy, let i = active {
                ForEach(LocalWorldAddons.all, id: \.name) { e in
                    if !LocalWorldAddons.isInstalled(e, in: i) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.system(size: 12)).bold()
                                Text(e.blurb).font(.system(size: 12)).foregroundStyle(Vana.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button(installingExtra == e.name ? "Installing…" : "Get") {
                                installingExtra = e.name
                                Task {
                                    let ok = await LocalWorldAddons.install(e, into: i) { line in
                                        Task { @MainActor in runner.appendLine(line) }
                                    }
                                    await MainActor.run {
                                        installingExtra = ""
                                        if ok {
                                            scanAddons(i, enabling: e.name)
                                            info("\(e.title) installed — Apply to enable")
                                        } else {
                                            notice = "\(e.title) couldn't be installed — Open log in Setup & Diagnostics"
                                        }
                                    }
                                }
                            }
                            .disabled(!installingExtra.isEmpty)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Vana.panel.opacity(0.6)))
                    }
                }
            }

            // While the scan runs (off the main actor, see scanAddons): a spinner where the list
            // will be, and nothing that could read as "nothing installed".
            if addonsScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(AddonSuite.scanningLabel).font(.system(size: 12)).foregroundStyle(Vana.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 320)
            } else {
                // Why the screen is empty, when it is. A blank list is the one outcome that
                // tells the player nothing: it reads the same whether the world has no client
                // installed, the folder is on a drive that is not mounted, or the server's list
                // hid everything. Each of those needs a different thing done about it.
                if addonItems.isEmpty {
                    Text(emptyAddonReason)
                        .font(.system(size: 12)).foregroundStyle(Vana.ember)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }

                List {
                    Section("Plugins") {
                        ForEach($addonItems.filter {
                            $0.wrappedValue.isPlugin && addonPolicy.allows($0.wrappedValue.name)
                        }) { $item in
                            addonRow($item)
                        }
                    }
                    Section("Addons") {
                        ForEach($addonItems.filter {
                            !$0.wrappedValue.isPlugin && addonPolicy.allows($0.wrappedValue.name)
                        }) { $item in
                            addonRow($item)
                        }
                    }
                    // Shown only on unrestricted/unfiltered worlds where no published allowlist exists.
                    // When an allowlist is in effect (e.g. HorizonXI), unapproved addons are strictly
                    // excluded from the list to prevent accidental loading or confusion.
                    if !addonPolicy.isRestricting && addonItems.contains(where: { !addonPolicy.allows($0.name) }) {
                        Section("Not on \(store.selected?.name ?? "this server")'s approved list") {
                            Text(unlistedNote)
                                .font(.system(size: 12)).foregroundStyle(Vana.ember)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach($addonItems.filter {
                                !addonPolicy.allows($0.wrappedValue.name)
                            }) { $item in
                                addonRow($item)
                            }
                        }
                    }
                }
                .frame(height: 320)
            }

            HStack {
                // "All" means all the ones this server permits. Enabling something the server
                // forbids is not a convenience, it is a ban.
                Button("Enable all") {
                    for i in addonItems.indices where addonPolicy.allows(addonItems[i].name) {
                        addonItems[i].enabled = true
                    }
                }
                .disabled(addonsScanning)
                Button("Disable all") {
                    for i in addonItems.indices { addonItems[i].enabled = false }
                }
                .disabled(addonsScanning)
                Spacer()
                Button("Cancel") { showAddons = false }
                Button("Apply") {
                    // The list is empty until the scan is back; writing it would turn every
                    // addon off (itemsToWrite below is exactly addonItems).
                    guard !addonsScanning else { return }
                    // Refuse to write a block that would disable everything.
                    //
                    // On 2026-08-22 a broken fetch made the policy reject every installed addon
                    // (see ServerFeeds.resembles). The screen went blank, Apply wrote an empty
                    // managed block, and the cursor fix -- which lived in an addon on nobody's
                    // published list -- vanished from scripts/default.txt with it. A player
                    // pressing Apply is asking to save a list, never to lose one, so a policy
                    // that permits *nothing* is treated as a broken policy rather than obeyed.
                    let permitted = addonItems.filter { addonPolicy.allows($0.name) }
                    if !addonItems.isEmpty && permitted.isEmpty {
                        notice = "Not saved: server's addon list came back empty"
                        showAddons = false
                        return
                    }
                    let itemsToWrite = addonPolicy.isRestricting
                        ? addonItems.filter { addonPolicy.allows($0.name) }
                        : addonItems
                    let profile = store.selected?.bootProfile ?? "horizonxi.ini"
                    if let i = active {
                        // What the script loaded until now: a running client loaded exactly that.
                        let before = AddonSuite.scan(i, profile: profile)
                        if !AddonSuite.write(itemsToWrite, to: i, profile: profile) {
                            notice = "Could not write the active boot script — its launcher markers are missing."
                        } else if let s = store.selected {
                            // The same change, at once, in that world's running client (if any).
                            // Off the main thread; one launcher.log line, nothing on screen.
                            let r = runner
                            LiveAddons.apply(LiveAddons.commands(from: before, to: itemsToWrite, policy: addonPolicy),
                                             world: s.name, host: s.host, profile: s.bootProfile,
                                             install: i) { line in
                                Task { @MainActor in r.logFileOnly(line) }
                            }
                        }
                    }
                    showAddons = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addonsScanning)
            }
        }
        .padding(20).frame(width: 460)
    }

    /// FFXI's own graphics settings, written into the selected world's boot profile. See
    /// `GraphicsSettings` for why this is not a wrapper around Config.exe.
    private var graphicsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Graphics").font(.headline)
            Text("Applied to \(store.selected?.bootProfile ?? "the boot profile") the next time "
                 + "you press Play.")
                .font(.system(size: 12)).foregroundStyle(Vana.muted)

            Picker("Resolution", selection: Binding(
                get: { "\(graphics.width)x\(graphics.height)" },
                set: { id in
                    let parts = id.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { graphics.width = parts[0]; graphics.height = parts[1] }
                })) {
                ForEach(GraphicsSettings.resolutions, id: \.0) { r in
                    Text(r.0).tag("\(r.1)x\(r.2)")
                }
            }
            .help("World rendering size. Higher values look sharper and use more GPU power.")
            Picker("Texture resolution", selection: $graphics.textureResolution) {
                ForEach([512, 1024, 2048, 4096], id: \.self) { Text(String($0)).tag($0) }
            }
            .help("Detail of world textures. Higher values use more graphics memory.")
            Picker("Mip mapping", selection: $graphics.mipMapping) {
                ForEach(GraphicsSettings.mipMappingChoices, id: \.1) { Text($0.0).tag($0.1) }
            }
            .help("Smooths distant textures. 6 is the best quality.")
            Picker("Texture compression", selection: $graphics.textureCompression) {
                ForEach(GraphicsSettings.textureCompressionChoices, id: \.1) { Text($0.0).tag($0.1) }
            }
            .help("Compressed textures use less graphics memory; uncompressed look best.")
            Picker("Map compression", selection: $graphics.mapCompression) {
                ForEach(GraphicsSettings.mapCompressionChoices, id: \.1) { Text($0.0).tag($0.1) }
            }
            .help("Compressed maps use less graphics memory.")
            Toggle("Bump mapping", isOn: $graphics.bumpMapping)
                .help("Adds raised-looking detail to some surfaces.")
            Picker("Environment animations", selection: $graphics.environmentAnimations) {
                ForEach(GraphicsSettings.environmentChoices, id: \.1) { Text($0.0).tag($0.1) }
            }
            .help("Animates effects such as water and weather.")
            Picker("Sound channels", selection: $graphics.soundChannels) {
                ForEach(GraphicsSettings.soundChannelChoices, id: \.self) { Text(String($0)).tag($0) }
            }
            .help("How many sounds can play at once. 20 is the most.")
            Divider()
            Toggle("Remember window size", isOn: $graphics.rememberWindowSize)
                .help("Opens at the last window size on the next Play. Resizing during play stretches the image until then.")
            Toggle("Match interface to render resolution", isOn: $graphics.uiFollowsResolution)
                .help("Draws menus and text at the world resolution. Turn off to choose a larger interface.")
            if !graphics.uiFollowsResolution {
                Picker("Interface resolution", selection: Binding(
                    get: { "\(graphics.uiWidth)x\(graphics.uiHeight)" },
                    set: { id in
                        let parts = id.split(separator: "x").compactMap { Int($0) }
                        if parts.count == 2 { graphics.uiWidth = parts[0]; graphics.uiHeight = parts[1] }
                    })) {
                    ForEach(GraphicsSettings.uiResolutions, id: \.0) { r in
                        Text(r.0).tag("\(r.1)x\(r.2)")
                    }
                }
                .help("Lower values make menus and text larger without changing world detail.")
            }

            HStack {
                Button("Low") { graphics = .lowSpec }
                    .help("640 × 480 window; every quality setting stays at max.")
                Button("Balanced") { graphics = .balanced }
                    .help("1080p with standard texture detail.")
                Button("Max (4K)") { graphics = .max4K }
                    .help("4K with maximum texture detail. Uses more graphics memory.")
                Spacer()
                Button("Cancel") { showGraphics = false }
                Button("Apply") {
                    graphics.save(world: store.selected?.name)
                    if let i = selected, let s = store.selected {
                        Credentials.ensureProfile(s.bootProfile, in: i, loader: s.loader,
                                                  template: s.bootTemplate, host: s.host, world: s.name)
                        graphics.write(to: i, profile: s.bootProfile)
                    }
                    showGraphics = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20).frame(width: 380)
    }

    private var addServerSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a server").font(.headline)
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
            TextField("Login host", text: $newHost).textFieldStyle(.roundedBorder)
            TextField("Boot profile (.ini)", text: $newProfile).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { newServer = false }
                Button("Add") {
                    store.add(name: newName, host: newHost, profile: newProfile)
                    newName = ""; newHost = ""; newProfile = ""; newServer = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 360)
    }

    /// Shown only for the local world. Selecting it means building an FFXI server on this Mac, so
    /// this says what that will cost and what is left to do before Play can work.
    @ViewBuilder private var localServerCard: some View {
        if store.selected?.local == true {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Your own server", systemImage: "internaldrive")
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                        .foregroundStyle(Vana.gold)
                    Spacer()
                    if local.busy {
                        ProgressView().controlSize(.small)
                        Text(local.activity).font(.system(size: 12)).foregroundStyle(Vana.muted)
                    }
                }

                if let s = local.status {
                    // Disk first: it is the one thing the user has to fix outside this app, and
                    // finding out 20 minutes into a build is far worse than finding out here.
                    // Once the server is built, space is about a *next* build: not shown.
                    if !s.ready {
                        HStack(spacing: 6) {
                            Image(systemName: s.spaceOK ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle(s.spaceOK ? Vana.crystal : Vana.ember)
                            Text(String(format: "%.1f GB free · about %.0f GB needed", s.freeGB, s.needGB))
                                .font(.system(size: 12))
                                .foregroundStyle(s.spaceOK ? Vana.text : Vana.ember)
                        }
                    }

                    if !s.spaceOK && !s.ready {
                        Text(s.belowFloor
                             ? "Not enough space: needs ~\(Int(s.needGB)) GB."
                             : "Space is tight (~\(Int(s.needGB)) GB recommended).")
                            .font(.system(size: 12)).foregroundStyle(Vana.ember)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if s.ready {
                        row("Server", s.running ? "Running" : "Ready")
                            .help(s.running ? "\(s.up.count) of 4 processes · \(s.root)"
                                            : "Play starts it · \(s.root)")
                    } else {
                        row("Still to do", s.todo).help(s.root)
                    }

                    HStack(spacing: 8) {
                        // Building it is the main button's Setup (b60); only the override for a
                        // tight disk stays here.
                        if !s.ready, s.belowFloor {
                            Toggle("Set up anyway", isOn: $forceSetup)
                                .toggleStyle(.checkbox).font(.system(size: 12))
                                .foregroundStyle(Vana.muted)
                                .help("Setup downloads Homebrew packages and the LandSandBoat source, imports "
                                      + "the game database and compiles the server. Half an hour or more "
                                      + "the first time; it can be re-run if it stops.")
                        }
                        if s.ready {
                            Button(s.running ? "Stop server" : "Start server") {
                                if s.running { local.stop(log: { runner.appendLine($0) }) }
                                else { local.start(log: { runner.appendLine($0) }) }
                            }
                            .disabled(local.busy)
                        }
                        Button("Refresh") { local.refresh() }.disabled(local.busy)
                    }
                    .padding(.top, 2)
                } else {
                    Text("Checking…")
                        .font(.system(size: 12)).foregroundStyle(Vana.muted)
                }
            }
            .padding(14)
            .frame(maxWidth: 500, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Vana.stroke))
            .padding(.horizontal, 34).padding(.top, 14)
        }
    }

    // MARK: - Signup

    /// Where to get an account, shown only while none is saved for the selected world.
    ///
    /// This is the one thing a new player cannot do from inside the launcher: every world runs
    /// its own account database, and four of the ten have no web signup at all — the account is
    /// typed into the loader console on first launch, or gated behind a Discord bot. So the card
    /// states the actual route for the selected world and offers the link that leads to it. See
    /// `Server.accountHow`. The local world makes its own account, so it never shows.
    @ViewBuilder
    private var accountCard: some View {
        if let s = store.selected, !s.local, !Credentials.hasSavedAccount(forWorld: s.name) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Getting an account", systemImage: "person.badge.key")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(Vana.gold)

                Text(s.accountHow.isEmpty ? "No public signup" : s.accountHow)
                    .font(.system(size: 12)).foregroundStyle(Vana.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    // Only the worlds whose account really is typed into the loader console get
                    // this line -- Tabula Rasa XI has no route at all and must not be told it
                    // has one.
                    if s.accountURL.isEmpty, s.accountHow.contains("loader window") {
                        Label("Created in the loader window when you press Play",
                              systemImage: "terminal")
                            .font(.system(size: 12)).foregroundStyle(Vana.crystalDim)
                    }
                    // The world's login server makes the account (b72): the name and password
                    // typed above, sent the way xiloader's own Create New Account sends them.
                    if s.createsAccountAtLogin {
                        Button { createAccount(for: s) } label: {
                            Label(creatingAccount ? "Creating…" : "Create account", systemImage: "person.badge.plus")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderedProminent).tint(Vana.goldDim)
                        .disabled(creatingAccount)
                        .help("Makes the account typed above on \(s.host)")
                    }
                    if let u = URL(string: s.accountURL), !s.accountURL.isEmpty {
                        Button {
                            NSWorkspace.shared.open(u)
                        } label: {
                            Label(Self.signupVerb(for: s), systemImage: "arrow.up.forward.square")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderedProminent).tint(Vana.goldDim)
                        .help(u.absoluteString)
                    }
                    if let d = URL(string: s.discordURL), !s.discordURL.isEmpty,
                       s.discordURL != s.accountURL {
                        Button { NSWorkspace.shared.open(d) } label: {
                            Label("Discord", systemImage: "bubble.left.and.bubble.right")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered).tint(Vana.crystalDim)
                        .help(d.absoluteString)
                    }
                    Spacer(minLength: 0)
                }
                if let r = accountResult, r.world == s.name {
                    Text(r.text).font(.system(size: 12)).foregroundStyle(r.ok ? Vana.gold : Vana.ember)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: 500, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Vana.stroke))
            .padding(.horizontal, 34).padding(.top, 16)
        }
    }

    /// Create account: the typed name and password, at the world's login server (LoginAccount).
    /// On success they are saved for the world as Play would save them, and the card goes away.
    private func createAccount(for s: Server) {
        let name = user.trimmingCharacters(in: .whitespaces), password = pass
        if let why = LoginAccount.problem(user: name, password: password) {
            accountResult = (s.name, false, why); return
        }
        creatingAccount = true
        accountResult = nil
        let host = s.host
        Task {
            let outcome = await LoginAccount.create(host: host, user: name, password: password)
            creatingAccount = false
            switch outcome {
            case .created:
                Credentials.setUsername(name, forWorld: s.name)
                if remember { Credentials.savePassword(password, for: name, world: s.name) }
                accountResult = (s.name, true, "Account \(name) created on \(s.name). Press Play.")
                // The card goes once the world has a saved account; the line stays where Play's are.
                info("Account \(name) created on \(s.name). Press Play.")
                runner.logFileOnly("==> \(s.name): account \(name) created at \(host)")
            case .taken:
                accountResult = (s.name, false, "\(name) is already taken on \(s.name). Choose another name.")
            case .refused(let why), .failed(let why):
                accountResult = (s.name, false, why)
                runner.logFileOnly("!! \(s.name): account not created: \(why)")
            }
        }
    }

    /// Say what the link actually does. Some of these lead to a wiki page or a control panel
    /// rather than a registration form, and calling that "Create account" would be a lie. A
    /// world with no signup page gets no button at all: its account is created in the loader
    /// window at Play time, so there is nowhere to send the player.
    private static func signupVerb(for s: Server) -> String {
        guard !s.accountURL.isEmpty else { return "" }
        if s.accountURL.contains("register") { return "Create account" }
        if s.accountURL.contains("fandom.com") || s.accountURL.contains("wordpress.com") {
            return "How to get one"
        }
        return "Account page"
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k.uppercased()).font(.system(size: 11)).tracking(1.2)
                .foregroundStyle(Vana.crystalDim).frame(width: 84, alignment: .leading)
            Text(v).font(.system(size: 12)).foregroundStyle(Vana.text)
            Spacer()
        }
    }

    /// Setup & Diagnostics' checks: only the ones that are not fine.
    private var statusList: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !checks.isEmpty, !checks.contains(where: { $0.state != .ok }) {
                Text("All checks passed").font(.system(size: 12)).foregroundStyle(Vana.muted)
            }
            ForEach(checks.filter { $0.state != .ok }) { c in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color(c.state)).frame(width: 7, height: 7).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.system(size: 12)).foregroundStyle(Vana.text)
                        Text(c.detail).font(.system(size: 12)).foregroundStyle(Vana.muted)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Errors only ("!!" lines, a refused login among them; see Runner.appendLine), and only
    /// while there are any. Everything else is in launcher.log (Setup & Diagnostics › Open log).
    @ViewBuilder private var logStrip: some View {
        if !runner.log.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Vana.stroke).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    ScrollViewReader { sp in
                        ScrollView {
                            Text(runner.log)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Vana.ember)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                                .id("end")
                        }
                        .frame(maxHeight: 108)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: runner.log) { _ in sp.scrollTo("end", anchor: .bottom) }
                    }
                    Button { runner.clearLog() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(Vana.muted)
                        .padding(10)
                        .help("Dismiss")
                }
            }
            .background(Color.black.opacity(0.28))
        }
    }

    // MARK: - Right: account + play

    private var sidebar: some View {
        // Scrolls rather than clips: with the install picker (gone in b65) and a long notice the
        // column outgrew a 632pt window and lost its top edge.
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 14) {
            serverPicker

            Rectangle().fill(Vana.stroke).frame(height: 1)

            HStack {
                Text("ACCOUNT").font(.system(size: 12)).tracking(2.5).foregroundStyle(Vana.gold)
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).foregroundStyle(Vana.muted)
                    .help("Rescan for installs")
                Button { chooseInstall() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).foregroundStyle(Vana.muted)
                    .help("Choose wrapper app…")
            }

            // The local server auto-creates its own account on first login (see LocalServer.swift)
            // -- there is no real account to type here, so the fields are disabled rather than
            // left editable and silently ignored.
            field("Account name", text: $user, secure: false, disabled: store.selected?.local == true, focus: .account)
            field("Password", text: $pass, secure: true, disabled: store.selected?.local == true, focus: .password)
            Toggle("Remember me", isOn: $remember)
                .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Vana.muted)
                .help("Remembered in a mode-600 file in Application Support. The game loader also receives it in its command line.")

            playButton
            runningList

            // Graphics and addons are things people change often -- they belong next to Play,
            // not inside a collapsed diagnostics section.
            HStack(spacing: 8) {
                Button("Graphics…") { openGraphics() }
                Button("Addons…") { openAddons() }
            }
            .font(.system(size: 12))

            if !notice.isEmpty {
                Text(notice).font(.system(size: 12)).foregroundStyle(Vana.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(playWarnings, id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundStyle(Vana.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if localServerSlowing {
                HStack(spacing: 8) {
                    Text(PlayCheck.localServerLine).font(.system(size: 12)).foregroundStyle(Vana.gold)
                    Button("Stop local server") {
                        local.stop(log: { runner.appendLine($0) }) { ok in if ok { localServerSlowing = false } }
                    }
                    .font(.system(size: 12))
                    .disabled(local.busy)
                }
            }

            Rectangle().fill(Vana.stroke).frame(height: 1)

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    rendererSection
                    row("Wine prefix", selected?.prefixName ?? (scanning ? "scanning…" : "not found"))
                    row("Client", selected == nil ? (scanning ? "scanning…" : "not found")
                                                  : "Ashita · \(store.selected?.bootProfile ?? "")")
                    Divider()
                    if let s = store.selected, !s.local {
                        Text("SERVER CONNECTION").font(.system(size: 12)).tracking(2).foregroundStyle(Vana.muted)
                        TextField("login host", text: Binding(
                            get: { s.host }, set: { var c = s; c.host = $0; store.update(c) }))
                            .focused($focus, equals: .host)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        HStack(spacing: 6) {
                            TextField("boot profile .ini", text: Binding(
                                get: { s.bootProfile }, set: { var c = s; c.bootProfile = $0; store.update(c) }))
                                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            if !Server.builtins.contains(where: { $0.name == s.name }) {
                                Button(role: .destructive) { store.remove(s) } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless)
                            }
                        }
                        Divider()
                    }
                    Toggle("Fast synchronisation (msync)", isOn: $perf.msync)
                    Toggle("Silence wine debug channels", isOn: $perf.silenceWineDebug)
                    Toggle("Keep awake (no App Nap)", isOn: $perf.disableAppNap)
                    Toggle("Follow the Mac's sound output", isOn: $perf.followSoundOutput)
                        .help("Game audio follows your Mac's output device.")
                    Toggle("Keep the game window's shape and title", isOn: $perf.keepWindowShape)
                        .help("Resizing keeps the picture in proportion; the title stays FFXI on Mac.")
                    Toggle("VanaVoice — read cutscenes aloud", isOn: $perf.narrateCutscenes)
                        .disabled(!Narration.isAvailable || !Narration.allowed(by: addonPolicy))
                        .help(narrationHelp)
                    Toggle("VanaGuide — quest guide (local server only)", isOn: $perf.enableVanaguide)
                        .disabled(!Guide.isAvailable || !Guide.allowed(by: addonPolicy))
                        .help(vanaguideHelp)
                    Toggle("Large address aware", isOn: $perf.largeAddressAware)
                    Divider()
                    RetroAchievementsSection(ra: ra, gameDir: active?.gameDir,
                                             log: { runner.appendLine($0) })
                    Divider()
                    HStack(spacing: 8) {
                        // Repair refuses (and says why) when the game data is unreachable; the
                        // main button never offers it then. Update HorizonXI is the main button.
                        Button("Repair") { if let i = active { runner.repair(i) { _ in recheck() } } }
                            .disabled(runner.busy || fdaBlocked || missingDrive != nil)
                            .help(missingDrive.map { "The '\($0)' drive isn't available." }
                                  ?? (fdaBlocked ? "Allow Full Disk Access first." : "Re-applies the prefix configuration the game needs."))
                        if let s = store.selected {
                            Button("Choose folder…") { chooseGameData(for: s) }
                                .disabled(runner.busy)
                                .help("Point \(s.name) at a folder that already holds its game files.")
                        }
                        if store.selected?.name == "CatsEyeXI" {
                            Button("CatsEyeXI installer…") { if let i = active, let s = store.selected { runner.runCatsEyeLauncher(i, dataPath: s.dataPath) } }
                                .disabled(runner.busy)
                                .help("Runs CatsEyeXI's own launcher inside the wrapper to install or update their client (their storage is private, so only their launcher can fetch it).")
                        }
                        if let s = store.selected, !s.local {
                            Button("Run installer…") { if let i = active { runLocalInstaller(for: s, install: i) } }
                                .disabled(runner.busy)
                                .help("Run a Windows installer or launcher (.exe or .zip) you already downloaded for \(s.name), inside the wrapper. It installs into C:\\Games\\\(s.name), which is \(s.dataPath.isEmpty ? "the folder you choose" : s.dataPath).")
                        }
                        // Also reachable when an install already exists: a wrapper can be
                        // broken past what Repair fixes, and rebuilding a fresh one beside it
                        // is faster than diagnosing wine by hand.
                        Button("Install dependencies…") { Task { await installDependencies() } }
                            .disabled(setupRunning)
                            .help("Installs Rosetta 2 and Wine, and creates the Windows drive FFXI installs into, in a folder you choose")
                        // Not offered while a drive the game is on is gone: a Move could only refuse.
                        if missingDrive == nil {
                            Button("Move…") { startMove() }
                                .disabled(active == nil || runner.busy || setupRunning || moveChecking)
                                .help("Copies Wine, its Windows drive and the game into one folder you choose. The old copy stays until you say otherwise.")
                        }
                    }
                    .padding(.top, 4)
                    // The full log: every line of every run, which the window no longer shows.
                    Button("Open log") { NSWorkspace.shared.open(Runner.logFile) }
                        .help(Runner.logFile.path)

                }
                .font(.system(size: 12))
                .foregroundStyle(Vana.muted)
                .padding(.top, 8)
                .onChange(of: perf.msync) { _ in perf.save() }
                .onChange(of: perf.silenceWineDebug) { _ in perf.save() }
                .onChange(of: perf.disableAppNap) { _ in perf.save() }
                .onChange(of: perf.followSoundOutput) { _ in perf.save() }
                .onChange(of: perf.keepWindowShape) { _ in perf.save() }
                .onChange(of: perf.largeAddressAware) { _ in perf.save() }
                .onChange(of: perf.narrateCutscenes) { _ in perf.save() }
                .onChange(of: perf.enableVanaguide) { _ in perf.save() }
                .onChange(of: perf.metalHUD) { _ in perf.save() }
            } label: {
                Text("SETUP & DIAGNOSTICS").font(.system(size: 12)).tracking(2.5)
                    .foregroundStyle(Vana.gold)
            }

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Vana.panel)
    }

    private var rendererSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RENDERER").font(.system(size: 12)).tracking(2).foregroundStyle(Vana.muted)
            Picker("", selection: $perf.renderer) {
                ForEach(Renderer.allCases) { r in Text(r.title).tag(r) }
            }
            .labelsHidden()
            .onChange(of: perf.renderer) { _ in perf.save() }
            Text(perf.renderer.blurb)
                .font(.system(size: 12)).foregroundStyle(Vana.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool,
                       disabled: Bool = false, focus field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 12)).tracking(1.5).foregroundStyle(Vana.muted)
            Group {
                if secure { SecureField("", text: text) } else { TextField("", text: text) }
            }
            .focused($focus, equals: field)
            .textFieldStyle(.plain)
            .disabled(disabled)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.40)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Vana.crystalDim.opacity(0.5)))
            .foregroundStyle(disabled ? Vana.muted : Vana.text)
            .opacity(disabled ? 0.5 : 1)
        }
    }

    /// The visible world picker row (see the ZStack in the sidebar for why it is separate).
    private var worldRow: some View {
                HStack(spacing: 8) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Vana.crystal)
                    Text(store.selected?.name ?? "Choose a world")
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(Vana.text)
                        .lineLimit(1)
                        .help(store.selected?.era ?? "")
                    Spacer(minLength: 4)
                    // Say it in words. The chevron-in-a-circle this replaced still read as
                    // decoration to a first-time user; a labelled gold pill does not.
                    HStack(spacing: 4) {
                        Text("CHANGE WORLD").font(.system(size: 11, weight: .bold)).tracking(1).lineLimit(1).fixedSize()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(worldHover ? Vana.crystal : Vana.gold))
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(worldHover ? Color.white.opacity(0.10) : Color.black.opacity(0.32)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(worldHover ? Vana.crystal : Vana.crystalDim.opacity(0.7),
                            lineWidth: worldHover ? 1.5 : 1))
                .contentShape(Rectangle())
                .onHover { hovering in
                    worldHover = hovering
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
    }

    /// Ask where this world's files already are. Opens on the world's folder in the chosen
    /// "FFXI on Mac" folder when there is one; nothing is created before the user picks. The
    /// choice is stored on the server entry.
    private func chooseGameData(for s: Server) {
        let panel = NSOpenPanel()
        panel.title = "Game data for \(s.name)"
        panel.message = "Choose the folder that holds \(s.name)'s game files. Any drive is fine; the launcher finds Ashita-cli.exe and SquareEnix inside it, however \(s.name)'s installer laid them out."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        let fm = FileManager.default
        let candidates = [InstallLocation.remembered.map { InstallLocation.worldData(s.name, in: $0) },
                          InstallLocation.remembered,
                          fm.homeDirectoryForCurrentUser.appendingPathComponent("Games/FFXI/\(s.name)")].compactMap { $0 }
        panel.directoryURL = candidates.first { fm.fileExists(atPath: $0.path) } ?? fm.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var c = s; c.dataPath = url.path; store.update(c)
        recheck()
    }

    /// The user already has the world's installer (their site, Discord, a friend's USB stick).
    /// Run it in the wrapper, pointed at the world's data folder.
    private func runLocalInstaller(for s: Server, install i: Install) {
        if s.dataPath.isEmpty {
            chooseGameData(for: s)
            guard let again = store.servers.first(where: { $0.name == s.name }), !again.dataPath.isEmpty else { return }
            runLocalInstaller(for: again, install: i.forServer(again)); return
        }
        let panel = NSOpenPanel()
        panel.title = "Installer for \(s.name)"
        panel.message = "Pick \(s.name)'s Windows installer or launcher (.exe, or a .zip holding one). It runs inside the wrapper; when it asks where to install, use C:\\Games\\\(s.name) — that is \(s.dataPath)."
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.exe, .zip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Run in wrapper"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runner.runLocalInstaller(url, in: i, dataPath: s.dataPath, name: s.name)
    }

    /// Where a world's own download page is, for when a direct installer link has gone stale.
    static let homePages: [String: String] = [
        "Eden": "https://edenxi.com", "FFEra": "https://ffera.com/login.php?guide=install",
        "ValhallaXI": "https://valhalla.group/site/connect.html", "Gaia XI": "https://gaiaxi.com",
        "CatsEyeXI": "https://catseyexi.com/download",
    ]

    /// Get the world's client the way that world distributes it. Nothing here redistributes
    /// Square Enix data: each route runs or opens the server's own installer.
    private func downloadGameData(for s: Server, install i: Install) {
        if let why = s.launchUnavailableReason { notice = why; return }
        if s.dataPath.isEmpty && s.name != "HorizonXI" {
            // Into the "FFXI on Mac" folder the user chose; asked for here only when there is none.
            guard placeWorldData(for: s),
                  let again = store.servers.first(where: { $0.name == s.name }), !again.dataPath.isEmpty else { return }
            downloadGameData(for: again, install: i.forServer(again)); return
        }
        switch s.installKind {
        case .catseyeLauncher:
            runner.runCatsEyeLauncher(i, dataPath: s.dataPath)
        case .horizonTorrent:
            runner.installHorizon(into: i.gameDir)
        case .installerExe:
            guard let u = URL(string: s.installURL) else { return }
            runner.installPageFallback = Self.homePages[s.name].flatMap(URL.init(string:))
            // An NSIS script may ignore /D= and install wherever it likes (Eden's does). Take
            // the folder the installer actually used rather than assuming the one we asked for —
            // a dataPath that does not hold the world's client is what made "Play Eden" launch
            // the HorizonXI client in the first place.
            runner.onClientInstalled = { found in
                guard var c = store.servers.first(where: { $0.name == s.name }) else { return }
                if c.dataPath != found.path {
                    c.dataPath = found.path; store.update(c)
                    runner.appendLine("==> \(s.name)'s game data folder set to \(found.path)")
                }
                recheck()
            }
            runner.runInstaller(from: u, in: i, dataPath: s.dataPath, name: s.name)
        case .clientZip:
            guard let u = URL(string: s.installURL) else { return }
            runner.installPageFallback = Self.homePages[s.name].flatMap(URL.init(string:))
            runner.installClientZip(from: u, into: s.dataPath, name: s.name)
        case .retail:
            runner.installRetail(for: s, in: i)
        case .ascensionChannel, .vanadreamsPackage, .driftwoodContent, .pegasusPack, .retailWorld, .scytheChannel:
            worldJob(for: s, install: i, full: true, runner: runner) { _ in recheck() }
        case .website:
            if let u = URL(string: s.installURL) { NSWorkspace.shared.open(u) }
            info("Download page opened — then use Run installer…")
        case .none:
            notice = "No download known for \(s.name)"
        }
    }

    /// Every world's boot profile, for `Sessions.bootHosts`.
    private var bootProfiles: [(world: String, profile: String)] {
        store.servers.map { ($0.name, $0.bootProfile) }
    }

    /// Clients elsewhere, and what an earlier launcher left behind (Sessions.refreshElsewhere).
    private func refreshElsewhere() async {
        await sessions.refreshElsewhere(install: selected, profiles: bootProfiles, servers: store.servers)
    }

    /// Clients this window did not start, named by the world whose host (or boot profile's
    /// `--server`) they were given.
    private var elsewhere: [(host: String, name: String, pids: [pid_t])] {
        sessions.elsewhere.keys.sorted().map { h in
            let name = store.servers.first { LiveClients.normalize($0.host) == h }?.name
                ?? store.servers.first { sessions.bootHosts[$0.name] == h }?.name
                ?? (h.isEmpty ? "Unknown world" : h)
            return (h, name, sessions.elsewhere[h] ?? [])
        }
    }

    /// The next required action, as one button: Setup, Update, Repair, Play or Stop (Play
    /// Another where a world allows two clients), or the running job's progress. One short line
    /// under it says why when it is not PLAY; nothing at all when the game is ready.
    private var playButton: some View {
        let d = primary
        let dim = !d.enabled || d.destructive
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { perform(d.action) } label: {
                    Text(d.label.uppercased())
                        .font(.system(size: 15, weight: .semibold, design: .serif)).tracking(3)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(
                            LinearGradient(colors: dim
                                           ? [Vana.goldDim.opacity(0.45), Vana.goldDim.opacity(0.25)]
                                           : [Vana.gold, Vana.goldDim],
                                           startPoint: .top, endPoint: .bottom))
                        .foregroundStyle(Color.black.opacity(0.86))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: Vana.gold.opacity(dim ? 0 : 0.35), radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                // Stop is never one Return key away.
                .keyboardShortcut(d.destructive ? nil : .defaultAction)
                .disabled(!d.enabled)
                // The running job's own Stop, beside its progress, for every job this window runs
                // (Repair, a copy or Move, Wine's update, an installer, a download): no step of
                // Setup holds the button with no way out (Daniel, 2026-10-15). What the job
                // started ends with it, its Wine session included (JobKill).
                if runner.updatingHorizon {
                    Button("Stop") { runner.stopHorizonUpdate() }
                        .controlSize(.small)
                        .help("Stops the download. Press the button again later to resume.")
                } else if runner.busy {
                    Button("Stop") { runner.stopJob() }
                        .controlSize(.small)
                        .help("Stops \(runner.busyReason.isEmpty ? "the job" : runner.busyReason.lowercased()). Press the button again to carry on.")
                }
            }
            if let p = d.progress { ProgressView(value: p).tint(Vana.gold) }
            if let r = d.reason {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle().fill(d.enabled ? Vana.gold : Vana.ember).frame(width: 6, height: 6)
                    Text(r).font(.system(size: 12)).foregroundStyle(Vana.text)
                        .lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(r)
                    // The game's files on another drive than Wine, every drive there: offer to bring
                    // them together (never beside a drive that is gone: InstallMove.offered).
                    if case .setup = d.action, probe.dataElsewhere, active != nil {
                        Spacer(minLength: 4)
                        Button("Move…") { startMove() }
                            .buttonStyle(.link).font(.system(size: 12))
                            .help("Copy Wine and the game into one folder you choose.")
                    }
                }
            }
        }
    }

    /// The button's click. Decided again now, and done only if it still says the same thing,
    /// so a double click or a state change under the pointer cannot start the wrong job.
    private func perform(_ a: PrimaryAction) {
        let now = primary
        guard now.action == a, now.enabled else { return }
        guard let s = store.selected else { return }
        switch a {
        case .serverInfo:
            if s.name == "Phoenix XI" {
                PhoenixSetup.shared.begin(wine: X87Sidecar.patchedWine() ?? selected?.wine, bootstrapWine: selected?.wine) { message in notice = message }
                return
            }
            if let url = URL(string: s.installURL) { NSWorkspace.shared.open(url) }
        case .setup(.localServer(lowSpace: true)):
            // Below the disk floor: say the numbers and set it up only on a yes ("Set up anyway").
            let alert = NSAlert()
            alert.messageText = "Not enough free space for the local server."
            if let st = local.status {
                alert.informativeText = String(format: "%.1f GB free; it needs about %.0f GB.", st.freeGB, st.needGB)
            }
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Set Up Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            forceSetup = true
            Task { await runSetup() }
        case .setup:
            Task { await runSetup() }
        case .update:
            guard let i = active else { return }
            if s.installKind == .catseyeLauncher { runner.runCatsEyeLauncher(i, dataPath: s.dataPath); return }
            guard s.name == "HorizonXI" else {
                // No updater in the launcher: the world's own route (installer, client zip or
                // download page); with none known, its home page, or the folder its client is in.
                if s.installKind != .none { downloadGameData(for: s, install: i) }
                else if let u = Self.homePages[s.name].flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
                else { chooseGameData(for: s) }
                return
            }
            // A failed or stopped update drops back to PLAY for this session: HorizonXI's login
            // server accepts a client one version behind.
            PrimaryFixer.perform(a, install: i, server: s, runner: runner) { ok in
                if !ok { updateDeferred = true }
                recheck()
            }
        case .repair(.host):
            showDetails = true
            DispatchQueue.main.async { focus = .host }
        case .repair(.check):
            // No fix of its own: the full Repair, with the checks open so what still fails shows.
            guard let i = active else { return }
            showDetails = true
            PrimaryFixer.perform(a, install: i, server: s, runner: runner) { _ in recheck() }
        case .repair(.access):
            // Turning FFXI on Mac on there covers Removable Volumes too; macOS then offers to
            // quit and reopen it, and coming back re-runs the checks.
            NSWorkspace.shared.open(PrimaryFixer.fullDiskAccessPane)
        case .repair:
            guard let i = active else { return }
            PrimaryFixer.perform(a, install: i, server: s, runner: runner) { _ in recheck() }
        case .play, .playAnother:
            guard !carryingOver else { return }
            // Registry and COM entries Preflight found missing are written by Play itself
            // (GameRegistry.point); forget its cache so it really does write them. Never under a
            // running client: its registry must not change (Runner.gate).
            // Read the registry again rather than trust the last check: after a Play that wrote it,
            // the checks taken before that Play still say "bad" until the next recheck, and the
            // second press re-pointed it all over again, a minute of "Starting…" (b60, 2026-10-15).
            if let i = active, sessions.live.isEmpty,
               checks.contains(where: { ["reg32", "reglayout", "com"].contains($0.id) && $0.state == .bad }),
               !Preflight.registryPointed(i) {
                GameRegistry.invalidate(i)
            }
            // A carry-over Setup could not do (a game was running then) goes first. With a game
            // still running it can't, and Play says so once instead of starting: after this Play
            // a character has logged in here, and nothing is carried any more.
            if a == .play, carriesOver, let i = active, CarryOver.isPending(i) {
                Task {
                    if let why = Self.carryOverBlocked(await carryOver(.play)), !carryOverWarned {
                        carryOverWarned = true
                        notice = why
                    } else {
                        play()
                    }
                }
            } else {
                play()
            }
        case .stop:
            // No question (b70) when nothing is left to save: Wine gone under the client (Force
            // Stop), or its graphics gone for good (the line under the button says so); nor for
            // a client that outlived a Stop already confirmed.
            if runner.serverLost || runner.renderStuckSince != nil || runner.stopOutlived {
                runner.stop(force: runner.serverLost)
                Task { await refreshElsewhere() }
                return
            }
            let alert = NSAlert()
            alert.messageText = "Stop \(s.name)?"
            alert.informativeText = "The game closes without logging out."
            alert.addButton(withTitle: "Keep Playing")
            alert.addButton(withTitle: "Stop")
            if alert.runModal() == .alertSecondButtonReturn {
                runner.stop()
                Task { await refreshElsewhere() }
            }
        case .enterAccount:
            focus = user.trimmingCharacters(in: .whitespaces).isEmpty ? .account : .password
        case .working:
            break
        }
    }

    // MARK: - Setup: every missing step, from one click

    /// Waits for the setup sheet (Wine and the Windows drive) to finish or be closed.
    final class SheetWaiter {
        private var cont: CheckedContinuation<Bool, Never>?
        func wait() async -> Bool { await withCheckedContinuation { cont = $0 } }
        /// True when a chain was waiting for this.
        @discardableResult func finish(_ ok: Bool) -> Bool {
            guard let c = cont else { return false }
            cont = nil
            c.resume(returning: ok)
            return true
        }
    }

    /// Setup's chain is on step `s`: the button names it, and its figure counts from there.
    private func setupStep(_ s: SetupMeter.Step) {
        setupMeter.meter.begin(s)
        setupAt = s
    }

    /// How far the chain's current step is, 0...1, from whatever does the work: the setup sheet's
    /// steps, the scripts' readouts (ScriptProgress), a copy's bytes.
    private var setupLive: Double {
        switch setupAt {
        case .wine?:
            switch bootstrapStep {
            case .rosetta?, nil: return 0
            case .download?: return 0.1
            case .assemble?: return 0.55
            case .prefix?: return 0.75
            }
        case .gameWine?, .game?: return runner.updatingHorizon ? runner.updateProgress : runner.ascensionProgress ?? 0
        case .multiServer?: return 0
        case .files?: return runner.moveProgress ?? 0
        default: return 0
        }
    }

    /// What the button names while the chain works ("Downloading HorizonXI"); nil says
    /// "Setting up" (choosing the folder, another world's installer).
    private var setupStage: SetupStage? {
        switch setupAt {
        case .rosetta?: return .rosetta
        case .wine?: return bootstrapStep.map(SetupStage.init)
        case .files?: return runner.busy ? .copyingFiles : .movingFiles
        case .gameWine?: return .gameWine
        case .multiServer?: return .multiServer
        case .game?: return runner.updatingHorizon ? runner.stage : nil
        case .configure?: return .finishing
        case .localServer?: return .buildingServer
        case nil: return nil
        }
    }

    /// The decision as it would be with no chain running: what Setup still has to do.
    private var nextNeed: PrimaryAction {
        var x = primaryInputs
        x.setupRunning = false
        return Primary.decide(x).action
    }

    /// SETUP. Runs every step that is still missing, in order, re-reading the state before each
    /// one, so pressing it again after a stop, a failure or a cancelled sheet carries on where
    /// it left off and never redoes finished work:
    ///
    ///   1. location -- the folder chooser, before anything is written: everything goes in
    ///      "<chosen>/FFXI on Mac/" (`setupLocationStep`, InstallLocation);
    ///   2. Wine and the Windows drive in that folder (Bootstrap, in the setup sheet), Rosetta 2
    ///      first (macOS's administrator prompt; on its own when only Rosetta is missing);
    ///   3. the game's Wine, athei's pinned wine-coop, into the same folder (scripts/game-wine.sh,
    ///      `setupGameWineStep`), with its download's progress on the button;
    ///   4. the game: HorizonXI's base, Ashita and every update (update-client.sh install),
    ///      or the world's own installer;
    ///   5. registry, COM and Wine's library links (Repair, install.sh);
    ///   6. the local server's build, for the local world;
    ///   7. the checks again, so the button becomes the next thing -- PLAY when all is done.
    ///
    /// Nothing is deleted or overwritten without a click: the folder chooser and the sheet are
    /// the clicks (Cancel on either writes nothing and leaves SETUP), and every job here only adds
    /// what is missing.
    private func runSetup() async {
        guard !setupRunning else { return }
        if let why = store.selected?.launchUnavailableReason { notice = why; return }
        let world = store.selectedID
        setupRunning = true
        // The whole chain as one figure, planned from where it starts (SetupMeter).
        var start = primaryInputs
        start.setupRunning = false
        setupMeter.meter = SetupMeter(planned: SetupMeter.plan(start))
        setupAt = nil
        bootstrapStep = nil
        notice = ""
        // The installs as they are before Setup changes anything: where a client it downloads
        // gets its macros and settings from (CarryOver), HorizonXI's in the install in use first.
        // Kept from earlier presses too: a rescan between them can drop an install the folder
        // button chose.
        let horizon = store.servers.first { $0.name == "HorizonXI" }
        for u in CarryOver.knownRoots(base: selected ?? Install.lastChosen(), horizon: horizon, installs: installs)
        where !carryHints.contains(u) {
            carryHints.append(u)
        }
        let r = runner
        defer {
            setupRunning = false
            setupAt = nil
            bootstrapStep = nil
            recheck()
        }
        // Each step at most once per press: a step that did not fix its need says why in its
        // own "!!" line, and the next press tries again.
        var done: [PrimaryAction.SetupNeed] = []
        var configured = false
        func configureIfNeeded() async -> Bool {
            guard !configured else { return true }
            guard checks.contains(where: { Primary.configuredAfterDownload.contains($0.id) && $0.state == .bad })
            else { return true }
            configured = true
            setupStep(.configure)
            return await setupConfigureStep(r)
        }
        // HorizonXI's update, when the install Setup found or finished is behind: once per press,
        // after the steps it needed (a fresh download applies every update itself).
        var updated = false
        for _ in 0..<10 {
            await recheckSettled()
            guard store.selectedID == world else { return }   // the user switched worlds
            let need: PrimaryAction.SetupNeed
            switch nextNeed {
            case .setup(let n): need = n
            case .update(let w, _) where w == "HorizonXI" && !updated && !done.isEmpty:
                updated = true
                setupStep(.game)
                guard let i = active, let s = store.selected else { return }
                let ok = await withCheckedContinuation { c in
                    PrimaryFixer.perform(.update(world: w, to: ""), install: i, server: s, runner: r) { c.resume(returning: $0) }
                }
                // Stopped or failed: Play this session anyway, as the Update button does.
                if !ok { updateDeferred = true; return }
                continue
            case .repair(.wine):
                // Step 5 on its own (Wine's library links), when it is all that is left.
                guard !configured, await configureIfNeeded() else { return }
                continue
            default: return                                     // nothing left to set up
            }
            if done.contains(need) { return }
            done.append(need)
            switch need {
            case .rosetta:
                setupStep(.rosetta)
                guard await setupRosettaStep(r) else { return }
            case .install, .wrapperDrive, .wine:
                guard await setupLocationStep(need) else { return }
                await refreshAsync()
            case .dataDrive, .chooseFolder:
                guard await setupLocationStep(need) else { return }
            case .game:
                setupStep(.game)
                await carryOverPrepare()
                guard await setupGameStep(r) else { return }
                // The macros, equipment sets and addon settings of the install played before, as
                // soon as the client is there (a configure step that fails must not lose them).
                await carryOver(.setup)
                // Step 5 right away: a fresh prefix has no registry, COM or library links yet.
                await recheckSettled()
                guard await configureIfNeeded() else { return }
            case .gameWine:
                setupStep(.gameWine)
                guard await setupGameWineStep(r) else { return }
            case .multiServer:
                setupStep(.multiServer)
                guard await setupMultiServerStep(r) else { return }
            case .localServer:
                setupStep(.localServer)
                guard await setupLocalServerStep(r) else { return }
            }
        }
    }

    private func setupMultiServerStep(_ r: Runner) async -> Bool {
        guard let base = selected, let server = store.selected, server.multiServerPlay else { return false }
        guard !preparingMultiServer else { return false }
        preparingMultiServer = true
        defer { preparingMultiServer = false }
        do {
            try await r.prepareMultiServer(base: base, server: server)
            return true
        } catch {
            let why = "Multi-server setup failed: \(error.localizedDescription)"
            r.appendLine("!! " + why)
            if store.selectedID == server.name { notice = why }
            return false
        }
    }

    /// The selected world's client is the one Setup downloads (HorizonXI's, which the local
    /// world plays too): the only one CarryOver carries into by itself. Another world's
    /// characters live on another server.
    private var carriesOver: Bool {
        guard let s = store.selected else { return false }
        return s.installKind == .horizonTorrent || s.local
    }

    /// Before Setup downloads the client: the folders it knows, kept with the install
    /// (CarryOver.prepare), so quitting mid-download does not lose them.
    private func carryOverPrepare() async {
        guard carriesOver, let i = active else { return }
        let known = carryHints + installs.map(\.gameDir)
        await Task.detached(priority: .userInitiated) { CarryOver.prepare(i, known: known) }.value
    }

    /// CarryOver for the install in use, off the main thread: right after Setup downloaded its
    /// client (`.setup`), or before its first Play when Setup could not do it then (`.play`).
    /// One line in launcher.log when it did or decided anything; nothing on screen. Returns what
    /// it waits for, when it could not run.
    @discardableResult
    private func carryOver(_ trigger: CarryOver.Trigger) async -> CarryOver.Result.Wait? {
        guard carriesOver, let i = active, !carryingOver else { return nil }
        carryingOver = true
        defer { carryingOver = false }
        let known = carryHints + installs.map(\.gameDir)
        let r = await Task.detached(priority: .userInitiated) {
            CarryOver.automatic(trigger, dest: i, known: known)
        }.value
        if let line = r.line { runner.logFileOnly(line) }
        return r.waits
    }

    /// The one line Play shows instead of starting, when a pending carry-over could not run.
    static func carryOverBlocked(_ w: CarryOver.Result.Wait?) -> String? {
        switch w {
        case .game?: return "Close the other game first: your macros and settings are copied to this install before its first Play."
        case .launch?: return "Another launch is under way. Press Play again in a moment."
        case .other?, nil: return nil
        }
    }

    /// The chain's recheck: back once the newest checks are on screen. A job ending also
    /// rechecks (onChange of busy), and a newer recheck discards an older one's answer, so
    /// waiting for our own is not enough.
    private func recheckSettled() async {
        await recheckAsync()
        for _ in 0..<100 where checksInFlight > 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Setup step 1: where things go, asked before anything is written (Daniel, 2026-10-15:
    /// "i want to choose"). The one place a location is decided:
    ///
    /// - Nothing installed, the wrapper's drive gone, or HorizonXI's files on a drive that is gone
    ///   (`.install`, `.wrapperDrive`, `.wine` without a wrapper to fix, `.dataDrive` for the
    ///   worlds that play the wrapper's own client): the folder chooser, then the setup sheet
    ///   builds Wine and its Windows drive in "<chosen>/FFXI on Mac/", and that install becomes
    ///   the one used (the game downloads into it next). The old install is left as it is.
    /// - Only the selected wrapper's Wine missing, its drive there: Wine is replaced in place.
    /// - Another world's folder on a drive that is gone: the chooser, and its files go in
    ///   "<chosen>/FFXI on Mac/Games/<world>"; with no download route, the folder that holds them.
    /// - No folder chosen, or an ambiguous one: the folder that holds the world's files.
    ///
    /// Returns false when the user cancelled; nothing has been written then.
    private func setupLocationStep(_ need: PrimaryAction.SetupNeed) async -> Bool {
        guard let s = store.selected else { return false }
        switch need {
        case .wine where wineRepairTarget != nil:
            Bootstrap.target = wineRepairTarget
            return await runSetupSheet()
        case .install, .wrapperDrive, .wine:
            return await setupNewLocation()
        case .dataDrive where s.local || s.name == "HorizonXI":
            return await setupNewLocation()
        case .dataDrive where s.installKind != .none:
            guard let folder = LocationPanel.choose(
                title: "Where should \(s.name) go?",
                message: "\(s.name)'s game files go in “FFXI on Mac/Games/\(s.name)” inside the folder you choose. Any Mac-formatted drive works, external included.",
                prompt: "Put It Here", need: InstallLocation.Need.gameZip + InstallLocation.Need.gameUnpacked) else { return false }
            return setWorldData(s, in: folder)
        case .dataDrive, .chooseFolder:
            let before = s.dataPath
            chooseGameData(for: s)
            guard let now = store.servers.first(where: { $0.name == s.name }) else { return false }
            return !now.dataPath.isEmpty && now.dataPath != before
        default:
            return true
        }
    }

    /// The folder chooser, then Wine and its Windows drive built in "<chosen>/FFXI on Mac/", which
    /// becomes the install in use. False when either was cancelled (nothing written by the
    /// chooser; the sheet writes only after "Set it up").
    ///
    /// What is already in the chosen folder is used, never built or downloaded a second time
    /// (ExistingInstall; Daniel, 2026-10-15: "is it going to auto recognize that and continue
    /// setup based on the files there? or will it duplicate everything"):
    /// - a wrapper that holds HorizonXI (siku.app, an "FFXI on Mac" folder, the old
    ///   ~/Applications "FFXI on Mac Wine.app") becomes the install in use; the sheet runs only
    ///   when its Wine or Windows drive is missing, and the chain does only what else is missing;
    /// - a HorizonXI or SquareEnix folder on its own is moved into the install (same drive) or
    ///   copied, keeping the original (another drive), on "Use Them";
    /// - files behind a drive that is gone are never touched: "Download Fresh" puts a new copy in
    ///   the chosen folder.
    private func setupNewLocation(adoptAlways: Bool = true) async -> Bool {
        let latest = feeds.horizonLatest
        let gameWineFound = X87Sidecar.patchedWine() != nil
        let need: (ExistingInstall.Found?) -> Int64 = { ExistingInstall.need($0, gameWineElsewhere: gameWineFound, latest: latest) }
        guard let choice = LocationPanel.chooseForSetup(
            title: "Where should FFXI on Mac go?",
            message: "Everything goes in one folder, “FFXI on Mac”, inside the folder you choose: Wine, its Windows drive and the game. A folder that already holds HorizonXI is used as it is. Any Mac-formatted drive works, external included.",
            prompt: "Set Up Here", need: need) else { return false }
        var found = choice.found
        // Files behind a drive that is gone: never touched. A fresh copy here, on a yes.
        if let f = found, let d = f.unreachableDrive {
            guard ask("HorizonXI here is on the '\(d)' drive, which isn't connected.",
                      "Setup can download a fresh copy into “\(f.home.path)” instead. Nothing on the '\(d)' drive is changed.",
                      yes: "Download Fresh", no: "Cancel") else { return false }
            found = ExistingInstall.fresh(f)
            if let c = f.client { carryHints.append(c.url) }
        }
        // A HorizonXI (or SquareEnix) folder on its own: moved or copied in, on a yes.
        var bring: ExistingInstall.Client?
        if let f = found, let c = f.client, !f.clientInWrapper {
            let what = c.squareEnixOnly ? "FINAL FANTASY XI files" : "HorizonXI files"
            if ask("Use the \(what) already here?",
                   (c.sameVolume ? "They'll be moved into FFXI on Mac, not copied:"
                                 : "They're on another drive, so they'll be copied into FFXI on Mac; the originals stay where they are:")
                   + "\n\n\(c.url.path)", yes: "Use Them", no: "Download Fresh") {
                bring = c
            } else {
                found = ExistingInstall.fresh(f)
                carryHints.append(c.url)
            }
        }
        let home = found?.home ?? choice.folder
        if bring == nil, let f = found, !f.clientInWrapper {
            // Download Fresh needs the full room: said now, before anything is written.
            var at = home.standardizedFileURL
            while !FileManager.default.fileExists(atPath: at.path), at.path != "/" { at = at.deletingLastPathComponent() }
            let v = InstallLocation.verdict(InstallLocation.facts(for: at), need: need(found))
            if !v.isOK { notice = v.line; return false }
        }
        if let f = found {
            runner.logFileOnly("==> Setup found in \(home.path): \(f.line)")
            if let w = f.wrapper, Bootstrap.isBuilt(w.wrapper), FileManager.default.fileExists(atPath: w.systemReg.path) {
                setupMeter.meter.drop(.wine)
            }
            if f.gameWine != nil { setupMeter.meter.drop(.gameWine) }
            if let c = f.client, c.complete, !c.squareEnixOnly, f.clientInWrapper || bring != nil,
               let v = c.version, let l = latest, !Primary.isNewer(l, than: v) {
                setupMeter.meter.drop(.game)
            }
            if bring != nil { setupMeter.meter.plan(.files) }
        }
        // Wine and its Windows drive: the found wrapper's when it has them, else built here.
        let install = found?.wrapper ?? InstallLocation.install(in: home)
        if !Bootstrap.isBuilt(install.wrapper) || !FileManager.default.fileExists(atPath: install.systemReg.path) {
            Bootstrap.target = install.wrapper
            guard await runSetupSheet() else { return false }
        }
        InstallLocation.remember(home)
        if let c = bring {
            setupStep(.files)
            guard await bringIn(c, to: install) else { return false }
        }
        // Install dependencies… beside an install that already has the game keeps that one in
        // use (G11); the folder button switches to the new one.
        if adoptAlways || selected?.hasGame != true {
            install.remember()
            installs = Install.dedupe([install] + installs.filter { $0.id != install.id }, keep: install.id)
            selected = install
            forgetUnreachableData()
        }
        return true
    }

    /// One question, two answers; true for `yes`.
    private func ask(_ message: String, _ info: String, yes: String, no: String) -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.addButton(withTitle: yes)
        a.addButton(withTitle: no)
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Setup's step: a client found on its own goes into `install` -- one rename on the same drive
    /// (ExistingInstall.moveIn), or a verified copy from another drive that keeps the original
    /// (Runner.copyIn) -- and any world's folder setting that named it follows it.
    private func bringIn(_ c: ExistingInstall.Client, to i: Install) async -> Bool {
        let dest = ExistingInstall.destination(for: c, in: i)
        if c.sameVolume {
            do {
                try ExistingInstall.moveIn(c, to: i, log: { runner.logFileOnly("==> " + $0) })
            } catch {
                let line = (error as? InstallMove.Refusal)?.line ?? error.localizedDescription
                runner.appendLine("!! " + line)
                notice = line
                return false
            }
        } else {
            let ok = await withCheckedContinuation { cont in runner.copyIn(c.url, to: dest) { cont.resume(returning: $0) } }
            guard ok else { return false }
        }
        let classic = i.driveC.appendingPathComponent("HorizonXI")
        for srv in store.servers {
            if let p = ExistingInstall.rewritten(srv.dataPath, from: c.url, to: dest,
                                                 classic: srv.local || srv.name == "HorizonXI" ? classic : nil) {
                var s = srv; s.dataPath = p; store.update(s)
            }
        }
        return true
    }

    /// The worlds that play the wrapper's own client (HorizonXI, the local server), pointed back at
    /// it when their folder setting names files behind a drive that is gone or no longer there:
    /// Setup set up the wrapper's own, and the old setting would keep the button on Setup.
    private func forgetUnreachableData() {
        let fm = FileManager.default
        for srv in store.servers where (srv.local || srv.name == "HorizonXI") && !srv.dataPath.isEmpty {
            guard Preflight.unavailableDrive(for: srv.dataPath) != nil || !fm.fileExists(atPath: srv.dataPath) else { continue }
            runner.logFileOnly("==> \(srv.name)'s game folder \(srv.dataPath) isn't there; it plays the install's own now")
            var s = srv; s.dataPath = ""; store.update(s)
        }
    }

    private func runSetupSheet() async -> Bool {
        showSetup = true
        return await setupSheetWaiter.wait()
    }

    /// Setup & Diagnostics › Install dependencies…: Wine replaced in place when only the selected
    /// wrapper's Wine is missing, else a new install where the user chooses.
    private func installDependencies() async {
        if let w = wineRepairTarget {
            Bootstrap.target = w
            guard await runSetupSheet() else { return }
        } else {
            guard await setupNewLocation(adoptAlways: false) else { return }
        }
        await refreshAsync()
    }

    /// A world other than HorizonXI with no folder yet: "<FFXI on Mac>/Games/<world>" in the
    /// folder already chosen, or one the user chooses now. False when cancelled.
    /// AscensionXI's job (Runner.syncAscension) in its client folder, which is chosen first the
    /// way every world's is (placeWorldData). Other worlds' clients are offered as donors of
    /// identical files only when every file is going to be checked anyway (Setup, Repair, or a
    /// folder no update has run in yet).
    private func worldJob(for s: Server, install i: Install, full: Bool, runner r: Runner,
                          done: @escaping (AscensionSync.Outcome) -> Void) {
        var w = s
        if w.dataPath.isEmpty {
            guard placeWorldData(for: w), let again = store.servers.first(where: { $0.name == w.name }),
                  !again.dataPath.isEmpty else { done(.failed("No folder chosen for \(w.name).")); return }
            w = again
        }
        let root = URL(fileURLWithPath: w.dataPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if w.installKind == .vanadreamsPackage { r.syncVanadreams(root: root, install: full, done: done); return }
        if w.installKind == .pegasusPack { r.syncPegasus(root: root, install: full, done: done); return }
        if w.installKind == .scytheChannel {
            r.syncScythe(root: root, install: full,
                         donors: AscensionChannel.donorClients(store.servers.filter { $0.name != w.name }, base: i), done: done)
            return
        }
        if w.installKind == .retailWorld, let spec = RetailWorld.spec(w.name) {
            r.syncRetailWorld(spec, root: root, install: full,
                              donors: AscensionChannel.donorClients(store.servers.filter { $0.name != w.name }, base: i), done: done)
            return
        }
        if w.installKind == .driftwoodContent {
            // Every file of their list is checked against the cache on each run, so donors are offered always.
            r.syncDriftwood(root: root, install: full, donors: AscensionChannel.donorClients(store.servers.filter { $0.name != w.name }, base: i),
                            done: done)
            return
        }
        let dats = Install.winePath(root.appendingPathComponent("Ashita/polplugins/DATs"), driveC: i.driveC)
        let checksAll = full || !FileManager.default.fileExists(atPath: root.appendingPathComponent(".base-manifest.json").path)
        let donors = checksAll ? AscensionChannel.donorClients(store.servers.filter { $0.name != w.name }, base: i) : []
        r.syncAscension(root: root, datsWine: dats, install: full, donors: donors, done: done)
    }

    private func placeWorldData(for s: Server) -> Bool {
        if let folder = InstallLocation.remembered,
           FileManager.default.fileExists(atPath: folder.path),
           InstallLocation.verdict(InstallLocation.facts(for: folder), need: 0).isOK {
            return setWorldData(s, in: folder)
        }
        guard let folder = LocationPanel.choose(
            title: "Where should \(s.name) go?",
            message: "\(s.name)'s game files go in “FFXI on Mac/Games/\(s.name)” inside the folder you choose. Any Mac-formatted drive works, external included.",
            prompt: "Put It Here", need: InstallLocation.Need.gameZip + InstallLocation.Need.gameUnpacked) else { return false }
        if InstallLocation.remembered == nil { InstallLocation.remember(folder) }
        return setWorldData(s, in: folder)
    }

    private func setWorldData(_ s: Server, in folder: URL) -> Bool {
        let dir = InstallLocation.worldData(s.name, in: folder)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { notice = "Couldn't make a folder in \(folder.lastPathComponent)."; return false }
        guard var c = store.servers.first(where: { $0.name == s.name }) else { return false }
        c.dataPath = dir.path
        store.update(c)
        recheck()
        return true
    }

    /// Setup's Rosetta 2 on its own (an install whose Wine is there, on a Mac without Rosetta: a
    /// new Mac set up from a backup). macOS's own administrator prompt; never Terminal.
    private func setupRosettaStep(_ r: Runner) async -> Bool {
        r.appendLine("==> installing Rosetta 2")
        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try await Bootstrap.ensureRosetta(log: { line in Task { @MainActor in r.logFileOnly(line) } })
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let why = failure { r.appendLine("!! " + why); return false }
        return true
    }

    /// Setup step 3: the game's Wine (scripts/game-wine.sh) into the "FFXI on Mac" folder the
    /// user chose. An install made before b60 has no chosen folder (or its drive is gone, or it
    /// has no room): the chooser asks where, and that becomes the folder, which is where
    /// `X87Sidecar.patchedWine` looks first. False when cancelled or when the download failed
    /// (its own "!!" line says why; the next press resumes it).
    private func setupGameWineStep(_ r: Runner) async -> Bool {
        let fm = FileManager.default
        var folder = InstallLocation.remembered
        if let f = folder, !fm.fileExists(atPath: f.path)
            || !InstallLocation.verdict(InstallLocation.facts(for: f), need: InstallLocation.Need.gameWine).isOK {
            folder = nil
        }
        if folder == nil {
            guard let chosen = LocationPanel.choose(
                title: "Where should the game's Wine go?",
                message: "It goes in “FFXI on Mac/wine-coop” inside the folder you choose. Any Mac-formatted drive works, external included.",
                prompt: "Put It Here", need: InstallLocation.Need.gameWine) else { return false }
            folder = chosen
        }
        guard let folder else { return false }
        InstallLocation.remember(folder)
        return await withCheckedContinuation { c in
            r.installGameWine(into: folder) { ok in c.resume(returning: ok) }
        }
    }

    /// Setup step 4: the game files. HorizonXI's (and the local world's, which plays HorizonXI's
    /// client) come by torrent with progress on the button; another world's come from its own
    /// installer, which runs on and is picked up by the recheck when it ends.
    private func setupGameStep(_ r: Runner) async -> Bool {
        guard let s = store.selected, let i = active else { return false }
        if s.installKind == .horizonTorrent || s.local {
            return await withCheckedContinuation { c in
                r.installHorizon(into: i.gameDir) { ok in c.resume(returning: ok) }
            }
        }
        if s.installKind.updatesBeforePlay {
            return await withCheckedContinuation { c in
                worldJob(for: s, install: i, full: true, runner: r) { outcome in
                    switch outcome {
                    case .ok: c.resume(returning: true)
                    case .offline(let why):
                        // Setup and Repair check every file: an unreachable channel checked nothing.
                        r.appendLine("!! " + why.replacingOccurrences(of: "; playing with the files from the last update", with: ""))
                        c.resume(returning: false)
                    case .stopped, .failed: c.resume(returning: false)
                    }
                }
            }
        }
        if s.installKind == .website {
            // Their page is the only source. The first press opens it; once the installer is
            // downloaded, the next press runs it inside the wrapper.
            if websiteOpened.contains(s.name) {
                runLocalInstaller(for: s, install: i)
            } else {
                websiteOpened.insert(s.name)
                downloadGameData(for: s, install: i)
                info("\(s.name)'s download page is open. When it has downloaded, press Setup again.")
            }
            return false
        }
        downloadGameData(for: s, install: i)
        return false
    }

    /// Setup step 5: registry, COM and Wine's library links (install.sh, with Play's Wine).
    private func setupConfigureStep(_ r: Runner) async -> Bool {
        guard let i = active else { return false }
        return await withCheckedContinuation { c in r.repair(i) { ok in c.resume(returning: ok) } }
    }

    /// Setup step 6: the local world's server (lsb-server.sh setup).
    private func setupLocalServerStep(_ r: Runner) async -> Bool {
        guard !local.busy, let st = local.status, !(st.belowFloor && !forceSetup) else { return false }
        return await withCheckedContinuation { c in
            local.setup(force: st.belowFloor && forceSetup, log: { r.appendLine($0) }) { ok in c.resume(returning: ok) }
        }
    }

    /// Setup repairs the selected wrapper when that is the one whose wine is missing, instead
    /// of building a second, empty wrapper and switching to it (G11). A wrapper whose drive is
    /// gone is never the target: a new one is built where the user chooses.
    private var wineRepairTarget: URL? {
        let fm = FileManager.default
        guard let i = selected, !fm.isExecutableFile(atPath: i.wine.path),
              Preflight.unavailableDrive(for: i.wrapper.path) == nil,
              fm.fileExists(atPath: i.sharedSupport.path) else { return nil }
        return i.wrapper
    }

    // MARK: - Move…

    /// Move…: from Setup & Diagnostics, and beside the main button's Setup line when the game's
    /// files are on another drive than Wine. Refuses while anything runs; measures the install
    /// (read-only; a drive that is gone is said in one line, and nothing happens); asks where,
    /// with the same checks as Setup plus room for exactly what it copies; then copies, verifies
    /// and switches (InstallMove, Runner.moveInstall), with "Moving… N%" on the button.
    private func startMove() {
        guard let i = active, let s = store.selected, !moveChecking else { return }
        let jobs = runner.busy || Runner.workInFlight || setupRunning
        let before = InstallMove.Activity(
            clientsLive: !sessions.live.isEmpty || !sessions.elsewhere.isEmpty,
            job: jobs ? (Runner.workInFlightReason ?? "a job") : nil,
            localServer: local.busy || LocalServer.workInFlight || local.status?.running == true,
            wineRunning: WineserverStopWait.anyStuck)
        if let why = InstallMove.blocker(before) { notice = why; return }
        notice = ""
        moveChecking = true
        Task {
            let (planned, wine, clients) = await Task.detached(priority: .userInitiated) {
                (Result { try InstallMove.plan(i, world: s.name) }, InstallMove.anyWineserver(), !LiveClients.scan().isEmpty)
            }.value
            // The local server answers on its login port while it runs, whichever world is picked.
            let server = await LocalServer.localLoginPortResponds()
            moveChecking = false
            if let why = InstallMove.blocker(.init(clientsLive: clients, localServer: server, wineRunning: wine)) {
                notice = why; return
            }
            let plan: InstallMove.Plan
            switch planned {
            case .success(let p): plan = p
            case .failure(let e): notice = (e as? InstallMove.Refusal)?.line ?? e.localizedDescription; return
            }
            guard let folder = LocationPanel.choose(
                title: "Move FFXI on Mac",
                message: "Wine, its Windows drive and the game are copied into one folder, “FFXI on Mac”, inside the folder you choose. The old copy stays until you say otherwise.",
                prompt: "Move Here", need: plan.bytes,
                extra: { InstallMove.destinationProblem($0, plan: plan) }) else { return }
            runner.moveInstall(plan, into: folder) { moved in
                guard let moved else { recheck(); return }
                finishMove(plan, moved: moved, folder: folder)
            }
        }
    }

    /// The copy is verified and in place: use it, then ask once about the old copy. It goes to
    /// the Trash only on a yes; nothing is ever removed outright.
    private func finishMove(_ plan: InstallMove.Plan, moved: Install, folder: URL) {
        for srv in store.servers {
            if let p = InstallMove.rewrittenDataPath(srv.dataPath, world: srv.name, plan: plan, folder: folder) {
                var c = srv; c.dataPath = p; store.update(c)
            }
        }
        InstallLocation.remember(folder)
        moved.remember()
        installs = [moved] + installs.filter { $0.id != moved.id }
        selected = moved
        recheck()
        // Never anything that holds the new copy.
        let newPath = folder.standardizedFileURL.path
        let old = plan.oldCopy.filter { u in
            let p = u.standardizedFileURL.path
            return p != newPath && !newPath.hasPrefix(p + "/") && !p.hasPrefix(newPath + "/")
        }
        guard !old.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "The game now plays from “\(folder.path)”."
        alert.informativeText = "The old copy is still here:\n\n" + old.map(\.path).joined(separator: "\n")
            + "\n\nMove it to the Trash?"
        alert.addButton(withTitle: "Keep It")
        alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        var failed: [String] = []
        for u in old {
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: nil)
                runner.logFileOnly("==> old copy moved to the Trash: \(u.path)")
            } catch {
                runner.logFileOnly("!! couldn't move \(u.path) to the Trash: \(error.localizedDescription)")
                failed.append(u.lastPathComponent)
            }
        }
        if !failed.isEmpty { notice = "Some of the old copy couldn't go to the Trash: \(failed.joined(separator: ", "))." }
        refresh()
    }

    /// Every world playing right now, each with its own Stop. Stopping one never stops another.
    @ViewBuilder private var runningList: some View {
        // The selected world's own client is left out only while the main button is its Stop:
        // not while it says "Starting…", nor on a world that allows a second client, whose
        // button is Play Another -- its first client's Stop is here. By the session the button
        // acts on: b70's Force Stop can be the Stop of a second client ("Local server #2"), and
        // its "Stopping…" stands for it too.
        let p = primary.action
        let own = p == .stop || (p == .working(.stopping, progress: nil) && runner.stoppingGame) ? runner.session : nil
        let live = sessions.live.filter { $0.id != own }
        if !live.isEmpty || !elsewhere.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("RUNNING").font(.system(size: 12)).tracking(2).foregroundStyle(Vana.muted)
                ForEach(live, id: \.id) { s in
                    HStack(spacing: 6) {
                        Circle().fill(Vana.crystal).frame(width: 6, height: 6)
                        Text(s.id).font(.system(size: 12)).foregroundStyle(Vana.text)
                        Spacer()
                        Button(s.runner.stoppingGame ? "Stopping…" : s.runner.serverLost ? "Force Stop" : "Stop") {
                            s.runner.stop(force: s.runner.serverLost)
                            Task { await refreshElsewhere() }
                        }
                            .disabled(s.runner.stoppingGame)
                            .font(.system(size: 12))
                            .help("Ends \(s.id)'s client only. Other worlds keep running.")
                    }
                }
                ForEach(elsewhere, id: \.host) { e in
                    HStack(spacing: 6) {
                        Circle().fill(Vana.muted).frame(width: 6, height: 6)
                        Text(e.name).font(.system(size: 12)).foregroundStyle(Vana.text)
                            .help("Started outside this window (pid \(e.pids.map(String.init).joined(separator: ","))). Stop it from there.")
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Actions

    /// `--world` and `--play`, from this launch's own command line or handed over by a later
    /// launch (SingleInstance): one path, so a forwarded --play goes through Sessions, the
    /// duplicate rule and every gate exactly as its own would.
    private func handleCommand(_ cmd: LaunchCommand, forwarded: Bool) async {
        let from = forwarded ? " (handed over by another launch)" : ""
        if let w = cmd.world {
            guard let srv = store.servers.first(where: { $0.name == w }) else {
                // Never fall through to the world that happens to be selected.
                runner.appendLine("!! --world\(from): no world named \(w)"
                                  + (cmd.play ? "; --play not carried out" : ""))
                return
            }
            store.select(srv)
        }
        guard cmd.play else { return }
        if updateInstalling {
            runner.logFileOnly("!! --play\(from): not carried out, the launcher is restarting to update")
            return
        }
        if selected == nil { runner.appendLine("!! --play\(from): no install found yet") }
        else if runner.running, store.selected?.allowsMultipleClients != true {
            runner.appendLine("!! --play\(from): \(store.selected?.name ?? "this world") is already running in this launcher")
        }
        else {
            // Selecting the world that was already selected changes nothing, so the account saved
            // for it since the window opened was never read (b71, 2026-10-24: "--play --world
            // AscensionXI" went in with empty fields). Read it here when the field is empty.
            if user.isEmpty, let s = store.selected, !s.local { user = Credentials.username(forWorld: s.name) }
            if remember, !user.isEmpty, pass.isEmpty { pass = Credentials.password(for: user, world: store.selected?.name ?? "") }
            await recheckAsync()
            if store.selected?.local == true {
                // A refresh may already be in flight from onAppear; either way, wait
                // for a verdict (bounded) rather than refusing on a status that is nil.
                await local.refreshAsync()
                for _ in 0..<60 where local.status == nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            runner.appendLine("==> --play\(from): \(store.selected?.name ?? "?") as \(user.isEmpty ? "(no account)" : user)")
            if carriesOver, let i = active, CarryOver.isPending(i) {
                let why = carryingOver ? "macros and settings are being copied to this install"
                                       : Self.carryOverBlocked(await carryOver(.play))
                if let why {
                    runner.logFileOnly("!! --play\(from): not carried out: \(why)")
                    return
                }
            }
            play()
            if !notice.isEmpty { runner.logFileOnly("!! \(notice)") }
        }
    }

    /// Act on every handed-over request, one at a time and in order.
    private func runForwarded() async {
        guard !forwardRunning else { return }
        forwardRunning = true
        defer { forwardRunning = false }
        while let cmd = SingleInstance.takePending() {
            await handleCommand(cmd, forwarded: true)
        }
    }

    private func play() {
        if let why = store.selected?.launchUnavailableReason { notice = why; return }
        guard let i = active else { return }
        // Only a handed-over --play gets here (the button says "Updating…"); the launcher is about to quit.
        if updateInstalling {
            runner.logFileOnly("!! not playing: the launcher is restarting to update")
            return
        }
        if runner.busy || setupRunning || preparingMultiServer {
            // Only a forwarded --play gets here (the button is the job's progress); not an error to keep.
            info("Wait for the install/update to finish")
            runner.logFileOnly("!! " + notice)
            return
        }
        notice = ""
        playWarnings = []
        runner.clearLog()
        localServerSlowing = false
        updateChecked = false
        Credentials.setUsername(user, forWorld: store.selected?.name ?? "")
        if guideWithPlay, Guide.companionURL != nil {
            Guide.openCompanion(world: store.selected?.name ?? "", worlds: orderedServers.map(\.name), activate: false)
        } else {
            Guide.shareSession(world: store.selected?.name ?? "", worlds: orderedServers.map(\.name))
        }
        Credentials.remember = remember
        if remember { Credentials.savePassword(pass, for: user, world: store.selected?.name ?? "") }
        else { Credentials.savePassword("", for: user, world: store.selected?.name ?? "") }

        let server = store.selected ?? Server.builtins[0]
        guard !server.host.isEmpty else {
            notice = "No login host for \(server.name)"
            runner.logFileOnly("!! " + notice)
            return
        }
        // Checked against the processes, not only this window's sessions: a client started by
        // another launcher (or by --play) counts just the same.
        let hosts = [server.host] + [Credentials.bootServer(in: i, profile: server.bootProfile)].compactMap { $0 }
        if let why = Runner.duplicateRefusal(world: server.name, hosts: hosts, maxClients: server.maxClients,
                                             clients: LiveClients.snapshot().clients, install: i) {
            notice = why
            runner.logFileOnly("!! " + why)
            return
        }
        if runner.running, !server.allowsMultipleClients {
            notice = "\(server.name) allows one client"
            runner.logFileOnly("!! " + notice)
            return
        }
        let r = runner.running ? sessions.newSession(for: server.name) : runner


        // The local world has to be running before the client can reach it. Start it here rather
        // than making the user press two buttons in the right order — but never build from Play,
        // because a first build is a half-hour job the user should be choosing deliberately.
        if server.local {
            guard let s = local.status, s.ready else {
                if local.status == nil { info("Still checking the local server") }
                else { notice = "The local server isn't set up yet — press Setup." }
                return
            }
            if !s.running {
                local.start(log: { r.appendLine($0) }) { ok in
                    if ok { launchClient(i, server: server, runner: r) }
                    else { notice = "Local server didn't start — Open log in Setup & Diagnostics" }
                }
                return
            }
        }
        launchClient(i, server: server, runner: r)
    }

    private func launchClient(_ i: Install, server: Server, runner r: Runner, synced: Bool = false) {
        if let why = server.launchUnavailableReason { notice = why; return }
        // Restart was pressed while the local server was starting for this launch.
        if updateInstalling {
            r.logFileOnly("!! not playing: the launcher is restarting to update")
            return
        }
        // Two servers on the list publish no login host anywhere this project could find. Ashita
        // would take `--server ` with nothing after it and fail somewhere less obvious, so say
        // what is actually missing instead.
        if server.host.trimmingCharacters(in: .whitespaces).isEmpty {
            notice = "No login host for \(server.name)"
            r.logFileOnly("!! " + notice)
            return
        }
        guard WorldPrefix.ready(i) else {
            notice = "Set up multi-server play before starting \(server.name)."
            r.logFileOnly("!! " + notice)
            recheck()
            return
        }
        // A world the install has no boot profile for — the local one, on every machine — needs
        // that file to exist before anything can be written into it.
        if !Credentials.ensureProfile(server.bootProfile, in: i, loader: server.loader,
                                      template: server.bootTemplate, host: server.host, world: server.name) {
            notice = "Could not create config/boot/\(server.bootProfile)."
            r.logFileOnly("!! " + notice)
            return
        }
        // A world may need a different renderer than the global preference (Gaia XI: DXVK kills
        // its client, OpenGL boots it). Applied here rather than by mutating the user's setting,
        // so switching worlds never silently rewrites what they chose.
        var effective = perf
        if !server.msync, effective.msync {
            effective.msync = false
            r.appendLine("i  \(server.name) runs with msync off — its client exits about a "
                         + "second after login with it on.")
        }
        if let pinned = server.renderer, pinned != perf.renderer {
            effective.renderer = pinned
            r.appendLine("i  \(server.name) is pinned to the \(pinned.title) renderer "
                         + "(your setting, \(perf.renderer.title), is left alone). "
                         + "Clear it in the server's settings to override.")
        }
        // Every refusal before any shared client file is rewritten: pivot.ini and the boot
        // profile belong to whatever world is already running too.
        let launchGate = r.gate(i, renderer: effective.renderer,
                            sync: MultiWorld.syncMode(msync: effective.msync, esync: effective.esync),
                            msyncAllowed: server.msync, profile: server.bootProfile,
                            world: server.name, host: server.host,
                            maxClients: server.maxClients)
        if let why = launchGate.refusal {
            notice = why
            r.logFileOnly("!! " + why)
            return
        }

        // The world's own update, before every Play, as its own launcher does it (AscensionSync,
        // VanadreamsSync): whatever the client, DATs, addons and loader changed. Seconds when nothing did;
        // the button shows "Updating…" while it runs. After the gate, so a Play that would be
        // refused anyway (another world's registry live) downloads nothing first.
        if server.installKind.updatesBeforePlay, !synced, !launchGate.gameFilesLive {
            worldJob(for: server, install: i, full: false, runner: r) { outcome in
                switch outcome {
                case .ok, .offline: break
                case .stopped: return
                case .failed(let why): notice = why; return
                }
                // Another world picked while it updated: the window's account fields now hold that
                // world's login, which must never go to AscensionXI's server (b71 review). Play again.
                guard store.selectedID == server.name else {
                    r.logFileOnly("!! \(server.name) updated; not started, \(store.selectedID) was selected meanwhile")
                    return
                }
                // The Ashita folder is found again: a first update may have just created it.
                let now = store.servers.first { $0.name == server.name } ?? server
                launchClient((active ?? i).forServer(now), server: now, runner: r, synced: true)
            }
            return
        }

        // Pre-game version check. The login server does this anyway and answers "The game's
        // data has been updated" — better to say so here, name the versions, and (for HorizonXI,
        // whose updates are public) fix it before launching.
        let requiredVer = feeds.requiredClients[server.name] ?? server.requiredClient
        // Local LSB has no version lock. Reading patch.cfg on an external game volume can
        // block on macOS privacy access, so do not touch it unless there is a version to check.
        if !requiredVer.isEmpty,
           let have = ClientVersion.installed(in: i),
           ClientVersion.isOlder(have, than: requiredVer) {
            notice = "\(server.name) needs client \(requiredVer); you have \(have)."
            r.logFileOnly("!! " + notice)
            return
        }
        // HorizonXI being a version behind is not a reason to refuse Play: its login server
        // accepts it. The banner offers the update when there is one; nothing is said here.

        // Written only once `launch` holds the lock and its gate has passed again, so a launch
        // refused there (another launcher got in first) rewrites nothing another world is using.
        let account = (user: user, pass: pass)
        let writeShared = {
            // The client was installed by HorizonXI and carries their logo in its own data. On
            // any other world, show the stock title screen instead. See Branding.swift.
            Branding.apply(stockBranding: Branding.wantsStockBranding(server), to: i)
            // The world's loader and the settings its profile needs (b61): a HorizonXI profile
            // copied from Ashita's example booted pol.exe and sat at its account menu. Fixed here,
            // on every Play, so nothing ever has to say so or wait for the user.
            for line in Credentials.prepareProfile(for: server, in: i) { r.logFileOnly("i  " + line) }
            if !account.user.isEmpty, !account.pass.isEmpty {
                if !Credentials.apply(user: account.user, password: account.pass, to: i,
                                      profile: server.bootProfile, server: server.host,
                                      options: server.loaderOptions) {
                    notice = "Could not write config/boot/\(server.bootProfile) — launching with its existing account."
                    r.logFileOnly("!! " + notice)
                    if i.gameDir.path.hasPrefix("/Volumes/") {
                        r.logFileOnly("i  Note: If external volume access is restricted by macOS, grant Full Disk Access to FFXI on Mac in System Settings › Privacy & Security › Full Disk Access.")
                    }
                }
            }
        }
        // What about the Mac will slow the game: Low Power Mode, memory (two clients plus LSB on
        // this 8 GB Mac is where frame rates collapse), heat. One line each, only when real, and
        // never a reason not to play.
        let warnings = PlayCheck.current(othersRunning: !LiveClients.scan().isEmpty)
        if let why = r.launch(i, perf: effective, profile: server.bootProfile, useX87: server.x87,
                              world: server.name, host: server.host,
                              maxClients: server.maxClients, msyncAllowed: server.msync,
                              addonPolicy: addonPolicy, beforeLaunch: writeShared) {
            notice = why
        } else {
            // Said about the game that is starting, so only once it is.
            playWarnings = warnings
            for w in warnings { r.logFileOnly("!! " + w) }
            // Fresh progress for this session, fetched by the launcher, never by the game.
            ra.refresh(.play, gameDir: i.gameDir, log: { r.appendLine($0) })
            if !server.local { checkLocalServerBeside(r) }
        }
    }

    /// A hosted world was just started while the local server (about 1 GB, and the measured cause
    /// of hosted stutter) is still up. Offer to stop it, unless a local client is playing on it.
    /// After the launch, off the main actor: a loopback connect and one process scan.
    private func checkLocalServerBeside(_ r: Runner) {
        let localWorlds = Set(store.servers.filter(\.local).map(\.name))
        Task {
            guard await LocalServer.localLoginPortResponds() else { return }
            let localClient = await Task.detached {
                LiveClients.snapshot().clients.contains { $0.host == "127.0.0.1" }
            }.value
            guard !localClient, !sessions.live.contains(where: { localWorlds.contains($0.world) }) else { return }
            // The game may already be gone (a client that died at start-up): nothing to slow.
            guard r.running else { return }
            localServerSlowing = true
            r.logFileOnly("!! " + PlayCheck.localServerLine)
        }
    }

    private func refresh() { Task { await refreshAsync() } }

    /// Point the launcher at a wrapper the scan cannot reach. Choosing it through a panel is
    /// also what grants access to a TCC-gated location such as Downloads, so this is the whole
    /// reason the scan itself does not need to go there.
    private func chooseInstall() {
        let panel = NSOpenPanel()
        panel.title = "Choose your HorizonXI wrapper"
        panel.message = "Pick the wrapper app that contains the game."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let found = Install.installs(inWrapper: url)
        guard !found.isEmpty else {
            notice = "No HorizonXI install inside \(url.lastPathComponent)"
            return
        }
        for i in found where !installs.contains(where: { $0.id == i.id }) { installs.append(i) }
        selected = found.first
        selected?.remember()
        recheck()
    }

    private func refreshAsync() async {
        // Use the install we used last time straight away. Scanning /Volumes can take a long
        // time on a slow external drive — long enough that the launcher never became usable —
        // and there is no reason to make the user wait for a path we already know.
        if selected == nil, let remembered = Install.remembered() {
            selected = remembered
            installs = [remembered]
            await recheckAsync()
        }

        scanning = true
        // One entry per set of game files (Install.dedupe), the one in use kept. The scan never
        // changes the install in use (InstallSelection): it is `install.last`, kept while its
        // drive is gone; only with no `install.last` is one picked from what was found.
        let keep = selected?.id, current = selected
        let (list, choice) = await Task.detached(priority: .userInitiated) { () -> ([Install], InstallSelection.Decision) in
            let found = Install.dedupe(Install.discover(), keep: keep)
            let choice = InstallSelection.resolve(current: current, found: { found })
            // The one in use is known even when the scan did not reach it (its wine is broken,
            // or it is outside the scanned folders).
            guard let c = choice.install, !found.contains(where: { $0.id == c.id }) else { return (found, choice) }
            return (Install.dedupe([c] + found, keep: c.id), choice)
        }.value
        scanning = false
        if let s = selected, s.id != keep {
            // Setup, Move… or the folder button chose an install while the scan ran: it is
            // `install.last` now, and stands over what the scan decided before that.
            installs = [s] + list.filter { $0.id != s.id }
        } else {
            installs = list
            selected = choice.install
            if case .adopted(let i) = choice {
                i.remember()
                runner.logFileOnly("==> install in use: \(i.wrapper.path) [\(i.prefixName)]")
            }
        }
        // The launcher's copy of DXVK's state cache starts from every cache the installs it knows
        // already hold (once; see DXVKStateCache.seedIfNeeded). Read-only on the installs.
        let known = installs, log = runner
        Task.detached(priority: .utility) {
            if let line = DXVKStateCache.seedIfNeeded(known) { await MainActor.run { log.logFileOnly(line) } }
        }
        await recheckAsync()
        if let i = selected { await runner.syncPrefixIfStale(i) }
    }

    private func recheck() { Task { await recheckAsync() } }

    /// Mount, unmount and activation rechecks: one at a time, the latest folded into a single rerun.
    private func autoRecheck() {
        // Nothing selected and no `install.last` (a first run): a drive coming back may bring an
        // install, which only a scan finds. With `install.last` set nothing else can be picked
        // (InstallSelection): the recheck looks at its own folder, off the main thread (a
        // spinning drive can take seconds to answer), and rescans once it is back.
        if selected == nil, !scanning, Install.lastChosen() == nil { refresh(); return }
        if checksInFlight > 0 { recheckPending = true; return }
        recheck()
    }

    private func recheckAsync() async {
        checksGeneration += 1
        let generation = checksGeneration
        guard let i = active else {
            checks = []; horizonInstalled = nil; probe = Primary.Probe(); checksWorld = nil
            // Nothing selected: if the remembered install is on a drive that is gone, the button
            // asks for that drive instead of offering a fresh setup (G6). Back on disk (its drive
            // came back), it is the install in use again, which the rescan takes up.
            let (r, back) = await Task.detached(priority: .userInitiated) {
                (Primary.rememberedDrive(), Install.remembered() != nil)
            }.value
            guard generation == checksGeneration else { return }
            rememberedDrive = r.map { (name: $0.0, state: $0.1) }
            if back, selected == nil, !scanning { refresh() }
            return
        }
        rememberedDrive = nil
        let world = store.selected?.name
        let profile = store.selected?.bootProfile ?? "horizonxi.ini"
        let horizon = world == "HorizonXI"
        let required = store.selected.map { feeds.requiredClients[$0.name] ?? $0.requiredClient } ?? ""
        let loader = store.selected?.loader ?? "", template = store.selected?.bootTemplate ?? ""
        checksInFlight += 1
        let p = await Task.detached(priority: .userInitiated) {
            Primary.probe(i, profile: profile, horizon: horizon, requiredClient: required,
                          loader: loader, template: template)
        }.value
        let (c, v) = (p.checks, p.horizonInstalled)
        checksInFlight -= 1
        if checksInFlight == 0, recheckPending { recheckPending = false; recheck() }
        // A newer recheck started meanwhile (world switched, drive mounted): its answer stands.
        guard generation == checksGeneration else { return }
        checks = c
        horizonInstalled = v
        probe = p
        checksWorld = world
    }

    /// A Play is between its press and the game window (or the 90 s fallback).
    private var launchUnderWay: Bool {
        forwardRunning || sessions.live.contains { $0.runner.starting }
    }

    /// Drop the play-time lines whose condition has ended.
    private func prunePlayWarnings() {
        guard !playWarnings.isEmpty else { return }
        let p = ProcessInfo.processInfo
        let left = PlayCheck.stillTrue(playWarnings, lowPower: p.isLowPowerModeEnabled, thermal: p.thermalState)
        if left != playWarnings { playWarnings = left }
    }

    /// Open the panel on whatever the profile actually says, not on this app's last write —
    /// the boot .ini is a plain text file the user may well have edited by hand.
    private func openGraphics() {
        // Prefer what the profile actually says; fall back to this world's stored value, not
        // to a value some other world last wrote. A key the profile lacks, or holds a value the
        // game does not have (an older build's 0018 = 4), shows the stored value.
        if let s = store.selected {
            graphics = GraphicsSettings.load(world: s.name)
            if let i = active, let onDisk = GraphicsSettings.read(from: i, profile: s.bootProfile, fallback: graphics) {
                graphics = onDisk
            }
        }
        showGraphics = true
    }

    private func openAddons() {
        guard let i = active else {
            // Silently doing nothing is indistinguishable from a broken button, and that is
            // exactly what it looked like: the addon screen "wouldn't open".
            notice = "No install selected — choose your wrapper with the folder button"
            return
        }
        showAddons = true
        scanAddons(i)
    }

    /// Fill the Addons… sheet from `i` off the main actor: the plugin and addon folders and the
    /// newest client log are slow to read on an external drive, and reading them first made the
    /// button look dead. The sheet shows a spinner until then and Apply waits for it. A result
    /// for a sheet that has been closed, or rescanned since, is dropped. `enabling` (an addon
    /// just fetched by Get) is switched on in the new list.
    private func scanAddons(_ i: Install, enabling: String? = nil) {
        addonScanGeneration &+= 1
        let generation = addonScanGeneration
        let profile = store.selected?.bootProfile ?? "horizonxi.ini"
        let policy = addonPolicy
        let key = AddonSuite.SheetKey(i, profile: profile, policy: policy)
        addonItems = []
        hiddenAddonCount = 0
        addonWarning = ""
        addonsScanning = true
        Task.detached(priority: .utility) {
            let found = AddonSuite.sheetContents(i, profile: profile, policy: policy)
            await MainActor.run {
                guard generation == addonScanGeneration, showAddons else { return }
                // The world, its folder or its server's list changed while this ran: the result is
                // not what the sheet now stands for, and Apply would write it there. Scan again.
                guard let now = active,
                      AddonSuite.SheetKey(now, profile: store.selected?.bootProfile ?? "horizonxi.ini",
                                          policy: addonPolicy) == key else {
                    rescanAddons()
                    return
                }
                addonItems = found.items
                hiddenAddonCount = found.hidden
                addonWarning = found.warning
                if let name = enabling,
                   let idx = addonItems.firstIndex(where: { !$0.isPlugin && $0.name.lowercased() == name }) {
                    addonItems[idx].enabled = true
                }
                addonsScanning = false
            }
        }
    }

    /// The open Addons… sheet, filled again for what is selected now (world, folder, server list).
    /// No install: an empty list, so the sheet's empty-list line says why; a scan still running
    /// for the old world is dropped.
    private func rescanAddons() {
        guard showAddons else { return }
        if let i = active { scanAddons(i); return }
        addonScanGeneration &+= 1
        addonItems = []
        hiddenAddonCount = 0
        addonWarning = ""
        addonsScanning = false
    }

    private func color(_ s: Check.State) -> Color {
        switch s {
        case .ok: return Vana.crystal
        case .warn: return Vana.gold
        case .bad: return Vana.ember
        }
    }
}

/// The left column's cards' measured height (`ContentView.hero`).
private struct CardsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
