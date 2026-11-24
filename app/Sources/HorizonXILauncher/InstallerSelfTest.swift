// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// `--selftest-installer`: a world's own Windows installer, issue #92 (Eden's installer writes
/// `C:\Eden` whatever it is told; "Run installer…" then never found the client).
///
/// - InstallerClient on fixture folders: which folder an installer run left is the world's client
///   (the world's folder first, then one named for the world, then the newest since the run; never a
///   link to another world's folder, never `C:\windows`); bringing it into the world's folder
///   (renames, then a link back), and every case that must leave it where it is.
/// - bsdtar listings and free-space arithmetic for the button's figure.
/// - A world added by hand: kept when it is named like a world this project retired, and filled in
///   from that world's research without replacing anything typed.
/// - The button: an installer's percentage, its gigabytes when the total is unknown, and the
///   step's name in Setup's chain.
/// - `Runner.linkGamesFolder` never deletes a real folder.
///
/// Writes only under a fresh folder in the temporary directory, removed at the end.
///
/// `--selftest-installer-live <installer .exe|.zip> <world> <world folder> <wrapper .app>` runs the
/// real job (Runner.runLocalInstaller: the installers' prefix, the installer under Wine, the
/// client brought into the world folder) on that wrapper, printing the button's figure as it
/// changes and the outcome. It changes no setting and touches no other prefix. For testing on a
/// spare wrapper only.
extension Headless {
    @MainActor static func runInstallerSelfTest() -> Never {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { results.append((name, ok)) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ffxi-installer-selftest-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: root)
        defer { try? fm.removeItem(at: root) }
        func touch(_ u: URL) {
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data("x".utf8))
        }
        func edenClient(at dir: URL) {
            touch(dir.appendingPathComponent("Ashita/Ashita.exe"))
            touch(dir.appendingPathComponent("Ashita/injector.exe"))
            touch(dir.appendingPathComponent("Ashita/ffxi-bootmod/xiloader.exe"))
            touch(dir.appendingPathComponent("SquareEnix/FINAL FANTASY XI/FFXiMain.dll"))
            touch(dir.appendingPathComponent("SquareEnix/PlayOnlineViewer/viewer/com/polcore.dll"))
            touch(dir.appendingPathComponent("Uninstall.exe"))
        }
        // The temporary folder is /var/…, which listings give back as /private/var/….
        func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }
        func old(_ u: URL, _ secondsAgo: Double) {
            let d = Date().addingTimeInterval(-secondsAgo)
            for p in [u, u.appendingPathComponent("Ashita"), u.appendingPathComponent("SquareEnix")] where fm.fileExists(atPath: p.path) {
                try? fm.setAttributes([.modificationDate: d], ofItemAtPath: p.path)
            }
        }

        // MARK: which folder is the client
        let driveC = root.appendingPathComponent("prefix-installers/drive_c", isDirectory: true)
        let data = root.appendingPathComponent("FFXI on Mac/Games/eden", isDirectory: true)
        let other = root.appendingPathComponent("FFXI on Mac/Games/FFEra", isDirectory: true)
        try? fm.createDirectory(at: data, withIntermediateDirectories: true)
        try? fm.createDirectory(at: driveC.appendingPathComponent("Games"), withIntermediateDirectories: true)
        touch(driveC.appendingPathComponent("windows/system32/Ashita-cli.exe"))   // never a client
        edenClient(at: other)
        try? fm.createSymbolicLink(at: driveC.appendingPathComponent("Games/FFEra"), withDestinationURL: other)
        try? fm.createSymbolicLink(at: driveC.appendingPathComponent("Games/eden"), withDestinationURL: data)
        // What the reporter's pane showed: the world's folder empty, apart from its downloads.
        touch(data.appendingPathComponent("installer-downloads/Eden535-unpacked/Installer.exe"))
        touch(data.appendingPathComponent("installer-downloads/Eden535-unpacked/Ashita/injector.exe"))
        check("an installer's own unpacked copy is not the client", !InstallerClient.holdsClient(data))
        check("nothing installed yet: nothing found",
              InstallerClient.find(driveC: driveC, world: "eden", dataPath: data, since: Date()) == nil)
        check("C:\\windows and links to other worlds' folders are never candidates",
              InstallerClient.candidates(driveC: driveC).isEmpty)

        let eden = driveC.appendingPathComponent("Eden", isDirectory: true)
        edenClient(at: eden)
        check("Eden's C:\\Eden holds a client (Ashita v3 injector.exe)", InstallerClient.holdsClient(eden))
        check("found by name, before any install (\"eden\" is C:\\Eden)",
              same(InstallerClient.find(driveC: driveC, world: "eden", dataPath: data, since: nil), eden))
        check("\"Eden XI\" and \"EDEN\" are the same name", InstallerClient.named(eden, world: "Eden XI") && InstallerClient.named(eden, world: "EDEN"))
        check("another world's name finds nothing before an install",
              InstallerClient.find(driveC: driveC, world: "Valhalla", dataPath: nil, since: nil) == nil)
        old(eden, 3600)
        check("after a run: an unnamed folder counts only when it changed since the run",
              InstallerClient.find(driveC: driveC, world: "Valhalla", dataPath: nil, since: Date()) == nil
              && same(InstallerClient.find(driveC: driveC, world: "Valhalla", dataPath: nil, since: Date().addingTimeInterval(-7200)), eden))
        let pf = driveC.appendingPathComponent("Program Files (x86)/Some World", isDirectory: true)
        touch(pf.appendingPathComponent("Ashita-cli.exe"))
        check("Program Files counts too, newest first",
              same(InstallerClient.find(driveC: driveC, world: "Valhalla", dataPath: nil, since: Date().addingTimeInterval(-60)), pf))
        try? fm.removeItem(at: driveC.appendingPathComponent("Program Files (x86)"))

        // MARK: bringing it into the world's folder
        var log: [String] = []
        let now = InstallerClient.adopt(eden, into: data) { log.append($0) }
        let link = (try? fm.destinationOfSymbolicLink(atPath: eden.path)).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        check("adopted into the world's folder: \(now.path)", now.path == data.path)
        check("its files are there, the downloads untouched",
              fm.fileExists(atPath: data.appendingPathComponent("Ashita/injector.exe").path)
              && fm.fileExists(atPath: data.appendingPathComponent("SquareEnix/PlayOnlineViewer/viewer/com/polcore.dll").path)
              && fm.fileExists(atPath: data.appendingPathComponent("installer-downloads/Eden535-unpacked/Installer.exe").path))
        check("C:\\Eden is now a link to it (\(link ?? "none"))", link == data.resolvingSymlinksInPath().path)
        check("the world's folder now holds the client, and is what is found",
              InstallerClient.holdsClient(data) && same(InstallerClient.find(driveC: driveC, world: "eden", dataPath: data, since: nil), data))
        check("the link is no longer a candidate", InstallerClient.candidates(driveC: driveC).isEmpty)
        check("it says what it moved", log.contains { $0.contains("moved the client") })
        check("adopting into itself changes nothing", InstallerClient.adopt(data, into: data) { _ in }.path == data.path)

        let moved = root.appendingPathComponent("Elsewhere/eden", isDirectory: true)
        try? fm.createDirectory(at: moved, withIntermediateDirectories: true)
        InstallerClient.repointLinks(driveC: driveC, world: "eden", to: moved)
        check("a re-run after the world's folder moved writes to the new folder",
              same(URL(fileURLWithPath: (try? fm.destinationOfSymbolicLink(atPath: eden.path)) ?? ""), moved))
        InstallerClient.repointLinks(driveC: driveC, world: "eden", to: data)
        check("and back", same(URL(fileURLWithPath: (try? fm.destinationOfSymbolicLink(atPath: eden.path)) ?? ""), data))

        let second = driveC.appendingPathComponent("Eden2", isDirectory: true)
        edenClient(at: second)
        log = []
        check("a name already in the world's folder: left where it is",
              InstallerClient.adopt(second, into: data) { log.append($0) }.path == second.path
              && fm.fileExists(atPath: second.appendingPathComponent("Ashita/injector.exe").path)
              && log.contains { $0.contains("already has") })
        let nested = second.appendingPathComponent("inner", isDirectory: true)
        check("never into a folder inside itself", InstallerClient.adopt(second, into: nested) { _ in }.path == second.path)

        // MARK: sizes and the meter
        let listing = """
        -rw-r--r--  0 0      0     1000 Apr  5  2023 SquareEnix/FINAL FANTASY XI/FFXiMain.dll
        drwxr-xr-x  0 0      0        0 Apr  5  2023 Ashita/
        -rw-r--r--  0 0      0      234 Apr  5  2023 Ashita/My Addons/a file.lua
        """
        check("a bsdtar listing sums its files, not its folders", InstallerClient.listedBytes(listing) == 1234)
        check("an empty listing is unknown, not zero", InstallerClient.listedBytes("") == nil)
        let zdir = root.appendingPathComponent("zipsrc", isDirectory: true)
        try? fm.createDirectory(at: zdir, withIntermediateDirectories: true)
        fm.createFile(atPath: zdir.appendingPathComponent("a.bin").path, contents: Data(repeating: 7, count: 300_000))
        fm.createFile(atPath: zdir.appendingPathComponent("b.bin").path, contents: Data(repeating: 9, count: 12_345))
        let zip = root.appendingPathComponent("payload.zip")
        let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); z.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", zdir.path, zip.path]
        try? z.run(); z.waitUntilExit()
        check("a zip's unpacked size from its own listing", InstallerClient.archiveBytes(zip) == 312_345)
        let exeDir = root.appendingPathComponent("unpacked", isDirectory: true)
        touch(exeDir.appendingPathComponent("Installer.exe"))
        check("no archive beside the installer: total unknown", InstallerClient.payloadBytes(beside: exeDir.appendingPathComponent("Installer.exe")) == nil)
        try? fm.copyItem(at: zip, to: exeDir.appendingPathComponent("data.7z"))
        check("an archive beside the installer is its payload",
              InstallerClient.payloadBytes(beside: exeDir.appendingPathComponent("Installer.exe")) == 312_345)
        check("written = free space that went", InstallerClient.written(since: ["/": 100, "/V": 50], now: ["/": 40, "/V": 50]) == 60)
        check("space that came back counts as nothing", InstallerClient.written(since: ["/": 100], now: ["/": 140]) == 0)
        check("free space is read per volume", (InstallerClient.freeBytes([root, root.appendingPathComponent("not/yet/made")]).count) == 1)
        check("a need beyond any disk is a shortfall", InstallerClient.shortfall(need: Int64.max, at: [root]) != nil
              && InstallerClient.shortfall(need: 1, at: [root]) == nil)

        // MARK: a world added by hand
        var added = Server(name: "eden", host: "", bootProfile: "horizonxi.ini", verified: false, note: Server.addedNote)
        added.fillFromCatalogue()
        check("\"eden\" is Eden's research", Server.catalogued(for: "eden")?.name == "Eden")
        check("its blank host is Eden's", added.host == "play.edenxi.com")
        check("Setup opens Eden's install page, then asks for the installer",
              added.installKind == .website && added.installURL == "https://edenxi.com/install")
        check("its account is made in the loader window", added.accountHow.contains("loader window"))
        var typed = Server(name: "Eden", host: "my.host", bootProfile: "x.ini", verified: false, note: Server.addedNote,
                           installURL: "https://example.invalid/", accountHow: "mine")
        typed.fillFromCatalogue()
        check("nothing typed is replaced", typed.host == "my.host" && typed.installURL == "https://example.invalid/" && typed.accountHow == "mine")
        var builtinLike = Server(name: "Eden", host: "", bootProfile: "eden.ini", verified: false, note: "Login host from Eden's own new-player wiki.")
        builtinLike.fillFromCatalogue()
        check("only a world added by hand is filled in", builtinLike.host.isEmpty)
        let merged = ServerStore.merge(saved: [
            Server(name: "Eden", host: "play.edenxi.com", bootProfile: "eden.ini", verified: false, note: Server.addedNote),
            Server(name: "FFEra", host: "ffera.com", bootProfile: "ffera.ini", verified: false, note: "Login host from FFEra's own wiki."),
        ])
        check("a world added as \"Eden\" survives a relaunch; the retired catalogue entry does not",
              merged.contains { $0.name == "Eden" && $0.addedByUser } && !merged.contains { $0.name == "FFEra" })
        check("Eden's download is the file its site links today (Eden535)",
              Server.all.first { $0.name == "Eden" }?.installURL.contains("1kLPVfruGCzXkkT2XQ-pmiSh4akHMLjo2") == true)
        check("Eden is still not offered in the picker", !Server.builtins.contains { $0.name == "Eden" })

        // MARK: the button
        var x = PrimaryInputs()
        x.world = "eden"; x.ownJob = "Installing eden"; x.ownProgress = 0.42
        check("an installer with a known size: \(Primary.decide(x).label)", Primary.decide(x).label == "Setting up… 42%" && Primary.decide(x).progress == 0.42)
        x.ownProgress = nil; x.ownWritten = 3_240_000_000
        check("unknown size: it counts gigabytes: \(Primary.decide(x).label)", Primary.decide(x).label == "Setting up… 3.2 GB")
        x.ownWritten = 50_000_000
        check("under 0.1 GB: no figure", Primary.decide(x).label == "Setting up…")
        var y = PrimaryInputs()
        y.setupRunning = true; y.setupStage = .installingGame; y.setupProgress = 0.63
        check("in Setup's chain it names the step: \(Primary.decide(y).label)", Primary.decide(y).label == "Installing the game… 63%")

        // MARK: C:\Games\<world>
        let wrapper = root.appendingPathComponent("Test Wine.app", isDirectory: true)
        let gi = Install(wrapper: wrapper, prefixName: "prefix10")
        let real = gi.driveC.appendingPathComponent("Games/Real", isDirectory: true)
        touch(real.appendingPathComponent("Ashita/injector.exe"))
        Runner.linkGamesFolder("Real", to: data.path, in: gi)
        check("a real folder at C:\\Games\\<world> is never deleted", fm.fileExists(atPath: real.appendingPathComponent("Ashita/injector.exe").path))
        Runner.linkGamesFolder("Linked", to: other.path, in: gi)
        Runner.linkGamesFolder("Linked", to: data.path, in: gi)
        check("a link there is replaced",
              (try? fm.destinationOfSymbolicLink(atPath: gi.driveC.appendingPathComponent("Games/Linked").path)) == data.path)
        check("the installers' prefix is never offered as an install",
              !Install.installs(inWrapper: wrapper).contains { $0.prefixName == Install.installerPrefixName })

        var failed = 0
        for (name, ok) in results {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failed += 1 }
        }
        print("\(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 1)
    }

    /// `--selftest-installer-live <installer> <world> <world folder> <wrapper .app>`: see above.
    @MainActor static func runInstallerLive() -> Never {
        let a = CommandLine.arguments
        guard let k = a.firstIndex(of: "--selftest-installer-live"), k + 4 < a.count else {
            FileHandle.standardError.write(Data("usage: --selftest-installer-live <installer .exe|.zip> <world> <world folder> <wrapper .app>\n".utf8))
            exit(2)
        }
        let file = URL(fileURLWithPath: a[k + 1]), world = a[k + 2], data = a[k + 3]
        let wrapper = URL(fileURLWithPath: a[k + 4])
        guard FileManager.default.isExecutableFile(atPath: wrapper.appendingPathComponent("Contents/SharedSupport/wine/bin/wine").path) else {
            FileHandle.standardError.write(Data("no wine in \(wrapper.path)\n".utf8)); exit(2)
        }
        let install = Install(wrapper: wrapper, prefixName: "prefix10")
        let runner = Runner(session: "installer self-test")
        let started = Date()
        var outcome: Runner.InstallerOutcome?
        var last = ""
        func stamp() -> String { String(format: "%6.1fs", Date().timeIntervalSince(started)) }
        runner.runLocalInstaller(file, in: install, dataPath: data, name: world) { outcome = $0 }
        while outcome == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            var x = PrimaryInputs()
            x.world = world
            if runner.busy { x.ownJob = runner.busyReason }
            x.ownProgress = runner.installerProgress
            x.ownWritten = runner.installerWritten
            let now = runner.busy ? Primary.decide(x).label : "(not busy)"
            if now != last { print("\(stamp())  button: \(now)"); last = now }
        }
        print("\(stamp())  outcome: \(String(describing: outcome!))")
        if case .installed(let at) = outcome! {
            let ok = InstallerClient.holdsClient(at)
            print("client in \(at.path): \(ok ? "yes" : "NO")")
            exit(ok ? 0 : 1)
        }
        exit(1)
    }
}
