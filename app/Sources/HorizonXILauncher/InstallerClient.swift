// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// Where a world's own Windows installer put its client, and bringing that client to the world's
/// folder. Issue #92 (2026-11-24): Eden's installer (NSIS 3.06.1, inside Eden535/534.zip) ignores
/// `/D=C:\Games\<world>` and always writes its 14.6 GB client to `C:\Eden` inside the installers'
/// prefix. "Run installer…" never looked there, so every check kept pointing at the empty
/// `Games/<world>` folder, and Setup asked for the installer again. Measured on this Mac with the
/// launcher's own Wine: the install itself finishes in about 2.5 minutes, exit 0.
///
/// Everything here is plain file work, off the main actor, so `--selftest-installer` runs it on
/// fixture folders.
enum InstallerClient {
    /// Folders a Windows installer makes its program folder in: `C:\`, `C:\Games` and both
    /// Program Files.
    static func containers(_ driveC: URL) -> [URL] {
        [driveC, driveC.appendingPathComponent("Games"),
         driveC.appendingPathComponent("Program Files"), driveC.appendingPathComponent("Program Files (x86)")]
    }

    /// `C:\`'s own folders, which are never a client.
    static let systemFolders: Set<String> = ["windows", "users", "programdata", "program files", "program files (x86)", "games"]

    /// The archives the installer itself left in a world's folder (`installer-downloads`) are not
    /// its client.
    static let downloadsFolder = "installer-downloads"

