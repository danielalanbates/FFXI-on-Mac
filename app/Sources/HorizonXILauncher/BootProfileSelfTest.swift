import Foundation

/// `--selftest-boot-profile`: what Play does to a world's boot profile (b61), on fixture clients.
///
/// The b60 failure, rebuilt: a HorizonXI client whose horizonxi.ini was copied from Ashita's
/// example (`file = .\\bootloader\\pol.exe`, no pivot) with pol.exe, xiloader.exe and
/// horizon-loader.exe all in bootloader/. Also: a client with no profile at all, other worlds'
/// profiles (left exactly as they were), the loader's account menu, and the repeat cap on its
/// output. Fixtures go under $HXI_FIXTURE_DIR (else the temporary folder) and are deleted
/// afterwards. Nothing outside them is written; launcher.log is not touched.
extension Headless {
    @MainActor static func runBootProfileSelfTest() -> Never {
        let fm = FileManager.default
        var checks: [(String, Bool)] = []
        let base = ProcessInfo.processInfo.environment["HXI_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory
        let tmp = base.appendingPathComponent("boot-profile-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Removed by hand before each exit: `exit` does not run a `defer`.

        guard let horizon = Server.all.first(where: { $0.name == "HorizonXI" }),
              let cats = Server.all.first(where: { $0.name == "CatsEyeXI" }) else {
            print("  FAIL no HorizonXI/CatsEyeXI world"); try? fm.removeItem(at: tmp); exit(1)
        }
        let profile = "horizonxi.ini"
        let T = BootProfile.horizonTemplate

        /// A v4 client: Ashita-cli.exe, these loaders, SquareEnix, polplugins/DATs, a pivot.ini.
        func client(_ name: String, loaders: [String], pivotRoot: String = #"C:\Games\HorizonXI\polplugins\DATs"#) -> Install {
            let i = Install(wrapper: tmp.appendingPathComponent("\(name).app"), prefixName: "prefix")
            for d in ["bootloader", "config/boot", "config/pivot", "SquareEnix/FINAL FANTASY XI", "polplugins/DATs/horizonoverrides"] {
                try? fm.createDirectory(at: i.gameDir.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            fm.createFile(atPath: i.gameDir.appendingPathComponent("Ashita-cli.exe").path, contents: Data())
            for l in loaders { fm.createFile(atPath: i.bootLoaderDir.appendingPathComponent(l).path, contents: Data()) }
            try? "[settings]\nroot_path=\(pivotRoot)\ndebug_log=true\n[overlays]\n0=horizonmusic\n1=horizonoverrides\n"
                .write(to: BootProfile.pivotINI(i), atomically: true, encoding: .utf8)
            return i
        }
        func profileURL(_ i: Install, _ p: String = "horizonxi.ini") -> URL { i.gameDir.appendingPathComponent("config/boot/\(p)") }
        func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        func write(_ t: String, _ u: URL) { try? t.write(to: u, atomically: true, encoding: .utf8) }

        // What b60 wrote: Ashita's example with the account and the renderer's override applied.
        let credentials = "command     = --server play.horizonxi.com --user fixtureuser --pass fixturepass"
        let exampleSeeded = """
            ;--- Ashita's example, abridged
            [ashita.launcher]
            autoclose   = 1
            name        = Example Configuration

            [ashita.boot]
            file        = .\\\\bootloader\\\\pol.exe
            \(credentials)
            gamemodule  = ffximain.dll
            script      = default.txt
            args        =

            ;---------------------------------------------------------------
            ; ashita.polplugins
            ;---------------------------------------------------------------
            [ashita.polplugins]
            sandbox = 0

            [ashita.polplugins.args]
            ;pivot = 1

            [ffxi.direct3d8]
            behaviorflags.fpu_preserve                      = 1

            [ffxi.registry]
            0001 = 1280
            0002 = 720

            """

        // 1. The template and the worlds.
        let template = BootProfile.templateText(T) ?? ""
        checks.append(("the HorizonXI template ships (app/Resources/\(T))", !template.isEmpty))
        checks.append(("it boots horizon-loader.exe, carries no account and is not Ashita's example",
                       BootProfile.loaderName(in: template) == "horizon-loader.exe"
                           && !template.contains("--user") && !template.contains("--pass")
                           && !template.contains("Example Configuration")))
        checks.append(("every required setting is in the template with the same value",
                       BootProfile.required(template: T, host: "play.horizonxi.com").allSatisfy {
                           BootProfile.value($0.key, section: $0.section, in: template) == $0.value
                       } && BootProfile.value("pivot", section: "ashita.polplugins", in: template) == "1"
                         && BootProfile.value("sandbox", section: "ashita.polplugins", in: template) == "1"))
        checks.append(("HorizonXI declares horizon-loader.exe and the template; the local world (same client) the loader only",
                       horizon.loader == "horizon-loader.exe" && horizon.bootTemplate == T
                           && Server.all.filter(\.local).allSatisfy { $0.loader == "horizon-loader.exe" && $0.bootTemplate.isEmpty }))
        checks.append(("no other world declares either",
                       Server.all.filter { $0.name != "HorizonXI" && !$0.local }.allSatisfy { $0.loader.isEmpty && $0.bootTemplate.isEmpty }))

        // 2. The loader decision.
        let all3 = ["pol.exe", "xiloader.exe", "horizon-loader.exe"]
        checks.append(("the world's loader wins over another that is present (pol.exe -> horizon-loader.exe)",
                       BootProfile.loaderToName(named: "pol.exe", present: all3, worldLoader: "horizon-loader.exe") == "horizon-loader.exe"))
        checks.append(("already the world's loader (any case): left alone",
                       BootProfile.loaderToName(named: "Horizon-Loader.exe", present: all3, worldLoader: "horizon-loader.exe") == nil))
        checks.append(("the world's loader not installed: the profile's own, while present, stays",
                       BootProfile.loaderToName(named: "pol.exe", present: ["pol.exe", "xiloader.exe"], worldLoader: "horizon-loader.exe") == nil))
        checks.append(("no world loader: a present loader stays (CatsEyeXI's pol.exe)",
                       BootProfile.loaderToName(named: "pol.exe", present: ["pol.exe", "horizon-loader.exe"], worldLoader: "") == nil))
        checks.append(("no world loader, the named one missing: first known present, as before",
                       BootProfile.loaderToName(named: "gxiloader.exe", present: ["pol.exe", "xiloader.exe"], worldLoader: "") == "xiloader.exe"))

        // 3. b60's install: the example-seeded profile, three loaders.
        let a = client("b60", loaders: all3)
        write(exampleSeeded, profileURL(a))
        let before = Preflight.run(a, profile: profile, loader: horizon.loader, template: horizon.bootTemplate)
            .first { $0.id == "bootprofile" }
        checks.append(("Preflight names the wrong loader and the missing pivot",
                       before?.state == .bad && before?.detail.contains("boots pol.exe, not horizon-loader.exe") == true
                           && before?.detail.contains("[ashita.polplugins] pivot") == true))
        var x = PrimaryInputs()
        x.world = "HorizonXI"; x.checks = before.map { [$0] } ?? []
        let d = Primary.decide(x)
        checks.append(("...which Play fixes: Play enabled, nothing said under it",
                       Primary.fixedByPlay.contains("bootprofile") && d.label == "Play" && d.enabled && d.reason == nil))
        let said = Credentials.prepareProfile(for: horizon, in: a)
        let after = read(profileURL(a))
        checks.append(("Play: the profile boots horizon-loader.exe", BootProfile.loaderName(in: after) == "horizon-loader.exe"
                           && Credentials.bootLoaderName(in: a, profile: profile) == "horizon-loader.exe"))
        checks.append(("Play: pivot = 1 added in [ashita.polplugins]; sandbox = 0 left as it was",
                       BootProfile.value("pivot", section: "ashita.polplugins", in: after) == "1"
                           && BootProfile.value("sandbox", section: "ashita.polplugins", in: after) == "0"))
        checks.append(("the account line is untouched, byte for byte", after.contains(credentials + "\n")))
        checks.append(("every other line is kept, in order: only `file` changed and one line was added",
                       {
                           let old = TextFile.lines(of: exampleSeeded), new = TextFile.lines(of: after)
                           guard new.count == old.count + 1 else { return false }
                           let changed = zip(old, new.filter { $0 != "pivot = 1" }).filter { $0 != $1 }
                           return changed.count == 1 && changed[0].0.contains("pol.exe")
                       }()))
        checks.append(("user values stay: fpu_preserve 1, 0001 1280, the name",
                       BootProfile.value("behaviorflags.fpu_preserve", section: "ffxi.direct3d8", in: after) == "1"
                           && BootProfile.value("0001", section: "ffxi.registry", in: after) == "1280"
                           && BootProfile.value("name", section: "ashita.launcher", in: after) == "Example Configuration"))
        checks.append(("no Sandbox paths added while Sandbox is off", !after.contains("[sandbox.paths]")))
        checks.append(("pivot.ini aimed at this client's own DATs; overlays kept",
                       read(BootProfile.pivotINI(a)).contains(#"root_path=C:\HorizonXI\polplugins\DATs"#)
                           && read(BootProfile.pivotINI(a)).contains("1=horizonoverrides")))
        checks.append(("what Play changed is said for launcher.log (loader, added keys, pivot)",
                       said.count == 3 && said[0].contains("pol.exe -> horizon-loader.exe")))
        checks.append(("the next Play changes nothing", Credentials.prepareProfile(for: horizon, in: a).isEmpty
                           && read(profileURL(a)) == after))
        checks.append(("Preflight is satisfied afterwards",
                       Preflight.run(a, profile: profile, loader: horizon.loader, template: horizon.bootTemplate)
                           .first { $0.id == "bootprofile" }?.state == .ok))

        // 4. The same profile with CRLF endings stays CRLF.
        let crlf = client("crlf", loaders: all3)
        write(exampleSeeded.replacingOccurrences(of: "\n", with: "\r\n"), profileURL(crlf))
        _ = Credentials.prepareProfile(for: horizon, in: crlf)
        let crlfAfter = read(profileURL(crlf))
        checks.append(("a CRLF profile is fixed and stays CRLF",
                       BootProfile.loaderName(in: crlfAfter) == "horizon-loader.exe"
                           && crlfAfter.contains("pivot = 1\r\n")
                           && !crlfAfter.replacingOccurrences(of: "\r\n", with: "").contains("\n")))

        // 5. A user's own pivot = 0, Sandbox on without its paths, and no `file` line at all.
        let u = client("user", loaders: all3)
        write("[ashita.boot]\n\(credentials)\nscript = default.txt\n\n[ashita.polplugins]\nsandbox = 1\npivot = 0\n\n[ffxi.direct3d8]\nbehaviorflags.fpu_preserve = 0\n", profileURL(u))
        _ = Credentials.prepareProfile(for: horizon, in: u)
        let uAfter = read(profileURL(u))
        checks.append(("a user's pivot = 0 is never changed", BootProfile.value("pivot", section: "ashita.polplugins", in: uAfter) == "0"))
        checks.append(("a profile with no `file` line gets the world's loader in [ashita.boot]",
                       BootProfile.loaderName(in: uAfter) == "horizon-loader.exe"))
        checks.append(("Sandbox on and no [sandbox.paths]: HorizonXI's relative paths are added",
                       BootProfile.value("pol", section: "sandbox.paths", in: uAfter) == #"..\SquareEnix\PlayOnlineViewer"#
                           && BootProfile.value("ffxi", section: "sandbox.paths", in: uAfter) == #"..\SquareEnix\FINAL FANTASY XI"#))

        // 6. A fresh client: no profile, Ashita's examples beside it.
        let f = client("fresh", loaders: all3)
        write(exampleSeeded, profileURL(f, "example-privateserver.ini"))
        let made = Credentials.ensureProfile(profile, in: f, loader: horizon.loader, template: horizon.bootTemplate,
                                             host: horizon.host)
        let fresh = read(profileURL(f))
        checks.append(("a new HorizonXI profile comes from the template, not Ashita's example",
                       made && BootProfile.value("name", section: "ashita.launcher", in: fresh) == "HorizonXI"
                           && BootProfile.loaderName(in: fresh) == "horizon-loader.exe"
                           && BootProfile.value("command", section: "ashita.boot", in: fresh) == "--server play.horizonxi.com"))
        _ = Credentials.apply(user: "fixtureuser", password: "fixturepass", to: f, profile: profile, server: horizon.host)
        checks.append(("the account is written into it, and Play then has nothing to add",
                       read(profileURL(f)).contains("--user fixtureuser --pass fixturepass")
                           && Credentials.prepareProfile(for: horizon, in: f).count == 1   // pivot.ini only
                           && BootProfile.missing(in: read(profileURL(f)), template: T, host: horizon.host, install: f).isEmpty))
        let l = client("fresh-local", loaders: all3)
        write(exampleSeeded, profileURL(l, "example-privateserver.ini"))
        guard let local = Server.all.first(where: \.local) else {
            print("  FAIL no local world"); try? fm.removeItem(at: tmp); exit(1)
        }
        _ = Credentials.ensureProfile(local.bootProfile, in: l, loader: local.loader, template: local.bootTemplate,
                                      host: local.host)
        let lsb = read(profileURL(l, local.bootProfile))
        checks.append(("the local world on a fresh client: copied as before, but booting horizon-loader.exe",
                       BootProfile.value("name", section: "ashita.launcher", in: lsb) == "Example Configuration"
                           && BootProfile.loaderName(in: lsb) == "horizon-loader.exe"
                           && Credentials.prepareProfile(for: local, in: l).isEmpty))
        var elsewhere = Install(wrapper: tmp.appendingPathComponent("else.app"), prefixName: "prefix",
                                gameDirOverride: tmp.appendingPathComponent("data/Ashita"))
        elsewhere.dataRoot = tmp.appendingPathComponent("data")
        try? fm.createDirectory(at: tmp.appendingPathComponent("data/Game/SquareEnix/FINAL FANTASY XI"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: tmp.appendingPathComponent("data/Ashita"), withIntermediateDirectories: true)
        checks.append(("a client whose SquareEnix is elsewhere gets its real path for Sandbox",
                       BootProfile.sandboxPaths(for: elsewhere)[1].value.hasPrefix("Z:")
                           && BootProfile.sandboxPaths(for: elsewhere)[1].value.hasSuffix(#"\Game\SquareEnix\PlayOnlineViewer"#)))

        // 7. Other worlds stay exactly as they were.
        let c = client("catseye", loaders: ["pol.exe", "horizon-loader.exe"], pivotRoot: #"C:\Nowhere\DATs"#)
        let catsProfile = "[ashita.boot]\nfile = .\\\\bootloader\\\\pol.exe\ncommand = --server server.catseyexi.com\n"
        write(catsProfile, profileURL(c, cats.bootProfile))
        checks.append(("CatsEyeXI: profile and pivot.ini untouched, no boot-profile check",
                       Credentials.prepareProfile(for: cats, in: c).isEmpty
                           && read(profileURL(c, cats.bootProfile)) == catsProfile
                           && read(BootProfile.pivotINI(c)).contains(#"root_path=C:\Nowhere\DATs"#)
                           && !Preflight.run(c, profile: cats.bootProfile).contains { $0.id == "bootprofile" }))
        let s = client("supernova", loaders: ["pol.exe", "xiloader.exe"])
        write("[ashita.boot]\nfile = .\\bootloader\\gxiloader.exe\n", profileURL(s, "supernova.ini"))
        Credentials.fixBootLoader("supernova.ini", in: s)
        checks.append(("a world with no loader of its own: a missing one is still replaced as before (xiloader.exe)",
                       BootProfile.loaderName(in: read(profileURL(s, "supernova.ini"))) == "xiloader.exe"))
        checks.append(("`file` is read from [ashita.boot] only, not any key starting with 'file'",
                       BootProfile.loaderName(in: "[other]\nfilename = x.exe\n[ashita.boot]\nfile = .\\\\bootloader\\\\y.exe\n") == "y.exe"))

        // 8. The loader's menu, and the refusals before it.
        let menu = """
            [10/15/26 12:21:34] Connected to server!
            [10/15/26 12:21:34] ==========================================================
            [10/15/26 12:21:34] What would you like to do?
            [10/15/26 12:21:34]    1.) Login
            [10/15/26 12:21:34]    2.) Create New Account
            [10/15/26 12:21:34] ==========================================================

            Enter a selection: \n
            """
        checks.append(("the account menu is a refused login, said in one plain line",
                       LoaderOutput.refusal(in: menu, world: "HorizonXI")
                           == LoaderOutput.Refusal(message: "HorizonXI didn't accept the login — check the account name and password.", atMenu: true)))
        checks.append(("the loader's own refusal before the menu is what is shown",
                       LoaderOutput.refusal(in: "[x] Failed to login. Invalid username or password.\n" + menu, world: "HorizonXI")
                           == LoaderOutput.Refusal(message: "Failed to login. Invalid username or password.", atMenu: false)))
        checks.append(("ordinary output is not a refusal; a job's output never counts the menu",
                       LoaderOutput.refusal(in: "[*] Ashita injected and installed! Enjoy!\n", world: "HorizonXI") == nil
                           && LoaderOutput.refusal(in: menu, world: "HorizonXI", menu: false) == nil))

        // 9. The repeat cap: 831 menus, as on 2026-10-15, read in odd-sized pieces.
        var cap = LoaderOutput.RepeatCap(limit: 20)
        var whole = ""
        for n in 0..<831 {
            whole += menu.replacingOccurrences(of: "12:21:34", with: String(format: "12:%02d:%02d", 21 + n / 60, n % 60))
        }
        var logged = "", cut = whole.startIndex, size = 7
        while cut < whole.endIndex {
            let end = whole.index(cut, offsetBy: size, limitedBy: whole.endIndex) ?? whole.endIndex
            logged += cap.filter(String(whole[cut..<end]))
            cut = end; size = size * 7 % 293 + 5
        }
        logged += cap.flush()
        let kept = logged.components(separatedBy: "What would you like to do?").count - 1
        checks.append(("each menu line is written 20 times, not 831; one note says the rest is dropped",
                       kept == 20 && logged.components(separatedBy: LoaderOutput.RepeatCap.note).count == 2
                           && logged.utf8.count < whole.utf8.count / 30))
        checks.append(("lines split across reads are whole when written",
                       logged.split(separator: "\n").allSatisfy { l in
                           l.isEmpty || l.hasPrefix("[10/15/26") || l.hasPrefix("Enter a selection") || l.hasPrefix("i  ")
                       }))
        var crlfCap = LoaderOutput.RepeatCap(limit: 3)
        let crlfOut = crlfCap.filter(String(repeating: "same line\r\n", count: 10)) + crlfCap.filter("other\r\n")
        checks.append(("CRLF lines are counted as lines too", crlfOut.components(separatedBy: "same line").count - 1 == 3
                           && crlfOut.contains("other")))

        // 10. Optional: a real profile (its password already masked by whoever copied it) put
        // through Play on a fixture client with HorizonXI's three loaders. Prints what changed.
        //   HXI_BOOT_PROFILE_SAMPLE=<horizonxi.ini copy> [HXI_PIVOT_SAMPLE=<pivot.ini copy>]
        let env = ProcessInfo.processInfo.environment
        if let sample = env["HXI_BOOT_PROFILE_SAMPLE"], let text = try? String(contentsOfFile: sample, encoding: .utf8) {
            let r = client("sample", loaders: all3)
            write(text, profileURL(r))
            if let p = env["HXI_PIVOT_SAMPLE"], let pt = try? String(contentsOfFile: p, encoding: .utf8) {
                write(pt, BootProfile.pivotINI(r))
            }
            let command = { (t: String) in TextFile.lines(of: t).first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("command") } }
            for line in Credentials.prepareProfile(for: horizon, in: r) { print("     sample: \(line)") }
            let out = read(profileURL(r))
            checks.append(("sample: boots horizon-loader.exe, has pivot, account line unchanged, then stable",
                           BootProfile.loaderName(in: out) == "horizon-loader.exe"
                               && BootProfile.value("pivot", section: "ashita.polplugins", in: out) != nil
                               && command(out) == command(text)
                               && Credentials.prepareProfile(for: horizon, in: r).isEmpty))
        }

        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        try? fm.removeItem(at: tmp)
        exit(failures == 0 ? 0 : 1)
    }
}
