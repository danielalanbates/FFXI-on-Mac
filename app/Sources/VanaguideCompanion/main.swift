// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// VanaguideCompanion — the Completionist's Guide as a completely separate GUI app for worlds
// whose addon allowlist excludes Vanaguide. It never injects into the client, never reads game
// memory, and never sniffs packets: it walks the same guide files manually, with the player
// pressing Next/Back/Done (the /vg next equivalent). Screenshot-OCR auto-advance comes later;
// see ../vanaguide/docs/COMPANION_APP.md.

import SwiftUI

@main
struct CompanionApp: App {
    init() {
        // Keep the parser fixture available to the offline gate without top-level statements,
        // which conflict with SwiftUI's @main entry point.
        if CommandLine.arguments.contains("--selftest-parser") {
            CompanionSelfTest.run()
        }
    }

    var body: some Scene {
        WindowGroup("Vanaguide Companion") {
            CompanionView()
        }
        .windowResizability(.contentSize)
    }
}

final class CompanionState: ObservableObject {
    @Published var guides: [Guide] = []
    @Published var selected: Int = 0
    @Published var stepIndex: Int = 0
    @Published var sourceNote = ""

    init() { reload() }

    /// The guides ship inside this app bundle when packaged; a sibling vanaguide checkout is
    /// the development fallback. Nothing is read from the game.
    func reload() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Vanaguide/guides"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/CloudStorage/GoogleDrive-danielalanbates@gmail.com/My Drive/Code/GitHub/vanaguide/Vanaguide/guides"),
        ]
        for c in candidates {
            guard let c, FileManager.default.fileExists(atPath: c.path) else { continue }
            let loaded = GuideParser.loadAll(from: c)
            if !loaded.isEmpty {
                guides = loaded
                sourceNote = c.path.contains("Resources") ? "bundled guides" : "development checkout"
                return
            }
        }
        sourceNote = "no guide files found"
    }
}

struct CompanionView: View {
    @StateObject var state = CompanionState()

    var guide: Guide? {
        state.guides.indices.contains(state.selected) ? state.guides[state.selected] : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            List(state.guides.indices, id: \.self, selection: Binding(
                get: { state.selected },
                set: { state.selected = $0 ?? 0; state.stepIndex = 0 }
            )) { i in
                Text(state.guides[i].name).font(.callout)
            }
            .frame(width: 230)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let g = guide {
                    Text(g.name).font(.title3).bold()
                    Text(g.desc).font(.callout).foregroundStyle(.secondary)
                    Divider()
                    if g.steps.indices.contains(state.stepIndex) {
                        let s = g.steps[state.stepIndex]
                        Text("Step \(state.stepIndex + 1) of \(g.steps.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(s.title).font(.headline)
                        if let z = s.zone { Text("Zone \(z)").font(.caption) }
                        if let x = s.posX, let z = s.posZ {
                            Text(String(format: "Target (%.1f, %.1f)", x, z)).font(.caption)
                        }
                        if let n = s.note {
                            Text(n).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if s.fixed {
                            Text("Manual checkpoint — press Done after completing it in game.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    HStack {
                        Button("Back") { if state.stepIndex > 0 { state.stepIndex -= 1 } }
                        Button("Done / Next") {
                            if let g = guide, state.stepIndex < g.steps.count - 1 { state.stepIndex += 1 }
                        }
                        .keyboardShortcut(.defaultAction)
                        Spacer()
                        Text(state.sourceNote).font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No guides loaded (\(state.sourceNote)).")
                    Button("Reload") { state.reload() }
                }
            }
            .padding()
            .frame(minWidth: 460, minHeight: 380, alignment: .topLeading)
        }
    }
}
