import Foundation

/// Locating and describing a Sikarugir/Kegworks-style wine wrapper that holds the HorizonXI prefix.
struct Install: Identifiable, Hashable {
    let wrapper: URL          // .../siku.app
    let prefixName: String    // e.g. prefix10
    /// Where this world's game files live. nil = the classic `drive_c/HorizonXI`. Any other
    /// folder on the Mac works: wine sees the whole disk as `Z:`, so a world's data can sit on
    /// an external drive and the wrapper stays small and shared. Set per server from
    /// `Server.dataPath`; see `Install.for(server:)`.
    var gameDirOverride: URL? = nil

    init(wrapper: URL, prefixName: String, gameDirOverride: URL? = nil) {
        self.wrapper = wrapper; self.prefixName = prefixName; self.gameDirOverride = gameDirOverride
    }

    var id: String { wrapper.path + "#" + prefixName }

    /// A sibling prefix in the same wrapper where server installers run, so a running
    /// download is never killed by Play's `wineserver -k` on the game prefix (and vice versa).
    /// Created on first use with `wineboot -u` (~30 s, ~340 MB). Anything an installer writes to
    /// *its* registry is irrelevant: the game prefix's registry is re-pointed at the resolved
    /// SquareEnix folder on every launch (see GameRegistry).
    static let installerPrefixName = "prefix-installers"
    var installerPrefix: Install { Install(wrapper: wrapper, prefixName: Self.installerPrefixName) }

    /// Only game prefixes belong in the install picker. The installer prefix runs untrusted
    /// third-party setup programs and deliberately has none of the registry state needed to play.
    static func isGamePrefixName(_ name: String) -> Bool {
        name.hasPrefix("prefix") && name != installerPrefixName
    }

    /// The world this install was resolved for, when it came from a `Server`. Diagnostics only
    /// (`clientAmbiguity`); the launch itself keys off `gameDirOverride`.
    var worldName: String? = nil

    /// May this world use the client that lives inside the wrapper? True only for HorizonXI and
    /// the local server. For anyone else an empty `dataPath` does not mean "default" -- it means
    /// the world has no client, and launching would run HorizonXI's data against their login
    /// server. See `clientAmbiguity`.
    var ownsWrapperClient: Bool = true

    /// The same wrapper and prefix, pointed at a world's own game folder.
    func forServer(_ s: Server) -> Install {
        var c = self
        c.worldName = s.name
        // Only HorizonXI (whose client the wrapper was built around) and the local server, which
        // plays through that same client, may legitimately run with no folder of their own.
        c.ownsWrapperClient = s.local || s.name == "HorizonXI"

        c.gameDirOverride = s.dataPath.isEmpty ? nil : Self.resolveAshitaDir(URL(fileURLWithPath: s.dataPath), world: s.name)
        c.dataRoot = s.dataPath.isEmpty ? nil : URL(fileURLWithPath: s.dataPath)
        return c
    }

    /// The folder the user chose (or the Download flow filled) for this world. The Ashita
    /// folder is *inside* it somewhere: `gameDirOverride` is the resolved one.
    var dataRoot: URL? = nil

    // MARK: - Layout resolution
    //
    // Every server's installer lays the client out differently. HorizonXI puts Ashita-cli.exe
    // and SquareEnix/ side by side in one folder; CatsEyeXI's launcher makes
    // `<root>/catseyexi-client/Ashita/Ashita-cli.exe` next to `<root>/catseyexi-client/Game/
    // SquareEnix`; Windows installers for the others land wherever they like under
    // `C:\Games\<name>`. The user is asked for one folder, so the launcher has to find the two
    // things it needs under it: the Ashita folder (config/boot, addons, bootloader live there)
    // and the SquareEnix folder (FINAL FANTASY XI + PlayOnlineViewer, what the registry must
    // name). Both searches are shallow (3 levels), skip the huge ROM trees, and are cached.

