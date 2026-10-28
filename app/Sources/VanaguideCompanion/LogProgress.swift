// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// The Server-Safe guide's own progress record. It cannot ask the server what a character has
// done, so it keeps what the player showed it: titles read from the in-game Quests/Missions
// logs during "Getting started", and steps the player pressed Done on. One JSON file per
// character under Application Support. No images or chat text are stored.

import Foundation

enum LogStatus: String, Codable { case current, completed }

struct LogRecord: Codable, Equatable {
    var status: LogStatus
    var seen: Date
    /// "quest log" (read from a log page) or "done" (the player pressed Done).
    var source: String
}

struct CharacterProgress: Codable, Equatable {
    var character: String
    var world: String
    /// Catalogue keys ("Q:sandoria,6", "M:sandoria,1") to what was last seen.
    var entries: [String: LogRecord] = [:]
    var updated = Date()

    var completedCount: Int { entries.values.filter { $0.status == .completed }.count }
    var currentCount: Int { entries.values.filter { $0.status == .current }.count }

    /// A completed record is never downgraded to current by a later misread; the player's own
    /// Done is never overwritten by a log read.
    mutating func record(_ key: String, _ status: LogStatus, source: String, at date: Date = Date()) -> Bool {
        if let old = entries[key] {
            if old.status == .completed && status == .current { return false }
            if old.status == status && (old.source == "done" || source != "done") {
                entries[key]?.seen = date
                return false
            }
        }
        entries[key] = LogRecord(status: status, seen: date, source: source)
        updated = date
        return true
    }
}

enum ProgressStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VanaGuide Server-Safe/characters", isDirectory: true)
    }

    static func fileName(character: String, world: String) -> String {
        func clean(_ s: String) -> String {
            let kept = s.trimmingCharacters(in: .whitespaces).unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
            return String(kept).isEmpty ? "unnamed" : String(kept)
        }
        return "\(clean(world))-\(clean(character)).json"
    }

    static func load(character: String, world: String, in dir: URL = directory) -> CharacterProgress {
        let url = dir.appendingPathComponent(fileName(character: character, world: world))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let p = try? decoder.decode(CharacterProgress.self, from: data) {
            return p
        }
        return CharacterProgress(character: character, world: world)
    }

    @discardableResult
    static func save(_ p: CharacterProgress, in dir: URL = directory) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(p) else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(fileName(character: p.character, world: p.world)),
                           options: .atomic)
            return true
        } catch { return false }
    }

    /// Saved characters, newest first, for the profile picker.
    static func saved(in dir: URL = directory) -> [CharacterProgress] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(CharacterProgress.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }
}

/// Reads a whole Quests/Missions log page. Unlike chat matching, a log page legitimately shows
/// many titles at once, so every exactly matching line is recorded.
enum LogSurvey {
    static let guideName = "Getting Started"

    static let areaTitles: [String: String] = [
        "san d oria": "sandoria", "bastok": "bastok", "windurst": "windurst", "jeuno": "jeuno",
        "other areas": "other", "outlands": "outlands", "aht urhgan": "ahturhgan",
        "crystal war": "wotg", "abyssea": "abyssea", "adoulin": "adoulin", "coalition": "coalition",
        // Mission log headings.
        "rise of the zilart": "zilart", "chains of promathia": "cop", "treasures of aht urhgan": "toau",
        "wings of the goddess": "wotg", "seekers of adoulin": "adoulin", "rhapsodies of vana diel": "rov",
        "the voracious resurgence": "tvr", "a crystalline prophecy": "acp", "a moogle kupo d etat": "amk",
        "a shantotto ascension": "asa",
    ]

    /// Steps for a brand-new or returning character. Keys and menu names follow the default
    /// PC layout; a remapped keyboard or gamepad uses its own menu button.
    static var guide: Guide {
        func step(_ title: String, _ note: String, list: String) -> GuideStep {
            GuideStep(kind: "C", title: title, note: note, fixed: true, tags: ["LOG": list])
        }
        return Guide(name: guideName,
                     desc: "Show the guide your in-game logs once, so it knows what you have done. Nothing is read from the server.",
                     levels: "", steps: [
            step("Choose Your Character and Start Reading",
                 "Enter your character and world above and press Load. Then open Screen Reading…, press Find Game Window, choose the game and press Start Reading. On these steps the whole game window is read, so the chat area does not matter.",
                 list: "none"),
            step("Open the Main Menu",
                 "Log in and stand somewhere safe. Press the minus key (−) to open the Main Menu (on a gamepad, the menu button). Keep the game window visible next to this one.",
                 list: "none"),
            step("Quests › Home Nation › Current Quests",
                 "In the Main Menu choose Quests, then your home nation (San d'Oria, Bastok or Windurst), then Current Quests. Hold each page still for about 20 seconds; the titles appear below as they are recorded. Page down for more. A new character's list is empty, which is fine.",
                 list: "current"),
            step("Quests › Home Nation › Completed Quests",
                 "Go back one level and choose Completed Quests. Hold each page for about 20 seconds.",
                 list: "completed"),
            step("Other Quest Areas (Optional)",
                 "Repeat Current and Completed for Jeuno, Other Areas, Outlands and any expansion areas you have played. New characters can skip this step.",
                 list: "auto"),
            step("Missions",
                 "Back in the Main Menu choose Missions, then your nation and any expansions. Hold the current mission and the completed list on screen for about 20 seconds each.",
                 list: "auto"),
            step("All Set",
                 "Your progress is saved for this character. Pick a guide on the left: completed quests are marked, and Next Unfinished skips them. Run this again any time to refresh it.",
                 list: "none"),
        ])
    }

    struct Reading: Equatable {
        var area: String?
        var status: LogStatus?
        var keys: [String]
    }

    /// `fallback` comes from the step ("current"/"completed"); a visible page heading wins.
    static func read(text: String, entries: [CatalogueEntry], fallback: LogStatus?) -> Reading {
        let lines = text.components(separatedBy: .newlines)
            .map { ScreenshotGuideMatcher.normalized($0) }.filter { !$0.isEmpty }
        var status = fallback
        if lines.contains(where: { $0.contains("completed") }) { status = .completed }
        else if lines.contains(where: { $0.contains("current") }) { status = .current }
        let area = lines.lazy.compactMap { areaTitles[$0] }.first
        var byName: [String: [CatalogueEntry]] = [:]
        for e in entries { byName[ScreenshotGuideMatcher.normalized(e.name), default: []].append(e) }
        var keys: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let truncated = trimmed.hasSuffix("...") || trimmed.hasSuffix("…")
            let line = ScreenshotGuideMatcher.normalized(trimmed)
            guard line.count >= 3 else { continue }
            var found = byName[line] ?? []
            // Long titles can be cut short with an ellipsis; accept a unique, long-enough stem.
            if found.isEmpty, truncated, line.count >= 8 {
                found = byName.filter { $0.key.hasPrefix(line) }
                    .flatMap(\.value)
            }
            if found.count > 1, let area { found = found.filter { $0.area == area } }
            if found.count == 1 { keys.append(found[0].key) }
        }
        return Reading(area: area, status: status, keys: Array(Set(keys)).sorted())
    }
}
