// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// The wiki side of Server-Safe: Gear (every piece of equipment, by how it is obtained) and
// Skills (a levelling guide per craft, fishing and combat/magic skill). Both are generated
// from the server's own data by the addon repository's tools/gen_gear_guide.py and
// tools/gen_skill_guides.py, and read here with LuaDataReader. Nothing is fetched online.

import SwiftUI

struct GearCategory: Identifiable, Equatable {
    var id: String
    var name: String
    var desc: String
    var count: Int
}

struct GearSource: Equatable {
    var kind: String
    var text: String
    var zone: Int?
    var npc: String?
}

struct GearItem: Identifiable, Equatable {
    var id: Int
    var name: String
    var level: Int
    var slot: String
    var jobs: String
    var rare: Bool
    var ex: Bool
    var categories: Set<String>
    var how: [GearSource]
}

struct ArtifactJob: Identifiable, Equatable {
    var id: String
    var name: String
    var count: Int
}

struct SkillGuide: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var group: String
    var desc: String
    var steps: [(title: String, note: String)]

    static func == (a: SkillGuide, b: SkillGuide) -> Bool { a.name == b.name && a.steps.count == b.steps.count }
}

enum WikiData {
    static func gear(_ url: URL) -> (categories: [GearCategory], items: [GearItem])? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // `local G = {}` is a table too; the data is the non-empty ones, in file order.
        let tables = LuaDataReader.tables(in: text).filter { !$0.array.isEmpty }
        guard tables.count >= 2 else { return nil }
        let cats = tables[0].array.compactMap { v -> GearCategory? in
            guard let t = v.table, let id = t["id"]?.string, let name = t["name"]?.string else { return nil }
            return GearCategory(id: id, name: name, desc: t["desc"]?.string ?? "", count: t["count"]?.int ?? 0)
        }
        let items = tables[1].array.compactMap { v -> GearItem? in
            guard let t = v.table, let id = t["id"]?.int, let name = t["name"]?.string else { return nil }
            let how = (t["how"]?.table?.array ?? []).compactMap { h -> GearSource? in
                guard let a = h.table?.array, a.count >= 2, let kind = a[0].string, let text = a[1].string else { return nil }
                return GearSource(kind: kind, text: text, zone: a.count > 2 ? a[2].int : nil,
                                  npc: a.count > 3 ? a[3].string : nil)
            }
            return GearItem(id: id, name: name, level: t["level"]?.int ?? 0, slot: t["slot"]?.string ?? "",
                            jobs: t["jobs"]?.string ?? "", rare: t["rare"] == .bool(true), ex: t["ex"] == .bool(true),
                            categories: Set((t["cats"]?.string ?? "").split(separator: " ").map(String.init)),
                            how: how)
        }
        return (cats, items)
    }

    static func skills(_ url: URL) -> [SkillGuide]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let list = LuaDataReader.tables(in: text).first(where: { !$0.array.isEmpty }) else { return nil }
        let guides = list.array.compactMap { v -> SkillGuide? in
            guard let t = v.table, let name = t["name"]?.string else { return nil }
            let steps = (t["steps"]?.table?.array ?? []).compactMap { s -> (String, String)? in
                guard let st = s.table, let title = st["title"]?.string else { return nil }
                return (title, st["note"]?.string ?? "")
            }
            return SkillGuide(name: name, group: t["group"]?.string ?? "", desc: t["desc"]?.string ?? "", steps: steps)
        }
        return guides.isEmpty ? nil : guides
    }
}