    private static var ashitaCache: [String: URL] = [:]
    private static var seCache: [String: URL] = [:]
    private static let heavyDirs: Set<String> = ["SquareEnix", "ROM", "ROM2", "ROM3", "ROM4", "ROM5", "ROM6", "ROM7", "ROM8", "ROM9", "addons", "plugins", "polplugins", "resources", "sound", "sound2", "sound3", "sound4", "sound5", "sound6", "sound7", "sound8", "sound9", "docs", "logs", "screenshots", "downloads", "updates", "backups", "builds", "deps"]

    /// First folder at or under `root` (depth ≤ 3) that holds Ashita-cli.exe. Falls back to
    /// `root` itself, so a wrong choice still shows up as "missing Ashita-cli.exe" at that path.
    ///
    /// **`world` matters when `root` holds more than one client.** Measured 2026-08-21: Eden's
    /// `dataPath` had been set to the *parent* folder that holds every world's install
    /// (`.../Mac/FFXI`), so this search returned `HorizonXI-fresh` and "Play Eden" silently
    /// launched the HorizonXI client, HorizonXI's loader and HorizonXI's DATs against
    /// play.edenxi.com, with nothing in the UI saying so. When a world name is given, a candidate
    /// whose path names that world wins; `clientAmbiguity` reports the cases with no safe guess.
    static func resolveAshitaDir(_ root: URL, world: String? = nil) -> URL {
        if Self.isAshitaDir(root) { return root }
        let key = root.path + "#" + (world ?? "")
        if let c = ashitaCache[key], Self.isAshitaDir(c) { return c }
        let hits = ashitaCandidates(under: root)
        guard !hits.isEmpty else { return root }
        let pick = world.flatMap { w in hits.first { matches(world: w, path: $0, under: root) } } ?? hits[0]
        ashitaCache[key] = pick
        return pick
    }

    /// Every folder at or under `root` (depth <= 3) holding Ashita-cli.exe, shallowest first.
    static func ashitaCandidates(under root: URL) -> [URL] {
        findAll(under: root, depth: 3) { isAshitaDir($0) }
    }

    /// Does `path` (below `root`) name `world`? Compared on letters and digits only, so
    /// "Gaia XI" matches `GaiaXI` and "CatsEyeXI" matches `catseyexi-client`, while a folder
    /// named for a different world never matches.
    static func matches(world: String, path: URL, under root: URL) -> Bool {
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let w = squash(world)
        guard !w.isEmpty else { return false }
        let rel = path.path.hasPrefix(root.path) ? String(path.path.dropFirst(root.path.count)) : path.path
        return squash(rel).contains(w)
    }

    /// nil when this install's client is unambiguously the world's own. Otherwise a sentence
    /// naming what was found, for the UI to refuse the launch with. A data root holding several
    /// clients, none named for the world, is exactly the wrong-client case: there is no safe
    /// guess, so it must not be guessed.
    var clientAmbiguity: String? {
        guard let world = worldName else { return nil }
        guard let root = dataRoot else {
            guard !ownsWrapperClient else { return nil }
            return "\(world) has no game folder set, so this would run the client inside the "
                 + "wrapper — which is HorizonXI's, with HorizonXI's game data. Install \(world)'s "
                 + "own client (Download…) or point it at the folder that already holds one."
        }
        let hits = Self.ashitaCandidates(under: root)
        guard hits.count > 1 else { return nil }
        if hits.contains(where: { Self.matches(world: world, path: $0, under: root) }) { return nil }
        let names = hits.prefix(4).map { $0.lastPathComponent }.joined(separator: ", ")
        return "\(root.path) holds \(hits.count) different FFXI clients (\(names)) and none is "
             + "named for \(world). Point \(world) at its own client folder, not at the folder "
             + "that contains them all -- otherwise it launches another world's client and data "
             + "against \(world)'s login server."
    }

