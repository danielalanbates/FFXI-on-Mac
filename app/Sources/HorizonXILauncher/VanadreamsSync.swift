import Foundation

/// Vanadreams (fairywitch.ca; login `vanadreams.online`, LandSandBoat, xiloader 2.2.x): its client,
/// Ashita and loader, put together the way their own launcher does it, natively.
///
/// Their launcher is open source (github.com/VanaDreams/vanadreams-ashita, a WPF app); everything
/// here was read from it on 2026-10-24 (`SetupPage.xaml.cs`, `Services/ClientInstall.cs`,
/// `Loader.cs`, `LoaderCommand.cs`, `Profile.cs`, `PivotConfig.cs`, `LookOverlays.cs`, `Effects.cs`):
///
///  1. **Ashita v4** from AshitaXI/Ashita-v4beta (they take `main`; pinned here to the commit `main`
///     was on that day), unpacked into the game folder with the archive's top folder dropped.
///  2. **xiloader v2.2.0** from LandSandBoat's releases into `bootloader/`. Their server checks the
///     loader's major.minor exactly ("Your xiloader is too old" for anything else, newer included),
///     so the version is pinned, as theirs is.
///  3. **XIPivot 4.3.001** (their launcher carries it; here from HealsCodes' own release).
///  4. **The client**: `vanadreams.org/download/client/<client_ver>/manifest.json` (client_ver from their
///     public status API) lists zips, each with a SHA-256 and a destination folder: `FINAL FANTASY XI`
///     and `PlayOnlineViewer` under the game folder, `{ashita}/…` under Ashita's (here the same
///     folder, as their defaults are). Each zip is downloaded, checked, unpacked and deleted, and a
///     line `<client_ver> <zip> <sha256>` is added to `.vanadreams-client.txt`, their own record, so a
///     stopped install carries on and a zip they add later is fetched by the next update.
///  5. **Profile** `config/boot/vanadreams.ini` from Ashita's `example-privateserver.ini`:
///     `file = .\bootloader\xiloader.exe`, `command = --server vanadreams.online`,
///     `script = vanadreams.txt`. An old `--server` they have moved from is pointed at the new one.
///  6. **pivot.ini**: their title and look packs as overlays (title first), no `root_path` (theirs
///     removes it: XIPivot's default is this client's own `polplugins/DATs`).
///
/// One Mac difference: the "modern look" effects they unpack beside the loader (crosire's d3d8to9 as
/// `d3d8.dll` and ReShade as `d3d9.dll`) would load ahead of this launcher's DXVK renderer, so they
/// are put in their own "low spec" state, renamed `.off`, exactly as their launcher's Low spec setting
/// does (`Effects.Apply`). The look and title DAT packs themselves stay on.
enum VanadreamsChannel {
    static let worldName = "Vanadreams"
    static let host = "vanadreams.online"
    /// Addresses the server has moved from (their catalogue's `servers.moved`, 2026-10-24).
    static let movedHosts = ["vanadreams.fairywitch.ca": "vanadreams.online"]
    static let bootProfile = "vanadreams.ini"
    static let scriptName = "vanadreams.txt"
    static let recordName = ".vanadreams-client.txt"
    static let statusURL = "https://vanadreams.org/api/public/vanadreams/status"
    static let clientBase = "https://vanadreams.org/download/client/"
    /// What their status API said on 2026-10-24, for when it does not answer.
    static let knownClientVersion = "30260904_1"
    static let ashitaCommit = "4171c74c8ddb2ca2a31654f199e6c1cee40d7256"
    static var ashitaZipURL: String { "https://codeload.github.com/AshitaXI/Ashita-v4beta/zip/\(ashitaCommit)" }
    static let loaderURL = "https://github.com/LandSandBoat/xiloader/releases/download/v2.2.0/xiloader.exe"
    static let loaderSHA = "aec6c0686cf3b2fe65247b818fe44f89fb18fc175e8ebd3ba3b7cf099988f504"
    static let pivotURL = "https://github.com/HealsCodes/XIPivot/releases/download/v4.3.001/XIPivot_Ashita_v4_4.3.001.zip"
    static let pivotSHA = "67cc4d082c863adf5005a77730b8a346471d792104cd15f87608f78477acfd73"
    /// Their overlays, in pivot.ini order: the title pack first (`LookOverlays.GiveOnce`).
    static let overlays = ["vanadreams-title", "vanadreams-looks"]
    static let effectWrappers = ["d3d8.dll", "d3d9.dll"]

