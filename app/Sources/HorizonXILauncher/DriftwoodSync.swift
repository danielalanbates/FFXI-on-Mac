import Foundation

/// DriftwoodXI (xi.driftwoodgaming.com, LandSandBoat, xiloader 2.1.x): retail FFXI on the build their
/// server takes, their Ashita bundle, its core updates and their 33 addons, the way their own
/// launcher keeps them, natively.
///
/// Read from their launcher (Electron 0.36.15, its AppImage's app.asar), their Linux guide
/// (/download/linux) and their public content repo (github.com/DriftwoodGaming/DriftwoodXI-Content),
/// 2026-10-24; the research is in docs/DRIFTWOOD.md:
///
///  * **No game files from them** ("No game files come from us, on any platform"): the player brings
///    retail FFXI on build 30260904_1. They publish the list of every file of that client with its
///    SHA-256 (`/api/manifest`, 65,053 files). Here the client is assembled from files byte-identical
///    to that list in other worlds' clients on this Mac (AscensionXI's and Vanadreams' are the same
///    retail build), the way AscensionSync uses donors. `patch2.cfg`, a patch-history file the
///    server never sees, is the one file allowed to differ (it does between their client and every
///    other one checked).
///  * **Ashita**: `ashita.json`'s bundle (44 MB, SHA-256 published) into `Ashita/`, then its `core`
///    (14 files with their own hashes) whenever one of them differs. Their zips name entries with
///    backslashes, which `ditto` keeps as literal names; `bsdtar` converts them.
///  * **Addons**: `content.json`'s packages (`addons/<id>/`, `dwgmpanel` never: staff tooling), each
///    checked by its zip's SHA-256 and by the folder's `treeHash` (sha256 over "path\0size\0sha256\n"
///    of every file, lower-cased paths in order; verified against `dwah` 2026-10-24). An entry file
///    with only LuaJITGuard's lines in front counts as current.
///  * **Profile and script** as their Linux guide writes them: `config/boot/driftwood.ini` from Ashita's
///    `example-privateserver.ini` (`--server xi.driftwoodgaming.com`, `script = driftwood.txt`) and
///    `scripts/driftwood.txt` loading their 33 dw* addons. The bundle's own `default.txt` (bigmode,
///    which throws on their Ashita; fps; multisend) and `pivot.ini` (a developer's E:\ paths) are not used.
///
/// Not ported: their `driftwood-core` DAT text overlay, built on the player's machine from item DATs by
/// a parser that exists only inside their launcher. Without it, by their own Linux guide, job capes
/// show donor names, augment strings are blank and DWPolitics titles are missing: cosmetic.
enum DriftwoodChannel {
    static let worldName = "DriftwoodXI"
    static let host = "xi.driftwoodgaming.com"
    static let site = "https://xi.driftwoodgaming.com"
    static let bootProfile = "driftwood.ini"
    static let scriptName = "driftwood.txt"
    static let clientBuild = "30260904_1"
    static let content = "https://raw.githubusercontent.com/DriftwoodGaming/DriftwoodXI-Content/main/"
    static let neverInstalled: Set<String> = ["dwgmpanel"]
    /// The one client file allowed to differ from their list (see the type's notes).
    static let mayDiffer: Set<String> = ["patch2.cfg"]
    /// Plugins their scripts load besides `addons` (their Linux guide's step 4).
    static let plugins = ["thirdparty", "addons", "screenshot", "winefix"]

    struct Sources {
        var manifest = DriftwoodChannel.site + "/api/manifest"
        var ashita = DriftwoodChannel.content + "ashita.json"
        var content = DriftwoodChannel.content + "content.json"
    }

    struct ClientFile { var path: String; var size: Int64; var sha256: String }

