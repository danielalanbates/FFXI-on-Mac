// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import Foundation

enum StarterFood {
    static func isFoodStep(guide: String, title: String) -> Bool {
        guide.caseInsensitiveCompare("Starting out") == .orderedSame
            && title == "Buy a few affordable food portions before fighting."
    }

    static func advice(job: String?, nation: String?) -> String {
        let shops = ["San d'Oria": "Boncort — Northern San d'Oria (F-8), Phoenix Perch Inn upstairs",
                     "Bastok": "Griselda — Bastok Mines (H-5), Bat's Lair Inn",
                     "Windurst": "Ness Rugetomal — Windurst Waters North (F-10), Rarab Tail Hostelry"]
        guard let job, !job.isEmpty, let nation, let shop = shops[nation] else {
            return "Choose this character's job and home nation for food and shop advice."
        }
        let drinks = ["San d'Oria": "Apple Juice: nation must be 1st or 2nd in Conquest.",
                      "Bastok": "Pineapple Juice: nation must be 1st; citizens only.",
                      "Windurst": "Orange Juice: nation must be 1st or 2nd in Conquest."]
        let recommendation = ["WHM", "BLM"].contains(job)
            ? "Budget for MP drinks or rest to recover MP. " + (drinks[nation] ?? "")
            : "Buy 2–3 Meat Jerky if affordable for early melee; it does not improve spell damage."
        return recommendation + " Shop: " + shop + ". Keep gil for spells and equipment; compare prices and check server-specific stock."
    }
}
