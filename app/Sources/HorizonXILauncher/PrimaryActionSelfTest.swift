import Foundation

/// `--selftest-primary-action`: every state the main button can be in, from plain inputs, plus
/// Repair's refusal on a fixture whose data sits behind a missing drive. Writes only to a
/// temporary folder; reads nothing of the real install.
extension Headless {
    @MainActor static func runPrimaryActionSelfTest() -> Never {
        var results: [(String, Bool)] = []
        func bad(_ id: String, drive: String? = nil) -> Check {
            Check(id: id, title: id, state: .bad, detail: "", short: "\(id) short", drive: drive)
        }
        func expect(_ name: String, _ x: PrimaryInputs, _ want: PrimaryAction, enabled: Bool? = nil) {
            let d = Primary.decide(x)
            var ok = d.action == want
            if let e = enabled { ok = ok && d.enabled == e }
            results.append((name + "  -> \(d.action.id) \"\(d.label)\"", ok))
        }
        var base = PrimaryInputs()
        base.checks = [Check(id: "wine", title: "Wine", state: .ok, detail: "")]

        expect("ready -> Play", base, .play, enabled: true)

        // Drives.
        var x = base; x.checks = [bad("squareenix", drive: "Games"), bad("reg32")]; x.driveStates = ["Games": .ghost]
        expect("ghost 'Games' (Daniel 2026-10-15) -> Restart Mac, never Repair", x, .restartMac(drive: "Games"), enabled: true)
        x.driveStates = ["Games": .unmounted(device: "disk9s1")]
        expect("unmounted drive -> Mount (diskutil, no admin)", x, .mountDrive(drive: "Games", device: "disk9s1"))
        x.driveStates = ["Games": .absent]
        expect("unplugged drive -> Connect (disabled)", x, .connectDrive(drive: "Games"), enabled: false)
        x.driveStates = [:]
        expect("drive with unknown state -> Connect", x, .connectDrive(drive: "Games"))
        x = base; x.checks = [bad("volume", drive: "x10")]; x.driveStates = ["x10": .ghost]
        expect("wrapper's own volume ghosted -> Restart Mac", x, .restartMac(drive: "x10"))

        // No install.
        x = base; x.hasInstall = false; x.scanning = true
        expect("no install, scanning -> working", x, .working("Looking for your install", progress: nil), enabled: false)
        x.scanning = false
        expect("no install -> Install Wine", x, .installWine, enabled: true)
        x.rememberedDrive = "x10"; x.driveStates = ["x10": .absent]
        expect("remembered install on unplugged drive -> Connect, not Install Wine", x, .connectDrive(drive: "x10"))

        // Access, wine, game files.
        x = base; x.checks = [bad("fda"), bad("wine")]
        expect("Full Disk Access + wine failing -> Allow Access", x, .allowAccess)
        x = base; x.checks = [bad("wine"), bad("client")]
        expect("wine missing -> Install Wine", x, .installWine)
        x = base; x.hasGame = false; x.checks = [bad("client"), bad("squareenix"), bad("ashita")]
        expect("no client -> Download HorizonXI", x, .downloadGame(world: "HorizonXI"))
        x = base; x.checks = [bad("ashita")]
        expect("Ashita missing -> Download", x, .downloadGame(world: "HorizonXI"))
        x = base; x.checks = [bad("squareenix")]
        expect("data missing on a present drive -> Download", x, .downloadGame(world: "HorizonXI"))
        x.canDownload = false; x.world = "Nowhere"
        expect("data missing, no download route -> Choose folder", x, .chooseFolder(world: "Nowhere"))
        x = base; x.checks = [bad("worldclient")]
        expect("ambiguous client folder -> Choose folder", x, .chooseFolder(world: "HorizonXI"))

        // Repair vs fixed by Play.
        x = base; x.checks = [bad("rpath"), bad("reg32")]
        expect("rpath -> Repair", x, .repair, enabled: true)
        x = base; x.checks = [bad("reg32"), bad("reglayout"), bad("com"), bad("sandbox")]
        expect("registry/COM/sandbox only -> Play (Play fixes them)", x, .play, enabled: true)
        x = base; x.checks = [bad("mystery")]
        expect("unknown failing check -> blocked with its line", x, .blocked("mystery short"), enabled: false)

        // Game wine.
        x = base; x.patchedWineMissing = true
        expect("wine-coop missing -> Game Wine Needed (disabled)", x, .needGameWine, enabled: false)
        x.checks = [bad("rpath")]
        expect("wine-coop missing but Repair first", x, .repair)

        // Updates.
        x = base; x.horizonInstalled = "2.0.4"; x.horizonLatest = "2.0.5"
        expect("HorizonXI behind -> Update", x, .updateGame(world: "HorizonXI", to: "2.0.5"))
        x.updateDeferred = true
        expect("update deferred this session -> Play", x, .play)
        x = base; x.horizonInstalled = "2.0.5"; x.horizonLatest = "2.0.5"
        expect("HorizonXI current -> Play", x, .play)
        x = base; x.world = "CatsEyeXI"; x.clientRequired = "30251204_1"; x.clientInstalled = "30240101_0"; x.canUpdateClient = true
        expect("CatsEye client too old -> Update", x, .updateGame(world: "CatsEyeXI", to: "30251204_1"))
        x.canUpdateClient = false; x.world = "Eden"
        expect("client too old, no updater -> disabled line", x, .clientTooOld(have: "30240101_0", need: "30251204_1"), enabled: false)

        // Busy, running, waiting.
        x = base; x.ownJob = "Downloading"; x.ownProgress = 0.42
        let dl = Primary.decide(x)
        results.append(("own download -> \"\(dl.label)\" disabled with progress",
                        dl.action == .working("Downloading", progress: 0.42) && !dl.enabled && dl.label == "Downloading 42%"))
        x = base; x.ownJob = "Repairing"; x.checks = [bad("squareenix", drive: "Games")]
        expect("busy outranks a missing drive", x, .working("Repairing", progress: nil))
        x = base; x.otherJob = "Updating"
        expect("another world's job -> wait", x, .wait("Updating"), enabled: false)
        x = base; x.starting = true
        expect("starting -> working", x, .working("Starting", progress: nil))
        x = base; x.runningHere = true
        let stop = Primary.decide(x)
        results.append(("running here -> Stop, never on Return", stop.action == .stop && stop.destructive && stop.enabled))
        x.allowsMultipleClients = true
        expect("running, second client allowed -> Play Another", x, .playAnother)
        x = base; x.runningElsewhere = true
        expect("running in another launcher -> disabled", x, .runningElsewhere, enabled: false)
        x = base; x.restartingLauncher = true
        expect("launcher restarting -> disabled", x, .restartingLauncher, enabled: false)
        x = base; x.checksPending = true
        expect("checks for another world -> Checking…", x, .checking, enabled: false)
        x = base; x.wineStuck = true
        expect("wineserver stuck -> wait", x, .wait("Wine is still closing."), enabled: false)

        // Accounts, hosts, local server.
        x = base; x.accountNeeded = true
        expect("no account -> Add Account", x, .enterAccount)
        x.isLocal = true; x.localReady = true
        expect("local world needs no account", x, .play)
        x = base; x.isLocal = true; x.localReady = false
        expect("local server not built -> Set Up Server", x, .setUpLocalServer)
        x.localReady = nil
        expect("local status loading -> working", x, .working("Checking the server", progress: nil))
        x = base; x.hostEmpty = true
        expect("no login host -> blocked", x, .blocked("This world has no login address."))

        // Wording rules: short labels, one short reason line, no jargon, Return never on
        // Stop / Restart Mac.
        let all: [PrimaryAction] = [.stop, .runningElsewhere, .restartMac(drive: "Games"),
            .mountDrive(drive: "Games", device: "disk9s1"), .connectDrive(drive: "Games"), .allowAccess,
            .installWine, .needGameWine, .downloadGame(world: "HorizonXI"), .chooseFolder(world: "HorizonXI"),
            .repair, .updateGame(world: "HorizonXI", to: "2.0.5"), .clientTooOld(have: "30240101_0", need: "30251204_1"),
            .setUpLocalServer, .enterAccount, .play, .playAnother, .checking]
        let jargon = ["prefix", "registry", "regsvr", "rpath", "dylib", "wineserver", "COM", "Setup & Diagnostics", "Preflight"]
        for a in all {
            let d = Primary.make(a, base)
            let r = d.reason ?? ""
            let shortOK = d.label.count <= 20 && r.count <= 60 && !r.contains("\n")
            let plain = !jargon.contains { r.contains($0) || d.label.contains($0) }
            let returnOK = !(a == .stop || a.id == "restart-mac") || d.destructive
            results.append(("wording: \(a.id) short=\(shortOK) plain=\(plain) return=\(returnOK)", shortOK && plain && returnOK))
        }
        results.append(("Play and Play Another have no reason line",
                        Primary.make(.play, base).reason == nil && Primary.make(.playAnother, base).reason == nil))

        // Repair refuses before writing when the data is behind a missing drive, and names it.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ffxi-primary-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let gone = "NoSuchDrive-\(UUID().uuidString.prefix(8))"
        let fake = Install(wrapper: tmp.appendingPathComponent("fake.app"), prefixName: "prefix")
        try? fm.createDirectory(at: fake.gameDir, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: fake.gameDir.appendingPathComponent("SquareEnix").path,
                                   withDestinationPath: "/Volumes/\(gone)/FFXI/SquareEnix")
        let why = Runner.repairBlocker(fake) ?? ""
        results.append(("Repair refuses on a missing drive, naming it", why.contains("'\(gone)'") && why.contains("nothing was changed")))
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
        results.append(("headless fixes are only the no-person ones",
                        PrimaryFixer.isHeadlessFixable(.repair) && PrimaryFixer.isHeadlessFixable(.mountDrive(drive: "a", device: "b"))
                            && !PrimaryFixer.isHeadlessFixable(.restartMac(drive: "a")) && !PrimaryFixer.isHeadlessFixable(.play)
                            && !PrimaryFixer.isHeadlessFixable(.allowAccess) && !PrimaryFixer.isHeadlessFixable(.stop)))

        var failed = 0
        for (name, ok) in results {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failed += 1 }
        }
        print("\(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
