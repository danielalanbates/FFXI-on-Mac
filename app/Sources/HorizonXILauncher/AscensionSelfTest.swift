import Foundation
import Network

/// `--selftest-ascension`: AscensionXI's channel client (AscensionChannel, AscensionSync,
/// AscensionScript, DotNetResources) against a fake channel served over HTTP on 127.0.0.1, in a
/// temporary folder. No network beyond loopback, nothing outside the temporary folder written.
extension Headless {
    @MainActor static func runAscensionSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ascension-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // MARK: Pure parts

        // AscensionScript: their AddonScript, line for line.
        let base = "# header\r\n#\r\n/load thirdparty\r\n/load addons\r\n/addon load fps\r\n/bind F12 /fps\r\n/wait 3\r\n"
        var sc = AscensionScript(base)
        check("script: every load line is collected, in order", sc.plugins == ["thirdparty", "addons"] && sc.addons == ["fps"])
        sc.enable(kind: "addon", "move"); sc.disable(kind: "addon", "fps"); sc.removeLine("/bind F12 /fps")
        let rendered = sc.render()
        check("script: the block goes where the first load was, CRLF kept",
              rendered == "# header\r\n#\r\n" + AscensionScript.fenceBegin + "\r\n/load thirdparty\r\n/load addons\r\n/addon load move\r\n"
                + AscensionScript.fenceEnd + "\r\n/wait 3\r\n")
        let again = AscensionScript(rendered)
        check("script: reading its own block back changes nothing", again.changed == nil)
        let bare = AscensionScript("# only comments\n\n/wait 1\n")
        check("script: no load lines -> the block goes after the leading comments",
              bare.render() == "# only comments\n\n" + AscensionScript.fenceBegin + "\n" + AscensionScript.fenceEnd + "\n/wait 1\n")
        check("script: case-insensitive, duplicates once, '/addonload' is not a load",
              AscensionScript("/LOAD Toon\n/load toon\n/addonload x\n").plugins == ["Toon"]
                && AscensionScript("/addonload x\n").addons.isEmpty)

        // pivot.ini: their RewritePivot.
        let oldPivot = "[settings]\r\nroot_path=C:\\Games\\X\\polplugins\\DATs\r\ndebug_log=false\r\n[overlays]\r\n0=ascensionxi-prod\r\n1=stockbrand\r\n2=ffxi-hd\r\n"
        var s = AscensionChannel.Settings()
        check("pivot: root_path is this client's, their overlay first, a foreign one kept after",
              AscensionChannel.pivot(oldPivot, datsWine: "Z:\\A\\DATs", settings: s, present: [])
                == "[settings]\r\nroot_path=Z:\\A\\DATs\r\ndebug_log=false\r\n[overlays]\r\n0=ascensionxi-prod\r\n1=stockbrand\r\n")
        s.hd = true; s.hdMaps = true
        check("pivot: HD on -> -hd overlay first; a pack is listed only when its folder is there",
              AscensionChannel.pivot(nil, datsWine: "Z:\\D", settings: s, present: ["ffxi-maps"])
                == "[settings]\r\nroot_path=Z:\\D\r\ndebug_log=false\r\nredirect_fopens=true\r\n[overlays]\r\n0=ascensionxi-prod-hd\r\n1=ascensionxi-prod\r\n2=ffxi-maps\\1024x1024\r\n")
        check("command: --json and its file come out, everything else stays",
              AscensionChannel.commandWithoutJSON("--server play.ascensionffxi.com --hairpin --json \"C:\\a b\\x.json\"")
                == "--server play.ascensionffxi.com --hairpin"
                && AscensionChannel.commandWithoutJSON("--json --hairpin") == "--hairpin")