    static func parseClientManifest(_ d: Data) -> [ClientFile]? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let files = o["files"] as? [Any] else { return nil }
        let out = files.compactMap { raw -> ClientFile? in
            guard let f = raw as? [String: Any], let p = f["path"] as? String, let h = f["sha256"] as? String else { return nil }
            return ClientFile(path: p.replacingOccurrences(of: "\\", with: "/"), size: (f["size"] as? NSNumber)?.int64Value ?? -1, sha256: h.lowercased())
        }
        return out.isEmpty ? nil : out
    }

    struct Bundle { var version: String; var url: String; var sha256: String; var core: Core? }
    struct Core { var version: String; var url: String; var sha256: String; var files: [ClientFile] }

    static func parseAshita(_ d: Data) -> Bundle? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let url = o["url"] as? String, let sha = o["sha256"] as? String else { return nil }
        var core: Core?
        if let c = o["core"] as? [String: Any], let cu = c["url"] as? String, let cs = c["sha256"] as? String {
            let files = ((c["files"] as? [Any]) ?? []).compactMap { raw -> ClientFile? in
                guard let f = raw as? [String: Any], let p = f["path"] as? String, let h = f["sha256"] as? String else { return nil }
                return ClientFile(path: p.replacingOccurrences(of: "\\", with: "/"), size: (f["size"] as? NSNumber)?.int64Value ?? -1, sha256: h.lowercased())
            }
            core = Core(version: (c["version"] as? String) ?? "", url: cu, sha256: cs.lowercased(), files: files)
        }
        return Bundle(version: (o["version"] as? String) ?? "", url: url, sha256: sha.lowercased(), core: core)
    }

    /// Where a core file may go (their `ASHITA_CORE_PATH`): Ashita.dll, Ashita-cli.exe,
    /// config/ashita/*.ini, plugins/*.dll, polplugins/*.dll. Anything else in a core list is ignored.
    static func coreFileAllowed(_ p: String) -> Bool {
        let parts = p.split(separator: "/").map(String.init)
        guard AscensionSync.safeRelative(p) else { return false }
        if parts.count == 1 { return p == "Ashita.dll" || p == "Ashita-cli.exe" }
        if parts.count == 3, parts[0] == "config", parts[1] == "ashita" { return p.lowercased().hasSuffix(".ini") }
        if parts.count == 2, parts[0] == "plugins" || parts[0] == "polplugins" { return p.lowercased().hasSuffix(".dll") }
        return false
    }

    struct Package { var id: String; var version: String; var url: String; var sha256: String; var treeHash: String }

    static func parseContent(_ d: Data) -> [Package]? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let ps = o["packages"] as? [Any] else { return nil }
        return ps.compactMap { raw in
            guard let p = raw as? [String: Any], let id = p["id"] as? String, AscensionChannel.safeAddonName(id),
                  (p["kind"] as? String ?? "ashita-addon") == "ashita-addon",
                  let url = p["url"] as? String, let sha = p["sha256"] as? String, let th = p["treeHash"] as? String else { return nil }
            return Package(id: id, version: (p["version"] as? String) ?? "", url: url, sha256: sha.lowercased(), treeHash: th.lowercased())
        }
    }

    /// Their `hashTree` over a folder. The addon's own entry file is read without LuaJITGuard's lines.
    static func treeHash(of dir: URL, entry: String? = nil) -> String? {
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: dir.path) else { return nil }
        var files: [(String, URL)] = []
        for case let rel as String in walk {
            let u = dir.appendingPathComponent(rel)
            guard AscensionSync.isRegularFile(u), !rel.hasSuffix(".driftwood-content.json") else { continue }
            files.append((rel.lowercased(), u))
        }
        files.sort { $0.0 < $1.0 }
        var acc = Data()
        for (rel, u) in files {
            guard var d = try? Data(contentsOf: u) else { return nil }
            if let e = entry, rel == e.lowercased(), let bare = AscensionSync.withoutJITGuard(d) { d = bare }
            acc += Data(rel.utf8) + Data([0]) + Data(String(d.count).utf8) + Data([0]) + Data(AscensionChannel.sha256(d).utf8) + Data([0x0A])
        }
        return AscensionChannel.sha256(acc)
    }

    static func profile(fromExample example: String) -> String {
        var t = example
        for s in [BootProfile.Setting(section: "ashita.launcher", key: "name", value: "DriftwoodXI"),
                  BootProfile.Setting(section: "ashita.boot", key: "file", value: ".\\\\bootloader\\\\xiloader.exe"),
                  BootProfile.Setting(section: "ashita.boot", key: "command", value: "--server \(host)"),
                  BootProfile.Setting(section: "ashita.boot", key: "script", value: scriptName)] {
            t = BootProfile.setting(s, in: t)
        }
        return t
    }

    static func script(addons: [String]) -> String {
        var lines = ["# DriftwoodXI startup script, written by FFXI on Mac the way their Linux guide does it.",
                     "# Their addons load below; Addons… switches them."]
        lines += plugins.map { "/load \($0)" }
        lines += addons.map { "/addon load \($0)" }
        lines += ["", "/wait 3", "/bind insert /ashita", "/bind SYSRQ /screenshot hide", "/bind $^v /paste", ""]
        return lines.joined(separator: "\r\n")
    }

    /// Their published allowlist (xi.driftwoodgaming.com/addons, 158 entries, 2026-10-24):
    /// "On this page means allowed ... Not on this page means not allowed."
    static let allowed: [String] = """
    dwah dwbags dwcon dwcpx dwcraft dwengage dwfame dwfishing dwmerits dwtoau dwgambits dwjobs dwarena dwnemesis dwunleashed \
    dwhub dwspoils dwtod dwchat dwesper dwpolitics dwleaderboard dwmacro dwmerc dwparse dwport dwquest dwraid dwreport dwscan \
    dwsquad dwtracker dwwarehouse HXUI XIUI xivbar statustimers timers tTimers recast partybuffs tparty distance targetlines \
    crosshair clock zonename move imguistyle hideui hideparty hideconsole cleancs minimapmon mapdot partyfinder FancyTrusts \
    GlamourUI trainmon Balloon minimap Nameplate actionparse simplelog checker mobdb chains petinfo easyTH LootScope TrackMeBooty \
    RollTracker blumon geocompass filterscan points gainz ventures sparks luashitacast LegacyAC equipmon invmon itemwatch find \
    FindAll blucheck blusets pupsets trimspells quicksets fastswap macrofix Shorthand Sequencer tHotBar Upcast timestamp filters \
    filterless chatfix instantchat stfu tokens logs links ime customcolors namecolors chatmon chime changecall autorespond Fancychat \
    enternity stepdialog instantah ahgo ahcolors allmaps cartographer sellit craftmon autojoin cfhblock debuff casper nolock \
    ButterFeet config VanaCompass Multisend activemon autologin logincmd hideobs xicamera noname renamer chamcham clearcolor \
    singlerace sexchange bigmode NoMount toon screenshot XIPivot fps freemem affinity aspect drawdistance mipmap addons thirdparty \
    hardwaremouse winefix
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    /// On their list, but their launcher never loads them (`BLOCKED_LOAD_REASONS`): bigmode "throws on
    /// load against the Ashita build this server ships"; chatfix "eats the first letter of every line
    /// the server says and misaddresses your tells".
    static let blockedLoads: Set<String> = ["bigmode", "chatfix"]

    static let addonPolicy = AddonPolicy.allowlist(published: allowed.filter { !blockedLoads.contains($0.lowercased()) },
        source: "DriftwoodXI's allowed list, xi.driftwoodgaming.com/addons (checked 2026-10-24), less the two their launcher blocks")
}

final class DriftwoodSync: @unchecked Sendable {
    typealias Outcome = AscensionSync.Outcome
    struct Failure: Error, CustomStringConvertible { let description: String }

    let root: URL
    private let src: DriftwoodChannel.Sources
    private let stop: StopFlag
    private let log: (String) -> Void
    private let progress: (String, Double) -> Void
    private let session: URLSession
    private let fm = FileManager.default
    private let hashes: HashCache
    private var changed = 0
    private var ashita: URL { root.appendingPathComponent("Ashita") }
    private var game: URL { root.appendingPathComponent("Game") }
    private var stateDir: URL { root.appendingPathComponent(".ffxi-on-mac") }
    private var stateURL: URL { stateDir.appendingPathComponent("driftwood.json") }

    init(root: URL, sources: DriftwoodChannel.Sources = .init(), stop: StopFlag = StopFlag(),
         log: @escaping (String) -> Void, progress: @escaping (String, Double) -> Void = { _, _ in }) {
        self.root = root; src = sources; self.stop = stop; self.log = log; self.progress = progress
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.httpAdditionalHeaders = ["User-Agent": "FFXI-on-Mac (DriftwoodXI client)"]
        session = URLSession(configuration: c)
        hashes = HashCache(url: root.appendingPathComponent(".ffxi-on-mac/hashes.json"))
    }

    func run(install: Bool = false, donors: [URL] = []) -> Outcome {
        defer { hashes.save() }
        hashes.trustStamps = !install
        var outcome: Outcome
        do { outcome = try steps(install: install, donors: donors) }
        catch let f as Failure { outcome = .failed(f.description) }
        catch { outcome = .failed("DriftwoodXI update failed: \(error.localizedDescription)") }
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
        // Their lists first; with none of them answering, a client that finished its last update plays.
        let manifestCopy = stateDir.appendingPathComponent("client-manifest.json")
        let gotManifest = try? fetchCached(src.manifest, cache: manifestCopy)
        guard let bundleData = try? get(src.ashita), let bundle = DriftwoodChannel.parseAshita(bundleData),
              let contentData = try? get(src.content), let packages = DriftwoodChannel.parseContent(contentData) else {
            try checkStop()
            if installedBefore { return .offline("DriftwoodXI's update lists didn't load; playing with the files from the last update.") }
            throw Failure(description: "DriftwoodXI's update lists (github.com/DriftwoodGaming/DriftwoodXI-Content) didn't load. Try again in a few minutes.")
        }
        writeState(["finished": false])
        // 1. The retail client, when their list is not the one it was last put together from, on
        // Setup/Repair, or when it is not there.
        let clientMissing = !fm.fileExists(atPath: game.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll").path)
        if let m = gotManifest {
            let listSHA = AscensionChannel.sha256(m.data)
            if install || clientMissing || readState()["clientList"] as? String != listSHA {
                guard let files = DriftwoodChannel.parseClientManifest(m.data) else { throw Failure(description: "DriftwoodXI's client list could not be read.") }
                try assembleClient(files, donors: donors)
                writeState(["clientList": listSHA])
            }
        } else if clientMissing {
            throw Failure(description: "DriftwoodXI's client list didn't load, and there is no client here yet.")
        }
        try ensureViewer(donors: donors)
        try checkStop()
        // 2. Ashita and its core.
        if install || !fm.fileExists(atPath: ashita.appendingPathComponent("Ashita-cli.exe").path) {
            log("==> DriftwoodXI: their Ashita bundle \(bundle.version)")
            try unpackZip(bundle.url, sha: bundle.sha256, into: ashita, strip: false)
            changed += 1
        }
        if let core = bundle.core { try applyCore(core) }
        try checkStop()
        // 3. Their addons.
        var firstSeen: [String] = []
        let seen = Set(readState()["seen"] as? [String] ?? [])
        for (n, p) in packages.enumerated() where !DriftwoodChannel.neverInstalled.contains(p.id) {
            try checkStop()
            progress("Updating DriftwoodXI's addons", Double(n) / Double(max(packages.count, 1)))
            let dir = ashita.appendingPathComponent("addons/\(p.id)")
            if DriftwoodChannel.treeHash(of: dir, entry: "\(p.id).lua") != p.treeHash {
                try installPackage(p, into: dir)
                changed += 1
            }
            if !seen.contains(p.id) { firstSeen.append(p.id) }
        }
        writeState(["seen": Array(seen.union(firstSeen)).sorted()])
        // 4. Profile, script, pivot.ini.
        try writeProfile()
        let script = ashita.appendingPathComponent("scripts/\(DriftwoodChannel.scriptName)")
        let ids = packages.map(\.id).filter { !DriftwoodChannel.neverInstalled.contains($0) }
        if !fm.fileExists(atPath: script.path) {
            try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DriftwoodChannel.script(addons: ids).write(to: script, atomically: true, encoding: .utf8)
        } else if !firstSeen.isEmpty, !seen.isEmpty, let text = try? String(contentsOf: script, encoding: .utf8) {
            // A package new in their list goes on once, as their launcher's default set takes it,
            // after the script's last addon line.
            let add = firstSeen.filter { id in !text.lowercased().contains("/addon load \(id.lowercased())") }
            if !add.isEmpty {
                var lines = TextFile.lines(of: text)
                let at = (lines.lastIndex { $0.lowercased().hasPrefix("/addon load ") } ?? lines.lastIndex { $0.hasPrefix("/load ") }).map { $0 + 1 } ?? lines.count
                lines.insert(contentsOf: add.map { "/addon load \($0)" }, at: at)
                try TextFile.join(lines, terminator: TextFile.terminator(of: text)).write(to: script, atomically: true, encoding: .utf8)
                log("i  DriftwoodXI: \(add.joined(separator: ", ")) switched on (new in their list)")
            }
        }
        // The bundle's pivot.ini names a developer's E:\ folder and overlays this client does not have.
        let pivot = ashita.appendingPathComponent("config/pivot/pivot.ini")
        let clean = "[settings]\r\ndebug_log = false\r\n\r\n[overlays]\r\n"
        if let t = try? String(contentsOf: pivot, encoding: .utf8), t.contains("E:\\") || t.lowercased().contains("catseyexi") {
            try clean.write(to: pivot, atomically: true, encoding: .utf8)
        }
        try checkStop()
        writeState(["finished": true, "bundle": bundle.version, "core": bundle.core?.version ?? "",
                    "updated": ISO8601DateFormatter().string(from: Date())])
        return .ok(changed: changed)
    }

    // MARK: - The client

    private func assembleClient(_ files: [DriftwoodChannel.ClientFile], donors: [URL]) throws {
        log("==> DriftwoodXI: checking the client against their list of \(files.count) files (build \(DriftwoodChannel.clientBuild))")
        let ffxi = game.appendingPathComponent("FINAL FANTASY XI")
        var kept = 0, copied = 0, missing: [String] = []
        for (n, f) in files.enumerated() {
            if n % 500 == 0 { try checkStop(); progress("Checking DriftwoodXI's client", Double(n) / Double(files.count)) }
            guard AscensionSync.safeRelative(f.path) else { throw Failure(description: "DriftwoodXI's client list names an unsafe path: \(f.path)") }
            let key = "Game/FINAL FANTASY XI/" + f.path
            let dest = ffxi.appendingPathComponent(f.path)
            if hashes.verified(key, at: dest, sha: f.sha256) { kept += 1; continue }
            if copy(f, from: donors, to: dest, key: key, exact: true) { copied += 1; changed += 1; continue }
            if DriftwoodChannel.mayDiffer.contains(f.path.lowercased()) {
                if fm.fileExists(atPath: dest.path) || copy(f, from: donors, to: dest, key: key, exact: false) { kept += 1; continue }
            }
            missing.append(f.path)
        }
        hashes.save()
        log("==> DriftwoodXI: \(kept) client files already right, \(copied) copied from other clients on this Mac, \(missing.count) missing")
        if !missing.isEmpty {
            throw Failure(description: "\(missing.count) of DriftwoodXI's client files are not on this Mac (first: \(missing[0])). They come from "
                          + "retail FFXI on build \(DriftwoodChannel.clientBuild): install AscensionXI or Vanadreams first, which carry that build.")
        }
    }

    /// The donor the last copied file came from: tried first, since a client is mostly one build.
    private var lastDonor: URL?

    /// A donor's copy of `f` into `dest`, hashed after copying. `exact: false` takes any same-path file.
    private func copy(_ f: DriftwoodChannel.ClientFile, from donors: [URL], to dest: URL, key: String, exact: Bool) -> Bool {
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        let order = lastDonor.map { l in [l] + donors.filter { $0 != l } } ?? donors
        for d in order {
            let c = d.appendingPathComponent("FINAL FANTASY XI").appendingPathComponent(f.path)
            guard AscensionSync.isRegularFile(c) else { continue }
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

    /// PlayOnline Viewer beside the game (their launcher takes it as FINAL FANTASY XI's sibling). Not in
    /// their list; copied whole when missing, from a donor on the same build: the one the client's
    /// files came from, else one whose FFXiMain.dll is this client's.
    private func ensureViewer(donors: [URL]) throws {
        let viewer = game.appendingPathComponent("PlayOnlineViewer")
        guard !fm.fileExists(atPath: viewer.appendingPathComponent("viewer/com/polcore.dll").path) else { return }
        let main = AscensionChannel.sha256(of: game.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll"))
        let sameBuild = donors.filter { main != nil && AscensionChannel.sha256(of: $0.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll")) == main }
        let order = (lastDonor.map { [$0] } ?? []) + sameBuild + donors
        guard let from = order.map({ $0.appendingPathComponent("PlayOnlineViewer") })
                .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("viewer/com/polcore.dll").path) }) else {
            throw Failure(description: "No PlayOnline Viewer on this Mac to copy for DriftwoodXI. Install AscensionXI or Vanadreams first.")
        }
        log("==> DriftwoodXI: PlayOnline Viewer from \(from.deletingLastPathComponent().path)")
        try? fm.removeItem(at: viewer)
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try fm.copyItem(at: from, to: viewer)
        changed += 1
    }

    // MARK: - Ashita

    private func applyCore(_ core: DriftwoodChannel.Core) throws {
        let stale = core.files.filter { DriftwoodChannel.coreFileAllowed($0.path)
            && !hashes.verified("Ashita/" + $0.path, at: ashita.appendingPathComponent($0.path), sha: $0.sha256) }
        guard !stale.isEmpty else { return }
        log("==> DriftwoodXI: Ashita core \(core.version) (\(stale.count) file\(stale.count == 1 ? "" : "s"))")
        let tmp = stateDir.appendingPathComponent("tmp/core-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try unpackZip(core.url, sha: core.sha256, into: tmp, strip: false)
        for f in stale {
            let from = tmp.appendingPathComponent(f.path)
            guard AscensionSync.isRegularFile(from), AscensionChannel.sha256(of: from) == f.sha256 else {
                throw Failure(description: "DriftwoodXI's Ashita core zip does not hold \(f.path) as listed.")
            }
            let to = ashita.appendingPathComponent(f.path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.moveItem(at: from, to: to)
            hashes.record("Ashita/" + f.path, at: to, sha: f.sha256)
            changed += 1
        }
    }

    private func installPackage(_ p: DriftwoodChannel.Package, into dir: URL) throws {
        let tmp = stateDir.appendingPathComponent("tmp/pkg-\(p.id)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try unpackZip(p.url, sha: p.sha256, into: tmp, strip: false)
        // The package's own folder is `<id>/` inside the zip.
        let inner = tmp.appendingPathComponent(p.id)
        let folder = fm.fileExists(atPath: inner.path) ? inner : tmp
        guard DriftwoodChannel.treeHash(of: folder) == p.treeHash else {
            throw Failure(description: "DriftwoodXI's \(p.id) package does not match its listed contents.")
        }
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: dir)
        let stamp = #"{"id":"\#(p.id)","version":"\#(p.version)","treeHash":"\#(p.treeHash)"}"#
        try? stamp.write(to: dir.appendingPathComponent(".driftwood-content.json"), atomically: true, encoding: .utf8)
        log("i  DriftwoodXI: \(p.id) \(p.version)")
    }

    private func writeProfile() throws {
        let ini = ashita.appendingPathComponent("config/boot/\(DriftwoodChannel.bootProfile)")
        guard !fm.fileExists(atPath: ini.path) else { return }
        let boot = ashita.appendingPathComponent("config/boot")
        guard let example = ["example-privateserver.ini", "example.ini"].lazy
                .compactMap({ try? String(contentsOf: boot.appendingPathComponent($0), encoding: .utf8) }).first else {
            throw Failure(description: "Ashita's example profiles are missing from DriftwoodXI's Ashita. Press Repair.")
        }
        try DriftwoodChannel.profile(fromExample: example).write(to: ini, atomically: true, encoding: .utf8)
    }

    // MARK: - HTTP and zips

    private func get(_ s: String, ifModifiedSince: String? = nil) throws -> Data? {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let ims = ifModifiedSince { req.setValue(ims, forHTTPHeaderField: "If-Modified-Since") }
        let sem = DispatchSemaphore(value: 0)
        var out: Result<(Data?, HTTPURLResponse), Error> = .failure(Failure(description: "no answer from \(s)"))
        let task = session.dataTask(with: req) { d, r, e in
            if let e { out = .failure(e) }
            else if let h = r as? HTTPURLResponse {
                if h.statusCode == 304 { out = .success((nil, h)) }
                else if (200...299).contains(h.statusCode) { out = .success((d ?? Data(), h)) }
                else { out = .failure(Failure(description: "HTTP \(h.statusCode) for \(s)")) }
            }
            sem.signal()
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        let (d, h) = try out.get()
        lastModified = h.value(forHTTPHeaderField: "Last-Modified")
        return d
    }
    private var lastModified: String?

    /// A copy kept beside the client, asked for again with If-Modified-Since.
    private func fetchCached(_ s: String, cache: URL) throws -> (data: Data, changed: Bool) {
        let have = try? Data(contentsOf: cache)
        let since = have == nil ? nil : AscensionSync.httpDate((try? fm.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date)
        if let d = try get(s, ifModifiedSince: since) {
            if let lm = lastModified, let date = AscensionSync.parseHTTPDate(lm), (try? d.write(to: cache, options: .atomic)) != nil {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: cache.path)
            }
            return (d, d != have)
        }
        guard let have else { throw Failure(description: "\(s): not modified, and no copy here") }
        return (have, false)
    }

    /// Download a zip (checked against `sha`), unpack it with bsdtar (their zips name entries with
    /// backslashes, which ditto keeps literally) and merge it into `dest`.
    private func unpackZip(_ s: String, sha: String, into dest: URL, strip: Bool) throws {
        guard let u = URL(string: s) else { throw Failure(description: "bad URL \(s)") }
        let tmp = stateDir.appendingPathComponent("tmp/zip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("a.zip")
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = session.downloadTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)) { t, r, e in
            defer { sem.signal() }
            if let e { failure = e; return }
            guard let h = r as? HTTPURLResponse, (200...299).contains(h.statusCode), let t else { failure = Failure(description: "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0) for \(s)"); return }
            do { try FileManager.default.moveItem(at: t, to: zip) } catch { failure = error }
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        if let failure { throw failure }
        guard AscensionChannel.sha256(of: zip) == sha else { throw Failure(description: "\(u.lastPathComponent) came down damaged") }
        let out = tmp.appendingPathComponent("x")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        // -P is never passed: bsdtar refuses absolute paths and "..", and keeps every entry under out.
        p.arguments = ["-xf", zip.path, "-C", out.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(description: "\(u.lastPathComponent) could not be unpacked (bsdtar \(p.terminationStatus))") }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let walk = fm.enumerator(atPath: out.path) else { return }
        for case let rel as String in walk {
            let from = out.appendingPathComponent(rel), to = dest.appendingPathComponent(rel)
            guard AscensionSync.isRegularFile(from) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.moveItem(at: from, to: to)
        }
    }
}
