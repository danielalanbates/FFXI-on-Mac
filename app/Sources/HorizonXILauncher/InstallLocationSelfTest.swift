// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// `--selftest-install-location [<fixture dir>]`: where Setup puts things, and Move…, without a
/// window.
///
/// - The chooser's refusals from injected volume facts: exFAT / FAT / NTFS, network, read-only,
///   not writable, not enough space (with the Mac's own disk keeping 8 GB), cloud-synced, inside
///   an app, a drive that is gone; and the facts read from a real folder.
/// - The one-folder layout: Wine, its Windows drive and HorizonXI's files (SquareEnix included)
///   all inside "<chosen>/FFXI on Mac/"; no default location for Bootstrap.
/// - The choice remembered (in a throwaway defaults suite, never the real one) and discovery
///   looking there first; `Install.remembered` finding a fresh install with no game yet.
/// - A real Move of a tiny fixture tree built under `<fixture dir>/install-location` (default: a
///   temporary folder): its SquareEnix is a link to a folder outside the tree, which links on to
///   a third; the copy must hold real files there, keep Wine's own links, re-point an absolute
///   link at the copy, leave the other prefixes behind, count the same as the source, and leave
///   the source exactly as it was. Then a copy whose source changed under it is refused and
///   discarded, a second Move into the same place is refused, and a source behind a missing
///   drive is refused in one line with nothing written.
/// - Move refusing while anything runs.
///
/// Writes only inside the fixture folder (a failed copy is "discarded" there, not to the Trash).
extension Headless {
    @MainActor static func runInstallLocationSelfTest() -> Never {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { results.append((name, ok)) }
        let fm = FileManager.default

        // MARK: Refusals, from injected facts
        let need = InstallLocation.Need.fresh
        var good = InstallLocation.Facts(); good.freeBytes = 200_000_000_000
        func line(_ f: InstallLocation.Facts) -> String { InstallLocation.verdict(f, need: need).line }
        func refused(_ f: InstallLocation.Facts) -> Bool { !InstallLocation.verdict(f, need: need).isOK }
        check("a local APFS folder with room is accepted: \(line(good))",
              InstallLocation.verdict(good, need: need) == .ok(free: 200_000_000_000, need: need)
                && line(good) == "200.0 GB free here · about 28 GB needed")
        var f = good; f.fsType = "hfs"
        check("Mac OS Extended is accepted", !refused(f))
        var lines: [String] = []
        for (fs, name) in [("exfat", "exFAT"), ("msdos", "FAT (MS-DOS)"), ("ntfs", "NTFS")] {
            f = good; f.fsType = fs
            lines.append(line(f))
            check("\(name) is refused: \(line(f))", refused(f) && line(f).contains(name) && line(f).contains("APFS"))
        }
        f = good; f.isLocal = false
        lines.append(line(f))
        check("a network volume is refused: \(line(f))", refused(f) && line(f).contains("network"))
        f = good; f.fsType = "smbfs"
        check("an SMB share is refused even when it says local", refused(f) && line(f).contains("network"))
        f = good; f.isReadOnly = true
        lines.append(line(f))
        check("a read-only volume is refused: \(line(f))", refused(f) && line(f).contains("read-only"))
        f = good; f.isWritable = false
        lines.append(line(f))
        check("a folder that can't be written is refused: \(line(f))", refused(f) && line(f).contains("written"))
        f = good; f.freeBytes = need - 1
        lines.append(line(f))
        check("not enough space is refused with both numbers: \(line(f))",
              refused(f) && line(f).contains("free") && line(f).contains("about 28 GB needed"))
        f = good; f.isBootVolume = true; f.freeBytes = need + 1_000_000_000
        lines.append(line(f))
        check("the Mac's own disk keeps 8 GB free: \(line(f))", refused(f) && line(f).contains("about 36 GB needed"))
        f.freeBytes = need + InstallLocation.bootFloor + 1
        check("... and is accepted with room for it", !refused(f))
        f = good; f.isCloud = true
        lines.append(line(f))
        check("a cloud-synced folder is refused: \(line(f))", refused(f) && line(f).contains("cloud"))
        f = good; f.insideApp = true
        lines.append(line(f))
        check("a folder inside an app is refused", refused(f) && line(f).contains("app"))
        f = good; f.missingDrive = "Games"
        lines.append(line(f))
        check("a drive that is gone is refused, naming it: \(line(f))", refused(f) && line(f).contains("'Games'"))
        check("every refusal is one short plain line, never 'restart'",
              lines.allSatisfy { !$0.contains("\n") && $0.count <= 80 && !$0.lowercased().contains("restart") })
        check("a fresh install needs about 28 GB (Wine 1.4 + the game's Wine 1.3 + zip 9.4 + game 15.5)",
              InstallLocation.gbUp(need) == "28 GB" && need > 27_000_000_000 && need < 28_000_000_000)
        check("the game's Wine alone needs about 2 GB (tarball + unpacked)", InstallLocation.gbUp(InstallLocation.Need.gameWine) == "2 GB")

        // MARK: Facts from real folders (read-only)
        let base: URL
        let keepFixture: Bool
        if let k = CommandLine.arguments.firstIndex(of: "--selftest-install-location"), k + 1 < CommandLine.arguments.count,
           !CommandLine.arguments[k + 1].hasPrefix("--") {
            base = URL(fileURLWithPath: CommandLine.arguments[k + 1], isDirectory: true)
            keepFixture = true
        } else {
            base = fm.temporaryDirectory.appendingPathComponent("ffxi-location-\(UUID().uuidString)", isDirectory: true)
            keepFixture = false
        }
        var F = base.appendingPathComponent("install-location", isDirectory: true).standardizedFileURL
        let marker = F.appendingPathComponent(".ffxi-selftest-fixture")
        // Only a folder this test made is ever cleared.
        if fm.fileExists(atPath: F.path) {
            guard fm.fileExists(atPath: marker.path) else {
                print("FAIL  \(F.path) exists and is not this test's fixture; not touching it"); exit(1)
            }
            try? fm.removeItem(at: F)
        }
        try? fm.createDirectory(at: F, withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: Data())
        // One spelling for every path the test compares (/private/var is /var; see canonical).
        if let r = InstallMove.canonical(F.path) { F = URL(fileURLWithPath: r, isDirectory: true) }
        let real = InstallLocation.facts(for: F)
        check("facts read from the fixture's folder: \(real.fsType), local \(real.isLocal), writable \(real.isWritable), "
              + "\(InstallLocation.gb(real.freeBytes)) free",
              real.fsType == "apfs" && real.isLocal && !real.isReadOnly && real.isWritable && real.freeBytes > 0 && real.missingDrive == nil)
        let gone = "NoSuchDrive-\(UUID().uuidString.prefix(8))"
        check("facts for a drive that is gone name it",
              InstallLocation.facts(for: URL(fileURLWithPath: "/Volumes/\(gone)/Games")).missingDrive == gone)

        // MARK: One folder
        let chosen = URL(fileURLWithPath: "/Volumes/Big/Stuff", isDirectory: true)
        let folder = InstallLocation.folder(for: chosen)
        check("the folder is <chosen>/FFXI on Mac", folder.path == "/Volumes/Big/Stuff/FFXI on Mac")
        check("choosing that folder itself does not nest another", InstallLocation.folder(for: folder) == folder)
        let fresh = InstallLocation.install(in: folder)
        let inside = [fresh.wrapper, fresh.wine, fresh.prefix, fresh.driveC, fresh.gameDir, fresh.squareEnix,
                      InstallLocation.worldData("CatsEyeXI", in: folder), Bootstrap.workDir(for: fresh.wrapper)]
        check("Wine, the Windows drive, HorizonXI and SquareEnix all inside it",
              inside.allSatisfy { $0.path.hasPrefix(folder.path + "/") }
                && fresh.gameDir.path == folder.path + "/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI"
                && fresh.squareEnix.path.hasSuffix("drive_c/HorizonXI/SquareEnix"))
        let savedTarget = Bootstrap.target
        Bootstrap.target = nil
        check("Bootstrap has no default location: nothing chosen, nothing built", Bootstrap.install == nil && !Bootstrap.repairsInPlace)
        Bootstrap.target = fresh.wrapper
        check("Bootstrap builds where Setup chose", Bootstrap.install?.gameDir == fresh.gameDir && !Bootstrap.repairsInPlace)
        Bootstrap.target = savedTarget

        // MARK: The fixture: an old install split across "drives"
        func mk(_ rel: String, _ bytes: Int = 16, exec: Bool = false) {
            let u = F.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data(repeating: 0x41, count: bytes),
                          attributes: exec ? [.posixPermissions: 0o755] : nil)
        }
        func ln(_ rel: String, _ to: String) {
            let u = F.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(atPath: u.path, withDestinationPath: to)
        }
        let W = "Old Place/siku.app", P = "\(W)/Contents/SharedSupport/prefix10"
        mk("\(W)/Contents/Info.plist")
        mk("\(W)/Contents/Frameworks/libfoo.dylib", 1000)
        mk("\(W)/Contents/SharedSupport/wine/bin/wine", exec: true)
        ln("\(W)/Contents/SharedSupport/wine/lib/libfoo.dylib", "../../../Frameworks/libfoo.dylib")
        mk("\(P)/system.reg", 300)
        ln("\(P)/dosdevices/c:", "../drive_c")
        ln("\(P)/dosdevices/z:", "/")
        mk("Home/Documents/private.txt")
        ln("\(P)/drive_c/users/me/Documents", F.appendingPathComponent("Home/Documents").path)
        mk("Elsewhere/CatsEyeXI/big.bin", 5000)
        ln("\(P)/drive_c/Games/CatsEyeXI", F.appendingPathComponent("Elsewhere/CatsEyeXI").path)
        mk("\(P)/drive_c/HorizonXI/Ashita-cli.exe", 200)
        mk("\(P)/drive_c/HorizonXI/config/boot/horizonxi.ini", 50)
        ln("\(P)/drive_c/HorizonXI/SquareEnix", F.appendingPathComponent("Other Drive/FFXI/SquareEnix").path)
        ln("\(P)/drive_c/HorizonXI/abs-inside", F.appendingPathComponent("\(W)/Contents/Frameworks/libfoo.dylib").path)
        ln("\(P)/drive_c/HorizonXI/dangling", F.appendingPathComponent("Nowhere/x").path)
        for d in ["FFXi.dll", "FFXiMain.dll", "FFXiVersions.dll"] { mk("Other Drive/FFXI/SquareEnix/FINAL FANTASY XI/\(d)", 700) }
        mk("Other Drive/FFXI/SquareEnix/FINAL FANTASY XI/ROM/0/0.DAT", 2048)
        ln("Other Drive/FFXI/SquareEnix/PlayOnlineViewer", F.appendingPathComponent("Third Drive/POL").path)
        ln("Other Drive/FFXI/SquareEnix/loop", F.appendingPathComponent("Other Drive/FFXI").path)
        mk("Third Drive/POL/viewer/com/polcore.dll", 400)
        mk("\(W)/Contents/SharedSupport/prefix-installers/system.reg")
        mk("\(W)/Contents/SharedSupport/prefix-old/drive_c/big.bin", 9000)
        let dest = F.appendingPathComponent("Dest", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let discarded = F.appendingPathComponent("discarded", isDirectory: true)
        try? fm.createDirectory(at: discarded, withIntermediateDirectories: true)
        InstallMove.discard = { u in
            try fm.moveItem(at: u, to: discarded.appendingPathComponent(u.lastPathComponent + "-\(UUID().uuidString.prefix(6))"))
        }

        /// Every entry under the fixture's source trees: path, kind, size, link target.
        func snapshot() -> [String] {
            var out: [String] = []
            for top in ["Old Place", "Other Drive", "Third Drive", "Home", "Elsewhere"] {
                var stack = [F.appendingPathComponent(top).path]
                while let cur = stack.popLast() {
                    var st = stat()
                    guard lstat(cur, &st) == 0 else { continue }
                    let rel = String(cur.dropFirst(F.path.count))
                    switch st.st_mode & S_IFMT {
                    case S_IFDIR:
                        out.append("d \(rel)")
                        for k in (try? fm.contentsOfDirectory(atPath: cur)) ?? [] { stack.append(cur + "/" + k) }
                    case S_IFLNK: out.append("l \(rel) -> \((try? fm.destinationOfSymbolicLink(atPath: cur)) ?? "?")")
                    default: out.append("f \(rel) \(st.st_size) \(st.st_mtimespec.tv_sec)")
                    }
                }
            }
            return out.sorted()
        }
        let before = snapshot()
        let old = Install(wrapper: F.appendingPathComponent(W), prefixName: "prefix10")
        check("a link to another folder on the same drive is not 'another drive'", !InstallMove.dataElsewhere(old))

        // MARK: Remembered, discovery
        let suite = "org.batesai.horizonxi-on-mac.selftest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let savedDefaults = InstallLocation.defaults
        InstallLocation.defaults = defaults
        check("nothing remembered in a fresh suite", InstallLocation.remembered == nil)
        let destFolder = InstallLocation.folder(for: dest)
        InstallLocation.remember(destFolder)
        check("the choice is remembered", InstallLocation.remembered?.path == destFolder.path)
        // The game's Wine: Setup puts it in the chosen folder, and that is where it is looked for
        // first; the places it was put by hand before b60 still follow.
        check("the game's Wine is looked for in the chosen folder first, then the old places",
              X87Sidecar.patchedWineCandidates == [destFolder.path + "/wine-coop/wine/bin/wine"] + X87Sidecar.fixedWineCandidates)
        let wineHere = InstallLocation.folder(for: F.appendingPathComponent("Wine Here"))
        mk("Wine Here/FFXI on Mac/wine-coop/wine/bin/wine", exec: true)
        InstallLocation.remember(wineHere)
        let savedWine = ProcessInfo.processInfo.environment["FFXI_ON_MAC_WINE"]
        unsetenv("FFXI_ON_MAC_WINE")
        check("a game Wine Setup installed in the chosen folder is the one Play runs",
              X87Sidecar.patchedWine()?.path == InstallLocation.gameWine(in: wineHere).path
                && OwnWine.current().owns(executable: wineHere.path + "/wine-coop/wine/lib/wine/x86_64-unix/wine"))
        if let w = savedWine { setenv("FFXI_ON_MAC_WINE", w, 1) }
        InstallLocation.remember(destFolder)
        check("discovery looks in the remembered folder first (once it exists)",
              Install.discoveryRoots(location: F.appendingPathComponent("Old Place")).first?.path == F.appendingPathComponent("Old Place").path
                && !Install.discoveryRoots(location: destFolder).contains { $0.path == destFolder.path })
        defaults.set(old.id, forKey: "install.last")
        check("a remembered install with its prefix but no game yet is still found",
              Install.remembered(defaults)?.id == old.id)
        check("installs(inWrapper:) lists its game prefix", Install.installs(inWrapper: old.wrapper).contains { $0.prefixName == "prefix10" })

        // MARK: Move
        do {
            let plan = try InstallMove.plan(old, world: "HorizonXI")
            check("plan: \(plan.expected)", plan.expected.files > 0 && plan.bytes > 0)
            check("plan: the other prefixes stay behind", plan.excluded.count == 2)
            let oldNames = plan.oldCopy.map { String($0.path.dropFirst(F.path.count)) }
            check("plan: the old copy is this prefix (the wrapper holds another) and the data it linked to: \(oldNames)",
                  oldNames == ["/\(P)", "/Other Drive/FFXI/SquareEnix"])
            check("Move refuses a folder inside the install it moves, or inside the data it links to",
                  InstallMove.destinationProblem(F.appendingPathComponent("\(W)/Contents"), plan: plan) != nil
                    && InstallMove.destinationProblem(F.appendingPathComponent("Other Drive/FFXI/SquareEnix/FINAL FANTASY XI"), plan: plan) != nil
                    && InstallMove.destinationProblem(dest, plan: plan) == nil)
            var shown: [Double] = []
            let moved = try InstallMove.copy(plan, into: destFolder, progress: { shown.append($0) })
            let nw = destFolder.appendingPathComponent(InstallLocation.wrapperName)
            check("the copy is <dest>/FFXI on Mac/FFXI on Mac Wine.app, prefix10",
                  moved.wrapper.path == nw.path && moved.prefixName == "prefix10")
            func kind(_ rel: String) -> mode_t {
                var st = stat(); return lstat(moved.prefix.appendingPathComponent(rel).path, &st) == 0 ? st.st_mode & S_IFMT : 0
            }
            func target(_ rel: String) -> String { (try? fm.destinationOfSymbolicLink(atPath: moved.prefix.appendingPathComponent(rel).path)) ?? "" }
            let se = "drive_c/HorizonXI/SquareEnix"
            check("SquareEnix is real files now, not a link", kind(se) == S_IFDIR
                  && ((try? fm.attributesOfItem(atPath: moved.prefix.appendingPathComponent("\(se)/FINAL FANTASY XI/ROM/0/0.DAT").path)[.size] as? Int) == 2048))
            check("... and the link inside it to a third place too", kind("\(se)/PlayOnlineViewer") == S_IFDIR
                  && fm.fileExists(atPath: moved.prefix.appendingPathComponent("\(se)/PlayOnlineViewer/viewer/com/polcore.dll").path))
            check("a link back to a folder that holds it stays a link (no endless copy)", kind("\(se)/loop") == S_IFLNK)
            check("Wine's drive letters stay as Wine made them", target("dosdevices/z:") == "/" && target("dosdevices/c:") == "../drive_c")
            check("Wine's user folders and other worlds' C:\\Games links stay links",
                  kind("drive_c/users/me/Documents") == S_IFLNK && kind("drive_c/Games/CatsEyeXI") == S_IFLNK)
            check("an absolute link inside the install now points at the copy",
                  target("drive_c/HorizonXI/abs-inside") == nw.appendingPathComponent("Contents/Frameworks/libfoo.dylib").path)
            check("a relative link inside the install still resolves in the copy",
                  fm.fileExists(atPath: nw.appendingPathComponent("Contents/SharedSupport/wine/lib/libfoo.dylib").path))
            check("a dangling link is copied as it was", kind("drive_c/HorizonXI/dangling") == S_IFLNK)
            check("the other prefixes were left behind",
                  !fm.fileExists(atPath: nw.appendingPathComponent("Contents/SharedSupport/prefix-old").path)
                    && !fm.fileExists(atPath: nw.appendingPathComponent("Contents/SharedSupport/prefix-installers").path))
            check("the copy counts the same as the source as copied: \(InstallMove.tally(nw.path))",
                  InstallMove.tally(nw.path) == plan.expected)
            let leftovers = ((try? fm.contentsOfDirectory(atPath: destFolder.path)) ?? []).filter { $0.hasPrefix(".") }
            check("no hidden partial copy is left", leftovers.isEmpty)
            check("progress ended at 100%", shown.last == 1)
            check("the source is exactly as it was", snapshot() == before)
            let bad = Preflight.run(moved).filter { $0.state == .bad }.map(\.id)
            check("the moved install passes the file checks (only the fake registry fails): \(bad)",
                  Set(bad).isSubset(of: ["reg32", "reglayout", "com"]))
            check("the moved install's game is in its own folder now", !InstallMove.dataElsewhere(moved)
                  && moved.squareEnix.path.hasPrefix(destFolder.path + "/"))
            check("discovery finds the copy in the remembered folder",
                  Install.installs(inWrapper: nw).contains { $0.prefixName == "prefix10" }
                    && Install.discoveryRoots(location: destFolder).first?.path == destFolder.path)
            check("a world folder inside the old wrapper is re-pointed at the copy",
                  InstallMove.rewrittenDataPath(old.driveC.appendingPathComponent("Games/Eden").path, world: "Eden", plan: plan, folder: destFolder)
                    == nw.appendingPathComponent("Contents/SharedSupport/prefix10/drive_c/Games/Eden").path
                    && InstallMove.rewrittenDataPath("/Volumes/x/Eden", world: "Eden", plan: plan, folder: destFolder) == nil
                    && InstallMove.rewrittenDataPath("", world: "Eden", plan: plan, folder: destFolder) == nil)
            do {
                _ = try InstallMove.copy(plan, into: destFolder)
                check("a second Move into the same place is refused", false)
            } catch {
                check("a second Move into the same place is refused: \((error as? InstallMove.Refusal)?.line ?? "?")",
                      (error as? InstallMove.Refusal)?.line.contains("already") == true && InstallMove.tally(nw.path) == plan.expected)
            }
            check("Move into the folder it is already in says so",
                  InstallMove.destinationProblem(dest, plan: try InstallMove.plan(moved, world: "HorizonXI")) == "The game is already in this folder.")

            // The source changes between the measure and the copy: refused, discarded, unchanged.
            let plan2 = try InstallMove.plan(old, world: "HorizonXI")
            mk("Other Drive/FFXI/SquareEnix/FINAL FANTASY XI/new.dat", 10)
            let dest2 = InstallLocation.folder(for: F.appendingPathComponent("Dest2"))
            do {
                _ = try InstallMove.copy(plan2, into: dest2)
                check("a copy that comes out different is refused", false)
            } catch {
                let line = (error as? InstallMove.Refusal)?.line ?? "?"
                check("a copy that comes out different is refused and discarded: \(line)",
                      line.contains("different") && !fm.fileExists(atPath: dest2.path)
                        && !((try? fm.contentsOfDirectory(atPath: discarded.path)) ?? []).isEmpty)
            }
            try? fm.removeItem(at: F.appendingPathComponent("Other Drive/FFXI/SquareEnix/FINAL FANTASY XI/new.dat"))
            check("... and the source is as it was", snapshot() == before)
        } catch {
            check("Move of the fixture: \(error.localizedDescription)", false)
        }

        // HorizonXI's whole folder a link to another place: copied as real files too.
        let H = "Linked Place/siku.app", HP = "\(H)/Contents/SharedSupport/prefix10"
        mk("\(H)/Contents/SharedSupport/wine/bin/wine", exec: true)
        mk("\(HP)/system.reg")
        mk("Linked Data/HorizonXI/Ashita-cli.exe", 30)
        mk("Linked Data/HorizonXI/SquareEnix/FINAL FANTASY XI/FFXiMain.dll", 40)
        ln("\(HP)/drive_c/HorizonXI", F.appendingPathComponent("Linked Data/HorizonXI").path)
        do {
            let linked = Install(wrapper: F.appendingPathComponent(H), prefixName: "prefix10")
            let lp = try InstallMove.plan(linked, world: "HorizonXI")
            let lm = try InstallMove.copy(lp, into: InstallLocation.folder(for: F.appendingPathComponent("DestL")))
            var st = stat()
            let isDir = lstat(lm.gameDir.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
            check("a HorizonXI folder that is itself a link is copied as real files",
                  isDir && fm.fileExists(atPath: lm.gameDir.appendingPathComponent("SquareEnix/FINAL FANTASY XI/FFXiMain.dll").path)
                    && InstallMove.tally(lm.wrapper.path) == lp.expected)
        } catch {
            check("a HorizonXI folder that is itself a link: \(error.localizedDescription)", false)
        }

        // A source behind a drive that is gone: one line, nothing written.
        let G = "Ghost Place/siku.app"
        mk("\(G)/Contents/SharedSupport/wine/bin/wine", exec: true)
        mk("\(G)/Contents/SharedSupport/prefix10/system.reg")
        mk("\(G)/Contents/SharedSupport/prefix10/drive_c/HorizonXI/Ashita-cli.exe")
        ln("\(G)/Contents/SharedSupport/prefix10/drive_c/HorizonXI/SquareEnix", "/Volumes/\(gone)/FFXI/SquareEnix")
        let ghost = Install(wrapper: F.appendingPathComponent(G), prefixName: "prefix10")
        check("game files behind a drive that is gone read as elsewhere (Move is offered)", InstallMove.dataElsewhere(ghost))
        let destG = F.appendingPathComponent("DestG")
        do {
            _ = try InstallMove.plan(ghost, world: "HorizonXI")
            check("Move refuses a source behind a missing drive", false)
        } catch {
            let l = (error as? InstallMove.Refusal)?.line ?? ""
            check("Move refuses a source behind a missing drive in one line: \(l)",
                  l == "The '\(gone)' drive isn't connected, so the game can't be moved." && !fm.fileExists(atPath: destG.path))
        }

        // MARK: Refused while anything runs
        let busy: [InstallMove.Activity] = [.init(clientsLive: true), .init(job: "Downloading"), .init(localServer: true),
                                            .init(wineRunning: true)]
        let busyLines = busy.compactMap { InstallMove.blocker($0) }
        check("Move refuses while a game, a job, the local server or Wine runs: \(busyLines)",
              busyLines.count == 4 && busyLines.allSatisfy { !$0.lowercased().contains("restart") })
        check("... and goes ahead when nothing runs", InstallMove.blocker(.init()) == nil)
        check("Move never resolves a link to the whole Mac, a drive or home",
              !InstallMove.resolvable("/", install: []) && !InstallMove.resolvable("/Volumes/x10", install: [])
                && !InstallMove.resolvable(fm.homeDirectoryForCurrentUser.path, install: [])
                && !InstallMove.resolvable("/a", install: ["/a/b"]) && InstallMove.resolvable("/Volumes/x10/FFXI/SquareEnix", install: ["/a"]))

        InstallLocation.defaults = savedDefaults
        defaults.removePersistentDomain(forName: suite)
        if !keepFixture { try? fm.removeItem(at: base) }

        var failed = 0
        for (name, ok) in results {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failed += 1 }
        }
        print("\(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
