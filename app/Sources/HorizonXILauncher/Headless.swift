import Foundation

/// `--check` — run every world's preflight and print the result, then exit. No window, no
/// wineserver, nothing launched.
///
/// This exists because the failure it is built to catch is invisible from the outside: a world
/// pointed at a folder that holds another world's client launches, connects, and plays *that*
/// world's data (see Install.clientAmbiguity). Checking it by eye means opening the launcher and
/// switching worlds one at a time; checking it here is one command, and it can run while somebody
/// is playing, because it touches nothing.
///
///     FFXI-on-Mac.app/Contents/MacOS/FFXI-on-Mac --check [--world <name>]
///
/// Exit status is 1 if any checked world has a blocking problem, so it is usable from a script.
enum Headless {
    /// True when this process was started to do one job and print about it, rather than to show
    /// a window: `--check` or a self-test (which exits here), or `--play` (which needs a window,
    /// but whose log belongs on stderr as well -- see Runner.tee).
    static var isHeadlessRun: Bool {
        let a = CommandLine.arguments
        return a.contains("--check")
            || a.contains("--play")
            || a.contains("--selftest-addon-policy")
            || a.contains("--selftest-addon-source")
            || a.contains("--selftest-addon-installer")
            || a.contains("--selftest-addon-profile")
            || a.contains("--selftest-addon-scrub")
            || a.contains("--selftest-addon-install")
            || a.contains("--selftest-cursor-fix")
            || a.contains("--selftest-guide-disabled")
            || a.contains("--selftest-narration-disabled")
            || a.contains("--selftest-multiworld")
            || a.contains("--selftest-single-instance")
            || a.contains("--selftest-single-instance-probe")
    }

    @MainActor static func runIfAsked() {
        let args = CommandLine.arguments
        if args.contains("--selftest-addon-policy") {
            runAddonPolicySelfTest()
        }
        if args.contains("--selftest-addon-source") {
            runAddonSourceSelfTest()
        }
        if args.contains("--selftest-addon-installer") {
            runAddonInstallerSelfTest()
        }
        if args.contains("--selftest-addon-profile") {
            runAddonProfileSelfTest()
        }
        if args.contains("--selftest-addon-scrub") {
            runAddonScrubSelfTest()
        }
        if args.contains("--selftest-addon-install") {
            runAddonInstallSelfTest()
        }
        if args.contains("--selftest-cursor-fix") {
            runCursorFixSelfTest()
        }
        if args.contains("--selftest-guide-disabled") {
            runGuideDisabledSelfTest()
        }
        if args.contains("--selftest-narration-disabled") {
            runNarrationDisabledSelfTest()
        }
        if args.contains("--selftest-multiworld") {
            runMultiWorldSelfTest()
        }
        if let at = args.firstIndex(of: "--selftest-single-instance-probe") {
            runSingleInstanceProbe(Array(args[(at + 1)...]))
        }
        if args.contains("--selftest-single-instance") {
            runSingleInstanceSelfTest()
        }
        // A self-test this build does not have must not fall through to a window: self-tests
        // are exempt from SingleInstance, so that would be a second launcher.
        if let unknown = args.first(where: { $0.hasPrefix("--selftest-") }) {
            FileHandle.standardError.write(Data("unknown self-test \(unknown)\n".utf8))
            exit(2)
        }
        guard args.contains("--check") else { return }
        var only: String? = nil
        if let w = args.firstIndex(of: "--world"), w + 1 < args.count { only = args[w + 1] }

        guard let base = Install.remembered() ?? Install.discover().first else {
            FileHandle.standardError.write(Data("no wrapper/install found\n".utf8))
            exit(2)
        }
        print("install: \(base.wrapper.path) [\(base.prefixName)]\n")

        let store = ServerStore()
        var worst = 0
        for server in store.servers where only == nil || server.name == only! {
            let i = base.forServer(server)
            let checks = Preflight.run(i, profile: server.bootProfile)
            let bad = checks.filter { $0.state == .bad }
            let flag = bad.isEmpty ? "ok  " : "BAD "
            let where_ = server.dataPath.isEmpty ? "(wrapper default)" : i.gameDir.path
            print("\(flag)\(server.name)")
            print("     client   \(where_)")
            print("     ashita   \(i.hasGame ? i.ashitaGeneration.rawValue : "none")  profile \(i.bootProfileName(server.bootProfile))")
            print("     data     \(i.squareEnix.path)")
            for c in bad { print("     ! \(c.title): \(c.detail)") }
            print("")
            if !bad.isEmpty { worst = 1 }
        }
        exit(Int32(worst))
    }