        // DotNetResources: a synthetic .NET PE with the loader, its licence and notice.
        let loaderPE = makePE(resources: nil, filler: 300)
        let launcher = makePE(resources: [Data([0, 0, 1, 0, 9, 9]), loaderPE,
                                          Data("    GNU GENERAL PUBLIC LICENSE\r\n Version 3".utf8),
                                          Data("AscensionXI native loader\r\nBased on xiloader".utf8),
                                          Data([0, 1, 0, 0, 7])], filler: 0)
        let found = DotNetResources.ascensionLoader(in: launcher)
        check("resources: five blobs, 8-byte aligned, read back", DotNetResources.blobs(in: launcher)?.count == 5)
        check("resources: the loader is the one native PE, with licence and notice",
              found?.exe == loaderPE && found?.license.contains("GNU GENERAL") == true && found?.notice.hasPrefix("AscensionXI native loader") == true)
        check("resources: a launcher with two PEs, or none, gives no loader",
              DotNetResources.ascensionLoader(in: makePE(resources: [loaderPE, loaderPE, Data("GNU GENERAL PUBLIC LICENSE".utf8),
                                                                      Data("AscensionXI native loader".utf8)], filler: 0)) == nil
                && DotNetResources.ascensionLoader(in: Data("MZ not a pe".utf8)) == nil)

        // MARK: A fake channel

