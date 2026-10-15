// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// `--selftest-setup-progress`: Setup's progress on the main button without a window or a script
/// (SetupProgress.swift). Daniel, 2026-10-15: "it's been stuck on setting up 0%".
///
/// - ScriptProgress reading update-client.sh's and game-wine.sh's output, as they print it: aria2's
///   summary blocks every 2 s, the unzip's "==> unpacking N%", the updates: the stage names, the
///   figure at each point, never going back (a readout that drops, a line split across reads), and
///   what is kept out of launcher.log.
/// - SetupMeter over a whole chain: a step that ends never drops the figure to 0%, a step found
///   not to be needed makes it jump, one not planned leaves it, and it says 100% only by ending.
/// - The button: the step's name with the chain's figure ("Downloading HorizonXI… 37%"), no
///   figure under 1%, short enough for the button, plain words.
///
/// Reads and writes nothing.
extension Headless {
    @MainActor static func runSetupProgressSelfTest() -> Never {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { results.append((name, ok)) }
        func pct(_ f: Double) -> Int { Int((f * 100 + 1e-9).rounded(.down)) }

        // MARK: update-client.sh install, as it prints
        let summary: (Int) -> String = { p in
            "\n *** Download Progress Summary as of Thu Oct 15 10:00:00 2026 ***\n"
            + "===============================================================================\n"
            + "[#2089b0 \(p)MiB/9400MiB(\(p)%) CN:44 SD:12 DL:5.1MiB ETA:20m]\n"
            + "FILE: /x/updates/HorizonXI.zip\n"
            + "-------------------------------------------------------------------------------\n"
        }
        let install: [String] = [
            "==> fetching HorizonXI.zip (2.0.2) by torrent into /x/updates — this is ~9.4 GB\n",
            "\n *** Download Progress Summary as of Thu Oct 15 10:00:00 2026 ***\n[#aaaaaa 0B/0B CN:1 DL:0B]\n",
            summary(25), summary(50), summary(40), summary(100),
            "==> extracting HorizonXI.zip\n",
            "==> unpacking 0%\n", "==> unpacking 40%\n", "==> unpacking 100%\n",
            "==> base client in place — applying updates\n",
            "==> installed HorizonXI 2.0.2, asking api.horizonxi.com what is newer\n",
            "==> update 2.0.3 (1/2)\n", summary(50), summary(100), "==> extracting HorizonXI-2_0_3.zip\n",
            "==> unpacking 100%\n", "==> now at 2.0.3\n",
            "==> update 2.0.4 (2/2)\n", "==> extracting HorizonXI-2_0_4.zip\n", "==> unpacking 100%\n",
            "==> now at 2.0.4\n", "==> done — client is at 30240101_0\n",
        ]
        var p = ScriptProgress(.horizonInstall)
        var trace: [(Double, SetupStage)] = []
        for chunk in install { p.read(chunk); trace.append((p.fraction, p.stage)) }
        let fr = trace.map(\.0)
        check("install: never goes back (the 40% readout after 50% leaves it): \(fr.map(pct))",
              zip(fr, fr.dropFirst()).allSatisfy { $0 <= $1 })
        check("install: the download is named, then the unzip, then the updates",
              trace[2].1 == .downloadingGame && trace[7].1 == .unpackingGame && trace[11].1 == .updatingGame)
        check("install: 25% of the torrent moves the button (\(pct(trace[2].0))%; it sat at 0% for minutes before)",
              pct(trace[2].0) == 14)
        check("install: the unzip moves it too (40% unpacked = \(pct(trace[8].0))%)", pct(trace[8].0) == 69)
        check("install: the base in place is 85%", pct(trace[10].0) == 85)
        check("install: every update applied is 100%", (trace.last?.0 ?? 0) >= 0.999 && p.label == "2.0.4 · 2 of 2")

        // The same output a byte at a time (a pipe splits lines anywhere): read the same.
        var q = ScriptProgress(.horizonInstall)
        for ch in install.joined() { q.read(String(ch)) }
        check("install: lines split across reads read the same", q.fraction == p.fraction && q.stage == p.stage)
        // aria2 on a terminal rewrites one line with \r.
        var r = ScriptProgress(.horizonInstall)
        r.read("[#2089b0 1MiB/9400MiB(10%)]\r[#2089b0 2MiB/9400MiB(20%)]\n")
        check("install: a \\r-rewritten readout is read (20% -> \(pct(r.fraction))%)", pct(r.fraction) == 11)

        let logged = ScriptProgress.loggable(install.joined())
        check("launcher.log keeps the steps, not the readouts or the unzip's figures",
              logged.contains("==> extracting HorizonXI.zip") && logged.contains("==> update 2.0.4 (2/2)")
                && !logged.contains("(25%)") && !logged.contains("FILE:") && !logged.contains("***")
                && !logged.contains("==> unpacking"))

        // An install that finds a complete client goes straight to its updates.
        var u = ScriptProgress(.horizonInstall)
        u.read("==> already has a client (version.json) — updating instead\n")
        check("install over a complete client: updates from 85%, named so", pct(u.fraction) == 85 && u.stage == .updatingGame)

        // MARK: update alone, game-wine.sh
        var up = ScriptProgress(.horizonUpdate)
        up.read("==> update 2.0.5 (1/1)\n" + summary(50))
        check("update: 50% of its download is 45% of the job, labelled 2.0.5",
              pct(up.fraction) == 45 && up.label == "2.0.5 · 1 of 1" && up.stage == .updatingGame)
        var gw = ScriptProgress(.gameWine)
        gw.read("==> downloading the game's Wine (203 MB) into /x\n[#game-wine 100/203MB(49%)]\n")
        let gwDown = gw.fraction
        gw.read("==> verifying the game's Wine\n==> extracting the game's Wine\n")
        check("game Wine: its download moves the button (\(pct(gwDown))%), its unpack is 90%",
              pct(gwDown) == 44 && pct(gw.fraction) == 90 && gw.stage == .gameWine)

        // MARK: the whole chain
        var x = PrimaryInputs()
        x.hasInstall = false; x.hasGame = false; x.patchedWineMissing = true
        check("a fresh Mac plans Wine, the game's Wine, the game and its finishing",
              SetupMeter.plan(x) == [.wine, .gameWine, .game, .configure])
        x = PrimaryInputs(); x.checks = [Check(id: "squareenix", title: "", state: .bad, detail: "", drive: "Games")]
        check("a drive that is gone plans a new install and the game", SetupMeter.plan(x).isSuperset(of: [.wine, .game]))
        x = PrimaryInputs(); x.patchedWineMissing = true
        check("only the game's Wine missing plans only that", SetupMeter.plan(x) == [.gameWine])

        var m = SetupMeter(planned: [.wine, .gameWine, .game, .configure])
        var shown: [Double] = [m.overall(0)]
        m.begin(.wine); shown.append(m.overall(0)); shown.append(m.overall(0.55))
        m.begin(.gameWine); shown.append(m.overall(0))           // a new job starts at 0
        shown.append(m.overall(0.5)); shown.append(m.overall(0))  // ... and its readout drops to 0 when it ends
        m.begin(.game); shown.append(m.overall(0)); shown.append(m.overall(0.5))
        shown.append(m.overall(0))                                // the download ended, the next not begun
        m.begin(.configure); shown.append(m.overall(0))
        check("the chain's figure only rises, step after step: \(shown.map(pct))",
              zip(shown, shown.dropFirst()).allSatisfy { $0 <= $1 } && shown.first == 0)
        check("half the game's download is past half the chain", shown[7] > 0.5)
        check("it never says 100% while working", shown.allSatisfy { $0 <= 0.99 } && m.overall(1) == 0.99)

        var a = SetupMeter(planned: [.wine, .gameWine, .game, .configure])
        a.begin(.wine)
        let w = a.overall(0.5)
        a.drop(.game)                                             // a complete client was found
        let dropped = a.overall(0.5)
        a.begin(.files); a.plan(.files)                           // ... and it is moved in
        let added = a.overall(0)
        check("a step found not needed makes it jump ahead (\(pct(w))% -> \(pct(dropped))%), one added never drops it (\(pct(added))%)",
              dropped > w && added >= dropped)
        var b = SetupMeter(planned: [.game])
        b.begin(.rosetta)
        check("a step that wasn't planned leaves it where it is", b.overall(0.7) == 0)

        // MARK: the button
        var y = PrimaryInputs()
        y.setupRunning = true; y.setupStage = .downloadingGame; y.setupProgress = 0.37
        let d1 = Primary.decide(y)
        check("the button names the step with the chain's figure: \(d1.label)", d1.label == "Downloading HorizonXI… 37%" && !d1.enabled)
        y.setupProgress = 0.004
        check("under 1% it shows no figure: \(Primary.decide(y).label)", Primary.decide(y).label == "Downloading HorizonXI…")
        y.setupStage = nil; y.setupProgress = 0
        check("choosing the folder: \(Primary.decide(y).label)", Primary.decide(y).label == "Setting up…")
        y.setupStage = .unpackingGame; y.setupProgress = 0.6
        check("the unzip: \(Primary.decide(y).label)", Primary.decide(y).label == "Unpacking HorizonXI… 60%")
        let longest = SetupStage.allCases.map { $0.rawValue + "… 99%" }.max { $0.count < $1.count } ?? ""
        check("every step's label fits the button (longest: \(longest), \(longest.count) characters)", longest.count <= 26)
        let jargon = ["prefix", "registry", "wineserver", "aria2", "torrent", "restart", "Restart"]
        check("plain words, never 'restart'", SetupStage.allCases.allSatisfy { s in !jargon.contains { s.rawValue.contains($0) } })
        check("the setup sheet's steps name themselves",
              SetupStage(Bootstrap.Step.download) == .downloadingWine && SetupStage(Bootstrap.Step.prefix) == .buildingWine
                && SetupStage(Bootstrap.Step.rosetta) == .rosetta)

        var failed = 0
        for (name, ok) in results {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failed += 1 }
        }
        print("\(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