/// Gear and Skills state, loaded once in the background (the gear file is ~1.6 MB).
@MainActor
final class WikiState: ObservableObject {
    @Published var categories: [GearCategory] = []
    @Published var items: [GearItem] = []
    @Published var skills: [SkillGuide] = []
    @Published var note = "Loading…"
    @Published var category: String? = "artifact"
    @Published var search = ""
    @Published var job = "All"
    @Published var artifactJob: String?
    // --gear-item <id> (test hook) opens an item's page, for --snapshot.
    @Published var openItem: Int? = CommandLine.arguments.firstIndex(of: "--gear-item")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil }
    // --skill <name> (test hook) opens that skill, for --snapshot.
    @Published var skill: String? = CommandLine.arguments.firstIndex(of: "--skill")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    /// Server tab: notes (rates, rules, commands) and quest walkthroughs from the chosen server's
    /// own wiki or site, data/servers/<key>/server_notes.lua and quest_guides.lua.
    @Published var crafts: [String: [CraftRecipe]] = [:]
    @Published var targets: [SkillTarget] = []
    @Published var monsters: [MonsterEntry] = []
    @Published var nmDetails: [NMDetails] = []
    @Published var notes: [SkillGuide] = []
    @Published var quests: [SkillGuide] = []
    @Published var serverPick: String?
    @Published var serverSearch = ""

    static let jobs = ["All", "WAR", "MNK", "WHM", "BLM", "RDM", "THF", "PLD", "DRK", "BST", "BRD", "RNG", "SAM",
                       "NIN", "DRG", "SMN", "BLU", "COR", "PUP", "DNC", "SCH", "GEO", "RUN"]
    static let jobNames = ["WAR": "Warrior", "MNK": "Monk", "WHM": "White Mage", "BLM": "Black Mage",
                           "RDM": "Red Mage", "THF": "Thief", "PLD": "Paladin", "DRK": "Dark Knight",
                           "BST": "Beastmaster", "BRD": "Bard", "RNG": "Ranger", "SAM": "Samurai",
                           "NIN": "Ninja", "DRG": "Dragoon", "SMN": "Summoner", "BLU": "Blue Mage",
                           "COR": "Corsair", "PUP": "Puppetmaster", "DNC": "Dancer", "SCH": "Scholar",
                           "GEO": "Geomancer", "RUN": "Rune Fencer"]

    private static func fits(_ item: GearItem, job: String) -> Bool {
        item.jobs == "All jobs" || item.jobs.split(separator: " ").contains(Substring(job))
    }

    /// Artifact Armor opens a second menu, listing only jobs present in this server's data.
    var artifactJobs: [ArtifactJob] {
        let armor = items.filter { $0.categories.contains("artifact") }
        return Self.jobs.dropFirst().compactMap { job in
            let count = armor.filter { Self.fits($0, job: job) }.count
            return count == 0 ? nil : ArtifactJob(id: job, name: Self.jobNames[job] ?? job, count: count)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func selectGearCategory(_ id: String?) {
        category = id
        openItem = nil
        if id == "artifact" { artifactJob = nil }
    }

    func selectArtifactJob(_ job: String) {
        guard artifactJobs.contains(where: { $0.id == job }) else { return }
        artifactJob = job
        openItem = nil
        search = ""
    }

    /// The server whose data is shown: a key under data/servers/, or "" for standard LandSandBoat.
    @Published private(set) var serverKey = ""

    /// data/servers/<key>/ for a world whose own server source was read (CatsEyeXI, PegasusXI);
    /// other worlds get standard LandSandBoat data. "CatsEyeXI" -> "catseyexi".
    nonisolated static func serverKey(for world: String) -> String {
        world.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private var requestedWorld = ""

    func load(roots: [URL], world: String = "") {
        requestedWorld = world
        nmDetails = []; monsters = []; notes = []; quests = []; items = []; skills = []
        let key = Self.serverKey(for: world)
        Task.detached(priority: .userInitiated) {
            func pick<T>(_ file: String, _ read: (URL) -> T?) -> (T, Bool)? {
                if !key.isEmpty {
                    for root in roots {
                        if let own = read(root.appendingPathComponent("data/servers/\(key)/\(file)")) { return (own, true) }
                    }
                }
                for root in roots {
                    if let stock = read(root.appendingPathComponent("data/\(file)")) { return (stock, false) }
                }
                return nil
            }
            let gear = pick("gear_guide.lua", WikiData.gear)
            // A server's own skill file may cover only crafts (wiki sources): keep the standard
            // combat and magic guides for the groups it lacks.
            let skills: ([SkillGuide], Bool)? = {
                guard let own = pick("skill_guides.lua", WikiData.skills) else { return nil }
                guard own.1, let stock = roots.lazy.compactMap({ WikiData.skills($0.appendingPathComponent("data/skill_guides.lua")) }).first
                else { return own }
                let have = Set(own.0.map(\.group))
                return (own.0 + stock.filter { !have.contains($0.group) }, true)
            }()
            let crafts = pick("craft_recipes.lua", WikiData.crafts)
            let targets = pick("skill_targets.lua", WikiData.targets)
            func own(_ file: String) -> [SkillGuide] {
                guard !key.isEmpty else { return [] }
                for root in roots {
                    if let g = WikiData.skills(root.appendingPathComponent("data/servers/\(key)/\(file)")) { return g }
                }
                return []
            }
            let notes = own("server_notes.lua"), quests = own("quest_guides.lua")
            let monsters = MonsterEntry.load(roots: roots, world: world)
            let nmDetails = NMDetails.load(roots: roots, world: world)
            await MainActor.run {
                // A previous server's slower load must never replace the current results.
                guard Self.serverKey(for: self.requestedWorld) == key else { return }
                self.monsters = monsters
                self.nmDetails = nmDetails
                self.notes = notes
                self.quests = quests
                self.serverPick = notes.first.map { Self.tag($0) } ?? quests.first.map { Self.tag($0) }
                self.serverKey = (gear?.1 ?? false) || (skills?.1 ?? false) || !notes.isEmpty ? key : ""
                self.categories = gear?.0.categories ?? []
                self.items = gear?.0.items ?? []
                if let job = self.artifactJob, !self.artifactJobs.contains(where: { $0.id == job }) {
                    self.artifactJob = nil
                    self.openItem = nil
                }
                self.skills = skills?.0 ?? []
                self.crafts = crafts?.0 ?? [:]
                self.targets = targets?.0 ?? []
                if self.skill.map({ s in !self.skills.contains { $0.name == s } }) ?? true { self.skill = self.skills.first?.name }
                self.note = gear == nil ? "Gear list not installed (Vanaguide/data/gear_guide.lua)." : ""
            }
        }
    }

    /// Selection tag for the Server tab: quest names repeat across logs, so group + name.
    static func tag(_ g: SkillGuide) -> String { g.group + "\u{1}" + g.name }

    /// Quest areas in file order, filtered by the search box.
    var questGroups: [(String, [SkillGuide])] {
        let needle = serverSearch.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = [], byGroup: [String: [SkillGuide]] = [:]
        for q in quests where needle.isEmpty || q.name.lowercased().contains(needle) || q.desc.lowercased().contains(needle) {
            if byGroup[q.group] == nil { order.append(q.group) }
            byGroup[q.group, default: []].append(q)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    /// Where the Gear and Skills tabs' data comes from, for the player.
    func sourceLine(world: String) -> String {
        if !serverKey.isEmpty { return "From \(world)'s own server code or wiki." }
        return world.isEmpty ? "Standard LandSandBoat data." : "Standard LandSandBoat data; \(world) may differ."
    }

    var shown: [GearItem] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let selectedJob = category == "artifact" ? artifactJob : (job == "All" ? nil : job)
        return items.filter { i in
            (category.map { i.categories.contains($0) } ?? true)
                && (selectedJob.map { Self.fits(i, job: $0) } ?? true)
                && (needle.isEmpty || i.name.lowercased().contains(needle))
        }
    }
}

extension CompanionView {
    var gearPane: some View {
        HStack(spacing: 8) {
            Card { VStack(alignment: .leading, spacing: 6) {
                List(wiki.categories, selection: Binding(get: { wiki.category }, set: { wiki.selectGearCategory($0) })) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.callout)
                        Text("\(c.count) pieces").font(.caption2).foregroundStyle(Theme.muted)
                    }
                    .tag(Optional(c.id))
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
                Text(wiki.sourceLine(world: state.world))
                    .font(.caption2).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } }
            .frame(width: 190)
            Card {
                if let id = wiki.openItem, let item = wiki.items.first(where: { $0.id == id }) {
                    gearDetail(item)
                } else if wiki.category == "artifact", wiki.artifactJob == nil {
                    artifactJobMenu
                } else {
                    gearList
                }
            }
        }
    }

    var artifactJobMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Artifact Armor").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gold)
            List(wiki.artifactJobs) { job in
                Button { wiki.selectArtifactJob(job.id) } label: {
                    HStack {
                        Text(job.name).font(.callout)
                        Text(job.id).font(.caption).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(job.count)").font(.caption).foregroundStyle(Theme.muted)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.crystal)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            if wiki.artifactJobs.isEmpty {
                Text(wiki.note.isEmpty ? "No artifact armor in this server's gear data." : wiki.note)
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    var gearList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if wiki.category == "artifact", let job = wiki.artifactJob {
                Button { wiki.artifactJob = nil } label: { Label("Jobs", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.crystal)
                Text("\(WikiState.jobNames[job] ?? job) Artifact Armor")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gold)
            }
            if let c = wiki.categories.first(where: { $0.id == wiki.category }) {
                if c.id != "artifact" {
                    Text(c.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gold)
                }
                Text(c.desc).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                TextField("Search", text: $wiki.search).textFieldStyle(.roundedBorder)
                if wiki.category != "artifact" {
                    Picker("Job", selection: $wiki.job) { ForEach(WikiState.jobs, id: \.self) { Text($0).tag($0) } }
                        .frame(width: 110)
                }
            }
            .controlSize(.small)
            if !wiki.note.isEmpty { Text(wiki.note).font(.caption).foregroundStyle(Theme.ember) }
            let shown = wiki.shown
            List(shown.prefix(400)) { item in
                Button { wiki.openItem = item.id } label: {
                    HStack {
                        Text(item.name).font(.callout)
                        Spacer()
                        Text("Lv \(item.level) · \(item.slot.capitalized)").font(.caption).foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            Text(shown.count > 400 ? "Showing 400 of \(shown.count). Search or pick a job to narrow it."
                                   : "\(shown.count) pieces")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    func gearDetail(_ item: GearItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { wiki.openItem = nil } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.crystal)
            Text(item.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.gold)
            Text("Level \(item.level) · \(item.slot.capitalized) · \(item.jobs)" + (item.rare ? " · Rare" : "") + (item.ex ? " · Ex" : ""))
                .font(.caption).foregroundStyle(Theme.muted)
            SectionLabel(text: "How to get it")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(item.how.enumerated()), id: \.offset) { _, h in
                        VStack(alignment: .leading, spacing: 2) {
                            if h.kind == "quest" || h.kind == "mission", let target = state.questStep(named: h.text) {
                                // Opens that quest's step in Guides, with its What to do.
                                Button {
                                    state.selected = target.guide
                                    state.stepIndex = target.step
                                    tab = 0
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(h.text).underline().multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Image(systemName: "arrow.right.circle")
                                    }
                                    .font(.callout).foregroundStyle(Theme.crystal)
                                }
                                .buttonStyle(.plain)
                                .help("Open this quest's guide")
                            } else if let q = (h.kind == "quest" || h.kind == "mission") ? wiki.quests.first(where: { h.text.localizedCaseInsensitiveContains($0.name) }) : nil {
                                // A quest only this server's wiki knows: its walkthrough on the Server tab.
                                Button {
                                    wiki.serverPick = WikiState.tag(q)
                                    searchPage = .server(WikiState.tag(q)); tab = 0
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(h.text).underline().multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Image(systemName: "arrow.right.circle")
                                    }
                                    .font(.callout).foregroundStyle(Theme.crystal)
                                }
                                .buttonStyle(.plain)
                                .help("Open this quest's walkthrough")
                            } else {
                                Text(h.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(wiki.nmDetails.filter { nm in
                                (h.zone == nil || h.zone == nm.zone) &&
                                (h.kind == "nm" || h.kind == "drop") && h.text.localizedCaseInsensitiveContains(nm.name)
                            }) { nm in nmDetail(nm) }
                            let place = [h.npc.map { $0 == "???" ? "the ??? marker" : $0.npcDisplay },
                                         h.zone.map { state.zones.name($0) }].compactMap { $0 }
                            if !place.isEmpty {
                                Label(place.joined(separator: " in "), systemImage: "mappin.and.ellipse")
                                    .font(.caption).foregroundStyle(Theme.crystal)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var skillsPane: some View {
        HStack(spacing: 8) {
            Card { VStack(alignment: .leading, spacing: 6) {
                List(selection: $wiki.skill) {
                    ForEach(["Crafting", "Combat", "Defense", "Magic"], id: \.self) { group in
                        let list = wiki.skills.filter { $0.group == group }
                        if !list.isEmpty {
                            Section(group) {
                                ForEach(list) { s in Text(s.name).font(.callout).tag(Optional(s.name)) }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
                Text(wiki.sourceLine(world: state.world))
                    .font(.caption2).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } }
            .frame(width: 190)
            Card {
                if let s = wiki.skills.first(where: { $0.name == wiki.skill }),
                   wiki.crafts[s.name] != nil || (s.group != "Crafting" && !wiki.targets.isEmpty) {
                    skillPicker(s)
                } else {
                    guideDetail(wiki.skills.first(where: { $0.name == wiki.skill }),
                                empty: wiki.skills.isEmpty ? "Skill guides not installed (Vanaguide/data/skill_guides.lua)." : "Pick a skill.")
                }
            }
        }
    }

    var serverPane: some View {
        HStack(spacing: 8) {
            Card { VStack(alignment: .leading, spacing: 6) {
                if !wiki.quests.isEmpty {
                    TextField("Search quests", text: $wiki.serverSearch).textFieldStyle(.roundedBorder)
                }
                List(selection: $wiki.serverPick) {
                    if !wiki.notes.isEmpty {
                        Section(state.world.isEmpty ? "Server" : state.world) {
                            ForEach(wiki.notes) { g in Text(g.name).font(.callout).tag(Optional(WikiState.tag(g))) }
                        }
                    }
                    ForEach(wiki.questGroups, id: \.0) { group, list in
                        Section(group) {
                            ForEach(list, id: \.self.name) { g in Text(g.name).font(.callout).tag(Optional(WikiState.tag(g))) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
            } }
            .frame(width: 210)
            Card { guideDetail((wiki.notes + wiki.quests).first(where: { WikiState.tag($0) == wiki.serverPick }),
                               empty: wiki.notes.isEmpty
                                   ? (state.world.isEmpty ? "Choose your server above." : "No notes for \(state.world) yet; Gear and Skills show standard LandSandBoat data.")
                                   : "Pick a topic.") }
        }
    }

    /// The player's level in a skill, remembered per server, character and skill.
    func skillLevel(_ skill: String) -> Binding<Int> {
        let key = "skill.level.\(state.world).\(state.character).\(skill)"
        return Binding(get: { UserDefaults.standard.integer(forKey: key) },
                       set: { UserDefaults.standard.set(min(max($0, 0), 110), forKey: key); wiki.objectWillChange.send() })
    }

    @ViewBuilder
    func skillPicker(_ s: SkillGuide) -> some View {
        let craft = wiki.crafts[s.name]
        let level = skillLevel(s.name)
        VStack(alignment: .leading, spacing: 8) {
            Text(s.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gold)
            HStack(spacing: 6) {
                Text(craft != nil ? "Your \(s.name) level" : "Your job level").font(.callout)
                TextField("", value: level, format: .number)
                    .frame(width: 52).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .modifier(ArrowKeys(value: level))
                Stepper("", value: level, in: 0...110).labelsHidden()
                Text("Type it, or use ↑ ↓").font(.caption).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let craft {
                        recipeCard("Best for skill-ups", SkillPicks.forSkill(craft, level: level.wrappedValue), gil: false)
                        recipeCard("Skill-ups while making gil", SkillPicks.forGil(craft, level: level.wrappedValue), gil: true)
                        Text("Recipes a little above your level give skill-ups; about 3 levels above balances skill-ups against failed synths. Prices are what NPCs charge; gil is what the result sells to an NPC for (the auction house often pays more).")
                            .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        monsterCard(SkillPicks.monster(wiki.targets, level: level.wrappedValue))
                        Text("Skill rises when you use it on monsters that aren't too weak for you. This one is at or a little above your level, doesn't attack on sight, and has many spawns.")
                            .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if !s.steps.isEmpty {
                        DisclosureGroup("Full \(s.name) guide") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(s.steps.enumerated()), id: \.offset) { _, st in
                                    SectionLabel(text: st.title)
                                    Text(st.note).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                            }
                        }
                        .font(.caption).tint(Theme.crystal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    func recipeCard(_ title: String, _ r: CraftRecipe?, gil: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: title)
            if let r {
                Text("\(r.name)").font(.system(size: 14, weight: .semibold))
                Text("Recipe level \(r.level)" + (r.other.isEmpty ? "" : " · also needs \(r.other.joined(separator: ", "))"))
                    .font(.caption).foregroundStyle(Theme.muted)
                Text("\(r.crystal) + " + r.parts.joined(separator: ", ")).font(.callout)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack(spacing: 10) {
                    Text(r.cost.map { "Costs \($0) gil" } ?? "Some ingredients aren't sold by NPCs")
                    Text("Sells for \(r.sell) gil")
                    if gil, let p = r.profit {
                        Text(p >= 0 ? "+\(p) gil each" : "\(p) gil each").foregroundStyle(p >= 0 ? Theme.jade : Theme.ember)
                    }
                }
                .font(.caption)
                if gil, let p = r.profit, p < 0 {
                    Text("Nothing in this range makes gil selling to NPCs; this one loses the least.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            } else {
                Text(gil ? "No recipe in this range has NPC-sold ingredients to price." : "No recipe above this level.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder
    func monsterCard(_ m: SkillTarget?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Fight this")
            if let m {
                Text(m.name).font(.system(size: 14, weight: .semibold))
                Label("in \(state.zones.name(m.zone))", systemImage: "mappin.and.ellipse")
                    .font(.callout).foregroundStyle(Theme.crystal)
                Text("Level \(m.min == m.max ? "\(m.min)" : "\(m.min)–\(m.max)") · \(m.spawns) spawns"
                     + (m.links ? " · calls for help from its kind" : ""))
                    .font(.caption).foregroundStyle(Theme.muted)
            } else {
                Text("No suitable monster found for this level.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder
    func guideDetail(_ guide: SkillGuide?, empty: String) -> some View {
                if let s = guide {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gold)
                        Text(s.desc).font(.caption).foregroundStyle(Theme.muted)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(s.steps.enumerated()), id: \.offset) { _, st in
                                    VStack(alignment: .leading, spacing: 4) {
                                        SectionLabel(text: st.title)
                                        Text(st.note).font(.callout).fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Text(empty).font(.caption).foregroundStyle(Theme.muted)
                }
    }
}

/// ↑ and ↓ in the level box step the level (macOS 14; Server-Safe requires 14, the package 13).
struct ArrowKeys: ViewModifier {
    var value: Binding<Int>
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.upArrow) { value.wrappedValue += 1; return .handled }
                .onKeyPress(.downArrow) { value.wrappedValue -= 1; return .handled }
        } else {
            content
        }
    }
}
