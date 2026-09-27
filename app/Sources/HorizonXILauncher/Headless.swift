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
        let canned = """
            57992 .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture
            57994 /Applications/FFXI-on-Mac.app/Contents/Resources/x87sidecar-coop --cooperative /Users/x/Library/Application Support/BatesAI/ffxi-runtime/wine-coop/wine/lib/wine/x86_64-unix/wine .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture
            61001 .\\\\bootloader\\\\horizon-loader.exe --server localhost --user local
            61003 C:\\Eden\\Ashita\\ffxi-bootmod\\xiloader.exe --server=PLAY.EDENXI.COM
            61010 C:\\CatsEye\\pol.exe
            61020 /bin/sh -c while /usr/bin/pgrep -qf horizon-loader.exe ; do /bin/sleep 2; done
            61030 grep horizon-loader.exe notes.txt
            """
        let live = LiveClients.parse(canned)
        checks.append(("host extraction: loader and its x87 sidecar file under one host",
                       live["play.horizonxi.com"] == [57992, 57994]))
        checks.append(("host extraction: localhost is the local world's 127.0.0.1",
                       live["127.0.0.1"] == [61001]))
        checks.append(("host extraction: --server=HOST form, case-folded",
                       live["play.edenxi.com"] == [61003]))
        checks.append(("host extraction: a loader with no --server is live under an unknown host",
                       live[""] == [61010]))
        checks.append(("host extraction: shells and greps naming a loader are not clients",
                       live.values.allSatisfy { !$0.contains(61020) && !$0.contains(61030) }))

        let horizon = Server.all.first { $0.name == "HorizonXI" }
        let local = Server.all.first(where: \.local)
        let dup = horizon.flatMap {
            MultiWorld.refusal(world: $0.name, host: $0.host,
                               allowsMultipleClients: $0.allowsMultipleClients, live: live)
        }
        checks.append(("duplicate HorizonXI is refused, naming the running pid",
                       horizon?.allowsMultipleClients == false && dup?.contains("57992") == true))
        checks.append(("the local world may run twice",
                       local?.allowsMultipleClients == true
                           && local.flatMap { MultiWorld.refusal(world: $0.name, host: $0.host,
                                                                 allowsMultipleClients: $0.allowsMultipleClients,
                                                                 live: live) } == nil))
        let onlyLocal = LiveClients.parse("61001 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1\n")
        checks.append(("a different world is not a duplicate",
                       horizon.flatMap { MultiWorld.refusal(world: $0.name, host: $0.host,
                                                            allowsMultipleClients: false,
                                                            live: onlyLocal) } == nil))
        checks.append(("only the local world and CatsEyeXI (cited rules) allow several clients",
                       Server.all.filter(\.allowsMultipleClients).map(\.name).sorted()
                           == ["CatsEyeXI", "Local server"]))

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
}