        let channel = TestChannel()
        guard (try? channel.start()) != nil, channel.port != 0 else {
            print("  FAIL could not listen on 127.0.0.1"); exit(1)
        }
        let mirror = "http://127.0.0.1:\(channel.port)"
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func entry(_ d: Data) -> [String: Any] { ["sha256": AscensionChannel.sha256(d), "size": d.count] }
        let ffximain = Data("FFXiMain v30260904".utf8), ashitaDLL = Data("Ashita.dll".utf8), cli = Data("Ashita-cli".utf8)
        let rom = Data(repeating: 7, count: 5000), pol = Data("pol viewer".utf8)
        let ini = Data("[ashita.boot]\r\nfile=.\\\\bootloader\\\\xiloader.exe\r\ncommand=--server play.ascensionffxi.com --hairpin --json x.json\r\nscript=default.txt\r\n".utf8)
        let script = Data("# Ashita v4 Default Script\r\n/load thirdparty\r\n/addon load fps\r\n/bind F12 /fps\r\n/wait 3\r\n".utf8)
        var baseFiles: [String: Data] = [
            "Ashita/Ashita-cli.exe": cli, "Ashita/Ashita.dll": ashitaDLL,
            "Ashita/config/boot/ascensionxi-prod-public.ini": ini,
            "Ashita/config/boot/ascensionxi-dev.ini": Data("dev".utf8),
            "Ashita/scripts/default.txt": script,
            "Ashita/bootloader/xiloader.exe": Data("stock".utf8),
            "Game/FINAL FANTASY XI/FFXiMain.dll": ffximain,
            "Game/FINAL FANTASY XI/ROM/1/1.DAT": rom,
            "Game/FINAL FANTASY XI/ROM/1/2.DAT": Data(repeating: 1, count: 64),
            "Game/PlayOnlineViewer/viewer.bin": pol,
            "Ashita/polplugins/DATs/ffxi-hd/ROM/1/1.DAT": Data(repeating: 9, count: 10),
        ]
        func publishBase(_ files: [String: Data], revision: String, at date: Date) {
            let m: [String: Any] = ["version": 1, "client_version": "30260904_1", "revision": revision,
                                    "files": files.mapValues(entry)]
            channel.put("/base/client-manifest.json", try! JSONSerialization.data(withJSONObject: m), date)
            for (k, v) in files { channel.put("/base/files/" + k, v, date) }
        }
        publishBase(baseFiles, revision: "r1", at: t0)
        var dats: [String: Data] = ["ROM/0/0.DAT": Data("ascension dat 0".utf8), "ROM/118/106.DAT": Data("ascension dat 106".utf8)]
        func publishManifest(_ d: [String: Data]) {
            let m: [String: Any] = [
                "version": 2,
                "files": d.mapValues(entry), "files_hd": [String: Any](),
                "launcher": ["AscensionXI.exe": (["path": "launcher/dist/AscensionXI.exe"] as [String: Any]).merging(entry(launcher)) { a, _ in a }],
                "compatibility": ["client_version": "30260904_1",
                                  "runtime_files": ["Game/FINAL FANTASY XI/FFXiMain.dll": AscensionChannel.sha256(ffximain),
                                                    "Ashita/Ashita.dll": AscensionChannel.sha256(ashitaDLL),
                                                    "Ashita/Ashita-cli.exe": AscensionChannel.sha256(cli)]],
            ]
            channel.put("/manifest.json", try! JSONSerialization.data(withJSONObject: m), t0)
            for (k, v) in d { channel.put("/dats/" + k, v, t0) }
        }
        publishManifest(dats)
        channel.put("/launcher/dist/AscensionXI.exe", launcher, t0)
        channel.put("/environment", Data("prod\n".utf8), t0)
        // The catalog: a channel-relative addon, an absolute-URL plugin, an archive addon, a removal.
        let moveLua = Data("addon.name = 'move'".utf8), thirdparty = Data("thirdparty.dll".utf8)
        let bigFiles = ["big.lua": Data("addon.name = 'big'".utf8), "lib/a.lua": Data("a".utf8), "lib/b.lua": Data("b".utf8)]
        let zipDir = tmp.appendingPathComponent("zipsrc/big-main")
        for (k, v) in bigFiles {
            let f = zipDir.appendingPathComponent(k)
            try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? v.write(to: f)
        }
        let zip = tmp.appendingPathComponent("big.zip")
        let ditto = Process(); ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", zipDir.path, zip.path]
        try? ditto.run(); ditto.waitUntilExit()
        let zipData = (try? Data(contentsOf: zip)) ?? Data()
        channel.put("/gh/big.zip", zipData, t0)
        channel.put("/addons/move/move.lua", moveLua, t0)
        channel.put("/gh/thirdparty.dll", thirdparty, t0)
        channel.put("/gh/new.lua", Data("chains".utf8), t0)
        let catalog: [String: Any] = [
            "version": 1,
            "switchOff": [["name": "fps", "kind": "addon", "reason": "TrueFPS replaces it"]],
            "entries": [
                ["name": "thirdparty", "kind": "plugin", "enabled": true,
                 "files": ["thirdparty.dll": entry(thirdparty).merging(["url": mirror + "/gh/thirdparty.dll"]) { a, _ in a }]],
                ["name": "move", "kind": "addon", "enabled": true,
                 "files": ["move.lua": entry(moveLua).merging(["url": "addons/move/move.lua"]) { a, _ in a }]],
                ["name": "big", "kind": "addon", "enabled": false,
                 "archives": [["url": mirror + "/gh/big.zip", "from": "big-main/", "into": "", "size": 10]],
                 "files": bigFiles.mapValues { entry($0).merging(["url": mirror + "/gh/missing"]) { a, _ in a } }],
                ["name": "chains", "kind": "addon", "enabled": false, "remove": ["old.lua"],
                 "files": ["chains.lua": entry(Data("chains".utf8)).merging(["url": mirror + "/gh/new.lua"]) { a, _ in a }]],
            ],
        ]
        channel.put("/addons/catalog.json", try! JSONSerialization.data(withJSONObject: catalog), t0)

