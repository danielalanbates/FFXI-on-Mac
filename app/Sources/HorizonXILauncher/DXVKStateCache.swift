// Copyright (c) 2026 Bates LLC. All rights reserved.

import CryptoKit
import Foundation

/// DXVK's pipeline state cache, carried from one install and one session to the next.
///
/// Daniel, 2026-10-15: "whenever I run around and it loads a new character, my computer freezes
/// for like 5 seconds while it renders". DXVK 1.10.3 builds a pipeline the first time a draw
/// needs it -- SPIR-V, then MoltenVK's MSL, then Metal's compiler, on the thread that draws -- and
/// appends what it built to `<exe>.dxvk-cache` in DXVK_STATE_CACHE_PATH (`C:\dxvk-cache`, see
/// Settings). The next session reads that file and builds those pipelines on background threads
/// as soon as their shaders appear. The install Setup made that day had no file to start from:
/// 184 pipelines by mid-session, 169 of which siku.app's cache (1,132, 2026-10-02) already held.
/// Nothing carried them across, so a new install, or one moved to a new folder, starts cold.
///
/// So the launcher keeps one copy per executable on the Mac (`masterDir`), and
/// - before Play, with no client running anywhere, merges it into the prefix's file (`warm`);
/// - after a session, merges the prefix's files back into it (`keep`);
/// - the first time, seeds it from the caches in the installs it already knows (`seedIfNeeded`).
///
/// The file, DXVK 1.10.3 (`src/dxvk/dxvk_state_cache.cpp`, `dxvk_state_cache_types.h`; the lines
/// are quoted in docs/BETA-63.md):
/// - a 12-byte header: magic "DXVK", version u32 = 10, entrySize u32 = 0 ("no longer meaningful");
/// - then entries back to back: u32 `{ stageMask : 8, entrySize : 24 }`, the SHA-1 of the data
///   (20 bytes), and the data itself (at most 1024 bytes): shader keys, render pass, state.
///
/// DXVK skips an entry whose SHA-1 does not match or whose data does not decode, then rewrites
/// the file with only the good ones; a half-written entry at the end it ignores without a word
/// (and later appends after it). A file of another version it converts (2-9) or empties (newer).
/// What is merged here is exactly what DXVK would load: an entry is kept only if its hash matches
/// and it decodes the way `readCacheEntry` decodes it. Entries are compared byte for byte -- DXVK
/// writes a pipeline from a zeroed state (`std::memset` in its constructors), so the same
/// pipeline is always the same bytes. A file that is not version 10 is never written; as a
/// source it is skipped.
enum DXVKStateCache {
    static let magic: [UInt8] = Array("DXVK".utf8)
    static let version: UInt32 = 10
    static let headerSize = 12
    /// u32 stageMask/entrySize + SHA-1.
    static let entryHeaderSize = 4 + 20
    /// `DxvkStateCacheEntryData::MaxSize`.
    static let maxEntryData = 1024
    /// Far above any real cache (FFXI's: ~300 bytes an entry, ~1,100 entries), so a stray huge
    /// file is refused instead of read into an 8 GB Mac's memory.
    static let maxFileBytes = 32 << 20
    static let fileExtension = "dxvk-cache"

    // Sizes in the data, DXVK 1.10.3 (dxvk_shader_key.h, dxvk_bind_mask.h, dxvk_graphics_state.h).
    // Checked against Daniel's real caches: every one of 1,335 entries decodes to its last byte.
    private static let shaderKeySize = 4 + 20      // VkShaderStageFlags + Sha1Hash
    private static let bindingMaskSize = 384 / 32 * 4  // DxvkBindingSet<MaxNumActiveBindings = 384>
    private static let computeBit: UInt8 = 0x20    // VK_SHADER_STAGE_COMPUTE_BIT
    private static let maxRenderTargets = 8, maxVertexAttributes = 32, maxVertexBindings = 32
    private static let maxSpecConstants = 12

    /// Where the launcher keeps its own copy, one file per executable.
    static let masterDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HorizonXI-on-Mac/dxvk-cache", isDirectory: true)

    /// DXVK_STATE_CACHE_PATH (`C:\dxvk-cache`) on the Mac side.
    static func cacheDir(_ i: Install) -> URL { i.driveC.appendingPathComponent("dxvk-cache", isDirectory: true) }

