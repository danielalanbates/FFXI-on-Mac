// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// Move…: copy an existing install into "<chosen>/FFXI on Mac/" so that everything -- Wine, its
/// Windows drive, the game's files and the game's Wine beside the wrapper -- sits in the one folder
/// the user chose (InstallLocation).
///
/// Daniel's own install showed why: the wrapper on 'x10', and `drive_c/HorizonXI/SquareEnix` a
/// link onto a third drive, 'Games', which went missing (2026-10-14) and took the game with it.
/// A Move therefore copies links that leave the install under the game's folder as real files:
/// the copy stands on its own. Wine's own links are left as Wine made them -- its drive letters
/// (`dosdevices`, `z:` is the whole Mac), the user folders under `drive_c/users`, and the
/// `C:\Games\<world>` links to other worlds' folders -- because they are maps of the Mac, not
/// the game. An absolute link that points inside the install is pointed at the new copy.
///
/// Nothing of the old install is changed. The copy is made under a hidden name, counted against
/// the source (files, folders, links and bytes, as the copy should be), checked for the files
/// the game cannot start without, and only then renamed into place. The old copy goes to the
/// Trash only on a yes (ContentView.finishMove); a failed copy's partial folder goes to the
/// Trash, never `rm`.
enum InstallMove {

    struct Tally: Equatable, CustomStringConvertible {
        var files = 0, dirs = 0, links = 0, other = 0
        var bytes: Int64 = 0
        var description: String { "\(files) files, \(dirs) folders, \(links) links, \(bytes) bytes" }
    }

    /// A one-line reason a Move did not happen (or failed), for the user.
    struct Refusal: LocalizedError, Equatable {
        let line: String
        init(_ l: String) { line = l }
        var errorDescription: String? { line }
    }

    /// One tree the Move copies: the wrapper, or the world's own folder when it is outside the
    /// wrapper.
    struct Part: Equatable {
        let source: URL
        /// Where it ends up, relative to the "FFXI on Mac" folder.
        let rel: String
        /// Under these source paths a link that leaves the install is data: copied as real files.
        let resolveUnder: [String]
    }

    /// A link the copy replaces: by the real files it points at, or by a link to the new copy.
    struct Fix: Equatable {
        /// The link's path inside its part's copy, relative to the part's root.
        let part: Int
        let rel: String
        /// `resolve`: the real (physical) path whose files replace the link. `relink`: the
        /// absolute source path inside the install it points at.
        let target: String
        let resolve: Bool
    }

    struct Plan {
        let install: Install
        let world: String
        var parts: [Part] = []
        /// Top-level `SharedSupport` entries left behind: the wrapper's other prefixes. The
        /// installer prefix is rebuilt on first use.
        var excluded: Set<String> = []
        var fixes: [Fix] = []
        /// The source as the copy must come out.
        var expected = Tally()
        /// Must exist in the new folder afterwards, relative to it.
        var keyFiles: [String] = []
        /// What "the old copy" is, for the Trash question.
        var oldCopy: [URL] = []
        var bytes: Int64 { expected.bytes }
    }

    // MARK: - Planning (read-only)

