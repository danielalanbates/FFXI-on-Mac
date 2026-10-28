// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// Zone names and the walk/transit graph, read from the addon's literal data files
// (zone_names.lua, zonelines.lua, travel.lua), so a step can say "Port San d'Oria" instead of
// 232 and give plain directions from where the player is. The player's zone comes only from
// the "=== Area: … ===" line the game prints in chat on every zone change.

import Foundation

struct Hop: Equatable {
    let to: Int
    /// nil = walk through the zone line; otherwise what to tell the player ("Airship to Jeuno …").
    let via: String?
    let needsPass: Bool
}

struct WorldMap {
    var names: [Int: String] = [:]
    var edges: [Int: [(hop: Hop, cost: Int)]] = [:]
    static let walkCost = 90

    static func load(root: URL) -> WorldMap {
        func text(_ f: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent("data/\(f)"), encoding: .utf8)) ?? ""
        }
        return parse(names: text("zone_names.lua"), zonelines: text("zonelines.lua"), travel: text("travel.lua"))
    }

    static func parse(names: String, zonelines: String, travel: String) -> WorldMap {
        var map = WorldMap()
        // zone_names.lua: the table whose numeric keys map to strings.
        for t in LuaDataReader.tables(in: names) {
            for k in t.keys { if let id = Int(k), let n = t[k]?.string, id > 0 { map.names[id] = n } }
        }
        func addWalk(_ a: Int, _ b: Int, oneWay: Bool = false) {
            map.add(a, Hop(to: b, via: nil, needsPass: false), walkCost)
            if !oneWay { map.add(b, Hop(to: a, via: nil, needsPass: false), walkCost) }
        }
        for t in LuaDataReader.tables(in: zonelines) + LuaDataReader.tables(in: travel) {
            for v in t.array {
                guard let pair = v.table else { continue }
                if pair.array.count >= 2, let a = pair.array[0].int, let b = pair.array[1].int {
                    addWalk(a, b, oneWay: pair.array.count > 2)
                } else if let from = pair["from"]?.int, let to = pair["to"]?.int {
                    map.add(from, Hop(to: to, via: pair["via"]?.string, needsPass: pair["pass"]?.string == "true"),
                            pair["cost"]?.int ?? 600)
                }
            }
        }
        return map
    }

    private mutating func add(_ from: Int, _ hop: Hop, _ cost: Int) {
        if edges[from, default: []].contains(where: { $0.hop.to == hop.to && $0.hop.via == hop.via }) { return }
        edges[from, default: []].append((hop, cost))
    }

    /// The zone's display name; never a bare number.
    func name(_ id: Int?) -> String {
        guard let id else { return "an unrecorded place" }
        return names[id] ?? "an unnamed zone"
    }

    /// The zone named in a chat line such as "=== Area: Port San d'Oria ===".
    func zone(inChat text: String) -> Int? {
        let byName = Dictionary(names.map { (ScreenshotGuideMatcher.normalized($0.value), $0.key) },
                                uniquingKeysWith: { a, _ in a })
        for line in text.components(separatedBy: .newlines).reversed() {
            guard let r = line.range(of: "Area:") else { continue }
            let n = ScreenshotGuideMatcher.normalized(String(line[r.upperBound...]))
            if let id = byName[n] { return id }
        }
        return nil
    }

    /// Cheapest route (walking = 90, transit = its wait). Empty when already there or unknown.
    func route(from: Int, to: Int) -> [Hop]? {
        if from == to { return [] }
        var best: [Int: Int] = [from: 0]
        var prev: [Int: (Int, Hop)] = [:]
        var open: Set<Int> = [from]
        while let here = open.min(by: { best[$0]! < best[$1]! }) {
            open.remove(here)
            if here == to { break }
            for (hop, cost) in edges[here] ?? [] {
                let c = best[here]! + cost
                if c < best[hop.to] ?? .max { best[hop.to] = c; prev[hop.to] = (here, hop); open.insert(hop.to) }
            }
        }
        guard prev[to] != nil else { return nil }
        var hops: [Hop] = []
        var at = to
        while at != from, let (p, hop) = prev[at] { hops.insert(hop, at: 0); at = p }
        return hops
    }

    /// Plain directions, one line per hop.
    func directions(_ hops: [Hop]) -> [String] {
        hops.map { hop in
            if let via = hop.via { return via + (hop.needsPass ? " (needs an Airship Pass)" : "") }
            return "Walk to \(name(hop.to))"
        }
    }
}

extension String {
    /// "Fyi_Chalmwoh" -> "Fyi Chalmwoh"; the game's glowing "???" spots (qm1, "qm6 (H-10/Boat)",
    /// "blank divine might") -> "the ??? marker", keeping any map hint.
    var npcDisplay: String {
        let name = replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()
        if lower.hasPrefix("qm") || lower.hasPrefix("blank") || lower.hasPrefix("iy") || lower.hasPrefix("iz") {
            if let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
                return "the ??? marker (\(name[name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)))"
            }
            return "the ??? marker"
        }
        return name
    }

    /// "???" spots are examined, people are talked to.
    var isMarker: Bool { npcDisplay.hasPrefix("the ??? marker") }
}
