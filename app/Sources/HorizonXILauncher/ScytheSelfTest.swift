import CryptoKit
import Foundation

/// `--selftest-scythe`: ScytheSync against a fake site on 127.0.0.1: a release signed with a test key
/// in the exact shape theirs is served in, its manifest, objects, Ashita and loader, and a donor client.
extension Headless {
    @MainActor static func runScytheSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("scythe-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        func write(_ d: Data, _ u: URL) {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: u)
        }

        // Their real release (2026-10-24) and key: the signature must verify, and change nothing in it.
        let real = Data("""
        {\r\n  "release": {\r\n    "schemaVersion": 1,\r\n    "releaseId": "scythe-30260429-1-r1",\r\n    "clientVersion": "30260429_1",\r\n    "minimumLauncherVersion": "3.0.0",\r\n    "package": {\r\n      "file": "scythe-30260429-1-r1.zip",\r\n      "url": "https://212-28-177-210.sslip.io/launcher/releases/scythe-30260429-1-r1.zip",\r\n      "bytes": 140,\r\n      "sha256": "E4E8A79844B21B4140CE4CD8C6A88CFF8AB3A31BCC806B421A5B51A614A5D560"\r\n    },\r\n    "source": {\r\n      "fileCount": 65062,\r\n      "bytes": 14865300130,\r\n      "sha256": "E4A9B818DBBD88844F5E2111420B689F751BF01EAB8042317E7702094052826B"\r\n    },\r\n    "target": {\r\n      "fileCount": 65062,\r\n      "bytes": 14865300130,\r\n      "sha256": "E4A9B818DBBD88844F5E2111420B689F751BF01EAB8042317E7702094052826B"\r\n    },\r\n    "files": [],\r\n    "removePaths": []\r\n  },\r\n  "signature": "9XuOuOhHsF\\u002B/7BcifBGstdnjBhpnY60NUlKzzwcBSNozWyFgufy\\u002B0ZqpJ4e8Nw0Qny7BMkGt6LTQhn8ObRO9lQ=="\r\n}
        """.utf8)
        let rel = ScytheChannel.verify(real, key: ScytheChannel.releaseKey)
        check("their real release verifies with their key: 740 signed bytes, id, version, target",
              ScytheChannel.signedBytes(real)?.count == 740 && rel?.releaseId == "scythe-30260429-1-r1" && rel?.manifestId == "scythe-30260429-1"
                && rel?.clientVersion == "30260429_1" && rel?.targetCount == 65062 && rel?.targetSHA.hasPrefix("E4A9B818") == true)
        let tampered = Data(String(decoding: real, as: UTF8.self).replacingOccurrences(of: "\"bytes\": 140", with: "\"bytes\": 141").utf8)
        check("a release changed by one byte is refused", ScytheChannel.verify(tampered, key: ScytheChannel.releaseKey) == nil)
        // Their tree hash sorts the Windows way: on "ROM\\1.DAT", where '\\' (0x5C) comes before '_' (0x5F).
        let tf: [DriftwoodChannel.ClientFile] = [.init(path: "ROM_X.DAT", size: 1, sha256: "aa"), .init(path: "ROM/1.DAT", size: 2, sha256: "bb")]
        let manual = AscensionChannel.sha256(Data("scythe-client-tree-v1\nROM/1.DAT\u{0}2\u{0}BB\nROM_X.DAT\u{0}1\u{0}AA\n".utf8)).uppercased()
        check("tree hash: backslash order, path\\0length\\0SHA lines, upper hex", ScytheChannel.treeHash(tf) == manual)

