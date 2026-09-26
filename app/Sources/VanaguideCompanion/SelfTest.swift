// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

import Foundation

enum CompanionSelfTest {
    static func run() -> Never {
        var checks: [(String, Bool)] = []

        let fixture = """
        -- Fixture guide
        G.register({
            name = "Fixture - Trial",
            author = 'Vanaguide',
            levels = '1+',
            desc = "A fixture route.",
            steps = [[
        A Accept the trial from Balasiel.|QA|sandoria,10|Z|230|POS|-138.33,65.76|N|No level check.|
        F Travel to King Ranperre's Tomb.|Z|190|
        t Examine the marker.|Z|193|POS|-94,273|FIXED||N|Use Done after the pool message.|
        K Defeat a Spook.|IT|940|Z|190|POS|2.9,-99.3|
        T Trade the root to Balasiel.|Q|sandoria,10|Z|230|POS|-138.33,65.76|
        ]],
        })
        """
        let guides = GuideParser.parse(fixture)
        checks.append(("fixture registers one guide", guides.count == 1))
        if let g = guides.first {
            checks.append(("guide name parses", g.name == "Fixture - Trial"))
            checks.append(("all five steps parse", g.steps.count == 5))
            if g.steps.count == 5 {
                checks.append(("acceptance keeps its QA tag", g.steps[0].tags["QA"] == "sandoria,10"))
                checks.append(("acceptance zone parses", g.steps[0].zone == 230))
                checks.append(("acceptance position parses",
                               g.steps[0].posX == -138.33 && g.steps[0].posZ == 65.76))
                checks.append(("travel step has zone only",
                               g.steps[1].zone == 190 && g.steps[1].posX == nil))
                checks.append(("FIXED after POS parses with note intact",
                               g.steps[2].fixed && g.steps[2].note == "Use Done after the pool message."))
                checks.append(("kill step keeps its item tag", g.steps[3].tags["IT"] == "940"))
                checks.append(("turn-in is not fixed", !g.steps[4].fixed))
            }
        }
        checks.append(("comment and junk lines are ignored",
                       GuideParser.parseStep("-- comment") == nil
                           && GuideParser.parseStep("]],") == nil
                           && GuideParser.parseStep("") == nil))

        // If the sibling checkout is present, the real guide library must parse without loss.
        let real = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/CloudStorage/GoogleDrive-danielalanbates@gmail.com/My Drive/Code/GitHub/vanaguide/Vanaguide/guides")
        if FileManager.default.fileExists(atPath: real.path) {
            let library = GuideParser.loadAll(from: real)
            checks.append(("real guide library loads at least ten guides", library.count >= 10))
            checks.append(("every real guide parses at least three steps",
                           library.allSatisfy { $0.steps.count >= 3 }))
            checks.append(("every real guide step has a zone, level, or tag",
                           library.allSatisfy { g in g.steps.allSatisfy {
                               $0.zone != nil || !$0.tags.isEmpty
                           } }))
        }

        var failures = 0
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
            if !passed { failures += 1 }
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
