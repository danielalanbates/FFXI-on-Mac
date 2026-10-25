import CryptoKit
import Foundation

/// Scythe (212.28.177.210, LandSandBoat): their signed client release, their pinned Ashita and loader,
/// the way their launcher (Scythe Launcher 3.0.39, .NET, read with ILSpy) keeps them, natively. The
/// research, with file:line citations into their code, is in docs/SCYTHE.md.
///
///  * **The release**: `/launcher/channel/current.json`, `{"release": {...}, "signature": "..."}`, signed
///    ECDSA P-256 / SHA-256 (64-byte r||s, Base64) over the `release` object serialized the .NET way
///    (top level, 2-space indent, CRLF). That is the received object re-indented one level, which is
///    what `signedBytes` builds; it reproduces their 740 bytes exactly.
///  * **The client**: `/launcher/client/releases/<releaseId without -rN>/manifest.json` lists every
///    file (path, length, SHA-256). It is not signed itself: it must hash to the release's signed
///    `target` (`treeHash`). Each file is kept when it already hashes right, copied from another
///    client on this Mac that has it byte for byte (their "seeds"), else fetched from
///    `/launcher/client/objects/<aa>/<sha>`. Of 30260429_1's 65,062 files, 63,808 are byte-identical
///    to retail 30260904_1 (2026-10-24): about 0.9 GB comes from Scythe.
///  * **The runtime**: their Ashita v4.3.1.1 zip (SHA-256 pinned in their launcher) and LandSandBoat
///    xiloader v1.1.5 (the file their launcher embeds), `config/boot/scythe.ini` as their launcher writes
///    it. Two differences: the sandbox polplugin is off (`sandbox = 0`; this launcher points the
///    registry at the client for every world instead of `[sandbox.paths]`), and `script = scythe.txt`
///    loads Ashita's thirdparty, addons and screenshot plugins (theirs names no script).
///
/// Newer retail files their release does not have are left out of a fresh client. On an update, a
/// file the previous release had and this one does not is removed (they keep it under TEMP).
enum ScytheChannel {
    static let worldName = "Scythe"
    static let host = "212.28.177.210"
    static let base = "https://212-28-177-210.sslip.io"
    static let bootProfile = "scythe.ini"
    static let scriptName = "scythe.txt"
    /// Their release key (`scythe-release-public-key.pem`, P-256).
    static let publicKeyX = "35F108E14C1FB374C98FA61C29AF6EF0EE5FC3CED69D4F3C46BE9600631D9F71"
    static let publicKeyY = "7A0FCF6EEEB69701BB3C4884A72FFE160501F8331CD742E184262870C5C58CFE"
    /// `ScytheRuntimeProfile.cs`: Ashita-v4beta at 7f4133d ("Ashita v4.3.1.1 Release").
    static let ashitaVersion = "4.3.1.1"
    static let ashitaSHA = "c9f5eddbfbad14c851160880293f8b49025aefe6decb080631543edbb544c8bb"
    static let loader = RetailWorld.Loader.release("1.1.5", "fe869337d3301280b5d5cd21ad9280033d8f99dca1e3830929f9f819062faa50")

    struct Sources {
        var base = ScytheChannel.base
        var ashitaZip = ScytheChannel.base + "/launcher/runtime/ashita-v\(ScytheChannel.ashitaVersion)-\(ScytheChannel.ashitaSHA).zip"
        var ashitaSHA = ScytheChannel.ashitaSHA
        var loader = ScytheChannel.loader
        var publicKey: P256.Signing.PublicKey? = ScytheChannel.releaseKey
        var channel: String { base + "/launcher/channel/current.json" }
        func manifest(_ id: String) -> String { base + "/launcher/client/releases/\(id)/manifest.json" }
        func object(_ sha: String) -> String { base + "/launcher/client/objects/\(sha.prefix(2))/\(sha)" }
    }

    static var releaseKey: P256.Signing.PublicKey? {
        guard let x = hex(publicKeyX), let y = hex(publicKeyY) else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
    }

    static func hex(_ s: String) -> Data? {
        var d = Data(), i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        return d
    }

    struct Release: Equatable {
        var releaseId: String
        var clientVersion: String
        var targetCount: Int
        var targetBytes: Int64
        var targetSHA: String
        /// The manifest's folder: the release id without its `-r<n>` revision.
        var manifestId: String {
            guard let r = releaseId.range(of: #"-r[1-9]\d*$"#, options: .regularExpression) else { return releaseId }
            return String(releaseId[..<r.lowerBound])
        }
    }

