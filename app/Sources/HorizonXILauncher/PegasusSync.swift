import Foundation
import zlib

/// PegasusXI (play.pegasusxi.com, LandSandBoat, stock xiloader 2.1.1): their whole client as one zip
/// on their CDN, installed and kept current the way their launcher means to, natively.
///
/// Read from their launcher (Electron 1.1.8, `app.asar` read as data: `lib/pegasusxi-zip-pack-sync.js`,
/// `main.js`), their site and their CDN, 2026-10-24; the research is in docs/PEGASUS.md:
///
///  * **The pack**: `cdn.pegasusxi.com/launcher/pegasusxi-pack.json` names the current release
///    (`{"version":"1.2.4","zipUrl":…}`), a ZIP64 of 13.9 GB (27.9 GB unpacked, 105,427 files) holding
///    one `PegasusXI_<version>/` folder: Ashita 4.3.0.2, LandSandBoat's xiloader, the retail client
///    under `Game/SquareEnix`, their addons, plugins and DAT overlays. No hashes are published; each
///    member's CRC-32 is in the zip's own directory.
///  * **Their install and update**: download the whole zip, unpack every member over the install with
///    the wrapper folder dropped, then `pegasusxi-pack-state.json` `{appliedVersion, zipUrl, updatedAt}`.
///    A newer `version` means the same again with the new zip.
///
/// Here the zip is never downloaded whole. Its directory is read with two Range requests (the end
/// record, then the 15.6 MB directory), and only the members this folder lacks, or that changed since
/// the release last applied, are fetched by Range, inflated and checked against their CRC-32. 1.2.3 →
/// 1.2.4 was 20 MB this way, not 13.9 GB. What differs from theirs:
///
///  * Their Windows-only pieces are not installed: `prereqs/`, the prereq installer, their launcher
///    exe and its shortcut, `LauncherLogs/`, their launcher's settings (`pegasus-config.json`, a
///    developer's E:\ paths) and its session profile `__runtime_pega.ini`.
///  * The player's own files are never reset: `Game/config/` (except Ashita's own `config/ashita/`),
///    `Game/scripts/`, the game's `USER/` and PlayOnline's `usr/` are written when missing, or when a
///    release changes them (theirs overwrites them every time), never by Repair.
///  * A file a release removed is removed (theirs leaves it, which keeps a stale DAT overlay live in
///    XIPivot's folders), unless it is one of the player's files or was changed here.
enum PegasusChannel {
    static let worldName = "PegasusXI"
    static let host = "play.pegasusxi.com"
    static let bootProfile = "PegasusXI.ini"
    static let site = "https://pegasusxi.com"
    static let stateFile = "pegasusxi-pack-state.json"

    struct Sources {
        var index = "https://cdn.pegasusxi.com/launcher/pegasusxi-pack.json"
        /// Only zips from here are taken (their site's own copy of the index is stale).
        var zipPrefix = "https://cdn.pegasusxi.com/"
    }

    struct Pack: Equatable { var version: String; var zipURL: String }

