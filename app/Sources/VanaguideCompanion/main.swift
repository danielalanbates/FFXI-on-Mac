// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// VanaguideCompanion — the Completionist's Guide as a completely separate GUI app for worlds
// whose addon allowlist excludes Vanaguide. It never injects into the client, never reads game
// memory, and never sniffs packets: it walks the same guide files manually, with the player
// pressing Next/Back/Done (the /vg next equivalent). Optional local screenshot OCR selects a
// matching quest section, without completing steps or controlling the game.
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
        // A second user-launched copy exits quietly. It must never create another capture
        // timer, re-open the game or move focus away from an existing play session.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            exit(0)
        }
    }

    var body: some Scene {
        Window("VanaGuide Server-Safe", id: "guide") {
            CompanionView()
                .preferredColorScheme(.dark)
                .tint(Theme.crystal)
        }
        .windowResizability(.contentSize)
    }
}

final class CompanionState: ObservableObject {
    @Published var guides: [Guide] = []
    @Published var selected: Int = 0
    @Published var stepIndex: Int = 0
    @Published var sourceNote = ""
    @Published var screenshotMatchNote = ""
    private var catalogue: [CatalogueEntry] = []
    @Published var zones = WorldMap()
    /// The player's zone, from the last "=== Area: … ===" line screen reading saw.
    @Published var currentZone: Int? {
        didSet {
            guard currentZone != oldValue else { return }
            heardHere = []
            if let z = currentZone, !character.isEmpty {
                UserDefaults.standard.set(["zone": z, "at": Date().timeIntervalSince1970], forKey: "zone.\(world).\(character)")
            }
        }
    }

    /// The zone this character was last seen in, if within two hours: Server-Safe restarted
    /// mid-session, the Area line may have scrolled away.
    func restoreZone() {
        guard currentZone == nil,
              let d = UserDefaults.standard.dictionary(forKey: "zone.\(world).\(character)"),
              let z = d["zone"] as? Int, let at = d["at"] as? Double,
              Date().timeIntervalSince1970 - at < 7200 else { return }
        currentZone = z
        DevTrace.log("zone-restored", ["id": z])
    }

    /// Developer Mode: record quest givers and zones while playing (LearnedData.swift).
    @Published var devMode = UserDefaults.standard.bool(forKey: "dev.mode") {
        didSet { UserDefaults.standard.set(devMode, forKey: "dev.mode") }
    }
    @Published var learned = LearnedData.load()
    /// Speakers seen in the current zone this session, newest first.
    @Published var heardHere: [String] = []
    @Published var devNote = ""

    /// Character discovery (CharacterDiscovery.swift) and the launcher-supplied world.
    @Published var discoveryNote = ""
    private var nameVote = CharacterDiscovery.Vote()
    private var lastAreaSeen: Date?
    /// Lines on screen in the previous sample; Developer Mode only records speakers on new ones,
    /// so a line still showing from the last zone is not credited to this one.
    private var seenLines = Set<String>()
    private var lastLines: [String]?
    private var baselined = false
    var requestDiscovery: (() -> Void)?
    var discoveryDone: (() -> Void)?

    /// Fill World from the launcher's session file when it names a different one.
    func applyLauncherWorld() {
        guard let w = CharacterDiscovery.launcherWorld(), w != world else { return }
        world = w
        loadCharacter()
    }

    /// Reading just started: use the window title if it is the name, else search the status box.
    func readingStarted(windowTitle: String?) {
        nameVote = CharacterDiscovery.Vote()
        if let n = windowTitle.flatMap(CharacterDiscovery.name(fromTitle:)) {
            setCharacter(n)
        } else {
            discoveryNote = "Looking for your character name…"
            requestDiscovery?()
        }
    }

    func readStatusText(_ text: String) {
        DevTrace.log("status", ["text": text])
        guard let n = nameVote.observe(CharacterDiscovery.candidates(fromStatus: text)) else { return }
        setCharacter(n)
        discoveryDone?()
    }

