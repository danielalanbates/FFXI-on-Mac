// Copyright (c) 2026 Bates LLC. All rights reserved.

import SwiftUI

/// The RetroAchievements block in Setup & Diagnostics: username, web API key (Keychain),
/// refresh button and what the last fetch said. See RetroAchievements.swift.
struct RetroAchievementsSection: View {
    @ObservedObject var ra: RAProgress
    let gameDir: URL?
    let log: (String) -> Void

    @State private var user = RetroAchievements.username
    @State private var keyEntry = ""
    @State private var keySaved = RetroAchievements.keySaved
    @State private var extraIDs = RetroAchievements.extraSetIDs.map(String.init).joined(separator: ", ")
    @State private var keyNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RETROACHIEVEMENTS").font(.caption2).tracking(2)
            TextField("RetroAchievements username", text: $user)
                .textFieldStyle(.roundedBorder).font(.caption2)
                .onSubmit { RetroAchievements.username = user }
                .onChange(of: user) { RetroAchievements.username = $0 }
            HStack(spacing: 6) {
                SecureField(keySaved ? "web API key saved in Keychain" : "web API key", text: $keyEntry)
                    .textFieldStyle(.roundedBorder).font(.caption2)
                Button("Save") {
                    let k = keyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !k.isEmpty else { return }
                    do {
                        try RetroAchievements.saveKey(k)
                        keySaved = true
                        keyNote = "key saved to the Keychain"
                    } catch {
                        keyNote = "could not save the key: \(error)"
                    }
                    keyEntry = ""
                }
                .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                if keySaved {
                    Button("Remove") {
                        RetroAchievements.removeKey()
                        keySaved = false
                        keyNote = "key removed"
                    }
                }
            }
            .help("Your personal web API key from retroachievements.org › Settings. It is kept in "
                  + "the macOS Keychain and only ever sent to retroachievements.org; the game never "
                  + "sees it.")
            TextField("extra set ids (optional)", text: $extraIDs)
                .textFieldStyle(.roundedBorder).font(.caption2)
                .onSubmit { RetroAchievements.extraSetIDs = RetroAchievements.parseSetIDs(extraIDs) }
                .help("Built in: \(RetroAchievements.builtinSets.map { "\($0.id) \($0.title)" }.joined(separator: ", ")).")
            HStack(spacing: 8) {
                Button(ra.busy ? "Refreshing…" : "Refresh achievements") {
                    RetroAchievements.username = user
                    RetroAchievements.extraSetIDs = RetroAchievements.parseSetIDs(extraIDs)
                    ra.refresh(.manual, gameDir: gameDir, log: log)
                }
                .disabled(ra.busy || gameDir == nil)
                if !keyNote.isEmpty { Text(keyNote).font(.caption2) }
            }
            Text(ra.status).font(.caption2).fixedSize(horizontal: false, vertical: true)
            if let e = ra.lastError {
                Text(e).font(.caption2).foregroundStyle(Vana.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Progress is fetched by the launcher and written next to Vanaguide's config; "
                 + "the game itself never goes online for it. On HorizonXI, view it in Vanaguide "
                 + "Companion.")
                .font(.caption2).foregroundStyle(Vana.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { ra.showExisting(gameDir: gameDir) }
    }
}
