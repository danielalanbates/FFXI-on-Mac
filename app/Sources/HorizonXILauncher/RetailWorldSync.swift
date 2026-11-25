import Foundation

/// Retail FFXI put together from other worlds' clients on this Mac: every file of a published list
/// (path, size, SHA-256) taken only from a donor whose copy hashes the same, and PlayOnline Viewer from
/// a donor on the same build. For worlds that ship no game files: DriftwoodXI, and the plain retail
/// worlds of `RetailWorldSync`. No Square Enix installer runs and nothing is downloaded.
final class RetailClient {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The folder holding `FINAL FANTASY XI` and `PlayOnlineViewer`.
    let game: URL
    private let world: String
    private let hashes: HashCache
    /// HashCache keys are `keyPrefix + "FINAL FANTASY XI/" + path`.
    private let keyPrefix: String
    private let stop: StopFlag
    private let log: (String) -> Void
    private let progress: (String, Double) -> Void
    private let fm = FileManager.default
    private(set) var changed = 0
    /// The donor the last copied file came from: tried first, since a client is mostly one build.
    private var lastDonor: URL?
    /// The one client file allowed to differ from a list: `patch2.cfg`, a PlayOnline patch-history
    /// file the server never sees (it differs between every client checked, 2026-10-24).
    static let mayDiffer: Set<String> = ["patch2.cfg"]

    init(game: URL, world: String, hashes: HashCache, keyPrefix: String = "Game/", stop: StopFlag,
         log: @escaping (String) -> Void, progress: @escaping (String, Double) -> Void) {
        self.game = game; self.world = world; self.hashes = hashes; self.keyPrefix = keyPrefix
        self.stop = stop; self.log = log; self.progress = progress
    }

