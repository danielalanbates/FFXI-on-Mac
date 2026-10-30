// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation
import SwiftUI

struct MonsterEntry: Identifiable, Equatable {
    var name: String
    var zone: Int
    var family: String
    var lo: Int
    var hi: Int
    var nm: Bool
    var drops: String
    var note: String
    var source: String
    var scope: String
    var searchText = ""
    var id: String { "\(name)\u{1}\(zone)" }

    static func read(_ url: URL) -> [MonsterEntry]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return LuaDataReader.tables(in: text).flatMap(\.array).compactMap { value in
            guard let t = value.table, let name = t["name"]?.string, let zone = t["zone"]?.int,
                  let family = t["family"]?.string, let lo = t["lo"]?.int, let hi = t["hi"]?.int else { return nil }
            return MonsterEntry(name: name, zone: zone, family: family, lo: lo, hi: hi,
                nm: t["nm"]?.string == "true", drops: t["drops"]?.string ?? "",
                note: t["note"]?.string ?? "", source: t["source"]?.string ?? "", scope: t["scope"]?.string ?? "Standard reference")
        }
    }

    static func load(roots: [URL], world: String) -> [MonsterEntry] {
        let stock = roots.lazy.compactMap { read($0.appendingPathComponent("data/monster_search.lua")) }.first ?? []
        let key = WikiState.serverKey(for: world)
        let own = roots.lazy.compactMap { read($0.appendingPathComponent("data/servers/\(key)/monster_search.lua")) }.first ?? []
        // A sourced server family replaces that whole standard family, including later-era variants.
        let families = Set(own.map(\.family))
        let zones = roots.first.map { WorldMap.load(root: $0) } ?? WorldMap()
        return (own + stock.filter { !families.contains($0.family) }).map {
            var mob = $0
            mob.searchText = GuideSearch.key("\(mob.name) \(mob.family) \(zones.name(mob.zone)) \(mob.drops)")
            return mob
        }
    }
}

enum GuideSearchTarget: Equatable {
    case guide(Int, Int?)
    case family(String)
    case monster(String)
    case gear(Int)
    case skill(String)
    case server(String)
}

struct GuideSearchHit: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var icon: String
    var target: GuideSearchTarget
}

enum GuideSearch {
    static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }
    static func words(_ query: String) -> [String] {
        key(query).split(separator: " ").map { word in
            word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
        }
    }
    static func matches(_ query: String, _ text: String) -> Bool {
        let haystack = key(text)
        let words = words(query)
        return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
    }

    @MainActor static func hits(query: String, guides: [Guide], world: String, wiki: WikiState, zones: WorldMap) -> [GuideSearchHit] {
        guard !key(query).isEmpty else { return [] }
        var result: [GuideSearchHit] = []
        for family in Set(wiki.monsters.map(\.family)).sorted() where matches(query, family) {
            result.append(GuideSearchHit(id: "family:\(family)", title: family == "Rabbit" ? "Rabbits" : family,
                subtitle: "Monster database", icon: "books.vertical", target: .family(family)))
            if result.count == 4 { break }
        }
        let words = words(query)
        let monsters = wiki.monsters.filter { mob in
            let text = mob.searchText.isEmpty ? key("\(mob.name) \(mob.family) \(zones.name(mob.zone)) \(mob.drops)") : mob.searchText
            return words.allSatisfy { text.contains($0) }
        }
            .sorted { a, b in
                let aName = matches(query, a.name), bName = matches(query, b.name)
                if aName != bName { return aName }
                return a.name == b.name ? a.zone < b.zone : a.name < b.name
            }
        // Keep separate room for named notorious monsters and ordinary monsters.
        for mob in Array(monsters.filter(\.nm).prefix(8)) + Array(monsters.filter { !$0.nm }.prefix(4)) {
            result.append(GuideSearchHit(id: "mob:\(mob.id)", title: mob.name,
                subtitle: "\(mob.nm ? "Notorious monster" : "Monster") · \(zones.name(mob.zone)) · \(mob.scope)",
                icon: mob.nm ? "star" : "pawprint", target: .monster(mob.id)))
        }
        var guideHits: [GuideSearchHit] = [], stepHits: [GuideSearchHit] = []
        for (index, guide) in guides.enumerated() where guide.available(on: world) {
            if matches(query, "\(guide.name) \(guide.desc)") && guideHits.count < 5 {
                guideHits.append(GuideSearchHit(id: "guide:\(index)", title: guide.name, subtitle: "Guide",
                    icon: "map", target: .guide(index, nil)))
            }
            if stepHits.count < 8 {
                for (step, entry) in guide.steps.enumerated() where matches(query, "\(entry.title) \(entry.note ?? "")") {
                    stepHits.append(GuideSearchHit(id: "step:\(index):\(step)", title: entry.title,
                        subtitle: "\(guide.name) · Step \(step + 1)", icon: "list.number", target: .guide(index, step)))
                    if stepHits.count == 8 { break }
                }
            }
        }
        result += guideHits + stepHits
        for item in wiki.items.lazy.filter({ matches(query, $0.name) }).prefix(4) {
            result.append(GuideSearchHit(id: "gear:\(item.id)", title: item.name, subtitle: "Gear · Level \(item.level)",
                icon: "shield", target: .gear(item.id)))
        }
        for skill in wiki.skills.lazy.filter({ matches(query, "\($0.name) \($0.desc)") }).prefix(3) {
            result.append(GuideSearchHit(id: "skill:\(skill.name)", title: skill.name, subtitle: "Skills",
                icon: "hammer", target: .skill(skill.name)))
        }
        for guide in (wiki.notes + wiki.quests).filter({ matches(query, "\($0.name) \($0.desc) " + $0.steps.map { "\($0.title) \($0.note)" }.joined(separator: " ")) }).prefix(4) {
            result.append(GuideSearchHit(id: "server:\(WikiState.tag(guide))", title: guide.name,
                subtitle: "\(world) · \(guide.group)", icon: "book", target: .server(WikiState.tag(guide))))
        }
        return result
    }
}