        // A fake site, signed with a key of the test's own.
        let ch = TestChannel()
        guard (try? ch.start()) != nil, ch.port != 0 else { print("  FAIL could not listen"); exit(1) }
        let site = "http://127.0.0.1:\(ch.port)"
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let key = P256.Signing.PrivateKey()
        let same = Data(repeating: 5, count: 900), theirs = Data("their 2026-04 dat".utf8), main = Data("ffximain-0429".utf8)
        let donor = tmp.appendingPathComponent("Other/SquareEnix")
        write(same, donor.appendingPathComponent("FINAL FANTASY XI/ROM/1/1.DAT"))
        write(Data("retail 2026-09 dat".utf8), donor.appendingPathComponent("FINAL FANTASY XI/ROM/1/2.DAT"))
        write(Data("ffximain-0904".utf8), donor.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll"))
        write(Data("pol".utf8), donor.appendingPathComponent("PlayOnlineViewer/viewer/com/polcore.dll"))
        func entry(_ p: String, _ d: Data) -> [String: Any] { ["path": p, "length": d.count, "sha256": AscensionChannel.sha256(d).uppercased()] }
        var files: [[String: Any]] = [entry("FFXiMain.dll", main), entry("ROM/1/1.DAT", same), entry("ROM/1/2.DAT", theirs), entry("empty.txt", Data())]
        for d in [main, theirs] { let h = AscensionChannel.sha256(d); ch.put("/launcher/client/objects/\(h.prefix(2))/\(h)", d, t0) }
        func clientFiles() -> [DriftwoodChannel.ClientFile] {
            files.map { .init(path: $0["path"] as! String, size: Int64($0["length"] as! Int), sha256: ($0["sha256"] as! String).lowercased()) }
        }
        func publish(_ id: String, signWith k: P256.Signing.PrivateKey? = nil) {
            let man: [String: Any] = ["schemaVersion": 1, "releaseId": id, "clientVersion": "30260429_1", "mutableRoots": ["SYS", "TEMP", "USER"], "files": files]
            ch.put("/launcher/client/releases/\(id)/manifest.json", try! JSONSerialization.data(withJSONObject: man), t0)
            let cf = clientFiles()
            let body = "{\n  \"schemaVersion\": 1,\n  \"releaseId\": \"\(id)-r1\",\n  \"clientVersion\": \"30260429_1\",\n  \"minimumLauncherVersion\": \"3.0.0\",\n"
                + "  \"target\": {\n    \"fileCount\": \(cf.count),\n    \"bytes\": \(cf.reduce(Int64(0)) { $0 + $1.size }),\n    \"sha256\": \"\(ScytheChannel.treeHash(cf))\"\n  },\n"
                + "  \"files\": [],\n  \"removePaths\": []\n}"
            let signed = Data(body.replacingOccurrences(of: "\n", with: "\r\n").utf8)
            let sig = try! (k ?? key).signature(for: signed).rawRepresentation.base64EncodedString()
            let nested = body.components(separatedBy: "\n").enumerated().map { $0.offset == 0 ? $0.element : "  " + $0.element }.joined(separator: "\r\n")
            ch.put("/launcher/channel/current.json", Data("{\r\n  \"release\": \(nested),\r\n  \"signature\": \"\(sig)\"\r\n}".utf8), t0)
        }
        publish("scythe-test-1")
        // Ashita zip, GitHub-style, and the loader.
        let asrc = tmp.appendingPathComponent("ashita-src/Ashita-v4beta-4.3.1.1")
        for (k, v) in ["Ashita-cli.exe": "cli", "config/boot/example-privateserver.ini": "[ashita.boot]\r\n", "plugins/addons.dll": "a"] { write(Data(v.utf8), asrc.appendingPathComponent(k)) }
        let az = tmp.appendingPathComponent("ashita.zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", asrc.path, az.path]
        try? p.run(); p.waitUntilExit()
        let azData = (try? Data(contentsOf: az)) ?? Data()
        ch.put("/ashita.zip", azData, t0)
        let loaderBytes = Data("xiloader 1.1.5".utf8)
        ch.put("/xiloader.exe", loaderBytes, t0)
        var src = ScytheChannel.Sources(base: site, ashitaZip: site + "/ashita.zip", ashitaSHA: AscensionChannel.sha256(azData),
                                        loader: .init(version: "1.1.5", sha256: AscensionChannel.sha256(loaderBytes), url: site + "/xiloader.exe"),
                                        publicKey: key.publicKey)
        let root = tmp.appendingPathComponent("Scythe")
        func sync(_ s: ScytheChannel.Sources? = nil, install: Bool = false, stop: StopFlag = StopFlag()) -> AscensionSync.Outcome {
            ch.clearLog()
            return ScytheSync(root: root, sources: s ?? src, stop: stop, log: { _ in }).run(install: install, donors: [donor])
        }
        func file(_ rel: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(rel)) }
        func objects() -> [String] { ch.log.filter { $0.contains("/objects/") } }

