// Copyright (c) 2026 Bates LLC. All rights reserved.

import Darwin
import Foundation

/// A new install's macros, equipment sets, keybinds and addon settings, carried over from the
/// install played before it.
///
/// Daniel, 2026-10-15: the install Setup made that day started with none of them. FFXI keeps them
/// per character in `SquareEnix/FINAL FANTASY XI/USER/<character id>/` (mcr*.dat macros, es*.dat
/// equipment sets, keybinds, filters, menu state), beside a few files of its own in USER (tig.dat,
/// cmb*.dat). Ashita keeps each addon's settings in `config/addons/<addon>/<name>_<id>/`, its
/// window layout in `config/imgui.ini` and each plugin's own in `config/<plugin>/`. A fresh
/// download has none of it. It was put back by hand that evening (what that replaced is in
/// `USER.bak-2026-10-15-before-restore` and `config.bak-2026-10-15-before-restore`). Now the
/// launcher does it.
///
/// **What is carried**, from the client's folder:
/// - `SquareEnix/FINAL FANTASY XI/USER/**`, every file.
/// - `config/**`, except `boot/` (the boot profiles: the launcher writes them, and they hold the
///   account and password), `ashita/` (Ashita's memory signatures, which belong to the Ashita
///   build beside them), `sandbox/` and `pivot/` (the launcher keeps both right for each install:
///   Sandbox, Branding). What is left is `addons/` (every addon's settings, LuAshitacast's gear
///   sets among them), `imgui.ini`, and the plugins' own folders (minimap, nameplate, Shorthand…).
/// - Not `scripts/default.txt`, which says what loads. HorizonXI's own launcher owns two blocks
///   of it and HorizonXI's updates change it, so an old copy can load what the new client lacks
///   or drop what it needs; the Addons… sheet sets it again in a minute. The manual restore left
///   it alone too.
/// - A link inside those folders is counted and skipped, never followed. The folders themselves
///   may be links (siku.app's SquareEnix leads to another drive), and those are followed.
///
/// **When.** Once per install, by itself, and only for HorizonXI's client (the worlds whose
/// client Setup downloads): right after Setup has downloaded it (`.setup`) or, when it could not
/// run then (a game was running, the install played before could not be read), before that
/// install's first Play (`.play`). Never again once it has run, found nothing to copy, or been
/// skipped: the marker `.ffxi-on-mac-carryover` in the client's folder says which.
/// `--carryover-apply` does it by hand.
///
/// **Only into a fresh install.** An install is fresh while no folder in its USER holds a file:
/// FFXI makes a character's folder the first time that character logs in there, and writes its
/// macro files then (b66's install had mcr.dat, mcr1.dat and mcr9.dat minutes after its first
/// login). Into a fresh install, what is missing is added and what differs (a file the new client
/// shipped) is replaced, after a copy of it goes to `<USER|config>.bak-<date>-carryover` beside
/// it. Once a character has logged in there, nothing is carried by itself. By hand, into such an
/// install, only what is missing is added: whole character folders it does not have, and files
/// outside them that it does not have. Nothing is replaced then.
///
/// **From where.** The installs the launcher knows: the one in use before Setup, every install
/// the scan found, a client the user chose not to use. The one whose USER has the newest file
/// wins. One that cannot be read, or whose drive is not there, is never chosen; when the install
/// in use before Setup is one of those, Setup waits for it, and the first Play takes the best
/// that can be read.
///
/// **How.** With the launch lock held and no game running anywhere: every file is copied into a
/// hidden folder beside its destination (`copyfile`, attributes and dates kept) and compared byte
/// for byte with its source; each file it replaces is copied to the backup folder and compared
/// the same way; only then is each moved into place, one rename per file that never writes over
/// anything it did not check. A failure before that point leaves the install as it was. From that
/// point the marker says `applying`: a copy cut short (the launcher quit) is finished the next
/// time, adding only what is still missing.
enum CarryOver {

    // MARK: - Where

    /// One client's two folders. `config` is nil for a SquareEnix folder on its own.
    struct Side: Equatable {
        /// The client's folder (Ashita's), or the SquareEnix folder: where the marker goes.
        var root: URL
        var user: URL
        var config: URL?
        /// It is there but can't be read (no permission, macOS privacy, a link that loops, a
        /// drive not connected): why. Its contents are unknown, not absent.
        var unreadable: String? = nil
    }

    static func userFolder(in squareEnix: URL) -> URL {
        squareEnix.appendingPathComponent("FINAL FANTASY XI", isDirectory: true).appendingPathComponent("USER", isDirectory: true)
    }

    /// An install's, for whichever world it was resolved for.
    static func side(_ i: Install) -> Side {
        Side(root: i.gameDir, user: userFolder(in: i.squareEnix),
             config: i.gameDir.appendingPathComponent("config", isDirectory: true))
    }

