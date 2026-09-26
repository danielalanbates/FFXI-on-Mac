// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// Swift port of Vanaguide's pipe-delimited step format (see ../vanaguide/docs/GUIDE_FORMAT.md).
// The companion reads the exact same guides/*.lua files the addon ships, so both stay in sync.
// It parses only the `G.register({ ... steps = [[ ... ]] ... })` payload — no Lua runtime needed.

import Foundation

struct GuideStep {
    /// One-letter step type: A accept, T turn-in, C condition, t talk, F travel, K kill,
    /// R reach, U trade, L level.
    var kind: String
    var title: String
    var zone: Int?
    var posX: Double?
    var posZ: Double?
    var note: String?
    /// FIXED steps never auto-complete; the player confirms them (the panel's Done button).
    var fixed = false
    /// Raw tags kept for display/debugging (KI, IT, MA, M, Q, QA, LV values).
    var tags: [String: String] = [:]
}

struct Guide {
    var name: String
    var desc: String
    var levels: String
    var steps: [GuideStep]
}

enum GuideParser {
    /// Parse every guide registered in a guides directory (the addon's `Vanaguide/guides/`).
    static func loadAll(from directory: URL) -> [Guide] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "lua" && $0.lastPathComponent != "init.lua" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { (try? String(contentsOf: $0, encoding: .utf8)).flatMap(parse) }
            .flatMap { $0 }
    }

    /// Parse all G.register blocks in one file's text.
    static func parse(_ text: String) -> [Guide] {
        var guides: [Guide] = []
        var search = text.startIndex
        while let stepsRange = text.range(of: "steps = [[", range: search..<text.endIndex) {
            guard let end = text.range(of: "]]", range: stepsRange.upperBound..<text.endIndex) else { break }
            let head = String(text[search..<stepsRange.lowerBound])
            let body = String(text[stepsRange.upperBound..<end.lowerBound])
            guides.append(Guide(
                name: luaString("name", in: head) ?? "Unnamed guide",
                desc: luaString("desc", in: head) ?? "",
                levels: luaString("levels", in: head) ?? "",
                steps: body.split(separator: "\n").compactMap { parseStep(String($0)) }
            ))
            search = end.upperBound
        }
        return guides
    }

    private static func luaString(_ key: String, in text: String) -> String? {
        // name = "value" or name = 'value' — take the LAST occurrence before the steps block,
        // so a file with several registers attributes fields to the nearest block.
        for quote in ["\"", "'"] {
            let pattern = "\(key) = \(quote)"
            if let r = text.range(of: pattern, options: .backwards),
               let close = text.range(of: quote, range: r.upperBound..<text.endIndex) {
                return String(text[r.upperBound..<close.lowerBound])
            }
        }
        return nil
    }

    /// One line: `t Report to Laurisse.|Z|102|POS|-291.76,141.19|FIXED||N|Complete the dialogue.|`
    static func parseStep(_ line: String) -> GuideStep? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 2, let space = trimmed.firstIndex(of: " ") else { return nil }
        let kind = String(trimmed[..<space])
        guard kind.count == 1, "ATCFKRULt".contains(kind) else { return nil }
        var fields = trimmed[trimmed.index(after: space)...].components(separatedBy: "|")
        var step = GuideStep(kind: kind, title: fields.removeFirst())
        var i = 0
        while i < fields.count {
            let tag = fields[i]
            switch tag {
            case "FIXED":
                step.fixed = true
                i += 2 // FIXED is serialized as an empty tag pair: FIXED||
            case "Z":
                step.zone = i + 1 < fields.count ? Int(fields[i + 1]) : nil
                i += 2
            case "POS":
                if i + 1 < fields.count {
                    let parts = fields[i + 1].components(separatedBy: ",")
                    if parts.count >= 2 {
                        step.posX = Double(parts[0])
                        step.posZ = Double(parts[1])
                    }
                }
                i += 2
            case "N":
                step.note = i + 1 < fields.count ? fields[i + 1] : nil
                i += 2
            case "":
                i += 1
            default:
                step.tags[tag] = i + 1 < fields.count ? fields[i + 1] : ""
                i += 2
            }
        }
        return step
    }
}
