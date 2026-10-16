// Copyright (c) 2026 Bates LLC. All rights reserved.

import CryptoKit
import Foundation

/// `--selftest-dxvk-cache`: DXVKStateCache on synthetic entries (good, corrupt, undecodable,
/// oversized, cut short, repeated, wrong version) and on copies of Daniel's real caches, in a
/// folder of its own under $TMPDIR. The real caches are read from the fixture folder
/// (`FFXI_DXVK_CACHE_FIXTURES`, else ~/Downloads/FFXI-on-Mac-build/fixture/dxvk-cache: old/,
/// new/, old-catseye/, copied there read-only from the installs) and only ever copied; the
/// launcher's own copy (`DXVKStateCache.masterDir`) and launcher.log are never touched.
extension Headless {
    static func runDXVKCacheSelfTest() -> Never {
        typealias C = DXVKStateCache
        var checks: [(String, Bool)] = []
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ffxi-dxvk-cache-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let realMasterBefore = listing(C.masterDir)

        func file(_ name: String, _ data: Data) -> URL {
            let u = work.appendingPathComponent(name)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: data)
            return u
        }
        func contents(_ u: URL) -> C.Contents? { if case .ok(let c) = C.read(u) { return c }; return nil }
        func bytes(_ u: URL) -> Data? { try? Data(contentsOf: u) }
        func noTemps(_ dir: URL) -> Bool {
            let all = fm.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []
            return !all.contains { $0.hasSuffix(".tmp") }
        }

        // The format.
        let e = (0..<6).map { syntheticEntry(UInt32($0)) }
        checks.append(("a new file's header is DXVK's: \"DXVK\", version 10, entry size 0",
                       [UInt8](C.encode([])) == [0x44, 0x58, 0x56, 0x4B, 10, 0, 0, 0, 0, 0, 0, 0]))
        let three = C.encode(Array(e[0..<3]))
        checks.append(("synthetic entries read back whole, in order",
                       C.parse(three) == .ok(C.Contents(entries: Array(e[0..<3])))))
        let compute = record(stageMask: 0x20, data: [UInt8](repeating: 7, count: 24) + [UInt8](repeating: 0, count: 48) + [0, 0, 0, 0])
        checks.append(("a compute entry (key, binding mask, no constants) decodes",
                       contents(file("compute.dxvk-cache", C.encode([compute])))?.entries == [compute]))
        checks.append(("file named as DXVK names it: .exe dropped in any case, folders dropped",
                       C.fileName(exe: "horizon-loader.exe") == "horizon-loader.dxvk-cache"
                           && C.fileName(exe: ".\\bootloader\\horizon-loader.exe") == "horizon-loader.dxvk-cache"
                           && C.fileName(exe: "XILOADER.EXE") == "XILOADER.dxvk-cache"
                           && C.fileName(exe: "pol") == "pol.dxvk-cache"))