    /// What a folder names: a wrapper (.app, its prefix that holds HorizonXI), an "FFXI on Mac"
    /// folder (or the one it is in), a client folder (Ashita's, or the only one at most three
    /// folders down), or a SquareEnix folder (USER only). nil when it is none of them, or holds
    /// more than one client. A folder that is there but can't be read is a side that says so.
    static func side(at url: URL) -> Side? {
        let fm = FileManager.default
        let u = url.standardizedFileURL
        func unreadable(_ why: String) -> Side {
            Side(root: u, user: userFolder(in: u.appendingPathComponent("SquareEnix")),
                 config: u.appendingPathComponent("config", isDirectory: true), unreadable: why)
        }
        if let d = Preflight.unavailableDrive(for: u.path) { return unreadable("the '\(d)' drive isn't connected") }
        var lst = stat()
        guard lstat(u.path, &lst) == 0 else {
            let e = errno
            return e == ENOENT || e == ENOTDIR ? nil : unreadable("it can't be read (\(String(cString: strerror(e))))")
        }
        do { _ = try fm.contentsOfDirectory(atPath: u.path) } catch {
            var st = stat()
            if stat(u.path, &st) == 0, st.st_mode & S_IFMT != S_IFDIR { return nil }
            return unreadable("it can't be read (\(reason(error)))")
        }
        if u.pathExtension.lowercased() == "app" {
            return ExistingInstall.wrapper(at: u).map { side($0.0) }
        }
        // The folder Setup makes ("FFXI on Mac"), or the one it was made in.
        for w in [InstallLocation.wrapper(in: u), InstallLocation.wrapper(in: InstallLocation.folder(for: u))]
        where fm.fileExists(atPath: w.path) {
            return ExistingInstall.wrapper(at: w).map { side($0.0) }
        }
        if fm.fileExists(atPath: u.appendingPathComponent("FINAL FANTASY XI").path) {
            return Side(root: u, user: userFolder(in: u), config: nil)
        }
        if !Install.isAshitaDir(u), clients(under: u) > 1 { return nil }
        let ashita = Install.resolveAshitaDir(u)
        guard Install.isAshitaDir(ashita) else { return nil }
        let se = Install.resolveSquareEnix(gameDir: ashita, root: u)
        return Side(root: ashita, user: userFolder(in: se), config: ashita.appendingPathComponent("config", isDirectory: true))
    }

    /// How many clients (Ashita folders) are at or under `u`, three folders down: a folder that
    /// holds several (`~/Games/FFXI`) names none of them.
    static func clients(under u: URL) -> Int { Install.ashitaCandidates(under: u).count }

    /// Where a HorizonXI client Setup downloads may find its macros and settings, the likeliest
    /// first: HorizonXI's client in `base` (the install in use, or `install.last` while its drive
    /// is gone), that wrapper's own, each of `installs`, and the install Setup made in each
    /// folder chosen before. `candidates` drops repeats and the destination.
    static func knownRoots(base: Install?, horizon: Server?, installs: [Install]) -> [URL] {
        var out: [URL] = []
        if let b = base {
            if let h = horizon { out.append(b.forServer(h).gameDir) }
            out.append(b.gameDir)
        }
        out += installs.map(\.gameDir)
        for f in [InstallLocation.remembered].compactMap({ $0 }) + InstallLocation.earlier {
            out.append(InstallLocation.install(in: f).gameDir)
        }
        return out
    }

    /// The real path of a side's USER folder (its FINAL FANTASY XI folder's, then "/USER"), which
    /// is what tells two sides apart: links, a second wrapper on the same files, the same folder
    /// spelled two ways. nil when there is no FINAL FANTASY XI folder to follow (or it loops).
    static func identity(_ s: Side) -> String? {
        guard s.unreadable == nil else { return nil }
        return InstallMove.canonical(s.user.deletingLastPathComponent().path).map { $0 + "/USER" }
    }

    // MARK: - Reading (read-only)

    /// Config folders never carried (see the type's comment). Compared without case.
    static let configSkipped: Set<String> = ["boot", "ashita", "sandbox", "pivot"]
    static let ignoredNames: Set<String> = [".DS_Store"]
    /// Far beyond any USER or config folder (Daniel's: about 1,250 files, 35 MB, most of it
    /// Vanaguide's nav grids). A folder over either is refused rather than walked: it is not one.
    static let maxFiles = 50_000
    static let maxBytes: Int64 = 2_000_000_000

    struct File: Equatable {
        var rel: String
        var size: Int64
        var modified: Date
    }

    /// One folder read: its files (sorted by path), the links skipped, and why it could not be
    /// read in full. A folder that is not there reads as empty, with no problem.
    struct Tree: Equatable {
        var files: [File] = []
        var links = 0
        var problem: String?

        var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
        var newest: Date? { files.map(\.modified).max() }

        /// The folders directly inside with a file somewhere in them: in USER, the characters
        /// that have logged in. Lowercased when `folded`.
        func characters(folded: Bool = true) -> Set<String> {
            Set(files.compactMap { CarryOver.character(of: $0.rel, folded: folded) })
        }
    }

    static func character(of rel: String, folded: Bool) -> String? {
        guard let slash = rel.firstIndex(of: "/") else { return nil }
        let c = String(rel[..<slash])
        return folded ? c.lowercased() : c
    }

