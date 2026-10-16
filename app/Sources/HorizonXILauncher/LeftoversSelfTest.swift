import Foundation

/// `--selftest-leftovers`: what an earlier launcher left behind (`Leftovers`), on synthetic `ps`
/// output shaped like the live client read on 2026-10-15. Nothing is scanned, signalled or
/// written: the pids are made up (99xxxx), the sessions are never stopped and never watched.
extension Headless {
    @MainActor static func runLeftoversSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        let prefix = "/Volumes/x10/Video Games/Mac/FFXI/FFXI on Mac/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10"
        let otherPrefix = "/Users/x/Library/Application Support/CrossOver/Bottles/FFXI"
        // `ps -axww -o pid=,pgid=,command=`, as read on the live client (pids changed): the
        // wineserver and wine's programs each lead a group; loader and sidecar share the spawn's.
        let psText = """
            990416 990416 /Volumes/x10/Video Games/Mac/FFXI/wine-coop/wine/lib/wine/../../bin/wineserver
            990423 990423 C:\\windows\\system32\\services.exe\u{20}
            990425 990425 C:\\windows\\system32\\winedevice.exe\u{20}
            990429 990429 C:\\windows\\system32\\explorer.exe /desktop\u{20}
            990436 990401 .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture\u{20}
            990438 990401 /Applications/FFXI-on-Mac.app/Contents/Resources/x87sidecar-coop --cooperative /Volumes/x10/Video Games/Mac/FFXI/wine-coop/wine/lib/wine/x86_64-unix/wine .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture
            """
        let own = LiveClients.parse(psText)   // every executable this launcher's wine
        let orphan = Leftovers.Orphan(group: 990401, host: "play.horizonxi.com", pids: [990436, 990438])
        func adoptable(_ snap: LiveClients.Snapshot, ownGroups: Set<pid_t> = [], hostsWithoutGroup: Set<String> = [],
                       groupPrefix: [pid_t: String] = [990401: prefix], servers: [pid_t: String?] = [990416: prefix],
                       other: Bool = false) -> [Leftovers.Orphan] {
            Leftovers.adoptable(snap, ownGroups: ownGroups, ownHostsWithoutGroup: hostsWithoutGroup, prefix: prefix,
                                prefixOfGroup: groupPrefix, serverPrefixes: servers, otherLauncherAlive: other)
        }

        // Ours.
        checks.append(("own orphaned loader (own wine, the selected prefix, no other launcher) is adopted",
                       adoptable(own) == [orphan]))
        // b69: the sidecar's command line when gamewindow.dylib's carry put /bin/sh before the loader.
        let carriedPs = psText.replacingOccurrences(
            of: "--cooperative /Volumes",
            with: "--cooperative /bin/sh -c export DYLD_INSERT_LIBRARIES=\"$HXI_DYLD_INSERT_LIBRARIES\"; exec \"$@\" hxi-carry /Volumes")
        checks.append(("... the same when its sidecar went through the carry's /bin/sh step (b69)",
                       carriedPs != psText && adoptable(LiveClients.parse(carriedPs)) == [orphan]))
        checks.append(("... with no sidecar to read, when this wine's only wineserver serves the selected prefix",
                       adoptable(own, groupPrefix: [:]) == [orphan]
                           && adoptable(own, groupPrefix: [:], servers: [990416: prefix + "/"]) == [orphan]))