    static func parsePack(_ d: Data, prefix: String) -> Pack? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let v = o["version"] as? String, !v.isEmpty, let u = o["zipUrl"] as? String, u.hasPrefix(prefix) else { return nil }
        return Pack(version: v, zipURL: u)
    }

    // MARK: - The zip's directory

    struct Member: Equatable {
        var path: String
        var method: UInt16
        var crc: UInt32
        var csize: UInt64
        var usize: UInt64
        var offset: UInt64
        var nameLength: Int
        var crcHex: String { String(format: "%08x", crc) }
    }

    static func u16(_ d: Data, _ at: Int) -> UInt16 { d.count >= at + 2 ? UInt16(d[d.startIndex + at]) | UInt16(d[d.startIndex + at + 1]) << 8 : 0 }
    static func u32(_ d: Data, _ at: Int) -> UInt32 { UInt32(u16(d, at)) | UInt32(u16(d, at + 2)) << 16 }
    static func u64(_ d: Data, _ at: Int) -> UInt64 { UInt64(u32(d, at)) | UInt64(u32(d, at + 4)) << 32 }

    /// Where the directory is, from the last bytes of a zip of `total` bytes (`tail`): the end record,
    /// and for a ZIP64 the ZIP64 end record its locator names (which must lie inside `tail`).
    static func locateDirectory(tail: Data, total: UInt64) -> (offset: UInt64, size: UInt64, entries: UInt64)? {
        guard tail.count >= 22 else { return nil }
        var at = tail.count - 22
        while at >= 0, u32(tail, at) != 0x0605_4b50 { at -= 1 }
        guard at >= 0 else { return nil }
        var entries = UInt64(u16(tail, at + 10)), size = UInt64(u32(tail, at + 12)), offset = UInt64(u32(tail, at + 16))
        if entries == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            let loc = at - 20
            guard loc >= 0, u32(tail, loc) == 0x0706_4b50 else { return nil }
            let rec = u64(tail, loc + 8), base = total - UInt64(tail.count)
            guard rec >= base, rec - base + 56 <= UInt64(tail.count) else { return nil }
            let r = Int(rec - base)
            guard u32(tail, r) == 0x0606_4b50 else { return nil }
            entries = u64(tail, r + 32); size = u64(tail, r + 40); offset = u64(tail, r + 48)
        }
        guard offset + size <= total else { return nil }
        return (offset, size, entries)
    }

    /// Every file entry of a central directory (folders left out), ZIP64 sizes and offsets read from
    /// the extra field. Nil when the bytes are not one.
    static func parseDirectory(_ cd: Data) -> [Member]? {
        var out: [Member] = [], at = 0
        while at + 46 <= cd.count, u32(cd, at) == 0x0201_4b50 {
            let flags = u16(cd, at + 8), method = u16(cd, at + 10), crc = u32(cd, at + 16)
            var csize = UInt64(u32(cd, at + 20)), usize = UInt64(u32(cd, at + 24))
            let n = Int(u16(cd, at + 28)), e = Int(u16(cd, at + 30)), c = Int(u16(cd, at + 32))
            var offset = UInt64(u32(cd, at + 42))
            guard at + 46 + n + e + c <= cd.count else { return nil }
            let nameBytes = cd[(cd.startIndex + at + 46)..<(cd.startIndex + at + 46 + n)]
            let name = (flags & 0x800 != 0 ? String(data: nameBytes, encoding: .utf8) : nil)
                ?? String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            // ZIP64 extra (0x0001): the fields that overflowed, in this order.
            var x = at + 46 + n
            let xEnd = x + e
            while x + 4 <= xEnd {
                let id = u16(cd, x), len = Int(u16(cd, x + 2))
                if id == 0x0001 {
                    var p = x + 4
                    if usize == 0xFFFF_FFFF, p + 8 <= x + 4 + len { usize = u64(cd, p); p += 8 }
                    if csize == 0xFFFF_FFFF, p + 8 <= x + 4 + len { csize = u64(cd, p); p += 8 }
                    if offset == 0xFFFF_FFFF, p + 8 <= x + 4 + len { offset = u64(cd, p); p += 8 }
                }
                x += 4 + len
            }
            if !name.hasSuffix("/") {
                out.append(Member(path: name.replacingOccurrences(of: "\\", with: "/"), method: method, crc: crc,
                                  csize: csize, usize: usize, offset: offset, nameLength: n))
            }
            at += 46 + n + e + c
        }
        return out
    }

    /// A member's path under the install: their `PegasusXI_<version>/` wrapper dropped (as their
    /// launcher strips it). Nil for anything outside the wrapper or unsafe.
    static func relative(_ path: String) -> String? {
        guard let slash = path.firstIndex(of: "/") else { return nil }
        let top = path[..<slash], rest = String(path[path.index(after: slash)...])
        guard top.hasPrefix("PegasusXI_"), !rest.isEmpty, AscensionSync.safeRelative(rest) else { return nil }
        return rest
    }

    /// Their Windows-only files, never installed here.
    static func skipped(_ rel: String) -> Bool {
        let l = rel.lowercased()
        return l.hasPrefix("prereqs/") || l == "install pegasusxi prereqs.exe" || l == "pegasusxi launcher.exe.lnk"
            || l == "scripts/install-prereqs.ps1" || l == "game/pegasusxi launcher.exe" || l.hasPrefix("game/launcherlogs/")
            || l == "game/pegasus-config.json" || l == "game/config/boot/__runtime_pega.ini"
    }

    /// The player's files: written when missing or changed by a release, never reset by Repair.
    static func userEditable(_ rel: String) -> Bool {
        let l = rel.lowercased()
        if l.hasPrefix("game/config/ashita/") { return false }
        return l.hasPrefix("game/config/") || l.hasPrefix("game/scripts/")
            || l.hasPrefix("game/squareenix/final fantasy xi/user/") || l.contains("/playonlineviewer/usr/")
            || l.contains("/playonlineviewer/default/usr/")
    }

    /// An addon's entry file (`Game/addons/<n>/<n>.lua`), which LuaJITGuard prefixes.
    static func isAddonEntry(_ rel: String) -> Bool {
        let p = rel.split(separator: "/")
        return p.count == 4 && p[0] == "Game" && p[1] == "addons" && p[3].lowercased() == p[2].lowercased() + ".lua"
    }

    static func crc32(_ d: Data) -> UInt32 {
        d.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }

    static func crc32(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var c: uLong = 0
        // Each chunk in a pool of its own: FileHandle's buffers are autoreleased, and a thread that
        // never drains one keeps every chunk it ever read (11 GB in the first real install).
        while let chunk = autoreleasepool(invoking: { try? h.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            c = chunk.withUnsafeBytes { zlib.crc32(c, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        }
        return String(format: "%08x", UInt32(c))
    }

    /// Their approved Ashita addons (pegasusxi.com/addons.js `ASHITA_APPROVED`, 88 names, 2026-10-24):
    /// "the only permissible addons … Unlisted addons should be considered prohibited, and using them
    /// is punishable."
    static let approved: [String] = """
    ahcolors ahgo allmaps aspect autojoin autorespond balloon blumon blusets cfhblock chains changecall chatmon checker \
    chime cleancs clippaste clock config craftmon crosshair debuff distance drawdistance dynamic_entity_renamer enternity \
    equipmon fastswap ffxiatlas filterless filters filterscan fishaid fps freemem gateway GMAss hideconsole hideparty \
    hideui ibar ime imguistyle instantah instantchat itemwatch links logincmd logs luashitacast macrofix mapdot minimapmon \
    mipmap Missiontracker mobdb move namecolors nocombat nokb nolock nomad nomount noname onevent paranormal peekaboo \
    petinfo recast renamer repeater sexchange simplelog singlerace skeletonkey statustimers stfu targetlines timers \
    timestamp tokens tparty treasurepool xichats xiui Yield zonename Zoom
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    static let addonPolicy = AddonPolicy.allowlist(published: approved,
        source: "PegasusXI's approved Ashita addons, pegasusxi.com/addons.html (checked 2026-10-24)")
}

final class PegasusSync: @unchecked Sendable {
    typealias Outcome = AscensionSync.Outcome
    /// LocalizedError too, so a catch that only has `localizedDescription` prints this text.
    struct Failure: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    let root: URL
    private let src: PegasusChannel.Sources
    private let stop: StopFlag
    private let log: (String) -> Void
    private let progress: (String, Double) -> Void
    private let session: URLSession
    private let fm = FileManager.default
    private let crcs: HashCache
    private let lock = NSLock()
    private var changed = 0
    private var stateDir: URL { root.appendingPathComponent(".ffxi-on-mac") }
    private var listingURL: URL { stateDir.appendingPathComponent("pegasus-listing.json") }
    private var oursURL: URL { stateDir.appendingPathComponent("pegasus.json") }
    /// Concurrent Range downloads.
    static let workers = 3
    /// One Range request covers members this close together, up to this many bytes.
    static let gapLimit: UInt64 = 1 << 20, runLimit: UInt64 = 64 << 20

    init(root: URL, sources: PegasusChannel.Sources = .init(), stop: StopFlag = StopFlag(),
         log: @escaping (String) -> Void, progress: @escaping (String, Double) -> Void = { _, _ in }) {
        self.root = root; src = sources; self.stop = stop; self.log = log; self.progress = progress
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.httpMaximumConnectionsPerHost = Self.workers + 1
        c.httpAdditionalHeaders = ["User-Agent": "FFXI-on-Mac (PegasusXI client)"]
        session = URLSession(configuration: c)
        crcs = HashCache(url: root.appendingPathComponent(".ffxi-on-mac/crc32.json"), hasher: PegasusChannel.crc32(of:))
    }

    func run(install: Bool = false) -> Outcome {
        defer { crcs.save() }
        crcs.trustStamps = !install
        var outcome: Outcome
        do { outcome = try steps(install: install) }
        catch let f as Failure { outcome = .failed(f.description) }
        catch { outcome = .failed("PegasusXI update failed: \(error.localizedDescription)") }
        return stop.raised ? .stopped : outcome
    }

    private func checkStop() throws {
        if stop.raised { throw Failure(description: "Stopped. Press the button again to carry on; nothing finished is lost.") }
    }

    private func readJSON(_ u: URL) -> [String: Any] {
        (try? Data(contentsOf: u)).flatMap { d in
            try? JSONSerialization.jsonObject(with: d.starts(with: [0xEF, 0xBB, 0xBF]) ? d.dropFirst(3) : d) as? [String: Any]
        } ?? [:]
    }
    private func writeJSON(_ o: Any, _ u: URL) throws {
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: u, options: .atomic)
    }
    private var ours: [String: Any] { readJSON(oursURL) }
    var installedBefore: Bool {
        fm.fileExists(atPath: root.appendingPathComponent("Game/Ashita-cli.exe").path) && ours["finished"] as? Bool == true
    }

    private func steps(install: Bool) throws -> Outcome {
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        guard let indexData = try? get(src.index).data, let pack = PegasusChannel.parsePack(indexData, prefix: src.zipPrefix) else {
            try checkStop()
            if installedBefore { return .offline("PegasusXI's update index didn't load; playing with the files from the last update.") }
            throw Failure(description: "PegasusXI's update index (cdn.pegasusxi.com) didn't load. Try again in a few minutes.")
        }
        let last = ours
        if !install, last["finished"] as? Bool == true, last["version"] as? String == pack.version,
           fm.fileExists(atPath: root.appendingPathComponent("Game/Ashita-cli.exe").path) {
            return .ok(changed: 0)
        }
        try writeJSON(last.merging(["finished": false]) { $1 }, oursURL)
        log("==> PegasusXI \(pack.version): reading the release's file list")
        let members = try directory(of: pack.zipURL)
        try checkStop()
        // The listing of the release last applied here: path -> [crc, size].
        let before = (readJSON(listingURL)["files"] as? [String: [Any]]) ?? [:]
        func old(_ rel: String) -> (String, UInt64)? {
            guard let e = before[rel], e.count == 2, let c = e[0] as? String, let n = (e[1] as? NSNumber)?.uint64Value else { return nil }
            return (c, n)
        }
        var need: [(PegasusChannel.Member, String)] = [], kept = 0
        var listing: [String: [Any]] = [:]
        for (n, m) in members.enumerated() {
            if n % 2000 == 0 { try checkStop(); progress("Checking PegasusXI's files", Double(n) / Double(members.count)) }
            guard let rel = PegasusChannel.relative(m.path), !PegasusChannel.skipped(rel) else { continue }
            listing[rel] = [m.crcHex, m.usize]
            // A pool per file: the stat and read results are autoreleased.
            let fetchIt: Bool = autoreleasepool {
                let dest = root.appendingPathComponent(rel)
                let upstreamChanged = old(rel).map { $0.0 != m.crcHex || $0.1 != m.usize } ?? true
                if !AscensionSync.isRegularFile(dest) { return true }
                // The player's: rewritten only when a release changes it.
                if PegasusChannel.userEditable(rel) { return upstreamChanged && old(rel) != nil }
                if !install && !upstreamChanged { return false }
                if crcs.verified(rel, at: dest, sha: m.crcHex) { return false }
                if PegasusChannel.isAddonEntry(rel), let d = try? Data(contentsOf: dest), let bare = AscensionSync.withoutJITGuard(d),
                   PegasusChannel.crc32(bare) == m.crc { return false }
                return true
            }
            if fetchIt { need.append((m, rel)) } else { kept += 1 }
        }
        let bytes = need.reduce(UInt64(0)) { $0 + $1.0.csize }
        log("==> PegasusXI: \(kept) files already right, \(need.count) to fetch (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))")
        try fetch(need, from: pack.zipURL, totalBytes: bytes)
        try checkStop()
        // Files their previous release had and this one does not, compared without letter case as the
        // Mac's disk and Wine compare paths: a folder a release only renames by case is the same
        // folder, and its files must stay.
        var removed = 0
        let present = Set(listing.keys.map { $0.lowercased() })
        for (rel, _) in before where !present.contains(rel.lowercased()) && !PegasusChannel.userEditable(rel) && !PegasusChannel.skipped(rel) {
            let f = root.appendingPathComponent(rel)
            guard let (c, _) = old(rel), AscensionSync.isRegularFile(f), crcs.verified(rel, at: f, sha: c) else { continue }
            try? fm.removeItem(at: f); crcs.forget(rel); removed += 1
        }
        if removed > 0 { log("==> PegasusXI: \(removed) files their release removed, removed") }
        try writeJSON(["version": pack.version, "zipUrl": pack.zipURL, "files": listing], listingURL)
        // Their launcher's own record, in its shape.
        let now = ISO8601DateFormatter().string(from: Date())
        try writeJSON(["appliedVersion": pack.version, "zipUrl": pack.zipURL, "updatedAt": now], root.appendingPathComponent(PegasusChannel.stateFile))
        try writeJSON(["finished": true, "version": pack.version, "updated": now], oursURL)
        return .ok(changed: changed + removed)
    }

    // MARK: - Reading the zip by Range

    private func directory(of zip: String) throws -> [PegasusChannel.Member] {
        let tailLength = 65_557 + 20 + 56 + 64
        let (tail, total) = try get(zip, range: "bytes=-\(tailLength)")
        guard let total, let loc = PegasusChannel.locateDirectory(tail: tail, total: total) else {
            throw Failure(description: "PegasusXI's release zip could not be read (no directory at its end).")
        }
        guard loc.size < 256 << 20 else { throw Failure(description: "PegasusXI's release zip has an implausible directory.") }
        let (cd, _) = try get(zip, range: "bytes=\(loc.offset)-\(loc.offset + loc.size - 1)")
        guard let members = PegasusChannel.parseDirectory(cd), !members.isEmpty, UInt64(cd.count) == loc.size else {
            throw Failure(description: "PegasusXI's release zip directory could not be read.")
        }
        return members
    }

    private struct Run { var start: UInt64; var end: UInt64; var members: [(PegasusChannel.Member, String)] }

    private func fetch(_ need: [(PegasusChannel.Member, String)], from zip: String, totalBytes: UInt64) throws {
        guard !need.isEmpty else { return }
        // Local header (30) + name + an extra field of up to 256 bytes, then the data.
        func span(_ m: PegasusChannel.Member) -> (UInt64, UInt64) { (m.offset, m.offset + 30 + UInt64(m.nameLength) + 256 + m.csize) }
        var runs: [Run] = []
        for item in need.sorted(by: { $0.0.offset < $1.0.offset }) {
            let (s, e) = span(item.0)
            if var r = runs.last, s <= r.end + Self.gapLimit, e - r.start <= Self.runLimit {
                r.end = max(r.end, e); r.members.append(item); runs[runs.count - 1] = r
            } else {
                runs.append(Run(start: s, end: e, members: [item]))
            }
        }
        var next = 0, done: UInt64 = 0, failure: Error?
        let group = DispatchGroup()
        for _ in 0..<min(Self.workers, runs.count) {
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                while true {
                    lock.lock()
                    if failure != nil || stop.raised || next >= runs.count { lock.unlock(); return }
                    let r = runs[next]; next += 1
                    lock.unlock()
                    do {
                        try autoreleasepool { try fetchRun(r, from: zip) }
                        lock.lock()
                        done += r.members.reduce(0) { $0 + $1.0.csize }
                        let f = Double(done) / Double(max(totalBytes, 1))
                        lock.unlock()
                        progress("Downloading PegasusXI", f)
                    } catch {
                        lock.lock(); if failure == nil { failure = error }; lock.unlock()
                    }
                }
            }
        }
        group.wait()
        crcs.save()
        if let failure { throw failure }
        try checkStop()
    }

    private func fetchRun(_ r: Run, from zip: String) throws {
        // Three tries per range: one dropped connection must not fail a 14 GB install.
        var file: URL?
        for attempt in 1...3 {
            do { file = try download(zip, range: "bytes=\(r.start)-\(r.end - 1)"); break }
            catch { if attempt == 3 || stop.raised { throw error }; Thread.sleep(forTimeInterval: Double(attempt * 2)) }
        }
        guard let file else { return }
        defer { try? fm.removeItem(at: file) }
        guard let h = try? FileHandle(forReadingFrom: file) else { throw Failure(description: "PegasusXI: a download could not be read.") }
        defer { try? h.close() }
        let have = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        for (m, rel) in r.members {
            if stop.raised { return }
            try autoreleasepool { try writeMember(m, rel: rel, from: h, at: m.offset - r.start, have: have, zip: zip) }
        }
    }

    private func writeMember(_ m: PegasusChannel.Member, rel: String, from h: FileHandle, at: UInt64, have: UInt64, zip: String) throws {
        try h.seek(toOffset: at)
        let head = try h.read(upToCount: 30) ?? Data()
        guard head.count == 30, PegasusChannel.u32(head, 0) == 0x0403_4b50 else {
            throw Failure(description: "PegasusXI's zip has no file where its directory puts \(rel).")
        }
        let dataAt = at + 30 + UInt64(PegasusChannel.u16(head, 26)) + UInt64(PegasusChannel.u16(head, 28))
        if dataAt + m.csize > have {
            // A longer extra field than allowed for: this member alone.
            try fetchRun(Run(start: m.offset, end: m.offset + (dataAt - at) + m.csize, members: [(m, rel)]), from: zip)
            return
        }
        try h.seek(toOffset: dataAt)
        try write(m, rel: rel, from: h)
    }

    /// One member from `h` (at its data) into place: inflated, CRC-32 and size checked, then moved
    /// over the old file.
    private func write(_ m: PegasusChannel.Member, rel: String, from h: FileHandle) throws {
        let dest = root.appendingPathComponent(rel)
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: part.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: part) else { throw Failure(description: "PegasusXI: cannot write \(rel).") }
        var ok = false
        defer { try? out.close(); if !ok { try? fm.removeItem(at: part) } }
        var crc: uLong = 0, written: UInt64 = 0, left = m.csize
        func emit(_ d: Data) throws {
            crc = d.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            written += UInt64(d.count)
            try out.write(contentsOf: d)
        }
        switch m.method {
        case 0:
            while left > 0 {
                guard let d = try autoreleasepool(invoking: { try h.read(upToCount: Int(min(left, 1 << 20))) }), !d.isEmpty else { break }
                left -= UInt64(d.count); try emit(d)
            }
        case 8:
            var z = z_stream()
            guard inflateInit2_(&z, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw Failure(description: "PegasusXI: inflate could not start.")
            }
            defer { inflateEnd(&z) }
            var outBuf = [UInt8](repeating: 0, count: 1 << 20)
            var status = Z_OK
            while status != Z_STREAM_END {
                guard left > 0, var input = try autoreleasepool(invoking: { try h.read(upToCount: Int(min(left, 1 << 20))) }), !input.isEmpty else { break }
                left -= UInt64(input.count)
                let inCount = input.count
                try input.withUnsafeMutableBytes { (inPtr: UnsafeMutableRawBufferPointer) in
                    z.next_in = inPtr.bindMemory(to: Bytef.self).baseAddress
                    z.avail_in = uInt(inCount)
                    repeat {
                        let produced: Int = outBuf.withUnsafeMutableBytes { o in
                            z.next_out = o.bindMemory(to: Bytef.self).baseAddress
                            z.avail_out = uInt(o.count)
                            status = inflate(&z, Z_NO_FLUSH)
                            return o.count - Int(z.avail_out)
                        }
                        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                            throw Failure(description: "PegasusXI: \(rel) came down damaged (inflate \(status)).")
                        }
                        if produced > 0 { try emit(Data(outBuf[0..<produced])) }
                    } while z.avail_out == 0 && status != Z_STREAM_END
                }
            }
            guard status == Z_STREAM_END else { throw Failure(description: "PegasusXI: \(rel) came down cut short.") }
        default:
            throw Failure(description: "PegasusXI: \(rel) uses a compression this launcher does not read (\(m.method)).")
        }
        guard UInt32(crc) == m.crc, written == m.usize else { throw Failure(description: "PegasusXI: \(rel) came down damaged.") }
        try out.close()
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
        ok = true
        crcs.record(rel, at: dest, sha: m.crcHex)
        lock.lock(); changed += 1; lock.unlock()
    }

    // MARK: - HTTP

    /// GET `s`, whole or a Range of it. The total size comes from Content-Range.
    private func get(_ s: String, range: String? = nil) throws -> (data: Data, total: UInt64?) {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        let sem = DispatchSemaphore(value: 0)
        var out: Result<(Data, UInt64?), Error> = .failure(Failure(description: "no answer from \(s)"))
        let task = session.dataTask(with: req) { d, r, e in
            defer { sem.signal() }
            if let e { out = .failure(e); return }
            guard let h = r as? HTTPURLResponse else { return }
            if range != nil, h.statusCode != 206 { out = .failure(Failure(description: "\(u.host ?? s) does not answer Range requests (HTTP \(h.statusCode))")); return }
            guard (200...299).contains(h.statusCode) else { out = .failure(Failure(description: "HTTP \(h.statusCode) for \(s)")); return }
            let total = h.value(forHTTPHeaderField: "Content-Range").flatMap { $0.split(separator: "/").last }.flatMap { UInt64($0) }
            out = .success((d ?? Data(), total))
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        let (d, t) = try out.get()
        return (d, t)
    }

    /// A Range of `s` into a file of its own.
    private func download(_ s: String, range: String) throws -> URL {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue(range, forHTTPHeaderField: "Range")
        let dest = fm.temporaryDirectory.appendingPathComponent("pegasus-\(UUID().uuidString).part")
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = session.downloadTask(with: req) { t, r, e in
            defer { sem.signal() }
            if let e { failure = e; return }
            guard let h = r as? HTTPURLResponse, h.statusCode == 206, let t else {
                failure = Failure(description: "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0) for a part of \(u.lastPathComponent)"); return
            }
            do { try FileManager.default.moveItem(at: t, to: dest) } catch { failure = error }
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        if let failure { try? fm.removeItem(at: dest); throw failure }
        return dest
    }
}
