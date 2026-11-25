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
        // The game's Wine beside the wrapper, as Setup (and Daniel's own install) has it.
        mk("Old Place/wine-coop/wine/bin/wine", exec: true)
        mk("Old Place/wine-coop/wine/bin/winegcc", 64, exec: true)
        ln("Old Place/wine-coop/wine/bin/winecpp", "winegcc")
        mk("Old Place/wine-coop/wine/lib/wine/x86_64-unix/ntdll.so", 3000)
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
                  oldNames == ["/\(P)", "/Other Drive/FFXI/SquareEnix", "/Old Place/wine-coop"])
            check("Move refuses a folder inside the install it moves, or inside the data it links to",
                  InstallMove.destinationProblem(F.appendingPathComponent("\(W)/Contents"), plan: plan) != nil
                    && InstallMove.destinationProblem(F.appendingPathComponent("Other Drive/FFXI/SquareEnix/FINAL FANTASY XI"), plan: plan) != nil
                    && InstallMove.destinationProblem(dest, plan: plan) == nil)
            var shown: [Double] = []
            // An earlier Move cut short by Quit left its hidden copy; a folder that only looks
            // like one (game-wine.sh's unpack folder) is not Move's.
            let stale = destFolder.appendingPathComponent(".\(InstallLocation.wrapperName).moving-1")
            let notOurs = destFolder.appendingPathComponent(".wine-coop-unpack.AbC123")
            try? fm.createDirectory(at: stale, withIntermediateDirectories: true)
            try? fm.createDirectory(at: notOurs, withIntermediateDirectories: true)
            let moved = try InstallMove.copy(plan, into: destFolder, progress: { shown.append($0) })
            check("an unfinished earlier Move's hidden copy is discarded first, nothing else",
                  !fm.fileExists(atPath: stale.path) && fm.fileExists(atPath: notOurs.path)
                    && ((try? fm.contentsOfDirectory(atPath: discarded.path)) ?? []).contains { $0.hasPrefix(stale.lastPathComponent) })
            try? fm.removeItem(at: notOurs)
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
            let nc = destFolder.appendingPathComponent(InstallLocation.gameWineFolder)
            let copied = InstallMove.add(InstallMove.tally(nw.path), InstallMove.tally(nc.path))
            check("the copy counts the same as the source as copied: \(copied)", copied == plan.expected)
            check("the game's Wine beside the wrapper came along, its relative link a link",
                  fm.isExecutableFile(atPath: InstallLocation.gameWine(in: destFolder).path)
                    && (try? fm.destinationOfSymbolicLink(atPath: nc.appendingPathComponent("wine/bin/winecpp").path)) == "winegcc"
                    && plan.keyFiles.contains("wine-coop/wine/bin/wine"))
            let savedWine2 = ProcessInfo.processInfo.environment["FFXI_ON_MAC_WINE"]
            unsetenv("FFXI_ON_MAC_WINE")
            check("... and is the game Wine Play runs from the new folder",
                  X87Sidecar.patchedWine()?.path == InstallLocation.gameWine(in: destFolder).path)
            if let w = savedWine2 { setenv("FFXI_ON_MAC_WINE", w, 1) }
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
                      (error as? InstallMove.Refusal)?.line.contains("already") == true
                        && InstallMove.add(InstallMove.tally(nw.path), InstallMove.tally(nc.path)) == plan.expected)
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
        check("game files behind a drive that is gone read as elsewhere, but Move… is not offered (it could only refuse)",
              InstallMove.dataElsewhere(ghost) && !InstallMove.offered(ghost) && !InstallMove.offered(old))
        let destG = F.appendingPathComponent("DestG")
        do {
            _ = try InstallMove.plan(ghost, world: "HorizonXI")
            check("Move refuses a source behind a missing drive", false)
        } catch {
            let l = (error as? InstallMove.Refusal)?.line ?? ""
            check("Move refuses a source behind a missing drive in one line: \(l)",
                  l == "The '\(gone)' drive isn't connected, so the game can't be moved." && !fm.fileExists(atPath: destG.path))
        }

        // MARK: What is already there (ExistingInstall): reused, moved, copied, never duplicated
        // Daniel, 2026-10-15: "is it going to auto recognize that and continue setup based on the
        // files there? or will it duplicate everything and create problems"
        typealias N = InstallLocation.Need
        func client(_ rel: String, _ version: String?, ashita: Bool = true) {
            for d in ["FFXi.dll", "FFXiMain.dll", "FFXiVersions.dll"] { mk("\(rel)/SquareEnix/FINAL FANTASY XI/\(d)", 300) }
            mk("\(rel)/SquareEnix/FINAL FANTASY XI/ROM/0/0.DAT", 4096)
            mk("\(rel)/SquareEnix/PlayOnlineViewer/viewer/com/polcore.dll", 200)
            if ashita { mk("\(rel)/Ashita-cli.exe", 100); mk("\(rel)/config/boot/horizonxi.ini", 40) }
            if let v = version {
                let u = F.appendingPathComponent("\(rel)/version.json")
                try? "{\n  \"version\": \"\(v)\"\n}\n".write(to: u, atomically: true, encoding: .utf8)
            }
        }
        func wrapperAt(_ rel: String, prefix: String = "prefix10") {
            mk("\(rel)/Contents/SharedSupport/wine/bin/wine", exec: true)
            mk("\(rel)/Contents/SharedSupport/\(prefix)/system.reg", 100)
        }
        func ino(_ rel: String) -> UInt64 { var st = stat(); return lstat(F.appendingPathComponent(rel).path, &st) == 0 ? UInt64(st.st_ino) : 0 }
        /// Every entry under `rel`: path, kind, size, link target (the read-only checks).
        func tree(_ rel: String) -> [String] {
            var out: [String] = []
            var stack = [F.appendingPathComponent(rel).path]
            while let cur = stack.popLast() {
                var st = stat()
                guard lstat(cur, &st) == 0 else { continue }
                let r = String(cur.dropFirst(F.path.count))
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    out.append("d \(r)")
                    for k in (try? fm.contentsOfDirectory(atPath: cur)) ?? [] { stack.append(cur + "/" + k) }
                case S_IFLNK: out.append("l \(r) -> \((try? fm.destinationOfSymbolicLink(atPath: cur)) ?? "?")")
                default: out.append("f \(r) \(st.st_size)")
                }
            }
            return out.sorted()
        }
        func wrappers(_ rel: String) -> [String] {
            var out: [String] = []
            var stack = [F.appendingPathComponent(rel).path]
            while let cur = stack.popLast() {
                if cur.hasSuffix(".app") { out.append(String(cur.dropFirst(F.path.count))); continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: cur, isDirectory: &isDir), isDir.boolValue else { continue }
                for k in (try? fm.contentsOfDirectory(atPath: cur)) ?? [] { stack.append(cur + "/" + k) }
            }
            return out.sorted()
        }
        let roomy = { () -> InstallLocation.Facts in var f = InstallLocation.Facts(); f.freeBytes = 5_000_000_000; return f }()

        // A. The layout Setup builds, chosen again (or its "FFXI on Mac" folder itself): reused.
        let A = "Reuse/FFXI on Mac"
        wrapperAt("\(A)/FFXI on Mac Wine.app")
        client("\(A)/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI", "2.0.4")
        mk("\(A)/wine-coop/wine/bin/wine", exec: true)
        let beforeA = tree("Reuse")
        let fa = ExistingInstall.find(in: F.appendingPathComponent("Reuse"))
        let aWrapper = F.appendingPathComponent("\(A)/FFXI on Mac Wine.app").path
        check("new layout: found and reused, no second wrapper: \(fa?.line ?? "nothing")",
              fa?.wrapper?.wrapper.path == aWrapper && fa?.newLayout == true && fa?.clientInWrapper == true
                && fa?.client?.complete == true && fa?.gameWine != nil
                && InstallLocation.wrapper(in: fa!.home).path == aWrapper
                && fa?.line == "Found HorizonXI 2.0.4 here — Setup will use it.")
        check("... the same when its \"FFXI on Mac\" folder itself is chosen",
              ExistingInstall.find(in: F.appendingPathComponent(A))?.wrapper?.wrapper.path == aWrapper)
        let needA = ExistingInstall.need(fa, gameWineElsewhere: false, latest: "2.0.4")
        check("... nothing to download at the latest version (need \(needA)), and the chooser takes it with 5 GB free",
              needA == 0 && InstallLocation.verdict(roomy, need: needA).line.contains("nothing more to download"))
        check("... a version behind needs about an update (\(InstallLocation.gbUp(ExistingInstall.need(fa, gameWineElsewhere: false, latest: "2.0.5"))))",
              ExistingInstall.need(fa, gameWineElsewhere: false, latest: "2.0.5") == N.update)
        check("... where a fresh install there would be refused for room",
              !InstallLocation.verdict(roomy, need: ExistingInstall.need(nil, gameWineElsewhere: false, latest: nil)).isOK)
        check("looking is read-only", tree("Reuse") == beforeA)

        // B. An older wrapper: siku.app three folders down, the game's Wine beside it.
        let B = "Adopt/Mac/FFXI"
        wrapperAt("\(B)/siku.app")
        client("\(B)/siku.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI", "2.0.4")
        mk("\(B)/siku.app/Contents/SharedSupport/prefix-old/drive_c/HorizonXI/config/boot/x.ini")
        mk("\(B)/siku.app/Contents/SharedSupport/prefix-installers/system.reg")
        mk("\(B)/wine-coop/wine/bin/wine", exec: true)
        wrapperAt("\(B)/Other.app")                                    // a wrapper without HorizonXI: not it
        let beforeB = tree("Adopt")
        let fb = ExistingInstall.find(in: F.appendingPathComponent("Adopt"))
        check("old wrapper (siku.app): adopted as the install in use, its game prefix: \(fb?.line ?? "nothing")",
              fb?.wrapper?.wrapper.lastPathComponent == "siku.app" && fb?.wrapper?.prefixName == "prefix10"
                && fb?.newLayout == false && fb?.clientInWrapper == true && fb?.client?.version == "2.0.4"
                && fb?.line == "Found HorizonXI 2.0.4 in “siku.app” — Setup will use it.")
        check("... Setup works beside it (its folder; the game's Wine found there), builds no wrapper",
              fb?.home.path == F.appendingPathComponent(B).path && fb?.gameWine != nil
                && !fm.fileExists(atPath: InstallLocation.wrapper(in: fb!.home).path)
                && wrappers("Adopt") == ["/\(B)/Other.app", "/\(B)/siku.app"])
        check("... and needs nothing more (\(ExistingInstall.need(fb, gameWineElsewhere: false, latest: "2.0.4")) bytes)",
              ExistingInstall.need(fb, gameWineElsewhere: false, latest: "2.0.4") == 0)
        check("... read-only", tree("Adopt") == beforeB)
        // The old ~/Applications default, Wine and a Windows drive and no game.
        wrapperAt("OldApps/FFXI on Mac Wine.app")
        let fo = ExistingInstall.find(in: F.appendingPathComponent("OldApps"))
        let needO = ExistingInstall.need(fo, gameWineElsewhere: false, latest: nil)
        check("the old \"FFXI on Mac Wine.app\" with no game: its Wine is used, the game still needed: \(fo?.line ?? "nothing")",
              fo?.wrapper?.wrapper.lastPathComponent == "FFXI on Mac Wine.app" && fo?.client == nil
                && fo?.line == "Found Wine in “FFXI on Mac Wine.app” — Setup will use it."
                && needO == N.gameWine + N.gameZip + N.gameUnpacked)
        // An unfinished download in a wrapper: what is there is not asked for again.
        mk("OldApps/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI/updates/HorizonXI.zip", 5000)
        let fp = ExistingInstall.find(in: F.appendingPathComponent("OldApps"))
        check("... a part-downloaded base counts against the need (aria2 resumes it)",
              fp?.partialBytes == 5000 && ExistingInstall.need(fp, gameWineElsewhere: false, latest: nil) == needO - 5000)

        // C. A HorizonXI client on its own, on the same drive: moved in by one rename.
        client("Bare/HorizonXI", "2.0.3")
        let fc = ExistingInstall.find(in: F.appendingPathComponent("Bare"))
        let homeC = F.appendingPathComponent("Bare/FFXI on Mac")
        check("bare HorizonXI: found, to be moved into a new FFXI on Mac: \(fc?.line ?? "nothing")",
              fc?.wrapper == nil && fc?.client?.sameVolume == true && fc?.clientInWrapper == false && fc?.home.path == homeC.path
                && fc?.line == "Found HorizonXI 2.0.3 here — Setup will move it into FFXI on Mac.")
        let needC = ExistingInstall.need(fc, gameWineElsewhere: false, latest: "2.0.4")
        check("... needs Wine, the game's Wine and an update, not the 25 GB (\(InstallLocation.gbUp(needC)) vs \(InstallLocation.gbUp(N.fresh)))",
              needC == N.wine + N.gameWine + N.update)
        // Setup: the sheet builds Wine and its drive (stood in for here), then the move.
        let builtC = InstallLocation.install(in: homeC)
        wrapperAt("Bare/FFXI on Mac/FFXI on Mac Wine.app")
        try? fm.createDirectory(at: builtC.driveC.appendingPathComponent("HorizonXI"), withIntermediateDirectories: true)
        let inoC = ino("Bare/HorizonXI/SquareEnix/FINAL FANTASY XI/ROM/0/0.DAT")
        let tallyC = InstallMove.tally(F.appendingPathComponent("Bare/HorizonXI").path)
        do {
            let dest = try ExistingInstall.moveIn(fc!.client!, to: builtC)
            let moved = "Bare/FFXI on Mac/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI"
            check("... moved, not copied: the same files (inode) at \(String(dest.path.dropFirst(F.path.count)))",
                  dest.path == F.appendingPathComponent(moved).path && ino("\(moved)/SquareEnix/FINAL FANTASY XI/ROM/0/0.DAT") == inoC
                    && InstallMove.tally(dest.path) == tallyC && builtC.hasGame)
            // Every regular file named 0.DAT under the folder, links not followed: one, not two.
            var dats = 0
            var walk = [F.appendingPathComponent("Bare").path]
            while let cur = walk.popLast() {
                var st = stat()
                guard lstat(cur, &st) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR {
                    for k in (try? fm.contentsOfDirectory(atPath: cur)) ?? [] { walk.append(cur + "/" + k) }
                } else if st.st_mode & S_IFMT == S_IFREG, cur.hasSuffix("/0.DAT") { dats += 1 }
            }
            check("... no second copy of any file in the folder (\(dats) copy of 0.DAT)", dats == 1)
            check("... a link left where it was, to the same files",
                  (try? fm.destinationOfSymbolicLink(atPath: F.appendingPathComponent("Bare/HorizonXI").path)) == dest.path)
            check("... one wrapper in the folder", wrappers("Bare") == ["/Bare/FFXI on Mac/FFXI on Mac Wine.app"])
            // An older wrapper whose HorizonXI linked to the client: one install in the picker.
            wrapperAt("Bare/old.app")
            ln("Bare/old.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI", F.appendingPathComponent("Bare/HorizonXI").path)
            let oldC = Install(wrapper: F.appendingPathComponent("Bare/old.app"), prefixName: "prefix10")
            let listed = Install.dedupe([oldC, builtC], keep: builtC.id)
            check("an older entry that points at the same files is dropped from the picker, the new one kept (files untouched)",
                  listed.map(\.id) == [builtC.id] && fm.fileExists(atPath: oldC.prefix.path)
                    && Install.dedupe([oldC, builtC]).map(\.id) == [oldC.id])
            check("... entries with different files both stay", Install.dedupe([builtC, old]).count == 2)
            let again = ExistingInstall.find(in: F.appendingPathComponent("Bare"))
            check("a second Setup in the same folder reuses the moved install (no second move): \(again?.line ?? "nothing")",
                  again?.wrapper?.wrapper.path == builtC.wrapper.path && again?.clientInWrapper == true)
            check("a world's folder setting that named the client follows it; HorizonXI's goes back to the install's own",
                  ExistingInstall.rewritten(F.appendingPathComponent("Bare/HorizonXI").path, from: fc!.client!.url, to: dest, classic: dest) == ""
                    && ExistingInstall.rewritten(F.appendingPathComponent("Bare/HorizonXI/sub").path, from: fc!.client!.url, to: dest, classic: nil)
                        == dest.path + "/sub"
                    && ExistingInstall.rewritten("/elsewhere", from: fc!.client!.url, to: dest, classic: nil) == nil)
        } catch {
            check("bare HorizonXI moved in: \(error.localizedDescription)", false)
        }
        // The launcher's own unfinished download where the client goes: to the Trash, not deleted.
        client("Bare2/HorizonXI", "2.0.4")
        wrapperAt("Bare2/FFXI on Mac/FFXI on Mac Wine.app")
        mk("Bare2/FFXI on Mac/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI/updates/HorizonXI.zip", 3000)
        let f2 = ExistingInstall.find(in: F.appendingPathComponent("Bare2"))
        let trashed = ((try? fm.contentsOfDirectory(atPath: discarded.path)) ?? []).count
        do {
            try ExistingInstall.moveIn(f2!.client!, to: f2!.wrapper!)
            check("bare client into a wrapper with an unfinished download: that wrapper used, the download to the Trash",
                  f2?.wrapper?.wrapper.lastPathComponent == "FFXI on Mac Wine.app" && f2!.wrapper!.hasGame
                    && ((try? fm.contentsOfDirectory(atPath: discarded.path)) ?? []).count == trashed + 1
                    && wrappers("Bare2").count == 1)
        } catch {
            check("bare client into a wrapper with an unfinished download: \(error.localizedDescription)", false)
        }

        // D. A SquareEnix folder on its own: moved into HorizonXI/SquareEnix; the base still comes
        // (HorizonXI ships Ashita only in it), so the need is the download, not the duplicate.
        client("SE/x", nil, ashita: false)
        try? fm.moveItem(at: F.appendingPathComponent("SE/x/SquareEnix"), to: F.appendingPathComponent("SE/SquareEnix"))
        try? fm.removeItem(at: F.appendingPathComponent("SE/x"))
        let fd = ExistingInstall.find(in: F.appendingPathComponent("SE"))
        check("bare SquareEnix: found, to be moved in: \(fd?.line ?? "nothing")",
              fd?.client?.squareEnixOnly == true
                && fd?.line == "Found FINAL FANTASY XI's files here — Setup will move them into FFXI on Mac."
                && ExistingInstall.need(fd, gameWineElsewhere: true, latest: nil) == N.wine + N.gameZip + N.gameUnpacked)
        let builtD = InstallLocation.install(in: fd?.home ?? F)
        wrapperAt("SE/FFXI on Mac/FFXI on Mac Wine.app")
        let inoD = ino("SE/SquareEnix/FINAL FANTASY XI/ROM/0/0.DAT")
        if let c = fd?.client, let dest = try? ExistingInstall.moveIn(c, to: builtD) {
            check("... now HorizonXI/SquareEnix in the install, the same files",
                  dest.path == builtD.driveC.appendingPathComponent("HorizonXI/SquareEnix").path
                    && ino(String(dest.path.dropFirst(F.path.count + 1)) + "/FINAL FANTASY XI/ROM/0/0.DAT") == inoD)
        } else {
            check("bare SquareEnix moved in", false)
        }
        // Another world's SquareEnix or client is never taken for HorizonXI's.
        client("Worlds/Eden/SquareEnixHolder", "2.0.4")
        client("Worlds/CatsEyeXI/catseyexi-client", nil)
        mk("Worlds/Gaia XI/SquareEnix/FINAL FANTASY XI/FFXiMain.dll")
        let fw = ExistingInstall.find(in: F.appendingPathComponent("Worlds"))
        check("other worlds' clients and SquareEnix folders are left alone" + (fw.map { ": found \($0.client?.url.path ?? $0.home.path)" } ?? ""), fw == nil)

        // E. On another drive (injected): copied, verified, the original kept exactly as it was.
        let savedSame = ExistingInstall.sameVolume
        ExistingInstall.sameVolume = { _, _ in false }
        client("Cross/HorizonXI", "2.0.4")
        let fe = ExistingInstall.find(in: F.appendingPathComponent("Cross"))
        check("on another drive: to be copied, keeping it: \(fe?.line ?? "nothing")",
              fe?.client?.sameVolume == false && fe?.line == "Found HorizonXI 2.0.4 on another drive — Setup will copy it."
                && ExistingInstall.need(fe, gameWineElsewhere: true, latest: "2.0.4") == N.wine + N.gameUnpacked)
        let builtE = InstallLocation.install(in: fe?.home ?? F)
        wrapperAt("Cross/FFXI on Mac/FFXI on Mac Wine.app")
        let beforeE = tree("Cross/HorizonXI")
        do {
            try ExistingInstall.moveIn(fe!.client!, to: builtE)
            check("a move across drives is refused", false)
        } catch {
            check("a move across drives is refused, nothing changed: \((error as? InstallMove.Refusal)?.line ?? "?")",
                  (error as? InstallMove.Refusal)?.line.contains("another drive") == true && tree("Cross/HorizonXI") == beforeE)
        }
        ExistingInstall.sameVolume = savedSame
        do {
            let dest = ExistingInstall.destination(for: fe!.client!, in: builtE)
            var shownE: [Double] = []
            try InstallMove.copyTree(fe!.client!.url, to: dest, progress: { shownE.append($0) })
            check("... the copy path: verified, in place, the original exactly as it was",
                  InstallMove.tally(dest.path) == InstallMove.tally(F.appendingPathComponent("Cross/HorizonXI").path)
                    && builtE.hasGame && tree("Cross/HorizonXI") == beforeE && shownE.last == 1
                    && !((try? fm.contentsOfDirectory(atPath: builtE.driveC.path)) ?? []).contains { $0.hasPrefix(".") })
        } catch {
            check("the copy path: \(error.localizedDescription)", false)
        }

        // F. Files behind a drive that is gone: said in one line, never touched, Download Fresh.
        wrapperAt("Ghosty/siku.app")
        mk("Ghosty/siku.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI/Ashita-cli.exe")
        ln("Ghosty/siku.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI/SquareEnix", "/Volumes/\(gone)/FFXI/SquareEnix")
        let ff = ExistingInstall.find(in: F.appendingPathComponent("Ghosty"))
        check("game files linked to a drive that is gone: one line naming it: \(ff?.line ?? "nothing")",
              ff?.unreachableDrive == gone && ff?.line == "HorizonXI here is on the '\(gone)' drive, which isn't connected."
                && ff?.line.lowercased().contains("restart") == false && ExistingInstall.refusal(ff) == nil)
        let freshF = ExistingInstall.fresh(ff)
        check("... Download Fresh goes in the chosen folder with the full need, the link untouched",
              freshF?.client == nil && freshF?.wrapper == nil && freshF?.home.path == F.appendingPathComponent("Ghosty/FFXI on Mac").path
                && ExistingInstall.need(freshF, gameWineElsewhere: false, latest: nil) == N.fresh
                && (try? fm.destinationOfSymbolicLink(atPath: F.appendingPathComponent("Ghosty/siku.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI/SquareEnix").path)) == "/Volumes/\(gone)/FFXI/SquareEnix")
        wrapperAt("GhostHome/FFXI on Mac/FFXI on Mac Wine.app")
        ln("GhostHome/FFXI on Mac/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10/drive_c/HorizonXI", "/Volumes/\(gone)/HorizonXI")
        let fg = ExistingInstall.find(in: F.appendingPathComponent("GhostHome"))
        check("... when that install is the chosen folder's own FFXI on Mac, the folder is refused: \(ExistingInstall.refusal(fg) ?? "-")",
              fg?.unreachableAtHome == true && ExistingInstall.refusal(fg)?.contains("'\(gone)'") == true)
        ln("GhostSE/SquareEnix", "/Volumes/\(gone)/FFXI/SquareEnix")
        check("a SquareEnix that is a link onto a drive that is gone is said so too",
              ExistingInstall.find(in: F.appendingPathComponent("GhostSE"))?.unreachableDrive == gone)
        // A usable install beats one behind a gone drive.
        client("Ghosty/HorizonXI", "2.0.4")
        check("... and a usable client beside it is used instead",
              ExistingInstall.find(in: F.appendingPathComponent("Ghosty"))?.client?.url.lastPathComponent == "HorizonXI"
                && ExistingInstall.find(in: F.appendingPathComponent("Ghosty"))?.unreachableDrive == nil)

        // G. The chosen folder is the client itself: FFXI on Mac goes beside it.
        client("Self/HorizonXI", "2.0.4")
        let fs = ExistingInstall.find(in: F.appendingPathComponent("Self/HorizonXI"))
        check("choosing the client folder itself: it is used, FFXI on Mac beside it",
              fs?.client?.url.path == F.appendingPathComponent("Self/HorizonXI").path
                && fs?.home.path == F.appendingPathComponent("Self/FFXI on Mac").path && ExistingInstall.refusal(fs) == nil)

        // H. Bounds: three folders down, never into an app's own files or system folders.
        client("Deep/a/b/c/HorizonXI", "2.0.4")
        client("Deep2/Library/HorizonXI", "2.0.4")
        client("Deep2/x.app/Contents/HorizonXI", "2.0.4")
        check("no deeper than three folders, never into Library or an app",
              ExistingInstall.find(in: F.appendingPathComponent("Deep")) == nil && ExistingInstall.find(in: F.appendingPathComponent("Deep2")) == nil)
        try? fm.createDirectory(at: F.appendingPathComponent("Empty/sub"), withIntermediateDirectories: true)
        check("nothing found in a folder with nothing in it", ExistingInstall.find(in: F.appendingPathComponent("Empty")) == nil)
        let home = fm.homeDirectoryForCurrentUser
        check("Desktop, Documents and Downloads are looked in only once chosen",
              ExistingInstall.isGated(home.appendingPathComponent("Downloads/x")) && !ExistingInstall.isGated(home.appendingPathComponent("Games")))

        // I. The game's Wine in a folder chosen before is still found (never downloaded twice).
        InstallLocation.remember(F.appendingPathComponent("Adopt/Mac/FFXI"))
        InstallLocation.remember(F.appendingPathComponent("Bare/FFXI on Mac"))
        check("the game's Wine in an earlier folder is still found after choosing a new one",
              X87Sidecar.patchedWineCandidates.contains(F.appendingPathComponent("Adopt/Mac/FFXI/wine-coop/wine/bin/wine").path)
                && InstallLocation.earlier.first?.path == F.appendingPathComponent("Adopt/Mac/FFXI").path)
        InstallLocation.remember(destFolder)

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
                && !InstallMove.resolvable("/a", install: ["/a/b"]) && InstallMove.resolvable("/Volumes/x10/FFXI/SquareEnix", install: ["/a"])
                && !InstallMove.resolvable("/Users", install: []) && !InstallMove.resolvable("/Applications", install: [])
                && !InstallMove.resolvable("/System/Library", install: []) && !InstallMove.resolvable("/usr/local", install: [])
                && InstallMove.resolvable("/Users/someone/Games/SquareEnix", install: ["/a"]))

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