        // Not ours.
        checks.append(("another launcher alive: its client stays elsewhere",
                       adoptable(own, other: true).isEmpty))
        let foreignWine = LiveClients.parse(psText, isOurs: { $0 != 990436 && $0 != 990438 })
        checks.append(("a client of another wine install is never adopted",
                       adoptable(foreignWine).isEmpty && adoptable(foreignWine, groupPrefix: [:]).isEmpty))
        let halfForeign = LiveClients.parse(psText, isOurs: { $0 != 990436 })
        checks.append(("... nor one whose group runs any other wine", adoptable(halfForeign).isEmpty))
        checks.append(("a client of this wine in another prefix is not adopted",
                       adoptable(own, groupPrefix: [990401: otherPrefix]).isEmpty))
        checks.append(("with no readable environment: not adopted while this wine serves another prefix too, or none, or one unreadable",
                       adoptable(own, groupPrefix: [:], servers: [990416: prefix, 990417: otherPrefix]).isEmpty
                           && adoptable(own, groupPrefix: [:], servers: [:]).isEmpty
                           && adoptable(own, groupPrefix: [:], servers: [990416: nil]).isEmpty))
        checks.append(("this launcher's own session (its group, or its host while it is starting) is never re-adopted",
                       adoptable(own, ownGroups: [990401]).isEmpty
                           && adoptable(own, hostsWithoutGroup: ["play.horizonxi.com"]).isEmpty))
        let catsEyeOwnLauncher = LiveClients.parse("""
            990510 990500 C:\\CatsEye\\pol.exe --server server.catseyexi.com
            990520 990520 /Applications/CatsEyeXI.app/Contents/SharedSupport/wine/bin/wineserver
            """, isOurs: { _ in false })
        checks.append(("CatsEyeXI's own launcher (its own wine): Running… without Stop",
                       adoptable(catsEyeOwnLauncher, groupPrefix: [:], servers: [:]).isEmpty
                           && !MultiWorld.elsewhere(catsEyeOwnLauncher.clients, ownGroups: [], ownHostsWithoutGroup: []).isEmpty))
        // CatsEyeXI's launcher run inside the wrapper (scripts/catseye-launcher.sh): this wine, the
        // selected prefix, and its Play starts the loader in its own group.
        let catsEyeInWrapper = LiveClients.parse(psText + "\n" + """
            990710 990700 C:\\CatsEyeXI-Launcher\\CatsEyeXI-Launcher.exe\u{20}
            990712 990700 C:\\Games\\CatsEyeXI\\catseyexi-client\\Ashita\\bootloader\\xiloader.exe --server catseyexi.com
            """)
        checks.append(("CatsEyeXI's launcher in this wine: its game is not adopted (Stop would end the launcher too)",
                       adoptable(catsEyeInWrapper, groupPrefix: [990401: prefix, 990700: prefix]) == [orphan]))
        checks.append(("this launcher's own process group (its jobs) is never adopted",
                       Leftovers.adoptable(own, ownGroups: [], ownHostsWithoutGroup: [], prefix: prefix,
                                           prefixOfGroup: [990401: prefix], serverPrefixes: [990416: prefix],
                                           otherLauncherAlive: false, selfGroup: 990401).isEmpty))
        let withInjector = LiveClients.parse(psText + "\n" + """
            990440 990401 .\\\\Ashita-cli.exe horizonxi.ini\u{20}
            """)
        checks.append(("an injector still in the group is the launch's own: still adopted",
                       adoptable(withInjector).map(\.group) == [990401]))

