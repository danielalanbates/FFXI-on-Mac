// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// What Setup finds already in the folder the user chose. Daniel, 2026-10-15: "when the folder
/// already contains the previous installation is it going to auto recognize that and continue
/// setup based on the files there? or will it duplicate everything and create problems"
///
/// Until now only the layout Setup builds itself ("FFXI on Mac/") was carried on from. An older
/// install in the folder -- a wrapper like siku.app, the "FFXI on Mac Wine.app" the old setup put
/// in ~/Applications, a HorizonXI client folder on its own, a SquareEnix folder -- was not seen:
/// Setup built a second wrapper beside it and downloaded 25 GB again. Now:
///
/// - a wrapper whose Windows drive holds HorizonXI (or a wrapper Setup built, with no game yet)
///   becomes the install in use, and Setup does only what it lacks; no second wrapper is built;
/// - a HorizonXI client or SquareEnix folder on its own is moved into the install's Windows drive
///   after one question: one rename on the same drive, nothing copied, and a link left where it
///   was. From another drive it is copied (InstallMove.copyTree) and the original stays;
/// - files behind a drive that is gone are said so in one line and never touched;
/// - the chooser's space check counts only what is still missing (`need`).
///
/// `find` is read-only and bounded: three folders down from the chosen one, at most `visitCap`
/// folders, never into an app's own files (a wrapper is looked at, not walked), the game's ROM
/// trees, or system, backup and media folders; a link is looked at once and never walked through.
/// The chooser runs it off the main thread.
enum ExistingInstall {

    /// A HorizonXI client folder (Ashita and SquareEnix side by side, version.json beside them),
    /// or a SquareEnix folder on its own.
    struct Client: Equatable {
        /// Where it really is: a link to it is followed once to get here.
        var url: URL
        var version: String?
        /// What update-client.sh calls complete: FFXiMain.dll, polcore.dll and Ashita. Without
        /// them Setup's download fetches the base again (it holds Ashita) and unpacks it over.
        var complete: Bool
        /// Only the SquareEnix folder: no Ashita, no version.json.
        var squareEnixOnly = false
        /// Its game files are behind this drive, which is not there (ghost or unplugged).
        var missingDrive: String? = nil
        /// On the same drive as the folder Setup works in: one rename moves it. Otherwise it is
        /// copied, and the original stays where it is.
        var sameVolume = true
    }

    struct Found: Equatable {
        /// Where Setup works: "<chosen>/FFXI on Mac", or the folder an older wrapper is in (the
        /// game's Wine goes beside it there, as the old layout had it).
        var home: URL
        /// The wrapper Setup uses instead of building one.
        var wrapper: Install? = nil
        /// It is "FFXI on Mac/FFXI on Mac Wine.app", the layout Setup builds.
        var newLayout = false
        /// The client inside `wrapper`, or one on its own elsewhere in the chosen folder.
        var client: Client? = nil
        var clientInWrapper = false
        /// The game's Wine (wine-coop) in `home`.
        var gameWine: URL? = nil
        /// Bytes of HorizonXI's base zip already downloaded into the wrapper (aria2 resumes them).
        var partialBytes: Int64 = 0
        /// The install whose files are behind a missing drive is "<chosen>/FFXI on Mac" itself, so
        /// there is nowhere to download fresh without touching it: the chooser refuses the folder.
        var unreachableAtHome = false

        var unreachableDrive: String? { client?.missingDrive }

        /// What the chooser says it found, in one line.
        var line: String {
            if let d = unreachableDrive { return "HorizonXI here is on the '\(d)' drive, which isn't connected." }
            let name: String? = client.map { c in
                c.squareEnixOnly ? "FINAL FANTASY XI's files" : c.version.map { "HorizonXI \($0)" } ?? "HorizonXI"
            }
            let them = client?.squareEnixOnly == true ? "them" : "it"
            let place = wrapper.map { newLayout ? "here" : "in “\($0.wrapper.lastPathComponent)”" } ?? "here"
            if let name, clientInWrapper {
                return client?.complete == true ? "Found \(name) \(place) — Setup will use it."
                                                : "Found part of HorizonXI \(place) — Setup will finish it."
            }
            if let name, let c = client {
                let into = wrapper.map { "“\($0.wrapper.lastPathComponent)”" } ?? "FFXI on Mac"
                return c.sameVolume ? "Found \(name) here — Setup will move \(them) into \(into)."
                                    : "Found \(name) on another drive — Setup will copy \(them)."
            }
            if wrapper != nil { return "Found Wine \(place) — Setup will use it." }
            if gameWine != nil { return "Found the game's Wine here — Setup will use it." }
            return ""
        }
    }

