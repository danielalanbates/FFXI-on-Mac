import Foundation

/// `--next-action [<world>]`, `--fix <world> --prefix <prefix dir>` and
/// `--selftest-primary-action`: the main button without the window.
///
///     FFXI-on-Mac --next-action HorizonXI
///     setup:data-drive | Setup | The 'Games' drive isn't connected — reconnect it or press Setup.
///
/// `--next-action` is read-only and safe while playing. Exit 0 = Play, 10 = something to do,
/// 2 = no install. It does not ask the network, so it never offers a HorizonXI update.
///
/// `--fix` runs the same `PrimaryFixer` the button runs, for the jobs that need no person
/// (Repair, Mount, Update, and Setup's HorizonXI download). Choosing where things go, the setup
/// sheet and System Settings stay with the window. It refuses unless `--prefix` names the prefix to work on
/// (`…/Some.app/Contents/SharedSupport/prefix10`), so it never touches the remembered install by
/// accident. Its log goes to $TMPDIR/ffxi-on-mac-fix.log, not launcher.log.
extension Headless {
    static func worldArgument(after flag: String) -> String? {
        let a = CommandLine.arguments
        if let w = a.firstIndex(of: "--world"), w + 1 < a.count { return a[w + 1] }
        if let f = a.firstIndex(of: flag), f + 1 < a.count, !a[f + 1].hasPrefix("--") { return a[f + 1] }
        return nil
    }

    /// The install a `--prefix …/Contents/SharedSupport/<prefix>` names.
    static func installFromPrefixArgument() -> Install? {
        let a = CommandLine.arguments
        guard let k = a.firstIndex(of: "--prefix"), k + 1 < a.count else { return nil }
        let prefix = URL(fileURLWithPath: a[k + 1]).standardizedFileURL
        let shared = prefix.deletingLastPathComponent()
        guard shared.lastPathComponent == "SharedSupport" else { return nil }
        let wrapper = shared.deletingLastPathComponent().deletingLastPathComponent()
        return Install(wrapper: wrapper, prefixName: prefix.lastPathComponent)
    }

    /// Everything `--next-action` and `--fix` can know without a window.
    @MainActor static func headlessDecision(base: Install?, server: Server) -> PrimaryDecision {
        var x = PrimaryInputs()
        x.world = server.name
        x.isLocal = server.local
        x.canDownload = server.local || server.installKind != .none
        x.hostEmpty = !server.local && server.host.trimmingCharacters(in: .whitespaces).isEmpty
        x.allowsMultipleClients = server.allowsMultipleClients
        x.accountInLoader = server.accountURL.isEmpty && server.accountHow.contains("loader window")
        guard let base else {
            x.hasInstall = false
            if let r = Primary.rememberedDrive() { x.rememberedDrive = r.0; x.driveStates[r.0] = r.1 }
            return Primary.decide(x)
        }
        let i = base.forServer(server)
        let p = Primary.probe(i, profile: server.bootProfile, horizon: server.name == "HorizonXI",
                              requiredClient: server.requiredClient,
                              loader: server.loader, template: server.bootTemplate)
        x.checks = p.checks
        x.driveStates = p.driveStates
        x.hasGame = p.hasGame
        x.patchedWineMissing = p.patchedWineMissing
        x.rosettaMissing = p.rosettaMissing
        x.horizonInstalled = p.horizonInstalled
        x.clientInstalled = p.clientInstalled
        x.clientRequired = server.requiredClient
        x.otherJob = Runner.workInFlight ? Runner.workInFlightReason : nil
        x.wineStuck = WineserverStopWait.anyStuck
        let user = Credentials.username(forWorld: server.name)
        x.accountNeeded = (user.isEmpty || Credentials.password(for: user, world: server.name).isEmpty) && !p.profileHasAccount
        if server.local { x.localReady = true }   // not probed headless; Play checks it
        return Primary.decide(x)
    }

