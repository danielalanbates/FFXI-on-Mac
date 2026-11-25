// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// Skills tab recommendations: the player sets their level and gets the recipe to craft (one for
// skill-ups, one for skill-ups that also make gil) or the monster to fight. Data from the addon
// repository's tools/gen_skill_data.py: data/craft_recipes.lua and data/skill_targets.lua.

import Foundation

struct CraftRecipe: Equatable {
    var level: Int
    var name: String
    var crystal: String
    var parts: [String]
    /// Cheapest NPC prices for every ingredient; nil when one is sold by no NPC.
    var cost: Int?
    /// What the result sells to an NPC for.
    var sell: Int
    var needsKeyItem: Bool
    /// Other crafts the recipe also needs ("Smithing 8").
    var other: [String]
    var profit: Int? { cost.map { sell - $0 } }
}

struct SkillTarget: Equatable {
    var name: String
    var zone: Int
    var min: Int
    var max: Int
    var spawns: Int
    var aggro: Bool
    var links: Bool
}

enum SkillPicks {
    /// Skill-ups come from recipes above your skill; the closer to +3 the better the trade-off
    /// between skill-up chance and failed synths. Only recipes you can make with this craft alone
    /// and without a key item, widening the window when a band has none.
    static func window(_ recipes: [CraftRecipe], level: Int) -> [CraftRecipe] {
        for (span, strict) in [(5, true), (10, true), (10, false)] {
            let w = recipes.filter { r in
                r.level > level && r.level <= level + span && !r.needsKeyItem
                    && (!strict || (r.other.isEmpty && r.cost != nil))
            }
            if !w.isEmpty { return w }
        }
        return []
    }

    static func forSkill(_ recipes: [CraftRecipe], level: Int) -> CraftRecipe? {
        window(recipes, level: level).min { a, b in
            let da = abs(a.level - (level + 3)), db = abs(b.level - (level + 3))
            return da != db ? da < db : (a.cost ?? .max) < (b.cost ?? .max)
        }
    }

    /// Same window, most gil back from an NPC after buying the ingredients.
    static func forGil(_ recipes: [CraftRecipe], level: Int) -> CraftRecipe? {
        window(recipes, level: level).filter { $0.cost != nil }.max { a, b in
            (a.profit ?? .min, -abs(a.level - (level + 3))) < (b.profit ?? .min, -abs(b.level - (level + 3)))
        }
    }

    /// A monster that gives skill-ups (it must not be too weak: at or above your level) and is
    /// safe to fight alone: not aggressive, preferably not linking, with plenty of spawns.
    static func monster(_ mobs: [SkillTarget], level: Int) -> SkillTarget? {
        let fits = mobs.filter { $0.max >= level && $0.min <= level + 3 && !$0.aggro }
        return fits.min { a, b in
            func score(_ m: SkillTarget) -> (Int, Double, Int) {
                (m.links ? 1 : 0, abs(Double(m.min + m.max) / 2 - Double(level) - 1), -m.spawns)
            }
            return score(a) < score(b)
        }
    }
}

extension WikiData {
    static func crafts(_ url: URL) -> [String: [CraftRecipe]]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let list = LuaDataReader.tables(in: text).first(where: { !$0.array.isEmpty }) else { return nil }
        var out: [String: [CraftRecipe]] = [:]
        for c in list.array.compactMap(\.table) {
            guard let name = c["name"]?.string else { continue }
            out[name] = (c["recipes"]?.table?.array ?? []).compactMap { v in
                guard let t = v.table, let lv = t["lv"]?.int, let n = t["name"]?.string else { return nil }
                return CraftRecipe(level: lv, name: n, crystal: t["crystal"]?.string ?? "",
                                   parts: (t["parts"]?.table?.array ?? []).compactMap(\.string),
                                   cost: t["cost"]?.int, sell: t["sell"]?.int ?? 0,
                                   needsKeyItem: t["ki"] == .bool(true),
                                   other: (t["other"]?.table?.array ?? []).compactMap(\.string))
            }
        }
        return out.isEmpty ? nil : out
    }

    static func targets(_ url: URL) -> [SkillTarget]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let list = LuaDataReader.tables(in: text).first(where: { !$0.array.isEmpty }) else { return nil }
        let mobs = list.array.compactMap { v -> SkillTarget? in
            guard let t = v.table, let n = t["name"]?.string, let z = t["zone"]?.int,
                  let lo = t["min"]?.int, let hi = t["max"]?.int else { return nil }
            return SkillTarget(name: n, zone: z, min: lo, max: hi, spawns: t["spawns"]?.int ?? 1,
                               aggro: t["aggro"] == .bool(true), links: t["links"] == .bool(true))
        }
        return mobs.isEmpty ? nil : mobs
    }
}
