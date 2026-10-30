// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation
import SwiftUI

struct NMDetails: Identifiable {
    var name: String
    var zone: Int
    var ids: String
    var spawn: String
    var area: String
    var ph: String
    var scope: String
    var source: String
    var notes: String
    var id: String { "\(name)\u{1}\(zone)" }
    static func read(_ url: URL) -> [NMDetails]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return LuaDataReader.tables(in: text).flatMap(\.array).compactMap { value in
            guard let t = value.table, let name = t["name"]?.string, let zone = t["zone"]?.int else { return nil }
            func str(_ key: String) -> String { t[key]?.string ?? "" }
            return NMDetails(name: name, zone: zone, ids: str("ids"), spawn: str("spawn"), area: str("area"), ph: str("ph"), scope: str("scope"), source: str("source"), notes: str("notes"))
        }
    }
    static func load(roots: [URL], world: String) -> [NMDetails] {
        let stock = roots.lazy.compactMap { read($0.appendingPathComponent("data/nm_details.lua")) }.first ?? []
        let key = WikiState.serverKey(for: world)
        let own = roots.lazy.compactMap { read($0.appendingPathComponent("data/servers/\(key)/nm_details.lua")) }.first ?? []
        let ids = Set(own.map(\.id))
        return own + stock.filter { !ids.contains($0.id) }
    }
}

extension CompanionView {
    @ViewBuilder func nmDetail(_ nm: NMDetails) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(nm.name).font(.headline).foregroundStyle(Theme.gold)
            Text(state.zones.name(nm.zone)).foregroundStyle(Theme.crystal)
            if let mob = wiki.monsters.first(where: { $0.name == nm.name && $0.zone == nm.zone }) {
                Text("\(mob.family) · Level \(mob.lo)–\(mob.hi)")
                if !mob.drops.isEmpty { Text("Drops: \(mob.drops)") }
            }
            Text("Spawn: " + (nm.spawn.isEmpty ? "Not documented in this reference" : nm.spawn))
            Text("NM ID(s): \(nm.ids)")
            Text("Placeholders: " + (nm.ph.isEmpty ? "Not documented in this reference" : nm.ph))
            Text((nm.scope == "Standard LSB reference" ? "Reference spawn coordinates: " : "Camp area: ") + nm.area)
            if !nm.notes.isEmpty { Text(nm.notes) }
            Text(nm.scope).font(.caption).foregroundStyle(Theme.muted)
            if let url = URL(string: nm.source), url.scheme == "https" { Link("Spawn source", destination: url).font(.caption) }
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.stroke.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
