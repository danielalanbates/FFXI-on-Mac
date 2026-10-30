// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

import Foundation

enum CompanionSelfTest {
    @MainActor static func run() -> Never {
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

        checks.append(("note steps remain visible with their explanation",
                       GuideParser.parseStep("N Budget first.|N|Keep money for spells.|")?.note == "Keep money for spells."))
        checks.append(("buy steps retain item conditions",
                       GuideParser.parseStep("B Buy food.|IT|4376,3|")?.tags["IT"] == "4376,3"))

        checks.append(("starting-city entry point is retained for route navigation",
                       GuideParser.parseStep("t Start in Windurst.|START|Windurst||N|Starting location: Windurst.|")?.tags["START"] == "Windurst"))

        for nation in ["San d'Oria", "Bastok", "Windurst"] {
            for job in ["WAR", "MNK", "WHM", "BLM", "RDM", "THF"] {
                let advice = StarterFood.advice(job: job, nation: nation)
                checks.append(("food profile \(job) \(nation)",
                    advice.contains("Shop:") && advice.contains("MP drinks") == ["WHM", "BLM"].contains(job)))
            }
        }
        checks.append(("food profile unknown stays explicit",
                       StarterFood.advice(job: nil, nation: nil).contains("Choose")))

        checks.append(("displayed starting guide retains food controls",
                       StarterFood.isFoodStep(guide: QuestCatalogue.displayName("Starting out"),
                           title: "Buy a few affordable food portions before fighting.")))
        checks.append(("other guides do not borrow food controls",
                       !StarterFood.isFoodStep(guide: "Other", title: "Buy a few affordable food portions before fighting.")))

        let searchWiki = WikiState()
        searchWiki.monsters = [MonsterEntry(name: "Jaggedy-Eared Jack", zone: 100, family: "Rabbit", lo: 9, hi: 10,
            nm: true, drops: "Rabbit Charm", note: "G-9–H-9", source: "https://horizonffxi.wiki/Category:Rabbits", scope: "HorizonXI")]
        let searchGuides = [Guide(name: "Solo EXP", desc: "Leveling", levels: "1-75", steps: [
            GuideStep(kind: "K", title: "Defeat Forest Hare", note: "Rabbit hides")], server: "HorizonXI"),
            Guide(name: "Other server", desc: "rabbit", levels: "", steps: [], server: "Other")]
        let rabbitHits = GuideSearch.hits(query: "rabbit", guides: searchGuides, world: "HorizonXI", wiki: searchWiki, zones: WorldMap())
        checks.append(("rabbit search offers a monster-family database", rabbitHits.contains { $0.target == .family("Rabbit") }))
        checks.append(("rabbit search separately offers Jaggedy-Eared Jack", rabbitHits.contains { $0.target == .monster(searchWiki.monsters[0].id) }))
        checks.append(("rabbit search opens the exact matching guide step", rabbitHits.contains { $0.target == .guide(0, 0) && $0.subtitle.contains("Step 1") }))
        checks.append(("search excludes other-server guides", !rabbitHits.contains { $0.target == .guide(1, 0) }))
        checks.append(("search normalizes punctuation and case", GuideSearch.matches("jaggedy eared JACK", "Jaggedy-Eared Jack")))
        checks.append(("plural rabbits also finds the Rabbit family", GuideSearch.matches("rabbits", "Rabbit")))
        checks.append(("blank search offers no suggestions", GuideSearch.hits(query: "  ", guides: searchGuides, world: "HorizonXI", wiki: searchWiki, zones: WorldMap()).isEmpty))
        checks.append(("unmatched search offers no suggestions", GuideSearch.hits(query: "zzzznoentry", guides: searchGuides, world: "HorizonXI", wiki: searchWiki, zones: WorldMap()).isEmpty))
        if let root = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"] {
            let monsters = MonsterEntry.load(roots: [URL(fileURLWithPath: root)], world: "HorizonXI")
            checks.append(("Horizon monster data keeps Jack in West Ronfaure at 9-10", monsters.contains { $0.name == "Jaggedy-Eared Jack" && $0.zone == 100 && $0.lo == 9 && $0.hi == 10 && $0.family == "Rabbit" && $0.scope == "HorizonXI" }))
            checks.append(("Horizon rabbit family excludes the standard Nyzul duplicate", !monsters.contains { $0.name == "Jaggedy-Eared Jack" && $0.zone == 77 }))
        }

        var scoped = Guide(name: "Scoped", desc: "", levels: "", steps: [], server: "HorizonXI")
        checks.append(("server guide accepts matching world and spacing", scoped.available(on: "Horizon XI")))
        checks.append(("server guide excludes another or unknown world",
                       !scoped.available(on: "CatsEyeXI") && !scoped.available(on: "")))
        scoped.server = nil
        checks.append(("general guides remain available", scoped.available(on: "CatsEyeXI")))

        // An explicit developer source can exercise the real library. Offline fixtures must
        // never auto-discover/hydrate the user's Google Drive or request app permissions.
        let real = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("guides", isDirectory: true)
        }
        if let real {
            let library = GuideParser.loadAll(from: real)
            checks.append(("real authored guide library loads", library.count >= 2))
            checks.append(("every real guide parses at least three steps",
                           library.allSatisfy { $0.steps.count >= 3 }))
            checks.append(("every real guide step keeps an action and readable instruction",
                           library.allSatisfy { g in g.steps.allSatisfy {
                               !$0.kind.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           } }))
        }

        checks += achievementChecks(guides: guides)
        checks += screenshotChecks()
        checks += guideProgressChecks()
        checks += artifactJobChecks()

        var failures = 0
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
            if !passed { failures += 1 }
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
