import Foundation

/// `--selftest-vanadreams`: VanadreamsSync against a fake site on 127.0.0.1 (TestChannel), in a
/// temporary folder: status, download list, client zips, Ashita's archive, the loader, XIPivot.
extension Headless {
    @MainActor static func runVanadreamsSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("vanadreams-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Pure parts.
        let m = VanadreamsChannel.parseManifest(Data(#"{"client_ver":"30260904_1","create_dirs":["USER"],"chunks":[{"name":"base.zip","size":5,"sha256":"AB","unpacked":9},{"name":"pol.zip","size":1,"sha256":"cd","dest":"PlayOnlineViewer"},{"name":"t.zip","size":1,"sha256":"ef","dest":"{ashita}/polplugins/DATs/vanadreams-title"}]}"#.utf8))
        check("manifest: version, chunks, default destination, lower-cased hashes",
              m?.version == "30260904_1" && m?.chunks.count == 3 && m?.chunks[0].dest == "FINAL FANTASY XI" && m?.chunks[0].sha256 == "ab")
        let r = URL(fileURLWithPath: "/R")
        check("destinations: game folder, viewer, {ashita} is the game folder; '..' refused",
              m.map { VanadreamsChannel.destFolder($0.chunks[0], root: r)?.path == "/R/FINAL FANTASY XI"
                && VanadreamsChannel.destFolder($0.chunks[2], root: r)?.path == "/R/polplugins/DATs/vanadreams-title" } == true
                && VanadreamsChannel.destFolder(.init(name: "x", size: 0, sha256: "", dest: "{ashita}/../../etc", unpacked: 0), root: r) == nil)
        // The version and every zip's name go into paths: a list that would leave its folders is refused.
        func parsed(_ ver: String, name: String = "base.zip", dirs: [String] = []) -> VanadreamsChannel.Manifest? {
            let o: [String: Any] = ["client_ver": ver, "create_dirs": dirs, "viewer_create_dirs": dirs,
                                    "chunks": [["name": name, "size": 1, "sha256": "ab"]]]
            return VanadreamsChannel.parseManifest(try! JSONSerialization.data(withJSONObject: o))
        }
        check("manifest: a client_ver not in their shape is refused",
              parsed("30260904_1") != nil && parsed("../../x") == nil && parsed("30260904_1/../x") == nil
                && parsed("30260904_1\n") == nil && parsed("2026_1") == nil && parsed("") == nil)
        check("manifest: a zip named with a path, '.', '..' or a hidden name is refused",
              ["../x.zip", "a/b.zip", "a\\b.zip", ".", "..", ".hidden.zip"].allSatisfy { parsed("30260904_1", name: $0) == nil })
        check("manifest: folders to make that would leave the client are dropped, the rest kept",
              parsed("30260904_1", dirs: ["USER", "../../etc", "/abs", "a/../../b", "C:\\x"])
                .map { $0.createDirs == ["USER"] && $0.viewerCreateDirs == ["USER"] } == true)
        // Their record grows a line at a time with FileHandle's throwing calls: a drive that takes no
        // more (here a file size limit, which writes meet as a full disk) is an error, not a crash.
        let rec0 = tmp.appendingPathComponent("record.txt")
        try? Data("30260904_1 a.zip 00\r\n".utf8).write(to: rec0)
        let appended = (try? VanadreamsSync.appendLine("30260904_1 b.zip 11\r\n", to: rec0)) != nil
        var lim = rlimit(); getrlimit(RLIMIT_FSIZE, &lim)
        let savedLim = lim, sigWas = signal(SIGXFSZ, SIG_IGN)
        lim.rlim_cur = rlim_t((try? Data(contentsOf: rec0))?.count ?? 0)
        setrlimit(RLIMIT_FSIZE, &lim)
        let refused = (try? VanadreamsSync.appendLine("30260904_1 c.zip 22\r\n", to: rec0)) == nil
        var backLim = savedLim; setrlimit(RLIMIT_FSIZE, &backLim); signal(SIGXFSZ, sigWas)
        check("record: a line is appended; a drive that takes no more throws instead of crashing the launcher",
              appended && refused && (try? String(contentsOf: rec0, encoding: .utf8)) == "30260904_1 a.zip 00\r\n30260904_1 b.zip 11\r\n")
        check("profile from Ashita's example: their loader, server, script, XIPivot",
              { let t = VanadreamsChannel.profile(fromExample: "[ashita.boot]\nfile        = .\\\\bootloader\\\\pol.exe\ncommand     = --server homepointxi.com\nscript      = default.txt\n[ashita.polplugins]\nsandbox = 0\n")
                return BootProfile.value("command", section: "ashita.boot", in: t) == "--server vanadreams.online"
                    && BootProfile.loaderName(in: t) == "xiloader.exe" && BootProfile.value("script", section: "ashita.boot", in: t) == "vanadreams.txt"
                    && BootProfile.value("pivot", section: "ashita.polplugins", in: t) == "1" }())
        check("a profile on the old address is pointed at the new one; others are left alone",
              VanadreamsChannel.repointed("--server vanadreams.fairywitch.ca --hairpin") == "--server vanadreams.online --hairpin"
                && VanadreamsChannel.repointed("--server vanadreams.online") == nil)
        check("pivot.ini: overlays already listed keep their place, theirs appended title then looks, root_path gone",
              VanadreamsChannel.pivot("[settings]\r\nroot_path=C:\\x\r\n[overlays]\r\n0=mine\r\n", present: ["vanadreams-title", "vanadreams-looks"])
                == "[settings]\r\n\r\n[overlays]\r\n0 = mine\r\n1 = vanadreams-title\r\n2 = vanadreams-looks\r\n")

        // A fake site.
        let ch = TestChannel()
        guard (try? ch.start()) != nil, ch.port != 0 else { print("  FAIL could not listen"); exit(1) }
        let site = "http://127.0.0.1:\(ch.port)"
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func zip(_ files: [String: Data], top: String? = nil) -> Data {
            let dir = tmp.appendingPathComponent("zipsrc-\(UUID().uuidString)")
            let base = top.map { dir.appendingPathComponent($0) } ?? dir
            for (k, v) in files {
                let f = base.appendingPathComponent(k)
                try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? v.write(to: f)
            }
            let out = tmp.appendingPathComponent("\(UUID().uuidString).zip")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k"] + (top != nil ? ["--keepParent", base.path] : [dir.path]) + [out.path]
            try? p.run(); p.waitUntilExit()
            return (try? Data(contentsOf: out)) ?? Data()
        }
        let example = "[ashita.launcher]\r\nname = Example\r\n[ashita.boot]\r\nfile        = .\\\\bootloader\\\\pol.exe\r\ncommand     = --server homepointxi.com\r\nscript      = default.txt\r\n[ashita.polplugins]\r\nsandbox = 0\r\n"
        let ashita = zip(["Ashita-cli.exe": Data("cli".utf8), "Ashita.dll": Data("dll".utf8),
                          "config/boot/example-privateserver.ini": Data(example.utf8), "scripts/default.txt": Data("/load addons\r\n".utf8),
                          "bootloader/pol.exe": Data("pol".utf8)], top: "Ashita-v4beta-abc")
        let loader = Data("xiloader 2.2".utf8)
        let pivot = zip(["polplugins/pivot.dll": Data("pivot".utf8), "config/pivot/pivot.sample.ini": Data("s".utf8)])
        let baseZip = zip(["FFXiMain.dll": Data("main".utf8), "ROM/1/1.DAT": Data(repeating: 1, count: 300)])
        let polZip = zip(["pol.exe": Data("viewer".utf8)])
        let titleZip = zip(["ROM/119/50.DAT": Data("title".utf8)])
        let fxZip = zip(["d3d8.dll": Data("d3d8to9".utf8), "d3d9.dll": Data("reshade".utf8), "ReShade.ini": Data("r".utf8)])
        func entry(_ name: String, _ d: Data, _ dest: String?) -> [String: Any] {
            var e: [String: Any] = ["name": name, "size": d.count, "sha256": AscensionChannel.sha256(d), "unpacked": d.count]
            if let dest { e["dest"] = dest }
            return e
        }
        var chunks: [[String: Any]] = [entry("base.zip", baseZip, nil), entry("pol-base.zip", polZip, "PlayOnlineViewer"),
                                       entry("vanadreams-title-01.zip", titleZip, "{ashita}/polplugins/DATs/vanadreams-title"),
                                       entry("looks-effects.zip", fxZip, "{ashita}/bootloader")]
        // The download list for `ver`, naming `said` as its client when given.
        func publish(_ ver: String = "30260904_1", saying said: String? = nil) {
            let man: [String: Any] = ["schema": 1, "client_ver": said ?? ver, "create_dirs": ["USER"], "viewer_create_dirs": ["usr/all"], "chunks": chunks]
            ch.put("/client/\(ver)/manifest.json", try! JSONSerialization.data(withJSONObject: man), t0)
        }
        ch.put("/status", Data(#"{"state":"online","client_ver":"30260904_1","ver_lock":0,"stats":{"online":22}}"#.utf8), t0)
        for (n, d) in [("base.zip", baseZip), ("pol-base.zip", polZip), ("vanadreams-title-01.zip", titleZip), ("looks-effects.zip", fxZip)] {
            ch.put("/client/30260904_1/\(n)", d, t0)
        }
        publish()
        ch.put("/ashita.zip", ashita, t0); ch.put("/xiloader.exe", loader, t0); ch.put("/pivot.zip", pivot, t0)
        let src = VanadreamsChannel.Sources(status: site + "/status", clientBase: site + "/client/", ashitaZip: site + "/ashita.zip",
                                            loader: site + "/xiloader.exe", loaderSHA: AscensionChannel.sha256(loader),
                                            pivot: site + "/pivot.zip", pivotSHA: AscensionChannel.sha256(pivot))
        let root = tmp.appendingPathComponent("Vanadreams")
        func sync(_ s: VanadreamsChannel.Sources = src, install: Bool = false, stop: StopFlag = StopFlag()) -> AscensionSync.Outcome {
            ch.clearLog()
            return VanadreamsSync(root: root, sources: s, stop: stop, log: { _ in }).run(install: install)
        }
        func file(_ rel: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(rel)) }
        func text(_ rel: String) -> String { file(rel).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        func state() -> [String: Any] { file(".ffxi-on-mac/vanadreams.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
        // The client zips the last sync asked for, with their answers.
        func fetched() -> [String] { ch.log.filter { $0.hasPrefix("/client/") && !$0.contains("/manifest.json") } }

        let first = sync(install: true)
        check("install: succeeds", { if case .ok = first { return true }; return false }())
        check("install: Ashita at the top of the game folder (the archive's own folder dropped)",
              file("Ashita-cli.exe") == Data("cli".utf8) && file("config/boot/example-privateserver.ini") != nil)
        check("install: their loader in bootloader/, XIPivot in polplugins/",
              file("bootloader/xiloader.exe") == loader && file("polplugins/pivot.dll") == Data("pivot".utf8))
        check("install: the client in FINAL FANTASY XI and PlayOnlineViewer, their DAT pack as an overlay",
              file("FINAL FANTASY XI/ROM/1/1.DAT") == Data(repeating: 1, count: 300) && file("PlayOnlineViewer/pol.exe") == Data("viewer".utf8)
                && file("polplugins/DATs/vanadreams-title/ROM/119/50.DAT") == Data("title".utf8))
        check("install: their effects beside the loader are switched off (.off), their other files kept",
              file("bootloader/d3d8.dll") == nil && file("bootloader/d3d9.dll.off") == Data("reshade".utf8) && file("bootloader/ReShade.ini") != nil)
        check("install: folders the client wants are made",
              fm.fileExists(atPath: root.appendingPathComponent("FINAL FANTASY XI/USER").path)
                && fm.fileExists(atPath: root.appendingPathComponent("PlayOnlineViewer/usr/all").path))
        let prof = text("config/boot/vanadreams.ini")
        check("install: vanadreams.ini boots xiloader at vanadreams.online with vanadreams.txt",
              BootProfile.value("command", section: "ashita.boot", in: prof) == "--server vanadreams.online"
                && BootProfile.loaderName(in: prof) == "xiloader.exe" && BootProfile.value("script", section: "ashita.boot", in: prof) == "vanadreams.txt")
        check("install: their script shape, with the player's marker", text("scripts/vanadreams.txt").contains("/load addons")
              && text("scripts/vanadreams.txt").contains("# --- yours ---"))
        check("install: pivot.ini lists the title pack", text("config/pivot/pivot.ini").contains("0 = vanadreams-title"))
        check("install: their record, one line per zip", text(".vanadreams-client.txt").components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 4)
        check("install: each zip's files and sizes listed as it is unpacked; the client being fetched written down first",
              text(".ffxi-on-mac/vanadreams-files/base.zip.txt").contains("300\tROM/1/1.DAT")
                && text(".ffxi-on-mac/vanadreams-files/looks-effects.zip.txt").contains("7\td3d9.dll")
                && state()["target"] as? String == "30260904_1")

        let second = sync()
        check("update: nothing new -> no zip, Ashita or loader downloaded",
              second == .ok(changed: 0) && !ch.log.contains { $0.hasSuffix(".zip 200") || $0.hasPrefix("/xiloader.exe") })
        // They add a zip to the same client version (their 11 Oct 2026 looks): only it comes down.
        let looks = zip(["ROM/1/2.DAT": Data("look".utf8)])
        ch.put("/client/30260904_1/looks-01.zip", looks, t0)
        chunks.append(entry("looks-01.zip", looks, "{ashita}/polplugins/DATs/vanadreams-looks"))
        publish()
        let third = sync()
        check("update: a zip added later is fetched, alone, and listed in pivot.ini after the title",
              { if case .ok(let n) = third { return n == 1 }; return false }()
                && ch.log.filter { $0.hasSuffix(".zip 200") } == ["/client/30260904_1/looks-01.zip 200"]
                && text("config/pivot/pivot.ini").contains("0 = vanadreams-title\r\n1 = vanadreams-looks"))
        // The server moved: an old profile follows it.
        let old = BootProfile.setting(.init(section: "ashita.boot", key: "command", value: "--server vanadreams.fairywitch.ca"), in: prof)
        try? old.write(to: root.appendingPathComponent("config/boot/vanadreams.ini"), atomically: true, encoding: .utf8)
        _ = sync()
        check("update: a profile on their old address is pointed at the new one",
              BootProfile.value("command", section: "ashita.boot", in: text("config/boot/vanadreams.ini")) == "--server vanadreams.online")
        // Setup and Repair check each zip's files against its list; a Play-time update does not.
        let clean = sync(install: true)
        let cleanFetched = fetched()
        try? fm.removeItem(at: root.appendingPathComponent("FINAL FANTASY XI/ROM/1/1.DAT"))
        try? Data("v".utf8).write(to: root.appendingPathComponent("PlayOnlineViewer/pol.exe"))
        _ = sync()
        let updateFetched = fetched()
        let repaired = sync(install: true)
        check("repair: a file missing and one the wrong size bring back their zips, only those; a clean Repair (effects .off included) and an update fetch none",
              clean == .ok(changed: 0) && cleanFetched.isEmpty && updateFetched.isEmpty && repaired == .ok(changed: 2)
                && fetched() == ["/client/30260904_1/base.zip 200", "/client/30260904_1/pol-base.zip 200"]
                && file("FINAL FANTASY XI/ROM/1/1.DAT") == Data(repeating: 1, count: 300) && file("PlayOnlineViewer/pol.exe") == Data("viewer".utf8))
        try? fm.removeItem(at: root.appendingPathComponent(".ffxi-on-mac/vanadreams-files/vanadreams-title-01.zip.txt"))
        _ = sync(install: true)
        let unlisted = fetched()
        _ = sync(install: true)
        check("repair: a zip unpacked before lists were kept is fetched once more, then checked by its list",
              unlisted == ["/client/30260904_1/vanadreams-title-01.zip 200"] && fetched().isEmpty)
        // A later zip replacing a file an earlier one holds (a patch): the file is the later zip's.
        let patch = zip(["FFXiMain.dll": Data("main v2".utf8)])
        ch.put("/client/30260904_1/patch-01.zip", patch, t0)
        chunks.append(entry("patch-01.zip", patch, nil)); publish()
        _ = sync()
        _ = sync(install: true)
        let patchedClean = fetched()
        try? fm.removeItem(at: root.appendingPathComponent("FINAL FANTASY XI/ROM/1/1.DAT"))
        _ = sync(install: true)
        check("repair: a file a later zip replaces is checked against it; the earlier zip fetched again brings the later one again after it",
              patchedClean.isEmpty && fetched() == ["/client/30260904_1/base.zip 200", "/client/30260904_1/patch-01.zip 200"]
                && file("FINAL FANTASY XI/FFXiMain.dll") == Data("main v2".utf8) && file("FINAL FANTASY XI/ROM/1/1.DAT") == Data(repeating: 1, count: 300))
        // Zips come down with FileDownload, straight into the folder they wait in: one stopped part-way
        // carries on; a folder left from another client version goes.
        let looks2 = zip(["ROM/2/1.DAT": Data(repeating: 2, count: 4000)])
        ch.put("/client/30260904_1/looks-02.zip", looks2, t0)
        chunks.append(entry("looks-02.zip", looks2, "{ashita}/polplugins/DATs/vanadreams-looks")); publish()
        let waiting = root.appendingPathComponent(".ffxi-on-mac/tmp/client-30260904_1")
        try? fm.createDirectory(at: waiting, withIntermediateDirectories: true)
        try? looks2.prefix(looks2.count / 2).write(to: waiting.appendingPathComponent("looks-02.zip"))
        let stale = root.appendingPathComponent(".ffxi-on-mac/tmp/client-30250101_1")
        try? fm.createDirectory(at: stale, withIntermediateDirectories: true)
        let resumed = sync()
        check("chunks: one stopped part-way carries on where it stopped; a folder left from another client version is removed",
              resumed == .ok(changed: 1) && fetched() == ["/client/30260904_1/looks-02.zip 206"]
                && file("polplugins/DATs/vanadreams-looks/ROM/2/1.DAT") == Data(repeating: 2, count: 4000)
                && !fm.fileExists(atPath: waiting.appendingPathComponent("looks-02.zip").path) && !fm.fileExists(atPath: stale.path))
        let looks3 = zip(["ROM/2/2.DAT": Data(repeating: 3, count: 4000)])
        ch.put("/client/30260904_1/looks-03.zip", looks3, t0)
        chunks.append(entry("looks-03.zip", looks3, "{ashita}/polplugins/DATs/vanadreams-looks")); publish()
        try? fm.createDirectory(at: waiting, withIntermediateDirectories: true)
        try? Data(repeating: 0, count: looks3.count).write(to: waiting.appendingPathComponent("looks-03.zip"))
        let restarted = sync()
        check("chunks: a whole leftover that does not hash right is started again, not carried on",
              restarted == .ok(changed: 1) && fetched() == ["/client/30260904_1/looks-03.zip 416", "/client/30260904_1/looks-03.zip 200"]
                && file("polplugins/DATs/vanadreams-looks/ROM/2/2.DAT") == Data(repeating: 3, count: 4000))
        // A download list for another client than the one asked for is not used.
        publish(saying: "30260905_1")
        check("a download list naming another client version than the one asked for is not used",
              { if case .offline = sync() { return true }; return false }() && fetched().isEmpty)
        publish()
        // A new client version carrying the same zips (same names, same sha256) fetches none of them.
        ch.put("/status", Data(#"{"state":"online","client_ver":"30261001_1"}"#.utf8), t0); publish("30261001_1")
        let bumped = sync()
        check("new client version: zips it carries unchanged are not fetched again; it is the client and the target",
              bumped == .ok(changed: 0) && fetched().isEmpty
                && state()["client"] as? String == "30261001_1" && state()["target"] as? String == "30261001_1")
        ch.put("/status", Data(#"{"state":"online","client_ver":"30260904_1"}"#.utf8), t0)
        // Their status API down: which client a folder asks for (here a list that is not there, so the
        // failure names it).
        func asked(state st: [String: Any]?, record: String?) -> String {
            let r = tmp.appendingPathComponent("fallback-\(UUID().uuidString)")
            try? fm.createDirectory(at: r.appendingPathComponent(".ffxi-on-mac"), withIntermediateDirectories: true)
            if let st, let d = try? JSONSerialization.data(withJSONObject: st) { try? d.write(to: r.appendingPathComponent(".ffxi-on-mac/vanadreams.json")) }
            if let record { try? record.write(to: r.appendingPathComponent(".vanadreams-client.txt"), atomically: true, encoding: .utf8) }
            var s = src; s.status = "http://127.0.0.1:9/status"; s.clientBase = site + "/none/"
            if case .failed(let why) = VanadreamsSync(root: r, sources: s, log: { _ in }).run() { return why }
            return ""
        }
        let rec = "30260801_1 a.zip 00\r\n30260950_3 b.zip 11\r\n"
        check("status API down: the client an update was fetching, else the last finished, else their record's last; the built-in one only with none",
              asked(state: ["finished": false, "target": "30261101_2", "client": "30261001_1"], record: rec).contains("client 30261101_2")
                && asked(state: ["finished": false, "client": "30261001_1"], record: rec).contains("client 30261001_1")
                && asked(state: nil, record: rec).contains("client 30260950_3")
                && asked(state: nil, record: nil).contains("client \(VanadreamsChannel.knownClientVersion)"))
        // A damaged download is refused.
        var bad = src; bad.loaderSHA = String(repeating: "0", count: 64)
        try? fm.removeItem(at: root.appendingPathComponent("bootloader/xiloader.exe"))
        check("loader: a download that does not hash to the pinned release is refused",
              { if case .failed = sync(bad) { return true }; return false }() && file("bootloader/xiloader.exe") == nil)
        _ = sync()
        // Offline after a finished update plays; Stop stops.
        var down = src; down.status = "http://127.0.0.1:9/status"; down.clientBase = "http://127.0.0.1:9/client/"
        check("offline after a finished update: play with what is there", { if case .offline = sync(down) { return true }; return false }())
        let flag = StopFlag(); flag.raise()
        check("stop: .stopped", sync(stop: flag) == .stopped)
        // A download list naming a folder outside the game is refused.
        chunks.append(["name": "evil.zip", "size": 1, "sha256": "00", "dest": "{ashita}/../../escape"]); publish()
        check("a destination outside the game folder is refused",
              { if case .failed(let why) = sync() { return why.contains("outside") }; return false }())

        // Create account (LoginAccount): the request, the answers, the version in both wordings.
        let req = (try? JSONSerialization.jsonObject(with: LoginAccount.request(user: "u", password: "p", version: [2, 2, 0]))) as? [String: Any]
        check("account: the request is xiloader's (command 0x20, empty otp and new_password, the version)",
              req?["command"] as? Int == 32 && req?["otp"] as? String == "" && req?["new_password"] as? String == ""
                && req?["version"] as? [Int] == [2, 2, 0] && req?["username"] as? String == "u")
        check("account: answers 3 created, 4 taken, 8 creation off, an error message passed through",
              LoginAccount.outcome(of: Data(#"{"result":3}"#.utf8)) == .created
                && LoginAccount.outcome(of: Data(#"{"result":4}"#.utf8)) == .taken
                && { if case .refused = LoginAccount.outcome(of: Data(#"{"result":8}"#.utf8)) { return true }; return false }()
                && LoginAccount.outcome(of: Data(#"{"error_message":"No.\nReally."}"#.utf8)) == .refused("No. Really.")
                && { if case .failed = LoginAccount.outcome(of: Data()) { return true }; return false }())
        check("account: the version the server asks for, old and new wording, never the one reported",
              LoginAccount.requiredVersion(in: "Your xiloader is too old.\nPlease update to version '2.1.x'.\nYour client reported '0.0.0'.") == [2, 1, 0]
                && LoginAccount.requiredVersion(in: "Unsupported xiloader version 0.0.0.\nThis server requires version 2.2.x.") == [2, 2, 0]
                && LoginAccount.requiredVersion(in: "Unsupported xiloader version 0.0.0.") == nil)
        check("account: names and passwords the server would drop silently are refused first",
              LoginAccount.problem(user: "", password: "x") != nil && LoginAccount.problem(user: String(repeating: "a", count: 17), password: "x") != nil
                && LoginAccount.problem(user: "a b", password: "x") != nil && LoginAccount.problem(user: "ab", password: "has space") != nil
                && LoginAccount.problem(user: "Murn01", password: "ok-pass_1") == nil)
        check("account: Vanadreams, Supernova, Moghouse XI, LevelDown 99, Scythe and Olympus XI offer Create account; HorizonXI and AscensionXI do not",
              Server.all.filter(\.createsAccountAtLogin).map(\.name).sorted() == ["LevelDown 99", "Moghouse XI", "Olympus XI", "Scythe", "Supernova", "Vanadreams"])

        // The launcher around it.
        let v = Server.all.first { $0.name == VanadreamsChannel.worldName }
        check("built-in: Vanadreams, LandSandBoat, its kind, xiloader, any number of clients, addons unrestricted",
              Server.builtins.contains { $0.name == VanadreamsChannel.worldName } && v?.codebase == .landSandBoat
                && v?.installKind == .vanadreamsPackage && v?.installKind.updatesBeforePlay == true && v?.loader == "xiloader.exe"
                && v?.allowsMultipleClients == true && v.map { !AddonPolicies.policy(for: $0).isRestricting } == true)
        let enc = v.flatMap { try? JSONEncoder().encode([$0]) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
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

    /// `--vanadreams-sync [--install] [--root <folder>]`: the install or update the button runs,
    /// headless, printing every line. Never launches the game.
    @MainActor static func runVanadreamsSync(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)   // a line at a time, also into a file
        let store = ServerStore()
        var rootPath = store.servers.first { $0.name == VanadreamsChannel.worldName }?.dataPath ?? ""
        if let k = args.firstIndex(of: "--root"), k + 1 < args.count { rootPath = args[k + 1] }
        guard !rootPath.isEmpty else { FileHandle.standardError.write(Data("pass --root <folder>\n".utf8)); exit(2) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var last = -1
        let sync = VanadreamsSync(root: root, log: { print($0) }, progress: { label, f in
            let pct = Int(f * 100)
            if pct != last, pct % 5 == 0 { last = pct; print("   \(label) \(pct)%") }
        })
        var outcome: AscensionSync.Outcome = .failed("not run")
        let done = DispatchSemaphore(value: 0)
        let install = args.contains("--install")
        Thread.detachNewThread { outcome = sync.run(install: install); done.signal() }
        while done.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print("outcome: \(outcome)")
        switch outcome { case .ok, .offline: exit(0); default: exit(1) }
    }
}

/// `--login-version <host>`: what LoginAccount's first step learns from a world's login server (one
/// TLS request with version 0.0.0, which every LandSandBoat server refuses before doing anything).
/// Creates nothing.
extension Headless {
    @MainActor static func runLoginVersion(_ args: [String]) -> Never {
        guard let k = args.firstIndex(of: "--login-version"), k + 1 < args.count else { print("usage: --login-version <host>"); exit(2) }
        let host = args[k + 1]
        var out: Result<Data, LoginAccount.Failure>?
        Task { out = await LoginAccount.exchange(host: host, port: LoginAccount.port,
                                                 body: LoginAccount.request(user: "zzprobe_notarealuser", password: "zzprobe", version: [0, 0, 0], command: 0x10)) }
        while out == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        switch out! {
        case .success(let d):
            let o = LoginAccount.outcome(of: d)
            print("\(host): \(o)")
            if case .refused(let msg) = o, let v = LoginAccount.requiredVersion(in: msg) { print("version: \(v)"); exit(0) }
            exit(1)
        case .failure(let e): print("\(host): \(e.description)"); exit(1)
        }
    }
}