    @MainActor private static func runAddonPolicySelfTest() -> Never {
        let local = AddonPolicies.localWorld
        let localServer = Server.all.first(where: \.local)
        let unknown = AddonPolicy.unknown
        let hostedList = AddonPolicy.allowlist(
            ["vanavoice", "vanaguide"], source: "offline policy fixture")
        let checks: [(String, Bool, Bool)] = [
            ("VanaVoice allowed on local LSB", Narration.allowed(by: local), true),
            ("Vanaguide allowed on local LSB", Guide.allowed(by: local), true),
            ("only local server gets local addon policy",
             localServer.map { AddonPolicies.policy(for: $0) == local } ?? false, true),
            ("remote server does not get local addon policy",
             Server.all.filter { !$0.local }.allSatisfy {
                 AddonPolicies.policy(for: $0) != local
             }, true),
            ("VanaVoice refused on unknown world", Narration.allowed(by: unknown), false),
            ("Vanaguide refused on unknown world", Guide.allowed(by: unknown), false),
            ("VanaVoice refused by hosted allowlist", Narration.allowed(by: hostedList), false),
            ("Vanaguide refused by hosted allowlist", Guide.allowed(by: hostedList), false),
        ]
        var failures = 0
        for (name, got, expected) in checks {
            let passed = got == expected
            if !passed { failures += 1 }
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runAddonInstallerSelfTest() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-addon-installer-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("game/addons/vanaguide", isDirectory: true)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        var checks: [(String, Bool)] = []

        do {
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: destination.appendingPathComponent("addon.lua"))
            try Data("new".utf8).write(to: source.appendingPathComponent("addon.lua"))

            do {
                try AddonInstaller.replaceDirectory(at: destination, with: missing, fileManager: fm)
                checks.append(("failed staging reports an error", false))
            } catch {
                let prior = try? String(contentsOf: destination.appendingPathComponent("addon.lua"), encoding: .utf8)
                checks.append(("failed staging leaves the playable addon intact", prior == "old"))
            }

            let navDir = destination.appendingPathComponent("data/nav", isDirectory: true)
            try fm.createDirectory(at: navDir, withIntermediateDirectories: true)
            try Data("grid".utf8).write(to: navDir.appendingPathComponent("231.vgnav"))
            try AddonInstaller.replaceDirectory(at: destination, with: source, preserving: ["data/nav"], fileManager: fm)
            let installed = try? String(contentsOf: destination.appendingPathComponent("addon.lua"), encoding: .utf8)
            checks.append(("successful staging atomically installs the new addon", installed == "new"))
            let grid = try? String(contentsOf: destination.appendingPathComponent("data/nav/231.vgnav"), encoding: .utf8)
            checks.append(("generated navigation grids survive a reinstall", grid == "grid"))
            let leftovers = (try? fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)) ?? []
            checks.append(("successful install leaves no staging or backup directories",
                           leftovers == [destination.lastPathComponent]))
        } catch {
            checks.append(("installer fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }

        try? fm.removeItem(at: root)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runAddonSourceSelfTest() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-addon-source-\(UUID().uuidString)")
        var checks: [(String, Bool)] = []
        do {
            let partial = root.appendingPathComponent("partial-guide", isDirectory: true)
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            try Data().write(to: partial.appendingPathComponent("Vanaguide.lua"))
            try fm.createDirectory(at: partial.appendingPathComponent("core", isDirectory: true),
                                   withIntermediateDirectories: true)
            try Data().write(to: partial.appendingPathComponent("core/guide.lua"))
            checks.append(("guide entry without required modules is rejected",
                           !Guide.isCompleteAddon(at: partial, fileManager: fm)))

            let complete = root.appendingPathComponent("complete-guide", isDirectory: true)
            for path in ["guides", "data", "routing", "ui"] {
                try fm.createDirectory(at: complete.appendingPathComponent(path, isDirectory: true),
                                       withIntermediateDirectories: true)
            }
            let requiredGuideFiles = [
                "Vanaguide.lua", "core/guide.lua", "core/progress.lua", "core/story.lua",
                "core/conditions.lua", "core/util.lua", "core/lookup.lua", "core/verify.lua",
                "core/walk.lua", "guides/init.lua", "routing/zonegraph.lua", "routing/router.lua",
                "routing/path.lua", "routing/zonepoints.lua", "routing/navgrid.lua",
                "ui/arrow.lua", "ui/window.lua", "ui/line.lua", "ui/project.lua",
                "data/zone_names.lua", "data/zonelines.lua", "data/zonepoints.lua",
                "data/drops.lua", "data/gear.lua", "data/missions.lua", "data/nm.lua",
                "data/quests.lua", "data/travel.lua", "data/vendors.lua",
            ]
            for path in requiredGuideFiles {
                let file = complete.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            }
            checks.append(("complete guide snapshot is accepted",
                           Guide.isCompleteAddon(at: complete, fileManager: fm)))

            let partialVoice = root.appendingPathComponent("partial-voice", isDirectory: true)
            try fm.createDirectory(at: partialVoice, withIntermediateDirectories: true)
            checks.append(("voice snapshot without its entry is rejected",
                           !Narration.isCompleteAddon(at: partialVoice)))
            try Data().write(to: partialVoice.appendingPathComponent("vanavoice.lua"))
            checks.append(("single-file voice addon is accepted",
                           Narration.isCompleteAddon(at: partialVoice)))
        } catch {
            checks.append(("addon source fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }
        try? fm.removeItem(at: root)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runAddonProfileSelfTest() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-addon-profile-\(UUID().uuidString)")
        let game = root.appendingPathComponent("game", isDirectory: true)
        let scripts = game.appendingPathComponent("scripts", isDirectory: true)
        let boot = game.appendingPathComponent("config/boot", isDirectory: true)
        let addons = game.appendingPathComponent("addons", isDirectory: true)
        let addon = addons.appendingPathComponent("sample", isDirectory: true)
        let defaultScript = scripts.appendingPathComponent("default.txt")
        let worldScript = scripts.appendingPathComponent("lsb.txt")
        var checks: [(String, Bool)] = []

        do {
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            try fm.createDirectory(at: boot, withIntermediateDirectories: true)
            try fm.createDirectory(at: addon, withIntermediateDirectories: true)
            try fm.createDirectory(at: addons.appendingPathComponent("vanavoice"), withIntermediateDirectories: true)
            try fm.createDirectory(at: addons.appendingPathComponent("Vanaguide"), withIntermediateDirectories: true)
            try "addon.name = 'vanavoice'\n".write(
                to: addons.appendingPathComponent("vanavoice/vanavoice.lua"), atomically: true, encoding: .utf8)
            try "addon.name = 'Vanaguide'\n".write(
                to: addons.appendingPathComponent("Vanaguide/Vanaguide.lua"), atomically: true, encoding: .utf8)
            try Data().write(to: game.appendingPathComponent("Ashita-cli.exe"))
            try "script=lsb.txt\n".write(to: boot.appendingPathComponent("lsb.ini"), atomically: true, encoding: .utf8)
            try "# default script stays user-owned\n".write(to: defaultScript, atomically: true, encoding: .utf8)
            let originalWorldScript = "/addon load sample\n/addon load vanavoice\n/addon load vanaguide\n# local profile sentinel\n"
            try originalWorldScript.write(to: worldScript, atomically: true, encoding: .utf8)
            try "addon.name = 'sample'\naddon.author = 'fixture'\n".write(
                to: addon.appendingPathComponent("sample.lua"), atomically: true, encoding: .utf8)

            let install = Install(wrapper: root.appendingPathComponent("wrapper.app"),
                                  prefixName: "prefix", gameDirOverride: game)
            checks.append(("stored password keys are isolated by world",
                           Credentials.passwordKey("same-user", world: "World A")
                               != Credentials.passwordKey("same-user", world: "World B")))
            let profileText = "; command = --pass ignored\ncommand = --server local --user same-user --pass world-secret"
            let adoption = Credentials.passwordAdoption(from: profileText, user: "same-user",
                                                        world: "World A", currentWorldPassword: "")
            checks.append(("profile migration stores credentials under the selected world key",
                           adoption?.key == Credentials.passwordKey("same-user", world: "World A")
                               && adoption?.password == "world-secret"))
            checks.append(("profile migration ignores commented credentials",
                           Credentials.passwordAdoption(
                               from: "; command = --server local --pass ignored\n", user: "same-user",
                               world: "World A", currentWorldPassword: "") == nil))
            checks.append(("profile migration preserves an existing world credential",
                           Credentials.passwordAdoption(from: profileText, user: "same-user",
                                                        world: "World A", currentWorldPassword: "already-set") == nil))
            let target = AddonSuite.scriptURL(install, profile: "lsb.ini")
            checks.append(("boot profile resolves to its configured script", target == worldScript))
            var items = AddonSuite.scan(install, profile: "lsb.ini")
            checks.append(("addon scan reads the selected world's enabled state",
                           items.count == 1 && items[0].name == "sample" && items[0].enabled))
            checks.append(("launcher-managed narrator and guide are controlled by their own settings",
                           !items.contains { ["vanavoice", "vanaguide"].contains($0.name.lowercased()) }))
            if items.count == 1 {
                items[0].enabled = false
                checks.append(("Apply writes the selected world's script", AddonSuite.write(items, to: install, profile: "lsb.ini")))
                let afterDisable = Credentials.readFile(at: worldScript) ?? ""
                checks.append(("disabled addon is removed from the selected script",
                               !afterDisable.contains("/addon load sample") && afterDisable.contains("local profile sentinel")))
                checks.append(("dedicated narrator and guide startup lines survive AddonSuite adoption",
                               afterDisable.contains("/addon load vanavoice")
                                   && afterDisable.contains("/addon load vanaguide")))
                checks.append(("default.txt remains untouched",
                               Credentials.readFile(at: defaultScript) == "# default script stays user-owned\n"))
                items[0].enabled = true
                checks.append(("re-enabling writes the selected profile", AddonSuite.write(items, to: install, profile: "lsb.ini")))
                checks.append(("re-enabled addon appears in the selected script",
                               (Credentials.readFile(at: worldScript) ?? "").contains("/addon load sample")))
            } else {
                checks.append(("selected addon can be disabled and re-enabled", false))
            }

            let legacyGame = root.appendingPathComponent("legacy-game", isDirectory: true)
            let legacyBoot = legacyGame.appendingPathComponent("config/boot", isDirectory: true)
            try fm.createDirectory(at: legacyBoot, withIntermediateDirectories: true)
            try "<settings><setting name=\"boot_script\">eden-start.txt</setting></settings>\n".write(
                to: legacyBoot.appendingPathComponent("eden.xml"), atomically: true, encoding: .utf8)
            let legacyInstall = Install(wrapper: root.appendingPathComponent("legacy-wrapper.app"),
                                        prefixName: "legacy-prefix", gameDirOverride: legacyGame)
            checks.append(("Ashita v3 INI server profile resolves to its XML profile",
                           legacyInstall.bootProfileName("eden.ini") == "eden.xml"))
            checks.append(("Ashita v3 XML selects its configured boot script",
                           Narration.scriptName(in: legacyInstall, profile: "eden.ini") == "eden-start.txt"))
            checks.append(("addon manager targets the Ashita v3 boot script",
                           AddonSuite.scriptURL(legacyInstall, profile: "eden.ini").lastPathComponent == "eden-start.txt"))
        } catch {
            checks.append(("profile fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }

        try? fm.removeItem(at: root)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runAddonScrubSelfTest() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-addon-scrub-\(UUID().uuidString)")
        let game = root.appendingPathComponent("game", isDirectory: true)
        let addonRoot = game.appendingPathComponent("addons", isDirectory: true)
        let scripts = game.appendingPathComponent("scripts", isDirectory: true)
        let boot = game.appendingPathComponent("config/boot", isDirectory: true)
        let script = scripts.appendingPathComponent("lsb.txt")
        let install = Install(wrapper: root.appendingPathComponent("wrapper.app"),
                              prefixName: "prefix", gameDirOverride: game)
        var checks: [(String, Bool)] = []

        do {
            try fm.createDirectory(at: addonRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            try fm.createDirectory(at: boot, withIntermediateDirectories: true)
            try Data().write(to: game.appendingPathComponent("Ashita-cli.exe"))
            try "script=lsb.txt\n".write(to: boot.appendingPathComponent("lsb.ini"), atomically: true, encoding: .utf8)

            func seed() throws {
                try fm.createDirectory(at: addonRoot.appendingPathComponent("vanavoice"), withIntermediateDirectories: true)
                try fm.createDirectory(at: addonRoot.appendingPathComponent("Vanaguide"), withIntermediateDirectories: true)
                try "/addon load vanavoice\n/addon load vanaguide\n# player command\n"
                    .write(to: script, atomically: true, encoding: .utf8)
            }

            func checkScrub(_ label: String, policy: AddonPolicy) throws {
                try seed()
                Narration.prepare(install, enabled: true, policy: policy, profile: "lsb.ini") { _ in }
                Guide.prepare(install, enabled: true, policy: policy, profile: "lsb.ini") { _ in }
                let text = Credentials.readFile(at: script) ?? ""
                checks.append(("\(label): narrator directory is removed",
                               !fm.fileExists(atPath: addonRoot.appendingPathComponent("vanavoice").path)))
                checks.append(("\(label): guide directory is removed",
                               !fm.fileExists(atPath: addonRoot.appendingPathComponent("Vanaguide").path)))
                checks.append(("\(label): active boot script is scrubbed without losing user commands",
                               !text.contains("/addon load vanavoice")
                                   && !text.contains("/addon load vanaguide")
                                   && text.contains("# player command")))
            }

            try checkScrub("unknown policy", policy: .unknown)
            try checkScrub("hosted allowlist", policy: .allowlist([], source: "offline fixture"))
        } catch {
            checks.append(("scrub fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }

        try? fm.removeItem(at: root)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runAddonInstallSelfTest() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-addon-install-\(UUID().uuidString)")
        let game = root.appendingPathComponent("game", isDirectory: true)
        let scripts = game.appendingPathComponent("scripts", isDirectory: true)
        let boot = game.appendingPathComponent("config/boot", isDirectory: true)
        let defaultScript = scripts.appendingPathComponent("default.txt")
        let worldScript = scripts.appendingPathComponent("lsb.txt")
        let tempAudio = root.appendingPathComponent("speech-queue", isDirectory: true)
        let install = Install(wrapper: root.appendingPathComponent("wrapper.app"),
                              prefixName: "prefix", gameDirOverride: game)
        var checks: [(String, Bool)] = []
        var launchRequests = 0

        do {
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            try fm.createDirectory(at: boot, withIntermediateDirectories: true)
            try Data().write(to: game.appendingPathComponent("Ashita-cli.exe"))
            try "script=lsb.txt\n".write(to: boot.appendingPathComponent("lsb.ini"), atomically: true, encoding: .utf8)
            try "# default sentinel\n".write(to: defaultScript, atomically: true, encoding: .utf8)
            try "# player command\n".write(to: worldScript, atomically: true, encoding: .utf8)

            Narration.prepare(install, enabled: true, policy: AddonPolicies.localWorld,
                              profile: "lsb.ini", temporaryDirectory: tempAudio,
                              launch: { launchRequests += 1 }, log: { _ in })
            Guide.prepare(install, enabled: true, policy: AddonPolicies.localWorld,
                          profile: "lsb.ini", log: { _ in })

            let text = Credentials.readFile(at: worldScript) ?? ""
            checks.append(("local policy installs the bundled/development VanaVoice addon",
                           fm.fileExists(atPath: game.appendingPathComponent("addons/vanavoice/vanavoice.lua").path)))
            checks.append(("local policy installs Vanaguide",
                           fm.fileExists(atPath: game.appendingPathComponent("addons/Vanaguide/Vanaguide.lua").path)))
            checks.append(("both addons load from the active local boot script",
                           text.contains("/addon load vanavoice") && text.contains("/addon load vanaguide")))
            checks.append(("user script content and default.txt are preserved",
                           text.contains("# player command")
                               && Credentials.readFile(at: defaultScript) == "# default sentinel\n"))
            checks.append(("speech queue uses the injected temporary location",
                           fm.fileExists(atPath: tempAudio.path)))
            checks.append(("helper launch is delegated, not started by the self-test",
                           launchRequests == (Narration.narratorAvailable ? 1 : 0)))
        } catch {
            checks.append(("local addon installation fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }

        try? fm.removeItem(at: root)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runCursorFixSelfTest() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-cursor-fix-\(UUID().uuidString)")
        let game = root.appendingPathComponent("game", isDirectory: true)
        let scripts = game.appendingPathComponent("scripts", isDirectory: true)
        let boot = game.appendingPathComponent("config/boot", isDirectory: true)
        let script = scripts.appendingPathComponent("lsb.txt")
        let addon = game.appendingPathComponent("addons/winecursor", isDirectory: true)
        let install = Install(wrapper: root.appendingPathComponent("wrapper.app"),
                              prefixName: "Fixture", gameDirOverride: game)
        var checks: [(String, Bool)] = []

        do {
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            try fm.createDirectory(at: boot, withIntermediateDirectories: true)
            try Data().write(to: game.appendingPathComponent("Ashita-cli.exe"))
            try "script=lsb.txt\n".write(to: boot.appendingPathComponent("lsb.ini"),
                                          atomically: true, encoding: .utf8)
            try "# player command\n".write(to: script, atomically: true, encoding: .utf8)
            CursorFix.prepare(install, policy: AddonPolicies.localWorld, profile: "lsb.ini") { _ in }
            let localText = Credentials.readFile(at: script) ?? ""
            checks.append(("local policy stages the complete cursor addon",
                           fm.fileExists(atPath: addon.appendingPathComponent("winecursor.lua").path)))
            checks.append(("local policy loads cursor addon from selected profile",
                           localText.contains(CursorFix.loadLine)))
            checks.append(("local policy preserves existing profile commands",
                           localText.contains("# player command")))

            CursorFix.prepare(install, policy: .unknown, profile: "lsb.ini") { _ in }
            let unknownText = Credentials.readFile(at: script) ?? ""
            checks.append(("unknown policy removes cursor addon folder",
                           !fm.fileExists(atPath: addon.path)))
            checks.append(("unknown policy removes load line and preserves user text",
                           !unknownText.contains(CursorFix.loadLine)
                               && unknownText.contains("# player command")))

            CursorFix.prepare(install, policy: AddonPolicies.localWorld, profile: "lsb.ini") { _ in }
            CursorFix.prepare(install, policy: AddonPolicies.horizon, profile: "lsb.ini") { _ in }
            let hostedText = Credentials.readFile(at: script) ?? ""
            checks.append(("hosted allowlist removes cursor addon folder",
                           !fm.fileExists(atPath: addon.path)))
            checks.append(("hosted allowlist removes cursor load line and preserves user text",
                           !hostedText.contains(CursorFix.loadLine)
                               && hostedText.contains("# player command")))
        } catch {
            checks.append(("cursor fix fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }
        try? fm.removeItem(at: root)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runGuideDisabledSelfTest() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-guide-disabled-\(UUID().uuidString)")
        let game = root.appendingPathComponent("game", isDirectory: true)
        let scripts = game.appendingPathComponent("scripts", isDirectory: true)
        let addons = game.appendingPathComponent("addons", isDirectory: true)
        let dest = addons.appendingPathComponent(Guide.addonDirName, isDirectory: true)
        let boot = game.appendingPathComponent("config/boot", isDirectory: true)
        var checks: [(String, Bool)] = []

        do {
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            try fm.createDirectory(at: boot, withIntermediateDirectories: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try Data().write(to: game.appendingPathComponent("Ashita-cli.exe"))
            try "script=lsb.txt\n".write(to: boot.appendingPathComponent("lsb.ini"),
                                            atomically: true, encoding: .utf8)
            try "# player command\n\(Guide.marker)\n\(Guide.loadLine)\n".write(
                to: scripts.appendingPathComponent("lsb.txt"), atomically: true, encoding: .utf8)
            try "addon.name = 'Vanaguide'\n".write(
                to: dest.appendingPathComponent("Vanaguide.lua"), atomically: true, encoding: .utf8)
            let install = Install(wrapper: root.appendingPathComponent("wrapper.app"),
                                  prefixName: "Fixture", gameDirOverride: game)
            var logs: [String] = []
            Guide.prepare(install, enabled: false, policy: AddonPolicies.localWorld,
                          profile: "lsb.ini") { logs.append($0) }
            let text = Credentials.readFile(at: scripts.appendingPathComponent("lsb.txt")) ?? ""
            checks.append(("disabled guide removes copied addon folder",
                           !fm.fileExists(atPath: dest.path)))
            checks.append(("disabled guide removes load line and marker",
                           !text.contains(Guide.loadLine) && !text.contains(Guide.marker)))
            checks.append(("disabled guide preserves unrelated startup commands",
                           text.contains("# player command")))
            checks.append(("disabled guide logs when stale addon is removed",
                           logs.contains(where: { $0.contains("vanaguide: off") })))
        } catch {
            checks.append(("disabled-guide fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }

        try? fm.removeItem(at: root)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runNarrationDisabledSelfTest() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hxi-narration-disabled-\(UUID().uuidString)")
        let game = root.appendingPathComponent("game", isDirectory: true)
        let scripts = game.appendingPathComponent("scripts", isDirectory: true)
        let dest = game.appendingPathComponent("addons/vanavoice", isDirectory: true)
        let boot = game.appendingPathComponent("config/boot", isDirectory: true)
        let queueDir = root.appendingPathComponent("speech-queue", isDirectory: true)
        var checks: [(String, Bool)] = []

        do {
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            try fm.createDirectory(at: boot, withIntermediateDirectories: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try Data().write(to: game.appendingPathComponent("Ashita-cli.exe"))
            try "script=lsb.txt\n".write(to: boot.appendingPathComponent("lsb.ini"),
                                            atomically: true, encoding: .utf8)
            try "# player command\n\(Narration.marker)\n\(Narration.loadLine)\n".write(
                to: scripts.appendingPathComponent("lsb.txt"), atomically: true, encoding: .utf8)
            try "addon.name = 'vanavoice'\n".write(
                to: dest.appendingPathComponent("vanavoice.lua"), atomically: true, encoding: .utf8)
            let install = Install(wrapper: root.appendingPathComponent("wrapper.app"),
                                  prefixName: "Fixture", gameDirOverride: game)
            var logs: [String] = []
            Narration.prepare(install, enabled: false, policy: AddonPolicies.localWorld,
                              profile: "lsb.ini", temporaryDirectory: queueDir,
                              launch: {}, log: { logs.append($0) })
            let text = Credentials.readFile(at: scripts.appendingPathComponent("lsb.txt")) ?? ""
            checks.append(("disabled narrator removes copied addon folder",
                           !fm.fileExists(atPath: dest.path)))
            checks.append(("disabled narrator removes load line and marker",
                           !text.contains(Narration.loadLine) && !text.contains(Narration.marker)))
            checks.append(("disabled narrator preserves unrelated startup commands",
                           text.contains("# player command")))
            checks.append(("disabled narrator does not create speech queue or launch helper",
                           !fm.fileExists(atPath: queueDir.path)))
            checks.append(("disabled narrator logs when stale addon is removed",
                           logs.contains(where: { $0.contains("narration: off") })))
        } catch {
            checks.append(("disabled-narration fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }

        try? fm.removeItem(at: root)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// docs/MULTI_WORLD.md, Tests. Everything runs on canned `pgrep` output and a temp fixture;
    /// nothing is scanned, launched or stopped, so it is safe while somebody is playing.
    @MainActor private static func runMultiWorldSelfTest() -> Never {
        let fm = FileManager.default
        var checks: [(String, Bool)] = []
        // `ps -axww -o pid=,pgid=,command=`: pid, process group, command line.
        let canned = """
            57992 57810 .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture
            57994 57810 /Applications/FFXI-on-Mac.app/Contents/Resources/x87sidecar-coop --cooperative /Users/x/Library/Application Support/BatesAI/ffxi-runtime/wine-coop/wine/lib/wine/x86_64-unix/wine .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture
            57827 57827 C:\\windows\\system32\\services.exe
            61001 61000 .\\\\bootloader\\\\horizon-loader.exe --server localhost --user local
            61003 61002 C:\\Eden\\Ashita\\ffxi-bootmod\\xiloader.exe --server=PLAY.EDENXI.COM
            61010 61009 C:\\CatsEye\\pol.exe
            61020 61019 /bin/sh -c while /usr/bin/pgrep -qf horizon-loader.exe ; do /bin/sleep 2; done
            61030 61029 grep horizon-loader.exe notes.txt
            """
        let snap = LiveClients.parse(canned)
        let live = snap.byHost
        checks.append(("host extraction: loader and its x87 sidecar file under one host",
                       live["play.horizonxi.com"] == [57992, 57994]))
        checks.append(("host extraction: localhost is the local world's 127.0.0.1",
                       live["127.0.0.1"] == [61001]))
        checks.append(("host extraction: --server=HOST form, case-folded",
                       live["play.edenxi.com"] == [61003]))
        checks.append(("host extraction: a loader with no --server is live under an unknown host",
                       live[""] == [61010]))
        checks.append(("host extraction: shells, greps and wine services are not clients",
                       live.values.allSatisfy { !$0.contains(61020) && !$0.contains(61030) && !$0.contains(57827) }))

        let horizon = Server.all.first { $0.name == "HorizonXI" }
        let local = Server.all.first(where: \.local)
        let catseye = Server.all.first { $0.name == "CatsEyeXI" }
        func refusal(_ s: Server?, _ clients: [LiveClients.Client], own: Set<pid_t> = []) -> String? {
            s.flatMap { MultiWorld.refusal(world: $0.name, hosts: [$0.host], maxClients: $0.maxClients,
                                           clients: clients, sessionGroups: own) }
        }
        let dup = refusal(horizon, snap.clients)
        checks.append(("duplicate HorizonXI is refused, naming the running pid",
                       horizon?.allowsMultipleClients == false && dup?.contains("57992") == true))
        checks.append(("the local world may run twice", local?.allowsMultipleClients == true
                           && refusal(local, snap.clients, own: [61000, 70000]) == nil))
        let onlyLocal = LiveClients.parse("61001 61000 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1\n").clients
        checks.append(("a different world is not a duplicate", refusal(horizon, onlyLocal) == nil))
        checks.append(("a boot profile --server that differs from the Host field still counts",
                       horizon.flatMap { MultiWorld.refusal(world: $0.name, hosts: ["play.example.org", "127.0.0.1"],
                                                            maxClients: 1, clients: onlyLocal) } != nil))
        checks.append(("a session of this window that is still injecting counts as a copy",
                       refusal(horizon, [], own: [-1]) != nil))
        checks.append(("only the local world and CatsEyeXI (cited rules) allow several clients",
                       Server.all.filter(\.allowsMultipleClients).map(\.name).sorted()
                           == ["CatsEyeXI", "Local server"]))
        let oneCats = LiveClients.parse("62001 62000 C:\\CatsEye\\xiloader.exe --server server.catseyexi.com\n"
                                        + "62002 62000 /x/x87sidecar-coop --cooperative /x/wine C:\\CatsEye\\xiloader.exe --server server.catseyexi.com\n").clients
        let twoCats = oneCats + LiveClients.parse("63001 63000 C:\\CatsEye\\xiloader.exe --server server.catseyexi.com\n").clients
        checks.append(("CatsEyeXI: a second client is allowed (a sidecar is not a second client)",
                       catseye?.maxClients == 2 && refusal(catseye, oneCats) == nil))
        checks.append(("CatsEyeXI: a third client is refused (their two-character cap)",
                       refusal(catseye, twoCats)?.contains("at most 2") == true))

        // Two local-world sessions in one prefix: A launched first (group 71000), then B (72000).
        let twoLocal = LiveClients.parse("""
            71001 71000 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1 --user a
            71002 71000 /x/x87sidecar-coop --cooperative /x/wine .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1 --user a
            72001 72000 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1 --user b
            72002 72000 /x/x87sidecar-coop --cooperative /x/wine .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1 --user b
            """)
        checks.append(("stop/watch on the first of two local sessions sees only its own pids",
                       MultiWorld.sessionPIDs(group: 71000, host: "127.0.0.1", preexisting: [],
                                              otherGroups: [72000], in: twoLocal) == [71001, 71002]))
        checks.append(("the second local session sees only its own pids",
                       MultiWorld.sessionPIDs(group: 72000, host: "127.0.0.1", preexisting: [71001, 71002],
                                              otherGroups: [71000], in: twoLocal) == [72001, 72002]))
        checks.append(("with its group unknown, a session still leaves other sessions' clients alone",
                       MultiWorld.sessionPIDs(group: nil, host: "127.0.0.1", preexisting: [],
                                              otherGroups: [72000], in: twoLocal) == [71001, 71002]))
        // wine moved the loader into a group of its own (setsid): the spawn group 75000 is empty.
        let moved = LiveClients.parse("75101 75101 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1 --user c\n"
                                      + "71001 71000 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1 --user a\n")
        checks.append(("a loader that left its spawn group is still found by host, other sessions excluded",
                       MultiWorld.sessionPIDs(group: 75000, groupHeldLoader: false, host: "127.0.0.1",
                                              preexisting: [], otherGroups: [71000], in: moved) == [75101]))
        checks.append(("once its group has held the loader, an empty group means the client exited",
                       MultiWorld.sessionPIDs(group: 75000, groupHeldLoader: true, host: "127.0.0.1",
                                              preexisting: [], otherGroups: [71000], in: moved).isEmpty
                           && MultiWorld.groupHoldsLoader(71000, in: moved)
                           && !MultiWorld.groupHoldsLoader(73000, in: LiveClients.parse(
                               "73001 73000 /x/wine C:\\HorizonXI\\Ashita-cli.exe horizonxi.ini\n"))))
        let unlisted = LiveClients.parse("74001 74000 C:\\Game\\mystery-loader.exe --server x\n")
        checks.append(("a session's group covers a loader name this launcher does not know",
                       MultiWorld.sessionPIDs(group: 74000, host: "x", preexisting: [], otherGroups: [],
                                              in: unlisted) == [74001]))

        let injecting = LiveClients.parse("""
            73001 73000 /x/wine/bin/wine C:\\HorizonXI\\Ashita-cli.exe horizonxi.ini
            73002 73000 C:\\Eden\\injector.exe eden.xml
            """).clients
        checks.append(("an injector is a live client under the unknown host, before its loader exists",
                       injecting.map(\.pid) == [73001, 73002] && injecting.allSatisfy { $0.injecting && $0.host.isEmpty }))
        checks.append(("an injector carries the boot profile it is starting",
                       injecting.map(\.bootFile) == ["horizonxi.ini", "eden.xml"]))

        // Another launcher process is in its injector phase: its Runner.playing is not ours to
        // see, and the scan shows only its injector. A duplicate must still be refused.
        let otherInjecting = LiveClients.parse("81001 81000 /x/wine/bin/wine C:\\HorizonXI\\Ashita-cli.exe horizonxi.ini\n").clients
        let bootHosts = ["horizonxi.ini": "play.horizonxi.com", "lsb.ini": "127.0.0.1"]
        func refusalSeeing(_ s: Server?, _ clients: [LiveClients.Client], own: Set<pid_t> = [],
                           ownGroups: Set<pid_t> = [], resolve: [String: String] = bootHosts) -> String? {
            s.flatMap { MultiWorld.refusal(world: $0.name, hosts: [$0.host], maxClients: $0.maxClients,
                                           clients: clients, sessionGroups: own, ownGroups: ownGroups,
                                           injectorHost: { resolve[$0] }) }
        }
        checks.append(("another launcher's injector for HorizonXI (scan shows only it) refuses a duplicate",
                       refusalSeeing(horizon, otherInjecting)?.contains("81001") == true))
        checks.append(("that injector is not a duplicate of a different world",
                       refusalSeeing(local, otherInjecting) == nil))
        checks.append(("an injector whose world cannot be told holds off a one-client world for a few seconds",
                       refusalSeeing(horizon, otherInjecting, resolve: [:])?.contains("few seconds") == true))
        checks.append(("... but not a world without a cap, nor when it is one of this window's own sessions",
                       refusalSeeing(local, otherInjecting, resolve: [:]) == nil
                           && refusalSeeing(horizon, otherInjecting, ownGroups: [81000], resolve: [:]) == nil))
        let injectorAndLoader = otherInjecting
            + LiveClients.parse("81002 81000 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1\n").clients
        checks.append(("an unresolved injector whose group already shows a loader is that loader's world",
                       refusalSeeing(horizon, injectorAndLoader, resolve: [:]) == nil))
        let catsInjecting = LiveClients.parse("82001 82000 /x/wine C:\\CatsEye\\Ashita-cli.exe catseye.ini\n").clients
        checks.append(("CatsEyeXI: one running plus another launcher's injector for it is at the cap of two",
                       refusalSeeing(catseye, oneCats + catsInjecting,
                                     resolve: ["catseye.ini": "server.catseyexi.com"])?.contains("at most 2") == true))
        checks.append(("a launch while another world is injecting treats the prefix as in use",
                       MultiWorld.clientsLive(injecting, otherSessionsPlaying: 0)))
        checks.append(("a launch while another session of this window is playing but not yet visible treats the prefix as in use",
                       MultiWorld.clientsLive([], otherSessionsPlaying: 1)
                           && !MultiWorld.clientsLive([], otherSessionsPlaying: 0)))
        checks.append(("the last Stop takes the wineserver down only when nothing else holds the prefix",
                       MultiWorld.mayStopWineserver([], otherSessionsPlaying: 0, launchUnderWay: false)
                           && !MultiWorld.mayStopWineserver(injecting, otherSessionsPlaying: 0, launchUnderWay: false)
                           && !MultiWorld.mayStopWineserver([], otherSessionsPlaying: 1, launchUnderWay: false)
                           && !MultiWorld.mayStopWineserver([], otherSessionsPlaying: 0, launchUnderWay: true)))
        checks.append(("the Running list shows clients another launcher started, not this window's",
                       MultiWorld.elsewhere(snap.clients, ownGroups: [57810], ownHostsWithoutGroup: ["play.edenxi.com"])
                           == ["127.0.0.1": [61001], "": [61010]]))

        checks.append(("Repair/Update wait for clients, for this window's starting sessions and for a held lock",
                       MultiWorld.maintenanceBlocker([:], sessionsPlaying: 0, lockHeldElsewhere: false) == nil
                           && MultiWorld.maintenanceBlocker(["": [73001]], sessionsPlaying: 0, lockHeldElsewhere: false) != nil
                           && MultiWorld.maintenanceBlocker([:], sessionsPlaying: 1, lockHeldElsewhere: false) != nil
                           && MultiWorld.maintenanceBlocker([:], sessionsPlaying: 0, lockHeldElsewhere: true) != nil))

        // msync/esync are the wineserver's: a second world must match it, or be refused.
        let prefixPath = "/Volumes/x10/Video Games/wrapper.app/Contents/SharedSupport/prefix10"
        let serverEnv = "/x/wine/bin/wineserver HOME=/Users/x WINEPREFIX=\(prefixPath) WINEESYNC=0 WINEMSYNC=1 PATH=/usr/bin"
        let wsSnap = LiveClients.parse("57821 57821 /Users/x/Library/Application Support/wine/bin/wineserver\n")
        checks.append(("a wineserver is recorded, not taken for a client, even with spaces in its path",
                       wsSnap.wineservers == [57821] && wsSnap.clients.isEmpty))
        checks.append(("the running wineserver's sync mode is read from its environment, for this prefix only",
                       MultiWorld.syncMode(wineserverEnv: serverEnv, prefix: prefixPath) == .msync
                           && MultiWorld.syncMode(wineserverEnv: serverEnv, prefix: "/other/prefix") == nil
                           && MultiWorld.syncMode(wineserverEnv: serverEnv.replacingOccurrences(of: "WINEMSYNC=1", with: "WINEMSYNC=0"),
                                                  prefix: prefixPath) == .off))
        let gaiaNext = MultiWorld.syncDecision(want: .off, running: .msync, msyncAllowed: false, world: "Gaia XI")
        let msyncNext = MultiWorld.syncDecision(want: .msync, running: .off, msyncAllowed: true, world: "Local server")
        checks.append(("a msync-off world next to a msync wineserver is refused; any other world matches the server",
                       gaiaNext.refusal?.contains("msync off") == true
                           && msyncNext.refusal == nil && msyncNext.use == .off
                           && MultiWorld.syncDecision(want: .off, running: .msync, msyncAllowed: true, world: "x").use == .msync
                           && MultiWorld.syncDecision(want: .msync, running: nil, msyncAllowed: true, world: "x").use == .msync))

        // Quote-aware: wine quotes a program path with spaces, and a quoted word is one word.
        checks.append(("tokenising keeps a quoted run as one word, quotes removed",
                       LiveClients.tokenize("\"a b\" c \"\"  d") == ["a b", "c", "", "d"]))
        let quoted = LiveClients.parse("""
            91001 91000 "Z:\\Volumes\\x10\\Video Games\\Eden\\Ashita\\injector.exe" eden.xml
            91011 91010 "Z:\\Volumes\\x10\\Video Games\\Eden\\Ashita\\ffxi-bootmod\\xiloader.exe" --server "PLAY.EDENXI.COM" --user x
            91021 91020 Z:\\Volumes\\x10\\Video Games\\HorizonXI\\Ashita-cli.exe horizonxi.ini
            91031 91030 /x/x87sidecar-coop --cooperative /x/wine "C:\\Program Files\\Eden\\injector.exe" "eden big.xml"
            91041 91040 "C:\\Program Files\\HorizonXI\\bootloader\\horizon-loader.exe" --server play.horizonxi.com
            91051 91050 /bin/echo "C:\\Games\\Video Games\\injector.exe" eden.xml
            """).clients
        func q(_ pid: pid_t) -> LiveClients.Client? { quoted.first { $0.pid == pid } }
        checks.append(("a quoted injector path with spaces is an injector, with its boot profile",
                       q(91001)?.injecting == true && q(91001)?.bootFile == "eden.xml"
                           && q(91031)?.injecting == true && q(91031)?.bootFile == "eden big.xml"))
        checks.append(("an unquoted Windows injector path with spaces is still an injector",
                       q(91021)?.injecting == true && q(91021)?.bootFile == "horizonxi.ini"))
        checks.append(("a quoted loader path with spaces is a loader, with its (quoted) --server",
                       q(91011)?.host == "play.edenxi.com" && q(91011)?.injecting == false
                           && q(91041)?.host == "play.horizonxi.com" && q(91041)?.other == false))
        checks.append(("a Mac command that only mentions a quoted .exe is not a client", q(91051) == nil))

        // Any Windows program holds the prefix, not only the loaders named in LiveClients.
        // wine's own, as read with ps under the live wineserver on 2026-09-26 (trailing space
        // and all), are not clients.
        let wineOwn = LiveClients.parse("""
            57821 57821 /Users/x/Library/Application Support/BatesAI/ffxi-runtime/wine-coop/wine/lib/wine/../../bin/wineserver
            57827 57827 C:\\windows\\system32\\services.exe\u{20}
            57836 57836 C:\\windows\\system32\\winedevice.exe\u{20}
            57840 57840 C:\\windows\\system32\\plugplay.exe\u{20}
            57847 57847 C:\\windows\\system32\\svchost.exe -k LocalServiceNetworkRestricted\u{20}
            57851 57851 C:\\windows\\system32\\winedevice.exe\u{20}
            57864 57864 C:\\windows\\system32\\rpcss.exe\u{20}
            58006 58006 C:\\windows\\system32\\explorer.exe /desktop\u{20}
            """)
        checks.append(("wine's own programs are not clients: the last Stop may take the wineserver down",
                       wineOwn.clients.isEmpty && !MultiWorld.clientsLive(wineOwn.clients, otherSessionsPlaying: 0)
                           && MultiWorld.mayStopWineserver(wineOwn.clients, otherSessionsPlaying: 0, launchUnderWay: false)
                           && wineOwn.wine.isSuperset(of: [57821, 57827, 58006])))
        let mystery = LiveClients.parse("""
            93001 93000 .\\\\bootloader\\\\mystery-loader.exe --user x
            93002 93000 /x/x87sidecar-coop --cooperative /x/wine .\\\\bootloader\\\\mystery-loader.exe --user x
            """)
        checks.append(("a loader under an unknown name is live: no wineserver -k, renderer and sync gated",
                       mystery.clients.map(\.pid) == [93001, 93002] && mystery.clients.allSatisfy(\.other)
                           && MultiWorld.clientsLive(mystery.clients, otherSessionsPlaying: 0)
                           && !MultiWorld.mayStopWineserver(mystery.clients, otherSessionsPlaying: 0, launchUnderWay: false)
                           && !LiveClients.byHost(mystery.clients).isEmpty))
        checks.append(("... but with no --server its world is unknown: not a duplicate, not in the Running list",
                       refusal(horizon, mystery.clients) == nil
                           && MultiWorld.elsewhere(mystery.clients, ownGroups: [], ownHostsWithoutGroup: []).isEmpty
                           && !MultiWorld.groupHoldsLoader(93000, in: mystery)))
        let mysteryWithHost = LiveClients.parse("95001 95000 C:\\Game\\mystery-loader.exe --server play.horizonxi.com\n")
        checks.append(("an unknown program given --server is that world's loader",
                       refusal(horizon, mysteryWithHost.clients)?.contains("95001") == true
                           && MultiWorld.groupHoldsLoader(95000, in: mysteryWithHost)))
        let lookalike = LiveClients.parse("""
            94001 94000 C:\\Games\\explorer.exe
            94011 94010 "C:\\Program Files\\Tools\\svchost.exe" -k x
            """).clients
        checks.append(("a game program sharing a wine program's name, outside C:\\windows, still counts",
                       lookalike.map(\.pid) == [94001, 94011] && MultiWorld.clientsLive(lookalike, otherSessionsPlaying: 0)))

        // Stop signals only what is provably still this session's.
        let stopSnap = LiveClients.parse("""
            96001 96000 /x/wine C:\\HorizonXI\\Ashita-cli.exe horizonxi.ini
            96002 96000 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1
            96003 96003 /usr/bin/vim notes.txt
            96004 96000 /bin/sleep 5
            97001 97000 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1
            98001 98000 /x/wine C:\\Other\\Ashita-cli.exe other.ini
            """)
        checks.append(("Stop signals this session's wine processes, never a reused pid, a non-wine process or another session's",
                       MultiWorld.signalable([96001, 96002, 96003, 96004, 97001, 98001, 99999], group: 96000,
                                             host: "127.0.0.1", otherGroups: [97000], in: stopSnap)
                           == [96001: 96000, 96002: 96000]))
        checks.append(("with no group, Stop signals only its host's loaders outside other sessions' groups",
                       MultiWorld.signalable([96002, 97001, 96003, 98001], group: nil, host: "127.0.0.1",
                                             otherGroups: [97000], in: stopSnap) == [96002: 96000]))
        let reused = LiveClients.parse("96002 96002 /usr/bin/vim notes.txt\n")
        checks.append(("the SIGKILL re-check refuses a pid that is no longer the same wine process",
                       MultiWorld.stillSignalable(96002, group: 96000, in: stopSnap)
                           && !MultiWorld.stillSignalable(96002, group: 96000, in: reused)
                           && !MultiWorld.stillSignalable(96002, group: 96000, in: LiveClients.Snapshot())))

        let lockFile = fm.temporaryDirectory.appendingPathComponent("hxi-multiworld-\(UUID().uuidString).lock")
        if let held = LaunchLock.acquire(at: lockFile) {
            let second = LaunchLock.acquire(at: lockFile)
            LaunchLock.release(held)
            let again = LaunchLock.acquire(at: lockFile)
            checks.append(("the launch lock refuses a second holder and frees on release",
                           second == nil && again != nil))
            if let again { LaunchLock.release(again) }
            if let second { LaunchLock.release(second) }
            // Handed-off hold: a spawn that is already gone lets the lock go (read-only scan).
            if let held2 = LaunchLock.acquire(at: lockFile) {
                LaunchLock.release(held2, whenVisible: 999_999, group: nil, timeout: 5)
                var freed: Int32? = nil
                for _ in 0..<60 where freed == nil {
                    usleep(100_000)
                    freed = LaunchLock.acquire(at: lockFile)
                }
                checks.append(("a launch's handed-off lock is let go once its spawn is gone", freed != nil))
                if let freed { LaunchLock.release(freed) }
            }
        } else {
            checks.append(("the launch lock refuses a second holder and frees on release", false))
        }
        try? fm.removeItem(at: lockFile)

        checks.append(("renderer step is skip, not stop-and-apply, while a client is live",
                       RendererSetup.step(for: .metal, current: .metal, clientsLive: true) == .skip))
        checks.append(("renderer step with an unreadable prefix and a live client is still skip",
                       RendererSetup.step(for: .metal, current: nil, clientsLive: true) == .skip))
        if case .refuse(let why) = RendererSetup.step(for: .openGL, current: .metal, clientsLive: true) {
            checks.append(("renderer change under a live client is refused with the design's message",
                           why.contains(RendererSetup.refuseChangeMessage)))
        } else {
            checks.append(("renderer change under a live client is refused with the design's message", false))
        }
        checks.append(("renderer step with nothing live stops and applies",
                       RendererSetup.step(for: .openGL, current: .metal, clientsLive: false) == .stopAndApply))
        let userReg = """
            [Software\\\\Wine\\\\Direct3D] 1786416352
            #time=1dd293b86547c74
            "MaxVersionGL"=dword:00040001
            "renderer"="gl"

            [Software\\\\Wine\\\\DllOverrides] 1790361829
            "*d3d8"="native"
            "*d3d9"="native"
            """
        checks.append(("prefix renderer read from user.reg: DXVK overrides mean Metal",
                       RendererSetup.renderer(fromUserReg: userReg) == .metal))
        checks.append(("prefix renderer read from user.reg: gl without overrides means Classic",
                       RendererSetup.renderer(fromUserReg: "[Software\\\\Wine\\\\Direct3D] 1\n\"renderer\"=\"gl\"\n") == .openGL))

        checks.append(("FPS logs are per world",
                       MultiWorld.fpsLogPath(gameDirName: "HorizonXI", world: "HorizonXI") == "C:\\HorizonXI\\fps-horizonxi.csv"
                           && MultiWorld.fpsLogPath(gameDirName: "HorizonXI", world: "Local server") == "C:\\HorizonXI\\fps-local-server.csv"))
        checks.append(("memory warning at >60% swap or <20% free, silent otherwise",
                       MultiWorld.memoryWarning(swapUsedFraction: 0.64, freePercent: 46) != nil
                           && MultiWorld.memoryWarning(swapUsedFraction: 0.2, freePercent: 15) != nil
                           && MultiWorld.memoryWarning(swapUsedFraction: 0.6, freePercent: 20) == nil))

        let sessions = Sessions()
        let first = sessions.runner(for: "Local server")
        first.running = true   // as if its client were playing; nothing is launched
        let second = sessions.newSession(for: "Local server")
        checks.append(("a world's session is reused", sessions.runner(for: "HorizonXI") === sessions.runner(for: "HorizonXI")))
        checks.append(("a second local client gets its own session, and Play/Stop/log follow it",
                       second !== first && second.session == "Local server #2"
                           && sessions.runner(for: "Local server") === second))
        checks.append(("sessions are per world", sessions.runner(for: "HorizonXI") !== first))

        let root = fm.temporaryDirectory.appendingPathComponent("hxi-multiworld-\(UUID().uuidString)")
        let game = root.appendingPathComponent("game", isDirectory: true)
        let scripts = game.appendingPathComponent("scripts", isDirectory: true)
        let boot = game.appendingPathComponent("config/boot", isDirectory: true)
        let addons = game.appendingPathComponent("addons", isDirectory: true)
        let script = scripts.appendingPathComponent("horizon.txt")
        let install = Install(wrapper: root.appendingPathComponent("wrapper.app"),
                              prefixName: "prefix", gameDirOverride: game)
        do {
            try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            try fm.createDirectory(at: boot, withIntermediateDirectories: true)
            try Data().write(to: game.appendingPathComponent("Ashita-cli.exe"))
            try "script=horizon.txt\n".write(to: boot.appendingPathComponent("horizonxi.ini"),
                                              atomically: true, encoding: .utf8)
            for (dir, file) in [("vanavoice", "vanavoice.lua"), (Guide.addonDirName, "Vanaguide.lua"),
                                (CursorFix.addonDirName, "winecursor.lua")] {
                try fm.createDirectory(at: addons.appendingPathComponent(dir), withIntermediateDirectories: true)
                try Data().write(to: addons.appendingPathComponent("\(dir)/\(file)"))
            }
            try "# player command\n\(Narration.loadLine)\n\(Guide.loadLine)\n\(CursorFix.loadLine)\n"
                .write(to: script, atomically: true, encoding: .utf8)
            Narration.prepare(install, enabled: true, policy: AddonPolicies.horizon, profile: "horizonxi.ini",
                              temporaryDirectory: root.appendingPathComponent("q"), launch: {},
                              othersLive: true, log: { _ in })
            Guide.prepare(install, enabled: true, policy: AddonPolicies.horizon, profile: "horizonxi.ini",
                          othersLive: true, log: { _ in })
            CursorFix.prepare(install, policy: AddonPolicies.horizon, profile: "horizonxi.ini",
                              othersLive: true, log: { _ in })
            let text = Credentials.readFile(at: script) ?? ""
            checks.append(("addon prepare keeps every addon folder while another host is live",
                           ["vanavoice", Guide.addonDirName, CursorFix.addonDirName].allSatisfy {
                               fm.fileExists(atPath: addons.appendingPathComponent($0).path) }))
            checks.append(("addon prepare still takes this world's load lines out, keeping user text",
                           !text.contains(Narration.loadLine) && !text.contains(Guide.loadLine)
                               && !text.contains(CursorFix.loadLine) && text.contains("# player command")))
            Guide.prepare(install, enabled: true, policy: AddonPolicies.horizon, profile: "horizonxi.ini",
                          othersLive: false, log: { _ in })
            checks.append(("with nothing else live, a strict allowlist world still gets the folder removed",
                           !fm.fileExists(atPath: addons.appendingPathComponent(Guide.addonDirName).path)))

            // The real path: Runner reads the injector's boot profile from the install.
            try "[ashita.boot]\ncommand     = --server play.horizonxi.com --user x --pass y\n"
                .write(to: boot.appendingPathComponent("otherlauncher.ini"), atomically: true, encoding: .utf8)
            let other = LiveClients.parse("83001 83000 /x/wine C:\\HorizonXI\\Ashita-cli.exe otherlauncher.ini\n").clients
            checks.append(("Runner refuses a duplicate while another launcher's HorizonXI is only an injector",
                           Runner.duplicateRefusal(world: "HorizonXI", hosts: ["play.horizonxi.com"], maxClients: 1,
                                                   clients: other, install: install)?.contains("83001") == true
                               && Runner.duplicateRefusal(world: "Local server", hosts: ["127.0.0.1"],
                                                          maxClients: Server.noClientCap,
                                                          clients: other, install: install) == nil))
        } catch {
            checks.append(("multiworld addon fixture setup and execution", false))
            FileHandle.standardError.write(Data("  \(error.localizedDescription)\n".utf8))
        }
        try? fm.removeItem(at: root)

        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        // Read-only (pgrep), for comparing against Activity Monitor; not a check.
        let now = LiveClients.scan()
        print("  i    live on this Mac: \(now.isEmpty ? "none" : Runner.describe(now))")
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
    /// docs/MULTI_WORLD.md, Single instance. Runs entirely in a temporary folder with a
    /// notification name of its own, so it never talks to, detects or disturbs a launcher that
    /// is open: the probes it starts are this binary with `--selftest-single-instance-probe`.
    @MainActor private static func runSingleInstanceSelfTest() -> Never {
        let fm = FileManager.default
        var checks: [(String, Bool)] = []
        let dir = fm.temporaryDirectory.appendingPathComponent("hxi-single-\(UUID().uuidString)", isDirectory: true)
        let name = Notification.Name("org.batesai.horizonxi-on-mac.selftest-\(UUID().uuidString)")
        let reqs = dir.appendingPathComponent("requests", isDirectory: true)
        func waiting() -> [String] {
            ((try? fm.contentsOfDirectory(atPath: reqs.path)) ?? []).filter { !$0.hasPrefix(".") }
        }

        let cmd = LaunchCommand(["/x/FFXI-on-Mac", "--world", "Local server", "--play", "-psn_0_1", "--junk"])
        checks.append(("--world and --play are what is forwarded; anything else is not",
                       cmd == LaunchCommand(world: "Local server", play: true)
                           && cmd.arguments == ["--world", "Local server", "--play"]
                           && LaunchCommand(["/x/FFXI-on-Mac"]).arguments.isEmpty))
        checks.append(("self-tests and --check are exempt; --play and a plain open are not",
                       SingleInstance.isExempt(["x", "--selftest-multiworld"]) && SingleInstance.isExempt(["x", "--check"])
                           && !SingleInstance.isExempt(["x", "--play"]) && !SingleInstance.isExempt(["x"])))

        let first = SingleInstance.claim(dir: dir)
        let second = SingleInstance.claim(dir: dir)
        checks.append(("the instance lock has one holder, which records its pid",
                       first != nil && second == nil && SingleInstance.holderPID(dir: dir) == getpid()))
        if let second { SingleInstance.release(second) }

        let req = SingleInstance.writeRequest(["--play"], dir: dir)
        let mode = req.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber }?.intValue
        let taken = SingleInstance.takeRequests(dir: dir)
        checks.append(("a request is private to this user, taken once, and deleted as it is taken",
                       mode == 0o600 && taken == [["--play"]] && SingleInstance.takeRequests(dir: dir).isEmpty
                           && waiting().isEmpty))
        if let old = SingleInstance.writeRequest(["--play"], dir: dir) {
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: old.path)
        }
        if let open = SingleInstance.writeRequest(["--play"], dir: dir) {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: open.path)
        }
        checks.append(("a stale request, or one others could have written, is thrown away unread",
                       SingleInstance.takeRequests(dir: dir).isEmpty && waiting().isEmpty))

        func probe(_ extra: [String]) -> Process? {
            guard let exe = Bundle.main.executableURL else { return nil }
            let p = Process()
            p.executableURL = exe
            p.arguments = ["--selftest-single-instance-probe", dir.path, name.rawValue] + extra
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            return (try? p.run()) != nil ? p : nil
        }
        /// Keep this run loop turning (the listener's notification and timer) until done.
        func pump(until done: () -> Bool, timeout: TimeInterval = 20) {
            let deadline = Date().addingTimeInterval(timeout)
            while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }

        // 1. A launcher is running (this process holds the lock and listens): a second launch
        //    hands over --world/--play and exits 0 once it is taken.
        var received: [[String]] = []
        SingleInstance.listen(dir: dir, name: name) { received.append($0) }
        if let p = probe(["5", "--world", "Local server", "--play"]) {
            pump(until: { !p.isRunning })
            checks.append(("a second launch forwards --world/--play to the running one and exits 0",
                           !p.isRunning && p.terminationStatus == 0
                               && received == [["--world", "Local server", "--play"]]))
        } else {
            checks.append(("a second launch forwards --world/--play to the running one and exits 0", false))
        }
        // 2. The holder does not answer: nothing is done, the request is withdrawn, exit 1.
        SingleInstance.stopListening()
        if let p = probe(["1", "--play"]) {
            p.waitUntilExit()
            checks.append(("unanswered, a second launch withdraws its request and exits 1 without taking over",
                           p.terminationStatus == 1 && waiting().isEmpty))
        } else {
            checks.append(("unanswered, a second launch withdraws its request and exits 1 without taking over", false))
        }
        if let first { SingleInstance.release(first) }
        // 3. Two launches at once, nothing running: exactly one becomes the launcher (exit 3,
        //    having taken the other's request) and the other forwards to it (exit 0).
        let racers = [probe(["5", "--play"]), probe(["5", "--play"])].compactMap { $0 }
        racers.forEach { $0.waitUntilExit() }
        checks.append(("two launches at once: one launcher, which takes the other's request",
                       racers.count == 2 && racers.map(\.terminationStatus).sorted() == [0, 3]))

        try? fm.removeItem(at: dir)
        let failures = checks.filter { !$0.1 }.count
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// One launch, as `SingleInstance.enforce` would make it, against the self-test's folder:
    /// `<dir> <notification name> <timeout s> [--world <w>] [--play]`. Exit 0 forwarded,
    /// 1 unanswered, 3 became the launcher and took exactly one request in three seconds,
    /// 4 became the launcher and took some other number, 2 bad arguments.
    @MainActor private static func runSingleInstanceProbe(_ args: [String]) -> Never {
        guard args.count >= 3, let timeout = TimeInterval(args[2]) else { exit(2) }
        let dir = URL(fileURLWithPath: args[0], isDirectory: true)
        let name = Notification.Name(args[1])
        switch SingleInstance.claimOrForward(LaunchCommand(Array(args[3...])), dir: dir, name: name,
                                             timeout: timeout) {
        case .forwarded: exit(0)
        case .unanswered: exit(1)
        case .primary(let fd):
            var took = 0
            SingleInstance.listen(dir: dir, name: name) { _ in took += 1 }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            SingleInstance.stopListening()
            SingleInstance.release(fd)
            exit(took == 1 ? 3 : 4)
        }
    }
}