    /// The folder that holds `FINAL FANTASY XI` (and `PlayOnlineViewer`) for this world — what the
    /// PlayOnline registry must name. Usually called `SquareEnix`, but CatsEyeXI's client puts both
    /// straight under `catseyexi-client/Game/`, so the name is not relied on: any folder under the
    /// world's data root with a `FINAL FANTASY XI` child counts, nearest to the Ashita folder first.
    /// **Never looks above the data root** — a sibling world's SquareEnix (`~/Games/FFXI/…`) would
    /// otherwise be picked up, which is exactly the wrong-client mistake this exists to prevent.
    /// Falls back to `gameDir/SquareEnix` (the classic HorizonXI layout, also the no-root case).
    static func resolveSquareEnix(gameDir: URL, root: URL?) -> URL {
        let fm = FileManager.default
        func ok(_ u: URL) -> Bool { fm.fileExists(atPath: u.appendingPathComponent("FINAL FANTASY XI").path) }
        let direct = gameDir.appendingPathComponent("SquareEnix")
        if ok(direct) { return direct }
        if let c = seCache[gameDir.path], ok(c) { return c }
        guard let root else { return direct }
        // Nearest first: the Ashita folder's own parents (within the root), then anything under
        // the root up to four levels down.
        var p = gameDir
        while p.path.hasPrefix(root.path), p.path != root.deletingLastPathComponent().path {
            for c in [p, p.appendingPathComponent("SquareEnix"), p.appendingPathComponent("Game"), p.appendingPathComponent("Game/SquareEnix")] where ok(c) {
                seCache[gameDir.path] = c; return c
            }
            if p.path == root.path { break }
            p = p.deletingLastPathComponent()
        }
        if let hit = find(under: root, depth: 4, where: ok, descendIntoHeavy: ["SquareEnix"]) {
            seCache[gameDir.path] = hit; return hit
        }
        return direct
    }