    // MARK: - Finding (read-only)

    static let maxDepth = 3
    /// The most folders one look reads: a folder of a few thousand subfolders is given up on, not
    /// walked for minutes on a spinning drive.
    static let visitCap = 3000

    /// Looked at (is it a client, a SquareEnix?) but never walked into.
    private static let noDescend: Set<String> = [
        "SquareEnix", "FINAL FANTASY XI", "PlayOnlineViewer", "ROM", "ROM2", "ROM3", "ROM4", "ROM5",
        "ROM6", "ROM7", "ROM8", "ROM9", "addons", "plugins", "polplugins", "updates", "logs", "screenshots",
    ]
    /// Not even looked at: system, backup and media folders.
    private static let skipNames: Set<String> = [
        "Library", "System", "private", "usr", "bin", "sbin", "dev", "cores", "opt", "Network", "Volumes",
        "Backups.backupdb", "node_modules", "Movies", "Music", "Pictures", "System Volume Information",
        ".Trashes", ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
    ]
    /// Packages other than apps: walked into by nothing.
    private static let packageExtensions: Set<String> = [
        "photoslibrary", "bundle", "framework", "plugin", "kext", "xcodeproj", "xcworkspace", "musiclibrary",
        "tvlibrary", "fcpbundle", "logicx", "band", "sparsebundle", "dmg",
    ]
    /// Asking about anything in these raises macOS's "would like to access files in your …
    /// folder" prompt (Install.tccGatedNames): the chooser does not look inside them while the
    /// user browses, only once a folder in them has been chosen.
    static func isGated(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return ["Desktop", "Documents", "Downloads"].contains { p == home + "/" + $0 || p.hasPrefix(home + "/" + $0 + "/") }
    }

    /// Whether two paths are on one drive (the nearest existing folder of each). The self-test
    /// swaps it to stand in for a second drive.
    static var sameVolume: (String, String) -> Bool = { a, b in
        func dev(_ path: String) -> dev_t? {
            var p = path
            var st = stat()
            while stat(p, &st) != 0 {
                if p == "/" || p.isEmpty { return nil }
                p = (p as NSString).deletingLastPathComponent
            }
            return st.st_dev
        }
        guard let x = dev(a), let y = dev(b) else { return false }
        return x == y
    }