        let first = sync(install: true)
        check("install: succeeds", { if case .ok = first { return true }; return false }())
        check("install: identical files copied from the donor, the rest fetched by SHA-256, newer retail ones replaced",
              file("Game/FINAL FANTASY XI/ROM/1/1.DAT") == same && file("Game/FINAL FANTASY XI/ROM/1/2.DAT") == theirs
                && file("Game/FINAL FANTASY XI/FFXiMain.dll") == main && file("Game/FINAL FANTASY XI/empty.txt") == Data()
                && objects().count == 2)
        check("install: their Ashita in Ashita/, their loader, the viewer",
              file("Ashita/Ashita-cli.exe") == Data("cli".utf8) && file("Ashita/bootloader/xiloader.exe") == loaderBytes
                && file("Game/PlayOnlineViewer/viewer/com/polcore.dll") == Data("pol".utf8))
        let ini = String(decoding: file("Ashita/config/boot/scythe.ini") ?? Data(), as: UTF8.self)
        check("install: scythe.ini as theirs (server, FFXiMain.dll, no overrides) with the sandbox off and a script",
              BootProfile.value("command", section: "ashita.boot", in: ini) == "--server 212.28.177.210"
                && BootProfile.loaderName(in: ini) == "xiloader.exe" && BootProfile.value("sandbox", section: "ashita.polplugins", in: ini) == "0"
                && BootProfile.value("script", section: "ashita.boot", in: ini) == "scythe.txt"
                && BootProfile.value("resources.use_overrides", section: "ashita.resources", in: ini) == "0" && file("Ashita/scripts/scythe.txt") != nil)
        check("Play, nothing new: the release alone is asked for", sync() == .ok(changed: 0) && ch.log == ["/launcher/channel/current.json 200"])
        // A new release: one file changed, one dropped.
        let theirs2 = Data("their 2026-05 dat".utf8)
        let h2 = AscensionChannel.sha256(theirs2); ch.put("/launcher/client/objects/\(h2.prefix(2))/\(h2)", theirs2, t0)
        files = [entry("FFXiMain.dll", main), entry("ROM/1/1.DAT", same), entry("ROM/1/2.DAT", theirs2)]
        publish("scythe-test-2")
        let upd = sync()
        check("update: only the changed file is fetched; a file the release dropped is removed",
              { if case .ok = upd { return true }; return false }() && objects().count == 1 && file("Game/FINAL FANTASY XI/ROM/1/2.DAT") == theirs2
                && file("Game/FINAL FANTASY XI/empty.txt") == nil)
        // A release signed by another key, a manifest not matching the signed target.
        publish("scythe-test-3", signWith: P256.Signing.PrivateKey())
        check("a release signed by another key is refused, nothing changed",
              { if case .failed(let why) = sync() { return why.contains("not signed") }; return false }() && file("Game/FINAL FANTASY XI/ROM/1/2.DAT") == theirs2)
        publish("scythe-test-2")
        ch.put("/launcher/client/releases/scythe-test-4/manifest.json", Data(#"{"releaseId":"scythe-test-4","clientVersion":"30260429_1","files":[]}"#.utf8), t0)
        files.append(entry("ROM/1/3.DAT", Data("x".utf8))); publish("scythe-test-4")
        ch.put("/launcher/client/releases/scythe-test-4/manifest.json", Data(#"{"releaseId":"scythe-test-4","clientVersion":"30260429_1","files":[]}"#.utf8), t0)
        check("a file list that does not hash to the signed target is refused",
              { if case .failed(let why) = sync() { return why.contains("does not match") }; return false }())
        files.removeLast(); publish("scythe-test-2")
        // Damaged object, damaged loader.
        try? Data("broken".utf8).write(to: root.appendingPathComponent("Game/FINAL FANTASY XI/FFXiMain.dll"))
        check("Repair: a damaged file is fetched again", { if case .ok = sync(install: true) { return true }; return false }()
              && file("Game/FINAL FANTASY XI/FFXiMain.dll") == main)
        var bad = src; bad.loader.sha256 = String(repeating: "0", count: 64)
        try? fm.removeItem(at: root.appendingPathComponent("Ashita/bootloader/xiloader.exe"))
        check("a loader that does not hash to the pin is refused",
              { if case .failed = sync(bad) { return true }; return false }() && file("Ashita/bootloader/xiloader.exe") == nil)
        _ = sync()
        let down = ScytheChannel.Sources(base: "http://127.0.0.1:9", ashitaZip: src.ashitaZip, ashitaSHA: src.ashitaSHA, loader: src.loader, publicKey: key.publicKey)
        check("offline after a finished update: play with what is there", { if case .offline = sync(down) { return true }; return false }())
        let flag = StopFlag(); flag.raise()
        check("stop: .stopped", sync(stop: flag) == .stopped)
        src.publicKey = nil
        check("no key, no install", { if case .failed = sync() { return true }; return false }())

        // The launcher around it.
        let w = Server.all.first { $0.name == ScytheChannel.worldName }
        check("built-in: Scythe, LandSandBoat, its kind, two clients, Create account",
              w?.installKind == .scytheChannel && w?.codebase == .landSandBoat && w?.maxClients == 2 && w?.createsAccountAtLogin == true
                && w?.installKind.updatesBeforePlay == true && w?.host == "212.28.177.210")
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

    /// `--scythe-sync [--install] [--root <folder>]`: the install or update the button runs, headless,
    /// with every other world's client offered as a donor. Never launches the game.
    @MainActor static func runScytheSync(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)   // a line at a time, also into a file
        let store = ServerStore()
        var rootPath = store.servers.first { $0.name == ScytheChannel.worldName }?.dataPath ?? ""
        if let r = args.firstIndex(of: "--root"), r + 1 < args.count { rootPath = args[r + 1] }
        guard !rootPath.isEmpty else { FileHandle.standardError.write(Data("pass --root <folder>\n".utf8)); exit(2) }
        guard let base = InstallSelection.inUse() ?? Install.lastChosen() else {
            FileHandle.standardError.write(Data("no install found\n".utf8)); exit(2)
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let donors = AscensionChannel.donorClients(store.servers.filter { $0.name != ScytheChannel.worldName }, base: base)
        for d in donors { print("donor: \(d.path)") }
        var last = -1
        let sync = ScytheSync(root: root, log: { print($0) }, progress: { label, f in
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
