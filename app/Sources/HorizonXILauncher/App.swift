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
    @State private var installs: [Install] = []
    @State private var selected: Install?
    /// The wrapper/prefix in `selected`, pointed at the chosen world's game folder.
    private var active: Install? {
        guard let i = selected else { return nil }
        return i.forServer(store.selected ?? Server.builtins[0])
    }
    @State private var checks: [Check] = []
    @State private var perf = PerfSettings.load()
    @StateObject private var sessions = Sessions()
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
    @State private var worldHover = false
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
    /// Setup's chain (runSetup) is running, and how far, for the button.
    @State private var setupRunning = false
    @State private var setupProgress: Double?
    /// The chain waits on the setup sheet through this.
    @State private var setupSheetWaiter = SheetWaiter()
    /// Worlds whose download page Setup opened this session: the next press runs the installer.
    @State private var websiteOpened: Set<String> = []
    /// Move… is measuring what it would copy (the button says "Checking…").
    @State private var moveChecking = false
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
        x.restartingLauncher = updateInstalling
        x.setupRunning = setupRunning
        x.setupProgress = runner.updatingHorizon ? runner.updateProgress : setupProgress
        if runner.busy { x.ownJob = runner.busyReason.isEmpty ? "Working" : runner.busyReason }
        else if x.isLocal, local.busy { x.ownJob = local.activity.isEmpty ? "setting up" : local.activity }
        else if moveChecking { x.ownJob = "Checking" }
        x.ownProgress = runner.updatingHorizon ? runner.updateProgress : runner.moveProgress
        if !runner.busy, Runner.workInFlight { x.otherJob = Runner.workInFlightReason ?? "Another job is running" }
        x.runningHere = runner.running
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
        .onAppear {
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
        }
        // Every job ends with fresh checks: a Download, Repair or Update that finished must turn
        // the button into the next step (or PLAY) without anyone pressing ↻.
        .onChange(of: runner.busy) { busy in if !busy { recheck() } }
        .onChange(of: local.busy) { busy in if !busy { recheck() } }
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
            guard !launchUnderWay, Date().timeIntervalSince(lastActivationRecheck) >= 5 else { return }
            lastActivationRecheck = Date()
            autoRecheck()
        }
        // Keep the players-online line current: on launch, whenever the world changes, and
        // every two minutes while the window is open. The fetch is three tiny GETs and silent
        // on failure, so this costs nothing when offline.
        .task { await feeds.refreshPopulations() }
        .onReceive(populationTick) { _ in
            Task { await feeds.refreshPopulations() }
            // RetroAchievements: gated to once per 10 minutes inside; a no-op until set up.
            ra.refresh(.automatic, gameDir: active?.gameDir, log: { runner.appendLine($0) })
        }
        // A later launch's --world/--play, handed over by SingleInstance.
        .onReceive(NotificationCenter.default.publisher(for: SingleInstance.arrived)) { _ in
            guard commandsReady else { return }   // the start-up task takes them in turn
            Task { await runForwarded() }
        }
        // Clients started by another launcher are only visible to a process scan. One `ps`.
        .task { await sessions.refreshElsewhere(install: active, profiles: bootProfiles) }
        .onReceive(elsewhereTick) { _ in
            guard NSApplication.shared.occlusionState.contains(.visible) else { return }
            Task { await sessions.refreshElsewhere(install: active, profiles: bootProfiles) }
        }
        // And at once when the window comes back into view, so the list is never 15 s stale.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeOcclusionStateNotification)) { _ in
            guard NSApplication.shared.occlusionState.contains(.visible) else { return }
            Task { await sessions.refreshElsewhere(install: active, profiles: bootProfiles) }
        }
        // Discovery walks /Volumes, and an external drive can make that take tens of seconds.
        // Doing it on the main thread means the window never appears at all — which looked
        // exactly like the app failing to launch. Scan off the main actor and fill the UI in.
        .task {
            // `--play` used to wait for the full volume scan below. After the game data moved
            // to the x10 (2.4 TB, spinning), that scan can run for many minutes, and the
            // launcher sat with no window and no log line — "it says it's running but it's
            // not". The remembered install is enough to play with; the scan only refreshes the
            // picker. So: fast path first, Play immediately, full scan afterwards.
            if selected == nil, let remembered = Install.remembered() {
                selected = remembered
                installs = [remembered]
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
                Text("FINAL FANTASY XI ON APPLE SILICON")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(3.5)
                    .foregroundStyle(Vana.gold)
                updateBanner
                populationLine
            }
            .padding(.horizontal, 34).padding(.top, 34).padding(.bottom, 20)

            // Scrolled rather than clipped: the cards below already overflow a 632pt window once
            // the signup list is open, and an overflowing VStack pushes the game's title off the
            // top of the window instead of cutting the bottom off.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    accountCard
                    localServerCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)

            if showDetails {
                ScrollView { statusList.padding(.horizontal, 34) }
                    .frame(maxHeight: 200)
            }
            logStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One dropdown for every server, kept next to the account fields since choosing a world and
    /// typing the account that logs into it are one decision, not two. HorizonXI is pinned to the
    /// top; the rest are ordered by community size, which is metadata the user never has to see
    /// or maintain. Sized for the 372pt sidebar column rather than the wide hero pane.
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
                ForEach(store.ordered) { s in
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
            SetupSheet { ok in
                if !setupSheetWaiter.finish(ok), ok { refresh() }
            }
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
            return "Vanaguide not found."
        }
        if !Guide.allowed(by: addonPolicy) {
            return "\(store.selected?.name ?? "This server") doesn't allow this addon."
        }
        return "Loads the Vanaguide quest guide in this world."
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

    /// Live players-online for the selected world. Only shown when the server publishes a
    /// counter (its own website's number); no counter, no line — never a 0.
    @ViewBuilder
    private var populationLine: some View {
        if let name = store.selected?.name, let n = feeds.populations[name] {
            HStack(spacing: 8) {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text("\(n.formatted()) online")
                    .font(.callout).foregroundStyle(Vana.muted)
            }
            .padding(.top, 2)
        }
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
                                            let all = AddonSuite.scan(i, profile: store.selected?.bootProfile ?? "horizonxi.ini")
                                            if addonPolicy.isRestricting {
                                                addonItems = all.filter { addonPolicy.allows($0.name) }
                                                hiddenAddonCount = all.count - addonItems.count
                                            } else {
                                                addonItems = all
                                                hiddenAddonCount = 0
                                            }
                                            if let idx = addonItems.firstIndex(where: {
                                                !$0.isPlugin && $0.name.lowercased() == e.name }) {
                                                addonItems[idx].enabled = true
                                            }
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

            HStack {
                // "All" means all the ones this server permits. Enabling something the server
                // forbids is not a convenience, it is a ban.
                Button("Enable all") {
                    for i in addonItems.indices where addonPolicy.allows(addonItems[i].name) {
                        addonItems[i].enabled = true
                    }
                }
                Button("Disable all") {
                    for i in addonItems.indices { addonItems[i].enabled = false }
                }
                Spacer()
                Button("Cancel") { showAddons = false }
                Button("Apply") {
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
                    if let i = active,
                       !AddonSuite.write(itemsToWrite, to: i,
                                         profile: store.selected?.bootProfile ?? "horizonxi.ini") {
                        notice = "Could not write the active boot script — its launcher markers are missing."
                    }
                    showAddons = false
                }
                .keyboardShortcut(.defaultAction)
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
                ForEach(0...4, id: \.self) { Text($0 == 0 ? "Off" : String($0)).tag($0) }
            }
            .help("Smooths distant textures. Higher values use stronger filtering.")
            Picker("Textures", selection: $graphics.textureCompression) {
                Text("Uncompressed").tag(0)
                Text("Compressed").tag(2)
            }
            .help("Compressed uses less graphics memory; uncompressed preserves texture quality.")
            Toggle("Bump mapping", isOn: $graphics.bumpMapping)
                .help("Adds raised-looking detail to some surfaces.")
            Toggle("Environmental animation", isOn: $graphics.environmentAnimation)
                .help("Animates effects such as water and weather.")
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
                        Credentials.ensureProfile(s.bootProfile, in: i)
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
            }
            .padding(14)
            .frame(maxWidth: 500, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Vana.stroke))
            .padding(.horizontal, 34).padding(.top, 16)
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
        // Scrolls rather than clips: with two prefixes found the install picker appears, and
        // together with a long notice the column outgrew a 632pt window and lost its top edge.
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

            if installs.count > 1 {
                Picker("", selection: Binding(
                    get: { selected?.id ?? "" },
                    set: { id in selected = installs.first { $0.id == id }; recheck() })
                ) {
                    ForEach(installs) { i in
                        Text("\(i.wrapper.lastPathComponent) · \(i.prefixName)").tag(i.id)
                    }
                }
                .labelsHidden()
            }

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
                    Toggle("Read cutscenes aloud (VanaVoice)", isOn: $perf.narrateCutscenes)
                        .disabled(!Narration.isAvailable || !Narration.allowed(by: addonPolicy))
                        .help(narrationHelp)
                    Toggle("Quest guide (Vanaguide, local LSB only)", isOn: $perf.enableVanaguide)
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
                        Button("Move…") { startMove() }
                            .disabled(active == nil || runner.busy || setupRunning || moveChecking)
                            .help("Copies Wine, its Windows drive and the game into one folder you choose. The old copy stays until you say otherwise.")
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
                // The running job's own Stop, beside its progress (it used to sit in a banner,
                // and the installers' in Setup & Diagnostics).
                if runner.updatingHorizon {
                    Button("Stop") { runner.stopHorizonUpdate() }
                        .controlSize(.small)
                        .help("Stops the download. Press the button again later to resume.")
                } else if runner.busy, runner.busyReason.hasPrefix("Installing") || runner.busyReason.hasPrefix("Running") {
                    Button("Stop") { if let i = active { runner.cancelInstaller(i) } }
                        .controlSize(.small)
                        .help("Stops the installer running inside the wrapper.")
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
                    // The game's files on another drive than Wine: offer to bring them together.
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
            // Registry and COM entries Preflight found missing are written by Play itself
            // (GameRegistry.point); forget its cache so it really does write them. Never under a
            // running client: its registry must not change (Runner.gate).
            if let i = active, sessions.live.isEmpty,
               checks.contains(where: { ["reg32", "reglayout", "com"].contains($0.id) && $0.state == .bad }) {
                GameRegistry.invalidate(i)
            }
            play()
        case .stop:
            let alert = NSAlert()
            alert.messageText = "Stop \(s.name)?"
            alert.informativeText = "The game closes without logging out."
            alert.addButton(withTitle: "Keep Playing")
            alert.addButton(withTitle: "Stop")
            if alert.runModal() == .alertSecondButtonReturn { runner.stop() }
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
    ///   2. Wine and the Windows drive in that folder (Bootstrap, in the setup sheet);
    ///   3. the patched game Wine -- no pinned download yet, so it is said at the end;
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
        let world = store.selectedID
        setupRunning = true
        setupProgress = nil
        notice = ""
        let r = runner
        var gameWineMissing = false
        defer {
            setupRunning = false
            setupProgress = nil
            if gameWineMissing, nextNeed == .setup(.gameWine) { notice = Primary.gameWineUnavailable }
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
            return await setupConfigureStep(r)
        }
        for _ in 0..<10 {
            await recheckSettled()
            guard store.selectedID == world else { return }   // the user switched worlds
            let need: PrimaryAction.SetupNeed
            switch nextNeed {
            case .setup(let n): need = n
            case .repair(.wine):
                // Step 5 on its own (Wine's library links), when it is all that is left.
                guard !configured, await configureIfNeeded() else { return }
                continue
            default: return                                     // nothing left to set up
            }
            if done.contains(need) { return }
            done.append(need)
            switch need {
            case .install, .wrapperDrive, .wine:
                guard await setupLocationStep(need) else { return }
                await refreshAsync()
            case .dataDrive, .chooseFolder:
                guard await setupLocationStep(need) else { return }
            case .game:
                guard await setupGameStep(r) else { return }
                // Step 5 right away: a fresh prefix has no registry, COM or library links yet.
                await recheckSettled()
                guard await configureIfNeeded() else { return }
            case .gameWine:
                // No pinned download for it yet (see Primary.gameWineUnavailable). Everything
                // after it still gets done, and the line at the end says what is left.
                gameWineMissing = true
                guard await configureIfNeeded() else { return }
                if store.selected?.local == true, local.status?.ready == false {
                    guard await setupLocalServerStep(r) else { return }
                }
                return
            case .localServer:
                guard await setupLocalServerStep(r) else { return }
            }
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
    private func setupNewLocation(adoptAlways: Bool = true) async -> Bool {
        guard let folder = LocationPanel.choose(
            title: "Where should FFXI on Mac go?",
            message: "Everything goes in one folder, “FFXI on Mac”, inside the folder you choose: Wine, its Windows drive and the game. Any Mac-formatted drive works, external included.",
            prompt: "Set Up Here", need: InstallLocation.Need.fresh) else { return false }
        Bootstrap.target = InstallLocation.wrapper(in: folder)
        guard await runSetupSheet() else { return false }
        let built = InstallLocation.install(in: folder)
        InstallLocation.remember(folder)
        // Install dependencies… beside an install that already has the game keeps that one in
        // use (G11); the new one is in the picker.
        if adoptAlways || selected?.hasGame != true {
            built.remember()
            installs = [built] + installs.filter { $0.id != built.id }
            selected = built
        }
        return true
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
            moveChecking = false
            if let why = InstallMove.blocker(.init(clientsLive: clients, wineRunning: wine)) { notice = why; return }
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
        let live = sessions.live
        if live.contains(where: { $0.id != store.selected?.name }) || !elsewhere.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("RUNNING").font(.system(size: 12)).tracking(2).foregroundStyle(Vana.muted)
                // The selected world's own Stop is the main button.
                ForEach(live.filter { $0.id != store.selected?.name }, id: \.id) { s in
                    HStack(spacing: 6) {
                        Circle().fill(Vana.crystal).frame(width: 6, height: 6)
                        Text(s.id).font(.system(size: 12)).foregroundStyle(Vana.text)
                        Spacer()
                        Button("Stop") { s.runner.stop() }
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
        guard let i = active else { return }
        // Only a handed-over --play gets here (PLAY is grey); the launcher is about to quit.
        if updateInstalling {
            runner.logFileOnly("!! not playing: the launcher is restarting to update")
            return
        }
        if runner.busy {
            // Only a forwarded --play gets here (PLAY is grey while busy); not an error to keep.
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

    private func launchClient(_ i: Install, server: Server, runner r: Runner) {
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
        // A world the install has no boot profile for — the local one, on every machine — needs
        // that file to exist before anything can be written into it.
        if !Credentials.ensureProfile(server.bootProfile, in: i) {
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
        if let why = r.gate(i, renderer: effective.renderer,
                            sync: MultiWorld.syncMode(msync: effective.msync, esync: effective.esync),
                            msyncAllowed: server.msync, profile: server.bootProfile,
                            world: server.name, host: server.host,
                            maxClients: server.maxClients).refusal {
            notice = why
            r.logFileOnly("!! " + why)
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
            if !account.user.isEmpty, !account.pass.isEmpty {
                if !Credentials.apply(user: account.user, password: account.pass, to: i,
                                      profile: server.bootProfile, server: server.host) {
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
        panel.message = "Pick the wrapper app that contains the game — usually siku.app."
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
        let found = await Task.detached(priority: .userInitiated) { Install.discover() }.value
        scanning = false
        // Nothing found: the checks still run, so the button can name a remembered install's
        // missing drive instead of offering a setup from scratch (G6).
        guard !found.isEmpty else { await recheckAsync(); return }
        installs = found
        if let cur = selected, !found.contains(where: { $0.id == cur.id }), cur.hasGame {
            // The selected install still holds the game but was not found (its wine is broken,
            // or it is outside the scanned folders): keep it rather than switching to an empty
            // wrapper and asking for a 9 GB download again (G11).
            installs = [cur] + found
        } else if selected == nil || !found.contains(where: { $0.id == selected?.id }) {
            selected = found.first
        }
        selected?.remember()
        await recheckAsync()
        if let i = selected { await runner.syncPrefixIfStale(i) }
    }

    private func recheck() { Task { await recheckAsync() } }

    /// Mount, unmount and activation rechecks: one at a time, the latest folded into a single rerun.
    private func autoRecheck() {
        // Nothing selected (the install's drive was gone at launch): a drive coming back may
        // bring it back, which only a scan finds.
        if selected == nil, !scanning { refresh(); return }
        if checksInFlight > 0 { recheckPending = true; return }
        recheck()
    }

    private func recheckAsync() async {
        checksGeneration += 1
        let generation = checksGeneration
        guard let i = active else {
            checks = []; horizonInstalled = nil; probe = Primary.Probe(); checksWorld = nil
            // Nothing selected: if the remembered install is on a drive that is gone, the button
            // asks for that drive instead of offering a fresh setup (G6).
            let r = await Task.detached(priority: .userInitiated) { Primary.rememberedDrive() }.value
            guard generation == checksGeneration else { return }
            rememberedDrive = r.map { (name: $0.0, state: $0.1) }
            return
        }
        rememberedDrive = nil
        let world = store.selected?.name
        let profile = store.selected?.bootProfile ?? "horizonxi.ini"
        let horizon = world == "HorizonXI"
        let required = store.selected.map { feeds.requiredClients[$0.name] ?? $0.requiredClient } ?? ""
        checksInFlight += 1
        let p = await Task.detached(priority: .userInitiated) {
            Primary.probe(i, profile: profile, horizon: horizon, requiredClient: required)
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
        // to a value some other world last wrote.
        if let s = store.selected {
            graphics = GraphicsSettings.load(world: s.name)
            if let i = active, let onDisk = GraphicsSettings.read(from: i, profile: s.bootProfile) {
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
        let all = AddonSuite.scan(i, profile: store.selected?.bootProfile ?? "horizonxi.ini")
        if addonPolicy.isRestricting {
            addonItems = all.filter { addonPolicy.allows($0.name) }
            hiddenAddonCount = all.count - addonItems.count
        } else {
            addonItems = all
            hiddenAddonCount = 0
        }
        let bad = AddonSuite.mismatchedPlugins(i)
        addonWarning = bad.isEmpty ? "" :
            "Ashita refused these plugins on the last run because they are built for a different "
            + "interface version than this Ashita core: \(bad.joined(separator: ", ")). "
            + (bad.contains { $0.lowercased() == "addons" }
               ? "That includes the Lua host, so no addon below can run until it is fixed."
               : "")
        showAddons = true
    }

    private func color(_ s: Check.State) -> Color {
        switch s {
        case .ok: return Vana.crystal
        case .warn: return Vana.gold
        case .bad: return Vana.ember
        }
    }
}
