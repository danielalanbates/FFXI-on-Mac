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

    /// The client an installer run left, best first:
    ///   1. `dataPath`, when it now holds one (the installer honoured `/D`, or wrote through a link);
    ///   2. a folder named for the world;
    ///   3. with `since` (right after a run): the newest folder changed since then.
    /// Without `since` (before asking for an installer) only 1 and 2 count, so another world's
    /// client is never taken.
    static func find(driveC: URL, world: String, dataPath: URL?, since: Date?) -> URL? {
        if let d = dataPath, holdsClient(d) { return d }
        let all = candidates(driveC: driveC)
        if let n = all.filter({ named($0.url, world: world) }).max(by: { $0.modified < $1.modified }) { return n.url }
        guard let since else { return nil }
        return all.filter { $0.modified >= since.addingTimeInterval(-60) }.max(by: { $0.modified < $1.modified })?.url
    }

    /// Bring the client at `found` into `dataPath`: each item is renamed in (same volume, so no copy
    /// and no extra space), then `found` becomes a link to `dataPath`, so the installers' registry
    /// (`C:\Eden\…`) and a later run of the same installer land there too. Nothing is overwritten:
    /// a name already in `dataPath`, another volume, or a failed rename leaves the client where it
    /// is (every item already moved goes back) and returns `found`. Returns where the client is now.
    static func adopt(_ found: URL, into dataPath: URL, log: (String) -> Void) -> URL {
        let fm = FileManager.default
        let from = found.resolvingSymlinksInPath().standardizedFileURL
        let to = dataPath.resolvingSymlinksInPath().standardizedFileURL
        if from.path == to.path { return dataPath }
        // Never into itself: a client folder that holds the world's folder.
        if to.path.hasPrefix(from.path + "/") || from.path.hasPrefix(to.path + "/") { return found }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        guard sameVolume(from, to) else {
            log("==> \(found.path) is on another drive than \(dataPath.path); the game is played from where the installer put it")
            return found
        }
        try? fm.removeItem(at: from.appendingPathComponent(".DS_Store"))
        guard let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil, options: []) else { return found }
        let taken = items.filter { lexists(to.appendingPathComponent($0.lastPathComponent).path) }
        if !taken.isEmpty {
            log("==> \(dataPath.path) already has \(taken.map(\.lastPathComponent).joined(separator: ", ")); the game is played from \(found.path)")
            return found
        }
        var moved: [URL] = []
        for item in items {
            let dest = to.appendingPathComponent(item.lastPathComponent)
            do { try fm.moveItem(at: item, to: dest); moved.append(item) } catch {
                for m in moved.reversed() { try? fm.moveItem(at: to.appendingPathComponent(m.lastPathComponent), to: m) }
                log("==> couldn't move \(item.lastPathComponent) into \(dataPath.path) (\(error.localizedDescription)); the game is played from \(found.path)")
                return found
            }
        }
        // The emptied folder becomes the link. If it cannot be replaced, the client is still whole
        // in dataPath; only a later run of the installer would write beside it again.
        if (try? fm.removeItem(at: from)) != nil {
            try? fm.createSymbolicLink(at: from, withDestinationURL: to)
        }
        log("==> moved the client from \(found.path) into \(dataPath.path)")
        return dataPath
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
    static func payloadBytes(beside exe: URL) -> Int64? {
        let dir = exe.deletingLastPathComponent()
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let archives = kids.filter { ["pak", "7z"].contains($0.pathExtension.lowercased()) }
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

    /// The first volume among `urls` with less than `need` bytes free, with what it has.
    static func shortfall(need: Int64, at urls: [URL]) -> (volume: String, free: Int64)? {
        freeBytes(urls).sorted { $0.key < $1.key }.first { $0.value < need }.map { ($0.key, $0.value) }
    }

    /// "14.6 GB".
    static func gigabytes(_ n: Int64) -> String { String(format: "%.1f GB", Double(n) / 1_000_000_000) }

    /// A volume's name for a message: "Macintosh HD" for "/", the folder name otherwise.
    static func volumeName(_ mount: String) -> String {
        mount == "/" ? "this Mac's disk" : "“\((mount as NSString).lastPathComponent)”"
    }
}