    /// The bytes their signature covers: the received `release` object, re-indented to top level with
    /// CRLF line ends (their launcher re-serializes it with System.Text.Json; the server writes it the
    /// same way, one level deeper).
    static func signedBytes(_ raw: Data) -> Data? {
        guard let text = String(data: raw, encoding: .utf8), let key = text.range(of: "\"release\": ") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = key.upperBound, end: String.Index?
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { end = i; break } }
            i = text.index(after: i)
        }
        guard let end, text[key.upperBound] == "{" else { return nil }
        let lines = String(text[key.upperBound...end]).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let out = [lines[0]] + lines.dropFirst().map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }
        return Data(out.joined(separator: "\r\n").utf8)
    }

    /// The release, when `raw` carries a valid signature by `key` and the fields their launcher checks.
    static func verify(_ raw: Data, key: P256.Signing.PublicKey?) -> Release? {
        guard let key, let signed = signedBytes(raw),
              let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let sigText = o["signature"] as? String, let sig = Data(base64Encoded: sigText), sig.count == 64,
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: sig),
              key.isValidSignature(ecdsa, for: signed),
              let r = o["release"] as? [String: Any], (r["schemaVersion"] as? NSNumber)?.intValue == 1,
              let id = r["releaseId"] as? String, id.range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil,
              let cv = r["clientVersion"] as? String,
              let t = r["target"] as? [String: Any], let tc = (t["fileCount"] as? NSNumber)?.intValue,
              let tb = (t["bytes"] as? NSNumber)?.int64Value, let ts = t["sha256"] as? String else { return nil }
        return Release(releaseId: id, clientVersion: cv, targetCount: tc, targetBytes: tb, targetSHA: ts.uppercased())
    }

    struct Manifest { var releaseId: String; var clientVersion: String; var files: [DriftwoodChannel.ClientFile] }

    static func parseManifest(_ d: Data) -> Manifest? {
        let body = d.starts(with: [0xEF, 0xBB, 0xBF]) ? d.dropFirst(3) : d
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = o["releaseId"] as? String, let cv = o["clientVersion"] as? String, let fs = o["files"] as? [Any] else { return nil }
        var files: [DriftwoodChannel.ClientFile] = []
        for raw in fs {
            guard let f = raw as? [String: Any], let p = f["path"] as? String, let n = (f["length"] as? NSNumber)?.int64Value,
                  let h = f["sha256"] as? String, AscensionSync.safeRelative(p) else { return nil }
            files.append(.init(path: p, size: n, sha256: h.lowercased()))
        }
        return Manifest(releaseId: id, clientVersion: cv, files: files)
    }

    /// Their tree identity (`ClientMatchTreeSnapshot`): SHA-256 of "scythe-client-tree-v1\n" then, per
    /// file in Windows order (case-insensitive on the backslash form), "path\0length\0SHA\n" (upper hex).
    static func treeHash(_ files: [DriftwoodChannel.ClientFile]) -> String {
        let sorted = files.sorted { $0.path.replacingOccurrences(of: "/", with: "\\").uppercased() < $1.path.replacingOccurrences(of: "/", with: "\\").uppercased() }
        var text = "scythe-client-tree-v1\n"
        for f in sorted { text += "\(f.path)\u{0}\(f.size)\u{0}\(f.sha256.uppercased())\n" }
        return AscensionChannel.sha256(Data(text.utf8)).uppercased()
    }

    /// `AshitaProfileBuilder.cs`, with the two differences in the type's notes.
    static let profileText = """
    [ashita.launcher]
    autoclose = 1
    name = Scythe

    [ashita.boot]
    file = .\\bootloader\\xiloader.exe
    command = --server \(host)
    gamemodule = FFXiMain.dll
    script = \(scriptName)

    [ashita.language]
    playonline = 2
    ashita = 2

    [ashita.logging]
    crashdumps = 1
    level = 4

    [ashita.polplugins]
    sandbox = 0

    [ashita.resources]
    offsets.use_overrides = 0
    pointers.use_overrides = 0
    resources.use_overrides = 0

    [ffxi.registry]
    padexsin000 = -1
    padguid000 = -1
    padmode000 = -1
    padsin000 = -1

    [ashita.misc]
    aliases.silent=0
    plugins.silent=0

    """

    static let scriptText = """
    # Scythe startup script, written by FFXI on Mac. Addons… switches addons on and off.
    /load thirdparty
    /load addons
    /load screenshot

    # The wait is required: without it, addons do not see the commands below.
    /wait 3
    /bind insert /ashita
    /bind SYSRQ /screenshot hide

    """
}

final class ScytheSync: @unchecked Sendable {
    typealias Outcome = AscensionSync.Outcome
    struct Failure: Error, CustomStringConvertible { let description: String }

    let root: URL
    private let src: ScytheChannel.Sources
    private let stop: StopFlag
    private let log: (String) -> Void
    private let progress: (String, Double) -> Void
    private let session: URLSession
    private let fm = FileManager.default
    private let hashes: HashCache
    private var changed = 0
    private var ashita: URL { root.appendingPathComponent("Ashita") }
    private var stateDir: URL { root.appendingPathComponent(".ffxi-on-mac") }
    private var stateURL: URL { stateDir.appendingPathComponent("scythe.json") }
    private lazy var client = RetailClient(game: root.appendingPathComponent("Game"), world: ScytheChannel.worldName, hashes: hashes,
                                           stop: stop, log: log, progress: progress)