    var present: Bool { fm.fileExists(atPath: game.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll").path) }

    /// Whether `u` may be replaced by a file: it is not there, or it is a file. A list naming a folder
    /// (`USER`, or `X/.`) must never have it deleted to make room.
    static func replaceable(_ u: URL) -> Bool {
        !FileManager.default.fileExists(atPath: u.path) || AscensionSync.isRegularFile(u)
    }

    /// Every file of `files` in place under `subfolder` ("FINAL FANTASY XI", or "PlayOnlineViewer"): kept
    /// when it already hashes right, copied from a donor that has it byte for byte, else `fetch`ed (a
    /// world that serves its own files) when there is one. `mayDiffer`: files a donor's copy of which
    /// is taken as it is when none matches.
    ///
    /// All or nothing: every file that is not already right must be available (a donor holds a file of
    /// that path and size, or `fetch` is given) before the first one is replaced, so a list this Mac
    /// cannot satisfy leaves the client as it was instead of half one build and half another.
    func assemble(_ files: [DriftwoodChannel.ClientFile], donors: [URL], build: String, subfolder: String = "FINAL FANTASY XI",
                  mayDiffer: Set<String> = RetailClient.mayDiffer,
                  canFetch: ((DriftwoodChannel.ClientFile) -> Bool)? = nil,
                  fetch: ((DriftwoodChannel.ClientFile, URL) throws -> Void)? = nil) throws {
        log("==> \(world): checking \(subfolder) against the list of \(files.count) files of \(fetch == nil ? "retail " : "")\(build)")
        let base = game.appendingPathComponent(subfolder)
        func stopped() throws { if stop.raised { throw Failure(description: "Stopped. Press the button again to carry on; nothing finished is lost.") } }
        // 1. What is already right.
        var kept = 0, need: [DriftwoodChannel.ClientFile] = []
        for (n, f) in files.enumerated() {
            if n % 500 == 0 { try stopped(); progress("Checking \(world)'s client", Double(n) / Double(max(files.count, 1)) * 0.5) }
            guard AscensionSync.safeRelative(f.path) else { throw Failure(description: "\(world)'s client list names an unsafe path: \(f.path)") }
            let right: Bool = autoreleasepool { hashes.verified(keyPrefix + subfolder + "/" + f.path, at: base.appendingPathComponent(f.path), sha: f.sha256) }
            if right { kept += 1 } else { need.append(f) }
        }
        // 2. Whether the rest can be had, before anything is replaced.
        let fetchable = canFetch ?? { _ in fetch != nil }
        do {
            let unavailable = need.filter { f in
                autoreleasepool {
                    if f.size == 0 || fetchable(f) { return false }
                    if mayDiffer.contains(f.path.lowercased()) { return false }
                    return !donors.contains { d in
                        let c = d.appendingPathComponent(subfolder).appendingPathComponent(f.path)
                        return ((try? fm.attributesOfItem(atPath: c.path))?[.size] as? NSNumber)?.int64Value == f.size
                    }
                }
            }
            if let first = unavailable.first {
                throw Failure(description: "\(unavailable.count) of \(world)'s client files are not on this Mac (first: \(subfolder)/\(first.path)). They come from "
                              + "retail FFXI on build \(build): install a world whose client is that build first (AscensionXI or Vanadreams carry 30260904_1). "
                              + "Nothing was changed.")
            }
        }
        // 3. In place.
        var copied = 0, fetched = 0, missing: [String] = []
        for (n, f) in need.enumerated() {
            if n % 100 == 0 { try stopped(); progress("Copying \(world)'s client", 0.5 + Double(n) / Double(max(need.count, 1)) * 0.5) }
            let key = keyPrefix + subfolder + "/" + f.path
            let dest = base.appendingPathComponent(f.path)
            // A pool per file: stat results and copies are autoreleased, and this thread drains none.
            enum Got { case kept, copied, fetched, missing }
            let got: Got = try autoreleasepool {
                if f.size == 0 {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data().write(to: dest); hashes.record(key, at: dest, sha: f.sha256); return .copied
                }
                if copy(f, from: donors, subfolder: subfolder, to: dest, key: key, exact: true) { return .copied }
                if mayDiffer.contains(f.path.lowercased()),
                   fm.fileExists(atPath: dest.path) || copy(f, from: donors, subfolder: subfolder, to: dest, key: key, exact: false) { return .kept }
                if let fetch {
                    try fetch(f, dest)
                    hashes.record(key, at: dest, sha: f.sha256)
                    return .fetched
                }
                return .missing
            }
            switch got {
            case .kept: kept += 1
            case .copied: copied += 1; changed += 1
            case .fetched: fetched += 1; changed += 1
            case .missing: missing.append(f.path)
            }
        }
        hashes.save()
        log("==> \(world): \(kept) files of \(subfolder) already right, \(copied) copied from other clients on this Mac, "
            + (fetch == nil ? "\(missing.count) missing" : "\(fetched) downloaded"))
        if !missing.isEmpty {
            // A donor of the right size held different bytes: rare, and the file stays as it was.
            throw Failure(description: "\(missing.count) of \(world)'s client files are not on this Mac byte for byte (first: \(subfolder)/\(missing[0])). "
                          + "They come from retail FFXI on build \(build).")
        }
    }

    /// A donor's copy of `f` into `dest`, hashed after copying. `exact: false` takes any same-path file.
    private func copy(_ f: DriftwoodChannel.ClientFile, from donors: [URL], subfolder: String = "FINAL FANTASY XI",
                      to dest: URL, key: String, exact: Bool) -> Bool {
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        let order = lastDonor.map { l in [l] + donors.filter { $0 != l } } ?? donors
        for d in order {
            let c = d.appendingPathComponent(subfolder).appendingPathComponent(f.path)
            guard AscensionSync.isRegularFile(c), Self.replaceable(dest) else { continue }
            if exact, ((try? fm.attributesOfItem(atPath: c.path))?[.size] as? NSNumber)?.int64Value != f.size { continue }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: part)
                try fm.copyItem(at: c, to: part)
                if exact, AscensionChannel.sha256(of: part) != f.sha256 { try? fm.removeItem(at: part); continue }
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: part, to: dest)
                if exact { hashes.record(key, at: dest, sha: f.sha256); lastDonor = d }
                return true
            } catch { try? fm.removeItem(at: part) }
        }
        return false
    }

    /// PlayOnline Viewer beside the game. Not in any list; copied whole when missing, from a donor on
    /// the same build: the one the client's files came from, else one whose FFXiMain.dll is this client's.
    func ensureViewer(donors: [URL]) throws {
        // FINAL FANTASY XI/USER holds each character's settings and macros. No file list carries it
        // (it is the player's), and Vanadreams' own installer makes it before the first login.
        let user = game.appendingPathComponent("FINAL FANTASY XI/USER")
        if present, !fm.fileExists(atPath: user.path) { try? fm.createDirectory(at: user, withIntermediateDirectories: true) }
        let viewer = game.appendingPathComponent("PlayOnlineViewer")
        guard !fm.fileExists(atPath: viewer.appendingPathComponent("viewer/com/polcore.dll").path) else { return }
        let main = AscensionChannel.sha256(of: game.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll"))
        let sameBuild = donors.filter { main != nil && AscensionChannel.sha256(of: $0.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll")) == main }
        // Among the rest, a viewer that never held a PlayOnline member's mail and messages first: the
        // copy is the program, not someone's PlayOnline data (HorizonXI's own viewer has both).
        func personal(_ d: URL) -> Bool {
            let pub = d.appendingPathComponent("PlayOnlineViewer/pub")
            return ((try? fm.contentsOfDirectory(atPath: pub.path)) ?? []).contains { home in
                ["mail", "EMAIL", "msg"].contains { fm.fileExists(atPath: pub.appendingPathComponent("\(home)/\($0)").path) }
            }
        }
        // And the newest viewer before an older one (version.dat, "1.18.15e"): the loaders find
        // PlayOnline's code by signature, and an un-updated viewer (1.18.00n) does not match.
        func version(_ d: URL) -> String {
            ((try? String(contentsOf: d.appendingPathComponent("PlayOnlineViewer/version.dat"), encoding: .ascii)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
        let ranked = donors.sorted { a, b in
            let (va, vb) = (version(a), version(b))
            return va != vb ? va.compare(vb, options: .numeric) == .orderedDescending : (!personal(a) && personal(b))
        }
        let order = (lastDonor.map { [$0] } ?? []) + sameBuild + ranked
        guard let from = order.map({ $0.appendingPathComponent("PlayOnlineViewer") })
                .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("viewer/com/polcore.dll").path) }) else {
            throw Failure(description: "No PlayOnline Viewer on this Mac to copy for \(world). Install AscensionXI or Vanadreams first.")
        }
        log("==> \(world): PlayOnline Viewer from \(from.deletingLastPathComponent().path)")
        try? fm.removeItem(at: viewer)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try fm.copyItem(at: from, to: viewer)
        changed += 1
    }
}

/// LandSandBoat worlds whose players bring retail FFXI and add Ashita and LandSandBoat's xiloader
/// themselves (each world's own setup guide), so the whole install is: a retail client, Ashita v4,
/// the xiloader release the world's login server takes, and a boot profile with `--server <host>`.
///
/// * **Client**: retail build 30260904_1 from identical files on this Mac (`RetailClient`), checked
///   against DriftwoodXI's public list of that build's 65,053 files. That list is the only published
///   SHA-256 list of a retail build there is; it names retail files only ("No game files come from
///   us"). A world needing a different build says so at login.
/// * **Ashita**: the AshitaXI/Ashita-v4beta commit VanadreamsSync pins (4171c74c, v4.3.2.1, the
///   `main` MistXI's own launcher tracks), into `Ashita/`.
/// * **Loader**: LandSandBoat's own release of the series the server asks for. Their login checks
///   major.minor exactly (`src/login/auth_session.cpp`), so a newer loader is refused too.
enum RetailWorld {
    struct Loader: Equatable {
        var version: String; var sha256: String; var url: String
        /// LandSandBoat's own GitHub release asset.
        static func release(_ v: String, _ sha: String) -> Loader {
            Loader(version: v, sha256: sha, url: "https://github.com/LandSandBoat/xiloader/releases/download/v\(v)/xiloader.exe")
        }
    }
    /// LandSandBoat xiloader releases by the series a login server asks for (GitHub release assets,
    /// checked 2026-10-24).
    static let loaders: [String: Loader] = [
        "2.0": .release("2.0.1", "85e2c33aeb10792be9dd381ea0c2a322d38eeeabd5c19a9a200e0e6deddeac26"),
        "2.1": .release("2.1.2", "f716a45d4da1b3fff65c83ee59b9c91b7bdf00f5b953b554c3791a39ab2eb4a8"),
        "2.2": .release("2.2.0", "aec6c0686cf3b2fe65247b818fe44f89fb18fc175e8ebd3ba3b7cf099988f504"),
    ]

    struct Spec {
        var world: String
        var host: String
        var profile: String
        var script: String
        /// The series the login server asks for ("2.1": "Please update to version '2.1.x'").
        var loaderSeries: String
        /// Addons the world's own launcher deletes from Ashita's bundle; never left in place here.
        var removedAddons: [String] = []
        /// Plugins (`plugins/<name>.dll`) the world's own launcher deletes.
        var removedPlugins: [String] = []
        var plugins: [String] = ["thirdparty", "addons", "screenshot", "winefix"]
        /// Where the client comes from: retail's files on this Mac (the default), a world's own archive
        /// of an older client (`ClientArchive`), or a world's own client list (Olympus XI).
        var client: ClientSource = .retail
        /// The world's own DATs, served ahead of the client's by XIPivot (`Overlay`).
        var overlay: Overlay? = nil
        /// Loader arguments their own profile passes after `--server` (also `Server.loaderOptions`).
        var loaderOptions: [String] = []
        var loader: Loader { RetailWorld.loaders[loaderSeries]! }
    }

    /// A world's DAT overlay: files of theirs that XIPivot reads in place of the client's, kept in
    /// `Ashita/polplugins/DATs/<name>/`. The client's own files are never changed.
    struct Overlay {
        enum Source {
            /// Olympus XI: GitHub releases `patch-<n>`, the newest one's `manifest.json` lists the whole
            /// set; each file is the release asset `<sha256>.dat`.
            case githubPatches(releases: String)
            /// Legendary Relaunch: `<base>/manifest.json` lists the whole set; each file is `<base>/files/<path>`.
            case fileList(base: String)
        }
        var name: String
        var source: Source
        /// Paths their own launcher never puts in the overlay.
        var skipped: Set<String> = []
    }

    struct OverlayFile: Equatable { var path: String; var size: Int64; var sha256: String; var url: String }

    /// Olympus XI's patch manifest (`@olympus/shared/src/patch/patch.ts`): their path rule (numbered DATs
    /// and the ROMn tables only), the asset named for its hash, no duplicate paths, their size limits.
    static func parsePatchManifest(_ d: Data, releases: String) -> (version: String, files: [OverlayFile])? {
        guard d.count <= 1 << 20, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let patch = (o["patch"] as? NSNumber)?.intValue, patch > 0, let fs = o["files"] as? [Any], fs.count <= 20_000 else { return nil }
        var out: [OverlayFile] = [], seen = Set<String>(), total: Int64 = 0
        for raw in fs {
            guard let f = raw as? [String: Any], let p = f["path"] as? String, let n = (f["size"] as? NSNumber)?.int64Value,
                  let h = (f["sha256"] as? String)?.lowercased(), h.count == 64, f["asset"] as? String == h + ".dat",
                  p.range(of: #"^(ROM[2-9]?/\d{1,4}/\d{1,5}\.DAT|ROM([2-9])/[VF]TABLE\2\.DAT)$"#, options: .regularExpression) != nil,
                  n >= 0, n <= 256 << 20, seen.insert(p.lowercased()).inserted else { return nil }
            total += n
            out.append(OverlayFile(path: p, size: n, sha256: h, url: "\(releases)/download/patch-\(patch)/\(h).dat"))
        }
        return total <= 2 << 30 ? ("patch-\(patch)", out) : nil
    }

    /// Legendary Relaunch's update manifest (`UpdateService`): `{version, files: [{path, sha256, size}]}`.
    static func parseFileListManifest(_ d: Data, base: String) -> (version: String, files: [OverlayFile])? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let v = o["version"] as? String, !v.isEmpty, let fs = o["files"] as? [Any] else { return nil }
        var out: [OverlayFile] = [], seen = Set<String>()
        for raw in fs {
            guard let f = raw as? [String: Any], let p0 = f["path"] as? String, let n = (f["size"] as? NSNumber)?.int64Value,
                  let h = (f["sha256"] as? String)?.lowercased(), h.count == 64 else { return nil }
            let p = p0.replacingOccurrences(of: "\\", with: "/")
            guard AscensionSync.safeRelative(p), p.uppercased().hasPrefix("ROM"), seen.insert(p.lowercased()).inserted else { return nil }
            let enc = p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
            out.append(OverlayFile(path: p, size: n, sha256: h, url: "\(base)/files/\(enc)"))
        }
        return (v, out)
    }

    /// pivot.ini with `first` at the top of the overlays and every other listed overlay after it, the
    /// rest of the file kept.
    static func pivotINI(_ existing: String?, first: String) -> String {
        var kept: [String] = [], listed: [String] = [], inOverlays = false
        for raw in TextFile.lines(of: existing ?? "") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inOverlays = t.lowercased() == "[overlays]"; if inOverlays { continue } }
            if inOverlays {
                if let eq = t.firstIndex(of: "=") {
                    let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty, v.caseInsensitiveCompare(first) != .orderedSame { listed.append(v) }
                }
                continue
            }
            kept.append(raw)
        }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        if !kept.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[settings]" }) {
            kept = ["[settings]", "debug_log = false"] + kept
        }
        let overlays = ([first] + listed).enumerated().map { "\($0.offset) = \($0.element)" }
        return (kept + ["", "[overlays]"] + overlays + [""]).joined(separator: "\r\n")
    }

    enum ClientSource {
        /// Retail 30260904_1 from identical files on this Mac (`RetailClient`), against the pinned list.
        case retail
        case archive(ClientArchive)
        /// Olympus XI: the client named by their newest patch's `client.tag`, a GitHub release holding
        /// `client-manifest.json` (every FINAL FANTASY XI and PlayOnlineViewer file with its SHA-256)
        /// and `pack-NN.bin` (the files changed since Square Enix's 2019 installer, each a zlib stream).
        case olympus(releases: String)
    }

    /// The client a world publishes as one archive of a whole `FINAL FANTASY XI` folder, named on a
    /// wiki page: its MediaWiki API (`action=parse&prop=wikitext`).
    ///
    /// The page is only a pointer. Anyone with an account can edit a wiki, so an archive is installed
    /// only when its version, file and SHA-256 are pinned here (`pins`); a version the page names that
    /// is not pinned is reported, and the client already in place is kept.
    struct ClientArchive {
        var page: String
        var pins: [String: ArchivePin]
    }
    struct ArchivePin: Equatable { var fileID: String; var sha256: String; var size: Int64 }

    /// The list of retail 30260904_1 (DriftwoodXI's `/api/manifest`) is pinned by this digest of its
    /// entries (`entriesDigest`): the JSON may be written again, the files of a build do not change.
    /// When they move to another build, a cached copy of this one is used instead.
    static let retailListDigest = "464d8608d81cb1b85caa1dbb19ce5d18c98bf882b0586b724e2f75f7584c9849"

    /// SHA-256 over "path\0size\0sha256\n" per file, paths lower-cased, in order.
    static func entriesDigest(_ files: [DriftwoodChannel.ClientFile]) -> String {
        let rows = files.map { ($0.path.lowercased(), $0.size, $0.sha256.lowercased()) }.sorted { $0.0 < $1.0 }
        var text = ""
        for r in rows { text += "\(r.0)\u{0}\(r.1)\u{0}\(r.2)\n" }
        return AscensionChannel.sha256(Data(text.utf8))
    }

    struct OlympusClientFile { var file: DriftwoodChannel.ClientFile; var subfolder: String; var pack: String?; var offset: Int64; var csize: Int64 }

    /// Olympus XI's `client-manifest.json`: `{version, files: [{path "SquareEnix/<sub>/…", size, sha256,
    /// delta?: {pack, offset, csize}}]}` (their launcher's client manager).
    static func parseOlympusClient(_ d: Data) -> (version: String, files: [OlympusClientFile])? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let v = o["version"] as? String,
              v.range(of: #"^3\d{7}_\d+$"#, options: .regularExpression) != nil, let fs = o["files"] as? [Any] else { return nil }
        var out: [OlympusClientFile] = []
        for raw in fs {
            guard let f = raw as? [String: Any], let p = f["path"] as? String, let n = (f["size"] as? NSNumber)?.int64Value,
                  let h = (f["sha256"] as? String)?.lowercased(), h.count == 64 else { return nil }
            let parts = p.split(separator: "/", maxSplits: 2).map(String.init)
            // Never the player's own folders (FINAL FANTASY XI/USER: settings and macros), never `.`.
            guard parts.count == 3, parts[0] == "SquareEnix", ["FINAL FANTASY XI", "PlayOnlineViewer"].contains(parts[1]),
                  AscensionSync.safeRelative(parts[2]), !parts[2].split(separator: "/").contains("."),
                  !(parts[1] == "FINAL FANTASY XI" && parts[2].split(separator: "/").first?.uppercased() == "USER"),
                  n >= 0, n <= 2 << 30 else { return nil }
            var pack: String?, offset: Int64 = 0, csize: Int64 = 0
            if let dl = f["delta"] as? [String: Any] {
                guard let pk = dl["pack"] as? String, pk.range(of: #"^pack-\d{2}\.bin$"#, options: .regularExpression) != nil,
                      let off = (dl["offset"] as? NSNumber)?.int64Value, let cs = (dl["csize"] as? NSNumber)?.int64Value,
                      off >= 0, cs > 0, cs <= 2 << 30, off <= Int64.max - cs else { return nil }
                pack = pk; offset = off; csize = cs
            }
            out.append(.init(file: .init(path: parts[2], size: n, sha256: h), subfolder: parts[1], pack: pack, offset: offset, csize: csize))
        }
        return (v, out)
    }

    /// The version and Google Drive file a world's page names as current: the first "FFXI Version
    /// <id>" heading before "Out of Date Versions" that is not struck through, and the first Drive file
    /// link after it.
    static func currentArchive(wikitext t: String) -> (version: String, fileID: String)? {
        let live = t.range(of: "Out of Date Versions", options: .caseInsensitive).map { String(t[..<$0.lowerBound]) } ?? t
        let lines = live.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where !line.contains("<s>") {
            guard let r = line.range(of: #"FFXI Version \d{8}_\d+"#, options: .regularExpression) else { continue }
            let version = String(line[r].split(separator: " ").last ?? "")
            let rest = lines[(i + 1)...].joined(separator: "\n")
            guard let d = rest.range(of: #"drive\.google\.com/file/d/[A-Za-z0-9_-]+"#, options: .regularExpression),
                  let id = rest[d].split(separator: "/").last.map(String.init), !id.isEmpty else { return nil }
            return (version, id)
        }
        return nil
    }

    /// The text of a MediaWiki `action=parse&prop=wikitext&format=json` answer.
    static func wikitext(_ d: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])
            .flatMap { $0["parse"] as? [String: Any] }.flatMap { $0["wikitext"] as? [String: Any] }.flatMap { $0["*"] as? String }
    }

    static func driveDownload(_ id: String) -> String { "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t" }

    /// LevelDown 99: "Use these downloads if you have a version of the game that is newer than the
    /// version LD99 is running on currently" (their wiki, Past FFXI Version Repository, 2026-10-24).
    static let levelDown = Spec(world: "LevelDown 99", host: "LevelDownFFXI.com", profile: "leveldown.ini", script: "leveldown.txt",
                                loaderSeries: "2.2",
                                client: .archive(ClientArchive(
                                    page: "https://ffxileveldown.fandom.com/api.php?action=parse&page=Past_FFXI_Version_Repository&prop=wikitext&format=json",
                                    // LDFFXI30260203_0.7z, downloaded and checked 2026-10-24 (66,264 entries, client 30260203_0).
                                    pins: ["30260203_0": ArchivePin(fileID: "1_WXohtOdVd1rUyGcK8eCfyYd2fEXp2HT",
                                                                    sha256: "5593ec2bf87a690a2cfb1add0aba2014f1d0a178db3a166033d5f3d8cc4a57cf",
                                                                    size: 5_528_427_346)])))

    static let mist = Spec(world: "MistXI", host: "play.mistxi.com", profile: "mistxi.ini", script: "mistxi.txt", loaderSeries: "2.1",
                           // MistXI's launcher deletes these from Ashita's bundle (GitHubAshitaService.cs `unwantedAddons`).
                           removedAddons: ["skeletonkey", "ahgo", "allmaps", "instantah", "instantchat", "paranormal"])
    static let moghouse = Spec(world: "Moghouse XI", host: "ffxi.cc", profile: "moghouse.ini", script: "moghouse.txt", loaderSeries: "2.2")
    /// Olympus XI (olympus-games.dev, open beta): their launcher 0.7.18 read as data (app.asar). Their
    /// client is retail 30260904_1 (the newest patch's `client.tag`); their DATs are an XIPivot overlay
    /// named "Olympus" from github.com/bobertdrake/olympus-xi-patch; their profile passes
    /// `--profileport 51220`.
    static let olympus = Spec(world: "Olympus XI", host: "172.96.141.132", profile: "olympus.ini", script: "olympus.txt",
                              loaderSeries: "2.2",
                              // Their launcher deletes and refuses these on every apply (index.js:2471-2520).
                              removedAddons: ["gateway", "skeletonkey", "nomad", "ahgo", "peekaboo", "truesight", "mapdot", "watchdog",
                                              "nokb", "casper", "paranormal", "repeater", "onevent", "allmaps", "cartographer",
                                              "minimapmon", "olympusbots"],
                              removedPlugins: ["minimap"],
                              client: .olympus(releases: "https://github.com/bobertdrake/olympus-xi-patch/releases"),
                              overlay: Overlay(name: "Olympus", source: .githubPatches(releases: "https://github.com/bobertdrake/olympus-xi-patch/releases")),
                              loaderOptions: ["--profileport", "51220"])
    /// Legendary Relaunch (ffxi-legendary.com, invite-only): their launcher 1.0.29 read with ILSpy. Fully
    /// patched retail, xiloader v2.1.2, and their DATs as the XIPivot overlay "legendary" from their
    /// portal; `ROM/0/6.DAT` is never put in it (`ItemDatGuard.IsPalUiRel`).
    static let legendary = Spec(world: "Legendary Relaunch", host: "15.204.112.102", profile: "legendary.ini", script: "legendary.txt",
                                loaderSeries: "2.1",
                                overlay: Overlay(name: "legendary", source: .fileList(base: "https://portal.ffxi-legendary.com/client-updates"),
                                                 skipped: ["ROM/0/6.DAT"]))
    static let all: [Spec] = [mist, moghouse, levelDown, olympus, legendary]
    static func spec(_ world: String) -> Spec? { all.first { $0.world == world } }

    static func profile(fromExample example: String, spec: Spec) -> String {
        var t = example
        for s in [BootProfile.Setting(section: "ashita.launcher", key: "name", value: spec.world),
                  BootProfile.Setting(section: "ashita.boot", key: "file", value: ".\\\\bootloader\\\\xiloader.exe"),
                  BootProfile.Setting(section: "ashita.boot", key: "command", value: (["--server", spec.host] + spec.loaderOptions).joined(separator: " ")),
                  BootProfile.Setting(section: "ashita.boot", key: "script", value: spec.script)] {
            t = BootProfile.setting(s, in: t)
        }
        return t
    }

    static func script(_ spec: Spec) -> String {
        var lines = ["# \(spec.world) startup script, written by FFXI on Mac. Addons… switches addons on and off.", ""]
        lines += spec.plugins.map { "/load \($0)" }
        lines += ["", "# The wait is required: without it, addons do not see the commands below.", "/wait 3",
                  "/bind insert /ashita", "/bind SYSRQ /screenshot hide", ""]
        return lines.joined(separator: "\r\n")
    }

    /// MistXI's approved list (mistxi.com/server-info, 2026-10-24): "Only items on this list are
    /// permitted", 101 addons and 23 plugins.
    static let mistAllowed: [String] = """
    actionparse activemon aecho affinity ahcolors aspect autocontrol autojoin autologin autorespond azuresets barfiller battlemod \
    blualert blucheck blumon blusets cancel cartographer casper cfhblock chamcham changecall chatfix chatmon checker chime cleancs \
    clock consolebg craftmon crosshair debuff distance enternity equipmon equipviewer fastcs fastfollow fastswap filterless filters \
    filterscan findall fps freemem gateway gearswap hideconsole hideobs hideparty hideui hxui ime imguistyle infobar invtracker \
    invmon itemwatch links logincmd logs macrofix mapdot minimapmon mipmap mobdb move namecolors nokb nomad nomount noname onevent \
    peekaboo petinfo quicksets recast renamer repeater scoreboard sellnpc send setbgm sexchange shortcut singlerace skillchains \
    statustimers stepdialog stfu stopwatch targetinfo thtracker timestamp tokens tparty treasurepool trimspells xipivot xivbar \
    addons ashitacast dashcam dats deeps duration hardwaremouse legacyac lootwhore minimap multisend nameplate packetflow \
    screenshot sequencer shorthand stylist thirdparty toon uberwarp watchexp winefix
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    static let mistPolicy = AddonPolicy.allowlist(published: mistAllowed,
        source: "MistXI's approved addons and plugins, mistxi.com/server-info (checked 2026-10-24)")

    struct Sources {
        /// The published retail file list (DriftwoodXI's: see the type's notes).
        var retailList = DriftwoodChannel.Sources().manifest
        var ashitaZip = VanadreamsChannel.ashitaZipURL
        var ashitaCommit = VanadreamsChannel.ashitaCommit
        /// nil: the spec's own pinned release.
        var loader: Loader?
        /// nil: the spec's own page; and where a Drive file id is fetched from.
        var archivePage: String?
        var archiveDownload: (String) -> String = RetailWorld.driveDownload
        /// nil: the spec's own pins.
        var archivePins: [String: ArchivePin]?
        var retailDigest = RetailWorld.retailListDigest
        /// nil: the spec's own Olympus releases page.
        var olympusReleases: String?
        /// nil: the spec's own overlay source (its releases page or base URL).
        var overlaySource: Overlay.Source?
        var pivotZip = VanadreamsChannel.pivotURL
        var pivotSHA = VanadreamsChannel.pivotSHA
    }
}

final class RetailWorldSync: @unchecked Sendable {
    typealias Outcome = AscensionSync.Outcome
    struct Failure: Error, CustomStringConvertible { let description: String }

    let root: URL
    let spec: RetailWorld.Spec
    private let src: RetailWorld.Sources
    private let stop: StopFlag
    private let log: (String) -> Void
    private let progress: (String, Double) -> Void
    private let session: URLSession
    private let fm = FileManager.default
    private let hashes: HashCache
    private var changed = 0
    private var ashita: URL { root.appendingPathComponent("Ashita") }
    private var stateDir: URL { root.appendingPathComponent(".ffxi-on-mac") }
    private var stateURL: URL { stateDir.appendingPathComponent("retail-world.json") }
    private lazy var client = RetailClient(game: root.appendingPathComponent("Game"), world: spec.world, hashes: hashes,
                                           stop: stop, log: log, progress: progress)

    init(spec: RetailWorld.Spec, root: URL, sources: RetailWorld.Sources = .init(), stop: StopFlag = StopFlag(),
         log: @escaping (String) -> Void, progress: @escaping (String, Double) -> Void = { _, _ in }) {
        self.spec = spec; self.root = root; src = sources; self.stop = stop; self.log = log; self.progress = progress
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "FFXI-on-Mac"]
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
        catch { outcome = .failed("\(spec.world) update failed: \(error.localizedDescription)") }
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
        let ashitaMissing = !fm.fileExists(atPath: ashita.appendingPathComponent("Ashita-cli.exe").path)
        // 1. The client, when its source changed since it was last put together, on Setup/Repair, or
        // when it is not there. Each source's list is read first; with none answering, a client that
        // finished its last update plays.
        let lastFinished = installedBefore
        switch spec.client {
        case .retail:
            let (files, moved) = retailFiles()
            if files == nil {
                try checkStop()
                if moved {
                    // Their list now names another build: never followed (see `retailListDigest`).
                    if !(client.present && lastFinished) {
                        throw Failure(description: "The published list of retail FFXI's files (xi.driftwoodgaming.com) now names another build than "
                                      + "\(DriftwoodChannel.clientBuild), and no copy of the \(DriftwoodChannel.clientBuild) list is on this Mac. Update FFXI on Mac.")
                    }
                    log("!! The published retail file list moved off \(DriftwoodChannel.clientBuild); keeping \(spec.world)'s client as it is.")
                } else {
                    if lastFinished { return .offline("The retail file list didn't load; playing with the files from the last update.") }
                    if !client.present || ashitaMissing {
                        throw Failure(description: "The list of retail FFXI's files (xi.driftwoodgaming.com/api/manifest) didn't load. Try again in a few minutes.")
                    }
                }
            }
            writeState(["finished": false])
            if let files {
                let digest = src.retailDigest
                if install || !client.present || readState()["clientList"] as? String != digest {
                    writeState(["clientList": ""])
                    try client.assemble(files, donors: donors, build: DriftwoodChannel.clientBuild)
                    writeState(["clientList": digest])
                }
            }
        case .archive(let a):
            let named = (try? get(src.archivePage ?? a.page).data).flatMap { $0 }.flatMap(RetailWorld.wikitext).flatMap(RetailWorld.currentArchive)
            if named == nil {
                try checkStop()
                if lastFinished { return .offline("\(spec.world)'s page naming their client version didn't load; playing with the files from the last update.") }
                if !client.present || ashitaMissing { throw Failure(description: "\(spec.world)'s page naming their client version didn't load. Try again in a few minutes.") }
            }
            writeState(["finished": false])
            if let named {
                let pins = src.archivePins ?? a.pins
                if let pin = pins[named.version], pin.fileID == named.fileID {
                    if install || !client.present || readState()["clientArchive"] as? String != named.version {
                        try installArchive(version: named.version, pin: pin)
                        writeState(["clientArchive": named.version])
                    }
                } else if client.present, readState()["clientArchive"] != nil {
                    log("!! \(spec.world)'s page names client \(named.version), which this build of FFXI on Mac has not checked; keeping client \(readState()["clientArchive"] as? String ?? "?"). Update FFXI on Mac.")
                } else {
                    throw Failure(description: "\(spec.world)'s page names client \(named.version) (file \(named.fileID)), which this build of FFXI on Mac "
                                  + "has not checked, so it is not installed. Update FFXI on Mac.")
                }
            }
        case .olympus(let releases0):
            let releases = src.olympusReleases ?? releases0
            let tag = (try? get(releases + "/latest/download/manifest.json").data).flatMap { $0 }
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                .flatMap { $0["client"] as? [String: Any] }.flatMap { $0["tag"] as? String }
                .flatMap { $0.range(of: #"^client-3\d{7}_\d+$"#, options: .regularExpression) != nil ? $0 : nil }
            if tag == nil {
                try checkStop()
                if lastFinished { return .offline("\(spec.world)'s patch list didn't load; playing with the files from the last update.") }
                if !client.present || ashitaMissing { throw Failure(description: "\(spec.world)'s patch list (GitHub) didn't load. Try again in a few minutes.") }
            }
            writeState(["finished": false])
            if let tag, install || !client.present || readState()["clientList"] as? String != tag {
                try assembleOlympus(releases: releases, tag: tag, donors: donors)
                writeState(["clientList": tag])
            }
        }
        try client.ensureViewer(donors: donors)
        try checkStop()
        // 2. Ashita at the pinned commit.
        if install || ashitaMissing || readState()["ashita"] as? String != src.ashitaCommit {
            try installAshita()
            writeState(["ashita": src.ashitaCommit])
        }
        for a in spec.removedAddons {
            let d = ashita.appendingPathComponent("addons/\(a)")
            if fm.fileExists(atPath: d.path) { try? fm.removeItem(at: d); log("i  \(spec.world): \(a) removed (their launcher removes it)") }
        }
        for pl in spec.removedPlugins {
            let f = ashita.appendingPathComponent("plugins/\(pl).dll")
            if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f); log("i  \(spec.world): plugin \(pl) removed (their launcher removes it)") }
        }
        try checkStop()
        // 3. The loader the server takes.
        let loader = src.loader ?? spec.loader
        let loaderFile = ashita.appendingPathComponent("bootloader/xiloader.exe")
        if AscensionChannel.sha256(of: loaderFile) != loader.sha256 {
            log("==> \(spec.world): LandSandBoat xiloader v\(loader.version)")
            try download(loader.url, to: loaderFile, sha: loader.sha256)
            changed += 1
        }
        // 4. Profile and script, only when missing: after that they are the player's.
        let ini = ashita.appendingPathComponent("config/boot/\(spec.profile)")
        if !fm.fileExists(atPath: ini.path) {
            guard let example = try? String(contentsOf: ashita.appendingPathComponent("config/boot/example-privateserver.ini"), encoding: .utf8) else {
                throw Failure(description: "Ashita's example profile is missing from \(spec.world)'s Ashita. Press Repair.")
            }
            try RetailWorld.profile(fromExample: example, spec: spec).write(to: ini, atomically: true, encoding: .utf8)
        }
        let script = ashita.appendingPathComponent("scripts/\(spec.script)")
        if !fm.fileExists(atPath: script.path) {
            try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try RetailWorld.script(spec).write(to: script, atomically: true, encoding: .utf8)
        }
        try checkStop()
        // 5. Their DATs, as an XIPivot overlay.
        if let ov = spec.overlay, let r = try syncOverlay(ov, install: install, profile: ini) { return r }
        try checkStop()
        writeState(["finished": true, "updated": ISO8601DateFormatter().string(from: Date())])
        return .ok(changed: changed + client.changed)
    }

    /// The overlay brought to their newest list: XIPivot in place, every listed file there with its
    /// hash (downloaded when not), files no longer listed removed, the overlay first in pivot.ini and
    /// `pivot = 1` in the profile. Returns an outcome only when their list cannot be read.
    private func syncOverlay(_ ov: RetailWorld.Overlay, install: Bool, profile ini: URL) throws -> Outcome? {
        try ensurePivot()
        let dir = ashita.appendingPathComponent("polplugins/DATs/\(ov.name)")
        let source = src.overlaySource ?? ov.source
        var parsed: (version: String, files: [RetailWorld.OverlayFile])?
        switch source {
        case .githubPatches(let releases):
            parsed = (try? get(releases + "/latest/download/manifest.json").data).flatMap { $0 }.flatMap { RetailWorld.parsePatchManifest($0, releases: releases) }
        case .fileList(let base):
            parsed = (try? get(base + "/manifest.json").data).flatMap { $0 }.flatMap { RetailWorld.parseFileListManifest($0, base: base) }
        }
        guard let parsed else {
            try checkStop()
            if readState()["overlay"] != nil, fm.fileExists(atPath: dir.path) {
                return .offline("\(spec.world)'s DAT list didn't load; playing with the DATs from the last update.")
            }
            throw Failure(description: "\(spec.world)'s DAT list didn't load. Try again in a few minutes.")
        }
        let files = parsed.files.filter { f in !ov.skipped.contains { $0.caseInsensitiveCompare(f.path) == .orderedSame } }
        if install || readState()["overlay"] as? String != parsed.version || !fm.fileExists(atPath: dir.path) {
            log("==> \(spec.world): their DATs \(parsed.version) (\(files.count) files)")
            var fetched = 0
            for (n, f) in files.enumerated() {
                try checkStop()
                try autoreleasepool {
                    progress("Updating \(spec.world)'s DATs", Double(n) / Double(max(files.count, 1)))
                    let dest = dir.appendingPathComponent(f.path)
                    let key = "Ashita/polplugins/DATs/\(ov.name)/\(f.path)"
                    if hashes.verified(key, at: dest, sha: f.sha256) { return }
                    var last: Error?
                    for attempt in 1...3 {
                        do { try download(f.url, to: dest, sha: f.sha256); last = nil; break }
                        catch { last = error; if stop.raised { break }; Thread.sleep(forTimeInterval: Double(attempt)) }
                    }
                    if let last { throw last }
                    hashes.record(key, at: dest, sha: f.sha256)
                    fetched += 1
                }
            }
            // Files their list no longer has (their launcher swaps in a fresh folder, so they go).
            let keep = Set(files.map { $0.path.lowercased() })
            var removed = 0
            if let walk = fm.enumerator(atPath: dir.path) {
                for case let rel as String in walk where AscensionSync.isRegularFile(dir.appendingPathComponent(rel)) && !keep.contains(rel.lowercased()) {
                    try? fm.removeItem(at: dir.appendingPathComponent(rel)); removed += 1
                }
            }
            if fetched + removed > 0 { log("==> \(spec.world): \(fetched) of their DATs downloaded, \(removed) no longer used removed") }
            changed += fetched + removed
            writeState(["overlay": parsed.version])
        }
        // XIPivot on, their overlay first.
        let pivotFile = ashita.appendingPathComponent("config/pivot/pivot.ini")
        let old = try? String(contentsOf: pivotFile, encoding: .utf8)
        let new = RetailWorld.pivotINI(old, first: ov.name)
        if new != old {
            try fm.createDirectory(at: pivotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try new.write(to: pivotFile, atomically: true, encoding: .utf8)
        }
        if let text = try? String(contentsOf: ini, encoding: .utf8),
           BootProfile.value("pivot", section: "ashita.polplugins", in: text) != "1" {
            try BootProfile.setting(.init(section: "ashita.polplugins", key: "pivot", value: "1"), in: text).write(to: ini, atomically: true, encoding: .utf8)
        }
        return nil
    }

    /// XIPivot 4.3.001 (HealsCodes' release, the pin VanadreamsSync uses) into Ashita, its files only
    /// where missing.
    private func ensurePivot() throws {
        guard !fm.fileExists(atPath: ashita.appendingPathComponent("polplugins/pivot.dll").path) else { return }
        log("==> \(spec.world): XIPivot 4.3.001")
        let tmp = stateDir.appendingPathComponent("tmp/pivot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("pivot.zip")
        try download(src.pivotZip, to: zip, sha: src.pivotSHA)
        let out = tmp.appendingPathComponent("x")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(description: "XIPivot could not be unpacked (ditto \(p.terminationStatus)).") }
        guard let walk = fm.enumerator(atPath: out.path) else { return }
        for case let rel as String in walk {
            let from = out.appendingPathComponent(rel), to = ashita.appendingPathComponent(rel)
            guard AscensionSync.isRegularFile(from), !fm.fileExists(atPath: to.path) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: to)
        }
        guard fm.fileExists(atPath: ashita.appendingPathComponent("polplugins/pivot.dll").path) else {
            throw Failure(description: "XIPivot's archive held no polplugins/pivot.dll.")
        }
        changed += 1
    }

    /// Their whole client, from the archive their page names: downloaded straight into this folder
    /// (resumed if stopped), unpacked with bsdtar (7-Zip included) without its `USER/` (another
    /// player's settings travel in it), then moved over `FINAL FANTASY XI`. Kept until a new version
    /// replaces it, so Repair unpacks it again without downloading.
    /// The pinned retail list: a copy of it already here, or one another world's folder holds, or the
    /// served one while it is still that list. A build's files do not change, so once a copy is here no
    /// request is made. `moved`: the list was served, and it is not the pinned one.
    private func retailFiles() -> (files: [DriftwoodChannel.ClientFile]?, moved: Bool) {
        let own = stateDir.appendingPathComponent("retail-list.json")
        func pinned(_ d: Data?) -> [DriftwoodChannel.ClientFile]? {
            d.flatMap(DriftwoodChannel.parseClientManifest).flatMap { RetailWorld.entriesDigest($0) == src.retailDigest ? $0 : nil }
        }
        if let fs = pinned(try? Data(contentsOf: own)) { return (fs, false) }
        let siblings = ((try? fm.contentsOfDirectory(at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .flatMap { [$0.appendingPathComponent(".ffxi-on-mac/retail-list.json"), $0.appendingPathComponent(".ffxi-on-mac/client-manifest.json")] }
        for c in siblings where c.path != own.path {
            if let d = try? Data(contentsOf: c), let fs = pinned(d) { try? d.write(to: own, options: .atomic); return (fs, false) }
        }
        guard let served = (try? get(src.retailList).data).flatMap({ $0 }) else { return (nil, false) }
        if let fs = pinned(served) { try? served.write(to: own, options: .atomic); return (fs, false) }
        return (nil, DriftwoodChannel.parseClientManifest(served) != nil)
    }

    /// Olympus XI's client: their client list (cached by tag), every file kept, copied from a donor, or
    /// taken from their delta pack, FINAL FANTASY XI and PlayOnlineViewer each all or nothing.
    private func assembleOlympus(releases: String, tag: String, donors: [URL]) throws {
        let copy = stateDir.appendingPathComponent("client-\(tag).json")
        var data = try? Data(contentsOf: copy)
        if data.flatMap(RetailWorld.parseOlympusClient) == nil {
            log("==> \(spec.world): their client list \(tag)")
            data = try get(releases + "/download/\(tag)/client-manifest.json").data
            try data?.write(to: copy, options: .atomic)
        }
        guard let data, let list = RetailWorld.parseOlympusClient(data) else { throw Failure(description: "\(spec.world)'s client list could not be read.") }
        writeState(["clientList": ""])
        for sub in ["FINAL FANTASY XI", "PlayOnlineViewer"] {
            let group = list.files.filter { $0.subfolder == sub }
            var deltas: [String: RetailWorld.OlympusClientFile] = [:]
            for e in group where e.pack != nil { deltas[e.file.path.lowercased()] = e }
            try client.assemble(group.map(\.file), donors: donors, build: list.version, subfolder: sub, mayDiffer: [],
                                canFetch: { deltas[$0.path.lowercased()] != nil }) { f, dest in
                guard let e = deltas[f.path.lowercased()] else {
                    throw Failure(description: "\(sub)/\(f.path) is not on this Mac and not among \(self.spec.world)'s changed files.")
                }
                try self.fetchDelta(releases: releases, tag: tag, e, to: dest)
            }
        }
    }

    /// One file out of their delta pack: its zlib stream by Range, inflated, size and SHA-256 checked.
    private func fetchDelta(releases: String, tag: String, _ e: RetailWorld.OlympusClientFile, to dest: URL) throws {
        guard let pack = e.pack, let u = URL(string: releases + "/download/\(tag)/\(pack)") else { throw Failure(description: "bad delta") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue("bytes=\(e.offset)-\(e.offset + e.csize - 1)", forHTTPHeaderField: "Range")
        let tmp = stateDir.appendingPathComponent("tmp/delta-\(UUID().uuidString)")
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        defer { try? fm.removeItem(at: tmp); try? fm.removeItem(at: part) }
        try fm.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = session.downloadTask(with: req) { t, r, err in
            defer { sem.signal() }
            if let err { failure = err; return }
            guard let h = r as? HTTPURLResponse, h.statusCode == 206, let t else {
                failure = Failure(description: "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0) for a part of \(pack)"); return
            }
            do { try FileManager.default.moveItem(at: t, to: tmp) } catch { failure = error }
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        if let failure { throw failure }
        guard ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value == e.csize else {
            throw Failure(description: "\(pack) answered a different part than asked for \(e.file.path).")
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard RetailClient.replaceable(dest) else { throw Failure(description: "\(e.file.path) is a folder here; their list names it as a file. Nothing replaced.") }
        let n = try Inflate.file(tmp, to: part, raw: false, limit: e.file.size)
        guard n == e.file.size, AscensionChannel.sha256(of: part) == e.file.sha256 else {
            throw Failure(description: "\(e.file.path) came down damaged from \(pack).")
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }

    private func installArchive(version: String, pin: RetailWorld.ArchivePin) throws {
        let a = (version: version, fileID: pin.fileID)
        let tmp = stateDir.appendingPathComponent("tmp")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("client-\(a.version).archive")
        let whole = tmp.appendingPathComponent("client-\(a.version).archive.done")
        for old in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("client-") && !old.lastPathComponent.hasPrefix("client-\(a.version).") {
            try? fm.removeItem(at: old)
        }
        if !fm.fileExists(atPath: whole.path) {
            guard let u = URL(string: src.archiveDownload(a.fileID)) else { throw Failure(description: "bad archive URL") }
            log("==> \(spec.world): their client \(a.version)")
            var tries = 0
            while true {
                do {
                    try FileDownload.run(u, to: file, stop: stop) { have, total in
                        if total > 0 { self.progress("Downloading \(self.spec.world)'s client", Double(have) / Double(total)) }
                    }
                    break
                } catch {
                    tries += 1
                    if tries >= 3 || stop.raised { throw error }
                    Thread.sleep(forTimeInterval: Double(tries * 3))
                }
            }
            fm.createFile(atPath: whole.path, contents: nil)
        }
        // Their archive as pinned, byte for byte, or nothing: checked before every unpack, a kept one too.
        log("==> \(spec.world): checking their client archive \(a.version)")
        let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value
        guard size == pin.size, AscensionChannel.sha256(of: file) == pin.sha256 else {
            try? fm.removeItem(at: file); try? fm.removeItem(at: whole)
            throw Failure(description: "\(spec.world)'s client archive \(a.version) is not the one this build of FFXI on Mac checked "
                          + "(its size or SHA-256 differs). Nothing was installed.")
        }
        try checkStop()
        log("==> \(spec.world): unpacking their client \(a.version)")
        progress("Unpacking \(spec.world)'s client", 0)
        let out = tmp.appendingPathComponent("x-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: out) }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        // -P is never passed: bsdtar keeps every entry under `out`.
        p.arguments = ["-xf", file.path, "-C", out.path, "--exclude", "USER", "--exclude", "*/USER"]
        try p.run()
        while p.isRunning { if stop.raised { p.terminate() }; Thread.sleep(forTimeInterval: 0.5) }
        try checkStop()
        guard p.terminationStatus == 0 else {
            // A damaged archive is not kept: the next try downloads it again.
            try? fm.removeItem(at: file); try? fm.removeItem(at: whole)
            throw Failure(description: "\(spec.world)'s client archive could not be unpacked (bsdtar \(p.terminationStatus)). Press the button again to download it again.")
        }
        // The folder that is a FINAL FANTASY XI: the archive's top, or its one folder.
        func isClient(_ u: URL) -> Bool { fm.fileExists(atPath: u.appendingPathComponent("FFXiMain.dll").path) && fm.fileExists(atPath: u.appendingPathComponent("ROM").path) }
        let tops = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard let top = isClient(out) ? out : tops.first(where: isClient) else {
            throw Failure(description: "\(spec.world)'s client archive holds no FINAL FANTASY XI folder.")
        }
        let ffxi = client.game.appendingPathComponent("FINAL FANTASY XI")
        // Their own instructions: the old VTABLE.DAT goes first, then the whole folder is replaced.
        try? fm.removeItem(at: ffxi.appendingPathComponent("VTABLE.DAT"))
        guard let walk = fm.enumerator(atPath: top.path) else { return }
        var n = 0
        for case let rel as String in walk {
            try autoreleasepool {
                let from = top.appendingPathComponent(rel), to = ffxi.appendingPathComponent(rel)
                guard AscensionSync.isRegularFile(from), RetailClient.replaceable(to) else { return }
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: to)
                try fm.moveItem(at: from, to: to)
                n += 1
            }
        }
        log("==> \(spec.world): client \(a.version) in place (\(n) files)")
        changed += n
    }

    private func installAshita() throws {
        log("==> \(spec.world): Ashita v4 (AshitaXI/Ashita-v4beta at \(src.ashitaCommit.prefix(7)))")
        let tmp = stateDir.appendingPathComponent("tmp/ashita-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("ashita.zip")
        try download(src.ashitaZip, to: zip, sha: nil)
        let out = tmp.appendingPathComponent("x")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(description: "Ashita's archive could not be unpacked (ditto \(p.terminationStatus)).") }
        // GitHub's archive nests everything one folder down.
        let tops = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard tops.count == 1, let top = tops.first, fm.fileExists(atPath: top.appendingPathComponent("Ashita-cli.exe").path) else {
            throw Failure(description: "Ashita's archive did not hold Ashita-cli.exe where expected.")
        }
        guard let walk = fm.enumerator(atPath: top.path) else { return }
        for case let rel as String in walk {
            let from = top.appendingPathComponent(rel), to = ashita.appendingPathComponent(rel)
            guard AscensionSync.isRegularFile(from), RetailClient.replaceable(to) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.moveItem(at: from, to: to)
        }
        changed += 1
    }

    // MARK: - HTTP

    private func get(_ s: String, ifModifiedSince: String? = nil) throws -> (data: Data?, lastModified: String?) {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let ims = ifModifiedSince { req.setValue(ims, forHTTPHeaderField: "If-Modified-Since") }
        let sem = DispatchSemaphore(value: 0)
        var out: Result<(Data?, String?), Error> = .failure(Failure(description: "no answer from \(s)"))
        let task = session.dataTask(with: req) { d, r, e in
            defer { sem.signal() }
            if let e { out = .failure(e); return }
            guard let h = r as? HTTPURLResponse else { return }
            if h.statusCode == 304 { out = .success((nil, nil)) }
            else if (200...299).contains(h.statusCode) { out = .success((d ?? Data(), h.value(forHTTPHeaderField: "Last-Modified"))) }
            else { out = .failure(Failure(description: "HTTP \(h.statusCode) for \(s)")) }
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        let (d, lm) = try out.get()
        return (d, lm)
    }

    private func download(_ s: String, to dest: URL, sha: String?) throws {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = session.downloadTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)) { t, r, e in
            defer { sem.signal() }
            if let e { failure = e; return }
            guard let h = r as? HTTPURLResponse, (200...299).contains(h.statusCode), let t else {
                failure = Failure(description: "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0) for \(s)"); return
            }
            try? FileManager.default.removeItem(at: part)
            do { try FileManager.default.moveItem(at: t, to: part) } catch { failure = error }
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        if let failure { try? fm.removeItem(at: part); throw failure }
        if let sha, AscensionChannel.sha256(of: part) != sha {
            try? fm.removeItem(at: part)
            throw Failure(description: "\(u.lastPathComponent) came down damaged (it does not hash to the pinned release).")
        }
        guard RetailClient.replaceable(dest) else { try? fm.removeItem(at: part); throw Failure(description: "\(dest.lastPathComponent) is a folder here; not replaced.") }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }
}
