import Foundation

/// `--selftest-addons-live`: which commands an Addons… Apply hands to a running client
/// (LiveAddons.commands), what `--send-ashita` refuses, how a running client is found, the
/// helper's environment and exit codes, and the launcher.log line. All on synthetic items and
/// synthetic `ps` output: nothing is scanned, launched or sent, and no file but a folder under
/// $TMPDIR (removed afterwards) is written.
///
/// With `HXI_LIVE_ADDONS_WINE_PREFIX` set (only scripts/tests/ashita-send-test.sh does that) it
/// also sends through the launcher's own path to the fake plugin that script runs in its
/// throwaway prefix. That part refuses unless the prefix is under
/// ~/Downloads/FFXI-on-Mac-build/fixture/ and the fake is the only client running.
extension Headless {
    @MainActor static func runAddonsLiveSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func item(_ n: String, plugin: Bool = false, _ on: Bool) -> AddonSuite.Item {
            AddonSuite.Item(name: n, isPlugin: plugin, enabled: on)
        }
        func flip(_ items: [AddonSuite.Item], _ names: Set<String>) -> [AddonSuite.Item] {
            items.map { var i = $0; if names.contains(i.name) { i.enabled.toggle() }; return i }
        }
        let horizon = AddonPolicies.horizon
        let local = AddonPolicies.localWorld
        let unknown = AddonPolicy.unknown
        func cmds(_ a: [AddonSuite.Item], _ b: [AddonSuite.Item], _ p: AddonPolicy) -> [String] {
            LiveAddons.commands(from: a, to: b, policy: p)
        }

        // MARK: the diff
        let base = [item("addons", plugin: true, true), item("minimap", plugin: true, true),
                    item("thirdparty", plugin: true, true), item("toon", plugin: true, false),
                    item("clock", true), item("distance", false), item("timers", true)]
        checks.append(("nothing changed: nothing sent", cmds(base, base, horizon).isEmpty))
        checks.append(("untick clock: exactly /addon unload clock",
                       cmds(base, flip(base, ["clock"]), horizon) == ["/addon unload clock"]))
        checks.append(("tick distance, untick clock: the unload, then the load",
                       cmds(base, flip(base, ["clock", "distance"]), horizon)
                           == ["/addon unload clock", "/addon load distance"]))
        checks.append(("plugins: /unload minimap, /load toon",
                       cmds(base, flip(base, ["minimap"]), horizon) == ["/unload minimap"]
                           && cmds(base, flip(base, ["toon"]), horizon) == ["/load toon"]))
        checks.append(("order: addon unloads, plugin unloads, plugin loads, addon loads",
                       cmds(base, flip(base, ["distance", "toon", "timers", "minimap"]), horizon)
                           == ["/addon unload timers", "/unload minimap", "/load toon", "/addon load distance"]))
        checks.append(("thirdparty is never sent, off or on",
                       cmds(base, flip(base, ["thirdparty"]), horizon).isEmpty
                           && cmds(flip(base, ["thirdparty"]), base, horizon).isEmpty))
        checks.append(("the Lua host: never /unload addons; /load addons comes before the addon loads",
                       cmds(base, flip(base, ["addons"]), horizon).isEmpty
                           && cmds(base, flip(base, ["addons", "distance"]), horizon) == ["/addon load distance"]
                           && cmds(flip(base, ["addons"]), flip(base, ["distance"]), horizon)
                               == ["/load addons", "/addon load distance"]))
        checks.append(("winefix, vanavoice and vanaguide are never sent",
                       cmds([item("winefix", plugin: true, false), item("vanavoice", false), item("vanaguide", false)],
                            [item("winefix", plugin: true, true), item("vanavoice", true), item("vanaguide", true)],
                            local).isEmpty))
        let extras = [item("gmtools", false), item("fps", plugin: true, false), item("fpslog", false)]
        checks.append(("HorizonXI: nothing off its list loads (gmtools), and no fps monitor",
                       cmds(extras, flip(extras, ["gmtools", "fps", "fpslog"]), horizon).isEmpty))
        checks.append(("HorizonXI: an unload is sent whatever the name",
                       cmds(flip(extras, ["gmtools"]), extras, horizon) == ["/addon unload gmtools"]))
        checks.append(("local world: anything installed loads",
                       cmds(extras, flip(extras, ["gmtools", "fps"]), local) == ["/load fps", "/addon load gmtools"]))
        checks.append(("a world with no sourced policy: what the sheet writes is what loads",
                       cmds([item("clock", false)], [item("clock", true)], unknown) == ["/addon load clock"]))
        checks.append(("an addon installed since the script was read loads when ticked, and only then",
                       cmds([], [item("gmtools", true)], local) == ["/addon load gmtools"]
                           && cmds([], [item("gmtools", false)], local).isEmpty))
        checks.append(("a name with ';', a space, a quote, a control character or non-ASCII is never sent",
                       cmds([], ["clo;ck", "my addon", "a\"b", "tab\tx", "café", ""].map { item($0, true) }, local).isEmpty))
        checks.append(("names of A-Z a-z 0-9 _ - . pass unchanged",
                       ["ASCII-Joy", "Minimap-Helper", "lib_x.v2"].allSatisfy { LiveAddons.sendableName($0) == $0 }
                           && LiveAddons.sendableName(String(repeating: "a", count: 65)) == nil))
        checks.append(("an item listed twice is sent once",
                       cmds([item("clock", false)], [item("clock", true), item("clock", true)], horizon)
                           == ["/addon load clock"]))
        checks.append(("case as installed is kept (HorizonXI's list matches it case-insensitively)",
                       cmds([item("XIVParty", false)], [item("XIVParty", true)], horizon) == ["/addon load XIVParty"]))