        // A donor client with one identical file and one of the same size but different bytes.
        let donor = tmp.appendingPathComponent("donor/SquareEnix")
        let donorRom = donor.appendingPathComponent("FINAL FANTASY XI/ROM/1/1.DAT")
        try? fm.createDirectory(at: donorRom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rom.write(to: donorRom)
        try? Data(repeating: 2, count: 64).write(to: donor.appendingPathComponent("FINAL FANTASY XI/ROM/1/2.DAT"))

        let root = tmp.appendingPathComponent("AscensionXI")
        // A stray file in their overlay folder, which the sync prunes; an old chains file it removes.
        let stray = root.appendingPathComponent("Ashita/polplugins/DATs/ascensionxi-prod/ROM/9/9.DAT")
        try? fm.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("old".utf8).write(to: stray)
        let oldChains = root.appendingPathComponent("Ashita/addons/chains/old.lua")
        try? fm.createDirectory(at: oldChains.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("old".utf8).write(to: oldChains)

        var lines: [String] = []
        let lineLock = NSLock()
        func sync(_ mirrors: [String] = [mirror], stop: StopFlag = StopFlag(), install: Bool = false, donors: [URL] = []) -> AscensionSync.Outcome {
            lineLock.lock(); lines = []; lineLock.unlock()
            channel.clearLog()
            let sy = AscensionSync(root: root, datsWine: "Z:\\T\\Ashita\\polplugins\\DATs", stop: stop, mirrors: mirrors,
                                   log: { l in lineLock.lock(); lines.append(l); lineLock.unlock() })
            return sy.run(install: install, donors: donors)
        }
        func file(_ rel: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(rel)) }
        func text(_ rel: String) -> String { file(rel).flatMap { String(data: $0, encoding: .isoLatin1) } ?? "" }

        // MARK: First run: install

        let first = sync(install: true, donors: [donor])
        check("install: succeeds", { if case .ok = first { return true }; return false }())
        let edited: Set<String> = ["Ashita/config/boot/ascensionxi-prod-public.ini", "Ashita/scripts/default.txt"]
        check("install: every base file outside the packs is there, byte for byte",
              baseFiles.filter { !$0.key.contains("ffxi-hd") && !$0.key.contains("ascensionxi-dev") && !edited.contains($0.key) }
                .allSatisfy { file($0.key) == $0.value })
        check("install: the HD pack is not fetched (off on the Mac)", file("Ashita/polplugins/DATs/ffxi-hd/ROM/1/1.DAT") == nil)
        check("install: the identical donor file is copied, the same-size different one downloaded",
              !channel.log.contains { $0.hasPrefix("/base/files/Game/FINAL%20FANTASY%20XI/ROM/1/1.DAT ") }
                && channel.log.contains("/base/files/Game/FINAL%20FANTASY%20XI/ROM/1/2.DAT 200"))
        check("install: their DATs are in the overlay, the stray one pruned",
              dats.allSatisfy { file("Ashita/polplugins/DATs/ascensionxi-prod/" + $0.key) == $0.value } && !fm.fileExists(atPath: stray.path))
        check("install: their dev boot profile is removed", file("Ashita/config/boot/ascensionxi-dev.ini") == nil)
        check("install: addons: a channel file, an absolute-URL plugin, an archive",
              file("Ashita/addons/move/move.lua") == moveLua && file("Ashita/plugins/thirdparty.dll") == thirdparty
                && bigFiles.allSatisfy { file("Ashita/addons/big/" + $0.key) == $0.value }
                && !channel.log.contains { $0.hasPrefix("/gh/missing") })
        check("install: the obsolete addon file is removed", !fm.fileExists(atPath: oldChains.path))
        let scriptNow = text("Ashita/scripts/default.txt")
        check("install: default.txt gets their block: defaults on, fps switched off, its bind gone",
              scriptNow == "# Ashita v4 Default Script\r\n" + AscensionScript.fenceBegin + "\r\n/load thirdparty\r\n/addon load move\r\n"
                + AscensionScript.fenceEnd + "\r\n/wait 3\r\n")
        let state = text("addons.json")
        check("install: addons.json in their format", state.hasPrefix("{\r\n  \"//\": \"The launcher's memory")
              && state.contains("\"seen\": [\"big\",\"chains\",\"move\",\"thirdparty\"]") && state.contains("\"switchedOff\": [\"fps\"]"))
        check("install: pivot.ini names this client's DATs and their overlay",
              text("Ashita/config/pivot/pivot.ini") == "[settings]\r\nroot_path=Z:\\T\\Ashita\\polplugins\\DATs\r\ndebug_log=false\r\nredirect_fopens=true\r\n[overlays]\r\n0=ascensionxi-prod\r\n")
        check("install: their loader, licence and notice in bootloader/",
              file("Ashita/bootloader/ascensionxi-loader.exe") == loaderPE
                && text("Ashita/bootloader/ascensionxi-loader-LICENSE.txt").contains("GNU GENERAL")
                && text("Ashita/bootloader/ascensionxi-loader-NOTICE.txt").hasPrefix("AscensionXI native loader"))
        check("install: the boot profile keeps --hairpin and loses --json",
              BootProfile.value("command", section: "ashita.boot", in: text("Ashita/config/boot/ascensionxi-prod-public.ini"))
                == "--server play.ascensionffxi.com --hairpin")
        let bmDate = (try? fm.attributesOfItem(atPath: root.appendingPathComponent(".base-manifest.json").path))?[.modificationDate] as? Date
        check("install: .base-manifest.json is kept, dated as the channel's Last-Modified",
              bmDate.map { abs($0.timeIntervalSince(t0)) < 1 } == true)
        check("install: the folder is marked as the prod client", text(".client-environment").hasPrefix("prod"))

        // MARK: Second run: nothing changed

        let second = sync()
        check("update: nothing changed -> nothing written", second == .ok(changed: 0))
        check("update: the base manifest is asked with If-Modified-Since and not downloaded again",
              channel.log.contains("/base/client-manifest.json 304") && !channel.log.contains(where: { $0.hasPrefix("/base/files/") }))
        check("update: unchanged DATs are not read again (hash cache), only stat'ed",
              !channel.log.contains(where: { $0.hasPrefix("/dats/") }))

        // Play's LuaJIT guard on an addon's entry file is not a change to fetch again.
        let moveFile = root.appendingPathComponent("Ashita/addons/move/move.lua")
        let guarded = LuaJITGuard.patch(moveFile)
        let afterGuard = sync()
        check("jit guard: an entry file with only the guard in front is current (no refetch, no rewrite)",
              guarded && afterGuard == .ok(changed: 0) && !channel.log.contains { $0.hasPrefix("/addons/move/") }
                && text("Ashita/addons/move/move.lua").hasPrefix(LuaJITGuard.marker))
        check("jit guard: the bytes after the guard must still be the catalog's",
              AscensionSync.withoutJITGuard(Data(LuaJITGuard.shim.utf8) + moveLua) == moveLua
                && AscensionSync.withoutJITGuard(moveLua) == nil
                && AscensionSync.withoutJITGuard(Data([0xEF, 0xBB, 0xBF]) + Data(LuaJITGuard.shim.utf8) + moveLua)
                    == Data([0xEF, 0xBB, 0xBF]) + moveLua)
        check("update: the addon catalog is asked with If-Modified-Since too",
              channel.log.contains("/addons/catalog.json 304"))

        // MARK: Third run: a new release

        let t1 = t0.addingTimeInterval(3600)
        baseFiles["Game/FINAL FANTASY XI/ROM/1/2.DAT"] = Data(repeating: 3, count: 64)
        baseFiles["Game/PlayOnlineViewer/viewer.bin"] = nil
        publishBase(baseFiles, revision: "r2", at: t1)
        dats["ROM/0/0.DAT"] = Data("ascension dat 0, v2".utf8)
        dats["ROM/118/106.DAT"] = nil
        publishManifest(dats)
        let third = sync()
        check("release: succeeds", { if case .ok(let n) = third { return n >= 2 }; return false }())
        check("release: the changed base file is fetched, the removed one deleted",
              file("Game/FINAL FANTASY XI/ROM/1/2.DAT") == Data(repeating: 3, count: 64) && file("Game/PlayOnlineViewer/viewer.bin") == nil
                && channel.log.filter { $0.hasPrefix("/base/files/") }.count == 1)
        check("release: the overlay follows the manifest (changed, and gone)",
              file("Ashita/polplugins/DATs/ascensionxi-prod/ROM/0/0.DAT") == dats["ROM/0/0.DAT"]
                && file("Ashita/polplugins/DATs/ascensionxi-prod/ROM/118/106.DAT") == nil)

        // MARK: Failures

        try? Data("tampered".utf8).write(to: root.appendingPathComponent("Game/FINAL FANTASY XI/FFXiMain.dll"))
        let tampered = sync()
        check("runtime: a client that is not the one the release needs is refused, naming the file",
              { if case .failed(let why) = tampered { return why.contains("FFXiMain.dll") }; return false }())
        let scriptBefore = text("Ashita/scripts/default.txt")
        let repaired = sync(install: true)
        check("repair (every file checked) puts it back", { if case .ok = repaired { return true }; return false }()
              && file("Game/FINAL FANTASY XI/FFXiMain.dll") == ffximain)
        check("repair keeps the boot script the player's addon choices are in (theirs resets it)",
              text("Ashita/scripts/default.txt") == scriptBefore)
        let offline = sync(["http://127.0.0.1:9"])
        check("offline: no mirror answers -> play with what is there", { if case .offline = offline { return true }; return false }())
        let flag = StopFlag(); flag.raise()
        check("stop: a raised Stop ends the run, saying so",
              { if case .failed(let why) = sync(stop: flag) { return why.hasPrefix("Stopped") }; return false }())
        let fresh = tmp.appendingPathComponent("empty")
        let none = AscensionSync(root: fresh, datsWine: "Z:\\", mirrors: ["http://127.0.0.1:9"], log: { _ in }).run()
        check("offline with nothing installed is a failure, not a Play", { if case .failed = none { return true }; return false }())

        // MARK: The launcher around it

        // AddonSuite writes their block, never a second one of ours.
        let gameDir = root.appendingPathComponent("Ashita")
        let inst = Install(wrapper: tmp.appendingPathComponent("w.app"), prefixName: "prefix", gameDirOverride: gameDir)
        var items = AddonSuite.scan(inst, profile: AscensionChannel.bootProfile)
        check("addons screen: reads their block", items.first { $0.name == "move" }?.enabled == true)
        if let k = items.firstIndex(where: { $0.name == "big" }) { items[k].enabled = true }
        _ = AddonSuite.write(items, to: inst, profile: AscensionChannel.bootProfile)
        let after = text("Ashita/scripts/default.txt")
        check("addons screen: Apply edits their block in place: one block, no HORIZON markers",
              after.contains("/addon load big") && !after.contains(AddonSuite.pluginsStart)
                && after.components(separatedBy: AscensionScript.fenceBegin).count == 2)

        // The account line keeps the world's own loader options.
        try? ini.write(to: gameDir.appendingPathComponent("config/boot/ascensionxi-prod-public.ini"))
        _ = Credentials.apply(user: "u1", password: "p1", to: inst, profile: AscensionChannel.bootProfile,
                              server: "play.ascensionffxi.com", options: ["--hairpin"])
        check("account: --hairpin follows the account",
              BootProfile.value("command", section: "ashita.boot", in: text("Ashita/config/boot/ascensionxi-prod-public.ini"))
                == "--server play.ascensionffxi.com --user u1 --pass p1 --hairpin")

        // servers.json: written so that 3.10 can still read it, read back as AscensionXI's own.
        let asc = Server.all.first { $0.name == AscensionChannel.worldName }
        let enc = asc.flatMap { try? JSONEncoder().encode([$0]) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("servers.json: AscensionXI's install kind is stored as one older builds know",
              enc.contains("\"installKind\":\"website\"") && !enc.contains("ascensionChannel"))
        let future = Data(#"[{"name":"X","host":"h","installKind":"teleporter"}]"#.utf8)
        check("servers.json: a kind this build does not know reads as website, not a reset",
              (try? JSONDecoder().decode([Server].self, from: future))?.first?.installKind == .website)
        check("built-in: AscensionXI is offered, LandSandBoat, one client, its loader and --hairpin",
              Server.builtins.contains { $0.name == AscensionChannel.worldName } && asc?.codebase == .landSandBoat
                && asc?.maxClients == 1 && asc?.loader == AscensionChannel.loaderName && asc?.loaderOptions == ["--hairpin"]
                && asc?.installKind == .ascensionChannel)

        // A world never played here must not inherit another world's account (b71).
        check("account: only HorizonXI inherits the pre-per-world name and password",
              Credentials.inheritsLegacyAccount("HorizonXI") && Credentials.inheritsLegacyAccount("")
                && !Credentials.inheritsLegacyAccount(AscensionChannel.worldName) && !Credentials.inheritsLegacyAccount("CatsEyeXI"))

        // Addon policy: their catalog.
        let policy = AscensionChannel.addonPolicy(clientRoot: root.path)
        check("policy: their catalog's addons are allowed, others are not",
              policy.isRestricting && policy.allows("move") && policy.allows("big") && policy.allows("thirdparty") && !policy.allows("vanaguide"))
        let snap = AscensionChannel.addonPolicy(clientRoot: fresh.path)
        check("policy: with no catalog yet, the 2026-10-24 snapshot", snap.allows("XIUI") && snap.allows("dlac") && !snap.allows("hxui"))

        channel.stop()
        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        if failures > 0 { print("--- last run's log:"); for l in lines { print("    " + l) } }
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// A minimal PE32: one section holding, when `resources` is given, a CLI header whose
    /// Resources directory is those blobs, each length-prefixed and 8-byte aligned. `filler` pads
    /// the section so two images differ.
    static func makePE(resources: [Data]?, filler: Int) -> Data {
        var d = Data(count: 0x200)
        func put32(_ v: Int, at o: Int) { for k in 0..<4 { d[o + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        func put16(_ v: Int, at o: Int) { for k in 0..<2 { d[o + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        d[0] = 0x4D; d[1] = 0x5A
        put32(0x80, at: 0x3C)
        d[0x80] = 0x50; d[0x81] = 0x45
        put16(0x14C, at: 0x84); put16(1, at: 0x86); put16(0xE0, at: 0x94)
        let opt = 0x98
        put16(0x10B, at: opt)
        var section = Data()
        if let res = resources {
            var blob = Data()
            for r in res {
                var len = Data(count: 4); for k in 0..<4 { len[k] = UInt8((r.count >> (8 * k)) & 0xFF) }
                blob += len + r
                while blob.count % 8 != 0 { blob.append(0) }
            }
            var cli = Data(count: 0x100)
            cli[0] = 72
            let resRVA = 0x2000 + 0x100
            for k in 0..<4 { cli[24 + k] = UInt8((resRVA >> (8 * k)) & 0xFF); cli[28 + k] = UInt8((blob.count >> (8 * k)) & 0xFF) }
            section = cli + blob
            put32(0x2000, at: opt + 96 + 14 * 8); put32(72, at: opt + 96 + 14 * 8 + 4)
        }
        section += Data(repeating: 0xCC, count: filler + 16)
        let sec = opt + 0xE0
        d.replaceSubrange(sec..<(sec + 5), with: Data(".text".utf8))
        put32(section.count, at: sec + 8); put32(0x2000, at: sec + 12)
        put32(section.count, at: sec + 16); put32(0x200, at: sec + 20)
        return d + section
    }
}

/// The fake channel: GET only, If-Modified-Since honoured, one request per connection. Every
/// request is logged as "<path> <status>" (the path as sent, percent-encoded).
final class TestChannel: @unchecked Sendable {
    private var files: [String: (Data, Date)] = [:]
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ascension-selftest-channel")
    private let lock = NSLock()
    private var requestLog: [String] = []

    var log: [String] { lock.lock(); defer { lock.unlock() }; return requestLog }
    func clearLog() { lock.lock(); requestLog = []; lock.unlock() }
    func put(_ path: String, _ data: Data, _ date: Date) {
        let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        lock.lock(); files[p] = (data, date); lock.unlock()
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { st in
            switch st { case .ready, .failed, .cancelled: ready.signal() default: break }
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        listener = l
        port = l.port?.rawValue ?? 0
    }

    func stop() { listener?.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            let b = buf + (data ?? Data())
            if let end = b.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(c, head: String(decoding: b[..<end.lowerBound], as: UTF8.self))
            } else if done || err != nil {
                c.cancel()
            } else {
                self.read(c, b)
            }
        }
    }

    private func answer(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let ims = lines.dropFirst().first { $0.lowercased().hasPrefix("if-modified-since:") }
            .map { String($0.dropFirst("if-modified-since:".count)).trimmingCharacters(in: .whitespaces) }
        lock.lock(); let hit = files[path]; lock.unlock()
        var status = "404 Not Found", body = Data(), extra = ""
        if let (data, date) = hit {
            if let ims, let since = AscensionSync.parseHTTPDate(ims), date <= since {
                status = "304 Not Modified"
            } else {
                status = "200 OK"; body = data
                extra = "Last-Modified: \(AscensionSync.httpDate(date) ?? "")\r\n"
            }
        }
        lock.lock(); requestLog.append("\(path) \(status.prefix(3))"); lock.unlock()
        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
        c.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// `--ascension-sync [--install] [--root <folder>]`: AscensionXI's install or Play-time update,
/// exactly as the button runs it, without the window, printing every line. The folder defaults to
/// AscensionXI's game folder in servers.json; with `--install` (or no update run there yet) other
/// worlds' clients are donors. Exit status 0 when it ends `ok` or `offline`. Never launches the game.
extension Headless {
    @MainActor static func runAscensionSync(_ args: [String]) -> Never {
        let store = ServerStore()
        guard let world = store.servers.first(where: { $0.name == AscensionChannel.worldName }) else {
            FileHandle.standardError.write(Data("AscensionXI is not in servers.json\n".utf8)); exit(2)
        }
        var rootPath = world.dataPath
        if let k = args.firstIndex(of: "--root"), k + 1 < args.count { rootPath = args[k + 1] }
        guard !rootPath.isEmpty else {
            FileHandle.standardError.write(Data("no folder: pass --root <folder> or set AscensionXI's game folder\n".utf8)); exit(2)
        }
        guard let base = InstallSelection.inUse() ?? Install.lastChosen() else {
            FileHandle.standardError.write(Data("no install found\n".utf8)); exit(2)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let install = args.contains("--install")
        let checksAll = install || !FileManager.default.fileExists(atPath: root.appendingPathComponent(".base-manifest.json").path)
        let donors = checksAll ? AscensionChannel.donorClients(store.servers.filter { $0.name != world.name }, base: base) : []
        for d in donors { print("donor: \(d.path)") }
        let dats = Install.winePath(root.appendingPathComponent("Ashita/polplugins/DATs"), driveC: base.driveC)
        var lastPct = -1
        let sync = AscensionSync(root: root, datsWine: dats, log: { print($0) }, progress: { label, f in
            let pct = Int(f * 100)
            if pct != lastPct, pct % 5 == 0 { lastPct = pct; print("   \(label) \(pct)%") }
        })
        var outcome: AscensionSync.Outcome = .failed("not run")
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { outcome = sync.run(install: install, donors: donors); done.signal() }
        while done.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print("outcome: \(outcome)")
        if case .failed = outcome { exit(1) }
        exit(0)
    }
}
