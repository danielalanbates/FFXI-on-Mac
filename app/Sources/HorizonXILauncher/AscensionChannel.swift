import Foundation
import CryptoKit

/// AscensionXI (ascensionffxi.com): their client, DATs, addons and loader, fetched the way their
/// own launcher fetches them, natively.
///
/// AscensionXI ships one Windows launcher (`AscensionXI.exe`, a .NET Framework WinForms app, GPL-3,
/// 3.6.0 when this was written on 2026-10-24) and nothing else: no zip link, no torrent, no retail
/// patch. Everything comes from their *update channel*, plain HTTP on port 54290, mirrored on two
/// hosts. Read out of that launcher (decompiled with ILSpy; see docs/ASCENSION.md for the whole
/// protocol), every Play does, in order:
///
///  1. **Base client**: `/base/client-manifest.json` (every file of a full client: 101,707 files,
///     28 GB, each with its SHA-256) with If-Modified-Since, and fetches what changed from
///     `/base/files/<path>`. A first install downloads `/base/AscensionXI-client.zip` (14.8 GB).
///  2. **Their DATs**: `/manifest.json` names the retail runtime it needs (FFXiMain.dll,
///     Ashita.dll, Ashita-cli.exe by SHA-256) and the ~560 DATs they changed, served from
///     `/dats/<path>` into the XIPivot overlay `Ashita/polplugins/DATs/ascensionxi-prod`.
///  3. **Addons**: `/addons/catalog.json`, every approved addon and plugin with its files, written
///     into `Ashita/addons`, `Ashita/plugins` and one fenced block of `scripts/default.txt`.
///  4. `pivot.ini`'s overlay list, and their loader (`ascensionxi-loader.exe`, LandSandBoat's
///     xiloader 2.1.2 plus "the website-only character menu policy") out of the launcher's own
///     resources into `Ashita/bootloader`.
///
/// This does the same steps, with three Mac-specific differences, each deliberate:
///
///  * **No 14.8 GB zip.** The base client is fetched file by file from both mirrors at once,
///    after copying every file that is byte-identical (same path, size and SHA-256) from the FFXI
///    clients already on this Mac. Most of a retail client never changes between patches: on
///    Daniel's Mac (2026-10-24) under 2,000 of the 66,783 files, about 1 GB of 14, had to come
///    from their channel; the rest matched files in the CatsEyeXI, Supernova and HorizonXI clients.
///  * **The optional packs are off** (their HD textures 11 GB, HD maps 2 GB, LoFi music 0.4 GB,
///    all on by default in their launcher). Not to save disk: HD textures multiply the game's
///    texture memory, and on an 8 GB Mac that memory is the frame rate. `launcher.json` in the
///    client root turns each back on, with their own key names (`hd`, `hdMaps`, `lofiMusic`).
///  * **Hashes are cached** (`.ffxi-on-mac/hashes.json`: size, modification time, SHA-256), so a
///    Play on a spinning drive does not re-read 400 MB of overlay every time. Every file is still
///    checked against the channel's SHA-256 before it is used or kept.
///
/// What it never does: run their .exe (it is read, as data, for the loader it carries), write
/// anything outside the client folder, or touch another world's files. Donor clients are only
/// read.
enum AscensionChannel {
    static let worldName = "AscensionXI"
    static let mirrors = ["http://dl.ascensionffxi.com:54290", "http://dl2.ascensionffxi.com:54290"]
    /// Their player profile (`Core.PlayerProfile`): the boot ini and the overlay folder it uses.
    static let bootProfile = "ascensionxi-prod-public.ini"
    static let overlay = "ascensionxi-prod"
    static let loaderName = "ascensionxi-loader.exe"
    static let launcherExe = "AscensionXI.exe"
    /// The XIPivot packs their base client carries, each optional (`LauncherSettings`).
    static let packs = ["ffxi-hd", "ffxi-maps", "ffxi-lofi"]
    /// What their launcher deletes from a player's client (`RetiredRootFiles`, `DevBootProfiles`).
    static let retiredRootFiles = ["AscensionXI-Dev.exe", "launcher.ps1", "AscensionXI-Local.cmd",
                                   "AscensionXI-Staging-LAN.cmd", "AscensionXI-Staging-Public.cmd",
                                   "AscensionXI-Prod-Tailscale.cmd", "AscensionXI-Prod-Public.cmd"]
    static let devBootProfiles = ["ascensionxi-dev.ini", "ascensionxi-staging.ini", "ascensionxi-remote.ini",
                                  "ascensionxi-prod-tailscale.ini", "ascensionxi-prod.ini"]
    /// The formats this was written against. Anything else is said once in launcher.log and still
    /// read: their launcher does not check these either, and the fields have stayed put so far.
    static let manifestVersion = 2, baseVersion = 1, catalogVersion = 1