    /// Where each download comes from; swapped for a local channel by --selftest-vanadreams.
    struct Sources {
        var status = VanadreamsChannel.statusURL
        var clientBase = VanadreamsChannel.clientBase
        var ashitaZip = VanadreamsChannel.ashitaZipURL
        var loader = VanadreamsChannel.loaderURL
        var loaderSHA = VanadreamsChannel.loaderSHA
        var pivot = VanadreamsChannel.pivotURL
        var pivotSHA = VanadreamsChannel.pivotSHA
    }

    struct Chunk: Equatable {
        var name: String, size: Int64, sha256: String, dest: String, unpacked: Int64
        var key: String { "\(name) \(sha256)" }
    }

    struct Manifest {
        var version: String
        var createDirs: [String], viewerCreateDirs: [String]
        var chunks: [Chunk]
        var totalSize: Int64 { chunks.reduce(0) { $0 + $1.size } }
    }

    static func parseManifest(_ d: Data) -> Manifest? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let v = o["client_ver"] as? String, !v.isEmpty else { return nil }
        func strings(_ k: String) -> [String] { ((o[k] as? [Any]) ?? []).compactMap { $0 as? String } }
        var chunks: [Chunk] = []
        for raw in (o["chunks"] as? [Any]) ?? [] {
            guard let c = raw as? [String: Any], let name = c["name"] as? String, !name.isEmpty,
                  let sha = c["sha256"] as? String else { continue }
            chunks.append(Chunk(name: name, size: (c["size"] as? NSNumber)?.int64Value ?? 0, sha256: sha.lowercased(),
                                dest: (c["dest"] as? String) ?? "FINAL FANTASY XI",
                                unpacked: (c["unpacked"] as? NSNumber)?.int64Value ?? 0))
        }
        guard !chunks.isEmpty else { return nil }
        return Manifest(version: v, createDirs: strings("create_dirs"), viewerCreateDirs: strings("viewer_create_dirs"), chunks: chunks)
    }

    /// The folder a chunk unpacks into, or nil when its destination would leave the game folder.
    /// `{ashita}` is the game folder itself here (their defaults put Ashita and the client together).
    static func destFolder(_ c: Chunk, root: URL) -> URL? {
        var d = c.dest.replacingOccurrences(of: "\\", with: "/")
        if d.lowercased().hasPrefix("{ashita}") { d = String(d.dropFirst("{ashita}".count)) }
        let parts = d.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.contains(":") }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// `<client_ver> <zip> <sha256>` lines already unpacked here, as "zip sha256".
    static func done(in root: URL, version: String) -> Set<String> {
        guard let text = try? String(contentsOf: root.appendingPathComponent(recordName), encoding: .utf8) else { return [] }
        var out = Set<String>()
        for line in TextFile.lines(of: text) {
            let f = line.split(separator: " ").map(String.init)
            if f.count >= 3, f[0] == version { out.insert(f[1] + " " + f[2]) }
        }
        return out
    }

    /// The boot profile their Setup writes, from Ashita's own example.
    static func profile(fromExample example: String) -> String {
        var t = example
        for s in [BootProfile.Setting(section: "ashita.launcher", key: "name", value: "Vanadreams"),
                  BootProfile.Setting(section: "ashita.boot", key: "file", value: ".\\\\bootloader\\\\xiloader.exe"),
                  BootProfile.Setting(section: "ashita.boot", key: "command", value: "--server \(host)"),
                  BootProfile.Setting(section: "ashita.boot", key: "script", value: scriptName),
                  BootProfile.Setting(section: "ashita.polplugins", key: "pivot", value: "1")] {
            t = BootProfile.setting(s, in: t)
        }
        return t
    }

    /// `command` with a `--server` they have moved from pointed at where they are now, or nil.
    static func repointed(_ command: String) -> String? {
        var t = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let k = t.firstIndex(where: { $0.lowercased() == "--server" }), k + 1 < t.count,
              let to = movedHosts.first(where: { $0.key.caseInsensitiveCompare(t[k + 1]) == .orderedSame })?.value else { return nil }
        t[k + 1] = to
        return t.joined(separator: " ")
    }

    /// The script their Setup starts a player with (`ScriptWriter.Build` with nothing ticked), less the
    /// graphics `/exec` that only their launcher writes.
    static let scriptText = """
    # Vanadreams startup script. Written by FFXI on Mac in the shape Vanadreams' own launcher writes.
    # Turn addons on and off with Addons…; write your own lines under the marker at the end.

    /load thirdparty
    /load addons

    # The wait is required: without it, addons do not see the commands below.
    /wait 3

    # --- yours ---
    # Anything below this line is kept exactly as you wrote it.

    """

    /// pivot.ini with their overlays listed (title first) and no `root_path`, every other line kept.
    static func pivot(_ existing: String?, present: [String]) -> String {
        var kept: [String] = [], listed: [String] = [], inOverlays = false, seenSettings = false
        for raw in TextFile.lines(of: existing ?? "") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                inOverlays = t.lowercased() == "[overlays]"
                if t.lowercased() == "[settings]" { seenSettings = true }
                if inOverlays { continue }
            }
            if inOverlays {
                if let eq = t.firstIndex(of: "=") {
                    let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { listed.append(v) }
                }
                continue
            }
            if t.lowercased().hasPrefix("root_path") { continue }
            kept.append(raw)
        }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        // Appended, in their order, as their `PivotConfig.AddOverlay` does: an overlay already listed keeps its place.
        for o in overlays where present.contains(o) && !listed.contains(where: { $0.caseInsensitiveCompare(o) == .orderedSame }) {
            listed.append(o)
        }
        var out = seenSettings ? kept : ["[settings]", "debug_log = false"] + kept
        out.append("")
        out.append("[overlays]")
        for (n, o) in listed.enumerated() { out.append("\(n) = \(o)") }
        return out.joined(separator: "\r\n") + "\r\n"
    }
}