    init(root: URL, sources: ScytheChannel.Sources = .init(), stop: StopFlag = StopFlag(),
         log: @escaping (String) -> Void, progress: @escaping (String, Double) -> Void = { _, _ in }) {
        self.root = root; src = sources; self.stop = stop; self.log = log; self.progress = progress
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "FFXI-on-Mac (Scythe client)", "Cache-Control": "no-cache, no-store"]
        session = URLSession(configuration: c)
        hashes = HashCache(url: root.appendingPathComponent(".ffxi-on-mac/hashes.json"))
    }

    func run(install: Bool = false, donors: [URL] = []) -> Outcome {
        defer { hashes.save() }
        hashes.trustStamps = !install
        var outcome: Outcome
        do { outcome = try steps(install: install, donors: donors) }
        catch let f as Failure { outcome = .failed(f.description) }
        catch let f as RetailClient.Failure { outcome = .failed(f.description) }
        catch { outcome = .failed("Scythe update failed: \(error.localizedDescription)") }
        return stop.raised ? .stopped : outcome
    }

    private func checkStop() throws {
        if stop.raised { throw Failure(description: "Stopped. Press the button again to carry on; nothing finished is lost.") }
    }
    private func readState() -> [String: Any] {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    private func writeState(_ m: [String: Any]) {
        var s = readState(); for (k, v) in m { s[k] = v }
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: stateURL, options: .atomic) }
    }
    var installedBefore: Bool { fm.fileExists(atPath: ashita.appendingPathComponent("Ashita-cli.exe").path) && readState()["finished"] as? Bool == true }

    private func steps(install: Bool, donors: [URL]) throws -> Outcome {
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        guard let raw = try? get(src.channel) else {
            try checkStop()
            if installedBefore { return .offline("Scythe's release channel didn't load; playing with the files from the last update.") }
            throw Failure(description: "Scythe's release channel (212-28-177-210.sslip.io) didn't load. Try again in a few minutes.")
        }
        guard let release = ScytheChannel.verify(raw, key: src.publicKey) else {
            throw Failure(description: "Scythe's release is not signed by Scythe's key (or not in the shape their launcher reads). Nothing was changed.")
        }
        let state = readState()
        let clientCurrent = state["release"] as? String == release.releaseId && state["finished"] as? Bool == true && client.present
        writeState(["finished": false])
        // 1. The client, when the release changed, on Setup/Repair, or when it is not there.
        if install || !clientCurrent {
            let copy = stateDir.appendingPathComponent("manifest-\(release.manifestId).json")
            var data = try? Data(contentsOf: copy)
            if data.flatMap(ScytheChannel.parseManifest).map({ ScytheChannel.treeHash($0.files) }) != release.targetSHA {
                log("==> Scythe \(release.releaseId): reading the release's file list")
                data = try get(src.manifest(release.manifestId))
            }
            guard let data, let m = ScytheChannel.parseManifest(data) else { throw Failure(description: "Scythe's file list could not be read.") }
            // Bound to the signed release: their launcher's AuthorizeManifest.
            guard m.releaseId == release.manifestId, m.clientVersion == release.clientVersion, m.files.count == release.targetCount,
                  m.files.reduce(Int64(0), { $0 + $1.size }) == release.targetBytes, ScytheChannel.treeHash(m.files) == release.targetSHA else {
                throw Failure(description: "Scythe's file list does not match their signed release. Nothing was changed.")
            }
            try data.write(to: copy, options: .atomic)
            try client.assemble(m.files, donors: donors, build: m.clientVersion, mayDiffer: []) { f, dest in
                try self.fetchObject(f, to: dest)
            }
            try removeDropped(now: m.files, previous: state["manifest"] as? String)
            writeState(["release": release.releaseId, "manifest": copy.lastPathComponent, "clientVersion": m.clientVersion])
        }
        try client.ensureViewer(donors: donors)
        try checkStop()
        // 2. Their Ashita, 3. their loader.
        if install || !fm.fileExists(atPath: ashita.appendingPathComponent("Ashita-cli.exe").path) || state["ashita"] as? String != src.ashitaSHA {
            try installAshita()
            writeState(["ashita": src.ashitaSHA])
        }
        let loaderFile = ashita.appendingPathComponent("bootloader/xiloader.exe")
        if AscensionChannel.sha256(of: loaderFile) != src.loader.sha256 {
            log("==> Scythe: LandSandBoat xiloader v\(src.loader.version) (the one their launcher carries)")
            try download(src.loader.url, to: loaderFile, sha: src.loader.sha256)
            changed += 1
        }
        // 4. Profile and script, only when missing.
        let ini = ashita.appendingPathComponent("config/boot/\(ScytheChannel.bootProfile)")
        if !fm.fileExists(atPath: ini.path) {
            try fm.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ScytheChannel.profileText.replacingOccurrences(of: "\n", with: "\r\n").write(to: ini, atomically: true, encoding: .utf8)
        }
        let script = ashita.appendingPathComponent("scripts/\(ScytheChannel.scriptName)")
        if !fm.fileExists(atPath: script.path) {
            try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ScytheChannel.scriptText.replacingOccurrences(of: "\n", with: "\r\n").write(to: script, atomically: true, encoding: .utf8)
        }
        try checkStop()
        writeState(["finished": true, "updated": ISO8601DateFormatter().string(from: Date())])
        return .ok(changed: changed + client.changed)
    }

    /// One object of theirs into `dest`: three tries, length and SHA-256 checked.
    private func fetchObject(_ f: DriftwoodChannel.ClientFile, to dest: URL) throws {
        var last: Error?
        for attempt in 1...3 {
            try checkStop()
            do { try download(src.object(f.sha256.lowercased()), to: dest, sha: f.sha256.lowercased()); return }
            catch { last = error; Thread.sleep(forTimeInterval: Double(attempt)) }
        }
        throw last ?? Failure(description: "\(f.path) didn't download.")
    }

    /// Files the previous release listed and this one does not, still as that release had them.
    private func removeDropped(now: [DriftwoodChannel.ClientFile], previous: String?) throws {
        guard let previous, let d = try? Data(contentsOf: stateDir.appendingPathComponent(previous)),
              let old = ScytheChannel.parseManifest(d) else { return }
        let keep = Set(now.map { $0.path.lowercased() })
        let ffxi = client.game.appendingPathComponent("FINAL FANTASY XI")
        var n = 0
        for f in old.files where !keep.contains(f.path.lowercased()) {
            let u = ffxi.appendingPathComponent(f.path)
            guard AscensionChannel.sha256(of: u) == f.sha256 else { continue }
            try? fm.removeItem(at: u); n += 1
        }
        if n > 0 { log("==> Scythe: \(n) files their new release dropped, removed") }
    }

    private func installAshita() throws {
        log("==> Scythe: Ashita v\(ScytheChannel.ashitaVersion) (their pinned runtime)")
        let tmp = stateDir.appendingPathComponent("tmp/ashita-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("ashita.zip")
        try download(src.ashitaZip, to: zip, sha: src.ashitaSHA)
        let out = tmp.appendingPathComponent("x")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(description: "Scythe's Ashita could not be unpacked (ditto \(p.terminationStatus)).") }
        let tops = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard tops.count == 1, let top = tops.first, fm.fileExists(atPath: top.appendingPathComponent("Ashita-cli.exe").path) else {
            throw Failure(description: "Scythe's Ashita did not hold Ashita-cli.exe where expected.")
        }
        guard let walk = fm.enumerator(atPath: top.path) else { return }
        for case let rel as String in walk {
            let from = top.appendingPathComponent(rel), to = ashita.appendingPathComponent(rel)
            guard AscensionSync.isRegularFile(from) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.moveItem(at: from, to: to)
        }
        changed += 1
    }

    // MARK: - HTTP

    /// GET `s`; a redirect is refused (their launcher sets AllowAutoRedirect = false).
    private func get(_ s: String) throws -> Data {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Data, Error> = .failure(Failure(description: "no answer from \(s)"))
        let task = session.dataTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)) { d, r, e in
            defer { sem.signal() }
            if let e { out = .failure(e); return }
            guard let h = r as? HTTPURLResponse else { return }
            guard h.url == u else { out = .failure(Failure(description: "\(s) redirected; refused")); return }
            guard (200...299).contains(h.statusCode) else { out = .failure(Failure(description: "HTTP \(h.statusCode) for \(s)")); return }
            out = .success(d ?? Data())
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        return try out.get()
    }

    private func download(_ s: String, to dest: URL, sha: String) throws {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = session.downloadTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)) { t, r, e in
            defer { sem.signal() }
            if let e { failure = e; return }
            guard let h = r as? HTTPURLResponse, (200...299).contains(h.statusCode), let t else {
                failure = Failure(description: "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0) for \(u.lastPathComponent)"); return
            }
            try? FileManager.default.removeItem(at: part)
            do { try FileManager.default.moveItem(at: t, to: part) } catch { failure = error }
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        if let failure { try? fm.removeItem(at: part); throw failure }
        guard AscensionChannel.sha256(of: part) == sha else {
            try? fm.removeItem(at: part)
            throw Failure(description: "\(u.lastPathComponent) came down damaged.")
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }
}
