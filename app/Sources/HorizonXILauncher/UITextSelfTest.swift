import Foundation

/// `--selftest-ui-text`: what the window says, headless. A drive that is not there (unplugged,
/// or ghost-mounted: listed by `mount`, absent on disk) is named whether the path lives on it or
/// reaches it through a symlink; the footer's one line and its order; that only "!!" lines reach
/// the log strip; the quit question. Files go to a temporary folder, deleted afterwards. The real
/// install is only read, and only reported.
extension Headless {
    @MainActor static func runUITextSelfTest() -> Never {
        let fm = FileManager.default
        var checks: [(String, Bool)] = []
        let tmp = fm.temporaryDirectory.appendingPathComponent("ffxi-uitext-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let gone = "NoSuchDrive-\(UUID().uuidString.prefix(8))"

        // Drive detection.
        let link = tmp.appendingPathComponent("SquareEnix")
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/\(gone)/FFXI/SquareEnix")
        checks.append(("a symlink into a missing /Volumes drive names that drive",
                       Preflight.unavailableDrive(for: link.appendingPathComponent("FINAL FANTASY XI").path) == gone))
        let chained = tmp.appendingPathComponent("chained")
        try? fm.createSymbolicLink(atPath: chained.path, withDestinationPath: "SquareEnix")
        checks.append(("a relative symlink to that symlink names it too",
                       Preflight.unavailableDrive(for: chained.appendingPathComponent("x").path) == gone))
        checks.append(("a plain path under a missing /Volumes drive names it",
                       Preflight.unavailableDrive(for: "/Volumes/\(gone)/FFXI/CatsEyeXI") == gone))
        checks.append(("an existing folder, and a missing file in one, name no drive",
                       Preflight.unavailableDrive(for: tmp.path) == nil
                           && Preflight.unavailableDrive(for: tmp.appendingPathComponent("nope/deeper").path) == nil))
        let toTmp = tmp.appendingPathComponent("toTmp")
        try? fm.createSymbolicLink(atPath: toTmp.path, withDestinationPath: "/tmp")
        checks.append(("a symlink to a folder that exists names no drive",
                       Preflight.unavailableDrive(for: toTmp.appendingPathComponent("x").path) == nil))
        let a = tmp.appendingPathComponent("loopA"), b = tmp.appendingPathComponent("loopB")
        try? fm.createSymbolicLink(atPath: a.path, withDestinationPath: b.path)
        try? fm.createSymbolicLink(atPath: b.path, withDestinationPath: a.path)
        checks.append(("a symlink loop ends (no drive, no hang)", Preflight.unavailableDrive(for: a.path) == nil))
        checks.append(("a different drive answering at /Volumes/<name> (other case) counts as that drive missing",
                       Preflight.isImpostor(volume: "/Volumes/Games", mountPoint: "/Volumes/GAMES")
                           && !Preflight.isImpostor(volume: "/Volumes/Games", mountPoint: "/Volumes/Games")
                           && !Preflight.isImpostor(volume: "/Volumes/Macintosh HD", mountPoint: "/")
                           && !Preflight.isImpostor(volume: "/Volumes/x", mountPoint: nil)))
        checks.append(("the boot volume's mount point is /", Preflight.mountPoint(of: "/") == "/"))
        checks.append(("the root volume is always there", Preflight.unavailableDrive(for: "/Volumes/Macintosh HD/Users") == nil
                           || !fm.fileExists(atPath: "/Volumes/Macintosh HD")))

        // Preflight on a fake wrapper whose SquareEnix links to the missing drive.
        let wrapper = tmp.appendingPathComponent("fake.app")
        let fake = Install(wrapper: wrapper, prefixName: "prefix")
        try? fm.createDirectory(at: fake.gameDir, withIntermediateDirectories: true)
        fm.createFile(atPath: fake.gameDir.appendingPathComponent("Ashita-cli.exe").path, contents: Data())
        try? fm.createSymbolicLink(atPath: fake.gameDir.appendingPathComponent("SquareEnix").path,
                                   withDestinationPath: "/Volumes/\(gone)/FFXI/SquareEnix")
        let pre = Preflight.run(fake)
        let se = pre.first { $0.id == "squareenix" }
        checks.append(("Preflight: the data check fails naming the drive",
                       se?.state == .bad && se?.drive == gone && se?.footer == Preflight.driveMessage(gone)))
        checks.append(("the drive line says reconnect it or press Setup, never restart",
                       Preflight.driveMessage(gone) == "The '\(gone)' drive isn't connected — reconnect it or press Setup."))
        checks.append(("Preflight: a file simply missing on a present drive names no drive",
                       pre.first { $0.id == "wine" }.map { $0.state == .bad && $0.drive == nil } == true))

        // The line under the main button (Primary.decide replaced PlayStatus.footer in b60).
        let ok = [Check(id: "wine", title: "Wine binary", state: .ok, detail: "")]
        func reason(installed install: Bool = true, scanning: Bool = false, busy: String? = nil, starting: Bool = false,
                    hasGame: Bool = true, _ c: [Check]) -> String? {
            var x = PrimaryInputs()
            x.world = "CatsEyeXI"; x.hasInstall = install; x.scanning = scanning; x.ownJob = busy
            x.starting = starting; x.hasGame = hasGame; x.checks = c
            return Primary.decide(x).reason
        }
        let wine = [Check(id: "wine", title: "Wine binary", state: .bad, detail: "missing /x", short: "Wine isn't installed yet.")]
        let plain = [Check(id: "x", title: "Something", state: .bad, detail: "long detail")]
        checks.append(("reason: nothing when ready", reason(ok) == nil))
        checks.append(("reason: nothing while a job runs or the game starts (the button says it)",
                       reason(busy: "Updating Wine", wine) == nil && reason(starting: true, ok) == nil
                           && reason(installed: false, scanning: true, ok) == nil))
        checks.append(("reason: no 'ready to play', 'game running' or 'setup incomplete' anywhere",
                       ![reason(ok), reason(starting: true, ok), reason(plain)].contains {
                           ["ready to play", "game running", "setup incomplete"].contains($0 ?? "") }))
        checks.append(("reason: nothing installed", reason(installed: false, ok) == "CatsEyeXI isn't installed yet."))
        let none = [Check(id: "client", title: "Game folder", state: .bad, detail: ""),
                    Check(id: "squareenix", title: "FINAL FANTASY XI data", state: .bad, detail: "")]
        checks.append(("reason: not installed", reason(hasGame: false, none) == "CatsEyeXI isn't installed yet."))
        checks.append(("reason: Wine missing", reason(wine) == "Wine isn't installed yet."))
        checks.append(("reason: an unknown failing check gives its title", reason(plain) == "Something"))
        checks.append(("reason: the missing drive, ahead of an earlier failing check",
                       reason(pre) == Preflight.driveMessage(gone)))
        checks.append(("reason: every line is one sentence, no line break, no menu to dig in",
                       [reason(wine), reason(plain), reason(pre), se?.footer]
                           .allSatisfy { ($0 ?? "").count <= 90 && !($0 ?? "").contains("\n")
                                         && !($0 ?? "").contains("Setup & Diagnostics") }))

        // Log strip: errors only.
        checks.append(("strip: only '!!' lines of a chunk", Runner.errorLines(in:
            "==> launching\nwarn: ConvertFormat: Unknown format\n!! x87 acceleration didn't attach\n  !! indented\n[mvk-warn] x\n")
            == "!! x87 acceleration didn't attach\n!! indented\n"))
        checks.append(("strip: a chunk with no errors adds nothing",
                       Runner.errorLines(in: "Successfully logged in as someone!\n==> game exited\n").isEmpty))

        // Quit question.
        checks.append(("quit alert names the work",
                       LauncherDelegate.quitQuestion("Updating Wine").message == "Quit while updating Wine?"
                           && LauncherDelegate.quitQuestion("Updating Wine").info == nil
                           && LauncherDelegate.quitQuestion("Downloading Eden").info != nil
                           && LauncherDelegate.quitQuestion(nil).message == "Quit while downloading?"))

        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks { print("  \(passed ? "ok  " : "FAIL") \(name)") }
        // Read-only, for the record: what this Mac's selected install would show right now.
        if let i = Install.remembered() {
            let data = i.squareEnix.appendingPathComponent("FINAL FANTASY XI").path
            print("  i    this Mac: \(data) -> "
                  + (Preflight.unavailableDrive(for: data).map(Preflight.driveMessage) ?? "no missing drive"))
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        // Here, not in a defer: exit() does not unwind, so a defer never ran.
        try? fm.removeItem(at: tmp)
        exit(failures == 0 ? 0 : 1)
    }
}
