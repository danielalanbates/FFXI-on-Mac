// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// `--selftest-carryover`: CarryOver on installs made up in a folder of its own under $TMPDIR:
/// a fresh destination and one a character has played in, a source behind a link, a missing
/// source, an unreadable one, two sources (the newer wins), the marker (once only), the backups,
/// the boot profiles never copied, a game running, the launch lock taken, no room, a copy that
/// fails, files changed between the plan and the copy, a link out of the destination, names
/// that differ only in case. With the old USER fixture
/// (`HXI_CARRYOVER_FIXTURE`, else ~/Downloads/FFXI-on-Mac-build/fixture/old-USER/USER) it also
/// carries a copy of that real folder. Nothing outside the work folder is written: no install,
/// no defaults, not launcher.log, not the launch lock (the test uses a lock file of its own).
extension Headless {
    static func runCarryOverSelfTest() -> Never {
        typealias C = CarryOver
        var checks: [(String, Bool)] = []
        let fm = FileManager.default
        let work = URL(fileURLWithPath: fm.temporaryDirectory.appendingPathComponent("ffxi-carryover-selftest-\(UUID().uuidString)").path)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let day = Date(timeIntervalSince1970: 1_792_094_400)   // 2026-10-15 20:00 UTC
        let old = Date(timeIntervalSince1970: 1_788_091_200)   // 2026-08-30
        let older = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01
        var running = false
        var free: Int64 = 50_000_000_000
        let lockFile = work.appendingPathComponent("launch.lock")
        let env = C.Environment(gameRunning: { running }, lock: { LaunchLock.acquire(at: lockFile) },
                                unlock: { LaunchLock.release($0) }, space: { _ in (free, false) }, now: { day })
        var unlockLater: [URL] = []

        @discardableResult
        func put(_ u: URL, _ text: String, _ date: Date? = nil) -> URL {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data(text.utf8))
            if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path) }
            return u
        }
        func text(_ u: URL) -> String? { (try? Data(contentsOf: u)).map { String(decoding: $0, as: UTF8.self) } }
        func mdate(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        /// An install as Setup lays it out: wrapper, prefix10, drive_c/HorizonXI with Ashita and
        /// the game's files.
        func install(_ name: String) -> Install {
            let i = Install(wrapper: work.appendingPathComponent(name + "/FFXI on Mac Wine.app"), prefixName: "prefix10")
            try? fm.createDirectory(at: i.sharedSupport.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
            put(i.gameDir.appendingPathComponent("Ashita-cli.exe"), "MZ")
            put(i.gameDir.appendingPathComponent("SquareEnix/FINAL FANTASY XI/FFXiMain.dll"), "MZ")
            put(i.gameDir.appendingPathComponent("config/boot/horizonxi.ini"), "--user dest --pass dest-own-password\n")
            put(i.gameDir.appendingPathComponent("config/ashita/custom.pointers.ini"), "dest pointers\n")
            return i
        }
        func user(_ i: Install, _ rel: String) -> URL { C.side(i).user.appendingPathComponent(rel) }
        func config(_ i: Install, _ rel: String) -> URL { i.gameDir.appendingPathComponent("config/" + rel) }
        /// A played client: two characters, files beside them, settings, and everything that must
        /// never be carried.
        func played(_ i: Install, date: Date, tag: String = "old") {
            for rel in ["1410b/mcr.dat", "1410b/mcr1.dat", "1410b/es0.dat", "1410b/keybind.dat", "99f/mcr.dat", "tig.dat", "cmb0.dat"] {
                put(user(i, rel), "\(tag) \(rel)", date)
            }
            put(config(i, "addons/clock/Murn_1/settings.lua"), "\(tag) clock", date)
            put(config(i, "addons/LuAshitacast/Murn_1/WAR.lua"), "\(tag) gear", date)
            put(config(i, "imgui.ini"), "\(tag) layout", date)
            put(config(i, "minimap/minimap.ini"), "\(tag) minimap", date)
            put(config(i, "boot/horizonxi.ini"), "--user murn --pass hunter2-secret\n", date)
            put(config(i, "ashita/custom.pointers.ini"), "\(tag) pointers", date)
            put(config(i, "sandbox/sandbox.ini"), "\(tag) sandbox", date)
            put(config(i, "pivot/pivot.ini"), "\(tag) pivot", date)
        }
        /// Every file under `dir`, relative, with its bytes: enough to see that nothing changed.
        func snapshot(_ dir: URL) -> [String: Data] {
            var out: [String: Data] = [:]
            let base = InstallMove.realPath(dir.path) ?? dir.path
            for case let rel as String in fm.enumerator(atPath: base)?.allObjects ?? [] {
                var st = stat()
                guard lstat(base + "/" + rel, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
                out[rel] = fm.contents(atPath: base + "/" + rel)
            }
            return out
        }
        func leftovers(_ dir: URL) -> [String] {
            ((fm.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []).filter { $0.contains(".carryover-") && !$0.contains(".bak-") }
        }
        func gameDirs(_ l: [Install]) -> [URL] { l.map(\.gameDir) }

        // MARK: Reading
        let src = install("src")
        played(src, date: old)
        try? fm.createDirectory(at: work.appendingPathComponent("outside"), withIntermediateDirectories: true)
        put(work.appendingPathComponent("outside/secret.dat"), "outside")
        try? fm.createSymbolicLink(atPath: user(src, "99f/link").path, withDestinationPath: work.appendingPathComponent("outside").path)
        try? fm.createSymbolicLink(atPath: user(src, "loop").path, withDestinationPath: C.side(src).user.path)
        let srcCand = C.survey(C.side(src))
        checks.append(("a USER folder reads as its files; characters are the folders with files in them",
                       srcCand.user.files.count == 7 && srcCand.characters == 2 && srcCand.usable))
        checks.append(("links inside are counted and never followed (one to another folder, one back to USER itself)",
                       srcCand.user.links == 2 && !srcCand.user.files.contains { $0.rel.contains("secret") || $0.rel.hasPrefix("loop") }))
        checks.append(("config: boot, ashita, sandbox and pivot are never read for carrying; addons, imgui.ini and plugin folders are",
                       Set(srcCand.config.files.map(\.rel)) == ["addons/LuAshitacast/Murn_1/WAR.lua", "addons/clock/Murn_1/settings.lua",
                                                                  "imgui.ini", "minimap/minimap.ini"]))
        let caps = work.appendingPathComponent("caps")
        put(caps.appendingPathComponent("Boot/x.ini"), "--pass x")
        put(caps.appendingPathComponent("ASHITA/y.ini"), "y")
        put(caps.appendingPathComponent("Pivot/z.ini"), "z")
        put(caps.appendingPathComponent("Addons/a/b.lua"), "b")
        put(caps.appendingPathComponent(".DS_Store"), "finder")
        checks.append(("... whatever their case; .DS_Store never",
                       C.read(caps, skipping: C.configSkipped).files.map(\.rel) == ["Addons/a/b.lua"]))
        checks.append(("a folder that is not there reads as empty, with no problem",
                       C.read(work.appendingPathComponent("nowhere")) == C.Tree()))
        let empty = install("empty")
        try? fm.createDirectory(at: user(empty, "13459"), withIntermediateDirectories: true)
        put(user(empty, "tig.dat"), "title")
        checks.append(("an empty character folder and files beside them are not a character that played",
                       C.read(C.side(empty).user).characters().isEmpty))

        // MARK: Fresh destination
        let dest = install("dest")
        put(config(dest, "imgui.ini"), "shipped layout", day)
        put(config(dest, "addons/filters/shipped.lua"), "shipped")
        put(config(dest, "minimap/minimap.ini"), "\("old") minimap", old)   // already the same
        let destBootBefore = text(config(dest, "boot/horizonxi.ini"))
        let destAshitaBefore = text(config(dest, "ashita/custom.pointers.ini"))
        let (du0, dc0) = C.readDest(C.side(dest))
        let p0 = C.plan(from: srcCand, to: C.side(dest), destUser: du0, destConfig: dc0)
        checks.append(("fresh: every USER file added, imgui.ini replaced, minimap already the same, the shipped addon file left",
                       p0.mode == .fresh && p0.count(.user, replaces: false) == 7 && p0.count(.user, replaces: true) == 0
                           && p0.items.filter { $0.area == .config }.map(\.target).sorted()
                               == ["addons/LuAshitacast/Murn_1/WAR.lua", "addons/clock/Murn_1/settings.lua", "imgui.ini"]
                           && p0.replaced == 1 && p0.same == 1 && p0.charactersAdded == ["1410b", "99f"]))
        let line0 = C.automatic(.setup, dest: dest, known: gameDirs([dest, src]), env: env).line ?? ""
        print("  log: \(line0)")
        let rec0 = C.record(dest.gameDir)
        checks.append(("Setup's carry-over: one line, the marker says done and where from",
                       line0.hasPrefix("==> carried over macros and settings from ") && line0.contains("2 characters, 10 files")
                           && rec0?.state == .done && rec0?.from == src.gameDir.path && rec0?.files == 10 && rec0?.replaced == 1))
        let same = ["1410b/mcr.dat", "1410b/mcr1.dat", "1410b/es0.dat", "1410b/keybind.dat", "99f/mcr.dat", "tig.dat", "cmb0.dat"].allSatisfy {
            text(user(dest, $0)) == text(user(src, $0)) && mdate(user(dest, $0)) == mdate(user(src, $0))
        }
        checks.append(("every USER file byte for byte, with its date", same))
        checks.append(("addon settings, gear sets and the ImGui layout arrived",
                       text(config(dest, "addons/clock/Murn_1/settings.lua")) == "old clock"
                           && text(config(dest, "addons/LuAshitacast/Murn_1/WAR.lua")) == "old gear"
                           && text(config(dest, "imgui.ini")) == "old layout"))
        let destFiles = snapshot(dest.gameDir)
        checks.append(("the boot profile is never copied: the destination's own is untouched, the password appears nowhere",
                       text(config(dest, "boot/horizonxi.ini")) == destBootBefore
                           && !destFiles.values.contains { String(decoding: $0, as: UTF8.self).contains("hunter2") }
                           && !line0.contains("hunter2")))
        checks.append(("ashita/, sandbox/ and pivot/ are not copied",
                       text(config(dest, "ashita/custom.pointers.ini")) == destAshitaBefore
                           && !fm.fileExists(atPath: config(dest, "sandbox").path) && !fm.fileExists(atPath: config(dest, "pivot").path)))
        let dayName = C.day(day)
        let configBak = dest.gameDir.appendingPathComponent("config.bak-\(dayName)-carryover")
        checks.append(("the replaced file is kept, as it was, in config.bak-<date>-carryover; nothing else is there",
                       text(configBak.appendingPathComponent("imgui.ini")) == "shipped layout"
                           && snapshot(configBak).count == 1
                           && !fm.fileExists(atPath: C.side(dest).user.path + ".bak-\(dayName)-carryover")))
        checks.append(("the shipped file the source does not have stays", text(config(dest, "addons/filters/shipped.lua")) == "shipped"))
        checks.append(("no link was followed: nothing from outside, no loop", !fm.fileExists(atPath: user(dest, "99f/link").path)
                           && !fm.fileExists(atPath: user(dest, "loop").path)))
        checks.append(("no hidden copy folder left behind", leftovers(dest.gameDir).isEmpty))
        // Once.
        put(user(dest, "1410b/mcr.dat"), "played since")
        let again = C.automatic(.setup, dest: dest, known: gameDirs([src]), env: env).line
        let againPlay = C.automatic(.play, dest: dest, known: gameDirs([src]), env: env).line
        checks.append(("once only: another Setup or a Play does nothing (the marker), even with the source still there",
                       again == nil && againPlay == nil && text(user(dest, "1410b/mcr.dat")) == "played since"))
        checks.append(("a Play never starts one Setup did not leave pending",
                       C.automatic(.play, dest: install("never-set-up"), known: gameDirs([src]), env: env).line == nil
                           && C.record(install("never-set-up").gameDir) == nil))

        // MARK: A destination a character has played in
        let playedDest = install("played")
        put(user(playedDest, "13459/mcr.dat"), "new character")
        put(user(playedDest, "1410B/mcr.dat"), "new on this install")
        put(user(playedDest, "tig.dat"), "new title")
        put(config(playedDest, "imgui.ini"), "new layout")
        let before = snapshot(playedDest.gameDir)
        let skippedLine = C.automatic(.setup, dest: playedDest, known: gameDirs([src]), env: env).line ?? ""
        checks.append(("played: nothing is carried by itself; the marker says skipped",
                       skippedLine.contains("not done") && C.record(playedDest.gameDir)?.state == .skipped
                           && snapshot(playedDest.gameDir).filter { !$0.key.hasPrefix(".ffxi") } == before))
        let (pu, pc) = C.readDest(C.side(playedDest))
        let pp = C.plan(from: srcCand, to: C.side(playedDest), destUser: pu, destConfig: pc)
        checks.append(("by hand into it: only what is missing (99f whole, cmb0.dat, settings); 1410b kept whole, whatever its case; nothing replaced",
                       pp.mode == .played && pp.replaced == 0 && pp.charactersAdded == ["99f"] && pp.charactersKept == ["1410b"]
                           && Set(pp.items.map(\.target)) == ["99f/mcr.dat", "cmb0.dat", "addons/LuAshitacast/Murn_1/WAR.lua",
                                                               "addons/clock/Murn_1/settings.lua", "minimap/minimap.ini"]
                           && pp.kept == 6))
        let po = (try? C.apply(pp, from: srcCand.side, to: C.side(playedDest), env: env)) ?? C.Outcome(failed: ["threw"])
        checks.append(("... carried out: the character that played and every file that was there are as they were, no backup",
                       po.added == 5 && po.replaced == 0 && po.backups.isEmpty && po.failed.isEmpty
                           && text(user(playedDest, "13459/mcr.dat")) == "new character"
                           && text(user(playedDest, "1410B/mcr.dat")) == "new on this install"
                           && !fm.fileExists(atPath: user(playedDest, "1410b/es0.dat").path)
                           && text(user(playedDest, "tig.dat")) == "new title" && text(config(playedDest, "imgui.ini")) == "new layout"
                           && text(user(playedDest, "99f/mcr.dat")) == "old 99f/mcr.dat"))

        // MARK: Choosing the source
        let link = install("linked")
        try? fm.removeItem(at: link.gameDir.appendingPathComponent("SquareEnix"))
        let otherDrive = work.appendingPathComponent("Games/FFXI/SquareEnix")
        put(otherDrive.appendingPathComponent("FINAL FANTASY XI/FFXiMain.dll"), "MZ")
        for rel in ["5155/mcr.dat", "5155/es1.dat"] { put(otherDrive.appendingPathComponent("FINAL FANTASY XI/USER/" + rel), "linked \(rel)", day) }
        try? fm.createSymbolicLink(atPath: link.gameDir.appendingPathComponent("SquareEnix").path, withDestinationPath: otherDrive.path)
        let alias = work.appendingPathComponent("alias")
        try? fm.createSymbolicLink(atPath: alias.path, withDestinationPath: link.gameDir.path)
        let found = C.candidates([link.gameDir, alias, otherDrive], dest: C.side(install("fresh-a")))
        checks.append(("a SquareEnix behind a link is followed; the same USER reached three ways is one candidate",
                       found.count == 1 && found[0].usable && found[0].characters == 1
                           && found[0].identity == (InstallMove.canonical(otherDrive.path) ?? "") + "/FINAL FANTASY XI/USER"))
        let sharing = install("sharing")
        try? fm.removeItem(at: sharing.gameDir.appendingPathComponent("SquareEnix"))
        try? fm.createSymbolicLink(atPath: sharing.gameDir.appendingPathComponent("SquareEnix").path, withDestinationPath: otherDrive.path)
        checks.append(("never the destination's own files, however reached",
                       C.candidates([link.gameDir, sharing.gameDir, src.gameDir], dest: C.side(sharing)).map(\.side.root.path) == [src.gameDir.path]))
        let freshA = install("fresh-a")
        let linkLine = C.automatic(.setup, dest: freshA, known: gameDirs([link]), env: env).line ?? ""
        checks.append(("carried from the linked folder", linkLine.hasPrefix("==> ") && text(user(freshA, "5155/es1.dat")) == "linked 5155/es1.dat"))

        let newer = install("newer")
        played(newer, date: day, tag: "newer")
        let oldest = install("oldest")
        played(oldest, date: older, tag: "oldest")
        let pick1 = C.choose(C.candidates(gameDirs([oldest, newer, src]), dest: C.side(install("x"))))
        let pick2 = C.choose(C.candidates(gameDirs([newer, oldest]), dest: C.side(install("x"))))
        checks.append(("two or more sources: the one whose USER has the newest file, in any order",
                       pick1?.side.root.path == newer.gameDir.path && pick2?.side.root.path == newer.gameDir.path))
        let twin = install("twin")
        played(twin, date: old)
        checks.append(("equal dates: the first in the list (the install in use before Setup comes first)",
                       C.choose(C.candidates(gameDirs([twin, src]), dest: C.side(install("x"))))?.side.root.path == twin.gameDir.path
                           && C.choose(C.candidates(gameDirs([src, twin]), dest: C.side(install("x"))))?.side.root.path == src.gameDir.path))
        let noChars = install("no-characters")
        put(user(noChars, "tig.dat"), "title only", day)
        checks.append(("a client with no character is never a source",
                       C.choose(C.candidates(gameDirs([noChars]), dest: C.side(install("x")))) == nil))
        let wrapperSide = C.side(at: work.appendingPathComponent("newer/FFXI on Mac Wine.app"))
        let folderSide = C.side(at: work.appendingPathComponent("newer"))
        checks.append(("by hand, a wrapper .app or the folder holding it names its client",
                       wrapperSide?.root.path == newer.gameDir.path && folderSide?.root.path == newer.gameDir.path))
        let seOnly = C.side(at: otherDrive)
        checks.append(("... and a SquareEnix folder on its own names its USER only", seOnly?.config == nil && seOnly.map(C.identity) != nil))

        // MARK: Missing and unreadable sources
        let lonely = install("lonely")
        let missingLine = C.automatic(.setup, dest: lonely, known: [work.appendingPathComponent("gone/HorizonXI")], env: env).line ?? ""
        checks.append(("no earlier install at all: said once, the marker says so, and never again",
                       missingLine.contains("no earlier install") && C.record(lonely.gameDir)?.state == .nothing
                           && C.automatic(.setup, dest: lonely, known: gameDirs([src]), env: env).line == nil))
        let locked = install("locked")
        played(locked, date: day, tag: "locked")
        let lockedUser = C.side(locked).user
        chmod(lockedUser.path, 0)
        unlockLater.append(lockedUser)
        let lc = C.survey(C.side(locked))
        checks.append(("an unreadable USER is a candidate with a problem, never chosen",
                       lc.problem?.contains("can't be read") == true && !lc.usable))
        checks.append(("... a readable one is chosen instead, even though the unreadable one may be newer",
                       C.choose(C.candidates(gameDirs([locked, src]), dest: C.side(install("x"))))?.side.root.path == src.gameDir.path))
        let waiting = install("waiting")
        let waitLine = C.automatic(.setup, dest: waiting, known: gameDirs([locked]), env: env).line ?? ""
        checks.append(("only an unreadable one: it waits (pending), nothing written but the marker",
                       waitLine.contains("waits") && C.isPending(waiting) && C.read(C.side(waiting).user).files.isEmpty))
        chmod(lockedUser.path, 0o755)
        let lateLine = C.automatic(.play, dest: waiting, known: [], env: env).line ?? ""
        checks.append(("readable again before the first Play: done then, from the folders Setup knew",
                       lateLine.hasPrefix("==> ") && C.record(waiting.gameDir)?.state == .done
                           && text(user(waiting, "1410b/mcr.dat")) == "locked 1410b/mcr.dat"))
        chmod(lockedUser.path, 0)
        let firstGone = install("first-gone")
        let fgLine = C.automatic(.setup, dest: firstGone, known: gameDirs([locked, src]), env: env).line ?? ""
        checks.append(("the install in use before Setup can't be read: Setup waits for it, though an older one could be read",
                       fgLine.contains("waits") && C.isPending(firstGone) && C.read(C.side(firstGone).user).files.isEmpty))
        let fgPlay = C.automatic(.play, dest: firstGone, known: [], env: env).line ?? ""
        checks.append(("... still unreadable at the first Play: the best readable one then",
                       fgPlay.hasPrefix("==> ") && C.record(firstGone.gameDir)?.from == src.gameDir.path))
        chmod(lockedUser.path, 0o755)
        let gameless = work.appendingPathComponent("gameless/HorizonXI")
        put(gameless.appendingPathComponent("Ashita-cli.exe"), "MZ")
        let glDest = install("gameless-dest")
        let glLine = C.automatic(.setup, dest: glDest, known: [gameless, src.gameDir], env: env).line ?? ""
        checks.append(("a client folder with no game in it is not waited for", glLine.hasPrefix("==> ")))
        let behindDrive = C.side(at: URL(fileURLWithPath: "/Volumes/ffxi-carryover-selftest-not-a-drive/HorizonXI"))
        let bd = behindDrive.map(C.survey)
        checks.append(("a client behind a drive that isn't connected: a candidate that says so",
                       bd?.problem?.contains("isn't connected") == true && bd?.usable == false))

        // MARK: Game running, lock, room
        let busy = install("busy")
        running = true
        let busyRun = C.automatic(.setup, dest: busy, known: gameDirs([src]), env: env)
        let busyLine = busyRun.line ?? ""
        running = false
        checks.append(("a game running: nothing copied, it waits for the first Play (which says so instead of starting)",
                       busyLine.contains("a game is running") && busyRun.waits == .game && C.isPending(busy)
                           && C.read(C.side(busy).user).files.isEmpty))
        let held = LaunchLock.acquire(at: lockFile)
        let heldRun = C.automatic(.play, dest: busy, known: [], env: env)
        if let h = held { LaunchLock.release(h) }
        checks.append(("the launch lock held elsewhere: it waits again",
                       (heldRun.line ?? "").contains("a launch is under way") && heldRun.waits == .launch && C.isPending(busy)))
        free = 10
        let fullLine = C.automatic(.play, dest: busy, known: [], env: env).line ?? ""
        free = 50_000_000_000
        checks.append(("no room: nothing changed, it waits, said as a failure",
                       fullLine.hasPrefix("!! ") && fullLine.contains("not enough space") && C.isPending(busy)
                           && C.read(C.side(busy).user).files.isEmpty && leftovers(busy.gameDir).isEmpty))
        let busyDone = C.automatic(.play, dest: busy, known: [], env: env).line ?? ""
        checks.append(("then nothing running and room: done", busyDone.hasPrefix("==> ") && C.record(busy.gameDir)?.state == .done))

        // MARK: Failures and changes between the plan and the copy
        let bad = install("bad-source")
        played(bad, date: day, tag: "bad")
        let badFile = user(bad, "1410b/es0.dat")
        chmod(badFile.path, 0)
        unlockLater.append(badFile)
        let fragile = install("fragile")
        put(user(fragile, "tig.dat"), "fragile title")
        let fragileBefore = snapshot(fragile.gameDir)
        let (fu, fc) = C.readDest(C.side(fragile))
        let bc = C.survey(C.side(bad))
        let fp = C.plan(from: bc, to: C.side(fragile), destUser: fu, destConfig: fc)
        var threw = false
        do { _ = try C.apply(fp, from: bc.side, to: C.side(fragile), env: env) } catch { threw = true }
        checks.append(("a file that can't be copied: nothing changed, no backup, no hidden copy left",
                       threw && snapshot(fragile.gameDir) == fragileBefore && leftovers(fragile.gameDir).isEmpty
                           && !fm.fileExists(atPath: C.side(fragile).user.path + ".bak-\(dayName)-carryover")))
        chmod(badFile.path, 0o644)
        let race = install("race")
        put(user(race, "tig.dat"), "shipped title")
        let (ru, rc) = C.readDest(C.side(race))
        let rp = C.plan(from: srcCand, to: C.side(race), destUser: ru, destConfig: rc)
        put(user(race, "tig.dat"), "written meanwhile")
        put(user(race, "99f/mcr.dat"), "appeared meanwhile")
        let ro = (try? C.apply(rp, from: srcCand.side, to: C.side(race), env: env)) ?? C.Outcome(failed: ["threw"])
        checks.append(("changed or appeared after the plan: left as it is, never written over",
                       ro.skipped == 2 && text(user(race, "tig.dat")) == "written meanwhile"
                           && text(user(race, "99f/mcr.dat")) == "appeared meanwhile" && text(user(race, "cmb0.dat")) == "old cmb0.dat"))
        // The same on a file system without RENAME_SWAP / RENAME_EXCL (HFS+, as x10 is).
        C.renameFlags = false
        let plain = install("plain-rename")
        put(user(plain, "tig.dat"), "shipped title")
        put(config(plain, "imgui.ini"), "shipped layout")
        let (plu, plc) = C.readDest(C.side(plain))
        let plp = C.plan(from: srcCand, to: C.side(plain), destUser: plu, destConfig: plc)
        put(user(plain, "99f/mcr.dat"), "appeared meanwhile")
        let plo = (try? C.apply(plp, from: srcCand.side, to: C.side(plain), env: env)) ?? C.Outcome(failed: ["threw"])
        C.renameFlags = true
        checks.append(("without the rename flags: added, replaced (backed up), and what appeared meanwhile kept",
                       plo.failed.isEmpty && plo.replaced == 2 && plo.skipped == 1 && text(user(plain, "tig.dat")) == "old tig.dat"
                           && text(user(plain, "99f/mcr.dat")) == "appeared meanwhile" && text(user(plain, "1410b/es0.dat")) == "old 1410b/es0.dat"
                           && text(URL(fileURLWithPath: C.side(plain).user.path + ".bak-\(dayName)-carryover/tig.dat")) == "shipped title"))
        let escape = install("escape")
        let elsewhere = work.appendingPathComponent("elsewhere")
        try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try? fm.createDirectory(at: C.side(escape).user, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: user(escape, "99f").path, withDestinationPath: elsewhere.path)
        let deep = install("deep-source")
        put(user(deep, "99f/mcr.dat"), "deep 99f")
        put(user(deep, "99f/deeper/es1.dat"), "deep es1")
        put(user(deep, "1410b/mcr.dat"), "deep 1410b")
        let deepCand = C.survey(C.side(deep))
        let (eu, ec) = C.readDest(C.side(escape))
        let ep = C.plan(from: deepCand, to: C.side(escape), destUser: eu, destConfig: ec)
        let eo = (try? C.apply(ep, from: deepCand.side, to: C.side(escape), env: env)) ?? C.Outcome(failed: ["threw"])
        checks.append(("nothing is written, and no folder made, through a link out of the destination",
                       eu.links == 1 && eo.skipped == 2 && eo.added >= 1 && text(user(escape, "1410b/mcr.dat")) == "deep 1410b"
                           && ((try? fm.contentsOfDirectory(atPath: elsewhere.path)) ?? ["?"]).isEmpty))
        let bak1 = C.backupFolder(beside: work.appendingPathComponent("b/USER").path, day: dayName)
        try? fm.createDirectory(atPath: bak1, withIntermediateDirectories: true)
        let bak2 = C.backupFolder(beside: work.appendingPathComponent("b/USER").path, day: dayName)
        checks.append(("a second backup the same day gets -2", bak1.hasSuffix("USER.bak-\(dayName)-carryover")
                           && bak2.hasSuffix("USER.bak-\(dayName)-carryover-2")))

        // MARK: Unreadable, ambiguous, cut short, prepared
        let walled = work.appendingPathComponent("walled")
        let walledClient = walled.appendingPathComponent("HorizonXI")
        put(walledClient.appendingPathComponent("Ashita-cli.exe"), "MZ")
        put(walledClient.appendingPathComponent("SquareEnix/FINAL FANTASY XI/USER/1410b/mcr.dat"), "walled", day)
        chmod(walled.path, 0)
        unlockLater.append(walled)
        let ws = C.side(at: walledClient)
        let wc = ws.map(C.survey)
        checks.append(("a client inside a folder that can't be read: a candidate that can't be read, not one that isn't there",
                       ws?.unreadable != nil && wc?.unreachable == true && wc?.usable == false
                           && C.read(walledClient.appendingPathComponent("SquareEnix/FINAL FANTASY XI/USER")).problem != nil))
        let walledDest = install("walled-dest")
        let wl = C.automatic(.setup, dest: walledDest, known: [walledClient, src.gameDir], env: env)
        checks.append(("... and when it is the install in use before Setup, Setup waits for it",
                       (wl.line ?? "").contains("waits") && C.isPending(walledDest)))
        chmod(walled.path, 0o755)
        let both = work.appendingPathComponent("both")
        for w in ["HorizonXI", "CatsEyeXI"] { put(both.appendingPathComponent("\(w)/Ashita-cli.exe"), "MZ") }
        checks.append(("a folder holding two clients names neither", C.side(at: both) == nil && C.clients(under: both) == 2))

        let cut = install("cut-short")
        for rel in ["1410b/mcr.dat", "tig.dat"] { put(user(cut, rel), "old \(rel)", old) }
        put(user(cut, "1410b/mcr1.dat"), "half-written by nobody: kept")
        C.write(C.Record(state: .applying, date: day, from: src.gameDir.path, hints: [src.gameDir.path]), cut.gameDir)
        let cutRun = C.automatic(.play, dest: cut, known: [], env: env)
        checks.append(("a copy cut short is finished at the next Play: only what is missing, nothing replaced, then done",
                       (cutRun.line ?? "").contains("finished a copy cut short") && C.record(cut.gameDir)?.state == .done
                           && text(user(cut, "1410b/mcr1.dat")) == "half-written by nobody: kept"
                           && text(user(cut, "1410b/es0.dat")) == "old 1410b/es0.dat" && text(user(cut, "99f/mcr.dat")) == "old 99f/mcr.dat"
                           && !fm.fileExists(atPath: C.side(cut).user.path + ".bak-\(dayName)-carryover")))

        let prepared = install("prepared")
        C.prepare(prepared, known: gameDirs([src]), now: day)
        let pr = C.record(prepared.gameDir)
        C.prepare(prepared, known: gameDirs([newer]), now: day)
        checks.append(("before the download: a pending marker with the folders Setup knows, added to, not replaced",
                       pr?.state == .pending && pr?.hints == [src.gameDir.path]
                           && C.record(prepared.gameDir)?.hints == [src.gameDir.path, newer.gameDir.path]))
        C.prepare(dest, known: gameDirs([newer]), now: day)
        checks.append(("... and never over a marker that says done", C.record(dest.gameDir)?.state == .done))
        let offline = Install(wrapper: URL(fileURLWithPath: "/Volumes/ffxi-carryover-selftest-not-a-drive/FFXI on Mac Wine.app"), prefixName: "prefix10")
        C.prepare(offline, known: [], now: day)
        checks.append(("... and never a folder made on a drive that isn't there",
                       !fm.fileExists(atPath: "/Volumes/ffxi-carryover-selftest-not-a-drive")))
        let preparedLine = C.automatic(.setup, dest: prepared, known: [], env: env).line ?? ""
        checks.append(("the download done after a relaunch (nothing in memory): the folders kept with the install are used",
                       preparedLine.hasPrefix("==> ") && C.record(prepared.gameDir)?.from == newer.gameDir.path))

        // MARK: Case
        func tree(_ files: [(String, Date)]) -> C.Tree { C.Tree(files: files.map { C.File(rel: $0.0, size: 1, modified: $0.1) }) }
        let clash = C.plan(user: tree([("1410B/mcr.dat", older), ("1410b/mcr.dat", day)]), config: C.Tree(),
                           destUser: C.Tree(), destConfig: C.Tree(), caseInsensitive: true) { _, _, _ in false }
        checks.append(("two names differing only in case, onto a case-insensitive drive: one copy, the newer",
                       clash.clashes == 1 && clash.items.count == 1 && clash.items[0].rel == "1410b/mcr.dat"))
        let sensitive = C.plan(user: tree([("1410B/mcr.dat", older), ("1410b/mcr.dat", day)]), config: C.Tree(),
                               destUser: C.Tree(), destConfig: C.Tree(), caseInsensitive: false) { _, _, _ in false }
        checks.append(("... onto a case-sensitive one: both", sensitive.clashes == 0 && sensitive.items.count == 2))
        let replaceCase = C.plan(user: tree([("tig.dat", day)]), config: tree([("IMGUI.INI", day)]), destUser: tree([("TIG.DAT", old)]),
                                 destConfig: tree([("imgui.ini", old)]), caseInsensitive: true) { _, _, _ in false }
        checks.append(("a replaced file keeps the name the destination has for it",
                       replaceCase.items.map(\.target).sorted() == ["TIG.DAT", "imgui.ini"] && replaceCase.replaced == 2))
        let mixed = C.plan(user: tree([("1410B/mcr.dat", older), ("1410b/mcr.dat", day)]), config: tree([("A.lua", day), ("a.lua", day)]),
                           destUser: C.Tree(), destConfig: C.Tree(), caseInsensitive: false, configCaseInsensitive: true) { _, _, _ in false }
        checks.append(("case is decided for each folder by its own drive (USER case-sensitive, config not)",
                       mixed.count(.user, replaces: false) == 2 && mixed.count(.config, replaces: false) == 1 && mixed.clashes == 1))

        // MARK: The marker
        let r = C.Record(state: .pending, date: day, hints: ["/a", "/b"], why: "a game is running")
        let mroot = work.appendingPathComponent("marker")
        try? fm.createDirectory(at: mroot, withIntermediateDirectories: true)
        checks.append(("the marker reads back as written", C.write(r, mroot) && C.record(mroot) == r))

        // MARK: Exemptions
        checks.append(("--carryover-report and --carryover-apply never reach a running launcher's window",
                       SingleInstance.isExempt(["x", "--carryover-report"]) && SingleInstance.isExempt(["x", "--carryover-apply"])
                           && SingleInstance.isExempt(["x", "--selftest-carryover"])))

        // MARK: Daniel's old USER folder, copied
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HXI_CARRYOVER_FIXTURE"]
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/FFXI-on-Mac-build/fixture/old-USER/USER").path)
        var realRun = false
        if fm.fileExists(atPath: fixture.path) {
            realRun = true
            let real = install("real-old")
            try? fm.copyItem(at: fixture, to: C.side(real).user)
            let realNew = install("real-new")
            let t0 = Date()
            let rl = C.automatic(.setup, dest: realNew, known: gameDirs([real]), env: env).line ?? ""
            let took = Date().timeIntervalSince(t0)
            let a = C.read(C.side(real).user), b = C.read(C.side(realNew).user)
            print("  real USER: \(a.files.count) files, \(a.characters().count) characters, \(a.bytes) bytes; carried in \(Int(took * 1000)) ms")
            // copyfile keeps dates to the microsecond.
            let listed = a.files.count == b.files.count && zip(a.files, b.files).allSatisfy {
                $0.rel == $1.rel && $0.size == $1.size && abs($0.modified.timeIntervalSince($1.modified)) < 1e-5
            }
            checks.append(("the real USER folder: every file, byte for byte and dated as it was",
                           rl.hasPrefix("==> ") && a.files.count > 0 && listed
                               && a.files.allSatisfy { fm.contentsEqual(atPath: C.side(real).user.appendingPathComponent($0.rel).path,
                                                                        andPath: C.side(realNew).user.appendingPathComponent($0.rel).path) }))
        } else {
            print("  real USER: skipped, nothing at \(fixture.path)")
        }

        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        if !realRun { print("  (real USER check not run)") }
        for u in unlockLater { chmod(u.path, 0o755) }
        // exit() runs no defer: clean up here.
        try? fm.removeItem(at: work)
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `--carryover-report [--world <name>]` and `--carryover-apply --from <folder> --to <folder>`.
extension Headless {
    private static func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1e6) }

    private static func describe(_ t: CarryOver.Tree, characters: Bool) -> String {
        if let p = t.problem { return "can't be read: \(p)" }
        return (characters ? "\(t.characters().count) characters, " : "") + "\(t.files.count) files, \(mb(t.bytes))"
            + (t.links > 0 ? ", \(t.links) links (skipped)" : "")
    }

    private static func describe(_ p: CarryOver.Plan) -> [String] {
        typealias A = CarryOver.Area
        let mode: String
        switch p.mode {
        case .fresh: mode = "into a fresh install"
        case .played: mode = "into an install a character has played in: only what is missing"
        case .finishing: mode = "finishing a copy cut short: only what is missing"
        }
        var out = [mode + ":"]
        for a in A.allCases {
            out.append("  \(a.rawValue): add \(p.count(a, replaces: false)), replace \(p.count(a, replaces: true)), \(mb(p.bytes(a)))")
        }
        out.append("  already the same \(p.same), left as they are \(p.kept)"
                   + (p.clashes > 0 ? ", \(p.clashes) names differing only in case (the older not copied)" : ""))
        out.append("  characters added \(p.charactersAdded.count)" + (p.charactersKept.isEmpty ? "" : ", kept as they are \(p.charactersKept.count)"))
        if p.replaced > 0 { out.append("  each replaced file is copied first to <USER|config>.bak-<date>-carryover beside it") }
        return out
    }

    /// The installs a carry-over into the install in use would look at: the folders Setup left
    /// in a pending marker, then what Setup would look at now (CarryOver.knownRoots, with a scan).
    @MainActor private static func carryOverRoots(_ base: Install, record: CarryOver.Record?) -> [URL] {
        let horizon = ServerStore().servers.first { $0.name == "HorizonXI" }
        return (record?.hints ?? []).map { URL(fileURLWithPath: $0) }
            + CarryOver.knownRoots(base: base, horizon: horizon, installs: Install.dedupe(Install.discover()))
    }

    /// Read-only: what a carry-over into the install in use (or `--to <folder>`) would copy, from
    /// where (the folders Setup would look at, or only each `--from <folder>`), and whether it
    /// will run by itself. Lists, sizes and dates only; no file's contents, no boot profile.
    /// Safe while a game is playing (it reads, and compares a few files' bytes).
    @MainActor static func runCarryOverReport(_ args: [String]) -> Never {
        func fail(_ s: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data((s + "\n").utf8))
            exit(code)
        }
        let usage = "usage: --carryover-report [--world <name>] [--to <folder>] [--from <folder>]..."
        func values(_ flag: String) -> [URL] {
            args.indices.filter { args[$0] == flag }.map { at -> URL in
                guard at + 1 < args.count, !args[at + 1].hasPrefix("--") else { fail(usage, 64) }
                return URL(fileURLWithPath: (args[at + 1] as NSString).expandingTildeInPath)
            }
        }
        let store = ServerStore()
        var chosen = store.servers.first { $0.name == "HorizonXI" } ?? store.selected
        if let w = args.firstIndex(of: "--world") {
            guard w + 1 < args.count else { fail(usage, 64) }
            let name = args[w + 1]
            chosen = store.servers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if chosen == nil { fail("no world named \(name)", 64) }
        }
        guard let server = chosen else { fail("no world", 64) }
        let only = values("--from")
        let dest: CarryOver.Side
        var base: Install? = nil
        if let to = values("--to").first {
            guard let s = CarryOver.side(at: to), s.config != nil, s.unreadable == nil else {
                let n = CarryOver.clients(under: to)
                fail(n > 1 ? "\(to.path) holds \(n) clients: name the one meant" : "no readable client (Ashita and SquareEnix) at \(to.path)", 2)
            }
            dest = s
        } else {
            guard let b = InstallSelection.inUse() else { fail("the install in use isn't on disk", 2) }
            base = b
            dest = CarryOver.side(b.forServer(server))
        }
        let rec = CarryOver.record(dest.root)
        let (du, dc) = CarryOver.readDest(dest)
        let iso = ISO8601DateFormatter()
        print("world: \(server.name)")
        print("destination: \(dest.root.path)")
        print("  USER: \(describe(du, characters: true))")
        print("  config (the part carried): \(describe(dc, characters: false))")
        print("  " + (du.characters().isEmpty ? "fresh: no character has played here" : "a character has played here"))
        print("  marker: " + (rec.map { "\($0.state.rawValue), \(iso.string(from: $0.date))" + ($0.from.map { " from \($0)" } ?? "")
                                  + ($0.why.map { " (\($0))" } ?? "") } ?? "none"))
        print("a game is running now: \(CarryOver.Environment.live.gameRunning() ? "yes" : "no")")
        guard server.name == "HorizonXI" || server.local || !only.isEmpty else {
            print("candidates: by itself, the carry-over covers HorizonXI's client only. By hand: --carryover-apply --from <client folder> --to \(dest.root.path)")
            exit(0)
        }
        let roots = !only.isEmpty ? only : base.map { carryOverRoots($0, record: rec) } ?? (rec?.hints ?? []).map { URL(fileURLWithPath: $0) }
        let found = CarryOver.candidates(roots, dest: dest)
        let best = CarryOver.choose(found)
        print("candidates:")
        if found.isEmpty { print("  none") }
        for c in found {
            let newest = c.user.newest.map { ", newest \(iso.string(from: $0))" } ?? ""
            print("  \(c.side.root.path): USER \(describe(c.user, characters: true))\(newest); config \(describe(c.config, characters: false))"
                  + (c == best ? "  <- would be used" : ""))
        }
        if let b = best {
            for l in describe(CarryOver.plan(from: b, to: dest, destUser: du, destConfig: dc)) { print(l) }
        }
        let auto: String
        switch rec?.state {
        case .pending?: auto = "before this install's next Play (pending)"
        case .applying?: auto = "before this install's next Play: a copy was cut short, what is missing is added"
        case .done?, .skipped?, .nothing?: auto = "never again (marker: \(rec!.state.rawValue))"
        case nil: auto = du.characters().isEmpty ? "only after Setup downloads a client here" : "no: a character has played here"
        }
        print("by itself: \(auto)")
        exit(0)
    }

    /// By hand, for support: the same copy from one client to another, with the same rules
    /// (nothing while a game runs or a launch is under way; into a played install only what is
    /// missing; backups; never a boot profile). `--from`/`--to`: a wrapper .app, the "FFXI on
    /// Mac" folder, a client folder, or (`--from` only, USER alone) a SquareEnix folder.
    /// Exit: 0 copied (or nothing to copy), 1 refused, 2 not found, 64 usage, 70 failed.
    @MainActor static func runCarryOverApply(_ args: [String]) -> Never {
        func fail(_ s: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data((s + "\n").utf8))
            exit(code)
        }
        let usage = "usage: --carryover-apply --from <wrapper, client or SquareEnix folder> --to <wrapper or client folder>"
        func value(_ flag: String) -> URL {
            guard let at = args.firstIndex(of: flag), at + 1 < args.count, !args[at + 1].hasPrefix("--") else { fail(usage, 64) }
            return URL(fileURLWithPath: (args[at + 1] as NSString).expandingTildeInPath)
        }
        let (fromURL, toURL) = (value("--from"), value("--to"))
        func notFound(_ u: URL) -> Never {
            let n = CarryOver.clients(under: u)
            fail(n > 1 ? "\(u.path) holds \(n) clients: name the one meant" : "no client found at \(u.path)", 2)
        }
        guard let from = CarryOver.side(at: fromURL) else { notFound(fromURL) }
        guard let to = CarryOver.side(at: toURL) else { notFound(toURL) }
        if let why = to.unreadable { fail("\(to.root.path) can't be read: \(why)", 1) }
        guard to.config != nil else { fail("\(to.root.path) is a SquareEnix folder: name the client (Ashita) folder", 2) }
        guard let destID = CarryOver.identity(to) else { fail("\(to.root.path) has no FINAL FANTASY XI folder", 2) }
        let env = CarryOver.Environment.live
        // Never released by hand: exit() closes the fd, and with it the flock.
        guard env.lock() != nil else { fail("a launch, Repair or Stop is under way: nothing copied", 1) }
        guard !env.gameRunning() else { fail("a game is running: nothing copied", 1) }
        let c = CarryOver.survey(from)
        guard c.identity != destID else { fail("--from and --to are the same client", 1) }
        if let p = c.problem { fail("\(from.root.path) can't be read: \(p)", 1) }
        let (du, dc) = CarryOver.readDest(to)
        if let p = du.problem ?? dc.problem { fail("\(to.root.path) can't be read: \(p)", 1) }
        print("from: \(from.root.path) (USER \(describe(c.user, characters: true)))")
        print("to:   \(to.root.path) (USER \(describe(du, characters: true)))")
        let plan = CarryOver.plan(from: c, to: to, destUser: du, destConfig: dc)
        for l in describe(plan) { print(l) }
        guard !plan.items.isEmpty else { print("nothing to copy"); exit(0) }
        do {
            let o = try CarryOver.apply(plan, from: from, to: to, env: env)
            print(CarryOver.summary(o, plan: plan, from: from))
            CarryOver.write(CarryOver.Record(state: .done, date: env.now(), from: from.root.path, files: o.added + o.replaced,
                                             replaced: o.replaced, bytes: o.bytes, why: "by hand (--carryover-apply)"), to.root)
            exit(o.failed.isEmpty ? 0 : 70)
        } catch {
            fail("nothing was changed: \((error as? CarryOver.Refusal)?.line ?? error.localizedDescription)", 70)
        }
    }
}