    func setCharacter(_ name: String) {
        DevTrace.log("character", ["name": name, "world": world])
        discoveryNote = "Playing as \(name)."
        guard name != character else { restoreZone(); return }
        character = name
        loadCharacter()
        restoreZone()
        stepIndex = 0
        selected = progress.entries.isEmpty ? 0 : min(1, max(guides.count - 1, 0))
    }
    private var screenshotTracker = ScreenshotMatchTracker()

    /// This character's local progress record (see LogProgress.swift).
    @Published var character = UserDefaults.standard.string(forKey: "progress.character") ?? ""
    @Published var world = UserDefaults.standard.string(forKey: "progress.world") ?? ""
    @Published var progress = CharacterProgress(character: "", world: "")
    @Published var surveyNote = ""
    @Published var recentlyRead: [String] = []

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

    init() {
        // Someone who has used Screen Reading will again: load the recognizer now, not at Start.
        if UserDefaults.standard.bool(forKey: "reading.used") { ScreenGuideCapture.warmUp() }
        reload()
        if let w = CharacterDiscovery.launcherWorld(), world.isEmpty || w != world { world = w }
        loadCharacter()
        // A character with nothing recorded starts on Getting started; others on their guides.
        selected = progress.entries.isEmpty ? 0 : min(1, max(guides.count - 1, 0))
        // Developer preview: --open-guide "<name>" [--step <n>] [--zone <id>], for screenshots.
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        if let name = value("--open-guide"), let gi = guides.firstIndex(where: { $0.name == name }) {
            selected = gi
            stepIndex = min(max((value("--step").flatMap(Int.init) ?? 1) - 1, 0), max(guides[gi].steps.count - 1, 0))
        }
        if let z = value("--zone").flatMap(Int.init) { currentZone = z }
        if args.contains("--dev-preview") { devMode = true; heardHere = ["Gulemont", "Antreneau", "Thierride"] }
    }

    func loadCharacter() {
        UserDefaults.standard.set(character, forKey: "progress.character")
        UserDefaults.standard.set(world, forKey: "progress.world")
        progress = ProgressStore.load(character: character, world: world)
        surveyNote = progress.entries.isEmpty ? ""
            : "\(progress.completedCount) completed, \(progress.currentCount) current on record."
        recentlyRead = []
    }

    static func key(for step: GuideStep) -> String? {
        if let t = step.tags["Q"] ?? step.tags["QA"] { return "Q:\(t)" }
        if let t = step.tags["M"] ?? step.tags["MA"] { return "M:\(t)" }
        return nil
    }

    /// The step with a giver recorded in Developer Mode filled in where the data has none.
    func resolved(_ step: GuideStep) -> GuideStep {
        guard let key = Self.key(for: step), let g = learned.givers[key] else { return step }
        var s = step
        if s.tags["NPC"] == nil || s.zone == nil {
            s.tags["NPC"] = g.npc
            s.zone = g.zone
            s.tags["LEARNED"] = "1"
        }
        return s
    }

    func assignGiver(_ npc: String, to step: GuideStep) {
        guard let key = Self.key(for: step), let zone = currentZone else { return }
        learned.givers[key] = LearnedGiver(npc: npc, zone: zone, recorded: Date())
        learned.save()
        devNote = "Saved: \(npc) in \(zones.name(zone))."
    }

    func clearGiver(for step: GuideStep) {
        guard let key = Self.key(for: step) else { return }
        learned.givers[key] = nil
        learned.save()
        devNote = "Cleared."
    }