    /// Breadth-first directory search, bounded, that never walks into the game's ROM trees.
    private static func find(under root: URL, depth: Int, where pred: (URL) -> Bool,
                             descendIntoHeavy: Set<String> = []) -> URL? {
        let fm = FileManager.default
        var level: [URL] = [root]
        for _ in 0...depth {
            var next: [URL] = []
            for dir in level {
                if pred(dir) { return dir }
                guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for k in kids {
                    let name = k.lastPathComponent
                    if heavyDirs.contains(name) && !descendIntoHeavy.contains(name) {
                        if pred(k) { return k }
                        continue
                    }
                    if (try? k.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { next.append(k) }
                }
            }
            level = next
            if level.isEmpty { break }
        }
        return nil
    }

    /// Every match, shallowest first. Same bounds and ROM-skipping as `find`.
    private static func findAll(under root: URL, depth: Int, where pred: (URL) -> Bool) -> [URL] {
        let fm = FileManager.default
        var level: [URL] = [root]
        var out: [URL] = []
        for _ in 0...depth {
            var next: [URL] = []
            for dir in level {
                if pred(dir) { out.append(dir); continue }
                guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for k in kids {
                    if heavyDirs.contains(k.lastPathComponent) {
                        if pred(k) { out.append(k) }
                        continue
                    }
                    if (try? k.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { next.append(k) }
                }
            }
            level = next
            if level.isEmpty { break }
        }
        return out
    }

    /// Windows-side path of `gameDir` for the wine command line: `C:\HorizonXI` for the classic
    /// location, `Z:\Users\…` (wine's whole-disk drive) for anything else.
    var gameDirWine: String {
        guard let o = gameDirOverride else { return "C:\\HorizonXI" }
        return Self.winePath(o, driveC: driveC)
    }

    var sharedSupport: URL { wrapper.appendingPathComponent("Contents/SharedSupport") }
    var wine: URL { sharedSupport.appendingPathComponent("wine/bin/wine") }
    var wineserver: URL { sharedSupport.appendingPathComponent("wine/bin/wineserver") }
    var prefix: URL { sharedSupport.appendingPathComponent(prefixName) }
    var driveC: URL { prefix.appendingPathComponent("drive_c") }
    var gameDir: URL { gameDirOverride ?? driveC.appendingPathComponent("HorizonXI") }

    /// Keep the classic `C:\HorizonXI` path available when HorizonXI's data lives elsewhere.
    /// The repair script and remembered-install fast path both use this location, while normal
    /// launches continue to use `gameDirOverride` directly. Never replace a real directory.
    @discardableResult
    func ensureClassicGameLink(log: (String) -> Void) -> Bool {
        guard gameDirOverride != nil else { return true }
        let fm = FileManager.default
        let classic = driveC.appendingPathComponent("HorizonXI")
        let wanted = gameDir.standardizedFileURL

        if let destination = try? fm.destinationOfSymbolicLink(atPath: classic.path) {
            let current = URL(fileURLWithPath: destination,
                              relativeTo: classic.deletingLastPathComponent()).standardizedFileURL
            if current.path == wanted.path { return true }
            do { try fm.removeItem(at: classic) }
            catch {
                log("!! could not replace the old C:\\HorizonXI link: \(error.localizedDescription)")
                return false
            }
        } else if fm.fileExists(atPath: classic.path) {
            log("!! C:\\HorizonXI is a real folder; not replacing it with a link to \(wanted.path)")
            return false
        }

        do {
            try fm.createDirectory(at: driveC, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: classic, withDestinationURL: wanted)
            log("==> linked C:\\HorizonXI to \(wanted.path)")
            return true
        } catch {
            log("!! could not link C:\\HorizonXI to \(wanted.path): \(error.localizedDescription)")
            return false
        }
    }

    var squareEnix: URL { Self.resolveSquareEnix(gameDir: gameDir, root: dataRoot) }
    /// Windows-side path of `squareEnix`, for the registry.
    var squareEnixWine: String { Self.winePath(squareEnix, driveC: driveC) }
    static func winePath(_ u: URL, driveC: URL) -> String {
        let p = u.standardizedFileURL.path, c = driveC.standardizedFileURL.path
        if p.hasPrefix(c + "/") { return "C:" + String(p.dropFirst(c.count)).replacingOccurrences(of: "/", with: "\\") }
        return "Z:" + p.replacingOccurrences(of: "/", with: "\\")
    }
    /// Which generation of Ashita this world's client ships.
    ///
    /// Ashita **v4** is `Ashita-cli.exe` driven by `config/boot/<name>.ini`; that is what
    /// HorizonXI, CatsEyeXI and Gaia XI ship and what this launcher was built against.
    /// Ashita **v3** is `injector.exe` driven by `config/boot/<name>.xml`, and Eden's client
    /// (Eden534, 2023) ships that one -- with the loader under `Ashita/ffxi-bootmod/` rather than
    /// `bootloader/`. Both have a command-line injector, so both can be launched unattended; only
    /// the file names and the config format differ.
    enum AshitaGeneration: String { case v4, v3 }

    var ashitaGeneration: AshitaGeneration {
        FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("Ashita-cli.exe").path)
            ? .v4 : .v3
    }

    /// The command-line injector to run, whichever generation this client is.
    var ashitaCLI: URL {
        gameDir.appendingPathComponent(ashitaGeneration == .v4 ? "Ashita-cli.exe" : "injector.exe")
    }

    /// The folder holding this client's boot loader. v4 keeps it in `bootloader/`, Eden's v3
    /// client in `ffxi-bootmod/`.
    var bootLoaderDir: URL {
        let fm = FileManager.default
        for name in ["bootloader", "ffxi-bootmod"] {
            let u = gameDir.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return gameDir.appendingPathComponent("bootloader")
    }

    /// Extension a boot profile takes for this client: `.ini` on v4, `.xml` on v3.
    var bootProfileExtension: String { ashitaGeneration == .v4 ? "ini" : "xml" }

    /// `profile` with the extension this client's Ashita actually reads, so a world configured
    /// as `eden.ini` still works against a v3 client.
    func bootProfileName(_ profile: String) -> String {
        let base = (profile as NSString).deletingPathExtension
        return base + "." + bootProfileExtension
    }
    var frameworks: URL { wrapper.appendingPathComponent("Contents/Frameworks") }
    var d3dMetal: URL { wrapper.appendingPathComponent("Contents/Frameworks/renderer/d3dmetal/external") }
    var systemReg: URL { prefix.appendingPathComponent("system.reg") }

    /// Whether the client is actually in this prefix. A wrapper with wine but no game is the
    /// normal state right after first-run setup, and the UI has to be able to say so.
    /// "Has the game" means Ashita-cli.exe is there, not merely that the folder exists — the
    /// folder is created the moment the user picks a location, long before anything is in it.
    var hasGame: Bool { FileManager.default.fileExists(atPath: ashitaCLI.path) }

    /// Does this folder hold an Ashita command-line injector of either generation?
    static func isAshitaDir(_ u: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: u.appendingPathComponent("Ashita-cli.exe").path)
            || fm.fileExists(atPath: u.appendingPathComponent("injector.exe").path)
    }

    /// Volume the wrapper lives on — the usual failure is that it simply is not mounted.
    var volume: URL? {
        let parts = wrapper.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return URL(fileURLWithPath: "/") }
        return URL(fileURLWithPath: "/\(parts[1])/\(parts[2])")
    }