        // What DXVK skips, as it skips it.
        var flipped = e[1]; flipped[flipped.count - 1] ^= 0xFF
        checks.append(("SHA-1 mismatch: that entry skipped, the others kept",
                       C.parse(C.encode([e[0], flipped, e[2]])) == .ok(C.Contents(entries: [e[0], e[2]], invalid: 1))))
        let badLayout = syntheticEntry(90, colorLayout: 5)
        let tooMany = syntheticEntry(91, attributes: 33)
        let badDepth = syntheticEntry(92, depthLayout: 2)
        let short = record(stageMask: 0x11, data: Array(syntheticData(93).dropLast(2)))
        checks.append(("hash right but DXVK cannot use it (render target layout, depth layout, 33 attributes, cut-off data): skipped",
                       C.parse(C.encode([badLayout, tooMany, badDepth, short, e[0]])) == .ok(C.Contents(entries: [e[0]], invalid: 4))))
        var oversized = Data()
        withUnsafeBytes(of: (UInt32(0x11) | UInt32(2000) << 8).littleEndian) { oversized.append(contentsOf: $0) }
        oversized.append(Data(repeating: 0, count: 20))
        checks.append(("size over 1024: skipped, and the next entry read right after its hash (as DXVK's stream does)",
                       C.parse(C.encode([oversized, e[0]])) == .ok(C.Contents(entries: [e[0]], invalid: 1))))
        let cut = C.encode(Array(e[0..<3])).dropLast(10)
        checks.append(("a half-written last entry is the tail, not an invalid entry",
                       C.parse(Data(cut)) == .ok(C.Contents(entries: [e[0], e[1]], tailBytes: e[2].count - 10))))
        checks.append(("a repeat is loaded once",
                       C.parse(C.encode([e[0], e[1], e[0]])) == .ok(C.Contents(entries: [e[0], e[1]], duplicates: 1))))
        var v9 = C.encode([e[0]]); v9[4] = 9
        var v11 = C.encode([e[0]]); v11[4] = 11
        var sized = C.encode([e[0]]); sized[8] = 4
        let unusable: (C.Read) -> Bool = { if case .unusable = $0 { return true }; return false }
        checks.append(("version 9, version 11, a header entry size, not a cache at all: unusable",
                       unusable(C.parse(v9)) && unusable(C.parse(v11)) && unusable(C.parse(sized))
                           && unusable(C.parse(Data("hello, world".utf8))) && unusable(C.parse(Data("DXV".utf8)))))
        checks.append(("no file and an empty file are both no cache",
                       C.read(work.appendingPathComponent("missing.dxvk-cache")) == .absent
                           && C.read(file("empty.dxvk-cache", Data())) == .absent))

        // Merging.
        let a = file("m/a.dxvk-cache", C.encode([e[0], e[1]]))
        let b = file("m/b.dxvk-cache", C.encode([e[1], e[2], e[3]]))
        let created = work.appendingPathComponent("m/new.dxvk-cache")
        let m1 = C.merge([a, b], into: created)
        checks.append(("into no file: created with every entry of both, once",
                       m1.wrote && m1.before == 0 && m1.after == 4 && contents(created) == C.Contents(entries: Array(e[0..<4]))))
        let stampBefore = try? fm.attributesOfItem(atPath: created.path)[.modificationDate] as? Date
        let m2 = C.merge([a, b], into: created)
        checks.append(("nothing new: not written (same bytes, same date)",
                       !m2.wrote && m2.added == 0 && m2.refused == nil && bytes(created) == C.encode(Array(e[0..<4]))
                           && (try? fm.attributesOfItem(atPath: created.path)[.modificationDate] as? Date) == stampBefore))
        let dry = C.merge([file("m/c.dxvk-cache", C.encode([e[4]]))], into: created, write: false)
        checks.append(("a dry run says what it would add and writes nothing",
                       dry.wrote && dry.added == 1 && bytes(created) == C.encode(Array(e[0..<4]))))
        let messy = file("m/messy.dxvk-cache", C.encode([e[0], flipped, e[2], e[0]]) + Data(e[3].prefix(30)))
        let m3 = C.merge([b], into: messy)
        checks.append(("a target with a bad entry, a repeat and a cut-off tail: rewritten with every good entry plus the new",
                       m3.wrote && m3.before == 2 && m3.after == 4 && contents(messy) == C.Contents(entries: [e[0], e[2], e[1], e[3]])))
        let corruptSource = file("m/corrupt.dxvk-cache", C.encode([flipped, badLayout, e[5]]))
        let clean = file("m/clean.dxvk-cache", C.encode([e[0]]))
        let m4 = C.merge([corruptSource], into: clean)
        checks.append(("from a source with bad entries: only its good ones go in; nothing invalid is written",
                       m4.added == 1 && contents(clean) == C.Contents(entries: [e[0], e[5]])))
        for (label, header) in [("version 9", v9), ("version 11", v11), ("not a cache", Data("hello, world".utf8))] {
            let t = file("m/refuse-\(label).dxvk-cache", header)
            let r = C.merge([a, b], into: t)
            checks.append(("target \(label): refused, left byte for byte as it was",
                           r.refused != nil && !r.wrote && bytes(t) == header))
        }
        let v9source = file("m/v9.dxvk-cache", v9)
        let keepTarget = file("m/keep.dxvk-cache", C.encode([e[2]]))
        let m5 = C.merge([v9source, work.appendingPathComponent("m/none.dxvk-cache")], into: keepTarget)
        checks.append(("a version-9 source is skipped and named; a missing one is not; the target stays",
                       m5.skipped.count == 1 && m5.skipped[0].contains("v9.dxvk-cache") && !m5.wrote
                           && bytes(keepTarget) == C.encode([e[2]])))
        let none = work.appendingPathComponent("m/empty-result.dxvk-cache")
        checks.append(("nothing to put in a file that is not there: no empty file made",
                       !C.merge([v9source], into: none).wrote && !fm.fileExists(atPath: none.path)))
        let gated = file("m/gated.dxvk-cache", C.encode([e[0]]))
        let gate = C.CommitGate()
        gate.close()
        let m6 = C.merge([b], into: gated, gate: gate)
        checks.append(("a closed gate (Play stopped waiting): not renamed, target as it was, no temp file left",
                       !m6.wrote && m6.refused != nil && !gate.renamed && bytes(gated) == C.encode([e[0]])
                           && noTemps(work.appendingPathComponent("m"))))
        let unmade = work.appendingPathComponent("m/no-folder-yet/x.dxvk-cache")
        let m7 = C.merge([b], into: unmade, gate: gate)
        checks.append(("... nor a folder or file made for a target that is not there yet",
                       !m7.wrote && m7.refused != nil && !fm.fileExists(atPath: unmade.deletingLastPathComponent().path)))

