import Foundation

/// `--selftest-leftovers`: what an earlier launcher left behind (`Leftovers`), on synthetic `ps`
/// output shaped like the live client read on 2026-10-15. Nothing is scanned or signalled: the
/// pids are made up (99xxxx) or 2026-10-16's (b70: their identities, the lock and the mappings
/// are injected, and so is every signal), the sessions are never stopped and never watched. The
/// only things written are a scratch folder under /tmp for `mapsFile` and `lockOwner`, removed at
/// the end, and one read-only mapping of a file in it into this process. The one process started
/// is this binary as a stand-in wineserver holding a lock in that folder (`--selftest-lock-probe`),
/// ended by closing its stdin.
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

        // b70: a Wine session that already died (Leftovers.stale), with 2026-10-16's numbers: the
        // 11:31 session's programs (started 1792175493-97; their executables on the X10 that
        // dropped at 14:15:40, so no readable path) still running at 16:39 beside the 16:37
        // session's wineserver 44464 (started 1792193859) and its programs (1792193860 on).
        // Identities, the lock and the mappings are injected: nothing is read or signalled.
        let me = getuid()
        let serverFolder = "/tmp/.wine-\(me)/server-1000016-d7c73b"
        let deadPs = """
            77779 77779 C:\\windows\\system32\\services.exe\u{20}
            77783 77783 C:\\windows\\system32\\plugplay.exe\u{20}
            77785 77785 C:\\windows\\system32\\explorer.exe /desktop\u{20}
            77787 77787 C:\\windows\\system32\\svchost.exe -k LocalServiceNetworkRestricted\u{20}
            77798 77798 C:\\windows\\system32\\rpcss.exe\u{20}
            77793 77790 .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture\u{20}
            """
        let livePs = """
            44464 44464 /Volumes/x10/Video Games/Mac/FFXI/wine-coop/wine/lib/wine/../../bin/wineserver
            44474 44474 C:\\windows\\system32\\services.exe\u{20}
            44478 44478 C:\\windows\\system32\\winedevice.exe\u{20}
            44482 44482 C:\\windows\\system32\\explorer.exe /desktop\u{20}
            44500 44500 C:\\windows\\system32\\rpcss.exe\u{20}
            44487 44470 .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture\u{20}
            """
        // proc_pidpath fails for every process of the dead session, so none is "this wine's".
        let both = LiveClients.parse(deadPs + "\n" + livePs, isOurs: { $0 < 77000 })
        var ids: [pid_t: Leftovers.ProcID] = [:]
        for (n, pid) in [77779, 77783, 77785, 77787, 77798].enumerated() {
            ids[pid_t(pid)] = Leftovers.ProcID(startSec: 1792175493 + UInt64(n), uid: me, ppid: 1)
        }
        for (n, pid) in [44474, 44478, 44482, 44500].enumerated() {
            ids[pid_t(pid)] = Leftovers.ProcID(startSec: 1792193860 + UInt64(n), uid: me, ppid: 1)
        }
        let owner = Leftovers.ServerLock.held(44464, Leftovers.ProcID(startSec: 1792193859, uid: me, ppid: 1))
        func flagged(_ snap: LiveClients.Snapshot, lock: Leftovers.ServerLock,
                     maps: (String, pid_t) -> Bool = { _, _ in true }) -> [pid_t] {
            Leftovers.stale(snap, dirs: [serverFolder], identity: { ids[$0] }, lock: { _ in lock },
                            maps: { d, pid, _ in maps(d, pid) }, skip: { _ in false }).map(\.pid)
        }
        checks.append(("b70: wine's own programs are all listed, readable path or not; only the live session's are this wine's",
                       both.systemPrograms == [44474, 44478, 44482, 44500, 77779, 77783, 77785, 77787, 77798]
                           && both.ownSystemPrograms == [44474, 44478, 44482, 44500]))
        // CrossOver, Whisky, XIV on Mac: the path reads, and is not this launcher's wine.
        let foreign = LiveClients.parse(livePs, isOurs: { _ in false }, pathRead: { _ in true })
        checks.append(("b70: another Wine install's programs are not listed at all, so never walked",
                       foreign.systemPrograms.isEmpty
                           && LiveClients.parse(livePs, isOurs: { _ in true }, pathRead: { _ in true }).systemPrograms
                               == [44474, 44478, 44482, 44500]))
        checks.append(("b70, 2026-10-16 16:39: exactly the dead session's five programs are flagged, beside the live session",
                       flagged(both, lock: owner) == [77779, 77783, 77785, 77787, 77798]))
        let deadOnly = LiveClients.parse(deadPs, isOurs: { _ in false })
        checks.append(("b70, 16:25 (no wineserver, the lock free): the same five, which the old rule never saw; never the frozen loader",
                       flagged(deadOnly, lock: .free) == [77779, 77783, 77785, 77787, 77798]
                           && Leftovers.serverless(deadOnly, parentOf: launchd, prefixSocketExists: false).isEmpty
                           && !deadOnly.systemPrograms.contains(77793)))
        let old = ids[77785]!
        var walked = false
        func rule(_ id: Leftovers.ProcID?, _ lock: Leftovers.ServerLock? = nil, maps: Bool = true) -> Bool {
            Leftovers.staleInstance(id, uid: me, lock: lock ?? owner, maps: { walked = true; return maps })
        }
        checks.append(("b70: one that maps no file of this prefix's server folder is never flagged",
                       !rule(old, maps: false) && flagged(both, lock: owner, maps: { _, _ in false }).isEmpty))
        checks.append(("b70: nor another user's, nor one with a live parent, nor one started within a minute of the wineserver",
                       !rule(Leftovers.ProcID(startSec: old.startSec, uid: me &+ 1, ppid: 1))
                           && !rule(Leftovers.ProcID(startSec: old.startSec, uid: me, ppid: 77000))
                           && !rule(Leftovers.ProcID(startSec: 1792193859 - 59, uid: me, ppid: 1))
                           && rule(Leftovers.ProcID(startSec: 1792193859 - 61, uid: me, ppid: 1))))
        // The wall clock stepped back between the wineserver's start and its programs' (a manual
        // change, a correction on wake): older by it, younger by the monotonic clock.
        let ownerUptime = 50_000.0
        let ownerBoth = Leftovers.ServerLock.held(44464, Leftovers.ProcID(startSec: 1792193859, startUptime: ownerUptime,
                                                                          uid: me, ppid: 1))
        checks.append(("b70: started a minute before the wineserver by both clocks, or it is not flagged (a clock stepped back)",
                       !rule(Leftovers.ProcID(startSec: 1792193859 - 120, startUptime: ownerUptime + 1, uid: me, ppid: 1), ownerBoth)
                           && !rule(Leftovers.ProcID(startSec: 1792193859 + 1, startUptime: ownerUptime - 120, uid: me, ppid: 1), ownerBoth)
                           && rule(Leftovers.ProcID(startSec: 1792193859 - 120, startUptime: ownerUptime - 120, uid: me, ppid: 1), ownerBoth)))
        checks.append(("b70: nothing decided when the lock's holder or the process cannot be read",
                       !rule(old, .unreadable) && !rule(nil)))
        walked = false
        let liveProgram = rule(ids[44482]!)
        checks.append(("b70: a live session's program fails before its regions are walked (the costly test is last)",
                       !liveProgram && !walked && rule(old) && walked))
        // The lock read again after the walks: a wineserver that took the free folder meanwhile.
        var lockReads = 0
        let takenMeanwhile = Leftovers.stale(deadOnly, dirs: [serverFolder], identity: { ids[$0] },
                                             lock: { _ in lockReads += 1; return lockReads == 1 ? .free : owner },
                                             maps: { _, _, _ in true }, skip: { _ in false })
        let pastDeadline = Leftovers.stale(deadOnly, dirs: [serverFolder], identity: { ids[$0] }, lock: { _ in .free },
                                           maps: { _, _, _ in true }, skip: { _ in false }, until: .now())
        checks.append(("b70: nothing flagged when the folder's lock changed during the scan, nor past Play's deadline",
                       takenMeanwhile.isEmpty && lockReads == 2 && pastDeadline.isEmpty))

        // Signals, injected: nothing is sent to any process, and what was killed is kept here, not
        // in the launcher's own table.
        var sent: [String] = []
        var killed: [Leftovers.Stale] = []
        let send: (pid_t, Int32) -> Void = { sent.append("\($1 == SIGKILL ? "KILL" : "TERM") \($0)") }
        let note: (Leftovers.Stale) -> Void = { killed.append($0) }
        let target = [Leftovers.Stale(pid: 77785, id: old)]
        let reused = Leftovers.ProcID(startSec: 1792200000, uid: me, ppid: 1)
        _ = Leftovers.signalStale(target, grace: 0, identity: { _ in reused }, pathGone: { _ in false },
                                  send: send, sleep: { _ in }, killedOne: note)
        checks.append(("b70: a pid that is another process by the time of the signal (reused) is never signalled",
                       sent.isEmpty && killed.isEmpty))
        sent = []
        _ = Leftovers.signalStale(target, grace: 0, identity: { _ in old }, pathGone: { _ in false },
                                  send: send, sleep: { _ in }, killedOne: note)
        checks.append(("b70: SIGTERM, then SIGKILL for one still the same process after the grace",
                       sent == ["TERM 77785", "KILL 77785"] && killed == target))
        sent = []
        killed = []
        var reads = 0
        let ended = Leftovers.signalStale(target, grace: 0, identity: { _ in reads += 1; return reads == 1 ? old : reused },
                                          pathGone: { _ in false }, send: send, sleep: { _ in }, killedOne: note)
        checks.append(("b70: ... no SIGKILL for one whose pid went to another process during the grace",
                       ended == [77785] && sent == ["TERM 77785"] && killed.isEmpty))
        sent = []
        _ = Leftovers.signalStale(target, grace: 0, identity: { _ in old }, pathGone: { _ in true },
                                  send: send, sleep: { _ in }, killedOne: note)
        checks.append(("b70: SIGKILL at once, no SIGTERM, for one whose executable's drive went away",
                       sent == ["KILL 77785"] && killed == target))
        // One that outlives SIGKILL (stuck in the kernel on the drive that went away) is not
        // flagged, signalled or logged again on the next refresh.
        let again = Leftovers.stale(deadOnly, dirs: [serverFolder], identity: { ids[$0] }, lock: { _ in .free },
                                    maps: { _, _, _ in true }, skip: { s in killed.contains(s) }).map(\.pid)
        checks.append(("b70: a program already sent SIGKILL is not flagged again; the others still are",
                       again == [77779, 77783, 77787, 77798]))
        checks.append(("b70: the launcher.log line says how many and which",
                       Leftovers.endedLine([77779, 77785])
                           == "i  ended 2 wine program(s) of a Wine session that had already died (pid 77779,77785)"))

        // The Mac's half, on this process and a scratch folder under /tmp (removed afterwards).
        checks.append(("b70: inside a folder by whole path components, /tmp and /private/tmp alike",
                       Leftovers.isUnder("/private/tmp/.wine-501/server-1000016-d7c73b/tmpmap-de75efcd",
                                         dir: "/tmp/.wine-501/server-1000016-d7c73b")
                           && Leftovers.isUnder("/tmp/.wine-501/server-1000016-d7c73b",
                                                dir: "/private/tmp/.wine-501/server-1000016-d7c73b/")
                           && !Leftovers.isUnder("/tmp/.wine-501/server-1000016-d7c73b2/tmpmap-1",
                                                 dir: "/tmp/.wine-501/server-1000016-d7c73b")
                           && !Leftovers.isUnder("/tmp/x", dir: "/") && !Leftovers.isUnder("/tmp/x", dir: "")))
        let scratch = "/tmp/ffxi-leftovers-\(UUID().uuidString.prefix(8))"
        let mappedDir = scratch + "/server-x2"
        try? FileManager.default.createDirectory(atPath: mappedDir, withIntermediateDirectories: true)
        let mapped = mappedDir + "/tmpmap-selftest"
        FileManager.default.createFile(atPath: mapped, contents: Data(count: 4096))
        let fd = open(mapped, O_RDONLY)
        let region = fd >= 0 ? mmap(nil, 4096, PROT_READ, MAP_PRIVATE, fd, 0) : nil
        let isMapped = region != nil && region != MAP_FAILED
        checks.append(("b70 mapsFile: a file this process maps is found under its folder, spelled /tmp (wine) or /private/tmp (the kernel)",
                       isMapped && Leftovers.mapsFile(under: mappedDir, pid: getpid())
                           && Leftovers.mapsFile(under: "/private" + mappedDir, pid: getpid())))
        checks.append(("b70 mapsFile: not under a sibling folder, nor under /tmp/x beside /tmp/x2",
                       isMapped && !Leftovers.mapsFile(under: scratch + "/server-x", pid: getpid())
                           && !Leftovers.mapsFile(under: scratch + "/other", pid: getpid())))
        // Kept once a program is a minute old: the walk is not repeated, so the file just unmapped
        // still counts for it; a younger one is walked again.
        let oldMe = Leftovers.ProcID(startSec: 1, startUptime: 0, uid: me, ppid: getppid())
        let youngMe = Leftovers.ProcID(startSec: 2, startUptime: Leftovers.uptimeNow(), uid: me, ppid: getppid())
        let bothMapped = isMapped && Leftovers.mapsFileOnce(under: mappedDir, pid: getpid(), id: oldMe)
            && Leftovers.mapsFileOnce(under: mappedDir, pid: getpid(), id: youngMe)
        if isMapped, let region { munmap(region, 4096) }
        if fd >= 0 { close(fd) }
        checks.append(("b70 mapsFileOnce: one walk per program, kept once it is a minute old; a younger one is walked again",
                       bothMapped && Leftovers.uptimeNow() > Leftovers.staleMargin
                           && Leftovers.mapsFileOnce(under: mappedDir, pid: getpid(), id: oldMe)
                           && !Leftovers.mapsFileOnce(under: mappedDir, pid: getpid(), id: youngMe)
                           && !Leftovers.mapsFile(under: mappedDir, pid: getpid())))
        let lockDir = scratch + "/server-lock"
        try? FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
        let noFile = Leftovers.lockOwner(lockDir) == .missing && Leftovers.serverLock(lockDir) == .free
            && !FileManager.default.fileExists(atPath: lockDir + "/lock")
        FileManager.default.createFile(atPath: lockDir + "/lock", contents: Data())
        checks.append(("b70 lockOwner: no lock file and no socket (never created) is free, and so is a lock nobody holds",
                       noFile && Leftovers.lockOwner(lockDir) == .unlocked && Leftovers.serverLock(lockDir) == .free
                           && Leftovers.lockHolder(lockDir) == nil))
        // A live wineserver whose lock file tmp_cleaner deleted after 3 days: the socket stays (a
        // stand-in file here; only its name is looked at).
        let cleanedDir = scratch + "/server-cleaned"
        try? FileManager.default.createDirectory(atPath: cleanedDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cleanedDir + "/socket", contents: Data())
        checks.append(("b70 serverLock: a missing lock file beside a socket is unreadable, never free",
                       Leftovers.lockOwner(cleanedDir) == .missing && Leftovers.serverLock(cleanedDir) == .unreadable
                           && Leftovers.lockHolder(cleanedDir) == nil))
        // A lock another process holds, read for real: this binary as a stand-in wineserver, which
        // takes the first byte the way a wineserver takes its folder's and holds it until its
        // stdin closes.
        let heldDir = scratch + "/server-held"
        try? FileManager.default.createDirectory(atPath: heldDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: heldDir + "/lock", contents: Data())
        let toProbe = Pipe(), fromProbe = Pipe()
        var probe: Process?
        if let exe = Bundle.main.executableURL {
            let p = Process()
            p.executableURL = exe
            p.arguments = ["--selftest-lock-probe", heldDir + "/lock"]
            p.standardInput = toProbe
            p.standardOutput = fromProbe
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { probe = p }
        }
        let said = probe == nil ? "" : String(decoding: fromProbe.fileHandleForReading.readData(ofLength: 7), as: UTF8.self)
        let child = probe?.processIdentifier ?? 0
        let childID = probe == nil ? nil : Leftovers.procID(child)
        let heldOwner = Leftovers.lockOwner(heldDir), heldLock = Leftovers.serverLock(heldDir)
        // Under that live holder, with the real lock read: one program started after it, one two
        // minutes before it by both clocks.
        var ages: [pid_t: Leftovers.ProcID] = [:]
        if let c = childID {
            ages[990801] = Leftovers.ProcID(startSec: c.startSec + 1, startUsec: c.startUsec,
                                            startUptime: c.startUptime + 1, uid: me, ppid: 1)
            ages[990802] = Leftovers.ProcID(startSec: c.startSec - 120, startUsec: c.startUsec,
                                            startUptime: c.startUptime - 120, uid: me, ppid: 1)
        }
        let probeSnap = LiveClients.parse("990801 990801 C:\\windows\\system32\\services.exe\n"
                                          + "990802 990802 C:\\windows\\system32\\winedevice.exe\n")
        let underHeld = Leftovers.stale(probeSnap, dirs: [heldDir], identity: { ages[$0] },
                                        maps: { _, _, _ in true }, skip: { _ in false }).map(\.pid)
        checks.append(("b70 lockOwner: a lock another process holds names it; held, with its identity; only what started before it is flagged",
                       said == "locked\n" && child > 0 && heldOwner == .holder(child)
                           && childID.map { heldLock == .held(child, $0) } == true && underHeld == [990802]))
        try? toProbe.fileHandleForWriting.close()
        probe?.waitUntilExit()
        checks.append(("b70 lockOwner: once its holder has exited (as a crashed wineserver), the same lock is free",
                       probe?.terminationStatus == 0 && Leftovers.lockOwner(heldDir) == .unlocked
                           && Leftovers.serverLock(heldDir) == .free))
        var st = stat()
        let statted = stat(lockDir, &st) == 0
        checks.append(("b70: a prefix's server folder is named from its stat; none for a prefix that is not there",
                       statted && Leftovers.serverDir(forPrefix: lockDir)
                           == Leftovers.serverDir(dev: UInt64(UInt32(bitPattern: st.st_dev)), ino: UInt64(st.st_ino))
                           && Leftovers.serverDir(forPrefix: scratch + "/no-such-prefix") == nil))
        let myID = Leftovers.procID(getpid())
        checks.append(("b70 procID of this process: its owner, its parent, a start time in the past on both clocks",
                       myID?.uid == getuid() && myID?.ppid == getppid()
                           && (myID.map { $0.start > 1_700_000_000 && $0.start <= Date().timeIntervalSince1970 } ?? false)
                           && (myID.map { $0.startUptime > 0 && $0.startUptime <= Leftovers.uptimeNow() } ?? false)))
        try? FileManager.default.removeItem(atPath: scratch)

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