        // MARK: --send-ashita's refusals
        func refused(_ c: String, _ p: AddonPolicy = horizon, hosted: Bool = true) -> Bool {
            LiveAddons.refusal(c, policy: p, hosted: hosted) != nil
        }
        let never = ["/unload thirdparty", "/reload thirdparty", "/unload addons", "/reload addons",
                     "  //unload  ThirdParty.dll", "/unload \"addons\"", "/unload", "/reload"]
        checks.append(("never, on any world: /unload or /reload of thirdparty or addons, or of nothing",
                       never.allSatisfy { refused($0) && refused($0, local, hosted: false) }))
        checks.append(("HorizonXI: /addon load of an approved addon is sent",
                       !refused("/addon load clock") && !refused("//addon  load  Clock")
                           && !refused("/addon reload distance") && !refused("/load minimap")))
        checks.append(("HorizonXI: /addon load or /load of anything else is refused",
                       refused("/addon load gmtools") && refused("/addons load GMTools") && refused("/load fps")
                           && refused("/addon reload gmtools") && refused("/reload fpslog") && refused("/addon load")))
        checks.append(("a hosted world with no published list: no load at all, unloads still go",
                       refused("/addon load clock", unknown) && refused("/load minimap", unknown)
                           && !refused("/addon unload clock", unknown) && !refused("/unload minimap", unknown)))
        checks.append(("the local world: any load", !refused("/addon load gmtools", local, hosted: false)
                           && !refused("/load fps", local, hosted: false)))
        checks.append(("/exec, /alias, /bind: refused on hosted worlds, sent on the local one",
                       ["/exec x", "/alias /x /addon load gmtools", "/bind F1 /addon load gmtools"].allSatisfy {
                           refused($0) && !refused($0, local, hosted: false) }))
        checks.append(("';', control characters, non-ASCII, empty: refused everywhere",
                       ["/addon load clock;/unload thirdparty", "/addon load clock\t", "/echo café", "", "  ", "/"]
                           .allSatisfy { refused($0, local, hosted: false) }))
        checks.append(("other commands pass (/drawdistance setworld 5, /addon unload x)",
                       !refused("/drawdistance setworld 5") && !refused("/addon unload anything")))

        // MARK: exit codes and the log line
        let codes: [(Int32, LiveAddons.Outcome)] = [(0, .delivered), (1, .refused), (2, .noClient), (3, .ambiguous),
                                                    (4, .busy), (5, .pending), (53, .failed(53))]
        checks.append(("the helper's exit codes", codes.allSatisfy { LiveAddons.Outcome(exitCode: $0.0) == $0.1
                                                                     && $0.1.exitCode == $0.0 }))
        let two = ["/addon unload clock", "/addon load distance"]
        let delivered = LiveAddons.logLine(two, world: "HorizonXI", outcome: .delivered, seconds: 0.21)
        let busy = LiveAddons.logLine(two, world: "HorizonXI", outcome: .busy, output: "the plugin did not free its block")
        let skip = LiveAddons.logLine(two, world: "HorizonXI", outcome: nil, skip: "no HorizonXI client is running")
        let pending = LiveAddons.logLine(two, world: "HorizonXI", outcome: .pending)
        let many = LiveAddons.logLine((1...12).map { "/addon load a\($0)" }, world: "W", outcome: .delivered)
        checks.append(("log: delivered is one ==> line naming the commands and the time",
                       delivered == "==> addons, live in HorizonXI: /addon unload clock, /addon load distance: delivered (0.2 s)"))
        checks.append(("log: not sent says why and that they load at the next Play",
                       skip.hasPrefix("i  ") && skip.contains("no HorizonXI client is running") && skip.hasSuffix("at the next Play")
                           && busy.hasPrefix("!! ") && busy.contains("[the plugin did not free its block]")
                           && busy.hasSuffix("at the next Play")))
        checks.append(("log: pending is not an error", pending.hasPrefix("i  ") && pending.contains("not taken yet")))
        checks.append(("log: delivered after busy retries says so",
                       LiveAddons.logLine(two, world: "W", outcome: .delivered, seconds: 7.04, tries: 3)
                           .hasSuffix("delivered (7.0 s, after 3 tries: an earlier change was still waiting for the game)")))
        checks.append(("log: a long list is cut at 8, and every line is one line",
                       many.contains("/addon load a8 and 4 more") && !many.contains("a9,")
                           && [delivered, busy, skip, pending, many].allSatisfy { !$0.contains("\n") }))

