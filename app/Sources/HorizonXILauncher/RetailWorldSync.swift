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

    /// Every file of `files` in place: kept when it already hashes right, copied from a donor that has
    /// it byte for byte, else `fetch`ed (a world that serves its own files) when there is one.
    /// `mayDiffer`: files a donor's copy of which is taken as it is when none matches.
    func assemble(_ files: [DriftwoodChannel.ClientFile], donors: [URL], build: String,
                  mayDiffer: Set<String> = RetailClient.mayDiffer,
                  fetch: ((DriftwoodChannel.ClientFile, URL) throws -> Void)? = nil) throws {
        log("==> \(world): checking the client against the list of \(files.count) files of \(fetch == nil ? "retail " : "")\(build)")
        let ffxi = game.appendingPathComponent("FINAL FANTASY XI")
        var kept = 0, copied = 0, fetched = 0, missing: [String] = []
        for (n, f) in files.enumerated() {
            if n % 500 == 0 {
                if stop.raised { throw Failure(description: "Stopped. Press the button again to carry on; nothing finished is lost.") }
                progress("Checking \(world)'s client", Double(n) / Double(files.count))
            }
            guard AscensionSync.safeRelative(f.path) else { throw Failure(description: "\(world)'s client list names an unsafe path: \(f.path)") }
            let key = keyPrefix + "FINAL FANTASY XI/" + f.path
            let dest = ffxi.appendingPathComponent(f.path)
            // A pool per file: stat results and copies are autoreleased, and this thread drains none.
            enum Got { case kept, copied, fetched, missing }
            let got: Got = try autoreleasepool {
                if hashes.verified(key, at: dest, sha: f.sha256) { return .kept }
                if f.size == 0 {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data().write(to: dest); hashes.record(key, at: dest, sha: f.sha256); return .copied
                }
                if copy(f, from: donors, to: dest, key: key, exact: true) { return .copied }
                if mayDiffer.contains(f.path.lowercased()),
                   fm.fileExists(atPath: dest.path) || copy(f, from: donors, to: dest, key: key, exact: false) { return .kept }
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
        log("==> \(world): \(kept) client files already right, \(copied) copied from other clients on this Mac, "
            + (fetch == nil ? "\(missing.count) missing" : "\(fetched) downloaded"))
        if !missing.isEmpty {
            throw Failure(description: "\(missing.count) of \(world)'s client files are not on this Mac (first: \(missing[0])). They come from "
                          + "retail FFXI on build \(build): install AscensionXI or Vanadreams first, which carry that build.")
        }
    }

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
        var plugins: [String] = ["thirdparty", "addons", "screenshot", "winefix"]
        /// A world whose server runs an older client than retail and hands out that client itself:
        /// the client comes from their archive instead of from retail files (`ClientArchive`).
        var archive: ClientArchive? = nil
        var loader: Loader { RetailWorld.loaders[loaderSeries]! }
    }

    /// The client a world publishes as one archive of a whole `FINAL FANTASY XI` folder, named on a
    /// wiki page: its MediaWiki API (`action=parse&prop=wikitext`).
    struct ClientArchive { var page: String }

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
                                archive: ClientArchive(page: "https://ffxileveldown.fandom.com/api.php?action=parse&page=Past_FFXI_Version_Repository&prop=wikitext&format=json"))

    static let mist = Spec(world: "MistXI", host: "play.mistxi.com", profile: "mistxi.ini", script: "mistxi.txt", loaderSeries: "2.1",
                           // MistXI's launcher deletes these from Ashita's bundle (GitHubAshitaService.cs `unwantedAddons`).
                           removedAddons: ["skeletonkey", "ahgo", "allmaps", "instantah", "instantchat", "paranormal"])
    static let moghouse = Spec(world: "Moghouse XI", host: "ffxi.cc", profile: "moghouse.ini", script: "moghouse.txt", loaderSeries: "2.2")
    static let all: [Spec] = [mist, moghouse, levelDown]
    static func spec(_ world: String) -> Spec? { all.first { $0.world == world } }

    static func profile(fromExample example: String, spec: Spec) -> String {
        var t = example
        for s in [BootProfile.Setting(section: "ashita.launcher", key: "name", value: spec.world),
                  BootProfile.Setting(section: "ashita.boot", key: "file", value: ".\\\\bootloader\\\\xiloader.exe"),
                  BootProfile.Setting(section: "ashita.boot", key: "command", value: "--server \(spec.host)"),
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
        // What the client is made from: retail's file list, or the world's own archive.
        var list: (data: Data, changed: Bool)?
        var archive: (version: String, fileID: String)?
        if let a = spec.archive {
            archive = (try? get(src.archivePage ?? a.page).data).flatMap { $0 }.flatMap(RetailWorld.wikitext).flatMap(RetailWorld.currentArchive)
        } else {
            list = try? fetchCached(src.retailList, cache: stateDir.appendingPathComponent("retail-list.json"))
        }
        if list == nil && archive == nil {
            try checkStop()
            if installedBefore { return .offline("\(spec.world)'s client list didn't load; playing with the files from the last update.") }
            if !client.present || ashitaMissing {
                throw Failure(description: spec.archive == nil
                    ? "The list of retail FFXI's files (xi.driftwoodgaming.com/api/manifest) didn't load. Try again in a few minutes."
                    : "\(spec.world)'s page naming their client version didn't load. Try again in a few minutes.")
            }
        }
        writeState(["finished": false])
        // 1. The client, when its source changed since it was last put together, on Setup/Repair, or
        // when it is not there.
        if let archive, install || !client.present || readState()["clientArchive"] as? String != archive.version {
            try installArchive(archive)
            writeState(["clientArchive": archive.version])
        }
        if let list {
            let listSHA = AscensionChannel.sha256(list.data)
            if install || !client.present || readState()["clientList"] as? String != listSHA {
                guard let files = DriftwoodChannel.parseClientManifest(list.data) else { throw Failure(description: "The retail file list could not be read.") }
                try client.assemble(files, donors: donors, build: DriftwoodChannel.clientBuild)
                writeState(["clientList": listSHA])
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
        writeState(["finished": true, "updated": ISO8601DateFormatter().string(from: Date())])
        return .ok(changed: changed + client.changed)
    }

    /// Their whole client, from the archive their page names: downloaded straight into this folder
    /// (resumed if stopped), unpacked with bsdtar (7-Zip included) without its `USER/` (another
    /// player's settings travel in it), then moved over `FINAL FANTASY XI`. Kept until a new version
    /// replaces it, so Repair unpacks it again without downloading.
    private func installArchive(_ a: (version: String, fileID: String)) throws {
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
                guard AscensionSync.isRegularFile(from) else { return }
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
            guard AscensionSync.isRegularFile(from) else { continue }
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

    /// A copy kept beside the client, asked for again with If-Modified-Since.
    private func fetchCached(_ s: String, cache: URL) throws -> (data: Data, changed: Bool) {
        let have = try? Data(contentsOf: cache)
        let since = have == nil ? nil : AscensionSync.httpDate((try? fm.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date)
        let (d, lm) = try get(s, ifModifiedSince: since)
        if let d {
            if (try? d.write(to: cache, options: .atomic)) != nil, let lm, let date = AscensionSync.parseHTTPDate(lm) {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: cache.path)
            }
            return (d, d != have)
        }
        guard let have else { throw Failure(description: "\(s): not modified, and no copy here") }
        return (have, false)
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
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }
}