    /// Everything Setup can use in `chosen` (the folder itself included), the best of it, or nil.
    /// In order: a wrapper that already holds HorizonXI (the new layout first among equals); a
    /// client on its own, moved into a wrapper with no game yet or into a new one; a wrapper with
    /// no game; the game's Wine alone. Anything whose files are behind a missing drive counts only
    /// when nothing else is there.
    static func find(in chosen: URL) -> Found? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: InstallMove.canonical(chosen.path) ?? chosen.standardizedFileURL.path, isDirectory: true)
        guard Preflight.unavailableDrive(for: root.path) == nil, isDir(root.path) else { return nil }

        struct W { var install: Install; var client: Client?; var partial: Int64; var newLayout: Bool; var depth: Int }
        var wrappers: [W] = []
        var clients: [(Client, Int)] = []
        var level: [URL] = [root]
        var visited = 0
        var seen = Set<String>()
        outer: for depth in 0...maxDepth {
            var next: [URL] = []
            for dir in level {
                visited += 1
                if visited > visitCap { break outer }
                guard seen.insert(dir.path).inserted else { continue }
                let name = dir.lastPathComponent
                if dir.pathExtension.lowercased() == "app" {
                    if let w = wrapper(at: dir) {
                        wrappers.append(W(install: w.0, client: w.1, partial: w.2, newLayout: false, depth: depth))
                    }
                    continue
                }
                if name == InstallLocation.folderName {
                    let app = InstallLocation.wrapper(in: dir)
                    if let w = wrapper(at: app) {
                        wrappers.append(W(install: w.0, client: w.1, partial: w.2, newLayout: true, depth: depth))
                    }
                    continue
                }
                if let c = bareClient(at: dir, root: root) { clients.append((c, depth)); continue }
                if depth == maxDepth || noDescend.contains(name) { continue }
                guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
                let homeDir = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
                for k in kids {
                    let n = k.lastPathComponent
                    if skipNames.contains(n) || packageExtensions.contains(k.pathExtension.lowercased()) { continue }
                    if dir.path == homeDir, ["Desktop", "Documents", "Downloads"].contains(n) { continue }
                    var st = stat()
                    guard lstat(k.path, &st) == 0 else { continue }
                    switch st.st_mode & S_IFMT {
                    case S_IFDIR:
                        next.append(k)
                    case S_IFLNK:
                        // Looked at once where it leads, never walked through. A link onto a drive
                        // that is gone is a SquareEnix (or client) whose files are not there.
                        if let d = Preflight.unavailableDrive(for: k.path) {
                            if n == "SquareEnix" || n.lowercased().contains("horizon"), !namesAnotherWorld(k, root: root, name: n) {
                                clients.append((Client(url: k, version: nil, complete: false, squareEnixOnly: n == "SquareEnix",
                                                       missingDrive: d), depth + 1))
                            }
                            continue
                        }
                        if let real = InstallMove.canonical(k.path), isDir(real) {
                            let r = URL(fileURLWithPath: real, isDirectory: true)
                            // The name the link has is what says what it is ("HorizonXI", "siku.app").
                            if r.pathExtension.lowercased() == "app" || k.pathExtension.lowercased() == "app" {
                                if let w = wrapper(at: r) {
                                    wrappers.append(W(install: w.0, client: w.1, partial: w.2, newLayout: false, depth: depth + 1))
                                }
                            } else if let c = bareClient(at: r, root: root, name: n) {
                                clients.append((c, depth + 1))
                            }
                        }
                    default:
                        continue
                    }
                }
            }
            level = next
            if level.isEmpty { break }
        }

        func rank(_ c: Client?) -> Int {
            guard let c else { return 1 }
            if c.missingDrive != nil { return 0 }
            return c.complete ? 3 : 2
        }
        func newer(_ a: String?, _ b: String?) -> Bool {
            guard let a else { return false }
            guard let b else { return true }
            return Primary.isNewer(a, than: b)
        }
        let bestWrapper = wrappers.max { a, b in
            if rank(a.client) != rank(b.client) { return rank(a.client) < rank(b.client) }
            if a.newLayout != b.newLayout { return !a.newLayout }
            if a.client?.version != b.client?.version { return newer(b.client?.version, a.client?.version) }
            return a.depth > b.depth
        }
        let bestClient = clients.max { a, b in
            if rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
            if a.0.squareEnixOnly != b.0.squareEnixOnly { return a.0.squareEnixOnly }
            if a.0.version != b.0.version { return newer(b.0.version, a.0.version) }
            return a.1 > b.1
        }
        func gameWine(in home: URL) -> URL? {
            let w = InstallLocation.gameWine(in: home)
            return fm.isExecutableFile(atPath: w.path) ? w : nil
        }
        func adopt(_ w: W) -> Found {
            let home = w.install.wrapper.deletingLastPathComponent()
            return Found(home: home, wrapper: w.install, newLayout: w.newLayout, gameWine: gameWine(in: home),
                         partialBytes: w.partial)
        }
        let freshHome = InstallLocation.folder(for: root)

        // A wrapper that already holds HorizonXI: used as it is.
        if let w = bestWrapper, rank(w.client) >= 2 {
            var f = adopt(w)
            f.client = w.client; f.clientInWrapper = true
            return f
        }
        // A client on its own: into a wrapper that has no game yet, or into a new one.
        if let (c0, _) = bestClient, rank(c0) >= 2 {
            var c = c0
            var f: Found
            if let w = bestWrapper, rank(w.client) == 1 {
                f = adopt(w)
            } else {
                // The chosen folder is the client itself: FFXI on Mac goes beside it.
                let home = c.url.standardizedFileURL.path == root.path
                    ? InstallLocation.folder(for: root.deletingLastPathComponent()) : freshHome
                f = Found(home: home, gameWine: gameWine(in: home))
            }
            c.sameVolume = sameVolume(c.url.path, f.home.path)
            f.client = c
            return f
        }
        // A wrapper with Wine and no game: its Wine and Windows drive are used.
        if let w = bestWrapper, rank(w.client) == 1 { return adopt(w) }
        // Only files behind a drive that is gone: said, and never touched.
        if let c = bestWrapper?.client ?? bestClient?.0, c.missingDrive != nil {
            let atHome = bestWrapper.map { $0.newLayout && $0.install.wrapper.deletingLastPathComponent().path == freshHome.path } ?? false
            return Found(home: freshHome, client: c, gameWine: gameWine(in: freshHome), unreachableAtHome: atHome)
        }
        if let g = gameWine(in: freshHome) { return Found(home: freshHome, gameWine: g) }
        return nil
    }

    /// A wrapper .app whose Windows drive holds a HorizonXI folder (the prefix with the most of
    /// HorizonXI in it; an empty one is a download that never finished, and resumes there), or one
    /// Setup built ("FFXI on Mac Wine.app") whose Wine or Windows drive is there with no game yet.
    static func wrapper(at app: URL) -> (Install, Client?, Int64)? {
        let fm = FileManager.default
        let shared = app.appendingPathComponent("Contents/SharedSupport")
        guard let kids = try? fm.contentsOfDirectory(atPath: shared.path) else { return nil }
        let installs = kids.filter { $0.hasPrefix("prefix") && $0 != Install.installerPrefixName }.sorted()
            .map { Install(wrapper: app, prefixName: $0) }
        func horizon(_ i: Install) -> URL { i.driveC.appendingPathComponent("HorizonXI") }
        func score(_ c: Client?) -> Int { c == nil ? 0 : c!.missingDrive != nil ? 1 : c!.complete ? 3 : 2 }
        let scored = installs.filter { lexists(horizon($0).path) }.map { ($0, client(at: horizon($0))) }
        if let best = scored.max(by: { a, b in
            if score(a.1) != score(b.1) { return score(a.1) < score(b.1) }
            return (a.0.prefixName == Bootstrap.prefixName ? 1 : 0) < (b.0.prefixName == Bootstrap.prefixName ? 1 : 0)
        }) {
            return (best.0, best.1, partialBytes(best.0))
        }
        guard app.lastPathComponent == InstallLocation.wrapperName else { return nil }
        let i = installs.first { $0.prefixName == Bootstrap.prefixName } ?? installs.first
            ?? Install(wrapper: app, prefixName: Bootstrap.prefixName)
        guard Bootstrap.isBuilt(app) || fm.fileExists(atPath: i.prefix.path) else { return nil }
        return (i, nil, partialBytes(i))
    }

    /// What is in a HorizonXI folder, or nil when nothing of a client is (no version.json, no
    /// Ashita, no SquareEnix).
    static func client(at dir: URL) -> Client? {
        let fm = FileManager.default
        // The whole folder a link onto a drive that is gone.
        if let d = Preflight.unavailableDrive(for: dir.path) {
            return Client(url: dir, version: nil, complete: false, missingDrive: d)
        }
        let se = dir.appendingPathComponent("SquareEnix")
        let version = horizonVersion(dir)
        let ashita = Install.isAshitaDir(dir)
        guard version != nil || ashita || lexists(se.path) else { return nil }
        let missing = Preflight.unavailableDrive(for: se.appendingPathComponent("FINAL FANTASY XI").path)
        let complete = missing == nil && ashita
            && fm.fileExists(atPath: se.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll").path)
            && fm.fileExists(atPath: se.appendingPathComponent("PlayOnlineViewer/viewer/com/polcore.dll").path)
        return Client(url: dir, version: version, complete: complete, missingDrive: missing)
    }

    /// A HorizonXI client or SquareEnix folder on its own (not inside a wrapper), never one that
    /// belongs to another world: HorizonXI's own version.json, or Ashita and SquareEnix together
    /// in a folder named for HorizonXI; or a folder named SquareEnix holding FINAL FANTASY XI.
    /// `name` is the name it was reached by (a link's), when that differs.
    static func bareClient(at dir: URL, root: URL, name: String? = nil) -> Client? {
        let fm = FileManager.default
        let label = name ?? dir.lastPathComponent
        // Most folders are neither: a few lstat calls say so before anything else is read.
        let marks = ["version.json", "Ashita-cli.exe", "injector.exe", "SquareEnix", "FINAL FANTASY XI"]
        guard marks.contains(where: { lexists(dir.appendingPathComponent($0).path) }) else { return nil }
        guard !namesAnotherWorld(dir, root: root, name: label) else { return nil }
        if label == "SquareEnix" || dir.lastPathComponent == "SquareEnix" {
            guard fm.fileExists(atPath: dir.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll").path) else { return nil }
            return Client(url: dir, version: nil, complete: false, squareEnixOnly: true)
        }
        guard let c = client(at: dir) else { return nil }
        let ashita = Install.isAshitaDir(dir), se = lexists(dir.appendingPathComponent("SquareEnix").path)
        let named = squash(label).contains("horizon") || squash(relative(dir, to: root)).contains("horizon")
        guard (c.version != nil && (ashita || se)) || (ashita && se && named) else { return nil }
        return c
    }

    /// The worlds whose clients must never be taken for HorizonXI's: every world the launcher
    /// knows, the ones the picker no longer offers (Eden) included.
    static var otherWorlds: [String] {
        Server.all.filter { !$0.local && $0.name != "HorizonXI" }.map { squash($0.name) }.filter { !$0.isEmpty }
    }

    static func namesAnotherWorld(_ dir: URL, root: URL, name: String) -> Bool {
        let path = squash(relative(dir, to: root) + "/" + name)
        return otherWorlds.contains { path.contains($0) }
    }

    /// `dir` below the chosen folder, the chosen folder's own name included.
    private static func relative(_ dir: URL, to root: URL) -> String {
        let base = root.deletingLastPathComponent().path
        let p = dir.standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
    }

    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// version.json's "version", read by pattern: files written before 356f615 hold a literal "\n"
    /// and are not JSON (update-client.sh reads them the same way).
    static func horizonVersion(_ dir: URL) -> String? {
        guard let t = try? String(contentsOf: dir.appendingPathComponent("version.json"), encoding: .utf8),
              let r = t.range(of: #""version"\s*:\s*"[^"]+""#, options: .regularExpression) else { return nil }
        let v = t[r].split(separator: "\"").last.map(String.init)
        return v?.isEmpty == false ? v : nil
    }

    /// The base zip aria2 has part of, in the wrapper's HorizonXI folder.
    static func partialBytes(_ i: Install) -> Int64 {
        let z = i.driveC.appendingPathComponent("HorizonXI/updates/HorizonXI.zip").path
        let size = (try? FileManager.default.attributesOfItem(atPath: z)[.size] as? Int64) ?? nil
        return min(size ?? 0, InstallLocation.Need.gameZip)
    }

    static func lexists(_ path: String) -> Bool { var st = stat(); return lstat(path, &st) == 0 }
    static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    // MARK: - What it still needs

    /// What Setup still has to write, given what is there (InstallLocation.Need): Wine unless a
    /// wrapper with Wine is used; the game's Wine unless it is found (in `home`, or anywhere Play
    /// looks: `gameWineElsewhere`); and the game -- for a complete client nothing but roughly an
    /// update when it is older than `latest` (or either is unknown); for an incomplete one, a lone
    /// SquareEnix (HorizonXI ships Ashita only inside its base zip) or none at all, the base
    /// download and its unzip less what is already downloaded; plus the client itself when it is
    /// copied from another drive.
    static func need(_ f: Found?, gameWineElsewhere: Bool, latest: String?) -> Int64 {
        typealias N = InstallLocation.Need
        var n: Int64 = 0
        if !(f?.wrapper.map { Bootstrap.isBuilt($0.wrapper) } ?? false) { n += N.wine }
        if f?.gameWine == nil, !gameWineElsewhere { n += N.gameWine }
        let base = N.gameZip - min(f?.partialBytes ?? 0, N.gameZip) + N.gameUnpacked
        guard let f, let c = f.client, c.missingDrive == nil else { return n + base }
        if !f.clientInWrapper, !c.sameVolume { n += N.gameUnpacked }
        if c.complete, !c.squareEnixOnly {
            if let v = c.version, let l = latest, !Primary.isNewer(l, than: v) { return n }
            return n + N.update
        }
        return n + base
    }

    /// The same, for a fresh download into `home` (Download Fresh): only the Wine and the game's
    /// Wine found there count.
    static func fresh(_ f: Found?) -> Found? {
        guard let f else { return nil }
        var g = Found(home: f.home, gameWine: f.gameWine)
        if let w = f.wrapper, !f.clientInWrapper { g.wrapper = w; g.newLayout = f.newLayout; g.partialBytes = f.partialBytes }
        return g
    }

    /// A refusal of the chosen folder because of what is in it, or nil.
    static func refusal(_ f: Found?) -> String? {
        guard let f else { return nil }
        if f.unreachableAtHome, let d = f.unreachableDrive {
            return "This install's files are on the '\(d)' drive, which isn't connected."
        }
        if let c = f.client, !f.clientInWrapper {
            let src = c.url.standardizedFileURL.path, home = f.home.standardizedFileURL.path
            if home == src || home.hasPrefix(src + "/") { return "Choose the folder that holds these game files." }
        }
        return nil
    }

    // MARK: - Bringing a client in

    /// Where a client goes in `install`: its Windows drive's HorizonXI folder, or the SquareEnix
    /// folder in it.
    static func destination(for c: Client, in i: Install) -> URL {
        let h = i.driveC.appendingPathComponent("HorizonXI", isDirectory: true)
        return c.squareEnixOnly ? h.appendingPathComponent("SquareEnix", isDirectory: true) : h
    }

    /// One rename into `install` (the same drive: nothing is copied), then a link where it was, so
    /// whatever pointed at it -- another wrapper's SquareEnix link, a world's folder setting --
    /// still reaches the same files (and the picker shows those as one install: Install.dedupe).
    /// What was at the destination -- an empty folder, or the launcher's own unfinished download --
    /// goes to the Trash first (InstallMove.discard). Throws, having changed nothing, when the
    /// client is on another drive (copy it instead) or its drive is gone.
    @discardableResult
    static func moveIn(_ c: Client, to i: Install, log: (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let src = c.url.standardizedFileURL
        let dest = destination(for: c, in: i).standardizedFileURL
        if let d = Preflight.unavailableDrive(for: src.path) ?? Preflight.unavailableDrive(for: i.driveC.path) {
            throw InstallMove.Refusal("The '\(d)' drive isn't connected, so nothing was moved.")
        }
        guard dest.path != src.path, !dest.path.hasPrefix(src.path + "/") else {
            throw InstallMove.Refusal("Choose the folder that holds these game files.")
        }
        guard sameVolume(src.path, i.driveC.path) else {
            throw InstallMove.Refusal("These files are on another drive, so they have to be copied.")
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if lexists(dest.path) {
            if isDir(dest.path), ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? ["?"]).isEmpty {
                try fm.removeItem(at: dest)
            } else {
                try InstallMove.discard(dest)
                log("moved to the Trash to make way for the game files: \(dest.path)")
            }
        }
        guard rename(src.path, dest.path) == 0 else {
            let why = String(cString: strerror(errno))
            throw InstallMove.Refusal("The game files couldn't be moved (\(why)).")
        }
        log("moved \(src.path) to \(dest.path)")
        do { try fm.createSymbolicLink(atPath: src.path, withDestinationPath: dest.path) }
        catch { log("no link left at \(src.path): \(error.localizedDescription)") }
        return dest
    }

    /// A world's folder setting that named the client (or something in it), pointed at where it is
    /// now; for the worlds that play the wrapper's own client, cleared when that is where it went.
    static func rewritten(_ dataPath: String, from src: URL, to dest: URL, classic: URL?) -> String? {
        guard !dataPath.isEmpty else { return nil }
        let p = URL(fileURLWithPath: dataPath).standardizedFileURL.path, s = src.standardizedFileURL.path
        guard p == s || p.hasPrefix(s + "/") else { return nil }
        let now = dest.standardizedFileURL.path + String(p.dropFirst(s.count))
        if let c = classic?.standardizedFileURL.path, now == c { return "" }
        return now
    }
}
