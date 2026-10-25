import Foundation
import Network

/// `--selftest-pegasus`: PegasusSync against a fake CDN on 127.0.0.1 (TestChannel, with Range
/// requests), in a temporary folder: their pack index, release zips made with Info-ZIP (one forced to
/// ZIP64), install, Play-time check, Repair, an update, a damaged member. Then FileDownload's resume
/// against TestChannel and against ScriptedHTTPServer's servers that do not honour Range.
extension Headless {
    @MainActor static func runPegasusSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pegasus-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        func write(_ d: Data, _ u: URL) {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: u)
        }

        // Pure parts.
        check("pack index: version and zip, only from their CDN",
              PegasusChannel.parsePack(Data(#"{"version":"1.2.4","zipUrl":"https://cdn.pegasusxi.com/launcher/PegasusXI_1.2.4.zip"}"#.utf8), prefix: "https://cdn.pegasusxi.com/")
                == .init(version: "1.2.4", zipURL: "https://cdn.pegasusxi.com/launcher/PegasusXI_1.2.4.zip")
                && PegasusChannel.parsePack(Data(#"{"version":"1.2.4","zipUrl":"https://evil.example/x.zip"}"#.utf8), prefix: "https://cdn.pegasusxi.com/") == nil)
        check("paths: their wrapper folder dropped; anything outside it or unsafe refused",
              PegasusChannel.relative("PegasusXI_1.2.4/Game/Ashita.dll") == "Game/Ashita.dll"
                && PegasusChannel.relative("Other/Game/Ashita.dll") == nil && PegasusChannel.relative("PegasusXI_1.2.4/../x") == nil
                && PegasusChannel.relative("PegasusXI_1.2.4/") == nil)
        check("their Windows-only files are skipped, the game's are not",
              PegasusChannel.skipped("prereqs/Visual C++ 2008/vcredist_x86.exe") && PegasusChannel.skipped("Game/PegasusXI Launcher.exe")
                && PegasusChannel.skipped("Game/LauncherLogs/launcher.log") && PegasusChannel.skipped("Game/pegasus-config.json")
                && PegasusChannel.skipped("Game/config/boot/__runtime_pega.ini") && PegasusChannel.skipped("Install PegasusXI Prereqs.exe")
                && !PegasusChannel.skipped("Game/Ashita-cli.exe") && !PegasusChannel.skipped("Game/config/boot/PegasusXI.ini"))
        check("the player's files: config, scripts, USER, PlayOnline's usr; not Ashita's own config or addons",
              PegasusChannel.userEditable("Game/config/boot/PegasusXI.ini") && PegasusChannel.userEditable("Game/scripts/default.txt")
                && PegasusChannel.userEditable("Game/SquareEnix/FINAL FANTASY XI/USER/1/acq.dat")
                && PegasusChannel.userEditable("Game/SquareEnix/PlayOnlineViewer/usr/all/x.png")
                && !PegasusChannel.userEditable("Game/config/ashita/ashita.datmap.ini") && !PegasusChannel.userEditable("Game/addons/fps/fps.lua"))
        check("crc32", PegasusChannel.crc32(Data("hello".utf8)) == 0x3610_a686)

        // Release zips, made the way Info-ZIP makes them (deflate, data descriptors off, extra fields on).
        func release(_ version: String, _ files: [String: Data], zip64: Bool = false) -> Data {
            let dir = tmp.appendingPathComponent("rel-\(UUID().uuidString)")
            for (k, v) in files { write(v, dir.appendingPathComponent("PegasusXI_\(version)/\(k)")) }
            let out = tmp.appendingPathComponent("\(UUID().uuidString).zip")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            p.arguments = ["-r", "-q"] + (zip64 ? ["-fz"] : []) + [out.path, "PegasusXI_\(version)"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            return (try? Data(contentsOf: out)) ?? Data()
        }
        var gen = SystemRandomNumberGenerator()
        let main = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &gen) })
        let profile = "[ashita.boot]\r\nfile        = .\\bootloader\\xiloader.exe\r\ncommand     = --server play.pegasusxi.com\r\nscript      = default.txt\r\n"
        var v1: [String: Data] = [
            "Game/Ashita-cli.exe": Data("cli".utf8), "Game/bootloader/xiloader.exe": Data("xiloader 2.1.1".utf8),
            "Game/config/boot/PegasusXI.ini": Data(profile.utf8), "Game/scripts/default.txt": Data("/load Addons\r\n".utf8),
            "Game/SquareEnix/FINAL FANTASY XI/FFXiMain.dll": main,
            "Game/SquareEnix/FINAL FANTASY XI/ROM/1/1.DAT": Data(repeating: 9, count: 50_000),
            "Game/SquareEnix/FINAL FANTASY XI/USER/1/acq.dat": Data("theirs".utf8),
            "Game/polplugins/DATs/PegasusXI-Enhancements/ROM/1/1.DAT": Data("enh 1".utf8),
            "Game/addons/fps/fps.lua": Data("-- fps".utf8),
            "prereqs/vcredist_x86.exe": Data("vc".utf8), "Game/PegasusXI Launcher.exe": Data("exe".utf8),
            "Game/LauncherLogs/launcher.log": Data("C:\\Users\\dev".utf8), "Game/pegasus-config.json": Data("{}".utf8),
            "README.txt": Data("readme".utf8)]
        let zip1 = release("1.2.4", v1)
        let dir1 = PegasusChannel.locateDirectory(tail: zip1.suffix(70_000), total: UInt64(zip1.count))
        let members1 = dir1.flatMap { PegasusChannel.parseDirectory(zip1.subdata(in: Int($0.offset)..<Int($0.offset + $0.size))) } ?? []
        check("zip: the directory found from the end, every file with its CRC-32 and size",
              members1.count == v1.count && members1.allSatisfy { m in
                  PegasusChannel.relative(m.path).flatMap { v1[$0] }.map { PegasusChannel.crc32($0) == m.crc && UInt64($0.count) == m.usize } == true })

        let ch = TestChannel()
        guard (try? ch.start()) != nil, ch.port != 0 else { print("  FAIL could not listen"); exit(1) }
        let site = "http://127.0.0.1:\(ch.port)"
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func publish(_ version: String, _ zip: Data) {
            ch.put("/launcher/PegasusXI_\(version).zip", zip, t0)
            ch.put("/launcher/pegasusxi-pack.json", Data(#"{"version":"\#(version)","zipUrl":"\#(site)/launcher/PegasusXI_\#(version).zip"}"#.utf8), t0)
        }
        publish("1.2.4", zip1)
        let src = PegasusChannel.Sources(index: site + "/launcher/pegasusxi-pack.json", zipPrefix: site + "/")
        let root = tmp.appendingPathComponent("PegasusXI")
        func sync(_ s: PegasusChannel.Sources = src, install: Bool = false, stop: StopFlag = StopFlag()) -> AscensionSync.Outcome {
            ch.clearLog()
            return PegasusSync(root: root, sources: s, stop: stop, log: { _ in }).run(install: install)
        }
        func file(_ rel: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(rel)) }
        func ranges() -> Int { ch.log.filter { $0.hasSuffix(" 206") }.count }

        let first = sync(install: true)
        check("install: succeeds", { if case .ok = first { return true }; return false }())
        check("install: the game, Ashita, loader, profile, overlay and addon in place, wrapper dropped",
              file("Game/SquareEnix/FINAL FANTASY XI/FFXiMain.dll") == main && file("Game/Ashita-cli.exe") == Data("cli".utf8)
                && file("Game/bootloader/xiloader.exe") != nil && file("Game/config/boot/PegasusXI.ini") == Data(profile.utf8)
                && file("Game/polplugins/DATs/PegasusXI-Enhancements/ROM/1/1.DAT") == Data("enh 1".utf8) && file("README.txt") != nil)
        check("install: their Windows-only files not installed",
              file("prereqs/vcredist_x86.exe") == nil && file("Game/PegasusXI Launcher.exe") == nil
                && file("Game/LauncherLogs/launcher.log") == nil && file("Game/pegasus-config.json") == nil)
        let st = (try? JSONSerialization.jsonObject(with: file(PegasusChannel.stateFile) ?? Data())) as? [String: Any]
        check("install: their own record, in their shape", st?["appliedVersion"] as? String == "1.2.4"
              && (st?["zipUrl"] as? String)?.hasSuffix("PegasusXI_1.2.4.zip") == true && st?["updatedAt"] != nil)
        check("install: read by Range, never the whole zip", ranges() >= 2 && !ch.log.contains("/launcher/PegasusXI_1.2.4.zip 200"))

        check("Play, nothing new: the index alone is asked for",
              sync() == .ok(changed: 0) && ch.log == ["/launcher/pegasusxi-pack.json 200"])

        // The player's own changes, a damaged game file, LuaJITGuard's lines: Repair.
        let mine = profile.replacingOccurrences(of: "--server play.pegasusxi.com", with: "--server play.pegasusxi.com --user me")
        try? Data(mine.utf8).write(to: root.appendingPathComponent("Game/config/boot/PegasusXI.ini"))
        try? Data("mine".utf8).write(to: root.appendingPathComponent("Game/SquareEnix/FINAL FANTASY XI/USER/1/acq.dat"))
        try? Data("broken".utf8).write(to: root.appendingPathComponent("Game/SquareEnix/FINAL FANTASY XI/FFXiMain.dll"))
        try? (Data(LuaJITGuard.shim.utf8) + Data("-- fps".utf8)).write(to: root.appendingPathComponent("Game/addons/fps/fps.lua"))
        let repair = sync(install: true)
        check("Repair: the damaged game file is fetched again, alone",
              repair == .ok(changed: 1) && file("Game/SquareEnix/FINAL FANTASY XI/FFXiMain.dll") == main)
        check("Repair: the player's profile and USER files are kept", file("Game/config/boot/PegasusXI.ini") == Data(mine.utf8)
              && file("Game/SquareEnix/FINAL FANTASY XI/USER/1/acq.dat") == Data("mine".utf8))
        check("Repair: an addon LuaJITGuard prefixed counts as intact",
              file("Game/addons/fps/fps.lua") == Data(LuaJITGuard.shim.utf8) + Data("-- fps".utf8))

        // Their next release (a ZIP64 this time): one DAT changed, one added, one removed, default.txt changed.
        v1["Game/SquareEnix/FINAL FANTASY XI/ROM/1/1.DAT"] = Data(repeating: 8, count: 50_000)
        v1["Game/polplugins/DATs/PegasusXI-Enhancements/ROM/1/2.DAT"] = Data("enh 2".utf8)
        v1["Game/polplugins/DATs/PegasusXI-Enhancements/ROM/1/1.DAT"] = nil
        v1["Game/scripts/default.txt"] = Data("/load Addons\r\n/load Screenshot\r\n".utf8)
        publish("1.2.5", release("1.2.5", v1, zip64: true))
        let update = sync()
        check("update: the changed and added files only, from the ZIP64",
              update == .ok(changed: 4) && file("Game/SquareEnix/FINAL FANTASY XI/ROM/1/1.DAT") == Data(repeating: 8, count: 50_000)
                && file("Game/polplugins/DATs/PegasusXI-Enhancements/ROM/1/2.DAT") == Data("enh 2".utf8))
        check("update: a file their release removed is removed (no stale overlay)",
              file("Game/polplugins/DATs/PegasusXI-Enhancements/ROM/1/1.DAT") == nil)
        check("update: a file of theirs the release changed is theirs again; the player's profile, unchanged upstream, stays",
              file("Game/scripts/default.txt") == Data("/load Addons\r\n/load Screenshot\r\n".utf8)
                && file("Game/config/boot/PegasusXI.ini") == Data(mine.utf8))
        check("update: their record moves to 1.2.5",
              ((try? JSONSerialization.jsonObject(with: file(PegasusChannel.stateFile) ?? Data())) as? [String: Any])?["appliedVersion"] as? String == "1.2.5")

        // A member damaged on the way: refused, the old file kept.
        v1["Game/SquareEnix/FINAL FANTASY XI/ROM/1/1.DAT"] = Data(repeating: 7, count: 50_000)
        var bad = release("1.2.6", v1)
        if let d = PegasusChannel.locateDirectory(tail: bad.suffix(70_000), total: UInt64(bad.count)),
           let m = PegasusChannel.parseDirectory(bad.subdata(in: Int(d.offset)..<Int(d.offset + d.size)))?.first(where: { $0.path.hasSuffix("ROM/1/1.DAT") }) {
            let at = Int(m.offset) + 30 + m.nameLength + 64
            bad[at] ^= 0xFF; bad[at + 1] ^= 0xFF
        }
        publish("1.2.6", bad)
        check("a damaged member is refused and the old file kept",
              { if case .failed(let why) = sync() { return why.contains("damaged") || why.contains("cut short") }; return false }()
                && file("Game/SquareEnix/FINAL FANTASY XI/ROM/1/1.DAT") == Data(repeating: 8, count: 50_000))
        publish("1.2.6", release("1.2.6", v1))
        check("the same release, intact: ok", { if case .ok = sync() { return true }; return false }())

        // Their next release renames a folder by letter case only: on the Mac's disk it is the same
        // folder, so the file in it is not one the release removed.
        v1["Game/bootloader/xiloader.exe"] = nil
        v1["Game/Bootloader/xiloader.exe"] = Data("xiloader 2.1.1".utf8)
        publish("1.2.7", release("1.2.7", v1))
        let recased = sync()
        check("update: a folder renamed only by letter case keeps its file on disk",
              { if case .ok = recased { return true }; return false }() && file("Game/Bootloader/xiloader.exe") == Data("xiloader 2.1.1".utf8))

        // Offline after a finished update plays; Stop stops; a zip off their CDN is refused.
        let down = PegasusChannel.Sources(index: "http://127.0.0.1:9/pack.json", zipPrefix: site + "/")
        check("offline after a finished update: play with what is there", { if case .offline = sync(down) { return true }; return false }())
        let flag = StopFlag(); flag.raise()
        check("stop: .stopped", sync(stop: flag) == .stopped)
        let elsewhere = PegasusChannel.Sources(index: src.index, zipPrefix: "https://cdn.pegasusxi.com/")
        check("an index naming a zip off their CDN is not followed",
              { if case .offline = sync(elsewhere) { return true }; return false }() && !ch.log.contains { $0.contains(".zip") })

        // The launcher around it.
        let w = Server.all.first { $0.name == PegasusChannel.worldName }
        check("built-in: PegasusXI, LandSandBoat, its kind, one client, their approved list, a website account",
              Server.builtins.contains { $0.name == PegasusChannel.worldName } && w?.codebase == .landSandBoat
                && w?.installKind == .pegasusPack && w?.installKind.updatesBeforePlay == true && w?.allowsMultipleClients == false
                && w.map { AddonPolicies.policy(for: $0).allows("luashitacast") && !AddonPolicies.policy(for: $0).allows("multisend") } == true
                && w?.accountURL == "https://pegasusxi.com/new_accounts/index.html")
        let enc = w.flatMap { try? JSONEncoder().encode([$0]) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("servers.json: its kind is stored as one older builds read", enc.contains("\"installKind\":\"website\""))
        check("failures read as their own text wherever they are caught (PegasusSync, FileDownload)",
              (PegasusSync.Failure(description: "PegasusXI: a.dat came down damaged.") as Error).localizedDescription == "PegasusXI: a.dat came down damaged."
                && (FileDownload.Failure(description: "HTTP 404 for x") as Error).localizedDescription == "HTTP 404 for x")

        // FileDownload (a client archive into its folder, resumed): TestChannel answers Range with 206
        // and Content-Range, 416 (without one) past the end, and 200 with Last-Modified.
        let blob = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &gen) })
        ch.put("/dl/client.archive", blob, t0)
        let dl = tmp.appendingPathComponent("dl/client.archive")
        let dlValidator = URL(fileURLWithPath: dl.path + ".validator")
        func fetchFile(_ url: String) -> Error? {
            guard let u = URL(string: url) else { return FileDownload.Failure(description: "bad URL") }
            do { try FileDownload.run(u, to: dl, stop: StopFlag()); return nil } catch { return error }
        }
        func saved() -> Data? { try? Data(contentsOf: dl) }
        func validator() -> String? { try? String(contentsOf: dlValidator, encoding: .utf8) }
        ch.clearLog()
        let fresh = fetchFile(site + "/dl/client.archive")
        check("FileDownload: a fresh copy whole, its Last-Modified kept beside it for If-Range",
              fresh == nil && saved() == blob && validator() == AscensionSync.httpDate(t0) && ch.log == ["/dl/client.archive 200"])
        try? blob.prefix(120_000).write(to: dl)
        ch.clearLog()
        let resumed = fetchFile(site + "/dl/client.archive")
        check("FileDownload: a resume onto a partial file gives the whole file, only the rest asked for, the validator kept",
              resumed == nil && saved() == blob && ch.log == ["/dl/client.archive 206"] && validator() == AscensionSync.httpDate(t0))
        try? (blob + Data("not theirs".utf8)).write(to: dl)
        let longer = fetchFile(site + "/dl/client.archive")
        let emptied = saved() == Data()
        let again = fetchFile(site + "/dl/client.archive")
        check("FileDownload: a file longer than theirs (416 without bytes */N) is emptied, and the next try fetches it whole",
              longer != nil && emptied && again == nil && saved() == blob)

        // Servers TestChannel does not play: one that ignores Range, one that answers from the wrong place.
        let other = ScriptedHTTPServer()
        guard (try? other.start()) != nil, other.port != 0 else { print("  FAIL could not listen"); exit(1) }
        let otherURL = "http://127.0.0.1:\(other.port)/client.archive"
        // A header of the first request since the last `answer`.
        func header(_ name: String) -> String? {
            (other.log.first ?? []).dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        let blob2 = Data(blob.reversed())
        try? blob.prefix(100_000).write(to: dl)
        try? Data("\"v1\"".utf8).write(to: dlValidator)
        other.answer { _ in ("200 OK", ["ETag: \"v2\""], blob2) }
        let restarted = fetchFile(otherURL)
        check("FileDownload: a resume asks If-Range with the copy's validator; a 200 to it restarts cleanly, the new ETag kept",
              header("Range") == "bytes=100000-" && header("If-Range") == "\"v1\""
                && restarted == nil && saved() == blob2 && validator() == "\"v2\"")
        try? blob.prefix(100_000).write(to: dl)
        other.answer { _ in ("206 Partial Content", ["Content-Range: bytes 0-\(blob.count - 1)/\(blob.count)"], blob) }
        let misplaced = fetchFile(otherURL)
        check("FileDownload: a 206 that does not continue where the file stopped is refused, the file emptied to start again",
              (misplaced as? FileDownload.Failure)?.description.contains("did not continue where it stopped") == true
                && saved() == Data() && validator() == nil)
        try? blob.write(to: dl)
        other.answer { _ in ("416 Range Not Satisfiable", ["Content-Range: bytes */\(blob.count)"], Data()) }
        let whole = fetchFile(otherURL)
        let wholeKept = saved() == blob
        try? (blob + Data("not theirs".utf8)).write(to: dl)
        let notWhole = fetchFile(otherURL)
        check("FileDownload: 416 means complete only when bytes */N is the size here",
              whole == nil && wholeKept && notWhole != nil && saved() == Data())
        other.stop()

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

    /// `--pegasus-sync [--install] [--root <folder>]`: the install or update the button runs, headless,
    /// printing every line. Never launches the game.
    @MainActor static func runPegasusSync(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)   // a line at a time, also into a file
        let store = ServerStore()
        var rootPath = store.servers.first { $0.name == PegasusChannel.worldName }?.dataPath ?? ""
        if let k = args.firstIndex(of: "--root"), k + 1 < args.count { rootPath = args[k + 1] }
        guard !rootPath.isEmpty else { FileHandle.standardError.write(Data("pass --root <folder>\n".utf8)); exit(2) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var last = -1
        let sync = PegasusSync(root: root, log: { print($0) }, progress: { label, f in
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

/// A fake server that answers every request as it is told, whatever it asks for: the servers
/// TestChannel never plays (one ignoring Range, one answering from the wrong place, a 416 with a
/// size). One request per connection; each request's header lines are kept.
final class ScriptedHTTPServer: @unchecked Sendable {
    typealias Reply = (status: String, headers: [String], body: Data)
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pegasus-selftest-scripted")
    private let lock = NSLock()
    private var reply: ([String]) -> Reply = { _ in ("404 Not Found", [], Data()) }
    private var requests: [[String]] = []

    /// The header lines of every request since the last `answer` (the request line first).
    var log: [[String]] { lock.lock(); defer { lock.unlock() }; return requests }
    /// How the next requests are answered, given each one's header lines.
    func answer(_ f: @escaping ([String]) -> Reply) { lock.lock(); reply = f; requests = []; lock.unlock() }

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
                let lines = String(decoding: b[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                self.lock.lock(); self.requests.append(lines); let f = self.reply; self.lock.unlock()
                let r = f(lines)
                let extra = r.headers.map { $0 + "\r\n" }.joined()
                let head = "HTTP/1.1 \(r.status)\r\nContent-Length: \(r.body.count)\r\n\(extra)Connection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { _ in c.cancel() })
            } else if done || err != nil {
                c.cancel()
            } else {
                self.read(c, b)
            }
        }
    }
}