        // MARK: the helper's environment
        let prefix = "/Volumes/x10/Video Games/Mac/FFXI/FFXI on Mac/FFXI on Mac Wine.app/Contents/SharedSupport/prefix10"
        let coop = URL(fileURLWithPath: "/nonexistent/wine-coop/wine/bin/wine")
        let target = LiveAddons.Target(wine: coop, prefix: URL(fileURLWithPath: prefix), sync: .msync, wineserver: 990416)
        let env = LiveAddons.environment(for: target, home: "/Users/x")
        var esync = target; esync.sync = .esync
        var off = target; off.sync = .off
        checks.append(("env: the running game's prefix", env["WINEPREFIX"] == prefix))
        checks.append(("env: the running wineserver's sync mode (msync, esync, off)",
                       env["WINEMSYNC"] == "1" && env["WINEESYNC"] == "0"
                           && LiveAddons.environment(for: esync, home: "")["WINEESYNC"] == "1"
                           && LiveAddons.environment(for: esync, home: "")["WINEMSYNC"] == "0"
                           && LiveAddons.environment(for: off, home: "")["WINEMSYNC"] == "0"
                           && LiveAddons.environment(for: off, home: "")["WINEESYNC"] == "0"))
        checks.append(("env: no display driver, no Mono/Gecko, no debug output",
                       env["WINEDLLOVERRIDES"] == "mscoree,mshtml=;winemac.drv=d" && env["WINEDEBUG"] == "-all"))
        checks.append(("env: nothing else (no x87 sidecar, no DXVK, no inherited variables)",
                       Set(env.keys) == ["WINEPREFIX", "WINEMSYNC", "WINEESYNC", "WINEDLLOVERRIDES", "WINEDEBUG", "HOME", "PATH"]))