        // Daniel's real caches, copied.
        let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FFXI_DXVK_CACHE_FIXTURES"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/FFXI-on-Mac-build/fixture/dxvk-cache").path)
        let realNames = ["old/horizon-loader.dxvk-cache", "new/horizon-loader.dxvk-cache", "old-catseye/CatsEyeXI-Launcher.dxvk-cache"]
        let realSums = realNames.map { bytes(fixtures.appendingPathComponent($0)).map { Data(Insecure.SHA1.hash(data: $0)) } }
        var realRun = false
        if realSums.allSatisfy({ $0 != nil }) {
            realRun = true
            let real = realNames.map { n -> URL in
                let u = work.appendingPathComponent("real/" + n)
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: fixtures.appendingPathComponent(n), to: u)
                return u
            }
            let parsed = real.map(contents)
            for (n, c) in zip(realNames, parsed) {
                print("  real \(n): \(c.map { "v\($0.version), \($0.entries.count) entries, \($0.invalid) invalid, \($0.duplicates) repeats, \($0.tailBytes) tail bytes" } ?? "unusable")")
            }
            checks.append(("the three real caches: version 10, every entry valid and decoded",
                           parsed.allSatisfy { $0.map { $0.clean && !$0.entries.isEmpty } == true }))
            if let old = parsed[0], let new = parsed[1] {
                let union = Set(old.entries).union(new.entries)
                print("  real old ∩ new: \(Set(old.entries).intersection(new.entries).count), union \(union.count)")
                let t0 = Date()
                let m = C.merge([real[0]], into: real[1])
                let took = Date().timeIntervalSince(t0)
                print("  real merge old -> new: \(m.before) -> \(m.after) in \(Int(took * 1000)) ms")
                let after = contents(real[1])
                checks.append(("old into new: every entry of both, once, new's first, and it reads back clean",
                               after.map { $0.clean && Set($0.entries) == union && $0.entries.count == union.count
                                   && Array($0.entries.prefix(new.entries.count)) == new.entries } == true))
                checks.append(("... in well under a second", took < 1))
                checks.append(("... and a second merge changes nothing", !C.merge([real[0]], into: real[1]).wrote))
            }
        } else {
            print("  real caches: skipped, none at \(fixtures.path)")
        }

        // The launcher's flow, on installs made up in the work folder.
        func install(_ path: String, caches: [String: Data]) -> Install {
            let i = Install(wrapper: work.appendingPathComponent(path), prefixName: "prefix10")
            for (rel, d) in caches {
                let u = i.driveC.appendingPathComponent(rel)
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: u.path, contents: d)
            }
            return i
        }
        let newInstall = install("x10/FFXI on Mac/FFXI on Mac Wine.app",
                                 caches: ["dxvk-cache/horizon-loader.dxvk-cache": C.encode([e[0], e[1]]),
                                          "dxvk-cache/dxvk.conf": Data("dxvk.enableStateCache = True\n".utf8)])
        let oldInstall = install("x10/siku.app",
                                 caches: ["dxvk-cache/horizon-loader.dxvk-cache": C.encode([e[1], e[2], e[3]]),
                                          "CatsEyeXI-Launcher/CatsEyeXI-Launcher.dxvk-cache": C.encode([e[4]]),
                                          "HorizonXI/bootloader/horizon-loader.dxvk-cache": C.encode([e[5]]),
                                          "dxvk-cache/horizon-loader.dxvk-cache.bak-2026-10-15-b63": C.encode([e[0]])])
        let master = work.appendingPathComponent("master")
        checks.append(("where an install's caches are looked for: C:\\dxvk-cache, folders in drive_c, the loader's folder; no backups",
                       // Relative to drive_c: a listing of $TMPDIR comes back as /private/var/...
                       C.found(in: oldInstall).map { $0.path.components(separatedBy: "/drive_c/").last ?? "" }.sorted()
                           == ["CatsEyeXI-Launcher/CatsEyeXI-Launcher.dxvk-cache", "HorizonXI/bootloader/horizon-loader.dxvk-cache",
                               "dxvk-cache/horizon-loader.dxvk-cache"]))
        let freshMaster = work.appendingPathComponent("master-empty")
        checks.append(("seeding with nothing found: nothing written, tried again next time",
                       C.seedIfNeeded([], master: freshMaster) == nil
                           && !fm.fileExists(atPath: freshMaster.appendingPathComponent(".seeded").path)))
        let seeded = C.seedIfNeeded([newInstall, oldInstall, newInstall], master: master)
        let loaderEntries = [e[0], e[1], e[2], e[3], e[5]]
        let masterHL = master.appendingPathComponent("horizon-loader.dxvk-cache")
        checks.append(("first seed: the Mac copy holds every entry of every install's caches, per executable",
                       seeded != nil && contents(masterHL).map { Set($0.entries) == Set(loaderEntries) && $0.entries.count == 5 } == true
                           && contents(master.appendingPathComponent("CatsEyeXI-Launcher.dxvk-cache"))?.entries == [e[4]]))
        checks.append(("... and only once", C.seedIfNeeded([newInstall, oldInstall], master: master) == nil))
        let prefixHL = C.cacheDir(newInstall).appendingPathComponent("horizon-loader.dxvk-cache")
        let warmed = C.warm(newInstall, exe: "horizon-loader.exe", master: master)
        checks.append(("before Play: the prefix gets everything, its own entries first",
                       warmed.contains("+3") && contents(prefixHL).map { Array($0.entries.prefix(2)) == [e[0], e[1]]
                           && Set($0.entries) == Set(loaderEntries) && $0.entries.count == 5 } == true))
        checks.append(("... and a second Play has nothing to add",
                       C.warm(newInstall, exe: "horizon-loader.exe", master: master).contains("already has all 5")))
        let fresh = syntheticEntry(77)
        if let h = try? FileHandle(forWritingTo: prefixHL) { h.seekToEndOfFile(); h.write(fresh); try? h.close() }
        let kept = C.keep(newInstall, master: master)
        checks.append(("after a session: what DXVK appended reaches the Mac copy",
                       kept.contains("+1") && contents(masterHL)?.entries.last == fresh))
        checks.append(("no Mac copy for an executable: the prefix is left alone",
                       C.warm(newInstall, exe: "pol.exe", master: master).contains("no Mac copy")
                           && !fm.fileExists(atPath: C.cacheDir(newInstall).appendingPathComponent("pol.dxvk-cache").path)))
        checks.append(("dxvk.conf beside the cache is not a cache",
                       C.files(in: C.cacheDir(newInstall)).map(\.lastPathComponent) == ["horizon-loader.dxvk-cache"]))
        checks.append(("no temp file left anywhere", noTemps(work)))

        // Nothing outside the work folder.
        checks.append(("the real caches were only read", realNames.enumerated().allSatisfy { k, n in
            bytes(fixtures.appendingPathComponent(n)).map { Data(Insecure.SHA1.hash(data: $0)) } == realSums[k] }))
        checks.append(("the launcher's own copy in Application Support is untouched", listing(C.masterDir) == realMasterBefore))

        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        if !realRun { print("  (real-cache checks not run)") }
        // exit() runs no defer: clean up here.
        try? fm.removeItem(at: work)
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Name, size and date of each file in `dir`: enough to see that nothing in it changed.
    private static func listing(_ dir: URL) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().map { n in
            let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path)
            return "\(n) \((a?[.size] as? NSNumber)?.intValue ?? -1) \((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
    }

    /// The data of a graphics entry DXVK would load: vertex and fragment shader keys, a depth
    /// target and one colour target, `attributes` vertex attributes and one binding, and one
    /// specialization constant (`n`, so every entry differs).
    private static func syntheticData(_ n: UInt32, attributes: Int = 2, depthLayout: UInt8 = 3,
                                      colorLayout: UInt8 = 2) -> [UInt8] {
        var d: [UInt8] = []
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d += $0 } }
        for stage: UInt32 in [0x01, 0x10] {
            u32(stage)
            d += Array(Insecure.SHA1.hash(data: Array("shader \(n) \(stage)".utf8)))
        }
        d += [1, 126, depthLayout]              // 1 sample, D32_SFLOAT
        d += [37, colorLayout]                  // R8G8B8A8_UNORM
        d += [UInt8](repeating: 0, count: 14)   // render targets 1-7 unused
        d += [UInt8](repeating: 0, count: 48)   // binding mask
        d += [3, 0]                             // ia: triangle list
        d += [UInt8(attributes), 1]             // il
        d += [UInt8](repeating: 0, count: 20)   // rs, ms, ds, om, dsFront, dsBack
        d += [UInt8](repeating: 0, count: 8)    // swizzles
        d += [UInt8](repeating: 0, count: 32)   // blend
        for k in 0..<attributes { u32(UInt32(k)) }
        u32(0)                                  // the binding
        u32(1)                                  // spec constant mask: constant 0
        u32(n)
        return d
    }

    private static func syntheticEntry(_ n: UInt32, attributes: Int = 2, depthLayout: UInt8 = 3,
                                       colorLayout: UInt8 = 2) -> Data {
        record(stageMask: 0x11, data: syntheticData(n, attributes: attributes, depthLayout: depthLayout,
                                                    colorLayout: colorLayout))
    }

    /// Entry header, SHA-1 of the data, data -- as DXVK's `writeCacheEntry` lays it out.
    private static func record(stageMask: UInt8, data: [UInt8]) -> Data {
        var r = Data()
        withUnsafeBytes(of: (UInt32(stageMask) | UInt32(data.count) << 8).littleEndian) { r.append(contentsOf: $0) }
        r.append(contentsOf: Array(Insecure.SHA1.hash(data: data)))
        r.append(contentsOf: data)
        return r
    }
}

