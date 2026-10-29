// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

import Foundation

extension CompanionSelfTest {
    static func screenshotChecks() -> [(String, Bool)] {
        let quests = QuestCatalogue.parse("""
        local Q = {}
        Q.quests = { sandoria = {
          [10] = { name = 'A Squire\\'s Test', zone = 230, x = -138.33, z = 65.76, npc = 'Balasiel' },
          [11] = { name = 'A Squire\\'s Test II', zone = 230 },
        } }
        return Q
        """, mission: false)
        let missions = QuestCatalogue.parse("""
        local M = {}
        M.missions = { zilart = { [30] = { name = 'Dawn' } } }
        return M
        """, mission: true)
        let entries = quests + missions
        let authored = Guide(name: "Authored trial", desc: "", levels: "", steps: [
            GuideStep(kind: "A", title: "Speak with Balasiel", tags: ["QA": "sandoria,10"]),
            GuideStep(kind: "T", title: "Finish the trial", tags: ["Q": "sandoria,10"]),
        ])
        let guides = [authored] + QuestCatalogue.referenceGuides(entries)
        let match: (String) -> ScreenshotGuideMatch? = {
            ScreenshotGuideMatcher.match(text: $0, entries: entries, guides: guides)
        }
        let trial = match("Quest accepted: A Squire’s Test.")
        var tracker = ScreenshotMatchTracker()
        let first = tracker.observe(trial)
        let second = tracker.observe(trial)
        let third = tracker.observe(trial)
        _ = tracker.observe(nil)
        _ = tracker.observe(trial)
        let repeated = tracker.observe(trial)
        var interrupted = ScreenshotMatchTracker()
        _ = interrupted.observe(trial)
        _ = interrupted.observe(nil)
        let interruptedFirst = interrupted.observe(trial)

        var checks: [(String, Bool)] = [
            ("catalogue parses literal quest and mission facts", quests.count == 2 && missions.count == 1),
            ("OCR title normalizes curly apostrophes and punctuation", trial?.title == "A Squire's Test"),
            ("OCR opens authored acceptance before a generated reference", trial?.guide == 0 && trial?.step == 0),
            ("a quest giver's dialogue opens their quest", match("Balasiel : Bring me a root.")?.key == "Q:sandoria,10"),
            ("an unknown later speaker falls back to the last quest giver", match("Balasiel : Hello.\nGulemont : Ahhh!")?.key == "Q:sandoria,10"
                && match("Someone : Hi.\nBalasiel : Hello.")?.key == "Q:sandoria,10"),
            ("a player or unknown speaker opens nothing", match("Labguide : !pos 1 2 3") == nil),
            ("a speaker named only inside a line opens nothing", match("Ask Balasiel about it.") == nil),
            ("OCR rejects several quest titles in one capture",
             match("A Squire's Test\nMission: Dawn") == nil),
            ("OCR does not match inside a longer word", match("A Squire's Testing") == nil),
            ("OCR refuses an overlapping sequel title", match("A Squire's Test II") == nil),
            ("single-word dialogue needs a mission or quest label", match("Dawn") == nil),
            ("explicit single-word mission matches its reference", match("Mission: Dawn")?.key == "M:zilart,30"),
            ("empty OCR does not select a guide", match(" \n ") == nil),
            ("OCR needs two consecutive matching samples", first == nil && second == trial),
            ("persistent chat never pulls the guide backward again", third == nil && repeated == nil),
            ("a blank sample resets the two-sample confirmation", interruptedFirst == nil),
        ]
        let duplicate = QuestCatalogue.parse("local Q = { bastok = { [3] = { name = 'A Squire\\'s Test' } } }", mission: false)
        checks.append(("identical quest titles in different logs are ambiguous",
                       ScreenshotGuideMatcher.match(text: "A Squire's Test", entries: entries + duplicate,
                                                    guides: guides) == nil))
        let references = QuestCatalogue.referenceGuides(entries)
        if let trial {
            checks.append(("OCR preserves a manually advanced authored route checkpoint",
                           ScreenshotGuideMatcher.preservesCheckpoint(currentGuide: trial.guide, currentStep: 1,
                                                                     match: trial, guides: guides)))
        }
        let referenceMatch = ScreenshotGuideMatcher.match(text: "Quest: A Squire's Test", entries: entries,
                                                         guides: references)
        checks.append(("OCR selects earlier independent targets in the same reference list",
                       referenceMatch.map {
                           !ScreenshotGuideMatcher.preservesCheckpoint(currentGuide: $0.guide, currentStep: $0.step + 1,
                                                                       match: $0, guides: references)
                       } == true))
        let referenceStep = references.flatMap(\.steps).first { $0.tags["Q"] == "sandoria,10" }
        checks.append(("reference targets preserve recorded coordinates and stay manual",
                       referenceStep?.zone == 230 && referenceStep?.posX == -138.33
                           && referenceStep?.posZ == 65.76 && referenceStep?.fixed == true))
        // Getting started: a whole log page is read, many titles at once.
        let page = LogSurvey.read(text: "Quests\nSan d'Oria\nCompleted Quests\nA Squire's Test\nA Squire's Test II\nGil: 1200",
                                  entries: entries + duplicate, fallback: .current)
        checks.append(("log page records exact titles and its heading's list",
                       page.status == .completed && page.area == "sandoria" && page.keys == ["Q:sandoria,10", "Q:sandoria,11"]))
        checks.append(("log page without a heading uses the step's list",
                       LogSurvey.read(text: "A Squire's Test", entries: entries, fallback: .current).status == .current))
        checks.append(("a truncated long title matches its unique stem",
                       LogSurvey.read(text: "A Squire's Te...", entries: quests.filter { $0.id == 10 },
                                      fallback: .current).keys == ["Q:sandoria,10"]))
        var record = CharacterProgress(character: "Test", world: "Local")
        _ = record.record("Q:sandoria,10", .completed, source: "quest log")
        let downgraded = record.record("Q:sandoria,10", .current, source: "quest log")
        _ = record.record("Q:sandoria,11", .current, source: "quest log")
        let upgraded = record.record("Q:sandoria,11", .completed, source: "done")
        checks.append(("progress never downgrades completed; Done upgrades current",
                       !downgraded && upgraded && record.completedCount == 2 && record.currentCount == 0))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-progress-\(UUID().uuidString)")
        let saved = ProgressStore.save(record, in: dir)
        let loaded = ProgressStore.load(character: "Test", world: "Local", in: dir)
        try? FileManager.default.removeItem(at: dir)
        checks.append(("progress round-trips through its JSON file",
                       saved && loaded.entries.keys.sorted() == record.entries.keys.sorted()))
        checks.append(("character file names cannot escape the folder",
                       !ProgressStore.fileName(character: "../x", world: "a/b").contains("/")))
        checks.append(("guide names are shown in title case",
                       QuestCatalogue.displayName("Support jobs - Mhaura") == "Support Jobs — Mhaura"
                           && QuestCatalogue.displayName("San d'Oria - every quest") == "San d'Oria — Every Quest"
                           && QuestCatalogue.displayName("Starting out") == "Starting Out"))
        let map = WorldMap.parse(
            names: "local Z = {}\nZ.name = { [230] = 'Southern San d\\'Oria', [231] = 'Northern San d\\'Oria', [232] = 'Port San d\\'Oria', [246] = 'Port Jeuno' }\nZ.id = {}",
            zonelines: "local Z = {}\nZ.walk = { { 230, 231 }, { 231, 232 } }",
            travel: "local T = {}\nT.transit = { { from = 232, to = 246, via = 'Airship to Jeuno (Port San d\\'Oria counter)', cost = 420, pass = true } }\nreturn T")
        checks.append(("zones are shown by name, never by number",
                       map.name(232) == "Port San d'Oria" && map.name(nil) == "an unrecorded place"
                           && map.name(9999) == "an unnamed zone"))
        checks.append(("the current zone comes from the game's Area line",
                       map.zone(inChat: "Labguide : hi\n=== Area: Northern San d'Oria ===") == 231))
        let hops = map.route(from: 230, to: 246) ?? []
        checks.append(("routes walk zone to zone, then take transit, in plain words",
                       map.directions(hops) == ["Walk to Northern San d'Oria", "Walk to Port San d'Oria",
                                                "Airship to Jeuno (Port San d'Oria counter) (needs an Airship Pass)"]))
        checks.append(("already there is an empty route", map.route(from: 232, to: 232) == []))
        checks.append(("NPC names drop underscores", "Fyi_Chalmwoh".npcDisplay == "Fyi Chalmwoh"))
        checks.append(("??? spots read as markers, not names",
                       "qm1".npcDisplay == "the ??? marker" && "qm6 (H-10/Boat)".npcDisplay == "the ??? marker (H-10/Boat)"
                           && "Hanaa_Punaa".npcDisplay == "Hanaa Punaa"))
        checks.append(("misread addon lines are not speakers",
                       LearnedData.speakers(in: "Vanaguidel release : x\nHanaa Punaa : Hello") == ["Hanaa Punaa"]))
        checks.append(("speakers are read from NPC lines, not system lines",
                       LearnedData.speakers(in: "Gulemont : Ahhh!\n=== Area: Port San d'Oria ===\nObtained: Gil\n[1] Labguide : hi\nPortaure : Well, well...")
                           == ["Gulemont", "Portaure"]))
        var learned = LearnedData()
        _ = learned.hear("Gulemont : Ahhh!", zone: 232)
        _ = learned.hear("Gulemont : Ahhh!", zone: 232)
        learned.givers["Q:sandoria,10"] = LearnedGiver(npc: "Balasiel", zone: 230, recorded: Date(timeIntervalSince1970: 0))
        let exported = learned.export(entries: entries, zoneName: { "zone \($0)" }, date: Date(timeIntervalSince1970: 0))
        checks.append(("heard speakers are counted per zone", learned.speakers["Gulemont"]?["232"] == 2))
        checks.append(("export writes mergeable guide data",
                       exported.contains("[10] = { name = 'A Squire\\'s Test', zone = 230, npc = 'Balasiel' },")))
        checks.append(("a character-name window title is the character",
                       CharacterDiscovery.name(fromTitle: "Labguide") == "Labguide"
                           && CharacterDiscovery.name(fromTitle: "FFXI on Mac") == nil
                           && CharacterDiscovery.name(fromTitle: "FFXI") == nil))
        checks.append(("the status box gives the name beside the HP",
                       CharacterDiscovery.candidates(fromStatus: "Solo\nLabguide 507 g") == ["Labguide"]
                           && CharacterDiscovery.candidates(fromStatus: "Solo 3\nGil 1200 Gulemont") == []))
        var vote = CharacterDiscovery.Vote()
        let once = vote.observe(["Labguide"])
        let twice = vote.observe(["Labguide"])
        checks.append(("a name is trusted after two readings", once == nil && twice == "Labguide"))
        let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-session-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("session.json")
        try? Data(#"{"updated":"x","world":"Local server"}"#.utf8).write(to: sessionFile)
        checks.append(("the launcher's world fills in World",
                       CharacterDiscovery.launcherWorld(at: sessionFile) == "Local server"))
        checks.append(("before the launcher shares its list, Server lists the shipped worlds",
                       CharacterDiscovery.launcherWorlds(at: sessionFile).contains("HorizonXI")))
        try? Data(#"{"world":"CatsEyeXI","worlds":["CatsEyeXI","Local server"]}"#.utf8).write(to: sessionFile)
        checks.append(("Server lists exactly the launcher's servers, in its order",
                       CharacterDiscovery.launcherWorlds(at: sessionFile) == ["CatsEyeXI", "Local server"]
                       && CharacterDiscovery.launcherWorld(at: sessionFile) == "CatsEyeXI"))
        try? FileManager.default.removeItem(at: sessionDir)
        let rows = OCRPiece.rows([
            OCRPiece(text: "It's been twenty years", x: 0.2, midY: 0.50, height: 0.04, width: 0.5),
            OCRPiece(text: "Gulemont", x: 0.0, midY: 0.505, height: 0.04, width: 0.14),
            OCRPiece(text: "Deleted San d'Oria", x: 0.0, midY: 0.10, height: 0.04, width: 0.3),
            OCRPiece(text: "quest 6 from Labguide.", x: 0.31, midY: 0.10, height: 0.04, width: 0.3),
            OCRPiece(text: "=== Area: Port San d'Oria ===", x: 0.0, midY: 0.30, height: 0.04),
            OCRPiece(text: "Labguide : !pos 1 2 3", x: 0.0, midY: 0.70, height: 0.04),
        ])
        checks.append(("OCR pieces rebuild chat rows and the speaker separator",
                       rows == ["Labguide : !pos 1 2 3", "Gulemont : It's been twenty years",
                                "=== Area: Port San d'Oria ===", "Deleted San d'Oria quest 6 from Labguide."]))
        var me = LearnedData()
        checks.append(("the player's own lines are not speakers",
                       me.hear("Labguide : !pos 1\nGulemont : Hi", zone: 232, excluding: "Labguide") == ["Gulemont"]))
        var seen = Set(ChatDiff.keys(["top cut", "a", "Glenne : Oh"]))
        let arrivedFirst = ChatDiff.newLines(seen: &seen, current: ["top cut off", "a", "Glenne : Oh", "Lusiane : Hi"])
        let again = ChatDiff.newLines(seen: &seen, current: ["a", "Lusiane : Hi", "Glenne : Oh"])
        let repeatLine = ChatDiff.newLines(seen: &seen, current: ["a", "Glenne : Oh", "Lusiane : Hi", "Glenne : Oh"])
        checks.append(("a line counts once, the first time it shows; the cut top row never does",
                       arrivedFirst == ["Lusiane : Hi"] && again.isEmpty))
        checks.append(("an NPC repeating the same line is heard again", repeatLine == ["Glenne : Oh"]))
        var full = Set(ChatDiff.keys(["x", "a", "Glenne : Oh", "b"]))
        let scrolled = ChatDiff.newLines(seen: &full, previous: ["x", "a", "Glenne : Oh", "b"],
                                         current: ["a", "Glenne : Oh", "b", "Glenne : Oh"])
        checks.append(("a repeat that scrolls the old copy away is still heard", scrolled == ["Glenne : Oh"]))
        checks.append(("bottom chat crop scales to screenshot pixels",
                       ChatCrop().rect(width: 1600, height: 1000) == CGRect(x: 0, y: 650, width: 1600, height: 350)))
        checks.append(("invalid and nonfinite crop values are refused",
                       !ChatCrop(left: 90, top: 0, width: 20, height: 30).valid
                           && !ChatCrop(left: .nan, top: 0, width: 20, height: 30).valid
                           && !ChatCrop(left: 0, top: 0, width: 0, height: 30).valid))
        checks.append(("FFXI browser and terminal titles are never capture candidates",
                       !GameWindowIdentity.matches(title: "FFXI Wiki", owner: "Google Chrome",
                                                   bundle: "com.google.chrome", executable: "Google Chrome")
                           && !GameWindowIdentity.matches(title: "FFXI on Mac", owner: "Terminal",
                                                          bundle: "com.apple.Terminal", executable: "Terminal")))
        checks.append(("game-window title also needs Wine or game process identity",
                       GameWindowIdentity.matches(title: "FFXI on Mac", owner: "wine64-preloader",
                                                  bundle: "", executable: "wine64-preloader")
                           && GameWindowIdentity.matches(title: "HorizonXI", owner: "unknown",
                                                         bundle: "", executable: "horizon-loader.exe")
                           && !GameWindowIdentity.matches(title: "Notepad", owner: "wine64-preloader",
                                                          bundle: "org.winehq.wine", executable: "wine64-preloader")))
        checks.append(("a character-named window of an FFXI loader process is the game",
                       GameWindowIdentity.matches(title: "Labguide", owner: "wine", bundle: "",
                                                  executable: "wine", gameProcess: true)
                           && !GameWindowIdentity.matches(title: "Labguide", owner: "Google Chrome",
                                                          bundle: "com.google.chrome", executable: "Google Chrome",
                                                          gameProcess: true)
                           && !GameWindowIdentity.isGameProcess(ProcessInfo.processInfo.processIdentifier)))
        // Explicit developer override only: never enumerate or hydrate Drive during this fixture.
        if let path = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"] {
            let real = QuestCatalogue.entries(at: URL(fileURLWithPath: path))
            checks.append(("real quest and mission catalogues load over 500 named entries", real.count > 500))
            checks.append(("real database produces manual reference sections",
                           QuestCatalogue.referenceGuides(real).flatMap(\.steps).count == real.count
                               && QuestCatalogue.referenceGuides(real).flatMap(\.steps).allSatisfy(\.fixed)))
            let world = WorldMap.load(root: URL(fileURLWithPath: path))
            checks.append(("real zone names and routes load",
                           world.names.count > 250 && world.name(232) == "Port San d'Oria"
                               && world.route(from: 230, to: 232) != nil
                               && (world.route(from: 230, to: 246)?.isEmpty == false)))
            let located = real.filter { $0.data["zone"]?.int != nil }
            checks.append(("every located quest names a known zone",
                           located.allSatisfy { world.names[$0.data["zone"]!.int!] != nil }))
        }
        return checks
    }
}