    /// Does `dir` hold a client: Ashita (v4 `Ashita-cli.exe` or v3 `injector.exe`) within three
    /// levels, or Square Enix's game files.
    static func holdsClient(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("SquareEnix/FINAL FANTASY XI/FFXiMain.dll").path) { return true }
        return Install.ashitaCandidates(under: dir).contains { !$0.pathComponents.contains(downloadsFolder) }
    }

    struct Candidate: Equatable {
        var url: URL
        var modified: Date
    }

    /// Real folders (never a link: a link in `C:\Games` is another world's folder) under the
    /// containers that hold a client.
    static func candidates(driveC: URL) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        for container in containers(driveC) {
            guard let kids = try? fm.contentsOfDirectory(
                at: container, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for k in kids {
                if container == driveC, systemFolders.contains(k.lastPathComponent.lowercased()) { continue }
                guard let v = try? k.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]),
                      v.isSymbolicLink != true, v.isDirectory == true, holdsClient(k) else { continue }
                // A re-run that only rewrote files leaves the folder's own date alone; Ashita's folder
                // (or the game's) dates it better.
                var newest = v.contentModificationDate ?? .distantPast
                for sub in ["Ashita", "SquareEnix"] {
                    if let d = (try? k.appendingPathComponent(sub).resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, d > newest { newest = d }
                }
                out.append(Candidate(url: k, modified: newest))
            }
        }
        return out
    }

    static func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Is `dir` named for `world` ("Eden" for "eden" or "Eden XI").
    static func named(_ dir: URL, world: String) -> Bool {
        let a = squash(dir.lastPathComponent), b = squash(world)
        guard a.count >= 3, b.count >= 3 else { return a == b && !a.isEmpty }
        return a.contains(b) || b.contains(a)
    }

    /// Left in a folder an installer run was stopped in, or failed in (issue #92 review): a
    /// half-written client must never be taken for one later. A run that finishes clears it.
    static let incompleteMarker = ".ffxi-on-mac-incomplete"

    static func isMarkedIncomplete(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(incompleteMarker).path)
    }

    /// The game's own files are all there: the three DLLs Repair needs (`Runner.repairBlocker`),
    /// in any layout the launcher reads (SquareEnix beside or inside Ashita, CatsEye's Game/).
    static func hasGameFiles(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let need = ["FFXi.dll", "FFXiMain.dll", "FFXiVersions.dll"]
        for se in ["SquareEnix/FINAL FANTASY XI", "Game/SquareEnix/FINAL FANTASY XI", "Game/FINAL FANTASY XI", "FINAL FANTASY XI"] {
            let d = dir.appendingPathComponent(se)
            if need.allSatisfy({ fm.fileExists(atPath: d.appendingPathComponent($0).path) }) { return true }
        }
        return false
    }

    /// Every candidate as it is now, path to date: taken just before a run, so only what the run
    /// made or changed counts as its result.
    static func snapshot(driveC: URL) -> [String: Date] {
        Dictionary(candidates(driveC: driveC).map { ($0.url.path, $0.modified) }, uniquingKeysWith: { a, _ in a })
    }

    /// What a run made or changed, against the `before` snapshot.
    static func changed(_ c: Candidate, before: [String: Date]) -> Bool {
        guard let was = before[c.url.path] else { return true }
        return c.modified > was
    }

    /// The client an installer run left, best first:
    ///   1. a real folder the run made or changed (`before` is the snapshot from just before it),
    ///      named for the world first;
    ///   2. a folder named for the world;
    ///   3. `dataPath`, when it holds one (the installer honoured `/D`, or wrote through a link).
    /// Without `before` (looking for one an earlier run left, before asking for an installer) only a
    /// folder named for the world counts, and only when it is complete (`hasGameFiles`) and not
    /// marked incomplete, so another world's client or a stopped run's half is never taken.
    static func find(driveC: URL, world: String, dataPath: URL?, before: [String: Date]?) -> URL? {
        let all = candidates(driveC: driveC)
        guard let before else {
            return all.filter { named($0.url, world: world) && !isMarkedIncomplete($0.url) && hasGameFiles($0.url) }
                .max { $0.modified < $1.modified }?.url
        }
        let fresh = all.filter { changed($0, before: before) }
        if let n = fresh.filter({ named($0.url, world: world) }).max(by: { $0.modified < $1.modified }) { return n.url }
        if let n = fresh.max(by: { $0.modified < $1.modified }) { return n.url }
        if let n = all.filter({ named($0.url, world: world) }).max(by: { $0.modified < $1.modified }) { return n.url }
        if let d = dataPath, holdsClient(d) { return d }
        return nil
    }

    /// Real folders (never links) in the containers, `C:\`'s own excepted: what an installer may
    /// have started writing, client yet or not.
    static func realFolders(driveC: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for container in containers(driveC) {
            guard let kids = try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { continue }
            for k in kids {
                if container == driveC, systemFolders.contains(k.lastPathComponent.lowercased()) { continue }
                guard let v = try? k.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                      v.isSymbolicLink != true, v.isDirectory == true else { continue }
                out.append(k)
            }
        }
        return out
    }

    /// After a run that was stopped or failed: everything it made or changed (a client yet or not:
    /// a later run may finish it), and the folder named for the world, is marked so that no later
    /// look takes it for a finished client.
    static func markIncomplete(driveC: URL, world: String, before: [String: Date], began: Date) {
        let fm = FileManager.default
        let changedClients = Set(candidates(driveC: driveC).filter { changed($0, before: before) }.map(\.url.path))
        for dir in realFolders(driveC: driveC) {
            let made = ((try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate).map { $0 >= began.addingTimeInterval(-2) } ?? false
            guard named(dir, world: world) || made || changedClients.contains(dir.path) else { continue }
            fm.createFile(atPath: dir.appendingPathComponent(incompleteMarker).path, contents: Data())
        }
    }

    /// What a folder named for the world already holds before a run writes over it (a stopped run's
    /// half): counted towards the button's figure, which otherwise only sees new space being used.
    static func alreadyThere(driveC: URL, world: String) -> Int64 {
        realFolders(driveC: driveC).filter { named($0, world: world) }.compactMap(treeBytes).reduce(0, +)
    }

    /// Bring the client at `found` into `dataPath`: each item is renamed in (same volume, so no copy
    /// and no extra space), then `found` becomes a link to `dataPath`, so the installers' registry
    /// (`C:\Eden\…`) and a later run of the same installer land there too. On another volume the
    /// items are copied (after a space check) and the originals removed. Nothing in `dataPath` is
    /// overwritten: a name already there, or a failed rename or copy, leaves the client where it is
    /// (whatever was already moved goes back) and returns `found`. Returns where the client is now.
    static func adopt(_ found: URL, into dataPath: URL, log: (String) -> Void) -> URL {
        let fm = FileManager.default
        let from = found.resolvingSymlinksInPath().standardizedFileURL
        let to = dataPath.resolvingSymlinksInPath().standardizedFileURL
        if from.path == to.path { try? fm.removeItem(at: to.appendingPathComponent(incompleteMarker)); return dataPath }
        // Never into itself: a client folder that holds the world's folder.
        if to.path.hasPrefix(from.path + "/") || from.path.hasPrefix(to.path + "/") { return found }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        try? fm.removeItem(at: from.appendingPathComponent(".DS_Store"))
        try? fm.removeItem(at: from.appendingPathComponent(incompleteMarker))
        guard let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil, options: []) else { return found }
        let taken = items.filter { lexists(to.appendingPathComponent($0.lastPathComponent).path) }
        if !taken.isEmpty {
            log("!! \(dataPath.path) already has \(taken.map(\.lastPathComponent).joined(separator: ", ")), so the new copy was left at \(found.path).")
            return found
        }
        if sameVolume(from, to) {
            var moved: [URL] = []
            for item in items {
                do { try fm.moveItem(at: item, to: to.appendingPathComponent(item.lastPathComponent)); moved.append(item) } catch {
                    for m in moved.reversed() { try? fm.moveItem(at: to.appendingPathComponent(m.lastPathComponent), to: m) }
                    log("!! Couldn't move \(item.lastPathComponent) into \(dataPath.path) (\(error.localizedDescription)); the game is played from \(found.path).")
                    return found
                }
            }
        } else {
            // Another drive (a world folder chosen apart from the wrapper): a copy, never a client
            // left inside the installers' prefix, which Move… does not carry.
            let need = treeBytes(from)
            if let need, let short = shortfall(need: need + 1_000_000_000, at: [to]) {
                log("!! \(found.path) is \(gigabytes(need)); \(volumeName(short.volume)) has \(gigabytes(short.free)) free, so the game is played from there.")
                return found
            }
            var copied: [URL] = []
            for item in items {
                let dest = to.appendingPathComponent(item.lastPathComponent)
                let d = Process(); d.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); d.arguments = [item.path, dest.path]
                d.standardOutput = FileHandle.nullDevice; d.standardError = FileHandle.nullDevice
                guard (try? d.run()) != nil else { break }
                d.waitUntilExit()
                guard d.terminationStatus == 0 else {
                    try? fm.removeItem(at: dest)
                    for c in copied { try? fm.removeItem(at: c) }
                    log("!! Couldn't copy \(item.lastPathComponent) into \(dataPath.path); the game is played from \(found.path).")
                    return found
                }
                copied.append(dest)
            }
            guard copied.count == items.count else {
                for c in copied { try? fm.removeItem(at: c) }
                return found
            }
            for item in items { try? fm.removeItem(at: item) }
        }
        // The emptied folder becomes the link. rmdir, never a recursive delete: anything that
        // appeared in it meanwhile stays (and so does the folder; only a later run would write
        // beside the client again).
        if rmdir(from.path) == 0 {
            try? fm.createSymbolicLink(at: from, withDestinationURL: to)
        }
        log("==> moved the client from \(found.path) into \(dataPath.path)")
        return dataPath
    }

    /// Bytes under `dir` (du), nil when it cannot be read.
    static func treeBytes(_ dir: URL) -> Int64? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/du"); p.arguments = ["-sk", dir.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let k = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.flatMap({ Int64($0) })
        else { return nil }
        return k * 1024
    }

    /// Before a run: a link an earlier adoption left in `C:\` for this world (`C:\Eden`) points at
    /// the world's folder as it is now, so the installer writes there and not into a folder the
    /// world has since moved from.
    static func repointLinks(driveC: URL, world: String, to dataPath: URL) {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: driveC, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
        else { return }
        let target = dataPath.resolvingSymlinksInPath().path
        for k in kids where named(k, world: world) && !systemFolders.contains(k.lastPathComponent.lowercased()) {
            guard (try? k.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  k.resolvingSymlinksInPath().path != target else { continue }
            try? fm.removeItem(at: k)
            try? fm.createSymbolicLink(at: k, withDestinationURL: dataPath)
        }
    }

    static func lexists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev
    }

    // MARK: - How big, and how far

    /// What an installer will write, when its payload sits beside it as an archive bsdtar can list
    /// (Eden's `data.pak` is a 7z: 14,623,105,145 bytes listed in about a second). Nil otherwise.
    ///
    /// `ownFolder`: the installer is in a folder this job unpacked, so every .pak/.7z there is its
    /// payload. Otherwise (an .exe picked in Downloads, say) only a `data.pak` counts: unrelated
    /// archives beside it must not make the job refuse for want of space.
    static func payloadBytes(beside exe: URL, ownFolder: Bool) -> Int64? {
        let dir = exe.deletingLastPathComponent()
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let archives = kids.filter {
            ownFolder ? ["pak", "7z"].contains($0.pathExtension.lowercased()) : $0.lastPathComponent.lowercased() == "data.pak"
        }
        let sizes = archives.compactMap(archiveBytes)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// The unpacked size of an archive (zip, 7z, …) from its own listing, by /usr/bin/bsdtar.
    static func archiveBytes(_ archive: URL) -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        p.arguments = ["-tvf", archive.path]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return listedBytes(String(decoding: data, as: UTF8.self))
    }

    /// Sum of the regular files' sizes in a `bsdtar -tv` listing
    /// ("-rw-r--r--  0 0      0   12345 Apr  5  2023 name"). Nil when nothing is listed.
    static func listedBytes(_ listing: String) -> Int64? {
        var total: Int64 = 0, files = 0
        for line in listing.split(whereSeparator: \.isNewline) where line.hasPrefix("-") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count > 4, let n = Int64(f[4]) else { continue }
            total += n; files += 1
        }
        return files > 0 ? total : nil
    }

    /// Free bytes on each distinct volume holding one of `urls` (the nearest existing folder
    /// counts), keyed by its mount point.
    static func freeBytes(_ urls: [URL]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for u in urls {
            var p = u.standardizedFileURL
            while !FileManager.default.fileExists(atPath: p.path), p.pathComponents.count > 1 { p = p.deletingLastPathComponent() }
            var st = statfs()
            guard statfs(p.path, &st) == 0 else { continue }
            let mount = withUnsafeBytes(of: st.f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            out[mount] = Int64(st.f_bavail) * Int64(st.f_bsize)
        }
        return out
    }

    /// Bytes written since `baseline`, over the same volumes (free space that went). Space that came
    /// back (a purge) counts as nothing written.
    static func written(since baseline: [String: Int64], now: [String: Int64]) -> Int64 {
        baseline.reduce(0) { sum, kv in sum + max(0, kv.value - (now[kv.key] ?? kv.value)) }
    }

    /// When no volume among `urls` has `need` bytes free: the first of them (the one a message
    /// names) and what it has. An installer writes to one of them, and which one is its own choice.
    static func shortfall(need: Int64, at urls: [URL]) -> (volume: String, free: Int64)? {
        let free = freeBytes(urls)
        guard !free.isEmpty, free.values.allSatisfy({ $0 < need }) else { return nil }
        let first = urls.first.flatMap { u in freeBytes([u]).first } ?? free.first!
        return (first.key, first.value)
    }

    /// "14.6 GB".
    static func gigabytes(_ n: Int64) -> String { String(format: "%.1f GB", Double(n) / 1_000_000_000) }

    /// A volume's name for a message: "Macintosh HD" for "/", the folder name otherwise.
    static func volumeName(_ mount: String) -> String {
        mount == "/" ? "this Mac's disk" : "“\((mount as NSString).lastPathComponent)”"
    }
}
