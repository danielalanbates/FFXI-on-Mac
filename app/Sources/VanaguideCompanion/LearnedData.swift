// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// Developer Mode: quest givers and their zones recorded while playing. The local reader supplies
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
                  // NPC names capitalize every word ("Hanaa Punaa"); "Vanaguidel release" is
                  // a misread addon line, not a speaker.
                  name.split(separator: " ").allSatisfy({ $0.first?.isUppercase == true }),
                  !["Area", "Quest", "Mission", "Gil", "Obtained"].contains(name) else { continue }
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// Records each speaker once per reading; returns the names heard.
    mutating func hear(_ text: String, zone: Int, excluding me: String = "") -> [String] {
        let names = Self.speakers(in: text).filter { $0.caseInsensitiveCompare(me) != .orderedSame }
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

/// What appeared in the chat since the zone was entered (or reading started). The game log
/// scrolls and, during conversations, jumps back to show older lines, so diffing two readings
/// misfires (2026-10-28: old lines looked new, a repeated NPC line looked old). Instead every
/// line seen since the baseline is remembered; a line is new the first time it shows up. The
/// top row is skipped: the crop can cut it in half, and a half line changes as it scrolls.
enum ChatDiff {
    static func key(_ line: String) -> String { String(ScreenshotGuideMatcher.normalized(line).prefix(24)) }

    /// Keys for a reading: text plus which copy on screen it is, so a second identical line
    /// (an NPC repeating themselves) is a different line from the first.
    static func keys(_ lines: [String]) -> [String] {
        var count: [String: Int] = [:]
        return lines.map { l in
            let k = key(l)
            count[k, default: 0] += 1
            return "\(k)#\(count[k]!)"
        }
    }

    static func newLines(seen: inout Set<String>, current: [String]) -> [String] {
        newLines(seen: &seen, previous: nil, current: current)
    }

    /// New = not seen since the zone began, OR unmatched when this reading is aligned with the
    /// previous one (longest common subsequence). The first misses an NPC repeating a line once
    /// the full log scrolls; the second misfires when the log jumps back. Missing the NPC you
    /// just spoke to is worse than an extra name, so either counts. The top row never does.
    static func newLines(seen: inout Set<String>, previous: [String]?, current: [String]) -> [String] {
        let keys = keys(current)
        let appended = previous.map { Set(unmatched(previous: $0, current: current)) } ?? []
        var out: [String] = []
        for (i, (line, k)) in zip(current, keys).enumerated() {
            guard !k.hasPrefix("#") else { continue }
            let unseen = seen.insert(k).inserted
            if i > 0 && (unseen || appended.contains(i)) { out.append(line) }
        }
        return out
    }

    /// Indices of `current` left unmatched by an earliest-first LCS alignment with `previous`.
    static func unmatched(previous: [String], current: [String]) -> [Int] {
        let p = previous.map(key), c = current.map(key)
        let n = p.count, m = c.count
        guard n > 0 else { return Array(current.indices) }
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = p[i] == c[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var matched = Set<Int>()
        var i = 0, j = 0
        while i < n && j < m {
            if p[i] == c[j] && lcs[i][j] == lcs[i + 1][j + 1] + 1 { matched.insert(j); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return current.indices.filter { !matched.contains($0) }
    }
}