        // What the window does with each.
        let sessions = Sessions()
        let runner = sessions.runner(for: "HorizonXI")
        let install = Install(wrapper: URL(fileURLWithPath: "/nonexistent/FFXI on Mac Wine.app"), prefixName: "prefix10")
        runner.adopt(group: orphan.group, host: orphan.host, world: "HorizonXI", install: install,
                     profile: "horizonxi.ini", pids: orphan.pids, watch: false)
        let mine = Runner.playingGroups
        checks.append(("adopted: a running session of this window, not starting, in the RUNNING list",
                       runner.running && !runner.starting && sessions.live.map(\.id) == ["HorizonXI"]
                           && mine.groups.contains(990401) && !mine.hostsWithoutGroup.contains("play.horizonxi.com")))
        checks.append(("adopted: no longer elsewhere, and not adopted twice",
                       MultiWorld.elsewhere(own.clients, ownGroups: mine.groups, ownHostsWithoutGroup: mine.hostsWithoutGroup).isEmpty
                           && adoptable(own, ownGroups: mine.groups, hostsWithoutGroup: mine.hostsWithoutGroup).isEmpty))
        var x = PrimaryInputs()
        x.runningHere = runner.running
        let button = Primary.decide(x)
        x.runningHere = false
        x.runningElsewhere = true
        let stranger = Primary.decide(x)
        checks.append(("adopted: the big button is Stop, enabled",
                       button.action == .stop && button.enabled && button.label == "Stop"))
        checks.append(("a stranger's client: Running…, disabled, no Stop",
                       stranger.action == .working(.runningElsewhere, progress: nil) && !stranger.enabled
                           && stranger.reason == "Already running from another launcher."))
        // The exit watcher and Stop go by the group: its wine processes while it runs, nothing
        // (the game exited) once it is empty.
        checks.append(("its Stop and exit watcher see exactly the group's processes, then nothing once it ends",
                       MultiWorld.sessionPIDs(group: 990401, groupHeldLoader: true, host: orphan.host, preexisting: [],
                                              otherGroups: [], in: own) == [990436, 990438]
                           && Set(MultiWorld.signalable([990436, 990438, 990423], group: 990401, host: orphan.host,
                                                        otherGroups: [], in: own).keys) == [990436, 990438]
                           && MultiWorld.sessionPIDs(group: 990401, groupHeldLoader: true, host: orphan.host, preexisting: [],
                                                     otherGroups: [], in: LiveClients.parse(psText.components(separatedBy: "\n").prefix(4)
                                                                                            .joined(separator: "\n"))).isEmpty))
        let second = sessions.runner(for: "HorizonXI")
        second.adopt(group: 990601, host: orphan.host, world: "HorizonXI", install: install, profile: "horizonxi.ini",
                     pids: [990602], watch: false)
        checks.append(("a running session is never re-pointed at another group",
                       Runner.playingGroups.groups.contains(990401) && !Runner.playingGroups.groups.contains(990601)))

        // wine's own programs with no wineserver.
        let serverGone = LiveClients.parse(psText.components(separatedBy: "\n").dropFirst().prefix(3).joined(separator: "\n"))
        let launchd: (pid_t) -> pid_t? = { _ in 1 }
        checks.append(("wine's own programs, this wine's, no wineserver left: flagged for cleanup",
                       serverGone.ownSystemPrograms == [990423, 990425, 990429] && serverGone.ownWineservers.isEmpty
                           && Leftovers.serverless(serverGone, parentOf: launchd, prefixSocketExists: false) == [990423, 990425, 990429]))
        checks.append(("... a stale socket with no wineserver at all does not save them",
                       Leftovers.serverless(serverGone, parentOf: launchd, prefixSocketExists: true) == [990423, 990425, 990429]))
        checks.append(("with this wine's wineserver alive (a game playing): nothing flagged",
                       own.ownWineservers == [990416] && Leftovers.serverless(own, parentOf: launchd, prefixSocketExists: true).isEmpty))
        let otherInstall = LiveClients.parse(psText.components(separatedBy: "\n").dropFirst().prefix(3).joined(separator: "\n"),
                                             isOurs: { _ in false })
        checks.append(("another wine install's programs are never flagged",
                       otherInstall.ownSystemPrograms.isEmpty
                           && Leftovers.serverless(otherInstall, parentOf: launchd, prefixSocketExists: false).isEmpty))
        let foreignServer = LiveClients.parse(psText.components(separatedBy: "\n").prefix(4).joined(separator: "\n"),
                                              isOurs: { $0 != 990416 })
        checks.append(("the prefix's socket there and a wineserver of another wine running: nothing flagged",
                       Leftovers.serverless(foreignServer, parentOf: launchd, prefixSocketExists: true).isEmpty
                           && Leftovers.serverless(foreignServer, parentOf: launchd, prefixSocketExists: false) == [990423, 990425, 990429]))
        checks.append(("one still parented to a live process is left alone",
                       Leftovers.serverless(serverGone, parentOf: { $0 == 990425 ? 990000 : 1 }, prefixSocketExists: false)
                           == [990423, 990429]))

