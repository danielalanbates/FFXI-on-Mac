// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation

extension CompanionSelfTest {
    static func worldSelectionChecks() -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        var selection = LauncherWorldSelection()
        checks.append(("old launcher session does not overwrite existing Phoenix selection",
                       selection.observe("HorizonXI", current: "Phoenix XI") == nil))
        checks.append(("repeated timer ticks preserve manual Phoenix selection",
                       (0..<5).allSatisfy { _ in selection.observe("HorizonXI", current: "Phoenix XI") == nil }))
        var restarted = LauncherWorldSelection(lastWorld: selection.lastWorld)
        checks.append(("companion restart preserves manual Phoenix selection",
                       restarted.observe("HorizonXI", current: "Phoenix XI") == nil))
        checks.append(("a new launcher world is followed once",
                       selection.observe("CatsEyeXI", current: "Phoenix XI") == "CatsEyeXI"
                       && selection.observe("CatsEyeXI", current: "Phoenix XI") == nil))
        checks.append(("missing session cannot clear the observed world",
                       selection.observe(nil, current: "Phoenix XI") == nil && selection.lastWorld == "CatsEyeXI"))
        checks.append(("switching launcher back to Horizon still works",
                       selection.observe("HorizonXI", current: "Phoenix XI") == "HorizonXI"))
        var firstRun = LauncherWorldSelection()
        checks.append(("first run without a saved world adopts the launcher world",
                       firstRun.observe("Phoenix XI", current: "") == "Phoenix XI"))
        let source = Guide(name: "Solo Guide - HorizonXI", desc: "", levels: "1-75", steps: [
            GuideStep(kind: "C", title: "Farm silk", tags: ["EXP": "Crawler", "GIL": "Silk Thread", "SRC": "fixture"])
        ], server: "HorizonXI", progressID: "Solo Gil - HorizonXI", legacyProgressID: "Solo EXP - HorizonXI")
        let library = ClassicSoloGuide.addingReference(to: [source])
        let reference = library.last!
        checks.append(("shared solo route is available to Phoenix and other worlds but not duplicated on Horizon",
                       reference.available(on: "Phoenix XI") && reference.available(on: "CatsEyeXI") && !reference.available(on: "Horizon XI")))
        checks.append(("shared route retains goals and citations without sharing Horizon progress aliases",
                       reference.steps.first?.goals.count == 2 && reference.steps.first?.tags["SRC"] == "fixture"
                       && reference.progressKey != source.progressKey && reference.legacyProgressID == nil))
        checks.append(("shared route construction is idempotent", ClassicSoloGuide.addingReference(to: library).count == 2))
        return checks
    }
}