        // MARK: finding the client (synthetic ps)
        let ps = """
            990416 990416 /nonexistent/wine-coop/wine/lib/wine/../../bin/wineserver
            990423 990423 C:\\windows\\system32\\services.exe\u{20}
            990429 990429 C:\\windows\\system32\\explorer.exe /desktop\u{20}
            990436 990401 .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture\u{20}
            990438 990401 /Applications/FFXI-on-Mac.app/Contents/Resources/x87sidecar-coop --cooperative /nonexistent/wine-coop/wine/lib/wine/x86_64-unix/wine .\\\\bootloader\\\\horizon-loader.exe --server play.horizonxi.com --user fixture --pass fixture
            """
        let playing = LiveClients.parse(ps)
        let idle = LiveClients.parse("990416 990416 /nonexistent/wine-coop/wine/bin/wineserver\n")
        let injecting = LiveClients.parse(ps + "\n990440 990401 .\\\\Ashita-cli.exe horizonxi.ini \n")
        let twoWorlds = LiveClients.parse(ps + "\n990520 990500 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1 --user a --pass b\n")
        let localOnly = LiveClients.parse("990416 990416 /nonexistent/wine-coop/wine/bin/wineserver\n"
                                          + "990520 990500 .\\\\bootloader\\\\horizon-loader.exe --server 127.0.0.1 --user a --pass b\n")
        func resolve(_ snap: LiveClients.Snapshot, world: String = "HorizonXI", hosts: [String] = ["play.horizonxi.com"],
                     servers: [pid_t: MultiWorld.SyncMode] = [990416: .msync], servedPrefix: String = prefix,
                     exe: String? = "/nonexistent/wine-coop/wine/bin/wineserver",
                     wines: [URL] = [URL(fileURLWithPath: "/nonexistent/wrapper/wine/bin/wine"), coop]) -> LiveAddons.Resolution {
            LiveAddons.resolve(world: world, hosts: hosts, prefix: prefix, snapshot: snap,
                               server: { p, pids in
                                   guard p == servedPrefix else { return nil }
                                   return pids.compactMap { pid in servers[pid].map { (pid, $0) } }.first
                               },
                               executable: { _ in exe }, wines: wines)
        }
        checks.append(("found: HorizonXI's client, the game's wine whose wineserver is running, msync",
                       resolve(playing) == .target(target)))
        checks.append(("found with the wineserver's esync mode", {
            if case .target(let t) = resolve(playing, servers: [990416: .esync]) { return t.sync == .esync }
            return false }()))
        checks.append(("no client of this world: not sent", resolve(idle) == .skip("no HorizonXI client is running")))
        checks.append(("a launch under way (injector): not sent", resolve(injecting) == .skip("a game is starting")))
        checks.append(("another world's client running too: not sent",
                       resolve(twoWorlds) == .skip("another world's client is running too")))
        checks.append(("the local world is found by localhost as well as 127.0.0.1", {
            if case .target = resolve(localOnly, world: "Local server", hosts: ["localhost"]) { return true }
            return false }()))
        checks.append(("no wineserver serves this install's prefix: not sent (and none is started)", {
            if case .skip(let why) = resolve(playing, servedPrefix: "/elsewhere/prefix10") { return why.contains("another install") }
            return false }()))
        checks.append(("a wineserver from a wine this launcher does not run: not sent", {
            if case .skip(let why) = resolve(playing, exe: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineserver") {
                return why.contains("not from a wine") }
            return false }()))
        checks.append(("the wrapper's own wine when its wineserver is the running one", {
            if case .target(let t) = resolve(playing, exe: "/nonexistent/wrapper/wine/bin/wineserver") {
                return t.wine.path == "/nonexistent/wrapper/wine/bin/wine" }
            return false }()))
        // The running wineserver's path as wine starts it (lib/wine/../../bin) is the same file.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("hxi-live-addons-\(UUID().uuidString)", isDirectory: true)
        let realBin = tmp.appendingPathComponent("wine-coop/wine/bin", isDirectory: true)
        try? fm.createDirectory(at: realBin, withIntermediateDirectories: true)
        try? fm.createDirectory(at: tmp.appendingPathComponent("wine-coop/wine/lib/wine"), withIntermediateDirectories: true)
        fm.createFile(atPath: realBin.appendingPathComponent("wineserver").path, contents: Data())
        let viaLib = tmp.appendingPathComponent("wine-coop/wine/lib/wine").path + "/../../bin/wineserver"
        checks.append(("the wineserver started as lib/wine/../../bin/wineserver matches its bin/wine", {
            if case .target(let t) = resolve(playing, exe: viaLib, wines: [realBin.appendingPathComponent("wine")]) {
                return t.wine == realBin.appendingPathComponent("wine") }
            return false }()))
        try? fm.removeItem(at: tmp)

        // MARK: registration
        checks.append(("--send-ashita is not handed to a running launcher window",
                       SingleInstance.isExempt(["app", "--send-ashita", "/addon load clock", "--world", "HorizonXI"])))
        let helper = LiveAddons.helperURL()
        let head = helper.flatMap { try? FileHandle(forReadingFrom: $0) }.flatMap { h -> Data? in
            defer { try? h.close() }; return try? h.read(upToCount: 2) }
        checks.append(("ashita-send.exe is found (bundle, or vendor/ in a checkout) and is a Windows program",
                       head == Data("MZ".utf8)))

