import SwiftUI
import AppKit
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // No more handed-over requests from here on: one taken now would never be acted on.
        SingleInstance.terminating = true
        guard Runner.workInFlight else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "A download or install is still running."
        a.informativeText = "Quitting stops it. It is resumable — pressing Download again picks "
                          + "up where it left off — but nothing more will download until you do."
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
    @StateObject private var updater = Updater()
    @StateObject private var ra = RAProgress()
    @State private var bannerIndex = 0
    /// One timer for the life of the view. Built inline in `newsBanner`'s body it was a *new*
    /// publisher on every body evaluation, so any re-render (hovering the window, a population
    /// refresh, changing world) restarted the 7-second countdown and the banner could sit on one
    /// item indefinitely -- watched it stay frozen for 28 seconds straight after a world change.
    private let bannerTick = Timer.publish(every: 7, on: .main, in: .common).autoconnect()
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
    @State private var showGraphics = false
    @State private var graphics = GraphicsSettings.load(world: nil)
    @State private var showAddons = false
    @State private var addonItems: [AddonSuite.Item] = []
    @State private var hiddenAddonCount = 0
    @State private var installingExtra = ""
    @State private var addonWarning = ""
    @State private var notice = ""
    /// One update attempt per Play press chain; a second Play retries.
    @State private var updateChecked = false
    @State private var scanning = false
    /// The start-up task has handled this launch's own --world/--play; handed-over requests
    /// may run from now on. See `runForwarded`.
    @State private var commandsReady = false
    @State private var forwardRunning = false
    @State private var showSetup = false
    @State private var horizonLatest: String?
    private var fdaBlocked: Bool { checks.contains(where: { $0.id == "fda" && $0.state == .bad }) }
    // Starts open when FFXI_ON_MAC_SHOW_SIGNUPS=1, so this project can screenshot the expanded
    // list without driving a synthetic click into the window (see docs/SERVERS-WORKLOG.md).
    @State private var showAllSignups =
        ProcessInfo.processInfo.environment["FFXI_ON_MAC_SHOW_SIGNUPS"] == "1"

    private var blocked: Bool { checks.contains { $0.state == .bad } }

    private var statusText: String {
        if scanning { return "looking for your install…" }
        if runner.starting { return "starting the game — the first launch after a Repair can take a minute" }
        if runner.running { return "game running" }
        if selected == nil { return "nothing installed yet" }
        if let i = active, !i.hasGame { return "wine is ready — \(store.selected?.name ?? "the game")'s data is not installed" }
        return blocked ? "setup incomplete" : "ready to play"
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
        .onChange(of: runner.loginFailure) { f in
            guard !f.isEmpty else { return }
            notice = "\(store.selected?.name ?? "The server") said: \(f)"
                + (f.contains("Invalid") ? " Check the account name and password — accounts are created on the server's own site or through its loader, not here." : "")
        }
        .onChange(of: store.selectedID) { _ in
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
        // Keep the players-online line current: on launch, whenever the world changes, and
        // every two minutes while the window is open. The fetch is three tiny GETs and silent
        // on failure, so this costs nothing when offline.
        .task { await feeds.refreshPopulations() }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
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
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
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
            // Check GitHub Releases and, if there is a newer build, download it automatically.
            // The update is only *applied* when the user presses Restart (updateBanner).
            updater.start()
            await fetchHorizonLatest()
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
                gameUpdateBanner
                newsBanner
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
                    rendererBanner
                    notesCard
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

            // The host and boot-profile fields used to sit here for every unverified world,
            // which read as something the player was expected to fill in. They now live under
            // Setup & Diagnostics; only the one thing that actually blocks Play stays visible.
            if let s = store.selected, !s.local, s.host.isEmpty {
                Text("No login host set for \(s.name) — add it under Setup & Diagnostics.")
                    .font(.system(size: 12)).foregroundStyle(Vana.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
        // A world other than HorizonXI with no folder of its own would be run out of HorizonXI's
        // files -- which is exactly what earns "The game's data has been updated" from CatsEye.
        // Say so right under the world, and offer the two ways to fix it.
        if let i = active, let s = store.selected,
           !i.hasGame || (s.dataPath.isEmpty && !s.local && s.name != "HorizonXI") {
            gameDataCard(for: s, install: i)
        }
        }
        .sheet(isPresented: $newServer) { addServerSheet }
        .sheet(isPresented: $showGraphics) { graphicsSheet }
        .sheet(isPresented: $showAddons) { addonsSheet }
        .sheet(isPresented: $showSetup) { SetupSheet { refresh() } }
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
            return "\(store.selected?.name ?? "This server") allows only the addons on its "
                 + "published list, and VanaVoice is not on it. Running it there risks your "
                 + "account, so the launcher will not install it."
        }
        if !Narration.narratorAvailable {
            return "Installs the bundled VanaVoice addon. To hear speech, install VanaVoice.app: "
                 + "github.com/danielalanbates/vanavoice"
        }
        return "Installs VanaVoice's addon into this world and starts the narrator, which "
             + "reads NPC and cutscene dialogue aloud in a neural voice."
    }

    /// Why the Vanaguide toggle is on, off, or greyed out. Same allowlist rule as narration:
    /// Vanaguide is on nobody's published list, so HorizonXI / CatsEyeXI / FFEra never get it.
    private var vanaguideHelp: String {
        if !Guide.isAvailable {
            return "Place the Vanaguide repo at Code/Vanaguide (addon root Code/Vanaguide/Vanaguide) "
                 + "or copy that folder to Downloads/Vanaguide. github.com/danielalanbates/vanaguide"
        }
        if !Guide.allowed(by: addonPolicy) {
            return "\(store.selected?.name ?? "This server") allows only the addons on its "
                 + "published list, and Vanaguide is not on it. Running it there risks your "
                 + "account, so the launcher will not install it. Use Local server (LandSandBoat)."
        }
        return "Copies Vanaguide into this world's addons folder and adds /addon load vanaguide "
             + "outside the managed AddonSuite block. Intended for local LandSandBoat only."
    }

    /// A rotating strip of what the launcher knows about the selected world.
    ///
    /// Every line here is something the launcher actually holds -- the server's era, its own
    /// note, the state of its addon rules, whether this project has tested it. **Nothing is
    /// invented to fill the space.** No FFXI private server publishes a news feed a launcher can
    /// read (see `ServerFeeds` for what was checked), so there are no headlines to rotate; the
    /// moment one does, fetched items appear here first and are marked as such.
    /// Shown only when an update has finished downloading and is staged: one line and a Restart
    /// button. While a download is in flight it shows quiet progress; otherwise it renders nothing,
    /// so the normal launcher is undisturbed.
    /// HorizonXI game update, shown at the top of the news only when the installed client is
    /// actually behind what api.horizonxi.com publishes (or while an update is running).
    @ViewBuilder private var gameUpdateBanner: some View {
        if runner.updatingHorizon {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Updating HorizonXI \(runner.updateLabel)  \(Int(runner.updateProgress * 100))%")
                        .font(.system(size: 12)).foregroundStyle(Vana.text)
                    ProgressView(value: runner.updateProgress).tint(Vana.gold)
                }
                Spacer()
                Button("Stop") { runner.stopHorizonUpdate() }.controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Vana.gold.opacity(0.12)))
            .padding(.top, 6)
        } else if store.selected?.name == "HorizonXI", let i = active,
                  let have = ClientVersion.horizonVersion(in: i), let latest = horizonLatest,
                  Updater.isNewer(latest, than: have) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Vana.gold)
                Text("HorizonXI \(latest) is available (you have \(have))")
                    .font(.system(size: 12)).foregroundStyle(Vana.text)
                Spacer()
                Button("Update") { runner.updateHorizon(i) { _ in recheck(); Task { await fetchHorizonLatest() } } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(runner.busy)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Vana.gold.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Vana.gold.opacity(0.35), lineWidth: 1))
            .padding(.top, 6)
        }
    }

    /// Newest HorizonXI client version their launcher API publishes. Quiet on failure.
    private func fetchHorizonLatest() async {
        var req = URLRequest(url: URL(string: "https://api.horizonxi.com/api/v1/launcher/install-game")!)
        req.setValue("FFXI-on-Mac launcher", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let ups = o["updateData"] as? [[String: Any]] ?? []
        let v = (ups.last?["marketingVersion"] as? String)
            ?? ((o["installData"] as? [String: Any])?["baseGameMarketingVersion"] as? String)
        if let v { horizonLatest = v }
    }

    @ViewBuilder private var updateBanner: some View {
        switch updater.state {
        case .ready(let release):
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Vana.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update \(release.version) is ready").font(.system(size: 12)).foregroundStyle(Vana.text)
                    Text("Restart to finish installing it.").font(.system(size: 12)).foregroundStyle(Vana.muted)
                }
                Spacer()
                Button("Restart") { updater.restartToUpdate() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!sessions.live.isEmpty || !sessions.elsewhere.isEmpty)
                    .help(!sessions.live.isEmpty || !sessions.elsewhere.isEmpty
                          ? "Finish your game before restarting for the update."
                          : "Install the ready update and reopen the launcher.")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Vana.gold.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Vana.gold.opacity(0.35), lineWidth: 1))
            .padding(.top, 6)
        case .downloading(let frac):
            HStack(spacing: 8) {
                ProgressView(value: frac).frame(width: 120)
                Text("Downloading update… \(Int(frac * 100))%").font(.system(size: 12)).foregroundStyle(Vana.muted)
            }.padding(.top, 6)
        case .staging:
            Text("Preparing update…").font(.system(size: 12)).foregroundStyle(Vana.muted).padding(.top, 6)
        case .failed(let msg):
            // Only worth showing when it is about an update that exists, not routine offline noise.
            if msg.contains("available") {
                Text(msg).font(.system(size: 12)).foregroundStyle(Vana.ember)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        case .idle, .checking:
            EmptyView()
        }
    }

    /// Live players-online for the selected world, under the news banner. Only shown when the
    /// server publishes a counter (its own website's number); no counter, no line — never a 0.
    @ViewBuilder
    private var populationLine: some View {
        if let name = store.selected?.name, let n = feeds.populations[name] {
            HStack(spacing: 8) {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text("\(n.formatted()) players online now")
                    .font(.callout).foregroundStyle(Vana.muted)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var newsBanner: some View {
        // Only real news fetched from the server. The built-in blurbs (era, emulator lineage,
        // connection notes, addon counts) were filler and are no longer rotated here.
        let items = feeds.bannerItems(for: store.selected, policy: addonPolicy).filter(\.fetched)
        if items.isEmpty {
            EmptyView()
        } else {
            let item = items[min(bannerIndex, items.count - 1) % items.count]
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(item.fetched ? Vana.gold : Vana.crystal.opacity(0.5))
                    .frame(width: 6, height: 6).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout).foregroundStyle(Vana.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = item.url {
                        Link("Open \(url.host ?? "page")", destination: url)
                            .font(.system(size: 12)).foregroundStyle(Vana.gold)
                    }
                }
                Spacer(minLength: 0)
            }
            // Tall enough for the longest item (three lines): sized to the two-line items, the
            // whole page nudged up and down as the banner rotated onto a three-line one.
            .frame(minHeight: 66, alignment: .top)
            .padding(.top, 4)
            .id(item.id)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.45), value: bannerIndex)
            .onReceive(bannerTick) { _ in
                bannerIndex = (bannerIndex + 1) % max(items.count, 1)
            }
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
        let world = store.selected?.name ?? "This server"
        return "\(world) has not approved these, and on most private servers running an "
             + "unapproved addon is a bannable offence. They are listed because they are "
             + "installed and they are yours to manage — not because they are allowed."
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
            Text("Written to scripts/default.txt, between the launcher-managed markers. Anything "
                 + "you added by hand outside those blocks is left alone.")
                .font(.system(size: 12)).foregroundStyle(Vana.muted)

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
                                            notice = "\(e.title) installed — press Apply to load it next Play."
                                        } else {
                                            notice = "\(e.title) could not be installed; see the log."
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
                        notice = "Not saving: this server's addon list came back empty, so every "
                               + "addon you have would be switched off. Nothing was written."
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
                    } else {
                        notice = "Addon list saved. It takes effect the next time you press Play."
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
                    .help("Lower resolution and texture memory use.")
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
                        notice = "Graphics written to \(s.bootProfile)."
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
                    // Once the server is built the space warning is about the *next* build, not
                    // this one, so state the number without dressing it as a problem.
                    HStack(spacing: 6) {
                        Image(systemName: (s.spaceOK || s.ready)
                              ? "checkmark.circle" : "exclamationmark.triangle.fill")
                            .foregroundStyle((s.spaceOK || s.ready) ? Vana.crystal : Vana.ember)
                        Text(s.ready
                             ? String(format: "%.1f GB free on this disk", s.freeGB)
                             : String(format: "%.1f GB free · about %.0f GB needed",
                                      s.freeGB, s.needGB))
                            .font(.system(size: 12))
                            .foregroundStyle((s.spaceOK || s.ready) ? Vana.text : Vana.ember)
                    }

                    if !s.spaceOK && !s.ready {
                        Text(s.belowFloor
                             ? "Not enough room to install a server. It needs roughly \(Int(s.needGB)) GB — "
                               + "about 5 GB of source, 3 GB of build output, and headroom for the "
                               + "database and the compiler. Free up space, then set up."
                             : "Below the recommended \(Int(s.needGB)) GB but above the "
                               + "\(Int(s.floorGB)) GB minimum. Setup will run, and may run tight.")
                            .font(.system(size: 12)).foregroundStyle(Vana.ember)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if s.ready {
                        row("Server", s.running
                            ? "running · \(s.up.count) of 4 processes"
                            : "built and ready — Play will start it")
                    } else {
                        row("Still to do", s.todo)
                        Text("Setting up downloads Homebrew packages and the LandSandBoat source, "
                             + "imports the game database and compiles the server. Budget half an "
                             + "hour or more the first time; it can be re-run if it stops.")
                            .font(.system(size: 12)).foregroundStyle(Vana.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    row("Location", s.root)

                    HStack(spacing: 8) {
                        if !s.ready {
                            Button(s.source ? "Continue setup" : "Set up server") {
                                local.setup(force: s.belowFloor && forceSetup,
                                            log: { runner.appendLine($0) })
                            }
                            .disabled(local.busy || (s.belowFloor && !forceSetup))
                            if s.belowFloor {
                                Toggle("Set up anyway", isOn: $forceSetup)
                                    .toggleStyle(.checkbox).font(.system(size: 12))
                                    .foregroundStyle(Vana.muted)
                            }
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
                    Text("checking what is installed…")
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

    /// Say plainly when the chosen renderer is not one you can actually play on.
    @ViewBuilder private var rendererBanner: some View {
        if !perf.renderer.playable {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Vana.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(perf.renderer.title) is experimental")
                        .font(.system(size: 12)).foregroundStyle(Vana.text)
                    Text(perf.renderer.blurb).font(.system(size: 12)).foregroundStyle(Vana.muted)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Vana.ember.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Vana.ember.opacity(0.35)))
            .padding(.horizontal, 34).padding(.top, 14)
            .frame(maxWidth: 500, alignment: .leading)
        }
    }

    /// The Horizon launcher fills this space with news. This project's equivalent is honest
    /// status: what the current renderer does, and where the write-up lives.
    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Vana'diel on Apple Silicon", systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .foregroundStyle(Vana.gold)

            row("Renderer", perf.renderer.title)
            row("Wine prefix", selected?.prefixName ?? (scanning ? "scanning…" : "not found"))
            row("Client", selected == nil ? (scanning ? "scanning…" : "not found") : "Ashita · \(store.selected?.bootProfile ?? "")")

            Text("Measured on this Mac with Metal/DXVK: rendering is correct, fog included, "
                 + "at 4K with every setting at maximum — see docs/MAX4K.md.")
                .font(.system(size: 12)).foregroundStyle(Vana.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 500, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Vana.stroke))
        .padding(.horizontal, 34).padding(.top, 16)
    }


    // MARK: - Signup

    /// Where to get an account, always on screen rather than buried in a sheet.
    ///
    /// This is the one thing a new player cannot do from inside the launcher: every world runs
    /// its own account database, and four of the ten have no web signup at all — the account is
    /// typed into the loader console on first launch, or gated behind a Discord bot. So the card
    /// states the actual route for the selected world and offers the link that leads to it, and
    /// keeps a link for every other world one disclosure away. See `Server.accountHow`.
    @ViewBuilder
    private var accountCard: some View {
        if let s = store.selected {
            VStack(alignment: .leading, spacing: 10) {
                Label("Getting an account", systemImage: "person.badge.key")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(Vana.gold)

                Text(s.accountHow.isEmpty
                     ? "\(s.name) publishes no signup route this project could find."
                     : s.accountHow)
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

                // A plain DisclosureGroup only toggles from its chevron on macOS -- clicking
                // the words did nothing, which is exactly the kind of dead target this card
                // exists to avoid. A button makes the whole row the target.
                Button { withAnimation(.easeInOut(duration: 0.18)) { showAllSignups.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(showAllSignups ? 90 : 0))
                        Text(showAllSignups ? "Every other world" : "Every other world")
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Vana.crystalDim)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Bounded and scrolled: the hero column has no scroll view of its own, so an
                // unbounded ten-row list pushed the game's title off the top of the window.
                if showAllSignups {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.ordered.filter { $0.name != s.name }) { other in
                                signupRow(other)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    // A ScrollView asks for zero height in a plain VStack, which rendered the
                    // list as an empty gap. Give it the rows' own height, capped.
                    .frame(height: CGFloat(store.ordered.count - 1) * 21 + 6)
                }
            }
            .padding(14)
            .frame(maxWidth: 500, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Vana.stroke))
            .padding(.horizontal, 34).padding(.top, 16)
        }
    }

    /// A world with no signup link at all still gets a row, saying so — a missing row reads as
    /// "the launcher forgot this one".
    @ViewBuilder
    private func signupRow(_ other: Server) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(other.name).font(.system(size: 12)).foregroundStyle(Vana.text)
                .frame(width: 104, alignment: .leading)
            if let u = URL(string: other.accountURL), !other.accountURL.isEmpty {
                Link(Self.signupVerb(for: other), destination: u)
                    .font(.system(size: 12)).foregroundStyle(Vana.gold)
                    .help(other.accountHow.isEmpty ? u.absoluteString : other.accountHow)
            } else {
                Text(other.accountHow.contains("loader window")
                     ? "in the loader window" : "no signup published")
                    .font(.system(size: 12)).foregroundStyle(Vana.muted)
                    .help(other.accountHow)
            }
            Spacer(minLength: 0)
            if let d = URL(string: other.discordURL), !other.discordURL.isEmpty,
               other.discordURL != other.accountURL {
                Link("Discord", destination: d).font(.system(size: 12)).foregroundStyle(Vana.crystalDim)
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

    private var statusList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(checks) { c in
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

    private var logStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Vana.stroke).frame(height: 1)
            ScrollViewReader { sp in
                ScrollView {
                    Text(runner.log.isEmpty ? "ready." : runner.log)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Vana.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .id("end")
                }
                .frame(height: 108)
                .onChange(of: runner.log) { _ in sp.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(Color.black.opacity(0.28))
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
                    .help("Choose install… — point at the wrapper app if it lives somewhere the "
                          + "scan does not look, such as Downloads")
            }

            // The local server auto-creates its own account on first login (see LocalServer.swift)
            // -- there is no real account to type here, so the fields are disabled rather than
            // left editable and silently ignored.
            field("Account name", text: $user, secure: false, disabled: store.selected?.local == true)
            field("Password", text: $pass, secure: true, disabled: store.selected?.local == true)
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
            }

            Rectangle().fill(Vana.stroke).frame(height: 1)

            rendererSection

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    if let s = store.selected, !s.local {
                        Text("SERVER CONNECTION").font(.system(size: 12)).tracking(2).foregroundStyle(Vana.muted)
                        TextField("login host", text: Binding(
                            get: { s.host }, set: { var c = s; c.host = $0; store.update(c) }))
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
                        .help("Switch headphones, speakers or a Bluetooth device while the game "
                              + "is running and the sound moves with it. Without this, wine keeps "
                              + "playing to whichever device was default when the game started.")
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
                        Button("Repair") { if let i = active { runner.repair(i) } }
                            .disabled(runner.busy || fdaBlocked)
                            .help(fdaBlocked ? "Grant Full Disk Access first — Repair runs wine from a drive this app can't read yet." : "Re-applies the prefix configuration the game needs.")
                        if store.selected?.name == "HorizonXI" {
                            Button("Update HorizonXI…") {
                                if let i = active { runner.updateHorizon(i) { _ in recheck() } }
                            }
                            .disabled(runner.busy)
                            .help("""
                                Only press this when HorizonXI have actually published an \
                                update and the game is refusing to let you in. It is not \
                                routine maintenance: it rewrites files in a working install, \
                                takes an hour or more over BitTorrent, and can leave the \
                                client mid-update if it stalls. A working install does not \
                                need it. Play stays available either way — HorizonXI's login \
                                server accepts an install that is a version or two behind.
                                """)
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
                        if runner.busy {
                            Button("Stop install") { if let i = active { runner.cancelInstaller(i) } }
                                .help("Kills whatever is running in the installer prefix.")
                        }
                        // Also reachable when an install already exists: a wrapper can be
                        // broken past what Repair fixes, and rebuilding a fresh one beside it
                        // is faster than diagnosing wine by hand.
                        Button("Install dependencies…") { showSetup = true }
                            .help("Installs Rosetta 2 and Wine, and creates the Windows drive FFXI installs into")
                    }
                    .padding(.top, 4)

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

            // Nothing found and the scan has finished: this is a first run, and the one thing
            // the user needs is the button that installs everything. Offering it here rather
            // than burying it in Setup & Diagnostics is the difference between a launcher that
            // works out of the box and one that needs the README first.
            // Shown outside the collapsed panel: without this grant every wine process the app
            // starts is killed by macOS at launch, so Play and Repair just "exit".
            if fdaBlocked {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                } label: {
                    Label("Grant Full Disk Access", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("The game drive needs Full Disk Access. Turn on FFXI on Mac in the list, then press ↻.")
            }

            if !scanning && selected == nil {
                Button { showSetup = true } label: {
                    Label("Set up FFXI on Mac", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Installs Rosetta 2 and Wine, and creates the Windows drive FFXI installs into")
            }

            HStack(spacing: 5) {
                Circle().fill(scanning ? Vana.gold : (blocked ? Vana.ember : Vana.crystal)).frame(width: 6, height: 6)
                Text(statusText).font(.system(size: 12)).foregroundStyle(Vana.muted)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Vana.panel)
    }

    private var rendererSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RENDERER").font(.system(size: 12)).tracking(2.5).foregroundStyle(Vana.gold)
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
                       disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 12)).tracking(1.5).foregroundStyle(Vana.muted)
            Group {
                if secure { SecureField("", text: text) } else { TextField("", text: text) }
            }
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.selected?.name ?? "Choose a world")
                            .font(.system(size: 14, weight: .semibold, design: .serif))
                            .foregroundStyle(Vana.text)
                            .lineLimit(1)
                        if let era = store.selected?.era, !era.isEmpty {
                            Text(era).font(.system(size: 12)).foregroundStyle(Vana.muted).lineLimit(1)
                        }
                    }
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

    /// Shown when the chosen world's game files are not where the launcher expects them. Two
    /// answers, both one click: point at a folder that already has them, or get them from the
    /// world's own source. The location is the user's to choose — external drives welcome — and
    /// is remembered per world in servers.json.
    private func gameDataCard(for s: Server, install i: Install) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GAME DATA").font(.system(size: 12)).tracking(2.5).foregroundStyle(Vana.gold)
            Text(s.dataPath.isEmpty
                 ? (i.hasGame ? "\(s.name) has no folder of its own yet — Play would use HorizonXI's files, which \(s.name)'s login server may reject."
                              : "\(s.name)'s game files are not installed yet.")
                 : "Nothing playable at \(s.dataPath).")
                .font(.system(size: 12)).foregroundStyle(Vana.muted).fixedSize(horizontal: false, vertical: true)
            if !s.installNote.isEmpty {
                Text(s.installNote).font(.system(size: 12)).foregroundStyle(Vana.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Three buttons never fit this panel's width: they rendered as "Downloa…",
            // "Choose fold…", "Run installer…" -- the primary action unreadable. The action that
            // matters gets its own full-width row; the alternatives share the one below.
            VStack(alignment: .leading, spacing: 6) {
                if s.installKind != .none {
                    // The button used to read "Download…" whether or not a download was already
                    // going, and a second press was silently ignored -- so a download that had
                    // been killed (quitting the launcher kills its child processes) and one that
                    // was running looked exactly the same. It now says which it is.
                    Button { downloadGameData(for: s, install: i) } label: {
                        Label(runner.busy ? "Downloading…" : "Download…",
                              systemImage: runner.busy ? "arrow.down.circle.dotted" : "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sessions.anyBusy || runner.running)
                    .help(runner.busy
                          ? "Another download or install is running — watch the log on the left. It resumes where it left off if it is interrupted."
                          : "Downloads are resumable: if this is interrupted, press Download again and it continues.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                Button("Choose folder…") { chooseGameData(for: s) }
                if !s.local {
                    Button("Run installer…") { runLocalInstaller(for: s, install: i) }
                        .help("Already have \(s.name)'s installer? Run it inside the wrapper.")
                }
                if s.name == "HorizonXI" {
                    Button("Install into wrapper…") { showSetup = true }
                        .help("The classic route: run HorizonXI's installer inside the wrapper.")
                }
                }
            }.font(.system(size: 12)).lineLimit(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
    }

    /// Ask where this world's files are (or should go). Defaults to ~/Games/FFXI/<world>, and
    /// the user can pick any drive. The choice is stored on the server entry.
    private func chooseGameData(for s: Server) {
        let panel = NSOpenPanel()
        panel.title = "Game data for \(s.name)"
        panel.message = "Choose the folder that holds (or will hold) \(s.name)'s game files. Any drive is fine; the launcher finds Ashita-cli.exe and SquareEnix inside it, however \(s.name)'s installer laid them out."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        let def = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/FFXI/\(s.name)")
        try? FileManager.default.createDirectory(at: def, withIntermediateDirectories: true)
        panel.directoryURL = def
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
            chooseGameData(for: s)
            guard let again = store.servers.first(where: { $0.name == s.name }), !again.dataPath.isEmpty else { return }
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
            notice = "\(s.name)'s download page is open in your browser. Save their installer, then use Run installer… (Setup & Diagnostics) or install into \(s.dataPath.isEmpty ? "the folder you choose" : s.dataPath) and press ↻."
        case .none:
            notice = "\(s.name) publishes no client download this launcher knows about."
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
            return (h, name + " (outside this window)", sessions.elsewhere[h] ?? [])
        }
    }

    /// The selected world is playing, here or in another launcher. Keyed like the duplicate
    /// refusal: the Host field and the `--server` its boot profile carries.
    private var selectedRunning: Bool {
        runner.running || store.selected.map { sessions.runningElsewhere(world: $0.name, host: $0.host) } == true
    }

    /// Play is still pressable on a running world that allows a second client.
    private var playAgain: Bool { selectedRunning && store.selected?.allowsMultipleClients == true }

    private var playButton: some View {
        Button(action: play) {
            Text(playAgain ? "PLAY ANOTHER" : selectedRunning ? "RUNNING" : "PLAY")
                .font(.system(size: 15, weight: .semibold, design: .serif)).tracking(5)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(
                    LinearGradient(colors: selectedRunning && !playAgain
                                   ? [Vana.goldDim.opacity(0.45), Vana.goldDim.opacity(0.25)]
                                   : [Vana.gold, Vana.goldDim],
                                   startPoint: .top, endPoint: .bottom))
                .foregroundStyle(Color.black.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: Vana.gold.opacity(selectedRunning && !playAgain ? 0 : 0.35), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        // Only the *absence* of an install should block Play. Once we have one — remembered
        // or found — a still-running background rescan must not hold the user up.
        .disabled(selected == nil || (selectedRunning && !playAgain) || blocked || runner.busy)
    }

    /// Every world playing right now, each with its own Stop. Stopping one never stops another.
    @ViewBuilder private var runningList: some View {
        let live = sessions.live
        if !live.isEmpty || !elsewhere.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("RUNNING").font(.system(size: 12)).tracking(2).foregroundStyle(Vana.muted)
                ForEach(live, id: \.id) { s in
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
                        Spacer()
                        Text("pid \(e.pids.map(String.init).joined(separator: ","))")
                            .font(.system(size: 12)).foregroundStyle(Vana.muted)
                            .help("Started outside this window (another launcher, or by hand). Stop it from there.")
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
            if !notice.isEmpty { runner.appendLine("!! \(notice)") }
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
        if runner.busy {
            notice = "An install or update is running in the wrapper. Play would stop it — wait for it to finish (or cancel it from Setup & Diagnostics)."
            runner.appendLine("!! " + notice)
            return
        }
        notice = ""
        updateChecked = false
        Credentials.setUsername(user, forWorld: store.selected?.name ?? "")
        Credentials.remember = remember
        if remember { Credentials.savePassword(pass, for: user, world: store.selected?.name ?? "") }
        else { Credentials.savePassword("", for: user, world: store.selected?.name ?? "") }

        let server = store.selected ?? Server.builtins[0]
        guard !server.host.isEmpty else {
            notice = "\(server.name) has no login host set."
            runner.appendLine("!! " + notice)
            return
        }
        // Checked against the processes, not only this window's sessions: a client started by
        // another launcher (or by --play) counts just the same.
        let hosts = [server.host] + [Credentials.bootServer(in: i, profile: server.bootProfile)].compactMap { $0 }
        if let why = Runner.duplicateRefusal(world: server.name, hosts: hosts, maxClients: server.maxClients,
                                             clients: LiveClients.snapshot().clients, install: i) {
            notice = why
            runner.appendLine("!! " + why)
            return
        }
        if runner.running, !server.allowsMultipleClients {
            notice = "\(server.name) is already running. \(server.name) does not allow a second "
                   + "client from the same player, so another copy is refused."
            runner.appendLine("!! " + notice)
            return
        }
        let r = runner.running ? sessions.newSession(for: server.name) : runner


        // The local world has to be running before the client can reach it. Start it here rather
        // than making the user press two buttons in the right order — but never build from Play,
        // because a first build is a half-hour job the user should be choosing deliberately.
        if server.local {
            guard let s = local.status, s.ready else {
                notice = local.status == nil
                    ? "Still checking the local server."
                    : "The local server is not set up yet — press “Set up server”."
                return
            }
            if !s.running {
                local.start(log: { r.appendLine($0) }) { ok in
                    if ok { launchClient(i, server: server, runner: r) }
                    else { notice = "The local server did not start — see the log." }
                }
                return
            }
        }
        launchClient(i, server: server, runner: r)
    }

    private func launchClient(_ i: Install, server: Server, runner r: Runner) {
        // Two servers on the list publish no login host anywhere this project could find. Ashita
        // would take `--server ` with nothing after it and fail somewhere less obvious, so say
        // what is actually missing instead.
        if server.host.trimmingCharacters(in: .whitespaces).isEmpty {
            notice = "\(server.name) has no login host set. Get it from that server's own "
                   + "launcher or setup guide and put it in the server's Host field."
            r.appendLine("!! " + notice)
            return
        }
        // A world the install has no boot profile for — the local one, on every machine — needs
        // that file to exist before anything can be written into it.
        if !Credentials.ensureProfile(server.bootProfile, in: i) {
            notice = "Could not create config/boot/\(server.bootProfile)."
            r.appendLine("!! " + notice)
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
            r.appendLine("!! " + why)
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
            notice = "\(server.name) needs client \(requiredVer) or newer; this install is at "
                   + "\(have). Its login server will refuse with “The game's data has been updated”. "
                   + (server.name == "CatsEyeXI"
                      ? "Open Setup & Diagnostics › CatsEyeXI installer… to update it with their own launcher."
                      : "Update the client first.")
            r.appendLine("!! " + notice)
            r.appendLine("!! version check: \(server.name) requires \(requiredVer), installed \(have)")
            return
        }
        // HorizonXI publishes its updates, but being behind is not a reason to refuse Play:
        // HorizonXI's login server accepts this client as-is (verified daily), and the torrent
        // fetch can take an hour. Mention it and carry on; the update itself is a button
        // (Setup & Diagnostics › Update HorizonXI…) and runs only when nothing else is.
        if server.name == "HorizonXI",
           let hv = ClientVersion.horizonVersion(in: i), let latest = feeds.horizonLatest, hv != latest {
            r.appendLine("i  HorizonXI \(latest) is published; this install is \(hv). "
                         + "You do not need to do anything: the login server accepts this "
                         + "client and the game plays normally. Only run Setup & Diagnostics "
                         + "\u{203A} Update HorizonXI\u{2026} if you are actually turned away.")
        }

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
                    r.appendLine("!! " + notice)
                    if i.gameDir.path.hasPrefix("/Volumes/") {
                        r.appendLine("i  Note: If external volume access is restricted by macOS, grant Full Disk Access to FFXI on Mac in System Settings › Privacy & Security › Full Disk Access.")
                    }
                }
            }
        }
        // Two clients plus LSB on this 8 GB Mac is where frame rates collapse; say so, then go.
        if !LiveClients.scan().isEmpty, let w = MultiWorld.currentMemoryWarning() {
            notice = w
            r.appendLine("!! " + w)
        }
        if let why = r.launch(i, perf: effective, profile: server.bootProfile, useX87: server.x87,
                              world: server.name, host: server.host,
                              maxClients: server.maxClients, msyncAllowed: server.msync,
                              addonPolicy: addonPolicy, beforeLaunch: writeShared) {
            notice = why
        } else {
            // Fresh progress for this session, fetched by the launcher, never by the game.
            ra.refresh(.play, gameDir: i.gameDir, log: { r.appendLine($0) })
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
            notice = "No HorizonXI install inside \(url.lastPathComponent)."
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
        guard !found.isEmpty else { return }
        installs = found
        if selected == nil || !found.contains(where: { $0.id == selected?.id }) {
            selected = found.first
        }
        selected?.remember()
        await recheckAsync()
        if let i = selected { await runner.syncPrefixIfStale(i) }
    }

    private func recheck() { Task { await recheckAsync() } }

    private func recheckAsync() async {
        guard let i = active else { checks = []; return }
        let profile = store.selected?.bootProfile ?? "horizonxi.ini"
        checks = await Task.detached(priority: .userInitiated) { Preflight.run(i, profile: profile) }.value
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
            notice = "No install selected, so there is nothing to list. Press the folder icon "
                   + "above and point the launcher at your wrapper app."
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
