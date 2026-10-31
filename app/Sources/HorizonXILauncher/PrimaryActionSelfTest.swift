import Foundation

/// `--selftest-primary-action`: every state the main button can be in, from plain inputs, plus
/// Repair's refusal on a fixture whose data sits behind a missing drive. Writes only to a
/// temporary folder; reads nothing of the real install.
///
/// The rules it holds the button to (Daniel, 2026-10-15): the label is one of Setup, Update,
/// Repair, Play, Stop, Play Another, or a running job's progress; anything not installed or a
/// dependency not done is Setup; a drive that is gone is Setup (reconnect it or put the game
/// elsewhere) and never "restart"; PLAY says nothing when the game is ready; and never a
/// greyed-out PLAY: a game that cannot start is an enabled Setup, Update or Repair, or a wait's
/// progress label.
extension Headless {
    @MainActor static func runPrimaryActionSelfTest() -> Never {
        var results: [(String, Bool)] = []
        func bad(_ id: String, drive: String? = nil) -> Check {
            Check(id: id, title: id, state: .bad, detail: "", short: "\(id) short", drive: drive)
        }
        var seen: [(String, PrimaryDecision)] = []
        func expect(_ name: String, _ x: PrimaryInputs, _ want: PrimaryAction, enabled: Bool? = nil,
                    reason: String?? = nil) {
            let d = Primary.decide(x)
            seen.append((name, d))
            var ok = d.action == want
            if let e = enabled { ok = ok && d.enabled == e }
            if let r = reason { ok = ok && d.reason == r }
            results.append((name + "  -> \(d.action.id)\(d.action.detail.isEmpty ? "" : ":" + d.action.detail) \"\(d.label)\""
                            + (d.reason.map { " / \($0)" } ?? ""), ok))
        }
        var base = PrimaryInputs()
        base.checks = [Check(id: "wine", title: "Wine", state: .ok, detail: "")]

        expect("ready -> Play, no reason line", base, .play, enabled: true, reason: .some(nil))

        var pending = base; pending.launchUnavailableReason = "Mac login pending."
        expect("catalogued world with pending Mac support -> official information", pending, .serverInfo, enabled: true)

        var phoenix = pending; phoenix.world = "Phoenix XI"
        expect("Phoenix account probe is available without offering Play", phoenix, .serverInfo, enabled: true)

        // Drives. Daniel's Mac on 2026-10-15: SquareEnix links into a ghost-mounted 'Games'.
        var x = base; x.checks = [bad("squareenix", drive: "Games"), bad("reg32")]; x.driveStates = ["Games": .ghost]
        expect("ghost 'Games' (Daniel 2026-10-15) -> Setup, never Repair or restart", x, .setup(.dataDrive("Games")),
               enabled: true, reason: "The 'Games' drive isn't connected — reconnect it or press Setup.")
        x.driveStates = ["Games": .absent]
        expect("unplugged data drive -> Setup", x, .setup(.dataDrive("Games")), enabled: true)
        x.driveStates = [:]
        expect("data drive in an unknown state -> Setup", x, .setup(.dataDrive("Games")))
        x.driveStates = ["Games": .unmounted(device: "disk9s1")]
        expect("unmounted drive -> Repair (diskutil mount, no admin)", x, .repair(.mount(drive: "Games", device: "disk9s1")),
               enabled: true, reason: "The 'Games' drive isn't mounted.")
        x = base; x.checks = [bad("volume", drive: "x10")]; x.driveStates = ["x10": .ghost]
        expect("the wrapper's own drive ghosted -> Setup", x, .setup(.wrapperDrive("x10")))

        // No install.
        x = base; x.hasInstall = false; x.scanning = true
        expect("no install, scanning -> Checking…", x, .working(.checking, progress: nil), enabled: false)
        x.scanning = false
        expect("no install -> Setup", x, .setup(.install), enabled: true, reason: "HorizonXI isn't installed yet.")
        x.rememberedDrive = "x10"; x.driveStates = ["x10": .absent]
        expect("remembered install on an unplugged drive -> Setup naming the drive", x, .setup(.wrapperDrive("x10")),
               reason: "The 'x10' drive isn't connected — reconnect it or press Setup.")
        x.driveStates = ["x10": .unmounted(device: "disk8s2")]
        expect("remembered install on an unmounted drive -> Repair", x, .repair(.mount(drive: "x10", device: "disk8s2")))

        // Access, Wine, the game, its folder.
        x = base; x.checks = [bad("fda"), bad("wine")]
        expect("Full Disk Access (+ wine unreadable) -> Repair", x, .repair(.access), enabled: true)
        x = base; x.checks = [bad("wine"), bad("client")]
        expect("Wine missing -> Setup", x, .setup(.wine), reason: "Wine isn't installed yet.")
        x = base; x.hasGame = false; x.checks = [bad("client"), bad("squareenix"), bad("ashita")]
        expect("game not downloaded -> Setup", x, .setup(.game(partial: false)), reason: "HorizonXI isn't installed yet.")
        x = base; x.checks = [bad("ashita")]
        expect("Ashita missing -> Setup", x, .setup(.game(partial: true)), reason: "Some of HorizonXI's files are missing.")
        x.hasGame = false
        expect("... also when hasGame (which is Ashita) is false", x, .setup(.game(partial: true)))
        x = base; x.checks = [bad("squareenix")]
        expect("base files missing on a present drive -> Setup", x, .setup(.game(partial: true)))
        x.canDownload = false; x.world = "Nowhere"
        expect("files missing, no download route -> Setup (choose the folder)", x, .setup(.chooseFolder))
        x = base; x.checks = [bad("worldclient")]
        expect("no folder chosen / ambiguous -> Setup (choose the folder)", x, .setup(.chooseFolder))

        // Rosetta and the game Wine: enabled Setups that install them (b60 part 3), in Setup's
        // order -- Rosetta, Wine, the game's Wine, the game -- so one press does them all.
        x = base; x.rosettaMissing = true
        expect("Rosetta missing -> Setup (macOS's own password prompt)", x, .setup(.rosetta), enabled: true,
               reason: "Apple's Rosetta isn't installed yet.")
        x.checks = [bad("wine"), bad("client")]; x.patchedWineMissing = true
        expect("Rosetta, Wine and the game's Wine all missing -> Rosetta first", x, .setup(.rosetta))
        x = base; x.rosettaMissing = true; x.checks = [bad("squareenix", drive: "Games")]; x.driveStates = ["Games": .ghost]
        expect("a missing drive outranks Rosetta", x, .setup(.dataDrive("Games")))
        x = base; x.hasInstall = false; x.rosettaMissing = true
        expect("nothing installed, Rosetta missing -> plain Setup (the sheet installs Rosetta first)", x, .setup(.install),
               reason: "HorizonXI isn't installed yet.")
        x = base; x.patchedWineMissing = true
        expect("patched game Wine missing -> Setup, enabled (it downloads it)", x, .setup(.gameWine), enabled: true,
               reason: "The game's Wine isn't installed yet.")
        x.checks = [bad("rpath")]
        expect("game Wine and Wine's links both missing -> Setup first (its chain repairs too)", x, .setup(.gameWine))
        x = base; x.patchedWineMissing = true; x.hasGame = false; x.checks = [bad("client"), bad("squareenix"), bad("ashita")]
        expect("game Wine and the game both missing -> the game's Wine first (before the 9.4 GB download)", x, .setup(.gameWine))
        x = base; x.patchedWineMissing = true; x.checks = [bad("wine")]
        expect("Wine and the game's Wine both missing -> Wine first", x, .setup(.wine))

        // Opting in never borrows the shared Windows environment while its own is incomplete.
        x = base; x.multiServerNeeded = true; x.checks = [bad("reg32"), bad("com")]
        expect("enabled multi-server environment missing -> explicit Setup, ahead of registry repair", x,
               .setup(.multiServer), enabled: true,
               reason: "Set up multi-server play (about 1 GB extra).")
        results.append(("multi-server Setup is included in the progress plan", SetupMeter.plan(x).contains(.multiServer)))
        x.patchedWineMissing = true
        expect("game Wine installs before the separate environment", x, .setup(.gameWine))
        x = base; x.multiServerNeeded = true; x.runningHere = true
        expect("a running single-client world keeps Stop before setup", x, .stop)
        x = base; x.multiServerNeeded = true; x.ownJob = "Enabling multi-server play"
        expect("preparing the separate environment shows progress", x, .working(.settingUp, progress: nil), enabled: false)
        x = base; x.multiServerNeeded = false
        expect("ready multi-server environment -> Play", x, .play, enabled: true, reason: .some(nil))

        // Repair, and what Play fixes itself.
        x = base; x.checks = [bad("rpath"), bad("reg32")]
        expect("Wine's library links -> Repair", x, .repair(.wine), enabled: true, reason: "Wine needs a quick repair.")
        x = base; x.checks = [bad("reg32"), bad("reglayout"), bad("com"), bad("sandbox")]
        expect("registry / COM / sandbox only -> Play, no line (Play fixes them)", x, .play, enabled: true, reason: .some(nil))
        x = base; x.checks = [bad("mystery")]
        expect("unknown failing check -> Repair with its line, never a grey Play", x,
               .repair(.check(id: "mystery", line: "mystery short")), enabled: true, reason: "mystery short")

        // Local server.
        x = base; x.isLocal = true; x.localReady = false
        expect("local server not built -> Setup", x, .setup(.localServer(lowSpace: false)), enabled: true)
        x.localBelowFloor = true
        expect("local server, disk below its floor -> Setup, enabled (the click asks first)", x,
               .setup(.localServer(lowSpace: true)), enabled: true, reason: "Not enough free space for the local server.")
        x.localForce = true
        expect("... 'Set up anyway' ticked -> plain Setup", x, .setup(.localServer(lowSpace: false)), enabled: true)
        x = base; x.isLocal = true; x.localReady = nil
        expect("local status loading -> Checking…", x, .working(.checking, progress: nil))
        x.localReady = true; x.accountNeeded = true
        expect("local world needs no account", x, .play)

        // Updates.
        x = base; x.horizonInstalled = "2.0.4"; x.horizonLatest = "2.0.5"
        expect("HorizonXI behind -> Update", x, .update(world: "HorizonXI", to: "2.0.5"), enabled: true,
               reason: "HorizonXI 2.0.5 is available.")
        x.updateDeferred = true
        expect("update failed or stopped this session -> Play", x, .play)
        x = base; x.horizonInstalled = "2.0.5"; x.horizonLatest = "2.0.5"
        expect("HorizonXI current -> Play", x, .play)
        x = base; x.world = "CatsEyeXI"; x.clientRequired = "30251204_1"; x.clientInstalled = "30240101_0"
        expect("CatsEye client too old -> Update", x, .update(world: "CatsEyeXI", to: "30251204_1"))
        x.world = "Eden"
        expect("client too old, no updater here -> Update (opens the world's own route)", x,
               .update(world: "Eden", to: "30251204_1"), enabled: true, reason: "Eden needs a client update.")

        // Jobs, running, waiting.
        x = base; x.setupRunning = true; x.setupProgress = 0.42
        let dl = Primary.decide(x)
        seen.append(("setup running", dl))
        results.append(("Setup running -> \"\(dl.label)\" greyed with progress",
                        dl.action == .working(.settingUp, progress: 0.42) && !dl.enabled && dl.label == "Setting up… 42%"))
        x = base; x.ownJob = "Downloading"; x.ownProgress = 0.07
        expect("HorizonXI download -> Setting up… 7%", x, .working(.settingUp, progress: 0.07))
        x = base; x.ownJob = "Updating"; x.ownProgress = 0.12
        let up = Primary.decide(x)
        seen.append(("update running", up))
        results.append(("update running -> \"Updating… 12%\"", up.label == "Updating… 12%" && !up.enabled))
        x = base; x.ownJob = "Repairing"; x.checks = [bad("squareenix", drive: "Games")]
        expect("a running job outranks a missing drive", x, .working(.repairing, progress: nil))
        x = base; x.ownJob = "Updating Wine"
        expect("Wine prefix update -> Updating…", x, .working(.updating, progress: nil))
        x = base; x.ownJob = "Installing Eden"
        expect("another world's installer -> Setting up…", x, .working(.settingUp, progress: nil))
        x = base; x.isLocal = true; x.localReady = true; x.ownJob = "stopping"
        expect("local server stopping -> Stopping…", x, .working(.stopping, progress: nil))
        x = base; x.otherJob = "Updating"
        expect("another world's job -> Waiting…", x, .working(.waiting, progress: nil), enabled: false,
               reason: "Waiting for another job to finish.")
        x = base; x.starting = true
        expect("starting -> Starting…", x, .working(.starting, progress: nil))
        x = base; x.runningHere = true
        let stop = Primary.decide(x)
        seen.append(("running", stop))
        results.append(("running here -> Stop, never on Return", stop.action == .stop && stop.destructive && stop.enabled && stop.reason == nil))
        x.allowsMultipleClients = true
        expect("running, second client allowed -> Play Another", x, .playAnother, reason: .some(nil))
        // b70: Wine died under the running client (Runner.serverLost).
        x = base; x.runningHere = true; x.serverLost = true
        let force = Primary.decide(x)
        seen.append(("Wine gone under the game", force))
        results.append(("Wine gone under the game -> Force Stop: enabled, destructive (never on Return), no reason line",
                        force.action == .stop && force.label == "Force Stop" && force.enabled && force.destructive
                            && force.reason == nil))
        x.starting = true; x.allowsMultipleClients = true
        let forceFirst = Primary.decide(x)
        seen.append(("Wine gone, still 'starting', a second client allowed", forceFirst))
        results.append(("... ahead of Starting… and of Play Another (never a second client beside a frozen one)",
                        forceFirst.action == .stop && forceFirst.label == "Force Stop"))
        x = base; x.serverLost = true
        expect("Wine lost with nothing running here changes nothing -> Play", x, .play, reason: .some(nil))
        // b70: Stop pressed, the client not gone yet (Runner.stoppingGame).
        x = base; x.runningHere = true; x.stopping = true
        expect("Stop under way -> Stopping…, not pressable, no line", x, .working(.stopping, progress: nil),
               enabled: false, reason: .some(nil))
        x.serverLost = true; x.renderStuckAt = "21:31:07"; x.starting = true; x.allowsMultipleClients = true
        let stoppingFirst = Primary.decide(x)
        seen.append(("Stop under way, Wine and graphics gone, 'starting', a second client allowed", stoppingFirst))
        results.append(("... ahead of Force Stop, the graphics line, Starting… and Play Another",
                        stoppingFirst.action == .working(.stopping, progress: nil) && stoppingFirst.label == "Stopping…"
                            && !stoppingFirst.enabled && stoppingFirst.reason == nil))
        // b70: the game's GPU device lost for good (Runner.renderStuckSince), 2026-10-16 21:31.
        x = base; x.runningHere = true; x.renderStuckAt = "21:31:07"
        let gpu = Primary.decide(x)
        seen.append(("graphics gone under the game", gpu))
        results.append(("graphics gone -> Stop (not Force Stop), enabled, destructive, with its line: \(gpu.reason ?? "-")",
                        gpu.action == .stop && gpu.label == "Stop" && gpu.enabled && gpu.destructive
                            && gpu.reason == "The game's graphics stopped at 21:31:07 — press Stop."))
        x.starting = true; x.allowsMultipleClients = true
        let gpuFirst = Primary.decide(x)
        seen.append(("graphics gone, still 'starting', a second client allowed", gpuFirst))
        results.append(("... ahead of Starting… and of Play Another",
                        gpuFirst.action == .stop && gpuFirst.reason == gpu.reason))
        x = base; x.runningHere = true; x.renderStuckAt = "21:31:07"; x.serverLost = true
        let both = Primary.decide(x)
        seen.append(("graphics and Wine gone", both))
        results.append(("graphics and Wine gone -> Force Stop, no line (the strip already says it)",
                        both.action == .stop && both.label == "Force Stop" && both.reason == nil))
        x = base; x.renderStuckAt = "21:31:07"
        expect("graphics lost with nothing running here changes nothing -> Play", x, .play, reason: .some(nil))
        x = base; x.stopping = true
        expect("a Stop under way with nothing running here changes nothing -> Play", x, .play, reason: .some(nil))
        x = base; x.runningElsewhere = true
        expect("running in another launcher -> Running…", x, .working(.runningElsewhere, progress: nil), enabled: false,
               reason: "Already running from another launcher.")
        x = base; x.restartingLauncher = true
        expect("launcher installing its own update -> Updating…", x, .working(.updating, progress: nil), enabled: false)
        x = base; x.checksPending = true
        expect("checks for another world -> Checking…", x, .working(.checking, progress: nil), enabled: false)
        x = base; x.wineStuck = true
        expect("Wine still closing -> Wine is closing…", x, .working(.closing, progress: nil), enabled: false)

        // Accounts and hosts.
        x = base; x.accountNeeded = true
        expect("no account, HorizonXI's loader can't ask -> Play, enabled, the click goes to the fields", x,
               .enterAccount, enabled: true, reason: "Type your account name and password above.")
        x.accountInLoader = true; x.world = "Eden"
        expect("no account, the loader window creates it -> Play", x, .play, enabled: true)
        x = base; x.hostEmpty = true
        expect("no login host -> Repair (opens the world's settings)", x, .repair(.host), enabled: true,
               reason: "This world has no login address.")
        x = base; x.isLocal = true; x.localReady = true; x.hostEmpty = true
        expect("the local world needs no login host", x, .play)
        x = base; x.wineStuck = true; x.accountNeeded = true
        expect("Wine closing outranks the account line", x, .working(.closing, progress: nil))
        x = base; x.ownJob = "Moving"; x.ownProgress = 0.4
        let mv = Primary.decide(x)
        seen.append(("move running", mv))
        results.append(("a Move -> \"Moving… 40%\" (\(mv.label))", mv.label == "Moving… 40%" && !mv.enabled))

        // Wording, over every state above and every action: the label is one of Daniel's verbs
        // or a running job's progress; one short plain line; no "restart" anywhere.
        let allActions: [PrimaryAction] = [
            .setup(.install), .setup(.rosetta), .setup(.wrapperDrive("x10")), .setup(.dataDrive("Games")), .setup(.wine),
            .setup(.game(partial: false)), .setup(.game(partial: true)), .setup(.chooseFolder), .setup(.gameWine),
            .setup(.localServer(lowSpace: false)), .setup(.localServer(lowSpace: true)),
            .update(world: "HorizonXI", to: "2.0.5"), .update(world: "CatsEyeXI", to: "30251204_1"),
            .repair(.wine), .repair(.mount(drive: "Games", device: "disk9s1")), .repair(.access),
            .repair(.host), .repair(.check(id: "x", line: "x")),
            .stop, .play, .playAnother, .enterAccount,
            .working(.settingUp, progress: nil), .working(.settingUp, progress: 1), .working(.updating, progress: 0.123),
            .working(.repairing, progress: nil), .working(.checking, progress: nil), .working(.starting, progress: nil),
            .working(.stopping, progress: nil), .working(.moving, progress: 0.5), .working(.waiting, progress: nil),
            .working(.runningElsewhere, progress: nil), .working(.closing, progress: nil),
        ]
        for a in allActions { seen.append(("action \(a.id):\(a.detail)", Primary.make(a, base))) }
        // Setup's chain names its step instead of "Setting up" (SetupStage): those are progress too.
        for s in SetupStage.allCases {
            var y = base; y.setupRunning = true; y.setupStage = s; y.setupProgress = 0.37
            seen.append(("Setup step \(s.rawValue)", Primary.decide(y)))
        }
        let names = ["Setting up", "Updating", "Repairing", "Checking", "Starting", "Stopping", "Moving", "Waiting",
                     "Running", "Wine is closing"] + SetupStage.allCases.map(\.rawValue)
        let progress = try! NSRegularExpression(
            pattern: "^(" + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")…( \\d{1,3}%)?$")
        func isProgress(_ l: String) -> Bool {
            progress.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }
        let jargon = ["prefix", "registry", "regsvr", "rpath", "dylib", "wineserver", "COM", "Setup & Diagnostics", "Preflight"]
        var badLabels: [String] = [], badLines: [String] = [], restarts: [String] = []
        for (name, d) in seen {
            if !(Primary.verbs.contains(d.label) || (isProgress(d.label) && !d.enabled)) { badLabels.append("\(name): \(d.label)") }
            let r = d.reason ?? ""
            if r.count > 72 || r.contains("\n") || jargon.contains(where: { r.contains($0) }) { badLines.append("\(name): \(r)") }
            if (d.label + " " + r).lowercased().contains("restart") { restarts.append(name) }
            if case .working = d.action, d.enabled { badLabels.append("\(name): a job's progress is pressable") }
        }
        results.append(("every label is Setup / Update / Repair / Play / Stop / Play Another or a job's progress"
                        + (badLabels.isEmpty ? "" : " -- " + badLabels.joined(separator: "; ")), badLabels.isEmpty))
        results.append(("every reason is one short plain line" + (badLines.isEmpty ? "" : " -- " + badLines.joined(separator: "; ")),
                        badLines.isEmpty))
        results.append(("no 'restart' in any label or reason (Daniel, 2026-10-15)"
                        + (restarts.isEmpty ? "" : " -- " + restarts.joined(separator: "; ")), restarts.isEmpty))
        let lines = [Preflight.driveMessage("Games"), Preflight.driveLine("Games", .ghost), Preflight.driveLine("Games", .absent),
                     Preflight.driveLine("Games", .unmounted(device: "disk9s1"))]
        results.append(("drive lines never say restart",
                        !lines.contains { $0.lowercased().contains("restart") }))
        // Never a greyed-out PLAY (Daniel, 2026-10-15). Every state above and every action:
        // Play / Play Another are always pressable; anything that does not start the game is an
        // enabled Setup / Update / Repair, or a wait's progress label -- the one exception is
        // the missing account, whose PLAY (enabled) puts the cursor in the field.
        var greyPlay: [String] = [], notActionable: [String] = []
        for (name, d) in seen {
            if (d.label == "Play" || d.label == "Play Another"), !d.enabled { greyPlay.append(name) }
            switch d.action {
            case .play, .playAnother, .stop, .enterAccount: break
            case .serverInfo:
                if !d.enabled || d.label != "Server Info" { notActionable.append(name) }
            case .working:
                if d.enabled || !isProgress(d.label) { notActionable.append("\(name): \(d.label)") }
            case .setup, .update, .repair:
                if !d.enabled || !["Setup", "Update", "Repair"].contains(d.label) { notActionable.append("\(name): \(d.label)") }
            }
        }
        results.append(("label Play / Play Another => enabled, in every state"
                        + (greyPlay.isEmpty ? "" : " -- " + greyPlay.joined(separator: "; ")), greyPlay.isEmpty))
        results.append(("every state that is not Play offers an enabled next action or a progress label"
                        + (notActionable.isEmpty ? "" : " -- " + notActionable.joined(separator: "; ")), notActionable.isEmpty))
        results.append(("Play shows only where the click starts the game, or (no account) goes to the fields",
                        seen.allSatisfy { !$0.1.label.hasPrefix("Play") || ([.play, .playAnother, .enterAccount] as [PrimaryAction]).contains($0.1.action) }))
        results.append(("only Stop is kept off Return",
                        seen.allSatisfy { $0.1.destructive == ($0.1.action == .stop) }))
        results.append(("Play and Play Another have no reason line (the account's Play has its one line)",
                        Primary.make(.play, base).reason == nil && Primary.make(.playAnother, base).reason == nil))

        // Repair refuses before writing when the data is behind a missing drive, and names it.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ffxi-primary-\(UUID().uuidString)", isDirectory: true)
        let gone = "NoSuchDrive-\(UUID().uuidString.prefix(8))"
        let fake = Install(wrapper: tmp.appendingPathComponent("fake.app"), prefixName: "prefix")
        try? fm.createDirectory(at: fake.gameDir, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: fake.gameDir.appendingPathComponent("SquareEnix").path,
                                   withDestinationPath: "/Volumes/\(gone)/FFXI/SquareEnix")
        let why = Runner.repairBlocker(fake) ?? ""
        results.append(("Repair refuses on a missing drive, naming it: \(why)",
                        why.contains("'\(gone)'") && why.contains("nothing was changed") && !why.lowercased().contains("restart")))
        results.append(("an unknown drive is 'absent'", Preflight.driveState(gone) == .absent))
        try? fm.removeItem(at: fake.gameDir.appendingPathComponent("SquareEnix"))
        try? fm.createDirectory(at: fake.squareEnix.appendingPathComponent("FINAL FANTASY XI"), withIntermediateDirectories: true)
        let missing = Runner.repairBlocker(fake) ?? ""
        results.append(("Repair refuses on missing DLLs, naming them", missing.contains("FFXi.dll") && missing.contains("FFXiMain.dll")))
        for d in ["FFXi.dll", "FFXiMain.dll", "FFXiVersions.dll"] {
            fm.createFile(atPath: fake.squareEnix.appendingPathComponent("FINAL FANTASY XI/\(d)").path, contents: Data())
        }
        results.append(("Repair proceeds when the DLLs are there", Runner.repairBlocker(fake) == nil))
        results.append(("the mount table lists /", Preflight.mountTableLists("/")))
        results.append(("headless fixes are only the jobs that need no person",
                        PrimaryFixer.isHeadlessFixable(.repair(.wine)) && PrimaryFixer.isHeadlessFixable(.repair(.mount(drive: "a", device: "b")))
                            && PrimaryFixer.isHeadlessFixable(.setup(.game(partial: false)))
                            && PrimaryFixer.isHeadlessFixable(.update(world: "HorizonXI", to: "2.0.5"))
                            && PrimaryFixer.isHeadlessFixable(.repair(.check(id: "x", line: "x")))
                            && !PrimaryFixer.isHeadlessFixable(.repair(.host)) && !PrimaryFixer.isHeadlessFixable(.enterAccount)
                            && !PrimaryFixer.isHeadlessFixable(.setup(.install)) && !PrimaryFixer.isHeadlessFixable(.setup(.dataDrive("a")))
                            && !PrimaryFixer.isHeadlessFixable(.play) && !PrimaryFixer.isHeadlessFixable(.repair(.access))
                            && !PrimaryFixer.isHeadlessFixable(.stop)
                            // They need a person: a password prompt, a place to put it.
                            && !PrimaryFixer.isHeadlessFixable(.setup(.rosetta)) && !PrimaryFixer.isHeadlessFixable(.setup(.gameWine))))

        // Rosetta's answer, injected (FFXI_ON_MAC_ROSETTA), and this Mac's own (read-only: arch -x86_64 true).
        let savedFlag = ProcessInfo.processInfo.environment["FFXI_ON_MAC_ROSETTA"]
        setenv("FFXI_ON_MAC_ROSETTA", "missing", 1)
        let saysMissing = Bootstrap.rosettaMissing()
        let probed = Primary.probe(fake, profile: "horizonxi.ini", horizon: true, requiredClient: "").rosettaMissing
        setenv("FFXI_ON_MAC_ROSETTA", "present", 1)
        let saysPresent = !Bootstrap.rosettaMissing()
        unsetenv("FFXI_ON_MAC_ROSETTA")
        let runs = Bootstrap.rosettaRuns()
        results.append(("Rosetta: the injected flag is read (missing, and by the probe; present)", saysMissing && probed && saysPresent))
        results.append(("Rosetta on this Mac: \(runs ? "x86_64 runs" : "missing"); rosettaMissing agrees", Bootstrap.rosettaMissing() == !runs))
        if let f = savedFlag { setenv("FFXI_ON_MAC_ROSETTA", f, 1) }
        try? fm.removeItem(at: tmp)

        var failed = 0
        for (name, ok) in results {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failed += 1 }
        }
        print("\(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
