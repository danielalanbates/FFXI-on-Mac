// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// VanaguideCompanion — the Completionist's Guide as a completely separate GUI app for worlds
// whose addon allowlist excludes Vanaguide. It never injects into the client, never reads game
// memory, and never sniffs packets: it walks the same guide files manually, with the player
// pressing Next/Back/Done (the /vg next equivalent). Screenshot-OCR auto-advance comes later;
// see ../vanaguide/docs/COMPANION_APP.md.
//
// RetroAchievements: progress is read from the snapshot the FFXI-on-Mac launcher writes (see
// Achievements.swift); the companion itself never goes online.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    @Published var achievementSets: [AchievementSetView] = []
    @Published var selectedSet: Int?
    @Published var achievementNote = ""
    @Published var progressNote = ""
    @Published var snapshot: ProgressSnapshot?
    private var achievementData: (sets: [AchievementSetInfo], achievements: [AchievementInfo])?
    private var snapshotURL: URL?
    private var snapshotModified: Date?

    /// A snapshot file the player picked by hand (Choose…), remembered for next time.
    var chosenSnapshot: String? {
        get { UserDefaults.standard.string(forKey: "ra.chosenSnapshot") }
        set { UserDefaults.standard.set(newValue, forKey: "ra.chosenSnapshot") }
    }

    init() { reload() }

    /// Vanaguide addon roots (the folder holding guides/ and data/), first hit wins. The bundled
    /// copy when packaged; checkouts for development; VANAGUIDE_ROOT overrides. Nothing is read
    /// from the game.
    static var vanaguideRoots: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env))
        }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Vanaguide") { roots.append(r) }
        roots.append(home.appendingPathComponent(
            "Library/CloudStorage/GoogleDrive-danielalanbates@gmail.com/My Drive/Code/GitHub/vanaguide/Vanaguide"))
        roots.append(home.appendingPathComponent("Downloads/vanaguide/Vanaguide"))
        return roots
    }

    func reload() {
        let fm = FileManager.default
        guides = []
        sourceNote = "no guide files found"
        for root in Self.vanaguideRoots {
            let g = root.appendingPathComponent("guides")
            guard fm.fileExists(atPath: g.path) else { continue }
            let loaded = GuideParser.loadAll(from: g)
            if !loaded.isEmpty {
                guides = loaded
                sourceNote = root.path.contains("/Resources/") ? "bundled guides" : "development checkout"
                break
            }
        }
        achievementData = nil
        achievementNote = "achievement lists not installed yet (Vanaguide/data/achievements.lua)"
        for root in Self.vanaguideRoots {
            let f = root.appendingPathComponent("data/achievements.lua")
            if let d = AchievementData.load(f) {
                achievementData = d
                achievementNote = "\(d.achievements.count) achievements in \(d.sets.count) sets"
                break
            }
        }
        reloadProgress(force: true)
    }

    /// Re-read the snapshot when it changed on disk. File reads only.
    func reloadProgress(force: Bool = false) {
        let paths = ProgressSnapshot.candidatePaths(chosen: chosenSnapshot)
        let found = ProgressSnapshot.newest(paths)
        let modified = found.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.0.path))?[.modificationDate] as? Date
        }
        if !force, found?.0 == snapshotURL, modified == snapshotModified { return }
        snapshotURL = found?.0
        snapshotModified = modified
        snapshot = found?.1
        if let s = snapshot {
            let when = DateFormatter.localizedString(from: s.fetchedDate, dateStyle: .medium, timeStyle: .short)
            progressNote = s.isStale()
                ? "Progress for \(s.user) is from \(when), more than a day old: earned ones are shown, the rest are unknown until the launcher refreshes."
                : "Progress for \(s.user) as of \(when)."
        } else {
            progressNote = "No progress data. Set your RetroAchievements username and key in FFXI on Mac › Setup & Diagnostics, then Refresh."
        }
        achievementSets = AchievementMerge.merge(data: achievementData, snapshot: snapshot)
        if let sel = selectedSet, !achievementSets.contains(where: { $0.id == sel }) { selectedSet = nil }
        if selectedSet == nil { selectedSet = achievementSets.first?.id }
    }

    func chooseSnapshot() {
        let p = NSOpenPanel()
        p.title = "Choose retroachievements.json"
        p.allowedContentTypes = [.json]
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let u = p.url else { return }
        chosenSnapshot = u.path
        reloadProgress(force: true)
    }

    /// The first guide step that reaches one of this achievement's targets.
    func guideLink(for a: AchievementInfo) -> (guide: Int, step: Int)? {
        guard !a.targets.isEmpty else { return nil }
        for (gi, g) in guides.enumerated() {
            for (si, s) in g.steps.enumerated() where a.targets.contains(where: { $0.matches(s) }) {
                return (gi, si)
            }
        }
        return nil
    }
}

struct CompanionView: View {
    @StateObject var state = CompanionState()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Guides").tag(0)
                Text("Achievements").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(8)
            Divider()
            if tab == 0 { guidesPane } else { achievementsPane }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            state.reloadProgress()
        }
    }

    var guide: Guide? {
        state.guides.indices.contains(state.selected) ? state.guides[state.selected] : nil
    }

    var guidesPane: some View {
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

    var currentSet: AchievementSetView? {
        state.achievementSets.first { $0.id == state.selectedSet }
    }

    var achievementsPane: some View {
        HStack(spacing: 0) {
            List(state.achievementSets, selection: $state.selectedSet) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.callout)
                    Text(s.earned.map { "\($0) / \(s.total) earned" } ?? "\(s.total) achievements")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .tag(s.id)
            }
            .frame(width: 230)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(state.progressNote).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let s = currentSet {
                    Text(s.title).font(.title3).bold()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if !s.remaining.isEmpty {
                                Text("TO DO").font(.caption2).tracking(2).foregroundStyle(.secondary)
                                ForEach(s.remaining) { r in row(r) }
                            }
                            if !s.earnedRows.isEmpty {
                                Text("EARNED").font(.caption2).tracking(2).foregroundStyle(.secondary)
                                    .padding(.top, 6)
                                ForEach(s.earnedRows) { r in row(r) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("No achievement sets to show.").foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Button("Reload") { state.reload() }
                    Button("Choose progress file…") { state.chooseSnapshot() }
                    Spacer()
                    Text(state.achievementNote).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(minWidth: 520, minHeight: 420, alignment: .topLeading)
        }
    }

    @ViewBuilder
    func row(_ r: AchievementRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.info.title).font(.callout).bold()
                if let p = r.info.points { Text("\(p) pts").font(.caption2).foregroundStyle(.secondary) }
                if let t = r.info.type, t == "missable" {
                    Text("missable").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                switch r.state {
                case .earned(let d): Text("earned \(Self.shortDate(d))").font(.caption2).foregroundStyle(.green)
                case .notEarned: EmptyView()
                case .unknown: Text("progress unknown").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !r.info.description.isEmpty {
                Text(r.info.description).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !r.isEarned, !r.info.targets.isEmpty {
                HStack(spacing: 6) {
                    Text("Guide target: " + r.info.targets.map(\.label).joined(separator: "; ")
                         + (r.info.confidence.map { " (\($0) confidence)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let link = state.guideLink(for: r.info) {
                        Button("Open in guide") {
                            state.selected = link.guide
                            state.stepIndex = link.step
                            tab = 0
                        }
                        .font(.caption2)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func shortDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none)
    }
}
