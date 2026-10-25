// Copyright (c) 2026 Bates LLC. All rights reserved.
import Foundation

/// `--selftest-runner-gate`: the real launch gate with synthetic process snapshots and two
/// tiny Windows-drive fixtures. No Wine, process scan, game server, signals or saved settings.
extension Headless {
    @MainActor static func runRunnerGateSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let fm = FileManager.default
        let tmp = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            .appendingPathComponent("runner-gate-selftest-" + UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        do {
            let wrapper = tmp.appendingPathComponent("Wine.app")
            let a = Install(wrapper: wrapper, prefixName: "prefixA",
                            gameDirOverride: tmp.appendingPathComponent("Horizon game"))
            let b = Install(wrapper: wrapper, prefixName: "prefixB",
                            gameDirOverride: tmp.appendingPathComponent("Other game"))
            for install in [a, b] {
                try fm.createDirectory(at: install.prefix, withIntermediateDirectories: true)
                try fm.createDirectory(at: install.gameDir.appendingPathComponent("config/boot"), withIntermediateDirectories: true)
            }
            // The fixtures have deliberately incompatible renderers and registry targets.
            // No system.reg is needed: gate only reads these renderer and target markers.
            let metal = "[Software\\\\Wine\\\\DllOverrides]\n\"*d3d8\"=\"native\"\n"
            let openGL = "[Software\\\\Wine\\\\Direct3D]\n\"renderer\"=\"gl\"\n"
            try metal.write(to: a.prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
            try openGL.write(to: b.prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
            try a.squareEnixWine.write(to: a.prefix.appendingPathComponent(".ffxi-on-mac-registry-target"), atomically: true, encoding: .utf8)
            try "Z:\\another-client\\SquareEnix".write(to: b.prefix.appendingPathComponent(".ffxi-on-mac-registry-target"), atomically: true, encoding: .utf8)
            try "[ashita.boot]\ncommand = --server horizon.example\n[ashita.polplugins]\nsandbox = 0\n"
                .write(to: a.gameDir.appendingPathComponent("config/boot/horizon.ini"), atomically: true, encoding: .utf8)
            try "[ashita.boot]\ncommand = --server other.example\n[ashita.polplugins]\nsandbox = 0\n"
                .write(to: b.gameDir.appendingPathComponent("config/boot/other.ini"), atomically: true, encoding: .utf8)
            check("fixtures have different registry targets and renderer settings",
                  RendererSetup.current(a) == .metal && RendererSetup.current(b) == .openGL
                    && GameRegistry.current(a) == a.squareEnixWine && GameRegistry.current(b) != b.squareEnixWine)

            let horizon = LiveClients.parse("992101 992100 .\\bootloader\\horizon-loader.exe --server horizon.example\n")
            let other = LiveClients.parse("992201 992200 .\\bootloader\\xiloader.exe --server other.example\n")
            let runner = Runner(session: "offline gate fixture")
            let firstOrder = runner.gate(b, renderer: .openGL, profile: "other.ini", world: "Other World",
                                         host: "other.example", maxClients: 1,
                                         snapshot: horizon, prefixEvidence: [992100: a.prefix.path])
            check("Horizon in drive A permits a different registry and OpenGL world in drive B",
                  firstOrder.refusal == nil && !firstOrder.clientsLive && firstOrder.rendererStep == .stopAndApply)
            let reverseOrder = runner.gate(a, renderer: .metal, profile: "horizon.ini", world: "HorizonXI",
                                           host: "horizon.example", maxClients: 1,
                                           snapshot: other, prefixEvidence: [992200: b.prefix.path])
            check("the reverse order permits Horizon's Metal world after drive B is running",
                  reverseOrder.refusal == nil && !reverseOrder.clientsLive && reverseOrder.rendererStep == .stopAndApply)

            let sameDriveMismatch = runner.gate(a, renderer: .openGL, profile: "unused.ini", world: "Another world",
                                                host: "third.example", maxClients: 1,
                                                snapshot: horizon, prefixEvidence: [992100: a.prefix.path])
            check("a running client in the same drive still prevents a renderer change",
                  sameDriveMismatch.clientsLive && sameDriveMismatch.refusal?.contains("renderer cannot change") == true)
            let capped = runner.gate(b, renderer: .openGL, profile: "unused.ini", world: "HorizonXI",
                                     host: "horizon.example", maxClients: 1,
                                     snapshot: horizon, prefixEvidence: [992100: a.prefix.path])
            check("a server's single-client cap remains global across separate Windows drives",
                  capped.refusal?.contains("does not allow a second client") == true)

            let uncertain = runner.gate(b, renderer: .openGL, profile: "other.ini", world: "Other World",
                                        host: "other.example", maxClients: 1,
                                        snapshot: horizon, prefixEvidence: [:])
            check("missing prefix evidence preserves the live registry and refuses its replacement",
                  uncertain.clientsLive && uncertain.rendererStep == .skip
                    && uncertain.refusal?.contains("registry names") == true)
            let uncertainRenderer = runner.gate(b, renderer: .metal, profile: "other.ini", world: "Other World",
                                                host: "other.example", maxClients: 1,
                                                snapshot: horizon, prefixEvidence: [:])
            check("missing prefix evidence also prevents a renderer change",
                  uncertainRenderer.clientsLive && uncertainRenderer.refusal?.contains("renderer cannot change") == true)

            let many = LiveClients.parse((0..<12).map { n in
                "\(993101 + n * 10) \(993100 + n * 10) .\\bootloader\\xiloader.exe --server uncapped.example\n"
            }.joined())
            let evidence = Dictionary(uniqueKeysWithValues: many.clients.map { ($0.group, a.prefix.path) })
            let thirteenth = runner.gate(a, renderer: .metal, profile: "unused.ini", world: "Uncapped World",
                                         host: "uncapped.example", maxClients: Server.noClientCap,
                                         snapshot: many, prefixEvidence: evidence)
            check("an uncapped world permits a thirteenth client with aligned registry and renderer",
                  many.clients.count == 12 && Set(many.clients.map(\.group)).count == 12
                    && thirteenth.refusal == nil && thirteenth.clientsLive && thirteenth.rendererStep == .skip)
            check("gate checks leave both drives and runner state untouched",
                  !runner.running && !runner.busy
                    && RendererSetup.current(a) == .metal && RendererSetup.current(b) == .openGL
                    && GameRegistry.current(a) == a.squareEnixWine
                    && GameRegistry.current(b) == "Z:\\another-client\\SquareEnix")
        } catch {
            checks.append(("fixture setup: \(error.localizedDescription)", false))
        }
        for (name, ok) in checks { print("  \(ok ? "ok  " : "FAIL") \(name)") }
        let failures = checks.filter { !$0.1 }.count
        print("\(checks.count) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