    // MARK: - What the channel publishes

    struct FileEntry: Equatable {
        var path: String = ""      // a channel-relative path or an absolute URL (catalog files)
        var sha256: String
        var size: Int64
    }

    struct Manifest {
        var version: Int
        /// SHA-256 of the manifest's own text, to notice a release that changed mid-update.
        var contentHash: String
        var clientVersion: String?
        var runtimeFiles: [String: String] = [:]
        var launcher: [String: FileEntry] = [:]
        var files: [String: FileEntry] = [:]
        var filesHD: [String: FileEntry] = [:]
    }

    struct BaseManifest {
        var raw: Data
        var lastModified: String?
        var version: Int
        var revision: String
        var clientVersion: String
        var files: [String: FileEntry]
    }

    struct Catalog {
        struct Archive: Equatable { var url: String; var from: String; var into: String; var size: Int64 }
        struct Entry {
            var name: String
            var kind: String                 // "addon" or "plugin"
            var description = "", author = "", version = "", url = ""
            var defaultEnabled = false, required = false, defaultIgnoreUpdates = false
            var files: [String: FileEntry] = [:]
            var remove: [String] = []
            var archives: [Archive] = []
        }
        struct SwitchOff { var name: String; var kind: String; var reason: String }
        var version = 0
        var entries: [Entry] = []
        var switchOff: [SwitchOff] = []
        func find(_ name: String, kind: String) -> Entry? {
            entries.first { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    // MARK: - Parsing (pure)

    private static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    private static func string(_ d: [String: Any]?, _ k: String) -> String? {
        guard let v = d?[k], !(v is NSNull) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    private static func int64(_ d: [String: Any]?, _ k: String) -> Int64 {
        if let n = d?[k] as? NSNumber { return n.int64Value }
        return Int64(string(d, k) ?? "") ?? 0
    }
    /// `AsBool`: a JSON boolean, else the fallback (a 0/1 number is not a boolean there).
    private static func bool(_ d: [String: Any]?, _ k: String, _ fallback: Bool) -> Bool {
        guard let n = d?[k] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return fallback }
        return n.boolValue
    }
    private static func object(_ data: Data) -> [String: Any]? {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    private static func entries(_ raw: Any?, pathKey: String = "path") -> [String: FileEntry] {
        guard let raw = dict(raw) else { return [:] }
        var out: [String: FileEntry] = [:]
        for (k, v) in raw {
            let d = dict(v)
            out[k] = FileEntry(path: string(d, pathKey) ?? "", sha256: (string(d, "sha256") ?? "").lowercased(),
                               size: int64(d, "size"))
        }
        return out
    }

    static func parseManifest(_ data: Data) -> Manifest? {
        guard let o = object(data) else { return nil }
        var m = Manifest(version: Int(int64(o, "version")), contentHash: sha256(data))
        if let c = dict(o["compatibility"]) {
            m.clientVersion = string(c, "client_version") ?? ""
            for (k, v) in dict(c["runtime_files"]) ?? [:] { if let s = v as? String { m.runtimeFiles[k] = s } }
        } else if o["compatibility"] != nil {
            m.clientVersion = ""
        }
        m.launcher = entries(o["launcher"])
        m.files = entries(o["files"])
        m.filesHD = entries(o["files_hd"])
        return m
    }

    static func parseBase(_ data: Data, lastModified: String?) -> BaseManifest? {
        guard let o = object(data) else { return nil }
        return BaseManifest(raw: data, lastModified: lastModified, version: Int(int64(o, "version")),
                            revision: string(o, "revision") ?? "unknown",
                            clientVersion: string(o, "client_version") ?? "",
                            files: entries(o["files"]))
    }

    static func parseCatalog(_ data: Data) -> Catalog {
        var c = Catalog()
        guard let o = object(data) else { return c }
        c.version = Int(int64(o, "version"))
        for raw in (o["entries"] as? [Any]) ?? [] {
            guard let d = dict(raw), let name = string(d, "name"), !name.isEmpty else { continue }
            let kind = (string(d, "kind") ?? "addon").lowercased()
            guard kind == "addon" || kind == "plugin" else { continue }
            var e = Catalog.Entry(name: name, kind: kind)
            e.description = string(d, "description") ?? ""
            e.author = string(d, "author") ?? ""
            e.version = string(d, "version") ?? ""
            e.url = string(d, "url") ?? ""
            e.defaultEnabled = bool(d, "enabled", false)
            e.required = bool(d, "required", false)
            e.defaultIgnoreUpdates = bool(d, "ignoreUpdates", false)
            e.remove = ((d["remove"] as? [Any]) ?? []).map { "\($0)" }
            for (k, f) in entries(d["files"], pathKey: "url") where !f.path.isEmpty {
                e.files[k.replacingOccurrences(of: "\\", with: "/")] = f
            }
            for a in (d["archives"] as? [Any]) ?? [] {
                let ad = dict(a)
                guard let u = string(ad, "url"), !u.isEmpty, let from = string(ad, "from"), !from.isEmpty else { continue }
                e.archives.append(.init(url: u, from: from, into: string(ad, "into") ?? "", size: int64(ad, "size")))
            }
            c.entries.append(e)
        }
        for raw in (o["switchOff"] as? [Any]) ?? [] {
            guard let d = dict(raw), let name = string(d, "name"), !name.isEmpty else { continue }
            let kind = (string(d, "kind") ?? "addon").lowercased()
            guard kind == "addon" || kind == "plugin" else { continue }
            c.switchOff.append(.init(name: name, kind: kind, reason: string(d, "reason") ?? ""))
        }
        return c
    }

    /// Is `rel` (a base-manifest path) inside one of the optional packs?
    static func pack(of rel: String) -> String? {
        packs.first { rel.hasPrefix("Ashita/polplugins/DATs/\($0)/") }
    }

    // MARK: - Hashing

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA-256 of a file, 1 MB at a time; nil when it cannot be read.
    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = autoreleasepool { try? h.read(upToCount: 1 << 20) }
            guard let c = chunk, !c.isEmpty else { break }
            hasher.update(data: c)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Settings (their launcher.json keys)

    struct Settings: Equatable {
        var hd = false, hdMaps = false, lofiMusic = false
        /// `manageAddons`: false leaves addons and the boot script alone, as theirs does.
        var manageAddons = true
    }

    /// `<root>/launcher.json`, read with their key names; absent keys keep the Mac defaults.
    static func settings(in root: URL) -> Settings {
        var s = Settings()
        guard let d = try? Data(contentsOf: root.appendingPathComponent("launcher.json")), let o = object(d) else { return s }
        s.hd = bool(o, "hd", s.hd)
        s.hdMaps = bool(o, "hdMaps", s.hdMaps)
        s.lofiMusic = bool(o, "lofiMusic", s.lofiMusic)
        s.manageAddons = bool(o, "manageAddons", s.manageAddons)
        return s
    }

    /// Packs these settings want on disk (and in pivot.ini).
    static func wantedPacks(_ s: Settings) -> Set<String> {
        var p = Set<String>()
        if s.hd { p.insert("ffxi-hd") }
        if s.hdMaps { p.insert("ffxi-maps") }
        if s.lofiMusic { p.insert("ffxi-lofi") }
        return p
    }

    // MARK: - pivot.ini (RewritePivot)

    /// pivot.ini as their launcher writes it: `root_path` aimed at this client's DATs folder
    /// (`datsWine`, its Windows path under Wine), their overlays first in their order, then every
    /// overlay that is not theirs, as it was. `present` says which pack folders exist on disk.
    static func pivot(_ existing: String?, datsWine: String, settings s: Settings, present: Set<String>) -> String {
        var kept: [String] = []
        var foreign: [String] = []
        func ours(_ entry: String) -> Bool {
            let head = entry.split(whereSeparator: { $0 == "\\" || $0 == "/" }).first.map(String.init) ?? entry
            let h = head.lowercased()
            return head == "ascensionxi" || head.hasPrefix("ascensionxi-") || head == "vanaheim"
                || head.hasPrefix("vanaheim-") || h == "ffxi-hd" || h == "ffxi-maps" || h == "ffxi-lofi"
        }
        if let text = existing {
            var section = ""
            for line in TextFile.lines(of: text) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[") && t.hasSuffix("]") { section = String(t.dropFirst().dropLast()) }
                if section == "overlays" {
                    if let eq = line.firstIndex(of: "="), eq > line.startIndex {
                        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                        if !key.isEmpty, key.allSatisfy(\.isNumber) {
                            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                            if !ours(v) { foreign.append(v) }
                        }
                    }
                } else if line.drop(while: { $0 == " " || $0 == "\t" }).lowercased().hasPrefix("root_path"), line.contains("=") {
                    kept.append("root_path=" + datsWine)
                } else {
                    kept.append(line)
                }
            }
            // `File.ReadAllLines` drops the newline after the last line; our split keeps an empty
            // last element for it, which would add a blank line on every rewrite.
            if kept.last == "" { kept.removeLast() }
        } else {
            kept = ["[settings]", "root_path=" + datsWine, "debug_log=false", "redirect_fopens=true"]
        }
        var list: [String] = []
        if s.hd { list.append(overlay + "-hd") }
        list.append(overlay)
        if s.hdMaps, present.contains("ffxi-maps") { list.append("ffxi-maps\\1024x1024") }
        if s.hd, present.contains("ffxi-hd") { list.append("ffxi-hd") }
        if s.lofiMusic, present.contains("ffxi-lofi") { list.append("ffxi-lofi") }
        list += foreign
        var out = kept + ["[overlays]"]
        for (n, v) in list.enumerated() { out.append("\(n)=\(v)") }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - The boot profile's command (SetLoaderJson)

    /// `command` with any `--json`/`--json-file <file>` taken out, as their launcher leaves it
    /// between runs. This launcher passes the account with `--user`/`--pass` instead.
    static func commandWithoutJSON(_ command: String) -> String {
        var t = splitArgs(command)
        var i = 0
        while i < t.count {
            if t[i] == "--json" || t[i] == "--json-file" {
                t.remove(at: i)
                if i < t.count, !t[i].hasPrefix("--") { t.remove(at: i) }
            } else { i += 1 }
        }
        return t.map { $0.isEmpty || $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, has = false
        for c in s {
            if c == "\"" { quoted.toggle(); has = true }
            else if c.isWhitespace, !quoted { if has { out.append(cur) }; cur = ""; has = false }
            else { cur.append(c); has = true }
        }
        if has { out.append(cur) }
        return out
    }

    // MARK: - Addon policy

    /// "Addons supplied through the AscensionXI launcher are approved for use. If you want to use
    /// another addon, speak with an admin and get approval before using it." (ascensionffxi.com/rules,
    /// read 2026-10-24.) Supplied = their catalog's entries and what their base client ships.
    /// The snapshot is their catalog of 2026-10-24 plus the base client's addons; the live list
    /// is the catalog their channel served last (`addons-catalog.json` in the client root).
    static let snapshotNames: [String] = [
        "XIUI", "addons", "affinity", "aspect", "autojoin", "autologin", "autorespond", "axmap", "blucheck",
        "blumon", "blusets", "cartographer", "casper", "cfhblock", "chains", "chamcham", "changecall",
        "chatfix", "chatmon", "checker", "chime", "cleancs", "clearcolor", "clock", "config", "craftmon",
        "crosshair", "debuff", "distance", "dlac", "drawdistance", "easyTH", "enternity", "equipmon",
        "fastswap", "filterless", "filters", "filterscan", "find", "freemem", "gateway", "hardwaremouse",
        "hideconsole", "hideobs", "hideparty", "hideui", "ime", "imguistyle", "instantchat", "invmon",
        "itemwatch", "libs", "links", "logincmd", "logs", "macrofix", "mapdot", "minimap", "minimapmon",
        "mipmap", "mobdb", "move", "namecolors", "nameplate", "nexus", "nolock", "noname", "onevent",
        "packetflow", "paranormal", "petinfo", "pivot", "points", "quicksets", "recast", "renamer",
        "sandbox", "screenshot", "sellit", "sexchange", "shorthand", "simplelog", "singlerace", "stfu",
        "tTimers", "targetlines", "thirdparty", "timestamp", "tokens", "toon", "tparty", "trimspells",
        "truefps", "truesight", "winefix",
    ]

    private static var policyCache: (key: String, policy: AddonPolicy)?
    private static let policyLock = NSLock()

    static func addonPolicy(clientRoot: String) -> AddonPolicy {
        let source = "AscensionXI's launcher catalog (their rules: addons it supplies are approved)"
        let cached = URL(fileURLWithPath: clientRoot).appendingPathComponent("addons-catalog.json")
        let attrs = clientRoot.isEmpty ? nil : try? FileManager.default.attributesOfItem(atPath: cached.path)
        let key = "\(cached.path)#\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        policyLock.lock(); defer { policyLock.unlock() }
        if let c = policyCache, c.key == key { return c.policy }
        var names = snapshotNames
        if attrs != nil, let d = try? Data(contentsOf: cached) {
            let cat = parseCatalog(d)
            if !cat.entries.isEmpty { names = Array(Set(cat.entries.map(\.name) + baseShipped)) }
        }
        let p = AddonPolicy.allowlist(published: names, source: source)
        policyCache = (key, p)
        return p
    }

    /// Every other world's client on this Mac, as the folder holding its `FINAL FANTASY XI` and
    /// `PlayOnlineViewer`: where identical retail files are copied from instead of downloaded.
    /// The local world plays HorizonXI's client and adds nothing.
    @MainActor static func donorClients(_ servers: [Server], base: Install) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = [], seen = Set<String>()
        for s in servers where !s.local && (!s.dataPath.isEmpty || s.name == "HorizonXI") {
            let se = base.forServer(s).squareEnix
            guard fm.fileExists(atPath: se.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll").path) else { continue }
            if seen.insert(se.resolvingSymlinksInPath().path).inserted { out.append(se) }
        }
        return out
    }

    /// Addons and plugins their base client itself ships (not all are in the catalog).
    static let baseShipped = ["chatfix", "libs", "pivot", "sandbox", "quicky", "extraslots"]
}

// MARK: - The fenced block of scripts/default.txt (AddonScript)

/// Their launcher owns one block of the boot script:
///
///     # ===== AscensionXI addons BEGIN - the launcher rewrites this block; change it on the launcher's Addons page =====
///     /load <plugin>
///     /addon load <addon>
///     # ===== AscensionXI addons END =====
///
/// Every `/load` and `/addon load` line anywhere in the file belongs to it: reading collects them
/// all (once each, case-insensitive), writing puts them all in the block, at the first place one
/// was, and leaves every other line where it was. A byte-for-byte port, so both launchers can edit
/// the same file in turn and agree.
struct AscensionScript {
    static let fenceBegin = "# ===== AscensionXI addons BEGIN - the launcher rewrites this block; change it on the launcher's Addons page ====="
    static let fenceEnd = "# ===== AscensionXI addons END ====="
    static let fencePrefix = "# ===== AscensionXI addons"

    private(set) var plugins: [String] = []
    private(set) var addons: [String] = []
    private var others: [String] = []
    private var blockAt = -1
    let newline: String
    let original: String
    let existed: Bool

    static func hasFence(_ text: String) -> Bool { text.contains(fencePrefix) }

    init(_ text: String?) {
        existed = text != nil
        original = text ?? ""
        newline = original.contains("\r\n") || !original.contains("\n") ? "\r\n" : "\n"
        // Split on the "\n" code unit, as `Split('\n')` does: Swift's own `split` sees "\r\n" as one
        // Character and would not split a CRLF script at all (see TextFile).
        let lines = original.isEmpty ? [] : original.components(separatedBy: "\n")
        for (n, raw) in lines.enumerated() {
            var line = raw
            while line.hasSuffix("\r") { line.removeLast() }
            if n == lines.count - 1, line.isEmpty { break }
            if line.hasPrefix(Self.fencePrefix) { place(); continue }
            if let p = Self.match(line, prefix: "/load") { place(); Self.add(&plugins, p); continue }
            if let a = Self.match(line, prefix: "/addon load") { place(); Self.add(&addons, a); continue }
            others.append(line)
        }
        if blockAt < 0 {
            blockAt = 0
            while blockAt < others.count,
                  others[blockAt].trimmingCharacters(in: .whitespaces).isEmpty
                    || others[blockAt].drop(while: \.isWhitespace).hasPrefix("#") {
                blockAt += 1
            }
        }
    }

    /// `^\s*/load\s+(\S+)\s*$` (and the addon one), case-insensitive.
    private static func match(_ line: String, prefix: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let words = t.split(whereSeparator: \.isWhitespace).map(String.init)
        let pw = prefix.split(separator: " ").map(String.init)
        guard words.count == pw.count + 1,
              zip(words, pw).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) else { return nil }
        // `\s+` between the words of the prefix: "/addon   load x" matches, "/addonload x" does not.
        return words.last
    }

    private mutating func place() { if blockAt < 0 { blockAt = others.count } }
    private static func add(_ list: inout [String], _ name: String) {
        if !list.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { list.append(name) }
    }

    func isEnabled(kind: String, _ name: String) -> Bool {
        (kind == "plugin" ? plugins : addons).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
    mutating func enable(kind: String, _ name: String) {
        if kind == "plugin" { Self.add(&plugins, name) } else { Self.add(&addons, name) }
    }
    mutating func disable(kind: String, _ name: String) {
        if kind == "plugin" { plugins.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame } }
        else { addons.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }
    /// Take every line equal to `line` out; true when there was one.
    @discardableResult
    mutating func removeLine(_ line: String) -> Bool {
        var removed = false
        var n = others.count - 1
        while n >= 0 {
            if others[n] == line {
                others.remove(at: n)
                if n < blockAt { blockAt -= 1 }
                removed = true
            }
            n -= 1
        }
        return removed
    }

    private var block: [String] {
        [Self.fenceBegin] + plugins.map { "/load " + $0 } + addons.map { "/addon load " + $0 } + [Self.fenceEnd]
    }

    func render() -> String {
        var out: [String] = []
        for (n, l) in others.enumerated() {
            if n == blockAt { out += block }
            out.append(l)
        }
        if blockAt >= others.count { out += block }
        return out.joined(separator: newline) + newline
    }

    /// The text to write, or nil when nothing changed.
    var changed: String? {
        let r = render()
        return existed && r == original ? nil : r
    }
}