        // MARK: optional: through the launcher's own path to scripts/tests' fake plugin
        if let wp = ProcessInfo.processInfo.environment["HXI_LIVE_ADDONS_WINE_PREFIX"], !wp.isEmpty {
            let fixture = OwnWine.resolve(NSHomeDirectory() + "/Downloads/FFXI-on-Mac-build/fixture") + "/"
            let safe = OwnWine.resolve(wp).hasPrefix(fixture)
            let snap = LiveClients.snapshot()
            let onlyFake = !snap.clients.isEmpty && snap.clients.allSatisfy { $0.host == "fake.invalid" }
            checks.append(("wine: the prefix is a throwaway one under the fixture folder", safe))
            checks.append(("wine: the fake plugin is the only client running (no game)", onlyFake))
            if safe, onlyFake {
                var wines: [URL] = []
                if let w = ProcessInfo.processInfo.environment["HXI_LIVE_ADDONS_WINE"], !w.isEmpty {
                    wines.append(URL(fileURLWithPath: w))
                }
                wines += X87Sidecar.patchedWineCandidates.map { URL(fileURLWithPath: $0) }
                let r = LiveAddons.resolve(world: "Fake", hosts: ["fake.invalid"], prefix: wp, snapshot: snap,
                                           server: { LiveClients.wineserver(serving: $0, among: $1) },
                                           executable: { LiveClients.executablePath(of: $0) }, wines: wines)
                var found: LiveAddons.Target?
                if case .target(let t) = r { found = t }
                checks.append(("wine: the fake's wineserver, its wine and msync are found from the live scan",
                               found?.sync == .msync && found?.prefix.path == wp))
                let wineCase = ProcessInfo.processInfo.environment["HXI_LIVE_ADDONS_WINE_CASE"] ?? ""
                if wineCase == "late", found != nil {
                    // The fake holds an earlier batch it takes only after 6 s: busy, then delivered.
                    let line = LiveAddons.deliver(["/addon load timers"], world: "Fake", hosts: ["fake.invalid"],
                                                  prefix: wp, wines: wines, busyRetry: 30)
                    print("     \(line)")
                    checks.append(("wine: busy while an earlier change waits, then delivered once the game takes it",
                                   line.hasPrefix("==> ") && line.contains(" tries: ")))
                } else if let t = found, let h = helper {
                    let sent = LiveAddons.run(["/addon unload clock", "/load minimap"], target: t, helper: h)
                    checks.append(("wine: delivered through LiveAddons.run (\(String(format: "%.2f", sent.seconds)) s)",
                                   sent.outcome == .delivered))
                    let refusedSend = LiveAddons.run(["/unload thirdparty"], target: t, helper: h)
                    checks.append(("wine: the helper refuses /unload thirdparty even if asked", refusedSend.outcome == .refused))
                }
            }
        }

        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--send-ashita "<command>" [--world <name>]`: hand one command to that world's running
    /// client, the way an Addons… Apply does, and say what happened. For checking by hand; it
    /// refuses what LiveAddons.refusal refuses (on a hosted world, any load that is not on the
    /// world's published list). Prints to stdout/stderr only; launcher.log is not touched.
    /// Exit: the helper's code (0 delivered … 5 pending), 1 refused, 2 not sent, 64 usage.
    @MainActor static func runSendAshita(_ args: [String]) -> Never {
        func fail(_ s: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data((s + "\n").utf8))
            exit(code)
        }
        guard let at = args.firstIndex(of: "--send-ashita"), at + 1 < args.count else {
            fail("usage: --send-ashita \"/command\" [--world <name>]", 64)
        }
        let command = args[at + 1]
        let store = ServerStore()
        var chosen = store.selected
        if let w = args.firstIndex(of: "--world") {
            guard w + 1 < args.count else { fail("usage: --send-ashita \"/command\" [--world <name>]", 64) }
            let name = args[w + 1]
            chosen = store.servers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if chosen == nil { fail("no world named \(name)", 64) }
        }
        guard let server = chosen else { fail("no world selected", 64) }
        let policy = AddonPolicies.policy(for: server)
        if let why = LiveAddons.refusal(command, policy: policy, hosted: !server.local) {
            fail("refused for \(server.name): \(why)", 1)
        }
        guard let base = InstallSelection.inUse() else { fail("the install in use isn't on disk", 2) }
        let install = base.forServer(server)
        let hosts = [server.host] + [Credentials.bootServer(in: install, profile: server.bootProfile)].compactMap { $0 }
        let r = LiveAddons.resolve(world: server.name, hosts: hosts, prefix: install.prefix.path,
                                   snapshot: LiveClients.snapshot(),
                                   server: { LiveClients.wineserver(serving: $0, among: $1) },
                                   executable: { LiveClients.executablePath(of: $0) },
                                   wines: LiveAddons.wines(for: install))
        switch r {
        case .skip(let why):
            fail("not sent to \(server.name): \(why)", 2)
        case .target(let t):
            guard let helper = LiveAddons.helperURL() else { fail("ashita-send.exe is missing from the app", 70) }
            let sent = LiveAddons.run([command], target: t, helper: helper)
            print("\(server.name): \(command): \(sent.outcome.text) (\(String(format: "%.1f", sent.seconds)) s)")
            if sent.outcome != .delivered, !sent.output.isEmpty { print(sent.output) }
            exit(sent.outcome.exitCode)
        }
    }
}