    /// Measures what a Move of `i` would copy. Read-only. Refuses, in one line, when anything
    /// the copy needs is behind a drive that is not there.
    static func plan(_ install: Install, world: String) throws -> Plan {
        let fm = FileManager.default
        if let d = Preflight.unavailableDrive(for: install.wrapper.path) { throw Refusal(unreachable(d)) }
        // A wrapper reached through a link (~/Applications/X.app -> a drive) is measured where it
        // really is, or every path below would compare as outside it.
        var i = install
        if let real = canonical(install.wrapper.path), real != install.wrapper.standardizedFileURL.path {
            i = Install(wrapper: URL(fileURLWithPath: real, isDirectory: true), prefixName: install.prefixName,
                        gameDirOverride: install.gameDirOverride)
            i.dataRoot = install.dataRoot; i.worldName = install.worldName; i.ownsWrapperClient = install.ownsWrapperClient
        }
        let w = i.wrapper.standardizedFileURL
        guard fm.fileExists(atPath: i.prefix.path) else {
            throw Refusal("There's no install at \(w.path) to move.")
        }
        var p = Plan(install: i, world: world)
        let shared = w.appendingPathComponent("Contents/SharedSupport")
        let kids = (try? fm.contentsOfDirectory(atPath: shared.path)) ?? []
        p.excluded = Set(kids.filter { $0.hasPrefix("prefix") && $0 != i.prefixName }.map { shared.appendingPathComponent($0).path })

        // The game's files inside the wrapper: HorizonXI's folder (also the local world's), and
        // the selected world's own when it is in the wrapper too.
        let horizon = i.driveC.appendingPathComponent("HorizonXI").standardizedFileURL.path
        var resolveIn = [horizon]
        let game = i.gameDir.standardizedFileURL.path
        if game.hasPrefix(w.path + "/"), !game.hasPrefix(horizon) { resolveIn.append(game) }
        p.parts.append(Part(source: w, rel: InstallLocation.wrapperName, resolveUnder: resolveIn))

        // The world's own folder, when it is outside the wrapper: copied to Games/<world>.
        if let chosen = i.dataRoot?.standardizedFileURL {
            if let d = Preflight.unavailableDrive(for: chosen.path) { throw Refusal(unreachable(d)) }
        }
        if let chosen = i.dataRoot, let real = canonical(chosen.path), !real.hasPrefix(w.path + "/") {
            let root = URL(fileURLWithPath: real, isDirectory: true)
            if fm.fileExists(atPath: root.path) {
                p.parts.append(Part(source: root, rel: InstallLocation.worldsFolder + "/" + world, resolveUnder: [root.path]))
            }
        }

        // The game's Wine beside the wrapper, where Setup puts it (and where Daniel's own install
        // has it): it moves too, so the new folder holds what X87Sidecar.patchedWine looks for
        // there. Its own links are relative and stay links.
        let coop = w.deletingLastPathComponent().appendingPathComponent(InstallLocation.gameWineFolder, isDirectory: true)
        if fm.isExecutableFile(atPath: coop.appendingPathComponent("wine/bin/wine").path),
           let real = canonical(coop.path),
           !p.parts.contains(where: { real == $0.source.path || real.hasPrefix($0.source.path + "/") }) {
            p.parts.append(Part(source: URL(fileURLWithPath: real, isDirectory: true), rel: InstallLocation.gameWineFolder,
                                resolveUnder: []))
        }

        let insides = p.parts.map(\.source.path)
        for (n, part) in p.parts.enumerated() {
            try measure(part, index: n, insides: insides, excluded: p.excluded, into: &p)
        }

        // What the game cannot start without, where the source had it.
        func keep(_ u: URL, _ rel: String) { if fm.fileExists(atPath: u.path) { p.keyFiles.append(rel) } }
        let wr = InstallLocation.wrapperName
        let pre = "\(wr)/Contents/SharedSupport/\(i.prefixName)"
        keep(i.wine, "\(wr)/Contents/SharedSupport/wine/bin/wine")
        keep(i.systemReg, "\(pre)/system.reg")
        if p.parts.contains(where: { $0.rel == InstallLocation.gameWineFolder }) {
            keep(coop.appendingPathComponent("wine/bin/wine"), InstallLocation.gameWineFolder + "/wine/bin/wine")
        }
        if game.hasPrefix(w.path + "/") {
            let g = "\(wr)/" + String(game.dropFirst(w.path.count + 1))
            keep(i.ashitaCLI, "\(g)/\(i.ashitaCLI.lastPathComponent)")
        }
        let se = i.squareEnix.standardizedFileURL
        for dll in ["FFXi.dll", "FFXiMain.dll", "FFXiVersions.dll"] {
            let src = se.appendingPathComponent("FINAL FANTASY XI/\(dll)")
            if let rel = newRelative(se.path, plan: p) { keep(src, "\(rel)/FINAL FANTASY XI/\(dll)") }
        }

        // The old copy: the whole wrapper, unless it holds other installs (then just this
        // prefix), plus the game data its links reached on other drives, plus the world folder
        // and the game's Wine.
        let others = p.excluded.filter { ($0 as NSString).lastPathComponent != Install.installerPrefixName }
        p.oldCopy = [others.isEmpty ? w : i.prefix.standardizedFileURL]
        for f in p.fixes where f.resolve && !p.fixes.contains(where: { $0.resolve && $0.part == f.part && f.rel.hasPrefix($0.rel + "/") }) {
            p.oldCopy.append(URL(fileURLWithPath: f.target))
        }
        p.oldCopy += p.parts.dropFirst().map(\.source)
        return p
    }

    static func unreachable(_ drive: String) -> String {
        "The '\(drive)' drive isn't connected, so the game can't be moved."
    }

