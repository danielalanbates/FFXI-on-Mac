// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// Finds the logged-in character's name without any server data: the game window's title when
// it is the character's name, otherwise the status box (bottom right), where the game prints
// "<Name> <HP>". A name must be read twice before it is trusted. The world comes from the
// FFXI on Mac launcher's session.json.

import Foundation

enum CharacterDiscovery {
    /// Bottom-right status/party box, as window percentages.
    static let statusCrop = ChatCrop(left: 65, top: 78, width: 35, height: 22)
    static let notNames: Set<String> = ["Solo", "Party", "Alliance", "Wine", "Ffxi", "Final", "Fantasy",
                                        "Horizonxi", "Labyrinth", "Target", "Menu", "Status", "Gil", "Level", "Lv"]

    /// FFXI names are one word: 3–15 letters, capitalized, nothing else.
    static func isName(_ s: String) -> Bool {
        guard (3...15).contains(s.count), let f = s.first, f.isUppercase,
              s.allSatisfy({ $0.isASCII && $0.isLetter }), s.dropFirst().contains(where: \.isLowercase)
        else { return false }
        return !notNames.contains(s.capitalized)
    }

    /// A private server titles the game window with the character's name.
    static func name(fromTitle title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        return isName(t) ? t : nil
    }

    /// Lines such as "Labguide 507" or "Labguide 507 g" in the status box.
    static func candidates(fromStatus text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ").map(String.init)
            // Name, HP, then only numbers or short OCR fragments ("507 g"), never more words.
            guard parts.count >= 2, isName(parts[0]), parts[1].allSatisfy(\.isNumber),
                  parts.dropFirst(2).allSatisfy({ $0.count <= 2 || $0.allSatisfy(\.isNumber) }) else { continue }
            if !out.contains(parts[0]) { out.append(parts[0]) }
        }
        return out
    }

    struct Vote {
        private var seen: [String: Int] = [:]
        /// The name once it has been read in two samples.
        mutating func observe(_ names: [String]) -> String? {
            for n in names { seen[n, default: 0] += 1 }
            return names.first { (seen[$0] ?? 0) >= 2 }
        }
    }

    /// The world the launcher last played or opened Server-Safe for.
    static func launcherWorld(at url: URL = ProgressStore.directory.deletingLastPathComponent()
                                  .appendingPathComponent("session.json")) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let w = obj["world"], !w.isEmpty else { return nil }
        return w
    }
}