    static func read(_ dir: URL, skipping top: Set<String> = []) -> Tree {
        var t = Tree()
        if let d = Preflight.unavailableDrive(for: dir.path) { t.problem = "the '\(d)' drive isn't connected"; return t }
        var st = stat()
        guard lstat(dir.path, &st) == 0 else {
            // Not there is empty; anything else (no permission, macOS privacy) is unknown.
            let e = errno
            if e != ENOENT && e != ENOTDIR { t.problem = "it can't be read (\(String(cString: strerror(e))))" }
            return t
        }
        guard let real = InstallMove.realPath(dir.path) else {
            t.problem = "it can't be followed (\(String(cString: strerror(errno))))"
            return t
        }
        guard stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { t.problem = "it isn't a folder"; return t }
        var total: Int64 = 0
        var stack = [""]
        while let rel = stack.popLast() {
            let path = rel.isEmpty ? real : real + "/" + rel
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: path) } catch {
                t.problem = (rel.isEmpty ? "it" : rel) + " can't be read (\(reason(error)))"
                return t
            }
            for n in names.sorted() where !ignoredNames.contains(n) {
                if rel.isEmpty, top.contains(n.lowercased()) { continue }
                let r = rel.isEmpty ? n : rel + "/" + n
                var s = stat()
                guard lstat(path + "/" + n, &s) == 0 else {
                    t.problem = r + " can't be read (\(String(cString: strerror(errno))))"
                    return t
                }
                switch s.st_mode & S_IFMT {
                case S_IFDIR:
                    stack.append(r)
                case S_IFREG:
                    t.files.append(file(s, rel: r))
                    total += Int64(s.st_size)
                    if t.files.count > maxFiles || total > maxBytes {
                        t.problem = "it holds more than \(maxFiles) files or \(maxBytes / 1_000_000_000) GB"
                        return t
                    }
                case S_IFLNK:
                    t.links += 1
                default:
                    continue
                }
            }
        }
        t.files.sort { $0.rel < $1.rel }
        return t
    }

    private static func file(_ s: stat, rel: String) -> File {
        let m = Date(timeIntervalSince1970: TimeInterval(s.st_mtimespec.tv_sec) + TimeInterval(s.st_mtimespec.tv_nsec) / 1e9)
        return File(rel: rel, size: Int64(s.st_size), modified: m)
    }

    /// One file's size and date as `read` takes them, or nil when it is not a regular file.
    static func facts(_ path: String, rel: String) -> File? {
        var s = stat()
        guard lstat(path, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { return nil }
        return file(s, rel: rel)
    }

    private static func reason(_ error: Error) -> String {
        let e = error as NSError
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(u.code)))
        }
        if e.domain == NSCocoaErrorDomain, e.code == NSFileReadNoPermissionError { return "permission denied" }
        return e.localizedDescription
    }

    /// Is the volume `u` is on (its nearest existing folder) case-insensitive, as APFS and HFS+
    /// are by default? Two names that differ only in case are then one file.
    static func caseInsensitive(_ u: URL) -> Bool {
        var p = u.standardizedFileURL
        while !FileManager.default.fileExists(atPath: p.path), p.path != "/" { p = p.deletingLastPathComponent() }
        return (try? p.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames != true
    }

    // MARK: - Candidates

    struct Candidate: Equatable {
        var side: Side
        var identity: String?
        var user: Tree
        var config: Tree

        var characters: Int { user.characters().count }
        /// Why it cannot be used, if it cannot.
        var problem: String? {
            user.problem ?? config.problem ?? (identity == nil ? "its FINAL FANTASY XI folder isn't there" : nil)
        }
        var usable: Bool { problem == nil && characters > 0 }
        /// Its files may be there but can't be read now (a drive not connected, no permission):
        /// what is in it is unknown, not absent.
        var unreachable: Bool { user.problem != nil || config.problem != nil }
    }

    static func survey(_ s: Side) -> Candidate {
        if let why = s.unreadable { return Candidate(side: s, identity: nil, user: Tree(problem: why), config: Tree()) }
        return Candidate(side: s, identity: identity(s), user: read(s.user),
                         config: s.config.map { read($0, skipping: configSkipped) } ?? Tree())
    }

    /// Each folder in `roots` that is a client, read, in order: never `dest`'s own files, and each
    /// USER folder once however many ways it is reached.
    static func candidates(_ roots: [URL], dest: Side) -> [Candidate] {
        let destID = identity(dest)
        var ids = Set<String>(), paths = Set<String>()
        var out: [Candidate] = []
        for r in roots {
            guard paths.insert(r.standardizedFileURL.path).inserted, let s = side(at: r) else { continue }
            let id = identity(s)
            if let id {
                guard id != destID, ids.insert(id).inserted else { continue }
            } else {
                guard paths.insert("user:" + s.user.standardizedFileURL.path).inserted else { continue }
            }
            out.append(survey(s))
        }
        return out
    }

    /// The candidate to copy from: readable, with characters, its USER's newest file the newest
    /// of all (the earlier in the list when equal). nil when none can be used.
    static func choose(_ c: [Candidate]) -> Candidate? {
        c.enumerated().filter { $0.element.usable }.max { a, b in
            let x = a.element.user.newest ?? .distantPast, y = b.element.user.newest ?? .distantPast
            if x != y { return x < y }
            return a.offset > b.offset
        }?.element
    }

    // MARK: - Plan

    /// `fresh`: no character has played in the destination. `played`: one has. `finishing`: a
    /// copy that was cut short, finished: every file still missing, nothing replaced.
    enum Mode: String, Equatable { case fresh, played, finishing }
    enum Area: String, Equatable, CaseIterable { case user = "USER", config = "config" }

    struct Item: Equatable {
        var area: Area
        /// The source file, relative to its area folder.
        var rel: String
        /// Where it goes, relative to the destination's area folder: the name the destination
        /// already has for it when it is replaced.
        var target: String
        var size: Int64
        var replaces: Bool
        /// The destination's file as the plan saw it, for one that is replaced: if it is not
        /// the same when the copy runs, it is left alone.
        var was: File? = nil
    }

    struct Plan: Equatable {
        var mode: Mode
        var items: [Item] = []
        /// Already there, byte for byte.
        var same = 0
        /// Different, or in a character folder that has played here, and left as it is.
        var kept = 0
        var charactersAdded: [String] = []
        var charactersKept: [String] = []
        /// Two source names the same but for case, for a destination that cannot tell them apart:
        /// the older is not copied.
        var clashes = 0

        var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
        var replaced: Int { items.filter(\.replaces).count }
        var added: Int { items.count - replaced }
        func count(_ a: Area, replaces r: Bool) -> Int { items.filter { $0.area == a && $0.replaces == r }.count }
        func bytes(_ a: Area) -> Int64 { items.filter { $0.area == a }.reduce(0) { $0 + $1.size } }
    }

    /// What copying `user`/`config` onto `destUser`/`destConfig` does. Names are compared without
    /// case on a drive that ignores it, each folder by its own drive (`caseInsensitive` for USER,
    /// `configCaseInsensitive` for config, the same when not given). `same(area, source rel,
    /// destination rel)` compares two files' bytes; it is asked only when their sizes match.
    static func plan(user: Tree, config: Tree, destUser: Tree, destConfig: Tree, caseInsensitive ci: Bool,
                     configCaseInsensitive: Bool? = nil, finishing: Bool = false,
                     same: (Area, String, String) -> Bool) -> Plan {
        let destChars = destUser.characters(folded: ci)
        var p = Plan(mode: finishing ? .finishing : destChars.isEmpty ? .fresh : .played)
        for (area, src, dst, folded) in [(Area.user, user, destUser, ci), (Area.config, config, destConfig, configCaseInsensitive ?? ci)] {
            func key(_ s: String) -> String { folded ? s.lowercased() : s }
            var have: [String: File] = [:]
            for f in dst.files { have[key(f.rel)] = f }
            var pick: [String: File] = [:]
            var order: [String] = []
            for f in src.files {
                let k = key(f.rel)
                if let o = pick[k] {
                    p.clashes += 1
                    if f.modified > o.modified { pick[k] = f }
                } else {
                    pick[k] = f
                    order.append(k)
                }
            }
            for k in order {
                guard let f = pick[k] else { continue }
                if area == .user, p.mode == .played, let c = character(of: f.rel, folded: ci), destChars.contains(c) {
                    p.kept += 1
                    continue
                }
                guard let d = have[k] else {
                    p.items.append(Item(area: area, rel: f.rel, target: f.rel, size: f.size, replaces: false))
                    continue
                }
                if d.size == f.size, same(area, f.rel, d.rel) { p.same += 1; continue }
                if p.mode == .fresh {
                    p.items.append(Item(area: area, rel: f.rel, target: d.rel, size: f.size, replaces: true, was: d))
                } else {
                    p.kept += 1
                }
            }
        }
        let srcChars = user.characters(folded: ci)
        p.charactersAdded = srcChars.subtracting(destChars).sorted()
        p.charactersKept = p.mode == .played ? srcChars.intersection(destChars).sorted() : []
        return p
    }

    /// The same, from a candidate onto a destination already read.
    static func plan(from c: Candidate, to dest: Side, destUser: Tree, destConfig: Tree, finishing: Bool = false) -> Plan {
        let fm = FileManager.default
        return plan(user: c.user, config: dest.config == nil ? Tree() : c.config, destUser: destUser, destConfig: destConfig,
                    caseInsensitive: caseInsensitive(dest.user),
                    configCaseInsensitive: dest.config.map(caseInsensitive), finishing: finishing) { area, s, d in
            guard let from = area == .user ? c.side.user : c.side.config,
                  let to = area == .user ? dest.user : dest.config else { return false }
            return fm.contentsEqual(atPath: from.appendingPathComponent(s).path, andPath: to.appendingPathComponent(d).path)
        }
    }

    static func readDest(_ dest: Side) -> (user: Tree, config: Tree) {
        (read(dest.user), dest.config.map { read($0, skipping: configSkipped) } ?? Tree())
    }

    // MARK: - Copying

    struct Outcome: Equatable {
        var added = 0, replaced = 0
        /// Changed (or appeared) in the destination after the plan: left as it is.
        var skipped = 0
        var bytes: Int64 = 0
        var backups: [URL] = []
        /// "<area>/<path>: why", for each file that could not be put in place.
        var failed: [String] = []
    }

    struct Refusal: LocalizedError, Equatable {
        let line: String
        init(_ l: String) { line = l }
        var errorDescription: String? { line }
    }

    /// What the copy needs from the Mac. `live` is the real one; the self-test makes its own.
    struct Environment {
        /// A game client, injector or x87 sidecar of any world is running.
        var gameRunning: () -> Bool
        /// The launch lock: no launch, Repair or Stop of any launcher starts while it is held.
        var lock: () -> Int32?
        var unlock: (Int32) -> Void
        /// Free bytes where a folder is, and whether that is the Mac's own disk.
        var space: (URL) -> (free: Int64, boot: Bool)
        var now: () -> Date

        static let live = Environment(
            gameRunning: {
                let s = LiveClients.snapshot()
                return !s.clients.isEmpty || !s.sidecars.isEmpty
            },
            lock: { LaunchLock.acquire() },
            unlock: { LaunchLock.release($0) },
            space: { u in
                let f = InstallLocation.facts(for: u)
                return (f.freeBytes, f.isBootVolume)
            },
            now: Date.init)
    }

    /// "2026-10-15", for the backup folder's name, in the Mac's own time zone.
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func lexists(_ p: String) -> Bool { var st = stat(); return lstat(p, &st) == 0 }

    /// A folder's real path, made or not: its own when it is there (a link followed), else its
    /// parent's real path and its name. nil when neither is there.
    static func realFolder(_ u: URL) -> String? {
        if lexists(u.path) { return InstallMove.canonical(u.path) }
        return InstallMove.canonical(u.deletingLastPathComponent().path).map { $0 + "/" + u.lastPathComponent }
    }

    /// Is `path` (made or not) really inside `root` (a real path)? Its nearest part that is there
    /// is followed through every link and must be `root` or below it.
    static func inside(_ path: String, _ root: String) -> Bool {
        var p = path
        while !lexists(p), p != "/", !p.isEmpty { p = (p as NSString).deletingLastPathComponent }
        guard let real = InstallMove.canonical(p) else { return false }
        return real == root || real.hasPrefix(root + "/")
    }

    /// Copy one regular file, attributes and dates included, never through a link, never over
    /// anything. A file system that refuses the extended attributes or ACL gets the data and the
    /// POSIX attributes (mode, dates).
    static func copyFile(_ src: String, _ dst: String) -> Bool {
        if copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 { return true }
        // Something was already there: never removed. Otherwise it is this call's own half-copy.
        guard errno != EEXIST else { return false }
        unlink(dst)
        return copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0
    }

    /// `<folder>.bak-<day>-carryover` beside `folder`, or with -2, -3… when that is taken.
    static func backupFolder(beside folder: String, day d: String) -> String {
        let base = folder + ".bak-\(d)-carryover"
        var u = base, n = 2
        while lexists(u) { u = base + "-\(n)"; n += 1 }
        return u
    }

    private static let stagingTag = ".carryover-"

    /// Carry `p` out (see the type's comment). Throws, having changed nothing in `to`, when a
    /// copy or a backup fails or there is not room. `beforeCommit` runs once everything is copied
    /// and backed up, just before the first file goes into place; after that each file that cannot
    /// be put in place is listed in `failed` and the rest go in. The caller holds the launch lock
    /// and has made sure no game is running.
    static func apply(_ p: Plan, from: Side, to: Side, env: Environment = .live,
                      beforeCommit: () -> Void = {}) throws -> Outcome {
        let fm = FileManager.default
        var o = Outcome()
        guard !p.items.isEmpty else { return o }
        struct Part { var area: Area; var src: String; var dst: String; var items: [Item] }
        var parts: [Part] = []
        for a in Area.allCases {
            let items = p.items.filter { $0.area == a }
            guard !items.isEmpty else { continue }
            guard let s = a == .user ? from.user : from.config, let d = a == .user ? to.user : to.config,
                  let src = InstallMove.canonical(s.path), let dst = realFolder(d) else {
                throw Refusal("the \(a.rawValue) folder isn't there to copy \(a == .user ? "from" : "into")")
            }
            guard dst != src, !dst.hasPrefix(src + "/"), !src.hasPrefix(dst + "/") else {
                throw Refusal("the two \(a.rawValue) folders are the same folder")
            }
            parts.append(Part(area: a, src: src, dst: dst, items: items))
        }
        // Room on each drive written to, for the copies and the backups, and what stays free on
        // the Mac's own disk.
        var need: [dev_t: (at: URL, bytes: Int64)] = [:]
        for a in parts {
            let parent = (a.dst as NSString).deletingLastPathComponent
            var st = stat()
            let dev = stat(parent, &st) == 0 ? st.st_dev : 0
            let n = a.items.reduce(Int64(0)) { $0 + $1.size + ($1.replaces ? ($1.was?.size ?? $1.size) : 0) }
            need[dev] = (URL(fileURLWithPath: parent), (need[dev]?.bytes ?? 0) + n)
        }
        for (_, w) in need {
            let room = env.space(w.at)
            let total = w.bytes + (room.boot ? InstallLocation.bootFloor : 0)
            guard room.free >= total else {
                throw Refusal("not enough space: \(InstallLocation.gb(room.free)) free, \(InstallLocation.gb(total)) needed")
            }
        }

        // 1. Every file into a hidden folder beside its destination, compared with its source.
        var staging: [Area: String] = [:]
        func discardStaging() { for s in staging.values { try? fm.removeItem(atPath: s) } }
        var backups: [Area: String] = [:]
        func discardBackups() { for b in backups.values { try? fm.removeItem(atPath: b) } }
        for a in parts {
            let dir = (a.dst as NSString).deletingLastPathComponent
            let name = (a.dst as NSString).lastPathComponent
            // An earlier run that never finished (the launcher quit mid-copy) left only copies here.
            for old in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where old.hasPrefix("." + name + stagingTag) {
                try? fm.removeItem(atPath: dir + "/" + old)
            }
            let s = dir + "/." + name + stagingTag + UUID().uuidString
            do { try fm.createDirectory(atPath: s, withIntermediateDirectories: true) } catch {
                discardStaging()
                throw Refusal("couldn't make a folder beside \(name) (\(reason(error)))")
            }
            staging[a.area] = s
            for it in a.items {
                let src = a.src + "/" + it.rel, tmp = s + "/" + it.target
                do { try fm.createDirectory(atPath: (tmp as NSString).deletingLastPathComponent, withIntermediateDirectories: true) } catch {
                    discardStaging()
                    throw Refusal("couldn't copy \(a.area.rawValue)/\(it.rel) (\(reason(error)))")
                }
                let copied = copyFile(src, tmp)
                let why = copied ? "the copy came out different" : String(cString: strerror(errno))
                guard copied, fm.contentsEqual(atPath: src, andPath: tmp) else {
                    discardStaging()
                    throw Refusal("couldn't copy \(a.area.rawValue)/\(it.rel) (\(why))")
                }
            }
        }
        // 2. Each file that will be replaced, copied aside and compared: only one still as the
        // plan saw it (written meanwhile, it is newer than anything carried, and stays).
        let d = day(env.now())
        var changed = Set<String>()
        for a in parts {
            for it in a.items where it.replaces {
                let now = facts(a.dst + "/" + it.target, rel: it.target)
                if now == nil || now?.size != it.was?.size || now?.modified != it.was?.modified {
                    changed.insert(a.area.rawValue + "/" + it.target)
                }
            }
        }
        for a in parts where a.items.contains(where: { $0.replaces && !changed.contains(a.area.rawValue + "/" + $0.target) }) {
            let b = backupFolder(beside: a.dst, day: d)
            backups[a.area] = b
            for it in a.items where it.replaces && !changed.contains(a.area.rawValue + "/" + it.target) {
                let cur = a.dst + "/" + it.target, saved = b + "/" + it.target
                var ok = (try? fm.createDirectory(atPath: (saved as NSString).deletingLastPathComponent, withIntermediateDirectories: true)) != nil
                ok = ok && copyFile(cur, saved) && fm.contentsEqual(atPath: cur, andPath: saved)
                guard ok else {
                    discardStaging(); discardBackups()
                    throw Refusal("couldn't keep a copy of \(a.area.rawValue)/\(it.target), so nothing was replaced")
                }
            }
        }
        // 3. Into place, one rename each, never writing over anything that was not checked, never
        // through a link out of the destination folder, and no folder made outside it.
        beforeCommit()
        for a in parts {
            guard let s = staging[a.area] else { continue }
            if !lexists(a.dst) {
                do { try fm.createDirectory(atPath: a.dst, withIntermediateDirectories: false) } catch {
                    o.failed.append("\(a.area.rawValue): \(reason(error))")
                    continue
                }
            }
            for it in a.items {
                let tmp = s + "/" + it.target, dst = a.dst + "/" + it.target
                let dir = (dst as NSString).deletingLastPathComponent
                if changed.contains(a.area.rawValue + "/" + it.target) || !inside(dir, a.dst) {
                    o.skipped += 1
                    continue
                }
                do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
                    o.failed.append("\(a.area.rawValue)/\(it.target): \(reason(error))")
                    continue
                }
                guard inside(dir, a.dst) else { o.skipped += 1; continue }
                if it.replaces {
                    let saved = backups[a.area].map { $0 + "/" + it.target } ?? ""
                    guard facts(dst, rel: it.target) != nil else { o.skipped += 1; continue }
                    // Swapped in, and what came out must be what was backed up; else it goes back.
                    if renamex_np(tmp, dst, UInt32(RENAME_SWAP)) == 0 {
                        if fm.contentsEqual(atPath: tmp, andPath: saved) {
                            o.replaced += 1; o.bytes += it.size
                        } else {
                            _ = renamex_np(tmp, dst, UInt32(RENAME_SWAP))
                            o.skipped += 1
                        }
                        continue
                    }
                    let e = errno
                    guard e == ENOTSUP || e == EINVAL else {
                        o.failed.append("\(a.area.rawValue)/\(it.target): \(String(cString: strerror(e)))")
                        continue
                    }
                    // A file system without the swap: compared, then renamed over.
                    guard fm.contentsEqual(atPath: dst, andPath: saved) else { o.skipped += 1; continue }
                    guard rename(tmp, dst) == 0 else {
                        o.failed.append("\(a.area.rawValue)/\(it.target): \(String(cString: strerror(errno)))")
                        continue
                    }
                    o.replaced += 1; o.bytes += it.size
                } else {
                    // Never over something that appeared meanwhile.
                    if renamex_np(tmp, dst, UInt32(RENAME_EXCL)) == 0 { o.added += 1; o.bytes += it.size; continue }
                    let e = errno
                    if e == EEXIST { o.skipped += 1; continue }
                    guard e == ENOTSUP || e == EINVAL else {
                        o.failed.append("\(a.area.rawValue)/\(it.target): \(String(cString: strerror(e)))")
                        continue
                    }
                    guard !lexists(dst) else { o.skipped += 1; continue }
                    guard rename(tmp, dst) == 0 else {
                        o.failed.append("\(a.area.rawValue)/\(it.target): \(String(cString: strerror(errno)))")
                        continue
                    }
                    o.added += 1; o.bytes += it.size
                }
            }
        }
        discardStaging()
        o.backups = parts.compactMap { backups[$0.area] }.map { URL(fileURLWithPath: $0) }
        return o
    }

    // MARK: - Once per install

    /// What happened, kept in the client's folder (`.ffxi-on-mac-carryover`). Paths only: no
    /// file's contents, nothing from a boot profile.
    struct Record: Codable, Equatable {
        /// `applying`: files were going into place when it last ran; finished next time.
        enum State: String, Codable { case pending, applying, done, skipped, nothing }
        var state: State
        var date: Date
        /// The client copied from.
        var from: String? = nil
        /// Pending: the folders of the installs known when Setup ran, tried again at Play.
        var hints: [String]? = nil
        var files: Int? = nil
        var replaced: Int? = nil
        var bytes: Int64? = nil
        var why: String? = nil
    }

    static let markerName = ".ffxi-on-mac-carryover"
    static func marker(_ root: URL) -> URL { root.appendingPathComponent(markerName) }

    static func record(_ root: URL) -> Record? {
        guard let d = FileManager.default.contents(atPath: marker(root).path) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Record.self, from: d)
    }

    @discardableResult
    static func write(_ r: Record, _ root: URL) -> Bool {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(r) else { return false }
        return (try? d.write(to: marker(root), options: .atomic)) != nil
    }

    /// Setup left a carry-over (or one cut short) for this install's next Play. One small read.
    static func isPending(_ i: Install) -> Bool {
        guard let s = record(i.gameDir)?.state else { return false }
        return s == .pending || s == .applying
    }

    /// Before Setup downloads a client into `i`: a pending marker holding the folders Setup knows
    /// now, so a launcher quit in the middle of the download still knows them afterwards. Leaves
    /// any other marker alone. Never makes a folder on a drive that is not there.
    static func prepare(_ i: Install, known: [URL], now: Date = Date()) {
        let root = i.gameDir
        let rec = record(root)
        guard rec == nil || rec?.state == .pending else { return }
        guard Preflight.unavailableDrive(for: root.path) == nil,
              FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path) else { return }
        var hints = rec?.hints ?? []
        for p in known.map({ $0.standardizedFileURL.path }) where !hints.contains(p) { hints.append(p) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        write(Record(state: .pending, date: now, hints: hints, why: "Setup is downloading the client"), root)
    }

    enum Trigger { case setup, play }

    /// What `automatic` did: a line for launcher.log (nil: nothing to say), and what it waits for
    /// when it could not run.
    struct Result: Equatable {
        enum Wait: Equatable { case game, launch, other }
        var line: String? = nil
        var waits: Wait? = nil
    }

    /// The carry-over by itself: right after Setup downloaded a client into `dest` (`.setup`), or
    /// before a Play when one is pending or was cut short (`.play`; nothing otherwise). `known`:
    /// the folders of the installs the launcher knows, the install in use before Setup first.
    /// Reads and copies files: never on the main thread.
    static func automatic(_ trigger: Trigger, dest i: Install, known: [URL], env: Environment = .live) -> Result {
        let dest = side(i)
        let rec = record(dest.root)
        let finishing = rec?.state == .applying
        if let r = rec, r.state != .pending, !finishing { return Result() }
        if trigger == .play, rec == nil { return Result() }
        // No game in this folder (yet): nothing to carry into.
        guard FileManager.default.fileExists(atPath: dest.user.deletingLastPathComponent().path) else { return Result() }
        var hints: [String] = []
        for p in (rec?.hints ?? []) + known.map({ $0.standardizedFileURL.path }) where !hints.contains(p) { hints.append(p) }
        func wait(_ why: String, _ kind: Result.Wait = .other, failed: Bool = false) -> Result {
            // A copy already going into place stays `applying`: it is finished, never begun afresh.
            write(Record(state: finishing ? .applying : .pending, date: env.now(), from: rec?.from, hints: hints, why: why), dest.root)
            return Result(line: (failed ? "!! " : "i  ") + "carry-over of macros and settings waits (\(why)); it runs before this install's next Play",
                          waits: kind)
        }
        func played(_ t: Tree) -> Result? {
            guard !finishing, !t.characters().isEmpty else { return nil }
            write(Record(state: .skipped, date: env.now(), why: "a character has played in this install"), dest.root)
            return Result(line: "i  carry-over of macros and settings: not done, a character has already played in this install")
        }
        let first = read(dest.user)
        if let p = first.problem { return wait("this install's USER folder can't be read: \(p)") }
        if let r = played(first) { return r }
        guard let fd = env.lock() else { return wait("a launch is under way", .launch) }
        defer { env.unlock(fd) }
        if env.gameRunning() { return wait("a game is running", .game) }
        // Read again under the lock, with nothing running.
        let (destUser, destConfig) = readDest(dest)
        if let p = destUser.problem ?? destConfig.problem { return wait("this install's folders can't be read: \(p)") }
        if let r = played(destUser) { return r }
        let best: Candidate
        if finishing {
            // Cut short last time: the same client, and only what is still missing.
            guard let from = rec?.from, let s = side(at: URL(fileURLWithPath: from)) else {
                return wait("the client it was copying from isn't there")
            }
            let c = survey(s)
            if c.identity == nil || c.unreachable { return wait("\(from) can't be read now: \(c.problem ?? "")") }
            best = c
        } else {
            let found = candidates(hints.map { URL(fileURLWithPath: $0) }, dest: dest)
            // The first is the install in use before Setup: the one played last. When it can't be
            // read, Setup waits for it rather than take an older one; the next Play, the last
            // chance before a character logs in here, takes the best there is.
            if trigger == .setup, let f = found.first, f.unreachable, let why = f.problem {
                return wait("\(f.side.root.path) can't be read now: \(why)")
            }
            guard let b = choose(found) else {
                if let w = found.first(where: \.unreachable), let why = w.problem {
                    return wait("\(w.side.root.path) can't be read now: \(why)")
                }
                write(Record(state: .nothing, date: env.now(), why: "no earlier install with characters"), dest.root)
                return Result(line: "i  carry-over of macros and settings: no earlier install with characters to copy from")
            }
            best = b
        }
        let p = plan(from: best, to: dest, destUser: destUser, destConfig: destConfig, finishing: finishing)
        do {
            let o = try apply(p, from: best.side, to: dest, env: env, beforeCommit: {
                write(Record(state: .applying, date: env.now(), from: best.side.root.path, hints: hints,
                             why: "files were going into place"), dest.root)
            })
            if !o.failed.isEmpty {
                // The rest is in place; what is still missing is added next time.
                write(Record(state: .applying, date: env.now(), from: best.side.root.path, hints: hints,
                             why: "\(o.failed.count) not put in place: \(o.failed[0])"), dest.root)
                let line = String(summary(o, plan: p, from: best.side).dropFirst(4))
                return Result(line: "!! " + line + "; what is missing is added before the next Play", waits: .other)
            }
            write(Record(state: .done, date: env.now(), from: best.side.root.path, files: o.added + o.replaced,
                         replaced: o.replaced, bytes: o.bytes), dest.root)
            return Result(line: summary(o, plan: p, from: best.side))
        } catch {
            let why = (error as? Refusal)?.line ?? error.localizedDescription
            return wait("the copy from \(best.side.root.path) failed, nothing was changed: \(why)", failed: true)
        }
    }

    /// One line for launcher.log.
    static func summary(_ o: Outcome, plan p: Plan, from: Side) -> String {
        let mb = String(format: "%.1f MB", Double(o.bytes) / 1e6)
        var s = "==> carried over macros and settings from \(from.root.path): "
            + (p.mode == .finishing ? "finished a copy cut short, " : "\(p.charactersAdded.count) characters, ")
            + "\(o.added + o.replaced) files (\(mb))"
        if o.replaced > 0 { s += "; \(o.replaced) replaced, the originals kept in " + o.backups.map(\.lastPathComponent).joined(separator: ", ") }
        if o.skipped > 0 { s += "; \(o.skipped) left as they were (changed meanwhile)" }
        if !o.failed.isEmpty { s += "; \(o.failed.count) could not be put in place, first \(o.failed[0])" }
        return s
    }
}