/// One Vanadreams install or Play-time update, off the main actor. Same outcomes as AscensionSync.
final class VanadreamsSync: @unchecked Sendable {
    typealias Outcome = AscensionSync.Outcome
    struct Failure: Error, CustomStringConvertible { let description: String }

    let root: URL
    private let src: VanadreamsChannel.Sources
    private let stop: StopFlag
    private let log: (String) -> Void
    private let progress: (String, Double) -> Void
    private let session: URLSession
    private let fm = FileManager.default
    private var changed = 0
    private var stateDir: URL { root.appendingPathComponent(".ffxi-on-mac") }
    private var stateURL: URL { stateDir.appendingPathComponent("vanadreams.json") }

    init(root: URL, sources: VanadreamsChannel.Sources = .init(), stop: StopFlag = StopFlag(),
         log: @escaping (String) -> Void, progress: @escaping (String, Double) -> Void = { _, _ in }) {
        self.root = root; src = sources; self.stop = stop; self.log = log; self.progress = progress
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 6 * 3600
        c.httpAdditionalHeaders = ["User-Agent": "FFXI-on-Mac (Vanadreams client)"]
        session = URLSession(configuration: c)
    }

    func run(install: Bool = false) -> Outcome {
        var outcome: Outcome
        do { outcome = try steps(install: install) }
        catch let f as Failure { outcome = .failed(f.description) }
        catch { outcome = .failed("Vanadreams update failed: \(error.localizedDescription)") }
        return stop.raised ? .stopped : outcome
    }

    private func checkStop() throws {
        if stop.raised { throw Failure(description: "Stopped. Press the button again to carry on; nothing finished is lost.") }
    }

    var installedBefore: Bool {
        fm.fileExists(atPath: root.appendingPathComponent("Ashita-cli.exe").path)
            && fm.fileExists(atPath: root.appendingPathComponent(VanadreamsChannel.recordName).path)
    }
    private var lastUpdateFinished: Bool { readState()["finished"] as? Bool == true }

