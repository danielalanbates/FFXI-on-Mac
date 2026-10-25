import Foundation

/// `--selftest-driftwood`: DriftwoodSync against a fake site on 127.0.0.1 (TestChannel), in a
/// temporary folder, with a fake donor client beside it: their client list, Ashita bundle and core,
/// content packages, profile and script.
extension Headless {
    @MainActor static func runDriftwoodSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("driftwood-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        func write(_ d: Data, _ u: URL) {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: u)
        }

        // Pure parts.
        let cm = DriftwoodChannel.parseClientManifest(Data(#"{"build":"30260904_1","files":[{"path":"ROM\\1\\1.DAT","size":3,"sha256":"AB"}]}"#.utf8))
        check("client list: backslashes become folders, hashes lower-cased", cm?.first?.path == "ROM/1/1.DAT" && cm?.first?.sha256 == "ab" && cm?.first?.size == 3)
        let b = DriftwoodChannel.parseAshita(Data(#"{"version":"v1","url":"u","sha256":"AA","core":{"version":"4.3.2.1","url":"c","sha256":"BB","files":[{"path":"plugins\\x.dll","sha256":"CC","size":1}]}}"#.utf8))
        check("ashita.json: bundle and core with their files", b?.version == "v1" && b?.core?.version == "4.3.2.1" && b?.core?.files.first?.path == "plugins/x.dll" && b?.core?.sha256 == "bb")
        check("core files go only where their launcher puts them",
              DriftwoodChannel.coreFileAllowed("Ashita.dll") && DriftwoodChannel.coreFileAllowed("config/ashita/ashita.datmap.ini")
                && DriftwoodChannel.coreFileAllowed("plugins/addons.dll") && DriftwoodChannel.coreFileAllowed("polplugins/sandbox.dll")
                && !DriftwoodChannel.coreFileAllowed("config/boot/driftwood.ini") && !DriftwoodChannel.coreFileAllowed("addons/x/x.lua")
                && !DriftwoodChannel.coreFileAllowed("../Ashita.dll") && !DriftwoodChannel.coreFileAllowed("plugins/x.lua")
                && !DriftwoodChannel.coreFileAllowed("other.dll"))
        let pk = DriftwoodChannel.parseContent(Data(#"{"packages":[{"id":"dwah","kind":"ashita-addon","version":"1","url":"u","sha256":"AA","treeHash":"BB"},{"id":"../x","url":"u","sha256":"a","treeHash":"b"},{"id":"tex","kind":"texture-pack","url":"u","sha256":"a","treeHash":"b"}]}"#.utf8))
        check("content.json: addon packages only, unsafe names dropped", pk?.map(\.id) == ["dwah"] && pk?.first?.treeHash == "bb")
        // Their hashTree, by hand: "a.lua\0" "1\0" sha("x") "\n" then "sub/b.txt\0" "2\0" sha("yz") "\n".
        let th = tmp.appendingPathComponent("th")
        write(Data("x".utf8), th.appendingPathComponent("A.lua")); write(Data("yz".utf8), th.appendingPathComponent("sub/b.txt"))
        let want = AscensionChannel.sha256(Data("a.lua\u{0}1\u{0}\(AscensionChannel.sha256(Data("x".utf8)))\nsub/b.txt\u{0}2\u{0}\(AscensionChannel.sha256(Data("yz".utf8)))\n".utf8))
        check("treeHash: lower-cased paths in order, size and sha256 of each", DriftwoodChannel.treeHash(of: th) == want)
        write(Data(LuaJITGuard.shim.utf8) + Data("x".utf8), th.appendingPathComponent("A.lua"))
        check("treeHash: an entry file with LuaJITGuard's lines in front counts as the same",
              DriftwoodChannel.treeHash(of: th, entry: "a.lua") == want && DriftwoodChannel.treeHash(of: th) != want)
        write(Data("finder".utf8), th.appendingPathComponent(".DS_Store")); write(Data("ad".utf8), th.appendingPathComponent("sub/._b.txt"))
        check("treeHash: skipFinderFiles leaves out Finder's .DS_Store and ._* files; without it they count",
              DriftwoodChannel.treeHash(of: th, entry: "a.lua", skipFinderFiles: true) == want && DriftwoodChannel.treeHash(of: th, entry: "a.lua") != want)
        let prof = DriftwoodChannel.profile(fromExample: "[ashita.launcher]\r\nname        = Example\r\n[ashita.boot]\r\nfile        = .\\\\bootloader\\\\pol.exe\r\ncommand     = --server homepointxi.com\r\nscript      = default.txt\r\n[ashita.polplugins]\r\nsandbox = 0\r\n")
        check("profile: their loader, server and script, the rest of the example kept",
              BootProfile.loaderName(in: prof) == "xiloader.exe" && BootProfile.value("command", section: "ashita.boot", in: prof) == "--server xi.driftwoodgaming.com"
                && BootProfile.value("script", section: "ashita.boot", in: prof) == "driftwood.txt"
                && BootProfile.value("name", section: "ashita.launcher", in: prof) == "DriftwoodXI"
                && BootProfile.value("sandbox", section: "ashita.polplugins", in: prof) == "0")
        let sc = DriftwoodChannel.script(addons: ["dwah", "dwbags"])
        check("script: their plugins and addons, never bigmode or fps",
              sc.contains("/load winefix\r\n") && sc.contains("/load thirdparty\r\n") && sc.contains("/addon load dwbags\r\n")
                && !sc.contains("bigmode") && !sc.contains("/load fps"))
        let pol = DriftwoodChannel.addonPolicy
        check("addons: their list allows dwah, HXUI and winefix, not an addon off it, nor the two their launcher blocks",
              pol.isRestricting && pol.allows("dwah") && pol.allows("HXUI") && pol.allows("winefix") && !pol.allows("notonthelist")
                && !pol.allows("bigmode") && !pol.allows("chatfix"))

        // A fake site and a donor client.
        let ch = TestChannel()
        guard (try? ch.start()) != nil, ch.port != 0 else { print("  FAIL could not listen"); exit(1) }
        let site = "http://127.0.0.1:\(ch.port)"
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func zip(_ files: [String: Data]) -> Data {
            let dir = tmp.appendingPathComponent("zipsrc-\(UUID().uuidString)")
            for (k, v) in files { write(v, dir.appendingPathComponent(k)) }
            let out = tmp.appendingPathComponent("\(UUID().uuidString).zip")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", dir.path, out.path]
            try? p.run(); p.waitUntilExit()
            return (try? Data(contentsOf: out)) ?? Data()
        }
        let donor = tmp.appendingPathComponent("Other/SquareEnix")
        let main = Data("ffximain".utf8), dat = Data(repeating: 7, count: 400), patch = Data("theirs".utf8)
        write(main, donor.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll"))
        write(dat, donor.appendingPathComponent("FINAL FANTASY XI/ROM/1/1.DAT"))
        write(Data("mine".utf8), donor.appendingPathComponent("FINAL FANTASY XI/patch2.cfg"))
        write(Data("pol".utf8), donor.appendingPathComponent("PlayOnlineViewer/viewer/com/polcore.dll"))
        // Another world's client on an older build, offered first.
        let older = tmp.appendingPathComponent("Older/SquareEnix")
        write(Data("ffximain-old!".utf8), older.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll"))
        write(Data("old-pol".utf8), older.appendingPathComponent("PlayOnlineViewer/viewer/com/polcore.dll"))
        var files: [[String: Any]] = [["path": "FFXiMain.dll", "size": main.count, "sha256": AscensionChannel.sha256(main)],
                                      ["path": "ROM\\1\\1.DAT", "size": dat.count, "sha256": AscensionChannel.sha256(dat)],
                                      ["path": "patch2.cfg", "size": patch.count, "sha256": AscensionChannel.sha256(patch)]]
        func publishClient(_ at: Date = t0) {
            ch.put("/api/manifest", try! JSONSerialization.data(withJSONObject: ["build": "30260904_1", "files": files]), at)
        }
        publishClient()
        let example = "[ashita.launcher]\r\nname        = Example\r\n[ashita.boot]\r\nfile        = .\\\\bootloader\\\\pol.exe\r\ncommand     = --server homepointxi.com\r\nscript      = default.txt\r\n"
        let oldDll = Data("ashita-old".utf8), newDll = Data("ashita-4.3.2.1".utf8)
        let bundle = zip(["Ashita-cli.exe": Data("cli".utf8), "Ashita.dll": oldDll, "bootloader/xiloader.exe": Data("xiloader 2.1.2".utf8),
                          "config/boot/example-privateserver.ini": Data(example.utf8), "scripts/default.txt": Data("/addon load bigmode\r\n".utf8),
                          "config/pivot/pivot.ini": Data("[settings]\r\nroot_path = E:\\dev\\catseyexi\r\n[overlays]\r\n0 = catseyexi\r\n".utf8)])
        let core = zip(["Ashita.dll": newDll, "plugins/winefix.dll": Data("wf".utf8), "scripts/evil.txt": Data("no".utf8)])
        func pkgFolder(_ id: String, _ body: String) -> [String: Data] { ["\(id)/\(id).lua": Data(body.utf8), "\(id)/lib/util.lua": Data("u".utf8)] }
        func treeOf(_ files: [String: Data], _ id: String) -> String {
            let d = tmp.appendingPathComponent("tree-\(UUID().uuidString)")
            for (k, v) in files { write(v, d.appendingPathComponent(k)) }
            return DriftwoodChannel.treeHash(of: d.appendingPathComponent(id)) ?? ""
        }
        var packages: [[String: Any]] = []
        func addPackage(_ id: String, _ body: String, version: String = "1") {
            let f = pkgFolder(id, body), z = zip(f), path = "/packages/\(id)-\(version).zip"
            ch.put(path, z, t0)
            packages.removeAll { $0["id"] as? String == id }
            packages.append(["id": id, "kind": "ashita-addon", "version": version, "url": site + path,
                             "sha256": AscensionChannel.sha256(z), "treeHash": treeOf(f, id)])
        }
        func publishContent() { ch.put("/content.json", try! JSONSerialization.data(withJSONObject: ["schema": 1, "packages": packages]), t0) }
        addPackage("dwah", "-- market"); addPackage("dwbags", "-- bags"); addPackage("dwgmpanel", "-- staff")
        publishContent()
        ch.put("/b.zip", bundle, t0); ch.put("/c.zip", core, t0)
        var ashitaJSON: [String: Any] = ["version": "20260920-1151", "url": site + "/b.zip", "sha256": AscensionChannel.sha256(bundle),
                                         "core": ["version": "4.3.2.1", "url": site + "/c.zip", "sha256": AscensionChannel.sha256(core),
                                                  "files": [["path": "Ashita.dll", "sha256": AscensionChannel.sha256(newDll)],
                                                            ["path": "plugins\\winefix.dll", "sha256": AscensionChannel.sha256(Data("wf".utf8))],
                                                            ["path": "scripts\\evil.txt", "sha256": AscensionChannel.sha256(Data("no".utf8))]]]]
        func publishAshita() { ch.put("/ashita.json", try! JSONSerialization.data(withJSONObject: ashitaJSON), t0) }
        publishAshita()
        let src = DriftwoodChannel.Sources(manifest: site + "/api/manifest", ashita: site + "/ashita.json", content: site + "/content.json")
        let root = tmp.appendingPathComponent("DriftwoodXI")
        func sync(_ s: DriftwoodChannel.Sources = src, install: Bool = false, donors: [URL]? = nil, stop: StopFlag = StopFlag()) -> AscensionSync.Outcome {
            ch.clearLog()
            return DriftwoodSync(root: root, sources: s, stop: stop, log: { _ in }).run(install: install, donors: donors ?? [donor])
        }
        func file(_ rel: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(rel)) }
        func text(_ rel: String) -> String { file(rel).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

        let first = sync(install: true, donors: [older, donor])
        check("install: succeeds", { if case .ok = first { return true }; return false }())
        check("install: the client from the donor's identical files, under Game/",
              file("Game/FINAL FANTASY XI/FFXiMain.dll") == main && file("Game/FINAL FANTASY XI/ROM/1/1.DAT") == dat)
        check("install: patch2.cfg, the one file allowed to differ, taken from the donor as it is",
              file("Game/FINAL FANTASY XI/patch2.cfg") == Data("mine".utf8))
        check("install: PlayOnline Viewer beside the game, from the donor on the same build", file("Game/PlayOnlineViewer/viewer/com/polcore.dll") == Data("pol".utf8))
        check("install: their Ashita bundle in Ashita/, with their loader",
              file("Ashita/Ashita-cli.exe") == Data("cli".utf8) && file("Ashita/bootloader/xiloader.exe") == Data("xiloader 2.1.2".utf8))
        check("install: the core's newer files over the bundle's; a core file outside its places ignored",
              file("Ashita/Ashita.dll") == newDll && file("Ashita/plugins/winefix.dll") == Data("wf".utf8) && file("Ashita/scripts/evil.txt") == nil)
        check("install: their addons in addons/<id>/, dwgmpanel never",
              file("Ashita/addons/dwah/dwah.lua") == Data("-- market".utf8) && file("Ashita/addons/dwbags/lib/util.lua") == Data("u".utf8)
                && !fm.fileExists(atPath: root.appendingPathComponent("Ashita/addons/dwgmpanel").path))
        let p = text("Ashita/config/boot/driftwood.ini")
        check("install: driftwood.ini boots xiloader at xi.driftwoodgaming.com with driftwood.txt",
              BootProfile.loaderName(in: p) == "xiloader.exe" && BootProfile.value("command", section: "ashita.boot", in: p) == "--server xi.driftwoodgaming.com"
                && BootProfile.value("script", section: "ashita.boot", in: p) == "driftwood.txt")
        let s1 = text("Ashita/scripts/driftwood.txt")
        check("install: driftwood.txt loads their addons and winefix; their default.txt untouched",
              s1.contains("/addon load dwah") && s1.contains("/addon load dwbags") && !s1.contains("dwgmpanel") && s1.contains("/load winefix")
                && text("Ashita/scripts/default.txt") == "/addon load bigmode\r\n")
        check("install: the developer's pivot.ini replaced", !text("Ashita/config/pivot/pivot.ini").contains("E:\\"))

        try? fm.removeItem(at: root.appendingPathComponent("Game/PlayOnlineViewer"))
        _ = sync(donors: [older, donor])
        check("a missing viewer comes back from the donor whose FFXiMain.dll is this client's",
              file("Game/PlayOnlineViewer/viewer/com/polcore.dll") == Data("pol".utf8))
        let second = sync(donors: [])
        check("update: nothing new -> nothing downloaded, the client list answered 304",
              second == .ok(changed: 0) && !ch.log.contains { $0.contains(".zip") } && ch.log.contains("/api/manifest 304"))
        // A new dwah, a new package, and a player's own change to the script.
        try? (s1.replacingOccurrences(of: "/addon load dwbags\r\n", with: "")).write(to: root.appendingPathComponent("Ashita/scripts/driftwood.txt"), atomically: true, encoding: .utf8)
        addPackage("dwah", "-- market v2", version: "2"); addPackage("dwchat", "-- chat"); publishContent()
        let third = sync(donors: [])
        let s3 = text("Ashita/scripts/driftwood.txt")
        check("update: only the changed and the new package come down",
              { if case .ok(let n) = third { return n == 2 }; return false }()
                && Set(ch.log.filter { $0.contains(".zip") }) == ["/packages/dwah-2.zip 200", "/packages/dwchat-1.zip 200"]
                && file("Ashita/addons/dwah/dwah.lua") == Data("-- market v2".utf8))
        check("update: a package new in their list is switched on once; one the player switched off stays off",
              s3.contains("/addon load dwchat\r\n") && !s3.contains("dwbags"))
        // LuaJITGuard's lines in an entry file are not a change.
        let entry = root.appendingPathComponent("Ashita/addons/dwah/dwah.lua")
        try? (Data(LuaJITGuard.shim.utf8) + Data("-- market v2".utf8)).write(to: entry)
        check("update: an entry file LuaJITGuard patched is not downloaded again",
              sync(donors: []) == .ok(changed: 0) && !ch.log.contains { $0.contains(".zip") })
        // Nor are the .DS_Store and ._* files Finder leaves in a folder it shows.
        write(Data("finder".utf8), root.appendingPathComponent("Ashita/addons/dwah/.DS_Store"))
        write(Data("ad".utf8), root.appendingPathComponent("Ashita/addons/dwah/lib/._util.lua"))
        check("update: an addon folder with Finder's .DS_Store and ._* files in it is not downloaded again",
              sync(donors: []) == .ok(changed: 0) && !ch.log.contains { $0.contains(".zip") })
        // A package that is not what it says, a damaged bundle.
        let evil = zip(["dwbad/dwbad.lua": Data("x".utf8)]); ch.put("/packages/dwbad.zip", evil, t0)
        packages.append(["id": "dwbad", "kind": "ashita-addon", "version": "1", "url": site + "/packages/dwbad.zip",
                         "sha256": AscensionChannel.sha256(evil), "treeHash": String(repeating: "0", count: 64)]); publishContent()
        check("a package whose contents do not match its treeHash is refused",
              { if case .failed(let why) = sync(donors: []) { return why.contains("dwbad") }; return false }()
                && !fm.fileExists(atPath: root.appendingPathComponent("Ashita/addons/dwbad").path))
        packages.removeAll { $0["id"] as? String == "dwbad" }; publishContent()
        ashitaJSON["sha256"] = String(repeating: "0", count: 64); publishAshita()
        check("a bundle that does not hash to ashita.json's is refused (Repair)",
              { if case .failed(let why) = sync(install: true) { return why.contains("damaged") }; return false }())
        ashitaJSON["sha256"] = AscensionChannel.sha256(bundle); publishAshita()
        check("Repair after it: ok", { if case .ok = sync(install: true) { return true }; return false }())
        // A client file no donor has.
        let extra = Data("new dat".utf8)
        files.append(["path": "ROM/2/2.DAT", "size": extra.count, "sha256": AscensionChannel.sha256(extra)]); publishClient(t0.addingTimeInterval(60))
        check("a client file not on this Mac: refused, naming it and the build",
              { if case .failed(let why) = sync() { return why.contains("ROM/2/2.DAT") && why.contains("30260904_1") }; return false }())
        files.removeLast(); publishClient(t0.addingTimeInterval(120))
        _ = sync()
        // A first install stopped part way through the client, then /api/manifest down.
        let halfway = tmp.appendingPathComponent("DriftwoodXI-halfway")
        let noList = DriftwoodChannel.Sources(manifest: "http://127.0.0.1:9/m", ashita: site + "/ashita.json", content: site + "/content.json")
        func halfState() -> [String: Any] {
            (try? Data(contentsOf: halfway.appendingPathComponent(".ffxi-on-mac/driftwood.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        // Stop as the client starts (its first line); FFXiMain.dll then stands for what a list of
        // 65,053 files gets done between two of assemble's Stop checks.
        let stopAtClient = StopFlag()
        let stopped = DriftwoodSync(root: halfway, sources: src, stop: stopAtClient, log: { _ in stopAtClient.raise() }).run(install: true, donors: [donor])
        check("stop part way through a first install's client: its list is left unverified",
              stopped == .stopped && halfState()["clientList"] as? String == "" && halfState()["finished"] as? Bool == false)
        write(main, halfway.appendingPathComponent("Game/FINAL FANTASY XI/FFXiMain.dll"))
        let listCopy = halfway.appendingPathComponent(".ffxi-on-mac/client-manifest.json")
        let keptList = try? Data(contentsOf: listCopy)
        try? fm.removeItem(at: listCopy)
        let noCopy = DriftwoodSync(root: halfway, sources: noList, log: { _ in }).run(donors: [donor])
        check("then /api/manifest down and no copy of it: refused, not finished",
              { if case .failed(let why) = noCopy { return why.contains("client list") }; return false }() && halfState()["finished"] as? Bool != true)
        if let keptList { write(keptList, listCopy) }
        let fromCopy = DriftwoodSync(root: halfway, sources: noList, log: { _ in }).run(donors: [donor])
        check("then /api/manifest down with the copy kept from it: the client completes from the donor",
              { if case .ok = fromCopy { return true }; return false }() && keptList != nil
                && (try? Data(contentsOf: halfway.appendingPathComponent("Game/FINAL FANTASY XI/ROM/1/1.DAT"))) == dat
                && halfState()["clientList"] as? String == keptList.map { AscensionChannel.sha256($0) } && halfState()["finished"] as? Bool == true)
        // Offline after a finished update plays; Stop stops.
        let down = DriftwoodChannel.Sources(manifest: "http://127.0.0.1:9/m", ashita: "http://127.0.0.1:9/a", content: "http://127.0.0.1:9/c")
        check("offline after a finished update: play with what is there", { if case .offline = sync(down) { return true }; return false }())
        let flag = StopFlag(); flag.raise()
        check("stop: .stopped", sync(stop: flag) == .stopped)

        // The launcher around it.
        let w = Server.all.first { $0.name == DriftwoodChannel.worldName }
        check("built-in: DriftwoodXI, LandSandBoat, its kind, one client, their addon list, a website account",
              Server.builtins.contains { $0.name == DriftwoodChannel.worldName } && w?.codebase == .landSandBoat
                && w?.installKind == .driftwoodContent && w?.installKind.updatesBeforePlay == true && w?.allowsMultipleClients == false
                && w.map { AddonPolicies.policy(for: $0).isRestricting } == true && w?.createsAccountAtLogin == false
                && w?.accountURL == "https://xi.driftwoodgaming.com/register")
        let enc = w.flatMap { try? JSONEncoder().encode([$0]) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
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

    /// `--driftwood-sync [--install] [--root <folder>]`: the install or update the button runs,
    /// headless, printing every line, with every other world's client offered as a donor. Never
    /// launches the game. `--driftwood-treehash <folder>` prints their hashTree of one folder.
    @MainActor static func runDriftwoodSync(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)   // a line at a time, also into a file
        if let k = args.firstIndex(of: "--driftwood-treehash"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1], isDirectory: true)
            print(DriftwoodChannel.treeHash(of: dir, entry: "\(dir.lastPathComponent).lua") ?? "unreadable")
            exit(0)
        }
        let store = ServerStore()
        var rootPath = store.servers.first { $0.name == DriftwoodChannel.worldName }?.dataPath ?? ""
        if let k = args.firstIndex(of: "--root"), k + 1 < args.count { rootPath = args[k + 1] }
        guard !rootPath.isEmpty else { FileHandle.standardError.write(Data("pass --root <folder>\n".utf8)); exit(2) }
        guard let base = InstallSelection.inUse() ?? Install.lastChosen() else {
            FileHandle.standardError.write(Data("no install found\n".utf8)); exit(2)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let donors = AscensionChannel.donorClients(store.servers.filter { $0.name != DriftwoodChannel.worldName }, base: base)
        for d in donors { print("donor: \(d.path)") }
        var last = -1
        let sync = DriftwoodSync(root: root, log: { print($0) }, progress: { label, f in
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