        // Reading the evidence.
        let sidecarEnv = "/Applications/FFXI-on-Mac.app/Contents/Resources/x87sidecar-coop --cooperative /x/wine .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user u --pass p HOME=/Users/x WINEPREFIX=\(prefix) WINEESYNC=0 WINEMSYNC=1"
        checks.append(("WINEPREFIX is read from a ps -E line, spaces and all; nothing when absent",
                       Leftovers.envValue("WINEPREFIX", in: sidecarEnv) == prefix
                           && Leftovers.envValue("WINEPREFIX", in: "/x/wineserver WINEPREFIX=/a b/c") == "/a b/c"
                           && Leftovers.envValue("WINEPREFIX", in: ".\\\\bootloader\\\\horizon-loader.exe --server h") == nil))
        // b69's carry puts a /bin/sh step, with a KEY="value"-looking word, before the loader in the
        // sidecar's command line, and its environment gains HXI_* variables.
        let carriedEnv = "/Applications/FFXI-on-Mac.app/Contents/Resources/x87sidecar-coop --cooperative /bin/sh -c export DYLD_INSERT_LIBRARIES=\"$HXI_DYLD_INSERT_LIBRARIES\"; exec \"$@\" hxi-carry /x/wine .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user u --pass p HOME=/Users/x HXI_DYLD_INSERT_LIBRARIES=/A b/gamewindow.dylib HXI_GAME_ASPECT=1920x1080 WINEPREFIX=\(prefix) WINEESYNC=0 WINEMSYNC=1"
        checks.append(("WINEPREFIX is read the same from a sidecar started through the carry's /bin/sh step",
                       Leftovers.envValue("WINEPREFIX", in: carriedEnv) == prefix))
        // b69 also sets HXI_WINDOW_TITLE, a value with spaces, next to it.
        let titledEnv = carriedEnv.replacingOccurrences(of: " WINEPREFIX=", with: " HXI_WINDOW_TITLE=FFXI on Mac WINEPREFIX=")
        checks.append(("WINEPREFIX and HXI_WINDOW_TITLE are read whole when the title (with spaces) comes first",
                       Leftovers.envValue("WINEPREFIX", in: titledEnv) == prefix
                           && Leftovers.envValue("HXI_WINDOW_TITLE", in: titledEnv) == "FFXI on Mac"))
        checks.append(("the wineserver socket folder is named as wine names it",
                       Leftovers.serverDir(dev: 0x1000016, ino: 0xd7c73b, uid: 501) == "/tmp/.wine-501/server-1000016-d7c73b"))

        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `--leftovers-report`: what the window would adopt and end right now, on this Mac, without
/// doing either. Read-only (one `ps`, a `ps -E` read for `WINEPREFIX` only, a `stat`); safe while
/// a game is playing. Prints pids and prefixes, never a command line.
extension Headless {
    @MainActor static func runLeftoversReport() -> Never {
        guard let install = installFromPrefixArgument() ?? Install.remembered() else {
            print("no install"); exit(2)
        }
        let prefix = OwnWine.resolve(install.prefix.path)
        let snap = LiveClients.snapshot()
        let ev = Leftovers.evidence(snap, ownGroups: [], ownHostsWithoutGroup: [])
        let other = SingleInstance.otherLauncherAlive()
        print("prefix: \(prefix)")
        print("another launcher alive: \(other)")
        print("this wine's wineservers: \(snap.ownWineservers.map { "\($0) -> \(ev.servers[$0].flatMap { $0 } ?? "unread")" })")
        for c in snap.clients where c.knownLoader {
            print("client pid \(c.pid) group \(c.group) host \(c.host.isEmpty ? "-" : c.host) own wine \(c.ownWine)"
                  + " prefix \(ev.groups[c.group] ?? "unread")")
        }
        let would = Leftovers.adoptable(snap, ownGroups: [], ownHostsWithoutGroup: [], prefix: prefix,
                                        prefixOfGroup: ev.groups, serverPrefixes: ev.servers, otherLauncherAlive: false)
        print("would adopt (with no other launcher alive): \(would.map { "group \($0.group) \($0.host) pids \($0.pids)" })")
        print("adopts now: \(other ? "nothing (another launcher is alive)" : "\(would.count)")")
        let left = Leftovers.serverless(snap, parentOf: Leftovers.parentPID,
                                        prefixSocketExists: Leftovers.prefixSocketExists(prefix))
        print("this wine's own programs: \(snap.ownSystemPrograms); would end: \(left)")
        exit(0)
    }
}
