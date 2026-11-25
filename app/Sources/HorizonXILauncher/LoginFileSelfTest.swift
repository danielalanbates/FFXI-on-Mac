import Foundation

/// `--selftest-login-file`: the password stays off the loader's command line (PR #35).
///
/// Fixture clients (an Ashita v4 one with a loader that does or does not carry `--json-file`, an
/// Ashita v3 one like Eden's) go under $HXI_FIXTURE_DIR (else the temporary folder) and are deleted
/// afterwards, with the login files the checks write. Also the installers' prefix never comes
/// back as the remembered install. Nothing else is written.
extension Headless {
    @MainActor static func runLoginFileSelfTest() -> Never {
        let fm = FileManager.default
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let base = ProcessInfo.processInfo.environment["HXI_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory
        let tmp = base.appendingPathComponent("login-file-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let folder = tmp.appendingPathComponent("login", isDirectory: true)
        let secret = "p@ss w\"o\\rd-é"

        func perms(_ u: URL) -> Int { ((try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        func json(_ u: URL) -> [String: String] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: u))) as? [String: String] ?? [:]
        }
        /// A client: v4 (Ashita-cli.exe, bootloader/, horizonxi.ini) or v3 (ffxi-bootmod/, Eden.xml).
        func client(_ name: String, v3: Bool = false, loaderBytes: String) -> (Install, URL) {
            let i = Install(wrapper: tmp.appendingPathComponent("\(name).app"), prefixName: "prefix")
            let loaderDir = v3 ? "ffxi-bootmod" : "bootloader"
            for d in [loaderDir, "config/boot"] {
                try? fm.createDirectory(at: i.gameDir.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            if !v3 { fm.createFile(atPath: i.gameDir.appendingPathComponent("Ashita-cli.exe").path, contents: Data()) }
            let loaderName = v3 ? "xiloader.exe" : "horizon-loader.exe"
            fm.createFile(atPath: i.gameDir.appendingPathComponent("\(loaderDir)/\(loaderName)").path,
                          contents: Data(("MZ junk " + loaderBytes + " more").utf8))
            let profile = i.gameDir.appendingPathComponent("config/boot/" + (v3 ? "Eden.xml" : "horizonxi.ini"))
            let text = v3
                ? "<settings>\n  <setting name=\"boot_file\">.\\ffxi-bootmod\\xiloader.exe</setting>\n  <setting name=\"boot_command\">--server play.edenxi.com</setting>\n</settings>\n"
                : "[ashita.boot]\nfile        = .\\\\bootloader\\\\horizon-loader.exe\n; command = --server x --pass example\ncommand     = --server play.horizonxi.com\n"
            try? text.write(to: profile, atomically: true, encoding: .utf8)
            return (i, profile)
        }

        // LoginFile on its own.
        let w = LoginFile.windowsPath(URL(fileURLWithPath: "/var/folders/ab/c_d/T/ffxi-on-mac-login/login-1.json"))
        check("Windows path is Z: plus the POSIX path", w == #"Z:\var\folders\ab\c_d\T\ffxi-on-mac-login\login-1.json"#)
        check("a path with a space is refused", LoginFile.windowsPath(URL(fileURLWithPath: "/a b/login-1.json")) == nil)
        let win = LoginFile.write(user: "fixture", password: secret, in: folder)
        let local = win.flatMap { LoginFile.localURL(windowsPath: $0, in: folder) }
        check("login file written", local.map { fm.fileExists(atPath: $0.path) } ?? false)
        check("folder is 0700, file 0600", perms(folder) == 0o700 && local.map(perms) == 0o600)
        check("file holds username and password exactly", local.map(json) == ["username": "fixture", "password": secret])
        check("a foreign path is not ours",
              LoginFile.localURL(windowsPath: #"Z:\tmp\login-x.json"#, in: folder) == nil
              && LoginFile.localURL(windowsPath: #"C:\login-x.json"#, in: folder) == nil)
        let open = tmp.appendingPathComponent("open", isDirectory: true)
        try? fm.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        check("a folder others can read is refused", LoginFile.write(user: "u", password: "p", in: open) == nil)
        check("strip drops --json-file and --json=",
              LoginFile.strip(from: "--server h --user u --json-file Z:\\x.json --hairpin") == "--server h --user u --hairpin"
              && LoginFile.strip(from: "--server h --json=Z:\\x.json") == "--server h")
        let loaderYes = tmp.appendingPathComponent("yes.exe"), loaderNo = tmp.appendingPathComponent("no.exe")
        fm.createFile(atPath: loaderYes.path, contents: Data("x --json-file y".utf8))
        fm.createFile(atPath: loaderNo.path, contents: Data("x --pass y".utf8))
        check("loader support read from the binary",
              LoginFile.supported(loader: loaderYes) && !LoginFile.supported(loader: loaderNo)
              && !LoginFile.supported(loader: tmp.appendingPathComponent("missing.exe")))

        // Play's account line, v4.
        let (a, aProfile) = client("json", loaderBytes: "--json-file --json")
        check("loader resolved from file = .\\\\bootloader\\\\…",
              Credentials.bootLoaderURL(in: a, profile: "horizonxi.ini")?.lastPathComponent == "horizon-loader.exe")
        let ok1 = Credentials.apply(user: "fixture", password: secret, to: a, profile: "horizonxi.ini",
                                    server: "play.horizonxi.com", options: ["--hairpin"], loginFolder: folder)
        let text1 = read(aProfile)
        let cmd1 = text1.split(separator: "\n").first { $0.hasPrefix("command") }.map(String.init) ?? ""
        let file1 = LoginFile.value(in: cmd1).flatMap { LoginFile.localURL(windowsPath: $0, in: folder) }
        check("apply succeeds", ok1)
        check("command has --server, --user, --json-file and the options, in that order",
              cmd1.hasPrefix("command     = --server play.horizonxi.com --user fixture --json-file Z:\\") && cmd1.hasSuffix(" --hairpin"))
        check("no password anywhere in the profile", !text1.contains(secret) && !cmd1.contains("--pass"))
        check("commented example left alone", text1.contains("; command = --server x --pass example"))
        check("the file it names holds the password", file1.map(json)?["password"] == secret)
        check("profile counts as having an account", Credentials.bootHasAccount(in: a, profile: "horizonxi.ini"))
        let ok2 = Credentials.apply(user: "fixture", password: secret, to: a, profile: "horizonxi.ini",
                                    server: "play.horizonxi.com", loginFolder: folder)
        let cmd2 = read(aProfile).split(separator: "\n").first { $0.hasPrefix("command") }.map(String.init) ?? ""
        let file2 = LoginFile.value(in: cmd2).flatMap { LoginFile.localURL(windowsPath: $0, in: folder) }
        check("the next Play writes a new file and deletes the old one",
              ok2 && file2 != nil && file2 != file1 && !fm.fileExists(atPath: file1?.path ?? "/")
              && fm.fileExists(atPath: file2?.path ?? "/"))
        // The file is gone (the loader was up): the next Play with no saved password drops it.
        LoginFile.remove(file2)
        let dropped = Credentials.dropMissingLoginFile("horizonxi.ini", in: a, loginFolder: folder)
        let cmd3 = read(aProfile).split(separator: "\n").first { $0.hasPrefix("command") }.map(String.init) ?? ""
        check("a used login file is dropped from the command",
              dropped != nil && cmd3 == "command     = --server play.horizonxi.com --user fixture")
        check("then the profile has no account (the loader will ask)", !Credentials.bootHasAccount(in: a, profile: "horizonxi.ini"))
        check("nothing to drop a second time", Credentials.dropMissingLoginFile("horizonxi.ini", in: a, loginFolder: folder) == nil)

        // A loader without the option keeps --pass, and no file is written.
        let before = (try? fm.contentsOfDirectory(atPath: folder.path))?.count ?? 0
        let (b, bProfile) = client("pass", loaderBytes: "--pass only")
        let okB = Credentials.apply(user: "fixture", password: "plain", to: b, profile: "horizonxi.ini",
                                    server: "h.example", loginFolder: folder)
        check("old loader: --pass as before",
              okB && read(bProfile).contains("command     = --server h.example --user fixture --pass plain"))
        check("old loader: no login file written", ((try? fm.contentsOfDirectory(atPath: folder.path))?.count ?? 0) == before)
        check("old loader: profile counts as having an account", Credentials.bootHasAccount(in: b, profile: "horizonxi.ini"))

        // Ashita v3 (Eden): boot_command in the XML.
        let (c, cProfile) = client("eden", v3: true, loaderBytes: "--json-file")
        check("v3 loader resolved from boot_file", Credentials.bootLoaderURL(in: c, profile: "Eden.ini")?.path
              == c.gameDir.appendingPathComponent("ffxi-bootmod/xiloader.exe").path)
        let okC = Credentials.apply(user: "fixture", password: secret, to: c, profile: "Eden.ini",
                                    server: "play.edenxi.com", loginFolder: folder)
        let xml = read(cProfile)
        check("v3: boot_command carries --json-file, not the password",
              okC && xml.contains("<setting name=\"boot_command\">--server play.edenxi.com --user fixture --json-file Z:\\")
              && !xml.contains("--pass") && !xml.contains("p@ss"))
        check("v3: counts as having an account", Credentials.bootHasAccount(in: c, profile: "Eden.ini"))

        // An absolute loader path is not guessed at.
        let (d, dProfile) = client("abs", loaderBytes: "--json-file")
        try? "[ashita.boot]\nfile        = C:\\\\x\\\\xiloader.exe\ncommand     = --server h\n".write(to: dProfile, atomically: true, encoding: .utf8)
        check("absolute loader path: not resolved, so --pass", Credentials.bootLoaderURL(in: d, profile: "horizonxi.ini") == nil
              && Credentials.apply(user: "u", password: "p", to: d, profile: "horizonxi.ini", server: "h", loginFolder: folder)
              && read(dProfile).contains("--pass p"))

        // Stale files: ours go, anything else stays.
        let other = folder.appendingPathComponent("keep.txt")
        fm.createFile(atPath: other.path, contents: Data())
        LoginFile.removeStale(olderThan: 0, in: folder)
        let left = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        check("removeStale deletes only login files", left == ["keep.txt"])

        // The installers' prefix is never the remembered install.
        let suite = "org.batesai.selftest.login-\(UUID().uuidString.prefix(6))"
        if let defaults = UserDefaults(suiteName: suite) {
            defaults.set("/x/FFXI on Mac Wine.app#prefix-installers", forKey: "install.last")
            let refused = Install.lastChosen(defaults) == nil
            defaults.set("/x/FFXI on Mac Wine.app#prefix10", forKey: "install.last")
            let kept = Install.lastChosen(defaults)?.prefixName == "prefix10"
            defaults.removePersistentDomain(forName: suite)
            check("remembered installers' prefix is ignored, a game prefix kept", refused && kept)
        } else { check("fixture defaults", false) }

        try? fm.removeItem(at: tmp)
        var failed = 0
        for (name, ok) in checks {
            print("  \(ok ? "ok  " : "FAIL") \(name)")
            if !ok { failed += 1 }
        }
        print(failed == 0 ? "login-file: \(checks.count)/\(checks.count) passed" : "login-file: \(failed) of \(checks.count) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
