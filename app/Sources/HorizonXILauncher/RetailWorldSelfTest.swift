import Foundation
import zlib

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
                && RetailWorld.spec("LevelDown 99")?.loader.version == "2.2.0"
                && { if case .archive(let a)? = RetailWorld.spec("LevelDown 99")?.client { return a.pins["30260203_0"]?.size == 5_528_427_346 }; return false }()
                && { if case .retail? = RetailWorld.spec("MistXI")?.client { return true }; return false }() && RetailWorld.spec("HorizonXI") == nil)
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
        let listFiles: [DriftwoodChannel.ClientFile] = [.init(path: "FFXiMain.dll", size: Int64(main.count), sha256: AscensionChannel.sha256(main)),
                                                       .init(path: "ROM/1/1.DAT", size: Int64(dat.count), sha256: AscensionChannel.sha256(dat))]
        sources.retailDigest = RetailWorld.entriesDigest(listFiles)
        check("the retail list is pinned by its entries, not its bytes; the real pin is the 30260904_1 list",
              RetailWorld.entriesDigest(listFiles) == RetailWorld.entriesDigest(listFiles.reversed())
                && RetailWorld.retailListDigest == "464d8608d81cb1b85caa1dbb19ce5d18c98bf882b0586b724e2f75f7584c9849")
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
        check("Play, nothing new: no request at all (the pinned list is kept here); no Ashita, no loader",
              second == .ok(changed: 0) && ch.log.isEmpty)
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
        // Their list moves to another build: not followed, the client kept as it is.
        let extra = Data("x".utf8)
        let more = files + [["path": "ROM/2/2.DAT", "size": extra.count, "sha256": AscensionChannel.sha256(extra)]]
        ch.put("/api/manifest", try! JSONSerialization.data(withJSONObject: ["build": "30260904_1", "files": more]), t0.addingTimeInterval(60))
        check("a published list that moved to another build is not followed: the pinned copy here is used",
              { if case .ok = sync(install: true, donors: [donor]) { return true }; return false }() && !ch.log.contains("/api/manifest 200")
                && file("Game/FINAL FANTASY XI/ROM/2/2.DAT") == nil)
        // A list this Mac cannot satisfy: refused before anything is replaced.
        let root2 = tmp.appendingPathComponent("MistXI-2")
        var src2 = sources
        src2.retailDigest = RetailWorld.entriesDigest(listFiles + [.init(path: "ROM/2/2.DAT", size: Int64(extra.count), sha256: AscensionChannel.sha256(extra))])
        let r2 = RetailWorldSync(spec: RetailWorld.mist, root: root2, sources: src2, log: { _ in }).run(install: true, donors: [donor])
        check("a retail file not on this Mac: refused, naming it, and nothing copied first",
              { if case .failed(let why) = r2 { return why.contains("ROM/2/2.DAT") && why.contains("Nothing was changed") }; return false }()
                && !fm.fileExists(atPath: root2.appendingPathComponent("Game/FINAL FANTASY XI/FFXiMain.dll").path))
        // Served list moved, and no copy of the pinned one anywhere near (another parent folder).
        let src3 = RetailWorld.Sources(retailList: site + "/api/manifest", ashitaZip: sources.ashitaZip, ashitaCommit: sources.ashitaCommit, loader: sources.loader,
                                       retailDigest: sources.retailDigest)
        check("a moved list with no copy of the pinned one: refused, naming the build",
              { if case .failed(let why) = RetailWorldSync(spec: RetailWorld.mist, root: tmp.appendingPathComponent("elsewhere/MistXI-3"), sources: src3, log: { _ in })
                    .run(install: true, donors: [donor]) { return why.contains("another build") }; return false }())
        ch.put("/api/manifest", try! JSONSerialization.data(withJSONObject: ["build": "30260904_1", "files": files]), t0.addingTimeInterval(120))
        var down = sources; down.retailList = "http://127.0.0.1:9/m"
        check("offline: once the pinned list is here, the retail list's server is not needed", sync(down) == .ok(changed: 0))
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
        let arcData = (try? Data(contentsOf: arcFile)) ?? Data()
        ldSrc.archivePins = ["30260203_0": .init(fileID: "LDFILE", sha256: AscensionChannel.sha256(arcData), size: Int64(arcData.count))]
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
        // The page names another version, or the same version with another file: never installed.
        ch.put("/wiki.json", try! JSONSerialization.data(withJSONObject: ["parse": ["wikitext": ["*": wiki.replacingOccurrences(of: "30260203_0", with: "30269999_0").replacingOccurrences(of: "1_WXohtOdVd1rUyGcK8eCfyYd2fEXp2HT", with: "EVIL")]]]), t0)
        check("archive world: a version their page names that is not pinned here is not installed; the client is kept",
              { if case .ok = ld() { return true }; return false }() && !ch.log.contains { $0.hasPrefix("/drive/") }
                && ldFile("Game/FINAL FANTASY XI/FFXiMain.dll") == Data("old main".utf8))
        let fresh = RetailWorldSync(spec: RetailWorld.levelDown, root: tmp.appendingPathComponent("LevelDown-2"), sources: ldSrc, log: { _ in })
            .run(install: true, donors: [donor])
        check("archive world: with no client yet, an unpinned version is refused", { if case .failed(let why) = fresh { return why.contains("not checked") }; return false }())
        ch.put("/wiki.json", try! JSONSerialization.data(withJSONObject: ["parse": ["wikitext": ["*": wiki.replacingOccurrences(of: "1_WXohtOdVd1rUyGcK8eCfyYd2fEXp2HT", with: "LDFILE")]]]), t0)
        var tampered = ldSrc; tampered.archivePins = ["30260203_0": .init(fileID: "LDFILE", sha256: String(repeating: "0", count: 64), size: Int64(arcData.count))]
        check("archive world: an archive that does not hash to its pin is refused and not kept",
              { if case .failed(let why) = RetailWorldSync(spec: RetailWorld.levelDown, root: ldRoot, sources: tampered, log: { _ in }).run(install: true, donors: [donor]) {
                    return why.contains("SHA-256") }; return false }()
                && !fm.fileExists(atPath: ldRoot.appendingPathComponent(".ffxi-on-mac/tmp/client-30260203_0.archive").path))
        let ldStop = StopFlag(); ldStop.raise()
        check("archive world: stop", ld(install: true, stop: ldStop) == .stopped)

        // A world with a DAT overlay (Olympus XI's GitHub patch releases; Legendary's file list).
        let pivotSrc = tmp.appendingPathComponent("pivot-src")
        for (k, v) in ["polplugins/pivot.dll": "pivot", "config/pivot/pivot.sample.ini": "s"] { write(Data(v.utf8), pivotSrc.appendingPathComponent(k)) }
        let pz = tmp.appendingPathComponent("pivot.zip")
        let pzp = Process(); pzp.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pzp.arguments = ["-c", "-k", "--norsrc", "--noextattr", pivotSrc.path, pz.path]
        try? pzp.run(); pzp.waitUntilExit()
        let pzData = (try? Data(contentsOf: pz)) ?? Data()
        ch.put("/pivot.zip", pzData, t0)
        let d1 = Data("olympus dat 1".utf8), d2 = Data("olympus dat 2".utf8), d3 = Data("olympus dat 3".utf8)
        func patchEntry(_ p: String, _ d: Data) -> [String: Any] {
            let h = AscensionChannel.sha256(d); return ["path": p, "size": d.count, "sha256": h, "asset": h + ".dat"]
        }
        func publishPatch(_ n: Int, _ entries: [(String, Data)]) {
            for (_, d) in entries { ch.put("/rel/download/patch-\(n)/\(AscensionChannel.sha256(d)).dat", d, t0) }
            let m: [String: Any] = ["schemaVersion": 1, "patch": n, "files": entries.map { patchEntry($0.0, $0.1) }, "client": ["tag": "client-30260904_1"]]
            ch.put("/rel/latest/download/manifest.json", try! JSONSerialization.data(withJSONObject: m), t0)
        }
        check("patch manifest: their path rule (numbered DATs and ROMn tables only), asset named for its hash, no duplicates",
              RetailWorld.parsePatchManifest(Data(#"{"patch":3,"files":[{"path":"ROM/1/2.DAT","size":1,"sha256":"\#(String(repeating: "a", count: 64))","asset":"\#(String(repeating: "a", count: 64)).dat"}]}"#.utf8), releases: "R")?.files.first?.url
                == "R/download/patch-3/\(String(repeating: "a", count: 64)).dat"
                && RetailWorld.parsePatchManifest(Data(#"{"patch":3,"files":[{"path":"VTABLE.DAT","size":1,"sha256":"\#(String(repeating: "a", count: 64))","asset":"\#(String(repeating: "a", count: 64)).dat"}]}"#.utf8), releases: "R") == nil
                && RetailWorld.parsePatchManifest(Data(#"{"patch":3,"files":[{"path":"ROM/../x.DAT","size":1,"sha256":"\#(String(repeating: "a", count: 64))","asset":"\#(String(repeating: "a", count: 64)).dat"}]}"#.utf8), releases: "R") == nil
                && RetailWorld.parsePatchManifest(Data(#"{"patch":3,"files":[{"path":"ROM/1/2.DAT","size":1,"sha256":"\#(String(repeating: "a", count: 64))","asset":"other.dat"}]}"#.utf8), releases: "R") == nil)
        check("pivot.ini: their overlay first, others kept after it, settings kept",
              RetailWorld.pivotINI("[settings]\r\ndebug_log = false\r\n[overlays]\r\n0 = NextHD\r\n1 = Olympus\r\n", first: "Olympus")
                == "[settings]\r\ndebug_log = false\r\n\r\n[overlays]\r\n0 = Olympus\r\n1 = NextHD\r\n")
        publishPatch(15, [("ROM/181/73.DAT", d1), ("ROM/1/2.DAT", d2)])
        var olSrc = sources; olSrc.overlaySource = .githubPatches(releases: site + "/rel"); olSrc.pivotZip = site + "/pivot.zip"; olSrc.pivotSHA = AscensionChannel.sha256(pzData)
        olSrc.olympusReleases = site + "/rel"
        // Their client: the donor's files, one root table only their delta pack has, the viewer.
        let vtable = Data("olympus vtable with their entries".utf8)
        func zlibStream(_ d: Data) -> Data {
            var out = [UInt8](repeating: 0, count: Int(compressBound(uLong(d.count))))
            var n = uLong(out.count)
            _ = d.withUnsafeBytes { compress2(&out, &n, $0.bindMemory(to: Bytef.self).baseAddress, uLong(d.count), 6) }
            return Data(out[0..<Int(n)])
        }
        let junk = Data(repeating: 0xAB, count: 77), packed = zlibStream(vtable)
        ch.put("/rel/download/client-30260904_1/pack-01.bin", junk + packed + junk, t0)
        func cf(_ p: String, _ d: Data, delta: Bool = false) -> [String: Any] {
            var e: [String: Any] = ["path": "SquareEnix/" + p, "size": d.count, "sha256": AscensionChannel.sha256(d)]
            if delta { e["delta"] = ["pack": "pack-01.bin", "offset": junk.count, "csize": packed.count] }
            return e
        }
        let olClient: [String: Any] = ["schemaVersion": 1, "version": "30260904_1",
                                       "files": [cf("FINAL FANTASY XI/FFXiMain.dll", main), cf("FINAL FANTASY XI/ROM/1/1.DAT", dat),
                                                 cf("FINAL FANTASY XI/VTABLE.DAT", vtable, delta: true),
                                                 cf("PlayOnlineViewer/viewer/com/polcore.dll", Data("pol".utf8))]]
        ch.put("/rel/download/client-30260904_1/client-manifest.json", try! JSONSerialization.data(withJSONObject: olClient), t0)
        let olRoot = tmp.appendingPathComponent("Olympus XI")
        func ol(install: Bool = false) -> AscensionSync.Outcome {
            ch.clearLog()
            return RetailWorldSync(spec: RetailWorld.olympus, root: olRoot, sources: olSrc, log: { _ in }).run(install: install, donors: [donor])
        }
        func olFile(_ rel: String) -> Data? { try? Data(contentsOf: olRoot.appendingPathComponent(rel)) }
        func olText(_ rel: String) -> String { olFile(rel).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let olFirst = ol(install: true)
        let olIni = olText("Ashita/config/boot/olympus.ini")
        check("overlay world: XIPivot in place, their DATs in polplugins/DATs/Olympus, the client untouched",
              { if case .ok = olFirst { return true }; return false }() && olFile("Ashita/polplugins/pivot.dll") == Data("pivot".utf8)
                && olFile("Ashita/polplugins/DATs/Olympus/ROM/181/73.DAT") == d1 && olFile("Ashita/polplugins/DATs/Olympus/ROM/1/2.DAT") == d2
                && olFile("Game/FINAL FANTASY XI/ROM/1/1.DAT") == dat)
        check("Olympus client: their list, the donor's identical files, a table only their pack has (zlib stream by Range), the viewer by hash",
              olFile("Game/FINAL FANTASY XI/VTABLE.DAT") == vtable && olFile("Game/FINAL FANTASY XI/FFXiMain.dll") == main
                && olFile("Game/PlayOnlineViewer/viewer/com/polcore.dll") == Data("pol".utf8)
                && RetailWorld.parseOlympusClient(try! JSONSerialization.data(withJSONObject: ["version": "30260904_1", "files": [["path": "SquareEnix/../x", "size": 1, "sha256": String(repeating: "a", count: 64)]]])) == nil)
        check("overlay world: pivot = 1 and their --profileport in the profile, the overlay first in pivot.ini",
              BootProfile.value("pivot", section: "ashita.polplugins", in: olIni) == "1"
                && BootProfile.value("command", section: "ashita.boot", in: olIni) == "--server 172.96.141.132 --profileport 51220"
                && olText("Ashita/config/pivot/pivot.ini").contains("0 = Olympus"))
        check("overlay world, Play with the same patch: only the lists are asked for, nothing downloaded",
              ol() == .ok(changed: 0) && !ch.log.contains { $0.contains("/download/patch-") })
        publishPatch(16, [("ROM/181/73.DAT", d1), ("ROM/1/2.DAT", d3)])
        try? Data("player's own".utf8).write(to: olRoot.appendingPathComponent("Ashita/polplugins/DATs/Olympus/ROM/9/9.DAT"))
        let olUpd = ol()
        check("overlay world, a new patch: only the changed DAT comes down; a file their list no longer has is removed",
              { if case .ok = olUpd { return true }; return false }() && ch.log.filter { $0.contains("/download/patch-") } == ["/rel/download/patch-16/\(AscensionChannel.sha256(d3)).dat 200"]
                && olFile("Ashita/polplugins/DATs/Olympus/ROM/1/2.DAT") == d3 && olFile("Ashita/polplugins/DATs/Olympus/ROM/9/9.DAT") == nil)
        ch.put("/rel/download/patch-17/\(AscensionChannel.sha256(d2)).dat", Data("tampered".utf8), t0)
        let m17: [String: Any] = ["patch": 17, "files": [patchEntry("ROM/1/2.DAT", d2)], "client": ["tag": "client-30260904_1"]]
        ch.put("/rel/latest/download/manifest.json", try! JSONSerialization.data(withJSONObject: m17), t0)
        check("overlay world: a DAT that does not hash to their list is refused, the old one kept",
              { if case .failed = ol() { return true }; return false }() && olFile("Ashita/polplugins/DATs/Olympus/ROM/1/2.DAT") == d3)
        // Legendary's shape: base/manifest.json + base/files/<path>, ROM/0/6.DAT never put in the overlay.
        let lg1 = Data("legendary dat".utf8), pal = Data("pal ui".utf8)
        func lgEntry(_ p: String, _ d: Data) -> [String: Any] { ["path": p, "size": d.count, "sha256": AscensionChannel.sha256(d)] }
        ch.put("/lg/files/ROM/387/14.DAT", lg1, t0); ch.put("/lg/files/ROM/0/6.DAT", pal, t0)
        ch.put("/lg/manifest.json", try! JSONSerialization.data(withJSONObject: ["version": "2026.10.20.2215", "files": [lgEntry("ROM/387/14.DAT", lg1), lgEntry("ROM/0/6.DAT", pal)]]), t0)
        var lgSrc = olSrc; lgSrc.overlaySource = .fileList(base: site + "/lg")
        let lgRoot = tmp.appendingPathComponent("Legendary Relaunch")
        let lgOut = RetailWorldSync(spec: RetailWorld.legendary, root: lgRoot, sources: lgSrc, log: { _ in }).run(install: true, donors: [donor])
        check("file-list overlay (Legendary): their DAT in polplugins/DATs/legendary, ROM/0/6.DAT never put there",
              { if case .ok = lgOut { return true }; return false }()
                && (try? Data(contentsOf: lgRoot.appendingPathComponent("Ashita/polplugins/DATs/legendary/ROM/387/14.DAT"))) == lg1
                && !fm.fileExists(atPath: lgRoot.appendingPathComponent("Ashita/polplugins/DATs/legendary/ROM/0/6.DAT").path))

        // The launcher around it.
        let mist = Server.all.first { $0.name == "MistXI" }, mog = Server.all.first { $0.name == "Moghouse XI" }
        check("built-in: MistXI (2 clients, their list, website account) and Moghouse XI (Create account, 1 client)",
              mist?.installKind == .retailWorld && mog?.installKind == .retailWorld && mist?.codebase == .landSandBoat
                && mist?.maxClients == 2 && mist.map { AddonPolicies.policy(for: $0).isRestricting } == true && mist?.createsAccountAtLogin == false
                && mog?.createsAccountAtLogin == true && mog?.maxClients == 1 && mog?.host == "ffxi.cc"
                && mist?.installKind.updatesBeforePlay == true)
        let oly = Server.all.first { $0.name == "Olympus XI" }, leg = Server.all.first { $0.name == "Legendary Relaunch" }
        check("built-in: Olympus XI (2.2, --profileport, Create account) and Legendary Relaunch (2.1, invite-only, any number of clients)",
              oly?.installKind == .retailWorld && oly?.loaderOptions == ["--profileport", "51220"] && oly?.createsAccountAtLogin == true
                && leg?.installKind == .retailWorld && leg?.createsAccountAtLogin == false && leg?.allowsMultipleClients == true
                && RetailWorld.spec("Olympus XI")?.loader.version == "2.2.0" && RetailWorld.spec("Legendary Relaunch")?.loader.version == "2.1.2")
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
