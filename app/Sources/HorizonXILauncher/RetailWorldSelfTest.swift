import Foundation

/// `--selftest-retail-world`: RetailWorldSync (MistXI's spec) against a fake site on 127.0.0.1 with a
/// fake donor client: the retail list, Ashita's archive, the pinned loader, profile and script.
extension Headless {
    @MainActor static func runRetailWorldSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("retail-world-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        func write(_ d: Data, _ u: URL) {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: u)
        }

        // Pure parts.
        check("loaders: one LandSandBoat release per series, from their GitHub",
              RetailWorld.loaders["2.1"]?.version == "2.1.2" && RetailWorld.loaders["2.2"]?.version == "2.2.0"
                && RetailWorld.loaders["2.0"]?.version == "2.0.1"
                && RetailWorld.loaders.values.allSatisfy { $0.url.hasPrefix("https://github.com/LandSandBoat/xiloader/releases/download/v\($0.version)/") && $0.sha256.count == 64 })
        check("specs: MistXI on 2.1, Moghouse XI and LevelDown 99 on 2.2; only LevelDown 99 brings its own client",
              RetailWorld.spec("MistXI")?.loader.version == "2.1.2" && RetailWorld.spec("Moghouse XI")?.loader.version == "2.2.0"
                && RetailWorld.spec("LevelDown 99")?.loader.version == "2.2.0" && RetailWorld.spec("LevelDown 99")?.archive != nil
                && RetailWorld.spec("MistXI")?.archive == nil && RetailWorld.spec("HorizonXI") == nil)
        let prof = RetailWorld.profile(fromExample: "[ashita.launcher]\r\nname        = Example\r\n[ashita.boot]\r\nfile        = .\\\\bootloader\\\\pol.exe\r\ncommand     = --server homepointxi.com\r\nscript      = default.txt\r\n", spec: RetailWorld.mist)
        check("profile: xiloader, --server play.mistxi.com, mistxi.txt, named MistXI",
              BootProfile.loaderName(in: prof) == "xiloader.exe" && BootProfile.value("command", section: "ashita.boot", in: prof) == "--server play.mistxi.com"
                && BootProfile.value("script", section: "ashita.boot", in: prof) == "mistxi.txt" && BootProfile.value("name", section: "ashita.launcher", in: prof) == "MistXI")
        let sc = RetailWorld.script(RetailWorld.mist)
        check("script: Ashita's own plugins incl. winefix, the wait, no addons forced on",
              sc.contains("/load addons\r\n") && sc.contains("/load winefix\r\n") && sc.contains("/wait 3") && !sc.contains("/addon load"))
        let wiki = "Use these downloads ...\n\n=== '''FFXI Version 30260203_0''' ===\n\n* https://drive.google.com/file/d/1_WXohtOdVd1rUyGcK8eCfyYd2fEXp2HT/view?usp=drive_link\n\n== Out of Date Versions ==\n=== '''<s>FFXI Version 30251003_3</s>''' ===\n* <s>https://drive.google.com/file/d/OLD/view</s>\n"
        check("archive page: the current version and its Drive file, never a struck-out one",
              RetailWorld.currentArchive(wikitext: wiki).map { $0.version == "30260203_0" && $0.fileID == "1_WXohtOdVd1rUyGcK8eCfyYd2fEXp2HT" } == true
                && RetailWorld.currentArchive(wikitext: "== Out of Date Versions ==\n=== <s>FFXI Version 30251003_3</s> ===\n* https://drive.google.com/file/d/OLD/view") == nil
                && RetailWorld.wikitext(Data(#"{"parse":{"title":"x","wikitext":{"*":"hi"}}}"#.utf8)) == "hi")
        let pol = RetailWorld.mistPolicy
        check("addons: MistXI's list allows hxui and winefix, not skeletonkey",
              pol.isRestricting && pol.allows("hxui") && pol.allows("winefix") && !pol.allows("skeletonkey") && !pol.allows("notonthelist"))

        // A fake site and a donor client.
        let ch = TestChannel()
        guard (try? ch.start()) != nil, ch.port != 0 else { print("  FAIL could not listen"); exit(1) }
        let site = "http://127.0.0.1:\(ch.port)"
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let donor = tmp.appendingPathComponent("Other/SquareEnix")
        let main = Data("ffximain".utf8), dat = Data(repeating: 3, count: 300)
        write(main, donor.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll"))
        write(dat, donor.appendingPathComponent("FINAL FANTASY XI/ROM/1/1.DAT"))
        write(Data("pol".utf8), donor.appendingPathComponent("PlayOnlineViewer/viewer/com/polcore.dll"))
        let files: [[String: Any]] = [["path": "FFXiMain.dll", "size": main.count, "sha256": AscensionChannel.sha256(main)],
                                      ["path": "ROM\\1\\1.DAT", "size": dat.count, "sha256": AscensionChannel.sha256(dat)]]
        ch.put("/api/manifest", try! JSONSerialization.data(withJSONObject: ["build": "30260904_1", "files": files]), t0)
        // Ashita's archive, GitHub-style: one top folder.
        let src = tmp.appendingPathComponent("ashita-src/Ashita-v4beta-abc")
        let example = "[ashita.launcher]\r\nname        = Example\r\n[ashita.boot]\r\nfile        = .\\\\bootloader\\\\pol.exe\r\ncommand     = --server homepointxi.com\r\nscript      = default.txt\r\n"
        for (k, v) in ["Ashita-cli.exe": "cli", "config/boot/example-privateserver.ini": example, "scripts/default.txt": "/load addons\r\n",
                       "addons/skeletonkey/skeletonkey.lua": "-- no", "addons/hxui/hxui.lua": "-- ok", "plugins/winefix.dll": "wf"] {
            write(Data(v.utf8), src.appendingPathComponent(k))
        }
        let zipURL = tmp.appendingPathComponent("ashita.zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", src.path, zipURL.path]
        try? p.run(); p.waitUntilExit()
        ch.put("/ashita.zip", (try? Data(contentsOf: zipURL)) ?? Data(), t0)
        let loaderBytes = Data("xiloader 2.1.2".utf8)
        ch.put("/xiloader.exe", loaderBytes, t0)
        var sources = RetailWorld.Sources(retailList: site + "/api/manifest", ashitaZip: site + "/ashita.zip", ashitaCommit: "abc",
                                          loader: .init(version: "2.1.2", sha256: AscensionChannel.sha256(loaderBytes), url: site + "/xiloader.exe"))
        let root = tmp.appendingPathComponent("MistXI")
        func sync(_ s: RetailWorld.Sources? = nil, install: Bool = false, donors: [URL]? = nil, stop: StopFlag = StopFlag()) -> AscensionSync.Outcome {
            ch.clearLog()
            return RetailWorldSync(spec: RetailWorld.mist, root: root, sources: s ?? sources, stop: stop, log: { _ in })
                .run(install: install, donors: donors ?? [donor])
        }
        func file(_ rel: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(rel)) }
        func text(_ rel: String) -> String { file(rel).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

        let first = sync(install: true)
        check("install: succeeds", { if case .ok = first { return true }; return false }())
        check("install: the retail client from the donor, under Game/, with PlayOnline Viewer",
              file("Game/FINAL FANTASY XI/FFXiMain.dll") == main && file("Game/FINAL FANTASY XI/ROM/1/1.DAT") == dat
                && file("Game/PlayOnlineViewer/viewer/com/polcore.dll") == Data("pol".utf8))
        check("install: Ashita in Ashita/ (top folder dropped), the pinned loader in bootloader/",
              file("Ashita/Ashita-cli.exe") == Data("cli".utf8) && file("Ashita/bootloader/xiloader.exe") == loaderBytes)
        check("install: the addons their launcher removes are gone, the rest kept",
              file("Ashita/addons/skeletonkey/skeletonkey.lua") == nil && file("Ashita/addons/hxui/hxui.lua") != nil)
        let ini = text("Ashita/config/boot/mistxi.ini")
        check("install: mistxi.ini boots xiloader at play.mistxi.com with mistxi.txt",
              BootProfile.value("command", section: "ashita.boot", in: ini) == "--server play.mistxi.com"
                && BootProfile.value("script", section: "ashita.boot", in: ini) == "mistxi.txt" && text("Ashita/scripts/mistxi.txt").contains("/load addons"))

        let second = sync(donors: [])
        check("Play, nothing new: only the list is asked for (304); no Ashita, no loader",
              second == .ok(changed: 0) && ch.log == ["/api/manifest 304"])
        // The player's own profile is theirs.
        try? Data((ini + "; mine\r\n").utf8).write(to: root.appendingPathComponent("Ashita/config/boot/mistxi.ini"))
        // A damaged loader is replaced; a download that is not the pinned release is refused.
        try? Data("old".utf8).write(to: root.appendingPathComponent("Ashita/bootloader/xiloader.exe"))
        check("a loader that is not the pinned release is replaced", sync(donors: []) == .ok(changed: 1)
              && file("Ashita/bootloader/xiloader.exe") == loaderBytes && text("Ashita/config/boot/mistxi.ini").hasSuffix("; mine\r\n"))
        var bad = sources; bad.loader?.sha256 = String(repeating: "0", count: 64)
        try? fm.removeItem(at: root.appendingPathComponent("Ashita/bootloader/xiloader.exe"))
        check("a loader download that does not hash to the pin is refused",
              { if case .failed(let why) = sync(bad, donors: []) { return why.contains("damaged") }; return false }()
                && file("Ashita/bootloader/xiloader.exe") == nil)
        _ = sync(donors: [])
        // A new Ashita pin is installed over the old one; the player's profile survives it.
        sources.ashitaCommit = "def"
        check("a new Ashita pin: Ashita again, the profile kept",
              { if case .ok(let n) = sync(donors: []) { return n >= 1 }; return false }() && ch.log.contains("/ashita.zip 200")
                && text("Ashita/config/boot/mistxi.ini").hasSuffix("; mine\r\n"))
        // No donor for a file of the list.
        let extra = Data("x".utf8)
        let more = files + [["path": "ROM/2/2.DAT", "size": extra.count, "sha256": AscensionChannel.sha256(extra)]]
        ch.put("/api/manifest", try! JSONSerialization.data(withJSONObject: ["build": "30260904_1", "files": more]), t0.addingTimeInterval(60))
        check("a retail file not on this Mac: refused, naming it",
              { if case .failed(let why) = sync() { return why.contains("ROM/2/2.DAT") }; return false }())
        ch.put("/api/manifest", try! JSONSerialization.data(withJSONObject: ["build": "30260904_1", "files": files]), t0.addingTimeInterval(120))
        _ = sync()
        let down = RetailWorld.Sources(retailList: "http://127.0.0.1:9/m", ashitaZip: sources.ashitaZip, ashitaCommit: sources.ashitaCommit, loader: sources.loader)
        check("offline after a finished update: play with what is there", { if case .offline = sync(down) { return true }; return false }())
        let flag = StopFlag(); flag.raise()
        check("stop: .stopped", sync(stop: flag) == .stopped)

        // A world that hands out its own client archive (LevelDown 99's shape): 7-Zip, with a USER/ folder.
        let arcSrc = tmp.appendingPathComponent("arc-src")
        for (k, v) in ["FFXiMain.dll": "old main", "ROM/1/1.DAT": "old dat", "VTABLE.DAT": "old vtable", "patch.cfg": "30260203_0",
                       "USER/186/mcr.dat": "someone else's macros"] { write(Data(v.utf8), arcSrc.appendingPathComponent(k)) }
        let arcFile = tmp.appendingPathComponent("client.7z")
        let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        z.currentDirectoryURL = arcSrc
        z.arguments = ["-c", "--format", "7zip", "-f", arcFile.path, "FFXiMain.dll", "ROM", "VTABLE.DAT", "patch.cfg", "USER"]
        try? z.run(); z.waitUntilExit()
        ch.put("/drive/LDFILE", (try? Data(contentsOf: arcFile)) ?? Data(), t0)
        ch.put("/wiki.json", try! JSONSerialization.data(withJSONObject: ["parse": ["wikitext": ["*": wiki.replacingOccurrences(of: "1_WXohtOdVd1rUyGcK8eCfyYd2fEXp2HT", with: "LDFILE")]]]), t0)
        let ldRoot = tmp.appendingPathComponent("LevelDown 99")
        var ldSrc = sources; ldSrc.archivePage = site + "/wiki.json"; ldSrc.archiveDownload = { site + "/drive/" + $0 }
        func ld(install: Bool = false, stop: StopFlag = StopFlag()) -> AscensionSync.Outcome {
            ch.clearLog()
            return RetailWorldSync(spec: RetailWorld.levelDown, root: ldRoot, sources: ldSrc, stop: stop, log: { _ in }).run(install: install, donors: [donor])
        }
        func ldFile(_ rel: String) -> Data? { try? Data(contentsOf: ldRoot.appendingPathComponent(rel)) }
        let ldFirst = ld(install: true)
        check("archive world: their client unpacked into Game/FINAL FANTASY XI, with the viewer and xiloader",
              { if case .ok = ldFirst { return true }; return false }() && ldFile("Game/FINAL FANTASY XI/FFXiMain.dll") == Data("old main".utf8)
                && ldFile("Game/FINAL FANTASY XI/ROM/1/1.DAT") == Data("old dat".utf8) && ldFile("Game/PlayOnlineViewer/viewer/com/polcore.dll") != nil
                && ldFile("Ashita/bootloader/xiloader.exe") == loaderBytes)
        check("archive world: the USER folder inside their archive is never installed (an empty one is made)",
              !fm.fileExists(atPath: ldRoot.appendingPathComponent("Game/FINAL FANTASY XI/USER/186").path)
                && fm.fileExists(atPath: ldRoot.appendingPathComponent("Game/FINAL FANTASY XI/USER").path))
        check("archive world, Play: only their page is asked for", ld() == .ok(changed: 0) && ch.log == ["/wiki.json 200"])
        try? Data("broken".utf8).write(to: ldRoot.appendingPathComponent("Game/FINAL FANTASY XI/FFXiMain.dll"))
        check("archive world, Repair: unpacked again from the kept archive, not downloaded again",
              { if case .ok = ld(install: true) { return true }; return false }() && !ch.log.contains("/drive/LDFILE 200")
                && ldFile("Game/FINAL FANTASY XI/FFXiMain.dll") == Data("old main".utf8))
        let ldStop = StopFlag(); ldStop.raise()
        check("archive world: stop", ld(install: true, stop: ldStop) == .stopped)

        // The launcher around it.
        let mist = Server.all.first { $0.name == "MistXI" }, mog = Server.all.first { $0.name == "Moghouse XI" }
        check("built-in: MistXI (2 clients, their list, website account) and Moghouse XI (Create account, 1 client)",
              mist?.installKind == .retailWorld && mog?.installKind == .retailWorld && mist?.codebase == .landSandBoat
                && mist?.maxClients == 2 && mist.map { AddonPolicies.policy(for: $0).isRestricting } == true && mist?.createsAccountAtLogin == false
                && mog?.createsAccountAtLogin == true && mog?.maxClients == 1 && mog?.host == "ffxi.cc"
                && mist?.installKind.updatesBeforePlay == true)
        let enc = mist.flatMap { try? JSONEncoder().encode([$0]) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("servers.json: its kind is stored as one older builds read", enc.contains("\"installKind\":\"website\""))

        ch.stop()
        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        try? fm.removeItem(at: tmp)   // exit() runs no defer
        exit(failures == 0 ? 0 : 1)
    }

    /// `--retail-world-sync --world <name> [--install] [--root <folder>]`: a plain retail world's install
    /// or update, headless, with every other world's client offered as a donor. Never launches the game.
    @MainActor static func runRetailWorldSync(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)   // a line at a time, also into a file
        guard let k = args.firstIndex(of: "--world"), k + 1 < args.count, let spec = RetailWorld.spec(args[k + 1]) else {
            FileHandle.standardError.write(Data("pass --world \(RetailWorld.all.map { "\"\($0.world)\"" }.joined(separator: " or "))\n".utf8)); exit(2)
        }
        let store = ServerStore()
        var rootPath = store.servers.first { $0.name == spec.world }?.dataPath ?? ""
        if let r = args.firstIndex(of: "--root"), r + 1 < args.count { rootPath = args[r + 1] }
        guard !rootPath.isEmpty else { FileHandle.standardError.write(Data("pass --root <folder>\n".utf8)); exit(2) }
        guard let base = InstallSelection.inUse() ?? Install.lastChosen() else {
            FileHandle.standardError.write(Data("no install found\n".utf8)); exit(2)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let donors = AscensionChannel.donorClients(store.servers.filter { $0.name != spec.world }, base: base)
        for d in donors { print("donor: \(d.path)") }
        var last = -1
        let sync = RetailWorldSync(spec: spec, root: root, log: { print($0) }, progress: { label, f in
            let pct = Int(f * 100)
            if pct != last, pct % 5 == 0 { last = pct; print("   \(label) \(pct)%") }
        })
        var outcome: AscensionSync.Outcome = .failed("not run")
        let done = DispatchSemaphore(value: 0)
        let install = args.contains("--install")
        Thread.detachNewThread { outcome = sync.run(install: install, donors: donors); done.signal() }
        while done.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print("outcome: \(outcome)")
        switch outcome { case .ok, .offline: exit(0); default: exit(1) }
    }
}