    /// DXVK names the file after the executable that created the device, minus a `.exe` in any
    /// case (`env::getExeBaseName`): horizon-loader.exe writes horizon-loader.dxvk-cache.
    static func fileName(exe: String) -> String {
        var base = exe.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? exe
        if base.lowercased().hasSuffix(".exe") { base = String(base.dropLast(4)) }
        return base + "." + fileExtension
    }

    // MARK: - Reading

    /// What DXVK would load from one file.
    struct Contents: Equatable {
        var version: UInt32 = DXVKStateCache.version
        /// Every entry DXVK would load, as stored (entry header, SHA-1, data), in file order;
        /// a repeat of an earlier one is left out.
        var entries: [Data] = []
        /// Entries DXVK skips: SHA-1 mismatch, data that does not decode, a size over 1024.
        var invalid = 0
        var duplicates = 0
        /// Bytes after the last whole entry (a write cut short).
        var tailBytes = 0
        /// Exactly what a merge would write: nothing to drop.
        var clean: Bool { invalid == 0 && duplicates == 0 && tailBytes == 0 }
    }

    enum Read: Equatable {
        /// No file, or an empty one -- which DXVK treats the same: it cannot read a header and
        /// starts a new file.
        case absent
        case ok(Contents)
        /// Not something to merge with, and why. Never written over.
        case unusable(String)
    }

    static func read(_ url: URL) -> Read {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return fm.fileExists(atPath: url.path) ? .unusable("unreadable") : .absent
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { return .unusable("not a file") }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size == 0 { return .absent }
        guard size <= maxFileBytes else { return .unusable("\(size) bytes, over \(maxFileBytes)") }
        guard let data = try? Data(contentsOf: url) else { return .unusable("unreadable") }
        return parse(data)
    }

    /// `DxvkStateCache::readCacheFile` for a version-10 file, entry by entry as its stream reads.
    static func parse(_ file: Data) -> Read {
        let b = [UInt8](file)
        if b.isEmpty { return .absent }
        // readCacheHeader: 12 bytes, then the magic.
        guard b.count >= headerSize, Array(b[0..<4]) == magic else { return .unusable("not a DXVK state cache") }
        let ver = u32(b, 4), entrySizeField = u32(b, 8)
        // Version 8 on: "expectedSize = newHeader.entrySize" (0); anything else and DXVK discards
        // the file ("State cache entry size changed").
        guard ver == version else { return .unusable("state cache version \(ver), not \(version)") }
        guard entrySizeField == 0 else { return .unusable("header entry size \(entrySizeField), not 0") }
        var c = Contents()
        var seen = Set<Data>()
        var at = headerSize
        while true {
            // A short entry header or data: the stream fails and DXVK stops, counting nothing.
            guard at + entryHeaderSize <= b.count else { c.tailBytes = b.count - at; break }
            let packed = u32(b, at)
            let stageMask = UInt8(packed & 0xFF), size = Int(packed >> 8)
            // readFromStream refuses a size over MaxSize *without reading it*: DXVK counts the
            // entry invalid and reads its next header from right after this one's hash.
            if size > maxEntryData { c.invalid += 1; at += entryHeaderSize; continue }
            guard at + entryHeaderSize + size <= b.count else { c.tailBytes = b.count - at; break }
            let hash = b[(at + 4)..<(at + entryHeaderSize)]
            let data = Array(b[(at + entryHeaderSize)..<(at + entryHeaderSize + size)])
            let record = Data(b[at..<(at + entryHeaderSize + size)])
            at += entryHeaderSize + size
            guard Array(Insecure.SHA1.hash(data: data)) == Array(hash), decodes(stageMask: stageMask, data: data) else {
                c.invalid += 1
                continue
            }
            if seen.insert(record).inserted { c.entries.append(record) } else { c.duplicates += 1 }
        }
        return .ok(c)
    }