/// `--selftest-lock-probe <lock file>`: `--selftest-leftovers`' stand-in wineserver. Takes the
/// write lock on the file's first byte the way a wineserver takes its folder's (F_SETLK,
/// server/request.c), says "locked", and holds it until its stdin closes: the self-test closes
/// it when done, and its own exit closes it too, so the probe never outlives the test. Exit 1
/// when the lock cannot be taken, 2 on bad arguments.
extension Headless {
    @MainActor static func runLockProbe(_ args: [String]) -> Never {
        guard let path = args.first else { exit(2) }
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { exit(1) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 1
        guard fcntl(fd, F_SETLK, &fl) == 0 else { exit(1) }
        FileHandle.standardOutput.write(Data("locked\n".utf8))
        _ = FileHandle.standardInput.readDataToEndOfFile()
        exit(0)
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
        // b70: the dead-session rule (Leftovers.stale). Read-only: a lock read (F_GETLK on a file
        // opened read-only), process reads, and a region walk only for a program that passed the
        // cheaper tests. A healthy session shows nothing here.
        let folder = Leftovers.serverDir(forPrefix: prefix)
        let lockText: String
        switch folder.map(Leftovers.serverLock) {
        case .free?: lockText = "free (no wineserver serves this prefix)"
        case .held(let pid, let id)?: lockText = "held by wineserver pid \(pid), started \(id.startSec)"
        case .unreadable?: lockText = "unreadable"
        case nil: lockText = "-"
        }
        let dead = folder.map { Leftovers.stale(snap, dirs: [$0]) } ?? []
        print("server folder: \(folder ?? "unreadable (prefix not there)"); lock: \(lockText)")
        print("wine's own programs, any wine: \(snap.systemPrograms); "
              + "of a Wine session that already died, would end: \(dead.map(\.pid))")
        exit(0)
    }
}