/// `--dxvk-cache-report`: what the DXVK cache carry-over would do on this Mac, without doing it.
/// Read-only: lists and parses the cache files of the install in use and the installs a scan
/// finds (or only `--prefix <path>`), and the launcher's copy. Safe while a game is playing.
extension Headless {
    @MainActor static func runDXVKCacheReport() -> Never {
        typealias C = DXVKStateCache
        let installs = dxvkKnownInstalls()
        func describe(_ u: URL) -> String {
            switch C.read(u) {
            case .absent: return "\(u.path): none"
            case .unusable(let why): return "\(u.path): not usable (\(why))"
            case .ok(let c):
                return "\(u.path): v\(c.version), \(c.entries.count) entries, \(c.invalid) invalid, "
                    + "\(c.duplicates) repeats, \(c.tailBytes) tail bytes"
            }
        }
        func would(_ m: C.Merge) -> String {
            if let r = m.refused { return "nothing (\(r))" }
            return (m.wrote ? "write \(m.before) -> \(m.after) (+\(m.added))" : "nothing (already has all \(m.after))")
                + m.skipped.map { "; skip \($0)" }.joined()
        }
        let master = C.masterDir
        let seeded = FileManager.default.fileExists(atPath: master.appendingPathComponent(".seeded").path)
        print("Mac copy: \(master.path) (seeded: \(seeded ? "yes" : "no"))")
        for f in C.files(in: master) { print("  " + describe(f)) }
        let running = !LiveClients.snapshot().clients.isEmpty
        print("a client is running now: \(running ? "yes -- Play would not warm a prefix until none is" : "no")")
        for i in installs {
            print("install \(i.id)\(i.id == Install.remembered()?.id ? " (in use)" : "")")
            let found = C.found(in: i)
            if found.isEmpty { print("  no caches") }
            for f in found { print("  " + describe(f)) }
            let exe = Credentials.bootLoaderName(in: i, profile: "horizonxi.ini") ?? "horizon-loader.exe"
            let name = C.fileName(exe: exe)
            let src = master.appendingPathComponent(name)
            let dst = C.cacheDir(i).appendingPathComponent(name)
            print("  Play (\(exe)) would: " + (FileManager.default.fileExists(atPath: src.path)
                                                ? would(C.merge([src], into: dst, write: false)) : "nothing (no Mac copy of \(name))"))
            for f in C.files(in: C.cacheDir(i)) {
                print("  after a session, Mac copy of \(f.lastPathComponent) would: "
                      + would(C.merge([f], into: master.appendingPathComponent(f.lastPathComponent), write: false)))
            }
        }
        if !seeded {
            let all = installs.flatMap(C.found(in:))
            let byName = Dictionary(grouping: all, by: { $0.lastPathComponent.lowercased() })
            for (_, group) in byName.sorted(by: { $0.key < $1.key }) {
                print("first-run seed, \(group[0].lastPathComponent) from \(group.count) file(s) would: "
                      + would(C.merge(group, into: master.appendingPathComponent(group[0].lastPathComponent), write: false)))
            }
        }
        exit(0)
    }

