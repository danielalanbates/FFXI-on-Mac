import AppKit

/// `--selftest-ui-text`: what the window says, headless. A drive that is not there (unplugged,
/// or ghost-mounted: listed by `mount`, absent on disk) is named whether the path lives on it or
/// reaches it through a symlink; the footer's one line and its order; that only "!!" lines reach
/// the log strip; the quit question; where the keyboard goes when the window opens (on an AppKit
/// window that is never shown). Files go to a temporary folder, deleted afterwards. The real
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

        // The Addons… sheet (b69): opens at once with a short word and a spinner while it scans
        // off the main actor; what the scan gives the sheet.
        checks.append(("Addons… while scanning: one short word, never a sentence",
                       !AddonSuite.scanningLabel.isEmpty && AddonSuite.scanningLabel.count <= 16
                           && AddonSuite.scanningLabel.split(separator: " ").count <= 2))
        let addonInstall = Install(wrapper: tmp.appendingPathComponent("addons.app"), prefixName: "prefix")
        let ag = addonInstall.gameDir
        for dir in ["plugins", "addons/bar", "addons/fps", "addons/nolua", "logs"] {
            try? fm.createDirectory(at: ag.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for f in ["plugins/Foo.dll", "plugins/winefix.dll", "addons/bar/bar.lua", "addons/fps/fps.lua"] {
            fm.createFile(atPath: ag.appendingPathComponent(f).path, contents: Data("addon.name = 'x';\n".utf8))
        }
        try? "[x] Failed to load plugin 'addons'; plugin is compiled with a different interface version.\n"
            .write(to: ag.appendingPathComponent("logs/ashita.txt"), atomically: true, encoding: .utf8)
        let scanned = AddonSuite.sheetContents(addonInstall, profile: "horizonxi.ini", policy: .unrestricted(reason: "local"))
        checks.append(("Addons… scan, unrestricted: every plugin and addon (never winefix, never a folder without its .lua), none hidden",
                       scanned.items.map { "\($0.isPlugin ? "p" : "a"):\($0.name)" } == ["p:Foo", "a:bar", "a:fps"]
                           && scanned.hidden == 0))
        let listed = AddonSuite.sheetContents(addonInstall, profile: "horizonxi.ini",
                                              policy: .allowlist(["bar"], source: "test"))
        checks.append(("Addons… scan, allowlist: only what it allows, the rest counted as hidden (fps is local-only)",
                       listed.items.map(\.name) == ["bar"] && listed.hidden == 2))
        checks.append(("Addons… scan, no published list: everything, none hidden",
                       AddonSuite.sheetItems(scanned.items, policy: .unknown).items == scanned.items
                           && AddonSuite.sheetItems(scanned.items, policy: .unknown).hidden == 0))
        checks.append(("Addons… scan: the refused-plugin line comes with it, naming the Lua host",
                       scanned.warning.contains("addons") && scanned.warning.contains("Lua host")
                           && AddonSuite.mismatchWarning([]).isEmpty
                           && !AddonSuite.mismatchWarning(["foo"]).contains("Lua host")))
        // A scan's result fills the sheet only while it is still for what is selected: the local
        // world and HorizonXI share a folder but not the profile or the list.
        let allowBar = AddonPolicy.allowlist(["bar"], source: "test")
        let scanKey = AddonSuite.SheetKey(addonInstall, profile: "horizonxi.ini", policy: allowBar)
        var otherClient = addonInstall
        otherClient.gameDirOverride = tmp.appendingPathComponent("other-client")
        checks.append(("Addons… scan result: kept for the same world; dropped for another profile, list or folder",
                       scanKey == AddonSuite.SheetKey(addonInstall, profile: "horizonxi.ini", policy: allowBar)
                           && scanKey != AddonSuite.SheetKey(addonInstall, profile: "lsb.ini", policy: allowBar)
                           && scanKey != AddonSuite.SheetKey(addonInstall, profile: "horizonxi.ini", policy: .unknown)
                           && scanKey != AddonSuite.SheetKey(otherClient, profile: "horizonxi.ini", policy: allowBar)))

        // b70: what is said when Wine dies under the game, and the sleep and wake lines.
        let at = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 14, minute: 15, second: 40))!
        let lost = Runner.serverLostLine(at: at)
        let lostDrive = Runner.serverLostLine(at: at, drive: "x10")
        let wantLost: String = "Wine stopped under the game at 14:15:40 — the game drive may have disconnected. "
            + "The game can't recover; press Force Stop."
        let wantDrive: String = "The 'x10' drive disconnected under the game at 14:15:40. The game can't recover; press Force Stop."
        checks.append(("Wine gone under the game: the time, what happened, what to press",
                       lost == wantLost && lostDrive == wantDrive))
        checks.append(("... one line each, no 'restart', and it reaches the strip as an error",
                       [lost, lostDrive].allSatisfy { !$0.contains("\n") && !$0.lowercased().contains("restart") && $0.count <= 130 }
                           && Runner.errorLines(in: "==> x\n!! " + lost + "\n") == "!! " + lost + "\n"))
        // 997 s: 2026-10-16's time asleep, summed over the dark wakes, between 15:41:57 and 16:02:15
        // (pmset; that span is 1218 s). 16.6 min, said as 17.
        let woke = at.addingTimeInterval(997)
        checks.append(("sleep and wake lines: the time to the second as pmset prints it, what played, minutes asleep",
                       Runner.sleepLine(at: at, sessions: ["HorizonXI", "Local server"]) == "i  sleep at 14:15:40 with HorizonXI, Local server"
                           && Runner.sleepLine(at: at, sessions: []) == "i  sleep at 14:15:40 with no game"
                           && Runner.wakeLine(at: woke, sleptAt: at) == "i  wake at 14:32:17 after 17 min"
                           && Runner.wakeLine(at: woke, sleptAt: nil) == "i  wake at 14:32:17"))

        // Quit question.
        checks.append(("quit alert names the work",
                       LauncherDelegate.quitQuestion("Updating Wine").message == "Quit while updating Wine?"
                           && LauncherDelegate.quitQuestion("Updating Wine").info == nil
                           && LauncherDelegate.quitQuestion("Downloading Eden").info != nil
                           && LauncherDelegate.quitQuestion(nil).message == "Quit while downloading?"))

        // The account field when the window opens (b66): focused only while empty, never with
        // its text selected for a stray keystroke to replace.
        checks.append(("open focus: the account field is focused only when empty and editable",
                       OpenFocus.focusAccount(accountName: "", fieldsDisabled: false)
                           && OpenFocus.focusAccount(accountName: "  ", fieldsDisabled: false)
                           && !OpenFocus.focusAccount(accountName: "someaccount", fieldsDisabled: false)
                           && !OpenFocus.focusAccount(accountName: "", fieldsDisabled: true)))
        checks.append(("open focus: all-selected is the signature, a caret or an empty field is not",
                       OpenFocus.isSelectAll(NSRange(location: 0, length: 11), textLength: 11)
                           && !OpenFocus.isSelectAll(NSRange(location: 11, length: 0), textLength: 11)
                           && !OpenFocus.isSelectAll(NSRange(location: 0, length: 4), textLength: 11)
                           && !OpenFocus.isSelectAll(NSRange(location: 0, length: 0), textLength: 0)))
        checks.append(("open focus: letters are dropped; Tab, Return, Escape, arrows and shortcuts are not",
                       OpenFocus.isTyping("d", shortcut: false) && OpenFocus.isTyping("é", shortcut: false)
                           && OpenFocus.isTyping(" ", shortcut: false)
                           && !OpenFocus.isTyping("\t", shortcut: false) && !OpenFocus.isTyping("\r", shortcut: false)
                           && !OpenFocus.isTyping("\u{1B}", shortcut: false)
                           && !OpenFocus.isTyping("\u{F700}", shortcut: false)
                           && !OpenFocus.isTyping("q", shortcut: true) && !OpenFocus.isTyping("", shortcut: false)))
        // The same in AppKit, on a window that is never shown.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled],
                           backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        let field = NSTextField(string: "someaccount")
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        let anchor = OpenFocusAnchor.AnchorView(frame: .zero)
        win.contentView?.addSubview(field)
        win.contentView?.addSubview(anchor)
        checks.append(("open focus (AppKit): a window not yet shown opens on the anchor, not a field",
                       win.initialFirstResponder === anchor))
        win.makeFirstResponder(field)
        let editor = win.firstResponder as? NSTextView
        checks.append(("open focus (AppKit): a field the window focuses has all its text selected (the bug)",
                       editor.map { $0.isFieldEditor && OpenFocus.isSelectAll($0.selectedRange(), textLength: ($0.string as NSString).length) } == true))
        checks.append(("open focus (AppKit): that field is let go of, its text untouched",
                       anchor.releaseSelectAll(in: win) && win.firstResponder === anchor && field.stringValue == "someaccount"))
        win.makeFirstResponder(field)
        (win.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 4, length: 0))
        checks.append(("open focus (AppKit): a field with a caret (clicked into) keeps the keyboard",
                       !anchor.releaseSelectAll(in: win) && (win.firstResponder as? NSTextView)?.isFieldEditor == true))
        win.makeFirstResponder(anchor)
        if let d = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "d",
                                    charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2) {
            anchor.keyDown(with: d)
        }
        checks.append(("open focus (AppKit): a letter typed while nothing is chosen changes nothing",
                       win.firstResponder === anchor && field.stringValue == "someaccount"))
        win.recalculateKeyViewLoop()
        win.selectNextKeyView(nil)   // what Tab does
        checks.append(("open focus (AppKit): Tab goes on into the field; the anchor is no Tab stop",
                       (win.firstResponder as? NSText)?.delegate === field && field.nextValidKeyView !== anchor))
        win.makeFirstResponder(nil)
        anchor.removeFromSuperview()
        field.removeFromSuperview()

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