    /// Where a source path (physical, possibly through a resolved link) lands in the new folder.
    private static func newRelative(_ path: String, plan p: Plan) -> String? {
        for part in p.parts where path == part.source.path || path.hasPrefix(part.source.path + "/") {
            return part.rel + String(path.dropFirst(part.source.path.count))
        }
        // Reached through a resolved link: the link's place in the copy.
        for f in p.fixes where f.resolve && (path == f.target || path.hasPrefix(f.target + "/")) {
            return p.parts[f.part].rel + "/" + f.rel + String(path.dropFirst(f.target.count))
        }
        return nil
    }

    /// Walks one part the way the copy will be, filling in `expected` and the link fixes.
    private static func measure(_ part: Part, index: Int, insides: [String], excluded: Set<String>,
                                into p: inout Plan) throws {
        let fm = FileManager.default
        let root = part.source.path
        // (physical path, path as it will be in the copy relative to the part's root, the link
        // targets already being copied on the way there)
        var stack: [(String, String, [String])] = [(root, "", [])]
        while let (phys, rel, chain) = stack.popLast() {
            let logical = rel.isEmpty ? root : root + "/" + rel
            if excluded.contains(logical) { continue }
            var st = stat()
            guard lstat(phys, &st) == 0 else {
                throw Refusal("Part of the install couldn't be read (\((phys as NSString).lastPathComponent)), so nothing was moved.")
            }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                p.expected.dirs += 1
                let kids = (try? fm.contentsOfDirectory(atPath: phys)) ?? []
                for k in kids { stack.append((phys + "/" + k, rel.isEmpty ? k : rel + "/" + k, chain)) }
            case S_IFREG:
                p.expected.files += 1
                p.expected.bytes += Int64(st.st_size)
            case S_IFLNK:
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: phys) else { p.expected.links += 1; continue }
                let parentLogical = (logical as NSString).deletingLastPathComponent
                let abs = dest.hasPrefix("/") ? normalize(dest) : normalize(parentLogical + "/" + dest)
                let inside = insides.contains { abs == $0 || abs.hasPrefix($0 + "/") }
                if inside {
                    // Relative links stay as they are; absolute ones are re-pointed at the copy.
                    if dest.hasPrefix("/") { p.fixes.append(Fix(part: index, rel: rel, target: abs, resolve: false)) }
                    p.expected.links += 1
                    continue
                }
                let underData = part.resolveUnder.contains { logical == $0 || logical.hasPrefix($0 + "/") }
                guard underData else { p.expected.links += 1; continue }   // Wine's own map of the Mac
                // Game data on another drive: copied as what it is, if it is there.
                let physAbs = dest.hasPrefix("/") ? normalize(dest) : normalize((phys as NSString).deletingLastPathComponent + "/" + dest)
                if let d = Preflight.unavailableDrive(for: physAbs) { throw Refusal(unreachable(d)) }
                // A folder that holds this link, or one already being copied on the way here,
                // would copy forever: left a link, like a dangling one or a whole drive.
                guard let real = canonical(physAbs), resolvable(real, install: insides),
                      !phys.hasPrefix(real + "/"),
                      !chain.contains(where: { $0 == real || $0.hasPrefix(real + "/") }) else {
                    p.expected.links += 1
                    continue
                }
                p.fixes.append(Fix(part: index, rel: rel, target: real, resolve: true))
                stack.append((real, rel, chain + [real]))
            default:
                p.expected.other += 1
            }
        }
    }

    /// A link's target that is safe to copy as data: not the whole Mac, a whole drive, the home
    /// folder, or a folder that holds the install itself.
    static func resolvable(_ real: String, install: [String]) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if real == "/" || real == home { return false }
        let parts = real.split(separator: "/")
        if parts.count <= 2, parts.first == "Volumes" { return false }
        return !install.contains { $0.hasPrefix(real + "/") }
    }

    static func normalize(_ path: String) -> String { (path as NSString).standardizingPath }

    static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// The real path, spelled the way `standardizedFileURL` spells the install's own paths
    /// (`/var/…` rather than `/private/var/…`), so the two can be compared.
    static func canonical(_ path: String) -> String? { realPath(path).map(normalize) }

    /// The game's files are on (or link to) another drive than the wrapper, whether or not that
    /// drive is there. Read-only: lstat/readlink, statfs.
    static func dataElsewhere(_ i: Install) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool {
            let boot: Set<String> = ["/", "/System/Volumes/Data"]
            if let a, let b, boot.contains(a), boot.contains(b) { return true }
            return a == b
        }
        let wrapperMount = Preflight.mountPoint(of: i.wrapper.path)
        let data = i.squareEnix.appendingPathComponent("FINAL FANTASY XI").path
        if let d = Preflight.unavailableDrive(for: data) { return !same(wrapperMount, "/Volumes/" + d) }
        guard let real = realPath(data) ?? realPath(i.gameDir.path) else { return false }
        return !same(wrapperMount, Preflight.mountPoint(of: real))
    }

    // MARK: - Is it free to move?

    /// What is running that a Move must not copy underneath.
    struct Activity: Equatable {
        var clientsLive = false
        var job: String? = nil
        var localServer = false
        var wineRunning = false
    }

    static func blocker(_ a: Activity) -> String? {
        if a.clientsLive { return "Close the game first, then press Move again." }
        if a.job != nil { return "Wait for the running job to finish, then press Move again." }
        if a.localServer { return "Stop the local server first, then press Move again." }
        if a.wineRunning { return "Wine is still running; press Move again in a minute." }
        return nil
    }

    /// Any wineserver on this Mac (read-only `pgrep`): one may still be writing a prefix.
    static func anyWineserver() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "wineserver"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Refusals of the destination itself (LocationPanel's `extra`): inside what is being moved,
    /// or where an install already is.
    static func destinationProblem(_ chosen: URL, plan p: Plan) -> String? {
        let folder = InstallLocation.folder(for: chosen).standardizedFileURL.path
        // Nor inside the data its links reach: that is part of the old copy the Trash may take.
        let sources = p.parts.map(\.source.path) + p.fixes.filter(\.resolve).map(\.target)
        for src in sources where folder == src || folder.hasPrefix(src + "/") {
            return "Choose a folder outside the install you're moving."
        }
        let fm = FileManager.default
        for part in p.parts where fm.fileExists(atPath: folder + "/" + part.rel) {
            return part.source.standardizedFileURL.path == folder + "/" + part.rel
                ? "The game is already in this folder."
                : "There's already an FFXI on Mac install here. Choose another folder."
        }
        return nil
    }

    // MARK: - Copying (writes only inside the new folder)

    /// Where a failed copy's partial folder goes: the Trash. The self-test points it at its own
    /// fixture folder instead.
    static var discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Copies, fixes the links, verifies, and renames into place. Returns the new install. On
    /// any failure the partial copy goes to the Trash and the old install is as it was.
    static func copy(_ p: Plan, into folder: URL, log: (String) -> Void = { _ in },
                     progress: (Double) -> Void = { _ in }) throws -> Install {
        let fm = FileManager.default
        let folder = folder.standardizedFileURL
        if let d = Preflight.unavailableDrive(for: folder.deletingLastPathComponent().path) {
            throw Refusal("The '\(d)' drive isn't connected. Choose another place.")
        }
        for part in p.parts where fm.fileExists(atPath: folder.appendingPathComponent(part.rel).path) {
            throw Refusal("There's already an FFXI on Mac install here. Choose another folder.")
        }
        let games = folder.appendingPathComponent(InstallLocation.worldsFolder)
        let made = [games, folder].filter { !fm.fileExists(atPath: $0.path) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        // Hidden while it is incomplete, so discovery never offers a half copy.
        let staged: [URL] = p.parts.map { part in
            let final = folder.appendingPathComponent(part.rel)
            return final.deletingLastPathComponent().appendingPathComponent(".\(final.lastPathComponent).moving-\(stamp)")
        }
        let freeAtStart = freeBytes(folder)
        var shown = 0.0
        func tick() {
            let done = Double(max(0, freeAtStart - freeBytes(folder)))
            let f = min(0.99, p.bytes > 0 ? done / Double(p.bytes) : 0)
            if f > shown { shown = f; progress(f) }
        }
        do {
            for (n, part) in p.parts.enumerated() {
                try fm.createDirectory(at: staged[n].deletingLastPathComponent(), withIntermediateDirectories: true)
                if n == 0 {
                    try copyWrapper(part.source, to: staged[n], excluded: p.excluded, tick: tick)
                } else {
                    try ditto(part.source.path, staged[n].path, tick: tick)
                }
            }
            // Links: shallowest first, so a link inside data that was itself behind a link is
            // there to be replaced by the time it is reached.
            let finalRoots = p.parts.map { folder.appendingPathComponent($0.rel).path }
            for f in p.fixes.sorted(by: { $0.rel.split(separator: "/").count < $1.rel.split(separator: "/").count }) {
                let at = staged[f.part].path + "/" + f.rel
                var st = stat()
                guard lstat(at, &st) == 0, st.st_mode & S_IFMT == S_IFLNK else {
                    throw Refusal("The copy came out different from the install, so nothing was switched.")
                }
                try fm.removeItem(atPath: at)            // the copy's own link, never the source
                if f.resolve {
                    log("copying \(f.target) in place of its link")
                    try ditto(f.target, at, tick: tick)
                } else {
                    let to = p.parts.indices.lazy.compactMap { k -> String? in
                        let s = p.parts[k].source.path
                        return f.target == s || f.target.hasPrefix(s + "/") ? finalRoots[k] + String(f.target.dropFirst(s.count)) : nil
                    }.first ?? f.target
                    try fm.createSymbolicLink(atPath: at, withDestinationPath: to)
                }
            }
            // The same count as the source, as the copy should be.
            var got = Tally()
            for s in staged { got = add(got, tally(s.path)) }
            guard got == p.expected else {
                log("copy: \(got); source as copied: \(p.expected)")
                throw Refusal("The copy came out different from the install, so nothing was switched.")
            }
            let missing = p.keyFiles.filter { key in
                guard let n = p.parts.firstIndex(where: { key == $0.rel || key.hasPrefix($0.rel + "/") }) else { return true }
                return !fm.fileExists(atPath: staged[n].path + String(key.dropFirst(p.parts[n].rel.count)))
            }
            guard missing.isEmpty else {
                log("copy: missing \(missing.joined(separator: ", "))")
                throw Refusal("The copy is missing game files, so nothing was switched.")
            }
            for (n, part) in p.parts.enumerated() {
                try fm.moveItem(at: staged[n], to: folder.appendingPathComponent(part.rel))
            }
            progress(1)
            var moved = Install(wrapper: InstallLocation.wrapper(in: folder), prefixName: p.install.prefixName)
            moved.worldName = p.install.worldName
            return moved
        } catch {
            // Our own partial copy: to the Trash, where it can still be looked at.
            for u in staged + p.parts.map({ folder.appendingPathComponent($0.rel) })
            where fm.fileExists(atPath: u.path) && !p.parts.contains(where: { $0.source.standardizedFileURL == u.standardizedFileURL }) {
                if (try? discard(u)) != nil { log("partial copy moved to the Trash: \(u.path)") }
            }
            // The folders this Move made, if nothing else is in them now.
            for dir in made {
                if let kids = try? fm.contentsOfDirectory(atPath: dir.path), kids.isEmpty { try? fm.removeItem(at: dir) }
            }
            throw error
        }
    }

    /// One folder copied as it is into `dest`, the way a Move copies (ExistingInstall: a HorizonXI
    /// client found on another drive than the install it joins): under a hidden name, counted
    /// against the source, and only then renamed into place. The source is never changed; its
    /// links stay links. What was at `dest` -- an empty folder, or the launcher's own unfinished
    /// download -- goes to the Trash (`discard`) only once the copy is verified, and a failed
    /// copy's partial folder goes there too.
    static func copyTree(_ source: URL, to dest: URL, log: (String) -> Void = { _ in },
                         progress: (Double) -> Void = { _ in }) throws {
        let fm = FileManager.default
        if let d = Preflight.unavailableDrive(for: source.path) {
            throw Refusal("The '\(d)' drive isn't connected, so its files can't be copied.")
        }
        let src = canonical(source.path) ?? source.standardizedFileURL.path
        let dest = dest.standardizedFileURL
        let parent = dest.deletingLastPathComponent()
        if let d = Preflight.unavailableDrive(for: parent.path) {
            throw Refusal("The '\(d)' drive isn't connected. Choose another place.")
        }
        guard dest.path != src, !dest.path.hasPrefix(src + "/") else {
            throw Refusal("The game files can't be copied into themselves.")
        }
        let expected = tally(src)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".\(dest.lastPathComponent).copying-\(Int(Date().timeIntervalSince1970))")
        let freeAtStart = freeBytes(parent)
        var shown = 0.0
        func tick() {
            let done = Double(max(0, freeAtStart - freeBytes(parent)))
            let f = min(0.99, expected.bytes > 0 ? done / Double(expected.bytes) : 0)
            if f > shown { shown = f; progress(f) }
        }
        do {
            try ditto(src, staged.path, tick: tick)
            let got = tally(staged.path)
            guard got == expected else {
                log("copy: \(got); source: \(expected)")
                throw Refusal("The copy came out different from the original, so it wasn't used.")
            }
            var st = stat()
            if lstat(dest.path, &st) == 0 {
                if st.st_mode & S_IFMT == S_IFDIR, ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? ["?"]).isEmpty {
                    try fm.removeItem(at: dest)
                } else {
                    try discard(dest)
                    log("moved to the Trash to make way for the copy: \(dest.path)")
                }
            }
            try fm.moveItem(at: staged, to: dest)
            progress(1)
        } catch {
            if fm.fileExists(atPath: staged.path), (try? discard(staged)) != nil {
                log("partial copy moved to the Trash: \(staged.path)")
            }
            throw error
        }
    }

    /// The wrapper, without its other prefixes: ditto per entry of Contents and SharedSupport.
    private static func copyWrapper(_ w: URL, to dest: URL, excluded: Set<String>, tick: () -> Void) throws {
        let fm = FileManager.default
        func children(_ u: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: u.path).sorted() }
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        for top in try children(w) {
            let s = w.appendingPathComponent(top), d = dest.appendingPathComponent(top)
            guard top == "Contents", isDir(s) else { try ditto(s.path, d.path, tick: tick); continue }
            try fm.createDirectory(at: d, withIntermediateDirectories: false)
            for c in try children(s) {
                let cs = s.appendingPathComponent(c), cd = d.appendingPathComponent(c)
                guard c == "SharedSupport", isDir(cs) else { try ditto(cs.path, cd.path, tick: tick); continue }
                try fm.createDirectory(at: cd, withIntermediateDirectories: false)
                for e in try children(cs) where !excluded.contains(cs.appendingPathComponent(e).path) {
                    try ditto(cs.appendingPathComponent(e).path, cd.appendingPathComponent(e).path, tick: tick)
                }
            }
        }
    }

    private static func isDir(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// `ditto src dst`: copies files, folders and links as they are (links are not followed),
    /// with their permissions, dates and extended attributes. Polls progress while it runs.
    private static func ditto(_ src: String, _ dst: String, tick: () -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [src, dst]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        while p.isRunning { tick(); Thread.sleep(forTimeInterval: 0.5) }
        p.waitUntilExit()
        tick()
        guard p.terminationStatus == 0 else {
            let why = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Refusal("The copy stopped: \(why.split(separator: "\n").first.map(String.init) ?? "ditto failed").")
        }
    }

    /// Counts a tree as it is: links are links, nothing is followed.
    static func tally(_ path: String) -> Tally {
        var t = Tally()
        var stack = [path]
        while let cur = stack.popLast() {
            var st = stat()
            guard lstat(cur, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                t.dirs += 1
                for k in (try? FileManager.default.contentsOfDirectory(atPath: cur)) ?? [] { stack.append(cur + "/" + k) }
            case S_IFREG: t.files += 1; t.bytes += Int64(st.st_size)
            case S_IFLNK: t.links += 1
            default: t.other += 1
            }
        }
        return t
    }

    static func add(_ a: Tally, _ b: Tally) -> Tally {
        Tally(files: a.files + b.files, dirs: a.dirs + b.dirs, links: a.links + b.links,
              other: a.other + b.other, bytes: a.bytes + b.bytes)
    }

    private static func freeBytes(_ u: URL) -> Int64 {
        Int64((try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0)
    }

    // MARK: - After the Move

    /// Every world folder that pointed inside the old wrapper, pointed at the new one; the moved
    /// world's own folder at its copy. Pure: the caller stores the result.
    static func rewrittenDataPath(_ dataPath: String, world: String, plan p: Plan, folder: URL) -> String? {
        guard !dataPath.isEmpty else { return nil }
        let path = canonical(dataPath) ?? URL(fileURLWithPath: dataPath).standardizedFileURL.path
        for (k, part) in p.parts.enumerated() where path == part.source.path || path.hasPrefix(part.source.path + "/") {
            if k > 0 && world != p.world { continue }
            return folder.standardizedFileURL.appendingPathComponent(part.rel).path + String(path.dropFirst(part.source.path.count))
        }
        return nil
    }
}