    /// `--dxvk-cache-warm`: what the window does with the DXVK cache, now, without a window: seed
    /// the launcher's copy (first run only) from the installs it knows, then merge it into the
    /// install in use (or `--prefix <path>`), as Play does before the client starts. Refuses, and
    /// writes nothing, while any FFXI client is running -- or while a launch is under way, which
    /// no scan can see yet: it holds the launch lock throughout, as Play does.
    @MainActor static func runDXVKCacheWarm() -> Never {
        typealias C = DXVKStateCache
        // Never released by hand: exit() closes the fd, and with it the flock.
        guard LaunchLock.acquire() != nil else {
            print("a launch, Repair or Stop is under way: nothing written")
            exit(1)
        }
        guard LiveClients.snapshot().clients.isEmpty else {
            print("a client is running: nothing written (Play warms the cache only with no client running)")
            exit(1)
        }
        guard let target = installFromPrefixArgument() ?? Install.remembered() else { print("no install"); exit(2) }
        let installs = dxvkKnownInstalls()
        print(C.seedIfNeeded(installs) ?? "dxvk cache: Mac copy already seeded")
        let exe = Credentials.bootLoaderName(in: target, profile: "horizonxi.ini") ?? "horizon-loader.exe"
        print(C.warm(target, exe: exe))
        exit(0)
    }

    /// The install in use and what a scan finds (as the window has them), or only `--prefix`.
    private static func dxvkKnownInstalls() -> [Install] {
        if let only = installFromPrefixArgument() { return [only] }
        let current = Install.remembered()
        return Install.dedupe((current.map { [$0] } ?? []) + Install.discover(), keep: current?.id)
    }
}