    private func steps(install: Bool) throws -> Outcome {
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // 0. Which client: their status API, the version their own launcher installs.
        let status = try? getJSON(src.status)
        if status == nil {
            try checkStop()
            if installedBefore, lastUpdateFinished { return .offline("Vanadreams' site didn't answer; playing with the files from the last update.") }
        }
        let version = (status?["client_ver"] as? String).flatMap { $0.range(of: #"^3\d{7}_\d+$"#, options: .regularExpression) != nil ? $0 : nil }
            ?? VanadreamsChannel.knownClientVersion
        guard let mData = try? get(src.clientBase + version + "/manifest.json"),
              let manifest = VanadreamsChannel.parseManifest(mData) else {
            try checkStop()
            if installedBefore, lastUpdateFinished { return .offline("Vanadreams' download list didn't load; playing with the files from the last update.") }
            throw Failure(description: "Vanadreams' download list (client \(version)) could not be read. Try again in a few minutes.")
        }
        writeState(["finished": false])
        // 1. Ashita.
        if install || !fm.fileExists(atPath: root.appendingPathComponent("Ashita-cli.exe").path) {
            try installAshita()
        }
        try checkStop()
        // 2. The loader the server takes, and 3. XIPivot.
        try ensureFile(src.loader, sha: src.loaderSHA, at: root.appendingPathComponent("bootloader/xiloader.exe"), label: "xiloader v2.2.0")
        try ensurePivot()
        try checkStop()
        // 4. The client.
        let done = VanadreamsChannel.done(in: root, version: manifest.version)
        let todo = manifest.chunks.filter { !done.contains($0.key) }
        if !todo.isEmpty {
            let mb = Double(todo.reduce(Int64(0)) { $0 + $1.size }) / 1_048_576
            log("==> Vanadreams: \(todo.count) of \(manifest.chunks.count) client packages to fetch (\(String(format: "%.0f", mb)) MB), client \(manifest.version)")
        }
        var fetched: Int64 = 0
        let total = max(todo.reduce(Int64(0)) { $0 + $1.size }, 1)
        for c in todo {
            try checkStop()
            guard let dest = VanadreamsChannel.destFolder(c, root: root) else {
                throw Failure(description: "Vanadreams' download list names a folder outside the game: \(c.dest)")
            }
            try installChunk(c, version: manifest.version, into: dest) { f in
                self.progress("Downloading Vanadreams", (Double(fetched) + f * Double(c.size)) / Double(total))
            }
            fetched += c.size
            changed += 1
        }
        for d in manifest.createDirs { try? fm.createDirectory(at: root.appendingPathComponent("FINAL FANTASY XI/\(d)"), withIntermediateDirectories: true) }
        for d in manifest.viewerCreateDirs { try? fm.createDirectory(at: root.appendingPathComponent("PlayOnlineViewer/\(d)"), withIntermediateDirectories: true) }
        // Their effects off on the Mac (see the type's notes).
        for w in VanadreamsChannel.effectWrappers {
            let on = root.appendingPathComponent("bootloader/\(w)"), off = root.appendingPathComponent("bootloader/\(w).off")
            guard AscensionSync.isRegularFile(on) else { continue }
            try? fm.removeItem(at: off)
            if (try? fm.moveItem(at: on, to: off)) != nil { log("i  Vanadreams: \(w) beside the loader switched off (their Low spec), so the Mac renderer is used") }
        }
        try checkStop()
        // 5. Profile and script, 6. pivot.ini.
        try writeProfile()
        let script = root.appendingPathComponent("scripts/\(VanadreamsChannel.scriptName)")
        if !fm.fileExists(atPath: script.path) {
            try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try VanadreamsChannel.scriptText.replacingOccurrences(of: "\n", with: "\r\n").write(to: script, atomically: true, encoding: .utf8)
        }
        let present = VanadreamsChannel.overlays.filter { fm.fileExists(atPath: root.appendingPathComponent("polplugins/DATs/\($0)").path) }
        let pivotFile = root.appendingPathComponent("config/pivot/pivot.ini")
        let old = try? String(contentsOf: pivotFile, encoding: .utf8)
        let newPivot = VanadreamsChannel.pivot(old, present: present)
        if newPivot != old {
            try fm.createDirectory(at: pivotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newPivot.write(to: pivotFile, atomically: true, encoding: .utf8)
        }
        try checkStop()
        writeState(["finished": true, "client": manifest.version, "updated": ISO8601DateFormatter().string(from: Date())])
        return .ok(changed: changed)
    }

    // MARK: - Steps

    private func installAshita() throws {
        log("==> Vanadreams: Ashita v4 (AshitaXI/Ashita-v4beta at \(VanadreamsChannel.ashitaCommit.prefix(7)))")
        let tmp = stateDir.appendingPathComponent("tmp/ashita-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("ashita.zip")
        try download(src.ashitaZip, to: zip, sha: nil)
        let out = tmp.appendingPathComponent("x")
        try unzip(zip, into: out)
        // GitHub's archive nests everything one folder down; that folder's contents go into the game folder.
        let tops = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard tops.count == 1, let top = tops.first,
              fm.fileExists(atPath: top.appendingPathComponent("Ashita-cli.exe").path) else {
            throw Failure(description: "Ashita's archive did not hold Ashita-cli.exe where expected.")
        }
        try merge(top, into: root)
    }

    /// Every file under `src` moved to the same place under `dest`, replacing what is there.
    private func merge(_ src: URL, into dest: URL) throws {
        guard let walk = fm.enumerator(atPath: src.path) else { return }
        for case let rel as String in walk {
            let from = src.appendingPathComponent(rel), to = dest.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.moveItem(at: from, to: to)
        }
    }

    private func ensureFile(_ url: String, sha: String, at dest: URL, label: String) throws {
        if AscensionChannel.sha256(of: dest) == sha { return }
        log("==> Vanadreams: \(label)")
        try download(url, to: dest, sha: sha)
        changed += 1
    }

    private func ensurePivot() throws {
        let dll = root.appendingPathComponent("polplugins/pivot.dll")
        if fm.fileExists(atPath: dll.path) { return }
        log("==> Vanadreams: XIPivot 4.3.001")
        let tmp = stateDir.appendingPathComponent("tmp/pivot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("pivot.zip")
        try download(src.pivot, to: zip, sha: src.pivotSHA)
        let out = tmp.appendingPathComponent("x")
        try unzip(zip, into: out)
        // Only what is missing: a pivot.ini or DATs README the player already has is theirs.
        guard let walk = fm.enumerator(atPath: out.path) else { return }
        for case let rel as String in walk {
            let from = out.appendingPathComponent(rel), to = root.appendingPathComponent(rel)
            guard AscensionSync.isRegularFile(from), !fm.fileExists(atPath: to.path) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: to)
        }
        changed += 1
    }

    private func installChunk(_ c: VanadreamsChannel.Chunk, version: String, into dest: URL, onProgress: @escaping (Double) -> Void) throws {
        let tmp = stateDir.appendingPathComponent("tmp/client-\(version)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent(c.name)
        if !(AscensionSync.isRegularFile(zip) && ((try? fm.attributesOfItem(atPath: zip.path))?[.size] as? NSNumber)?.int64Value == c.size
             && AscensionChannel.sha256(of: zip) == c.sha256) {
            try download(src.clientBase + version + "/" + c.name, to: zip, sha: c.sha256, onProgress: onProgress)
        }
        let out = tmp.appendingPathComponent("x-\(c.name)")
        try? fm.removeItem(at: out)
        defer { try? fm.removeItem(at: out) }
        try unzip(zip, into: out)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try merge(out, into: dest)
        let line = "\(version) \(c.name) \(c.sha256)\r\n"
        let record = root.appendingPathComponent(VanadreamsChannel.recordName)
        if let h = try? FileHandle(forWritingTo: record) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try line.write(to: record, atomically: true, encoding: .utf8) }
        try? fm.removeItem(at: zip)
        log("i  Vanadreams: \(c.name) unpacked into \(dest.lastPathComponent)")
    }

    private func writeProfile() throws {
        let ini = root.appendingPathComponent("config/boot/\(VanadreamsChannel.bootProfile)")
        if let text = try? String(contentsOf: ini, encoding: .utf8) {
            if let cmd = BootProfile.value("command", section: "ashita.boot", in: text), let now = VanadreamsChannel.repointed(cmd) {
                try BootProfile.setting(.init(section: "ashita.boot", key: "command", value: now), in: text).write(to: ini, atomically: true, encoding: .utf8)
                log("i  Vanadreams: profile pointed at \(VanadreamsChannel.host) (the server moved)")
            }
            return
        }
        let boot = root.appendingPathComponent("config/boot")
        guard let example = ["example-privateserver.ini", "example.ini"].lazy
                .compactMap({ try? String(contentsOf: boot.appendingPathComponent($0), encoding: .utf8) }).first else {
            throw Failure(description: "Ashita's example profiles are missing from config/boot. Press Repair.")
        }
        try VanadreamsChannel.profile(fromExample: example).write(to: ini, atomically: true, encoding: .utf8)
    }

    // MARK: - HTTP and zips

    private func get(_ s: String, timeout: TimeInterval = 30) throws -> Data {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Data, Error> = .failure(Failure(description: "no answer from \(s)"))
        let task = session.dataTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)) { d, r, e in
            if let e { out = .failure(e) }
            else if let h = r as? HTTPURLResponse, (200...299).contains(h.statusCode) { out = .success(d ?? Data()) }
            else { out = .failure(Failure(description: "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0) for \(s)")) }
            sem.signal()
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        return try out.get()
    }

    private func getJSON(_ s: String) throws -> [String: Any] {
        guard let o = (try JSONSerialization.jsonObject(with: try get(s, timeout: 15))) as? [String: Any] else {
            throw Failure(description: "\(s) is not JSON")
        }
        return o
    }

    /// Download into `dest` (beside it first), keeping it only when it hashes to `sha` (when given).
    private func download(_ s: String, to dest: URL, sha: String?, onProgress: ((Double) -> Void)? = nil) throws {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        try? fm.removeItem(at: part)
        var lastError: Error = Failure(description: "download failed")
        for attempt in 0..<3 {
            try checkStop()
            let sem = DispatchSemaphore(value: 0)
            var failure: Error?
            let task = session.downloadTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)) { tmp, r, e in
                defer { sem.signal() }
                if let e { failure = e; return }
                guard let h = r as? HTTPURLResponse, (200...299).contains(h.statusCode), let tmp else {
                    failure = Failure(description: "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0) for \(s)"); return
                }
                do { try FileManager.default.moveItem(at: tmp, to: part) } catch { failure = error }
            }
            task.resume()
            while sem.wait(timeout: .now() + 0.5) == .timedOut {
                if stop.raised { task.cancel() }
                let total = task.countOfBytesExpectedToReceive
                if total > 0 { onProgress?(Double(task.countOfBytesReceived) / Double(total)) }
            }
            if let failure { lastError = failure; try? fm.removeItem(at: part); try checkStop(); Thread.sleep(forTimeInterval: Double(attempt + 1)); continue }
            if let sha, AscensionChannel.sha256(of: part) != sha {
                try? fm.removeItem(at: part)
                lastError = Failure(description: "\(dest.lastPathComponent) came down damaged")
                continue
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
            return
        }
        throw lastError
    }

    /// `/usr/bin/ditto -x -k`, which keeps a "../" or absolute entry inside `out` (checked
    /// 2026-10-24); a link it unpacked is removed rather than followed by the merge.
    private func unzip(_ zip: URL, into out: URL) throws {
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        while p.isRunning { if stop.raised { p.terminate() }; Thread.sleep(forTimeInterval: 0.2) }
        try checkStop()
        guard p.terminationStatus == 0 else { throw Failure(description: "\(zip.lastPathComponent) could not be unpacked (ditto \(p.terminationStatus))") }
        if let walk = fm.enumerator(at: out, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let u as URL in walk where (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try? fm.removeItem(at: u)
            }
        }
    }

    // MARK: - State

    private func readState() -> [String: Any] {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    private func writeState(_ merge: [String: Any]) {
        var s = readState()
        for (k, v) in merge { s[k] = v }
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: stateURL, options: .atomic)
        }
    }
}
