// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// Developer Mode: quest givers and their zones recorded while playing. Screen Reading supplies
// the zone ("=== Area: … ===") and every speaker line ("Gulemont : …"); the developer assigns
// a heard speaker to the quest on screen. Saved locally; Export writes guide data to Downloads
// for merging into the addon's data/quests.lua and data/missions.lua.

import Foundation

struct LearnedGiver: Codable, Equatable {
    var npc: String
    var zone: Int
    var recorded: Date
}

struct LearnedData: Codable, Equatable {
    /// Speaker -> zone id (as text) -> times heard.
    var speakers: [String: [String: Int]] = [:]
    /// Catalogue key ("Q:sandoria,6") -> who gives it and where.
    var givers: [String: LearnedGiver] = [:]

    static var url: URL {
        ProgressStore.directory.deletingLastPathComponent().appendingPathComponent("learned.json")
    }

    static func load(from url: URL = url) -> LearnedData {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? d.decode(LearnedData.self, from: $0) } ?? LearnedData()
    }

    @discardableResult
    func save(to url: URL = url) -> Bool {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(self) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    /// Speaker names at the start of chat lines. FFXI prints NPC and /say lines as
    /// "Name : text"; system lines, bracketed channels and numbers are not speakers.
    static func speakers(in text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard let r = line.range(of: " : ") ?? line.range(of: ": ") else { continue }
            let name = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            guard (2...24).contains(name.count), let first = name.first, first.isUppercase,
                  name.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "-" }),
                  !["Area", "Quest", "Mission", "Gil", "Obtained"].contains(name) else { continue }
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// Records each speaker once per reading; returns the names heard.
    mutating func hear(_ text: String, zone: Int) -> [String] {
        let names = Self.speakers(in: text)
        for n in names { speakers[n, default: [:]][String(zone), default: 0] += 1 }
        return names
    }

    /// Guide data lines, grouped by log and area, ready to merge into the addon's data files.
    func export(entries: [CatalogueEntry], zoneName: (Int) -> String, date: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        var lines = ["-- VanaGuide Server-Safe: quest givers recorded in Developer Mode, \(stamp).",
                     "-- Merge each line into data/quests.lua or data/missions.lua under its area.", ""]
        let byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for key in givers.keys.sorted() {
            guard let g = givers[key], let e = byKey[key] else { continue }
            let name = e.name.replacingOccurrences(of: "'", with: "\\'")
            let npc = g.npc.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "'", with: "\\'")
            lines.append("-- \(e.mission ? "missions" : "quests").\(e.area) — \(zoneName(g.zone))")
            lines.append("[\(e.id)] = { name = '\(name)', zone = \(g.zone), npc = '\(npc)' },")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