extension CompanionView {
    var searchHits: [GuideSearchHit] {
        GuideSearch.hits(query: globalSearch, guides: state.guides, world: state.world, wiki: wiki, zones: state.zones)
    }

    var globalSearchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Search guides, steps, monsters…", text: $globalSearch)
                .textFieldStyle(.plain)
                .frame(height: 18)
                .onSubmit { if let first = searchHits.first { openSearch(first.target) } }
                .onChange(of: globalSearch) { showSearch = !GuideSearch.key($0).isEmpty }
                .onExitCommand { showSearch = false }
            if !globalSearch.isEmpty {
                Button { globalSearch = ""; showSearch = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(7).background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
        .frame(minWidth: 150, idealWidth: 260, maxWidth: 360)
        .overlay(alignment: .topTrailing) {
            if showSearch {
                let hits = searchHits
                VStack(alignment: .leading, spacing: 0) {
                    if hits.isEmpty {
                        Text("No matches for “\(globalSearch)”.").font(.callout).padding(12)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(hits) { hit in
                                    Button { openSearch(hit.target) } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: hit.icon).frame(width: 18).foregroundStyle(Theme.gold)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(hit.title).font(.callout).foregroundStyle(Theme.text)
                                                Text(hit.subtitle).font(.caption2).foregroundStyle(Theme.muted)
                                            }
                                            .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Divider().overlay(Theme.stroke)
                                }
                            }.padding(4)
                        }.frame(height: min(CGFloat(hits.count) * 66, 330))
                    }
                }
                .frame(width: 370, alignment: .leading)
                .background(Theme.night, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
                .shadow(radius: 10).offset(y: 34)
            }
        }
    }

    func openSearch(_ target: GuideSearchTarget) {
        showSearch = false
        searchPage = nil
        switch target {
        case .guide(let guide, let step):
            guard state.guides.indices.contains(guide), state.guides[guide].available(on: state.world),
                  step.map({ state.guides[guide].steps.indices.contains($0) }) ?? true else { return }
            tab = 0; state.openGuide(guide, at: step)
            expandedContent.insert(QuestCatalogue.section(of: state.guides[guide]))
        case .family, .monster: searchPage = target
        case .gear(let id): wiki.openItem = id; tab = 1
        case .skill(let name): wiki.skill = name; tab = 2
        case .server(let name): wiki.serverPick = name; tab = 4
        }
    }

    @ViewBuilder
    func searchDetail(_ target: GuideSearchTarget) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Button { searchPage = nil } label: { Label("Back to guides", systemImage: "chevron.left") }
                    .controlSize(.small)
                switch target {
                case .family(let family):
                    Text(family == "Rabbit" ? "Rabbits" : family).font(.title2.bold()).foregroundStyle(Theme.gold)
                    Text("Monster database · \(state.world)").font(.caption).foregroundStyle(Theme.muted)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(wiki.monsters.filter { $0.family == family }.sorted { $0.lo == $1.lo ? $0.name < $1.name : $0.lo < $1.lo }) { mob in
                                Button { searchPage = .monster(mob.id) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(mob.name + (mob.nm ? " · NM" : "")).foregroundStyle(Theme.crystal)
                                            Text("\(state.zones.name(mob.zone)) · Level \(mob.lo)–\(mob.hi) · \(mob.scope)")
                                                .font(.caption).foregroundStyle(Theme.muted)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                case .monster(let id):
                    if let mob = wiki.monsters.first(where: { $0.id == id }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(mob.name).font(.title2.bold()).foregroundStyle(Theme.gold)
                                Button("\(mob.family) · Monster database") { searchPage = .family(mob.family) }.buttonStyle(.link)
                                Text("\(mob.nm ? "Notorious monster" : "Monster") · Level \(mob.lo)–\(mob.hi)")
                                Label(state.zones.name(mob.zone), systemImage: "mappin.and.ellipse")
                                if !mob.note.isEmpty { Text(mob.note).fixedSize(horizontal: false, vertical: true) }
                                if !mob.drops.isEmpty { Text("Drops: \(mob.drops)").fixedSize(horizontal: false, vertical: true) }
                                Text(mob.scope == "Standard reference" ? "Standard reference; this server may change availability, levels and drops." : "\(mob.scope) reference")
                                    .font(.caption).foregroundStyle(Theme.muted)
                                if let url = URL(string: mob.source), ["http", "https"].contains(url.scheme ?? "") {
                                    Link("Source", destination: url).font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else { Text("This entry is unavailable for the selected server.") }
                default: EmptyView()
                }
            }
        }
    }
}