    static func line(_ d: PrimaryDecision) -> String {
        let id = d.action.detail.isEmpty ? d.action.id : d.action.id + ":" + d.action.detail
        return "\(id) | \(d.label) | \(d.reason ?? "")" + (d.enabled ? "" : "  (disabled)")
    }

    @MainActor static func runNextAction() -> Never {
        let store = ServerStore()
        let name = worldArgument(after: "--next-action") ?? store.selected?.name ?? "HorizonXI"
        guard let server = store.servers.first(where: { $0.name == name }) else {
            FileHandle.standardError.write(Data("no world named \(name)\n".utf8)); exit(2)
        }
        let base = installFromPrefixArgument() ?? InstallSelection.inUse()
        let d = headlessDecision(base: base, server: server)
        print(line(d))
        if base == nil { exit(2) }
        if case .play = d.action { exit(0) }
        exit(10)
    }

    @MainActor static func runFix() -> Never {
        let store = ServerStore()
        let name = worldArgument(after: "--fix") ?? "HorizonXI"
        guard let server = store.servers.first(where: { $0.name == name }) else {
            FileHandle.standardError.write(Data("no world named \(name)\n".utf8)); exit(2)
        }
        guard let base = installFromPrefixArgument() else {
            let d = headlessDecision(base: InstallSelection.inUse(), server: server)
            print(line(d))
            print("refusing: --fix only works on a prefix named with --prefix …/Contents/SharedSupport/<prefix>")
            exit(3)
        }
        let d = headlessDecision(base: base, server: server)
        print("before: " + line(d))
        guard PrimaryFixer.isHeadlessFixable(d.action), d.enabled else {
            print(d.action == .play ? "nothing to fix" : "refusing: \(line(d)) needs a person (or the window)")
            exit(d.action == .play ? 0 : 3)
        }
        let runner = Runner()
        var finished: Bool?
        let started = PrimaryFixer.perform(d.action, install: base.forServer(server), server: server,
                                           runner: runner) { ok in finished = ok }
        guard started else { print("refusing: \(d.action.id) is not run headless for \(server.name)"); exit(3) }
        while finished == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let after = headlessDecision(base: base, server: server)
        print("result: \(finished == true ? "ok" : "failed")")
        print("after:  " + line(after))
        exit(finished == true ? 0 : 1)
    }
}

/// `--progress-trace <horizon-install|horizon-update|game-wine> <file>`: a setup script's output
/// read the way the main button reads it (ScriptProgress), one line each time what the button
/// would say changes: "<percent> <stage>". scripts/tests/setup-scripts-test.sh feeds it the real
/// scripts' output, so the figure is checked against what they actually print. Reads only the file.
extension Headless {
    static func runProgressTrace() -> Never {
        let a = CommandLine.arguments
        guard let k = a.firstIndex(of: "--progress-trace"), k + 2 < a.count,
              let text = try? String(contentsOfFile: a[k + 2], encoding: .utf8) else {
            FileHandle.standardError.write(Data("usage: --progress-trace <horizon-install|horizon-update|game-wine> <file>\n".utf8))
            exit(2)
        }
        let job: ScriptProgress.Job
        switch a[k + 1] {
        case "horizon-install": job = .horizonInstall
        case "horizon-update": job = .horizonUpdate
        case "game-wine": job = .gameWine
        default: FileHandle.standardError.write(Data("unknown job \(a[k + 1])\n".utf8)); exit(2)
        }
        var p = ScriptProgress(job)
        var last = ""
        // In pieces, as a pipe delivers it: lines split across reads must read the same.
        var rest = Substring(text)
        while !rest.isEmpty {
            p.read(String(rest.prefix(37)))
            rest = rest.dropFirst(37)
            let now = "\(Int((p.fraction * 100).rounded(.down))) \(p.stage.rawValue)"
            if now != last { print(now); last = now }
        }
        p.read("\n")
        let end = "\(Int((p.fraction * 100).rounded(.down))) \(p.stage.rawValue)"
        if end != last { print(end) }
        exit(0)
    }
}