    /// Writes guide data to Downloads (the only place this project saves exports).
    func exportLearned() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/vanaguide-learned-\(f.string(from: Date())).lua")
        let text = learned.export(entries: catalogue, zoneName: { self.zones.name($0) })
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            devNote = "Exported \(learned.givers.count) givers to Downloads/\(url.lastPathComponent)."
        } catch { devNote = "Export failed: \(error.localizedDescription)" }
    }

    func status(of step: GuideStep) -> LogRecord? {
        Self.key(for: step).flatMap { progress.entries[$0] }
    }

    var isSurveying: Bool {
        guard guides.indices.contains(selected), guides[selected].name == LogSurvey.guideName,
              guides[selected].steps.indices.contains(stepIndex) else { return false }
        return guides[selected].steps[stepIndex].tags["LOG"] != "none"
    }

    /// Done on a step with a quest/mission: accepting makes it current, anything else completes it.
    func markDone(_ step: GuideStep) {
        guard let key = Self.key(for: step) else { return }
        let status: LogStatus = (step.kind == "A" || step.tags["QA"] != nil || step.tags["MA"] != nil)
            ? .current : .completed
        if progress.record(key, status, source: "done") { ProgressStore.save(progress) }
    }

    func nextUnfinished() {
        guard guides.indices.contains(selected) else { return }
        let steps = guides[selected].steps
        var i = stepIndex + 1
        while i < steps.count, status(of: steps[i])?.status == .completed { i += 1 }
        if i < steps.count { stepIndex = i }
    }

    private func readLogPage(_ text: String) {
        let step = guides[selected].steps[stepIndex]
        let fallback = LogStatus(rawValue: step.tags["LOG"] ?? "")
        let reading = LogSurvey.read(text: text, entries: catalogue, fallback: fallback)
        DevTrace.log("survey", ["keys": reading.keys, "status": reading.status?.rawValue ?? "", "area": reading.area ?? ""])
        guard let status = reading.status else {
            surveyNote = "Open Current Quests or Completed Quests so the guide knows which list this is."
            return
        }
        guard !reading.keys.isEmpty else {
            surveyNote = "No quest or mission titles visible yet."
            return
        }
        var added = 0
        for key in reading.keys where progress.record(key, status, source: "quest log") { added += 1 }
        ProgressStore.save(progress)
        let names = reading.keys.compactMap { k in catalogue.first { $0.key == k }?.name }
        recentlyRead = Array((names + recentlyRead).prefix(12))
        surveyNote = "Read \(reading.keys.count) \(status.rawValue) (\(added) new). "
            + "\(progress.completedCount) completed, \(progress.currentCount) current on record."
    }

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
        roots += CodeFolders.googleDriveCodeRoots.map {
            $0.appendingPathComponent("GitHub/vanaguide/Vanaguide", isDirectory: true)
        }
        roots.append(home.appendingPathComponent("Downloads/vanaguide/Vanaguide"))
        return roots
    }

    func reload() {
        let fm = FileManager.default
        guides = []
        catalogue = []
        sourceNote = "no guide files found"
        for root in Self.vanaguideRoots {
            let g = root.appendingPathComponent("guides")
            guard fm.fileExists(atPath: g.path) else { continue }
            let loaded = GuideParser.loadAll(from: g)
            let entries = QuestCatalogue.entries(at: root)
            if !loaded.isEmpty || !entries.isEmpty {
                zones = WorldMap.load(root: root)
                guides = [LogSurvey.guide] + loaded.map { var g = $0; g.name = QuestCatalogue.displayName(g.name); return g }
                catalogue = entries
                guides += QuestCatalogue.referenceGuides(catalogue)
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

    func resetScreenshotMatching() {
        screenshotTracker = ScreenshotMatchTracker()
        screenshotMatchNote = ""
    }

    /// Two consecutive unique matches select a section. Existing progress stays manual.
    func readScreenshotText(_ text: String) {
        DevTrace.log("ocr", ["text": text, "surveying": isSurveying])
        // A line is known by its first 24 normalized characters, so OCR noise later in a long
        // line, or a re-wrap, does not make an old line look new.
        let rawLines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let arrivals = ChatDiff.newLines(seen: &seenLines, previous: lastLines, current: rawLines)
        lastLines = rawLines
        let fresh = baselined ? arrivals.joined(separator: "\n") : ""
        if !fresh.isEmpty { DevTrace.log("fresh", ["lines": arrivals]) }
        baselined = true
        var zoneChanged = false
        if let z = zones.zone(inChat: text) {
            if z != currentZone {
                DevTrace.log("zone", ["id": z, "name": zones.name(z)])
                // Everything on screen at a zone change belongs to before it.
                zoneChanged = true
                seenLines = Set(ChatDiff.keys(rawLines))
            }
            currentZone = z
            // An Area line after a quiet spell is a login or character switch: look again.
            if lastAreaSeen.map({ Date().timeIntervalSince($0) > 120 }) ?? true {
                nameVote = CharacterDiscovery.Vote()
                requestDiscovery?()
            }
            lastAreaSeen = Date()
        }
        if devMode, !zoneChanged, let z = currentZone {
            let heard = learned.hear(fresh, zone: z, excluding: character)
            if !heard.isEmpty {
                DevTrace.log("heard", ["names": heard, "zone": z])
                learned.save()
                heardHere = Array((heard.reversed() + heardHere.filter { !heard.contains($0) }).prefix(12))
                // Test hook (--dev-autotest): do what clicking the newest name and Export do.
                if DevTrace.args.contains("--dev-autotest"), guides.indices.contains(selected),
                   guides[selected].steps.indices.contains(stepIndex), let name = heard.last {
                    let step = guides[selected].steps[stepIndex]
                    if let key = Self.key(for: step), learned.givers[key] == nil {
                        assignGiver(name, to: step)
                        exportLearned()
                        DevTrace.log("assigned", ["npc": name, "key": key, "note": devNote])
                    }
                }
            }
        }
        if isSurveying { readLogPage(text); return }
        // Titles: whole screen, two samples. Speakers: only lines new since reading began, so old
        // chat (a previous step, a previous session) never drags the guide somewhere else.
        let titled = ScreenshotGuideMatcher.match(text: text, entries: catalogue, guides: guides, speakers: false)
        // The sample that shows a zone change is baseline only: nobody speaks to an NPC in the
        // same instant they arrive, and the log often re-shows old lines as it changes.
        let spoken = (fresh.isEmpty || zoneChanged) ? nil
            : ScreenshotGuideMatcher.speakerMatch(text: fresh, entries: catalogue, guides: guides)
        // A giver's line counts as new only once, so it needs no once-per-session limit; that
        // limit let a stray old line use up a quest and ignore the real one later (2026-10-28).
        let speakerPick = spoken.flatMap { m in (m.guide == selected && m.step == stepIndex) ? nil : m }
        guard let confirmed = screenshotTracker.observe(titled) ?? speakerPick else { return }
        // Keep a player's more advanced manual checkpoint in an already selected route.
        if ScreenshotGuideMatcher.preservesCheckpoint(currentGuide: selected, currentStep: stepIndex,
                                                      match: confirmed, guides: guides) {
            screenshotMatchNote = "Recognized \(confirmed.title)."
            return
        }
        selected = confirmed.guide
        stepIndex = confirmed.step
        screenshotMatchNote = "Opened \(confirmed.title)."
        DevTrace.log("opened", ["title": confirmed.title, "key": confirmed.key,
                                "guide": guides[confirmed.guide].name, "step": confirmed.step + 1])
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
            progressNote = "No progress yet. Add your RetroAchievements username and key in FFXI on Mac › Setup & Diagnostics, then Refresh."
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
    @StateObject private var capture = ScreenGuideCapture()
    @State private var tab = 0
    @State private var showReading = false

    static let width: CGFloat = 620
    static let height: CGFloat = 460

    var body: some View {
        VStack(spacing: 8) {
            header
            Group { if tab == 0 { guidesPane } else { achievementsPane } }
                .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(width: Self.width, height: Self.height)
        .foregroundStyle(Theme.text)
        .background(Theme.backdrop)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            state.reloadProgress()
            state.applyLauncherWorld()
        }
        .onAppear {
            capture.receivedText = { state.readScreenshotText($0) }
            capture.receivedStatus = { state.readStatusText($0) }
            state.requestDiscovery = { capture.beginDiscovery() }
            state.discoveryDone = { capture.endDiscovery() }
            if let want = DevTrace.value("--auto-read") { autoRead(want) }
            // Test hook: --replay <trace.jsonl> feeds a recorded run's OCR text back through
            // the same reader, so a live miss can be reproduced offline.
            if let path = DevTrace.value("--replay"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          obj["event"] as? String == "ocr", let ocr = obj["text"] as? String else { continue }
                    DevTrace.log("replay", ["at": obj["t"] as? String ?? ""])
                    state.readScreenshotText(ocr)
                }
                DevTrace.log("replay-done")
            }
        }
        .onChange(of: state.isSurveying) { capture.fullWindow = $0 }
        .onDisappear { capture.stop() }
    }

    /// Test hook: choose the game window by title and start reading, with no clicks.
    func autoRead(_ want: String) {
        if let c = DevTrace.crop { capture.crop = c }
        capture.refreshWindows()
        Task { @MainActor in
            for _ in 0..<40 {
                if let w = capture.windows.first(where: { $0.title.localizedCaseInsensitiveContains(want) })
                    ?? (want.isEmpty ? capture.windows.first : nil) {
                    capture.selectedID = w.id
                    state.resetScreenshotMatching()
                    capture.fullWindow = state.isSurveying
                    capture.start()
                    let title = DevTrace.args.contains("--ignore-title") ? nil : capture.targetTitle
                    DevTrace.log("reading", ["window": w.title, "running": capture.running, "note": capture.note])
                    state.readingStarted(windowTitle: title)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !capture.busy && capture.windows.isEmpty { capture.refreshWindows() }
            }
            DevTrace.log("reading-failed", ["note": capture.note, "windows": capture.windows.map(\.label)])
        }
    }

    // MARK: Header — tabs, character, screen reading

    var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("VanaGuide").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.gold)
                Text("Server-Safe").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Picker("", selection: $tab) {
                    Text("Guides").tag(0)
                    Text("Achievements").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                Spacer()
                Button {
                    state.devMode.toggle()
                } label: {
                    Image(systemName: state.devMode ? "hammer.fill" : "hammer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.devMode ? Theme.night : Theme.text)
                        .frame(width: 26, height: 20)
                        .background(Capsule().fill(state.devMode ? Theme.gold : Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(state.devMode ? "Developer Mode is on: recording quest givers and zones. Click to turn off."
                                    : "Developer Mode: record quest givers and their zones while you play.")
                readingStatus
            }
            HStack(spacing: 6) {
                TextField("Character", text: $state.character).frame(width: 110)
                    .onSubmit { state.loadCharacter() }
                TextField("World", text: $state.world).frame(width: 110)
                    .onSubmit { state.loadCharacter() }
                Button("Load") { state.loadCharacter() }
                Spacer()
                if !state.discoveryNote.isEmpty {
                    Text(state.discoveryNote).font(.caption).foregroundStyle(Theme.crystal).lineLimit(1)
                }
                Text("\(state.progress.completedCount) completed · \(state.progress.currentCount) current")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .textFieldStyle(.roundedBorder).controlSize(.small)
        }
    }

    var readingStatus: some View {
        HStack(spacing: 6) {
            if capture.running {
                Circle().fill(ScreenGuideCapture.warm ? Theme.jade : Theme.gold).frame(width: 8, height: 8)
                    .help(!ScreenGuideCapture.warm ? "Preparing text recognition…"
                          : capture.discovering ? "Finding your character…" : capture.note)
                Button("Stop") { capture.stop() }.controlSize(.small)
            } else {
                Button("Screen Reading…") { showReading.toggle() }
                    .controlSize(.small)
                    .popover(isPresented: $showReading, arrowEdge: .bottom) { readingSettings }
            }
        }
    }

    var readingSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screen Reading").font(.headline).foregroundStyle(Theme.gold)
            Text("Reads the chosen game window every 10 seconds, on this Mac only. Use it where your server permits screen tools.")
                .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Find Game Window") { capture.refreshWindows() }.disabled(capture.busy)
                Picker("", selection: $capture.selectedID) {
                    Text("Choose…").tag(Optional<CGWindowID>.none)
                    ForEach(capture.windows) { window in Text(window.label).tag(Optional(window.id)) }
                }
                .labelsHidden()
            }
            SectionLabel(text: "Chat area, % of window")
            HStack(spacing: 8) {
                cropField("Left", value: $capture.crop.left)
                cropField("Top", value: $capture.crop.top)
                cropField("Width", value: $capture.crop.width)
                cropField("Height", value: $capture.crop.height)
            }
            if !capture.note.isEmpty {
                Text(capture.note).font(.caption).foregroundStyle(Theme.muted)
            }
            HStack {
                Spacer()
                Button("Start Reading") {
                    state.resetScreenshotMatching()
                    capture.fullWindow = state.isSurveying
                    capture.start()
                    state.readingStarted(windowTitle: capture.targetTitle)
                    tab = 0
                    showReading = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(capture.selectedID == nil || !capture.crop.valid || capture.busy)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    func cropField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 56).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Guides

    var guide: Guide? {
        state.guides.indices.contains(state.selected) ? state.guides[state.selected] : nil
    }

    var guidesPane: some View {
        HStack(spacing: 8) {
            Card {
                List(state.guides.indices, id: \.self, selection: Binding(
                    get: { state.selected },
                    set: { state.selected = $0 ?? 0; state.stepIndex = 0 }
                )) { i in
                    Text(state.guides[i].name).font(.callout).lineLimit(2)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
            }
            .frame(width: 190)

            Card { stepDetail }
        }
    }

    @ViewBuilder
    var stepDetail: some View {
        if let g = guide {
            VStack(alignment: .leading, spacing: 8) {
                Text(g.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gold)
                    .lineLimit(2)
                if !g.desc.isEmpty {
                    Text(g.desc).font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if g.steps.indices.contains(state.stepIndex) {
                    let s = state.resolved(g.steps[state.stepIndex])
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "Step \(state.stepIndex + 1) of \(g.steps.count)")
                            stepCard(s)
                            stepStatus(s, in: g)
                            if state.devMode { devPanel(s) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Button("Back") { if state.stepIndex > 0 { state.stepIndex -= 1 } }
                    Button("Done") {
                        if g.steps.indices.contains(state.stepIndex) { state.markDone(g.steps[state.stepIndex]) }
                        if state.stepIndex < g.steps.count - 1 { state.stepIndex += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Next Unfinished") { state.nextUnfinished() }
                    Spacer()
                    if !state.screenshotMatchNote.isEmpty {
                        Text(state.screenshotMatchNote).font(.caption2).foregroundStyle(Theme.crystal).lineLimit(1)
                    }
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No guides loaded (\(state.sourceNote)).")
                Button("Reload") { state.reload() }
            }
        }
    }

    /// Zygor-style: one plain action, where it happens, how to get there. No numbers.
    @ViewBuilder
    func stepCard(_ s: GuideStep) -> some View {
        let npc = s.tags["NPC"]?.npcDisplay
        let isQuest = s.tags["Q"] != nil || s.tags["QA"] != nil
        let isMission = s.tags["M"] != nil || s.tags["MA"] != nil
        Text(npc.map { $0.hasPrefix("the ??? marker") ? "Examine \($0)" : "Talk to \($0)" } ?? s.title)
            .font(.system(size: 17, weight: .semibold))
        if s.zone != nil {
            Label("in \(state.zones.name(s.zone))", systemImage: "mappin.and.ellipse")
                .font(.callout).foregroundStyle(Theme.crystal)
        }
        if npc != nil && (isQuest || isMission) {
            Label("\(isMission ? "Mission" : "Quest"): \(s.title)", systemImage: isMission ? "flag" : "scroll")
                .font(.callout)
        }
        if s.tags["LEARNED"] != nil {
            Text("Location recorded in Developer Mode").font(.caption2).foregroundStyle(Theme.gold)
        }
        if let lv = s.tags["LV"] {
            Label("Recommended level \(lv)", systemImage: "chart.bar").font(.caption).foregroundStyle(Theme.muted)
        }
        if let n = s.note {
            Text(n).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        howToGetThere(s, npc: npc)
    }

    @ViewBuilder
    func howToGetThere(_ s: GuideStep, npc: String?) -> some View {
        if let target = s.zone {
            SectionLabel(text: "How to get there").padding(.top, 4)
            if let here = state.currentZone {
                if here == target {
                    Text(npc.map { $0.isMarker
                            ? "You're in the right place. Look for a small glowing \"???\" spot, target it and press Enter."
                            : "You're in the right place. Look around for \($0), walk up to them, target them and press Enter to talk." }
                         ?? "You're in the right place.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } else if let hops = state.zones.route(from: here, to: target) {
                    Text("You're in \(state.zones.name(here)).").font(.caption).foregroundStyle(Theme.muted)
                    ForEach(Array(state.zones.directions(hops).enumerated()), id: \.offset) { i, line in
                        Text("\(i + 1). \(line)").font(.callout)
                    }
                    if let npc {
                        Text("\(hops.count + 1). " + (npc.isMarker ? "Find the small glowing \"???\" spot, target it and press Enter."
                                                                   : "Find \(npc), target them and press Enter to talk."))
                            .font(.callout)
                    }
                } else {
                    Text("No known route from \(state.zones.name(here)) yet. Head for \(state.zones.name(target)).")
                        .font(.callout)
                }
            } else {
                Text("Go to \(state.zones.name(target))\(npc.map { $0.isMarker ? " and find the small glowing \"???\" spot. Target it and press Enter." : " and find \($0). Target them and press Enter to talk." } ?? ".")")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Turn on Screen Reading and the guide will give turn-by-turn directions from where you are.")
                    .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        } else if s.tags["Q"] != nil || s.tags["M"] != nil {
            Text("The guide doesn't know where this one starts yet.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    /// Developer Mode panel: where the reader thinks you are, who it has heard, and a one-click
    /// way to record the quest giver for the step on screen.
    @ViewBuilder
    func devPanel(_ s: GuideStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Developer Mode")
            if !capture.running {
                Text("Start Screen Reading to record.").font(.caption).foregroundStyle(Theme.ember)
            }
            Text(state.currentZone.map { "Zone: \(state.zones.name($0))" }
                 ?? "Zone unknown — change zones once so the Area line appears in chat.")
                .font(.caption).foregroundStyle(Theme.crystal)
            if let key = CompanionState.key(for: s) {
                if let g = state.learned.givers[key] {
                    HStack {
                        Text("Recorded giver: \(g.npc) in \(state.zones.name(g.zone))").font(.caption)
                        Button("Clear") { state.clearGiver(for: s) }.controlSize(.mini)
                    }
                }
                if state.heardHere.isEmpty {
                    Text("Talk to the quest giver; their name appears here.").font(.caption).foregroundStyle(Theme.muted)
                } else {
                    Text("Heard here — click the giver of \(s.title):").font(.caption).foregroundStyle(Theme.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(state.heardHere, id: \.self) { name in
                            Button(name) { state.assignGiver(name, to: s) }
                                .controlSize(.small)
                                .disabled(state.currentZone == nil)
                        }
                    }
                }
            } else {
                Text("This step has no quest or mission to record.").font(.caption).foregroundStyle(Theme.muted)
            }
            HStack {
                Text("\(state.learned.givers.count) givers recorded · \(state.learned.speakers.count) speakers heard")
                    .font(.caption2).foregroundStyle(Theme.muted)
                Spacer()
                Button("Export to Downloads") { state.exportLearned() }
                    .controlSize(.small).disabled(state.learned.givers.isEmpty)
            }
            if !state.devNote.isEmpty { Text(state.devNote).font(.caption2).foregroundStyle(Theme.jade) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Theme.gold.opacity(0.5)))
        .padding(.top, 6)
    }

    @ViewBuilder
    func stepStatus(_ s: GuideStep, in g: Guide) -> some View {
        if let r = state.status(of: s) {
            Text(r.status == .completed ? "Completed · from your \(r.source)" : "Current · from your \(r.source)")
                .font(.caption).foregroundStyle(r.status == .completed ? Theme.jade : Theme.crystal)
        } else if s.fixed && s.tags["LOG"] == nil {
            Text("Press Done once you have finished this in game.")
                .font(.caption).foregroundStyle(Theme.gold)
        }
        if g.name == LogSurvey.guideName {
            if s.tags["LOG"] != "none" && !capture.running {
                Text("Start Screen Reading so this page can be recorded.")
                    .font(.caption).foregroundStyle(Theme.ember)
            }
            if !state.surveyNote.isEmpty {
                Text(state.surveyNote).font(.caption).foregroundStyle(Theme.muted)
            }
            if !state.recentlyRead.isEmpty {
                Text("Just read: " + state.recentlyRead.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Achievements

    var currentSet: AchievementSetView? {
        state.achievementSets.first { $0.id == state.selectedSet }
    }

    var achievementsPane: some View {
        HStack(spacing: 8) {
            Card {
                List(state.achievementSets, selection: $state.selectedSet) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.callout)
                        Text(s.earned.map { "\($0) / \(s.total) earned" } ?? "\(s.total) achievements")
                            .font(.caption2).foregroundStyle(Theme.muted)
                    }
                    .tag(s.id)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
            }
            .frame(width: 190)

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.progressNote).font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let s = currentSet {
                        Text(s.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gold)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if !s.remaining.isEmpty {
                                    SectionLabel(text: "To Do")
                                    ForEach(s.remaining) { r in row(r) }
                                }
                                if !s.earnedRows.isEmpty {
                                    SectionLabel(text: "Earned").padding(.top, 6)
                                    ForEach(s.earnedRows) { r in row(r) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("No achievement sets to show.").foregroundStyle(Theme.muted)
                        Spacer()
                    }
                    HStack {
                        Button("Reload") { state.reload() }
                        Button("Choose Progress File…") { state.chooseSnapshot() }
                        Spacer()
                        Text(state.achievementNote).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    func row(_ r: AchievementRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.info.title).font(.callout).bold()
                if let p = r.info.points { Text("\(p) pts").font(.caption2).foregroundStyle(Theme.muted) }
                if let t = r.info.type, t == "missable" {
                    Text("Missable").font(.caption2).foregroundStyle(Theme.ember)
                }
                Spacer()
                switch r.state {
                case .earned(let d): Text("Earned \(Self.shortDate(d))").font(.caption2).foregroundStyle(Theme.jade)
                case .notEarned: EmptyView()
                case .unknown: Text("Progress unknown").font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            if !r.info.description.isEmpty {
                Text(r.info.description).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !r.isEarned, !r.info.targets.isEmpty {
                HStack(spacing: 6) {
                    Text("Guide target: " + r.info.targets.map(\.label).joined(separator: "; ")
                         + (r.info.confidence.map { " (\($0) confidence)" } ?? ""))
                        .font(.caption2).foregroundStyle(Theme.muted)
                    if let link = state.guideLink(for: r.info) {
                        Button("Open in Guide") {
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
