// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

import Foundation

/// Reads literal tables only. generated.lua executes Lua to create most addon guides, so its
/// content is deliberately recreated here from the same bundled quest/mission facts.
struct CatalogueEntry {
    let key: String
    let name: String
    let area: String
    let id: Int
    let mission: Bool
    let data: LuaTable

    var tag: String { "\(area),\(id)" }
}

enum QuestCatalogue {
    static func entries(at root: URL) -> [CatalogueEntry] {
        [read(root.appendingPathComponent("data/quests.lua"), mission: false),
         read(root.appendingPathComponent("data/missions.lua"), mission: true)].flatMap { $0 }
    }

    static func read(_ file: URL, mission: Bool) -> [CatalogueEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parse(text, mission: mission)
    }

    static func parse(_ text: String, mission: Bool) -> [CatalogueEntry] {
        var entries: [CatalogueEntry] = []
        for table in LuaDataReader.tables(in: text) {
            for area in table.keys.sorted() {
                guard let values = table[area]?.table else { continue }
                for key in values.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                    guard let id = Int(key), let data = values[key]?.table,
                          let name = data["name"]?.string, !name.isEmpty else { continue }
                    entries.append(CatalogueEntry(key: "\(mission ? "M" : "Q"):\(area),\(id)",
                                                  name: name, area: area, id: id,
                                                  mission: mission, data: data))
                }
            }
        }
        return entries
    }

    /// One reference section per log area. These provide recorded targets, not an invented
    /// walkthrough. Authored routes remain at the front of the guide list.
    /// What to do for each quest and mission, written from the server's scripts
    /// (data/quest_steps.lua, built by the addon repository's tools/gen_quest_steps.py).
    /// Keyed like CatalogueEntry.key: "Q:sandoria,0". `scripted` is full, partial or stub.
    struct Walkthrough: Equatable { var steps: [String]; var scripted: String }

    static func walkthroughs(at root: URL) -> [String: Walkthrough] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("data/quest_steps.lua"), encoding: .utf8)
        else { return [:] }
        var out: [String: Walkthrough] = [:]
        // T.quests then T.missions: { area = { [id] = { scripted = '…', steps = { '…' } } } }
        for (n, table) in LuaDataReader.tables(in: text).filter({ !$0.keys.isEmpty }).prefix(2).enumerated() {
            for area in table.keys {
                guard let ids = table[area]?.table else { continue }
                for key in ids.keys {
                    guard let id = Int(key), let e = ids[key]?.table else { continue }
                    let steps = (e["steps"]?.table?.array ?? []).compactMap(\.string)
                    guard !steps.isEmpty else { continue }
                    out["\(n == 0 ? "Q" : "M"):\(area),\(id)"] = Walkthrough(steps: steps, scripted: e["scripted"]?.string ?? "full")
                }
            }
        }
        return out
    }

    /// Quests that unlock a job (their scripts call player:unlockJob), in the game's job order.
    /// Dragoon (The Holy Crest) and Rune Fencer are added when the quest data has them.
    static let jobUnlocks: [(job: String, quest: String)] = [
        ("Paladin", "A Knight's Test"), ("Dark Knight", "Blade of Darkness"),
        ("Beastmaster", "Path of the Beastmaster"), ("Bard", "Path of the Bard"),
        ("Ranger", "The Fanged One"), ("Samurai", "Forge Your Destiny"), ("Ninja", "Ayame and Kaede"),
        ("Dragoon", "The Holy Crest"), ("Summoner", "I Can Hear a Rainbow"),
        ("Blue Mage", "An Empty Vessel"), ("Corsair", "Luck of the Draw"), ("Puppetmaster", "No Strings Attached"),
        ("Dancer", "Lakeside Minuet"), ("Scholar", "A Little Knowledge"), ("Geomancer", "Dances with Luopans"),
        ("Rune Fencer", "Children of the Rune"),
    ]

    /// "Job Unlocks": one step per advanced job, copied from the quest's own reference step so
    /// it carries the same location and What to do.
    static func jobUnlockGuide(from references: [Guide]) -> Guide? {
        let steps: [GuideStep] = jobUnlocks.compactMap { job, quest in
            guard let hit = CompanionState.questStep(in: references, named: "Quest: " + quest) else { return nil }
            var st = references[hit.guide].steps[hit.step]
            st.tags["JOB"] = job
            return st
        }
        guard !steps.isEmpty else { return nil }
        return Guide(name: "Job Unlocks", desc: "The quest that unlocks each advanced job. Reach level 30 on any job first; most start in a nation city or Jeuno.",
                     levels: "", steps: steps, isReference: true)
    }

    /// Content order (Daniel, 2026-10-28): jobs, then missions, then quests. Starting Out and
    /// other authored routes stay at the very top; Job Unlocks and Support Jobs make up Jobs.
    static func section(of g: Guide) -> String {
        if g.name.hasSuffix(" Missions") { return "Missions" }
        if g.name.hasSuffix(" Quests") { return "Quests" }
        if g.name == "Job Unlocks" || g.name.localizedCaseInsensitiveContains("job") { return "Jobs" }
        return "Start Here"
    }
    static let sectionOrder = ["Start Here", "Jobs", "Missions", "Quests"]

    /// Within Missions and Quests: the three nations, then the expansions in release order.
    static let storyOrder = ["San d'Oria", "Bastok", "Windurst", "Jeuno", "Rise of the Zilart", "Other Areas",
                             "Outlands", "Chains of Promathia", "Treasures of Aht Urhgan", "Aht Urhgan",
                             "Wings of the Goddess", "Crystal War", "A Crystalline Prophecy", "A Moogle Kupo d'Etat",
                             "A Shantotto Ascension", "Abyssea", "Seekers of Adoulin", "Adoulin", "Coalition",
                             "Rhapsodies of Vana'diel", "The Voracious Resurgence"]

    static func storyRank(_ g: Guide) -> Int {
        let area = g.name.replacingOccurrences(of: #" (Missions|Quests)$"#, with: "", options: .regularExpression)
        return storyOrder.firstIndex(of: area) ?? storyOrder.count
    }

    static func contentOrder(_ guides: [Guide]) -> [Guide] {
        guides.enumerated().sorted { a, b in
            let sa = sectionOrder.firstIndex(of: section(of: a.element)) ?? 0
            let sb = sectionOrder.firstIndex(of: section(of: b.element)) ?? 0
            if sa != sb { return sa < sb }
            let ra = storyRank(a.element), rb = storyRank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    static func referenceGuides(_ entries: [CatalogueEntry], walkthroughs: [String: Walkthrough] = [:]) -> [Guide] {
        let groups = Dictionary(grouping: entries) { "\(areaName($0.area, mission: $0.mission)) \($0.mission ? "Missions" : "Quests")" }
        // Quests before missions, each alphabetical.
        let titles = groups.keys.sorted { a, b in
            let am = a.hasSuffix("Missions"), bm = b.hasSuffix("Missions")
            return am == bm ? a < b : !am
        }
        return titles.map { title in
            let steps = (groups[title] ?? []).map { entry in
                let d = entry.data
                var tags = [entry.mission ? "M" : "Q": entry.tag]
                if let npc = d["npc"]?.string { tags["NPC"] = npc }
                if let level = d["level"]?.int { tags["LV"] = String(level) }
                let walk = walkthroughs[entry.key]
                if let walk { tags["WALK"] = walk.scripted }
                return GuideStep(kind: entry.mission ? "M" : "Q", title: entry.name, zone: d["zone"]?.int,
                                 posX: number(d["x"]), posZ: number(d["z"]), note: walk?.steps.joined(separator: "\n"),
                                 fixed: true, tags: tags)
            }
            return Guide(name: title, desc: "Every quest or mission in this log. Work down the list; Next Unfinished skips ones you have done.",
                         levels: "", steps: steps, isReference: true)
        }
    }

    /// Title case for guide names written in sentence case ("Support jobs - Mhaura" becomes
    /// "Support Jobs — Mhaura"). Display only: the addon keys saved progress by the original name.
    static func displayName(_ name: String) -> String {
        let small: Set<String> = ["a", "an", "and", "at", "by", "for", "in", "of", "on", "or", "the", "to"]
        let words = name.replacingOccurrences(of: " - ", with: " — ").split(separator: " ", omittingEmptySubsequences: false)
        return words.enumerated().map { i, w in
            let word = String(w)
            if i > 0 && small.contains(word.lowercased()) { return word.lowercased() }
            // "d'Oria" keeps its particle lowercase.
            guard let first = word.first, first.isLowercase, !word.hasPrefix("d'") else { return word }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// Display names for the database's log areas.
    static func areaName(_ area: String, mission: Bool) -> String {
        let names: [String: String] = [
            "sandoria": "San d'Oria", "bastok": "Bastok", "windurst": "Windurst", "jeuno": "Jeuno",
            "other": "Other Areas", "outlands": "Outlands", "ahturhgan": "Aht Urhgan",
            "abyssea": "Abyssea", "adoulin": mission ? "Seekers of Adoulin" : "Adoulin",
            "coalition": "Coalition", "wotg": mission ? "Wings of the Goddess" : "Crystal War",
            "zilart": "Rise of the Zilart", "cop": "Chains of Promathia", "toau": "Treasures of Aht Urhgan",
            "rov": "Rhapsodies of Vana'diel", "tvr": "The Voracious Resurgence",
            "acp": "A Crystalline Prophecy", "amk": "A Moogle Kupo d'Etat", "asa": "A Shantotto Ascension",
        ]
        return names[area] ?? area.capitalized
    }

    private static func number(_ value: LuaValue?) -> Double? {
        guard let text = value?.string else { return nil }
        return Double(text)
    }
}

struct ScreenshotGuideMatch: Equatable {
    let key: String
    let title: String
    let guide: Int
    let step: Int
}

enum ScreenshotGuideMatcher {
    /// An authored route's manual checkpoint stays ahead of a recognized acceptance step.
    /// Reference lists contain unrelated quest IDs, so a lower index is a new target, not a rewind.
    static func preservesCheckpoint(currentGuide: Int, currentStep: Int,
                                    match: ScreenshotGuideMatch, guides: [Guide]) -> Bool {
        currentGuide == match.guide && currentStep > match.step
            && guides.indices.contains(currentGuide) && !guides[currentGuide].isReference
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Exact normalized title, with word boundaries; no fuzzy guesses from item chatter. A single
    /// short word such as "Dawn" requires an explicit quest/mission label. Without a title, an
    /// exact quest-giver speaker name is the fallback (see speakerMatch).
    static func match(text: String, entries: [CatalogueEntry], guides: [Guide],
                      speakers: Bool = true) -> ScreenshotGuideMatch? {
        let lines = text.components(separatedBy: .newlines).map(normalized).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var hits: [CatalogueEntry] = []
        for entry in entries {
            let name = normalized(entry.name)
            guard !name.isEmpty else { continue }
            let words = name.split(separator: " ")
            let found = lines.contains { line in
                guard (" " + line + " ").contains(" " + name + " ") else { return false }
                if words.count < 2 {
                    return line.hasPrefix("quest " + name) || line.hasPrefix("mission " + name)
                }
                if name.count < 9 {
                    return line == name || line.hasPrefix("quest " + name) || line.hasPrefix("mission " + name)
                }
                return true
            }
            if found { hits.append(entry) }
        }
        // The same name in multiple logs, or several names on one screenshot, is ambiguous.
        if hits.count > 1 { return nil }
        if let entry = hits.first { return locate(entry, title: entry.name, guides: guides) }
        return speakers ? speakerMatch(text: text, entries: entries, guides: guides) : nil
    }

    /// FFXI rarely prints a quest's title, but every NPC line starts with the speaker:
    /// "Gulemont : Ahhh, now I've gone and done it!".  When the speaker's whole name is a
    /// recorded quest giver, open that NPC's quest.  The newest speaker line wins; a giver of
    /// several quests opens the first and says how many, rather than guessing which one.
    static func speakerMatch(text: String, entries: [CatalogueEntry], guides: [Guide]) -> ScreenshotGuideMatch? {
        var givers: [String: [CatalogueEntry]] = [:]
        for entry in entries {
            guard let npc = entry.data["npc"]?.string else { continue }
            let name = normalized(npc)
            if !name.isEmpty { givers[name, default: []].append(entry) }
        }
        for line in text.components(separatedBy: .newlines).reversed() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let speaker = normalized(String(line[..<colon]))
            guard let offered = givers[speaker], let first = offered.first else { continue }
            let title = offered.count == 1 ? first.name
                : "\(first.name) (\(String(line[..<colon]).trimmingCharacters(in: .whitespaces)) offers \(offered.count))"
            return locate(first, title: title, guides: guides)
        }
        return nil
    }

    private static func locate(_ entry: CatalogueEntry, title: String, guides: [Guide]) -> ScreenshotGuideMatch? {
        for (gi, guide) in guides.enumerated() {
            for (si, step) in guide.steps.enumerated() {
                let tags = entry.mission ? ["M", "MA"] : ["Q", "QA"]
                if tags.contains(where: { step.tags[$0] == entry.tag }) {
                    return ScreenshotGuideMatch(key: entry.key, title: title, guide: gi, step: si)
                }
            }
        }
        return nil
    }
}

/// Debounces persistent chat text. Re-reading the same line must not keep jumping back after
/// the player uses Next. Nothing in this state machine marks a quest or guide step complete.
struct ScreenshotMatchTracker {
    private var previous: String?
    private var repeated = 0
    private var opened = Set<String>()

    /// A quest giver speaking on a line that just appeared is enough on its own; each quest is
    /// still opened only once per reading session.
    mutating func openOnce(_ match: ScreenshotGuideMatch?) -> ScreenshotGuideMatch? {
        guard let match, opened.insert(match.key).inserted else { return nil }
        return match
    }

    mutating func observe(_ match: ScreenshotGuideMatch?) -> ScreenshotGuideMatch? {
        guard let match else { previous = nil; repeated = 0; return nil }
        if previous == match.key { repeated += 1 } else { previous = match.key; repeated = 1 }
        guard repeated >= 2, opened.insert(match.key).inserted else { return nil }
        return match
    }
}