    var isMounted: Bool {
        guard let v = volume else { return false }
        return FileManager.default.fileExists(atPath: v.path)
    }

    // MARK: - Remembering the last good install

    private static let key = "install.last"

    /// The install used last time, if it is still on disk. Lets the UI be usable before the
    /// volume scan finishes.
    static func remembered() -> Install? {
        guard let s = UserDefaults.standard.string(forKey: key) else { return nil }
        let parts = s.components(separatedBy: "#")
        guard parts.count == 2, isGamePrefixName(parts[1]) else { return nil }
        let i = Install(wrapper: URL(fileURLWithPath: parts[0]), prefixName: parts[1])
        return FileManager.default.fileExists(atPath: i.gameDir.path) ? i : nil
    }

    func remember() {
        UserDefaults.standard.set(id, forKey: Self.key)
    }

    // MARK: - Discovery

    /// Search the usual places for a wrapper .app that contains a wine build and a HorizonXI client.
    /// Deliberately shallow: a full-disk crawl on an 8GB machine is not worth it.
    static func discover() -> [Install] {
        let fm = FileManager.default
        var roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            // Wrapper apps are large, so people keep them with their games rather than in
            // /Applications. Missing this one is why the launcher was running the copy on an
            // external drive while an identical install sat on the internal SSD.
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Games"),
            // Downloads is deliberately *not* scanned -- see `tccGatedNames`. An install that
            // really is in Downloads is reached by the "Choose install…" button instead.
        ]
        if let vols = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                  includingPropertiesForKeys: nil) {
            roots.append(contentsOf: vols)
        }

        var found: [Install] = []
        var seen = Set<String>()

        for root in roots {
            // depth 4: "Video Games/Mac/FFXI/siku.app" on an external drive is four deep.
            for app in appsUnder(root, depth: 4) {
                guard seen.insert(app.path).inserted else { continue }
                let shared = app.appendingPathComponent("Contents/SharedSupport")
                guard fm.isExecutableFile(atPath: shared.appendingPathComponent("wine/bin/wine").path)
                else { continue }
                guard let kids = try? fm.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil)
                else { continue }
                // A prefix with no game in it used to be discarded outright. That made the
                // wrapper first-run setup builds invisible to its own launcher: wine installed,
                // drive created, and the UI still insisting nothing was found.
                //
                // Keeping *every* empty prefix is wrong too -- a long-lived wrapper accumulates
                // half a dozen of them and they would all show up in the picker. So: if this
                // wrapper has the game anywhere, show only the prefixes that have it. If it has
                // the game nowhere, it is a fresh wrapper waiting for an install, and its
                // prefixes are exactly what the user needs to see.
                let candidates = kids
                    .filter { isGamePrefixName($0.lastPathComponent) }
                    .map { Install(wrapper: app, prefixName: $0.lastPathComponent) }
                let withGame = candidates.filter(\.hasGame)
                found.append(contentsOf: withGame.isEmpty ? candidates : withGame)
            }
        }
        // Rank by how many preconditions the prefix already satisfies, so a half-finished
        // experiment never outranks a configured one. Equal scores fall back to name order,
        // which puts the plain `prefixNN` prefixes ahead of suffixed experiments.
        return found.sorted { a, b in
            // An install with the game beats one without, whatever else is true of it.
            if a.hasGame != b.hasGame { return a.hasGame }
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            // An install on an external volume works right up until the drive is unplugged, and
            // it reads slower besides. Prefer an equally-good one on the internal disk.
            let ea = a.wrapper.path.hasPrefix("/Volumes/"), eb = b.wrapper.path.hasPrefix("/Volumes/")
            if ea != eb { return !ea }
            return a.prefixName < b.prefixName
        }
    }

    /// Every install a given wrapper .app holds, whether or not it sits anywhere `discover()`
    /// looks. This is what the "Choose install…" button hands its result to.
    static func installs(inWrapper app: URL) -> [Install] {
        let fm = FileManager.default
        let shared = app.appendingPathComponent("Contents/SharedSupport")
        guard fm.isExecutableFile(atPath: shared.appendingPathComponent("wine/bin/wine").path),
              let kids = try? fm.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil)
        else { return [] }
        return kids
            .filter { isGamePrefixName($0.lastPathComponent) }
            .map { Install(wrapper: app, prefixName: $0.lastPathComponent) }
            .sorted { a, b in
                if a.hasGame != b.hasGame { return a.hasGame }
                return a.prefixName < b.prefixName
            }
    }

    private static func score(_ i: Install) -> Int {
        Preflight.run(i).reduce(0) { $0 + ($1.state == .ok ? 1 : 0) }
    }

    /// Directories macOS gates behind TCC. Touching one at all — even just asking whether it is
    /// a directory — pops "FFXI-on-Mac would like to access files in your Downloads folder"
    /// before the user has pressed anything, which is a terrible first thing for a game launcher
    /// to do. They are never scanned; the "Choose install…" button reaches them instead, and
    /// picking through a panel is what actually grants the access.
    ///
    /// Matched by name rather than by path: `/Volumes` holds an entry for the boot volume, so the
    /// volume scan reaches `/Volumes/Macintosh HD/Users/<user>/` and arrives at the same folders
    /// from the other side — and that entry is an APFS *firmlink*, which
    /// `resolvingSymlinksInPath()` does not collapse, so the two spellings never compare equal.
    ///
    /// **This does not yet make the prompt go away, and the launcher still raises it on first
    /// run.** Measured 2026-08-14: removing Downloads from `roots`, then adding both guards
    /// below, then disabling the `/Volumes` scan entirely, all still produced the prompt, so the
    /// access is somewhere else and is not yet identified. The guards are kept because skipping
    /// three folders the game is never installed in is free and correct either way. Whoever
    /// picks this up: find the actual accessor first (`sudo fs_usage -w -f filesys` filtered to
    /// the launcher's pid catches it; `log stream` on a TCC predicate did not).
    private static let tccGatedNames: Set<String> = ["Downloads", "Desktop", "Documents"]

    private static let skipNames: Set<String> = [
        "Backups.backupdb", "Photos", "Photos Library.photoslibrary", "Library", "node_modules",
        ".Trashes", "System Volume Information", "Movies", "Music", "Pictures",
        // The x10 archive drive (2.4 TB, spinning): none of these hold a wrapper app, and
        // walking them made discovery run for 10+ minutes after the game data moved there.
        "LLMs", "Media", "Guidebooks", "Games & ROMs", "Emulators", "Operating Systems",
        "SteamLibrary", "Software", "Thumb Drives Backup", "Daniel Backup", "Windows",
        "SquareEnix", "ROM", "updates", "logs", "screenshots",
    ]

    private static func appsUnder(_ root: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        guard !tccGatedNames.contains(root.lastPathComponent) else { return [] }
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for kid in kids {
            // Checked before asking anything about the file: even a metadata query against a
            // gated folder is enough to raise the prompt.
            if tccGatedNames.contains(kid.lastPathComponent) { continue }
            // Never descend into these: a Time Machine set on an external drive is millions of
            // entries, and the scan visibly hung the launcher ("looking for your install…").
            if Self.skipNames.contains(kid.lastPathComponent) { continue }
            let isDir = (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if kid.pathExtension == "app" {
                out.append(kid)
            } else {
                out.append(contentsOf: appsUnder(kid, depth: depth - 1))
            }
        }
        return out
    }
}