    /// `DxvkStateCache::readCacheEntry`, version 10, after its hash check: does the data decode?
    /// A read that does not fit fails without consuming anything, as `DxvkStateCacheEntryData::read`
    /// does; a missing shader key is not checked at all (DXVK ignores that read's result), and
    /// bytes left over at the end are allowed.
    static func decodes(stageMask: UInt8, data: [UInt8]) -> Bool {
        var at = 0
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard at + n <= data.count else { return nil }
            defer { at += n }
            return data[at..<(at + n)]
        }
        for i in 0..<6 where stageMask & (1 << i) != 0 { _ = take(shaderKeySize) }
        if stageMask & computeBit != 0 {
            guard take(bindingMaskSize) != nil else { return false }
        } else {
            // Packed render pass: sample count, depth format and layout, then format and layout
            // of each of the 8 render targets; `validateRenderPassFormat` on the result.
            guard let rp = take(3) else { return false }
            let depthFormat = rp[rp.startIndex + 1], depthLayout = rp[rp.startIndex + 2]
            // GENERAL, DEPTH_STENCIL_ATTACHMENT_OPTIMAL, DEPTH_STENCIL_READ_ONLY_OPTIMAL, and the two
            // packed as 0x80/0x81 (DEPTH_READ_ONLY_STENCIL_ATTACHMENT / ..._STENCIL_READ_ONLY).
            if depthFormat != 0, ![1, 3, 4, 0x80, 0x81].contains(depthLayout) { return false }
            for _ in 0..<maxRenderTargets {
                guard let t = take(2) else { return false }
                // GENERAL or COLOR_ATTACHMENT_OPTIMAL.
                if t[t.startIndex] != 0, ![1, 2].contains(t[t.startIndex + 1]) { return false }
            }
            // bsBindingMask, ia (2), il (2), rs (4), ms (4), ds (2), om (2), dsFront (4), dsBack (4).
            guard take(bindingMaskSize) != nil, take(2) != nil, let il = take(2), take(4) != nil, take(4) != nil,
                  take(2) != nil, take(2) != nil, take(4) != nil, take(4) != nil else { return false }
            let attributes = Int(il[il.startIndex]), bindings = Int(il[il.startIndex + 1])
            guard attributes <= maxVertexAttributes, bindings <= maxVertexBindings else { return false }
            // Swizzles (1 each), blend (4 each), then the attributes and bindings in use (4 each).
            for _ in 0..<maxRenderTargets { guard take(1) != nil else { return false } }
            for _ in 0..<maxRenderTargets { guard take(4) != nil else { return false } }
            for _ in 0..<attributes { guard take(4) != nil else { return false } }
            for _ in 0..<bindings { guard take(4) != nil else { return false } }
        }
        // The non-zero specialization constants: a mask, then one u32 per bit set.
        guard let m = take(4) else { return false }
        let mask = u32(Array(m), 0)
        for i in 0..<maxSpecConstants where mask & (1 << i) != 0 {
            guard take(4) != nil else { return false }
        }
        return true
    }

    /// The bytes of a cache holding `entries`, as DXVK writes a new file: header, then entries.
    static func encode(_ entries: [Data]) -> Data {
        var out = Data(magic)
        withUnsafeBytes(of: version.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { out.append(contentsOf: $0) }
        for e in entries { out.append(e) }
        return out
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    // MARK: - Merging

    /// Lets a caller that stops waiting be sure the rename does not happen after it moved on:
    /// once `close` returns, a merge either has renamed already or never will.
    final class CommitGate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var line: String?
        private var done = false

        func commit(_ rename: () -> Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if closed { return false }
            done = rename()
            return done
        }

        /// The rename happened (whether or not the caller was still waiting for it).
        var renamed: Bool { lock.lock(); defer { lock.unlock() }; return done }

        /// The caller has stopped waiting: write nothing more beside the target either.
        var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

        func close() { lock.lock(); closed = true; lock.unlock() }

        /// What the merge reported, for the caller that waited.
        var result: String? {
            get { lock.lock(); defer { lock.unlock() }; return line }
            set { lock.lock(); line = newValue; lock.unlock() }
        }
    }

    struct Merge: Equatable {
        var target: URL
        /// Entries DXVK would load from the target, before and after.
        var before = 0
        var after = 0
        var added: Int { after - before }
        /// The target was (or, on a dry run, would be) rewritten.
        var wrote = false
        /// The target is left exactly as it was, and why.
        var refused: String? = nil
        /// Sources not merged, and why (a missing source is not listed).
        var skipped: [String] = []
    }

    /// Adds every entry of `sources` that the target lacks, keeping every one it has. Writes only
    /// when that changes what DXVK would load or drops something it would skip (bad entries,
    /// repeats, a cut-off tail), and then whole: a file beside the target, read back and checked,
    /// renamed over it. Refuses -- target untouched -- when the target is not a version-10 cache,
    /// or changed while this ran. `write: false` reports what would happen and writes nothing.
    static func merge(_ sources: [URL], into target: URL, write: Bool = true, gate: CommitGate? = nil) -> Merge {
        var m = Merge(target: target)
        let stamp = Self.stamp(target)
        var base = Contents()
        var exists = false
        switch read(target) {
        case .absent: break
        case .unusable(let why): m.refused = why; return m
        case .ok(let c): base = c; exists = true
        }
        m.before = base.entries.count
        var all = base.entries
        var seen = Set(all)
        for s in sources where s.standardizedFileURL != target.standardizedFileURL {
            switch read(s) {
            case .absent: continue
            case .unusable(let why): m.skipped.append("\(s.path): \(why)")
            case .ok(let c):
                for e in c.entries where seen.insert(e).inserted { all.append(e) }
            }
        }
        m.after = all.count
        // Nothing to add and nothing to drop: leave the file alone. Never create an empty one.
        if m.added == 0, exists ? base.clean : true { return m }
        m.wrote = true
        guard write else { return m }
        if let why = writeAtomically(encode(all), entries: all.count, to: target, unchanged: stamp, gate: gate) {
            m.wrote = false
            m.refused = why
            m.after = m.before
        }
        return m
    }

    private struct Stamp: Equatable { let size: Int; let modified: Date? }

    private static func stamp(_ u: URL) -> Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return nil }
        return Stamp(size: (a[.size] as? NSNumber)?.intValue ?? -1, modified: a[.modificationDate] as? Date)
    }

    /// nil once `bytes` is the target; otherwise why not (and the target is as it was).
    private static func writeAtomically(_ bytes: Data, entries: Int, to target: URL, unchanged: Stamp?,
                                        gate: CommitGate?) -> String? {
        let fm = FileManager.default
        // Play stopped waiting while this read: the client may be starting in that prefix, so not
        // even a temp file or a folder goes into it now.
        if gate?.isClosed == true { return "not renamed in time" }
        let dir = target.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).\(getpid()).tmp")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }
        guard fm.createFile(atPath: tmp.path, contents: bytes) else { return "could not write \(tmp.lastPathComponent)" }
        if let h = try? FileHandle(forWritingTo: tmp) { try? h.synchronize(); try? h.close() }
        // What is on disk, not what was meant: read back, every entry valid and none missing.
        guard case .ok(let back) = read(tmp), back.clean, back.entries.count == entries else {
            return "written copy did not read back whole"
        }
        // A DXVK writer (or anything else) appended meanwhile: replacing the file would lose that.
        guard stamp(target) == unchanged else { return "changed while merging" }
        var renameErrno: Int32 = 0
        let renamed = { () -> Bool in
            if rename(tmp.path, target.path) == 0 { return true }
            renameErrno = errno
            return false
        }
        guard gate.map({ $0.commit(renamed) }) ?? renamed() else {
            return renameErrno == 0 ? "not renamed in time" : "rename failed: \(String(cString: strerror(renameErrno)))"
        }
        return nil
    }

    // MARK: - The launcher's copy

    /// One merge into `master` at a time, across processes (the window, `--play`, the headless
    /// commands). nil when another holds it past `seconds`.
    static func locked<T>(_ master: URL, seconds: Double = 5, _ work: () -> T) -> T? {
        try? FileManager.default.createDirectory(at: master, withIntermediateDirectories: true)
        // Close-on-exec: a game spawned while this is held must not inherit the lock.
        let fd = open(master.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(seconds)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline { return nil }
            usleep(50_000)
        }
        defer { flock(fd, LOCK_UN) }
        return work()
    }

    private static func describe(_ m: Merge, _ name: String) -> String {
        if let r = m.refused { return "\(name) left as it was (\(r))" }
        if !m.wrote { return "\(name) already has all \(m.after)" }
        return m.added > 0 ? "\(name) +\(m.added) (\(m.before) -> \(m.after))" : "\(name) rewritten without bad entries (\(m.after))"
    }

    /// Before Play, with no client running anywhere: everything the launcher's copy holds for
    /// `exe` goes into the prefix's cache, so DXVK starts with it. Returns the launcher.log line.
    static func warm(_ i: Install, exe: String, master: URL = masterDir, gate: CommitGate? = nil) -> String {
        let name = fileName(exe: exe)
        let source = master.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return "dxvk cache: no Mac copy of \(name) yet; the prefix keeps its own"
        }
        guard let m = locked(master, { merge([source], into: cacheDir(i).appendingPathComponent(name), gate: gate) }) else {
            return "dxvk cache: \(name) not warmed (the Mac copy is busy)"
        }
        return "dxvk cache: prefix " + describe(m, name) + m.skipped.map { "; skipped \($0)" }.joined()
    }

    /// After a session: every cache in the prefix goes into the launcher's copy. Read-only on the
    /// prefix, so another client still playing there does not matter (a half-appended entry at
    /// the end is not whole yet and is left for the next time).
    static func keep(_ i: Install, master: URL = masterDir) -> String {
        let caches = files(in: cacheDir(i))
        guard !caches.isEmpty else { return "dxvk cache: nothing in \(cacheDir(i).path) to keep" }
        guard let lines = locked(master, {
            caches.map { c -> String in
                let m = merge([c], into: master.appendingPathComponent(c.lastPathComponent))
                return describe(m, c.lastPathComponent) + m.skipped.map { "; skipped \($0)" }.joined()
            }
        }) else { return "dxvk cache: not kept on the Mac (the Mac copy is busy)" }
        return "dxvk cache: Mac copy " + lines.joined(separator: ", ")
    }

    /// The first time this runs (no `.seeded` in `master`): merge every cache found in `installs`
    /// into the launcher's copy. Only the installs given -- the one in use and the window's list --
    /// and only where a cache can be (`found(in:)`); nothing else is scanned. nil when it has
    /// already run, found nothing (the drive may not be there yet), or the copy is busy: each of
    /// those tries again next start.
    static func seedIfNeeded(_ installs: [Install], master: URL = masterDir) -> String? {
        let marker = master.appendingPathComponent(".seeded")
        if FileManager.default.fileExists(atPath: marker.path) { return nil }
        var ids = Set<String>()
        let perInstall = installs.filter { ids.insert($0.id).inserted }.map(found(in:))
        let caches = perInstall.flatMap { $0 }
        if caches.isEmpty { return nil }
        return locked(master) { () -> String? in
            if FileManager.default.fileExists(atPath: marker.path) { return nil }
            let byName = Dictionary(grouping: caches, by: { $0.lastPathComponent.lowercased() })
            var lines: [String] = []
            for (_, group) in byName.sorted(by: { $0.key < $1.key }) {
                let name = group[0].lastPathComponent
                let m = merge(group, into: master.appendingPathComponent(name))
                lines.append(describe(m, name) + m.skipped.map { "; skipped \($0)" }.joined())
            }
            let note = (["seeded \(Date())"] + caches.map(\.path)).joined(separator: "\n") + "\n"
            FileManager.default.createFile(atPath: marker.path, contents: Data(note.utf8))
            return "dxvk cache: seeded the Mac copy from \(caches.count) cache(s) in "
                + "\(perInstall.filter { !$0.isEmpty }.count) of \(perInstall.count) known install(s)"
                + (lines.isEmpty ? "" : ": " + lines.joined(separator: ", "))
        } ?? nil
    }

    /// Where an install can hold a DXVK cache: C:\dxvk-cache (DXVK_STATE_CACHE_PATH), and --
    /// from before the launcher set that path, when DXVK wrote beside the program's working
    /// folder -- drive_c itself, each folder directly in it (HorizonXI, CatsEyeXI-Launcher, ...)
    /// and the boot loader's folder. A few dozen directory listings, never a walk.
    static func found(in i: Install) -> [URL] {
        let fm = FileManager.default
        var dirs = [cacheDir(i), i.driveC, i.gameDir, i.bootLoaderDir]
        if let kids = try? fm.contentsOfDirectory(at: i.driveC, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles]) {
            dirs += kids.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.prefix(64)
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }.flatMap(files(in:))
    }

    /// The `*.dxvk-cache` files directly in `dir`.
    static func files(in dir: URL) -> [URL] {
        let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return kids.filter { $0.pathExtension == fileExtension }.sorted { $0.path < $1.path }
    }
}
