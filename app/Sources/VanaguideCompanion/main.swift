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
        if CommandLine.arguments.contains("--selftest-layout") {
            CompanionLayoutSelfTest.run()
        }
        // A second user-launched copy exits quietly. It must never create another capture
        // timer, re-open the game or move focus away from an existing play session.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            exit(0)
        }
        // Test hook: --snapshot <png> draws the window off-screen after 4 s and quits, so the
        // layout can be checked without opening, focusing or covering anything.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(i + 1) {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Snapshot.write(to: path) }
        }
    }

    var body: some Scene {
        Window("ALPHA VanaGuide Server-Safe", id: "guide") {
            CompanionView()
                .preferredColorScheme(.dark)
                .tint(Theme.crystal)
        }
        // Resizable (Daniel, 2026-10-28); never smaller than the layout's design size.
        .windowResizability(.contentMinSize)
        .defaultSize(width: CompanionView.width, height: CompanionView.height)
    }
}

/// Automatic window reading is kept off in the public navigation UI.
enum Features {
    static let screenReading = false
}

final class CompanionState: ObservableObject {
    @Published var guides: [Guide] = []
    @Published var selected: Int = 0
    @Published var stepIndex: Int = 0
    @Published var guideSaveError = ""
    @Published var guideDetailOpen = true
    var storesGuideProgress = true
    var guideProgressWriter: (CharacterProgress) -> Bool = { ProgressStore.save($0) }
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
        selectWorld(w)
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
        remember()
        restoreZone()
        openInitialGuide()
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

    init(loadData: Bool = true) {
        storesGuideProgress = loadData
        // The hidden layout verifier uses synthetic state and never loads/saves a character,
        // discovers a game, warms OCR, or reads the launcher's session.
        guard loadData else {
            character = "Layout"
            world = "Local fixture"
            learned = LearnedData()
            worldOptions = [world]
            characterOptions = [character]
            guides = [Guide(name: "Layout fixture: a journey through Vana'diel",
                            desc: "Synthetic guide for checking readable text and controls while resizing.",
                            levels: "1+", steps: [GuideStep(kind: "t",
                                title: "Talk to the guide keeper at the city gates.",
                                zone: nil, posX: nil, posZ: nil,
                                note: "Follow the numbered directions, read the dialogue, then choose Next. "
                                    + "This longer paragraph checks wrapping in both compact and expanded windows.",
                                fixed: true)])]
            return
        }
        // Leave OCR idle until the player explicitly finds a game window. Starting the guide
        // for manual reference must not spend CPU loading the recognizer, even after prior use.
        if !Features.screenReading { devMode = false }
        reload()
        if let w = CharacterDiscovery.launcherWorld(), w != world {
            world = w
            character = Self.lastCharacter(on: w)
        }
        // Test hook: --world <name> picks the server, as the Server list would (for --snapshot).
        if let w = DevTrace.value("--world") { world = w }
        loadCharacter()
        // A character with nothing recorded starts on Getting started; others on their guides.
        openInitialGuide()
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

    /// Servers: the launcher's list, plus any world a character was saved under.
    @Published var worldOptions: [String] = []
    /// Characters saved under the chosen server, most recently played first.
    @Published var characterOptions: [String] = []

    func refreshOptions() {
        let saved = ProgressStore.saved()
        var worlds = CharacterDiscovery.launcherWorlds()
        for w in saved.map(\.world) + [world] where !w.isEmpty && !worlds.contains(w) { worlds.append(w) }
        worldOptions = worlds
        var names = saved.filter { $0.world == world }.map(\.character).filter { !$0.isEmpty }
        if !character.isEmpty && !names.contains(character) { names.insert(character, at: 0) }
        characterOptions = names
    }

    /// Choosing a server switches to the character last played there.
    func selectWorld(_ w: String) {
        guard w != world else { return }
        world = w
        character = Self.lastCharacter(on: w)
        loadCharacter()
        restoreZone()
        openInitialGuide()
    }

    /// Getting Started for a character with nothing on record; otherwise the
    /// first real guide.
    var startGuide: Int {
        let available = guides.indices.filter { guides[$0].available(on: world) }
        guard Features.screenReading, !progress.entries.isEmpty else { return available.first ?? 0 }
        return available.first(where: { guides[$0].name != LogSurvey.guide.name }) ?? available.first ?? 0
    }

    static func lastCharacter(on world: String) -> String {
        ProgressStore.saved().first { $0.world == world && !$0.character.isEmpty }?.character ?? ""
    }

    func setFoodProfile(job: String? = nil, nation: String? = nil) {
        if let job { progress.foodJob = job }
        if let nation { progress.homeNation = nation }
        ProgressStore.save(progress)
    }

    func selectCharacter(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != character else { return }
        character = n
        loadCharacter()
        remember()
        restoreZone()
        openInitialGuide()
    }

    /// Keeps a chosen or discovered character in this server's list from now on.
    private func remember() {
        guard !character.isEmpty, !world.isEmpty,
              !FileManager.default.fileExists(atPath: ProgressStore.directory
                  .appendingPathComponent(ProgressStore.fileName(character: character, world: world)).path)
        else { return }
        ProgressStore.save(progress)
        refreshOptions()
    }

    func loadCharacter() {
        UserDefaults.standard.set(character, forKey: "progress.character")
        UserDefaults.standard.set(world, forKey: "progress.world")
        progress = ProgressStore.load(character: character, world: world)
        refreshOptions()
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

    /// Opens a pre-filled "new file" page in the guide's public repository, in
    /// suggested-changes/. The player reviews it and proposes it with their own GitHub account;
    /// nothing is sent until they press the button there, and no credentials live in this app.
    /// The repository's tools/apply_suggestions.py adds givers only where a step has none.
    func suggestToGuide() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let text = learned.export(entries: catalogue, zoneName: { self.zones.name($0) })
        var c = URLComponents(string: "https://github.com/danielalanbates/vanaguide/new/master")!
        c.queryItems = [URLQueryItem(name: "filename", value: "suggested-changes/givers-\(f.string(from: Date())).lua"),
                        URLQueryItem(name: "value", value: text)]
        guard let url = c.url else { devNote = "Too much to suggest at once; use Export."; return }
        NSWorkspace.shared.open(url)
        devNote = "Opened GitHub: review the file there and press Commit/Propose to send it."
    }

    /// The guide step for a quest or mission a gear source names: "Quest: No Strings Attached
    /// (Aht Urhgan)", "… during the quest Scattered Into Shadow (Jeuno)". The full per-log
    /// guides win over authored routes, so the step always has its What to do.
    func questStep(named text: String) -> (guide: Int, step: Int)? { Self.questStep(in: guides, named: text) }

    static func questStep(in guides: [Guide], named text: String) -> (guide: Int, step: Int)? {
        let norm = ScreenshotGuideMatcher.normalized
        // Titles built from script constants lose or change small words ("Scattered Into Shadow"
        // for "Scattered into the Shadow", "Guest Of Hauteur" for "A Guest of Hauteur").
        let small: Set<String> = ["a", "an", "the", "of", "and", "into", "in", "to", "for", "on", "at", "s"]
        func core(_ t: String) -> String {
            norm(t.replacingOccurrences(of: "'", with: "")).split(separator: " ")
                .filter { !small.contains(String($0)) }.joined(separator: " ")
        }
        var byTitle: [String: (Int, Int)] = [:], byCore: [String: (Int, Int)] = [:]
        for (g, guide) in guides.enumerated() {
            for (i, st) in guide.steps.enumerated() where st.tags["Q"] != nil || st.tags["M"] != nil {
                // Also without a bracketed suffix: "Quelling the Storm (WOTG Nation Quests - Bastok 7)".
                let bare = st.title.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
                for t in Set([st.title, bare]) {
                    let k = norm(t), c = core(t)
                    if byTitle[k] == nil || guide.isReference { byTitle[k] = (g, i) }
                    if byCore[c] == nil || guide.isReference { byCore[c] = (g, i) }
                }
            }
        }
        // The title sits after "Quest:", "Mission:" or "the quest", before " (Area)" or ",".
        let pattern = #"(?i)(?:quest|mission)s?:?\s+(.+?)(?:\s+\([^)]*\))?(?:[,.]|$)"#
        if let r = try? NSRegularExpression(pattern: pattern),
           let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(m.range(at: 1), in: text) {
            let name = String(text[range])
            if let hit = byTitle[norm(name)] ?? byCore[core(name)] { return hit }
        }
        // Otherwise the longest known title inside the line (8+ characters, so "Dawn" can't match chatter).
        let line = " " + norm(text) + " "
        return byTitle.filter { $0.key.count >= 8 && line.contains(" " + $0.key + " ") }
            .max { $0.key.count < $1.key.count }.map { $0.value }
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
        let guide = guides[selected]
        let route = guide.activeStepIndices(startingLocation: progress.guideBookmarks?[guide.progressKey]?.startingLocation)
        if let next = route.first(where: { $0 > stepIndex && status(of: guide.steps[$0])?.status != .completed }) {
            moveToStep(next)
        }
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
                guides = (Features.screenReading ? [LogSurvey.guide] : []) + loaded.map { var g = $0; g.name = QuestCatalogue.displayName(g.name); return g }
                catalogue = entries
                let references = QuestCatalogue.referenceGuides(catalogue, walkthroughs: QuestCatalogue.walkthroughs(at: root))
                guides += (QuestCatalogue.jobUnlockGuide(from: references).map { [$0] } ?? []) + references
                guides = QuestCatalogue.contentOrder(guides)
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
        guard guides.indices.contains(confirmed.guide), guides[confirmed.guide].available(on: world) else { return }
        openGuide(confirmed.guide, at: confirmed.step)
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
            progressNote = paths.lazy.compactMap(ProgressSnapshot.problem).first
                ?? "No progress yet. Add your RetroAchievements username and key in FFXI on Mac › Setup & Diagnostics, then Refresh."
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
        for (gi, g) in guides.enumerated() {
            for (si, s) in g.steps.enumerated() where a.targets.contains(where: { $0.matches(s) }) {
                return (gi, si)
            }
        }
        return Self.achievementStep(in: guides, description: a.description)
    }

    /// Where an achievement's description points: a quoted quest or mission ("Complete 'The
    /// Doorman' and obtain the Razor Axe"), or a nation rank ("Achieve Rank 7 in Windurst") ->
    /// that nation's missions.
    static func achievementStep(in guides: [Guide], description d: String) -> (guide: Int, step: Int)? {
        // 'Name' in straight or curly quotes; the apostrophe inside "Silence of the Ram's" is
        // kept by requiring the closing quote to be followed by a non-letter.
        if let r = try? NSRegularExpression(pattern: #"['‘“"](.+?)['’”"](?![A-Za-z])"#) {
            for m in r.matches(in: d, range: NSRange(d.startIndex..., in: d)) {
                guard let range = Range(m.range(at: 1), in: d) else { continue }
                if let hit = questStep(in: guides, named: "Quest: " + d[range]) { return hit }
            }
        }
        // Nation rank -> that nation's missions; fame -> its quests (quests are what raise fame).
        for (pattern, kind) in [(#"(?i)rank \d+ in (San d'Oria|Bastok|Windurst)"#, "Missions"),
                                (#"(?i)fame level of \d+ in (San d'Oria|Bastok|Windurst|Jeuno)"#, "Quests")] {
            if let r = try? NSRegularExpression(pattern: pattern),
               let m = r.firstMatch(in: d, range: NSRange(d.startIndex..., in: d)),
               let range = Range(m.range(at: 1), in: d),
               let g = guides.firstIndex(where: { $0.name.caseInsensitiveCompare("\(d[range]) \(kind)") == .orderedSame }) {
                return (g, 0)
            }
        }
        return nil
    }
}

struct CompanionView: View {
    @StateObject var state: CompanionState
    @StateObject private var capture = ScreenGuideCapture()
    @StateObject var wiki: WikiState
    // --tab <n> (test hook) opens on another tab, 1 Gear, 2 Skills, 3 Achievements, 4 Server, for --snapshot.
    @State var tab = CommandLine.arguments.firstIndex(of: "--tab")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 0
    @State var expandedContent: Set<String> = ["Start Here"]
    @State var globalSearch = ""
    @State var showSearch = false
    @State var searchPage: GuideSearchTarget?
    private let layoutTest: Bool

    init(layoutTest: Bool = false, tab: Int? = nil, wiki: WikiState? = nil, foodFixture: String? = nil, gilFixture: Bool = false, searchFixture: String? = nil, monsterFixture: String? = nil, completedFixture: Bool = false, completedStepFixture: Bool = false, goalsFixture: Bool = false) {
        self.layoutTest = layoutTest
        let initialState = CompanionState(loadData: !layoutTest)
        if layoutTest && tab == 5 { initialState.characterOptions = ["Layout", "SecondCharacter"] }
        if layoutTest, let foodFixture {
            initialState.guides = [Guide(name: QuestCatalogue.displayName("Starting out"), desc: "Starter food for this character.", levels: "1-10",
                steps: [GuideStep(kind: "t", title: "Buy a few affordable food portions before fighting.",
                                  note: "Buy singles first and keep gil for spells and equipment.")])]
            initialState.progress.foodJob = foodFixture
            initialState.progress.homeNation = "San d'Oria"
        }
        if layoutTest && gilFixture {
            initialState.guides = [Guide(name: "Solo Gil - HorizonXI", desc: "Choose your starting location.", levels: "Early quests",
                steps: ["Windurst", "San d'Oria", "Bastok"].map { nation in
                    GuideStep(kind: "t", title: "Start in \(nation).", note: "Starting location: \(nation). Check requirements and costs before travelling.", tags: ["START": nation])
                })]
        }
        if layoutTest && goalsFixture {
            initialState.guides = [Guide(name: "Solo Guide - HorizonXI", desc: "Leveling, quests and notorious monsters in one route.", levels: "1-75 ALPHA",
                steps: [GuideStep(kind: "C", title: "Levels 26-30: Bull Dhalmel.", note: "Starting location: All starting cities. Pull one at a time; these monsters link.", tags: ["EXP": "Bull Dhalmel (20-24) — Buburimu Peninsula.", "GIL": "Carnivorous Crawler for Silk Thread, or Bull Dhalmel for Dhalmel Hide and Dhalmel Meat.", "LV": "30"])])]
        }
        if layoutTest && completedFixture {
            _ = initialState.finishGuideStep()
            if completedStepFixture { initialState.openGuide(0) }
            _expandedContent = State(initialValue: ["Start Here", "Completed"])
        }
        if layoutTest, let root = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"] {
            initialState.zones = WorldMap.load(root: URL(fileURLWithPath: root))
        }
        _state = StateObject(wrappedValue: initialState)
        _wiki = StateObject(wrappedValue: wiki ?? WikiState())
        if let tab { _tab = State(initialValue: tab) }
        if let searchFixture {
            _globalSearch = State(initialValue: searchFixture)
            _showSearch = State(initialValue: true)
        }
        if let monsterFixture { _searchPage = State(initialValue: .monster(monsterFixture)) }

    }
    static let addCharacterTag = "\u{1}add"

    static let width: CGFloat = 620
    static let height: CGFloat = 460

    var body: some View {
        VStack(spacing: 8) {
            header.zIndex(10)
            Group {
                if let page = searchPage {
                    searchDetail(page)
                } else {
                switch tab {
                case 1: gearPane
                case 2: skillsPane
                case 3: achievementsPane
                case 4: serverPane
                case 5: CharacterSettingsView(state: state)
                default: guidesPane
                }
                }
            }
                .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(minWidth: Self.width, idealWidth: Self.width, maxWidth: .infinity,
               minHeight: Self.height, idealHeight: Self.height, maxHeight: .infinity)
        .foregroundStyle(Theme.text)
        .background(Theme.backdrop)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            guard !layoutTest else { return }
            state.reloadProgress()
            if tab != 5 { state.applyLauncherWorld() }
        }
        .onAppear {
            guard !layoutTest else { return }
            wiki.load(roots: CompanionState.vanaguideRoots, world: state.world)
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
        .onChange(of: state.world) {
            searchPage = nil; showSearch = false
            if !layoutTest { wiki.load(roots: CompanionState.vanaguideRoots, world: $0) }
        }
        .onChange(of: tab) { _ in searchPage = nil; showSearch = false }
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

    // MARK: Header — tabs, character, search

    var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("ALPHA VanaGuide").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.gold)
                Text("Server-Safe").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                globalSearchBar
            }
            .zIndex(2)
            Picker("", selection: $tab) {
                Text("Guides").tag(0)
                Text("Gear").tag(1)
                Text("Skills").tag(2)
                Text("Server").tag(4)
                Text("Achievements").tag(3)
                Text("Settings").tag(5)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 6) {
                Picker("Server", selection: Binding(get: { state.world }, set: { state.selectWorld($0) })) {
                    if state.world.isEmpty { Text("Choose…").tag("") }
                    ForEach(state.worldOptions, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 165)
                Picker("Character", selection: Binding(get: { state.character }, set: {
                    if $0 == Self.addCharacterTag { tab = 5 } else { state.selectCharacter($0) }
                })) {
                    if state.character.isEmpty { Text("None yet").tag("") }
                    ForEach(state.characterOptions, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Manage Characters…").tag(Self.addCharacterTag)
                }
                .frame(width: 150)
                .disabled(state.world.isEmpty)
                Spacer()
                if !state.discoveryNote.isEmpty {
                    Text(state.discoveryNote).font(.caption).foregroundStyle(Theme.crystal).lineLimit(1)
                }
                if state.devMode {
                    Text("Developer Mode activated").font(.caption.bold()).foregroundStyle(Theme.alert)
                        .lineLimit(1).fixedSize()
                }
                let completedGuides = state.guides.filter { $0.available(on: state.world) && state.progress.completed($0) }.count
                Text("\(completedGuides) \(completedGuides == 1 ? "guide" : "guides") · \(state.progress.completedCount) quests completed")
                    .font(.caption).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            }
            .textFieldStyle(.roundedBorder).controlSize(.small)
        }
    }

    /// Developer Mode indicator.
    var hammer: some View {
        Image(systemName: state.devMode ? "hammer.fill" : "hammer")
            .foregroundStyle(state.devMode ? Theme.alert : Theme.text)
    }

    // MARK: Guides

    var guide: Guide? {
        state.guides.indices.contains(state.selected) && state.guides[state.selected].available(on: state.world) ? state.guides[state.selected] : nil
    }

    var guidesPane: some View {
        HStack(spacing: 8) {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.gold)
                        .padding(.leading, 4)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(QuestCatalogue.sectionOrder + ["Completed"], id: \.self) { section in
                                let rows = state.guides.indices.filter { state.guides[$0].available(on: state.world) && (section == "Completed" ? state.progress.completed(state.guides[$0]) : QuestCatalogue.section(of: state.guides[$0]) == section) }
                                if !rows.isEmpty {
                                    Button {
                                        if expandedContent.contains(section) { expandedContent.remove(section) }
                                        else { expandedContent.insert(section) }
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: expandedContent.contains(section) ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 10, weight: .bold)).frame(width: 12)
                                            Text(section).font(.system(size: 13, weight: .semibold))
                                            Spacer(minLength: 0)
                                        }
                                        .foregroundStyle(Theme.gold)
                                        .padding(.horizontal, 8).padding(.vertical, 9)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityValue(expandedContent.contains(section) ? "Expanded" : "Collapsed")
                                    .help("Expand or collapse \(section)")
                                    if expandedContent.contains(section) {
                                        ForEach(rows, id: \.self) { i in
                                            Button {
                                                state.openGuide(i)
                                            } label: {
                                                HStack(alignment: .top, spacing: 4) {
                                                    Text(state.guides[i].name).font(.callout)
                                                        .multilineTextAlignment(.leading)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                    if state.progress.completed(state.guides[i]) {
                                                        Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.gold)
                                                            .accessibilityLabel("Completed")
                                                    }
                                                }
                                                    .padding(.vertical, 7).padding(.leading, 16).padding(.trailing, 6)
                                                    .foregroundStyle(state.selected == i ? Theme.crystal : Theme.text)
                                                    .background(state.selected == i ? Theme.crystal.opacity(0.14) : Color.clear,
                                                                in: RoundedRectangle(cornerRadius: 5))
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityAddTraits(state.selected == i ? .isSelected : [])
                                            .id("\(section):\(i)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: state.selected) { index in
                        guard state.guides.indices.contains(index) else { return }
                        expandedContent.insert(QuestCatalogue.section(of: state.guides[index]))
                    }
                }
            }
            .frame(width: 190)

            Card {
                if state.guideDetailOpen { stepDetail }
                else { completedGuideOverview }
            }
        }
    }

    var completedGuideOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Guide completed", systemImage: "star.fill")
                    .font(.title2.bold()).foregroundStyle(Theme.gold)
                Spacer()
                if let g = guide, state.progress.completed(g) {
                    Button("Not Completed") { state.uncompleteGuide() }
                        .controlSize(.small)
                }
            }
            if let guide {
                Text(guide.name).font(.headline)
            }
            if !state.guideSaveError.isEmpty {
                Text(state.guideSaveError).font(.caption).foregroundStyle(Theme.ember)
            }
            Text("Choose another guide from Content, or review a completed guide below.")
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.guides.indices.filter { state.guides[$0].available(on: state.world) && state.progress.completed(state.guides[$0]) }, id: \.self) { index in
                        Button { state.openGuide(index) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "star.fill").foregroundStyle(Theme.gold)
                                Text(state.guides[index].name).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Text("Review").font(.caption).foregroundStyle(Theme.crystal)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.stroke.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    var foodProfile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Main job", selection: Binding(get: { state.progress.foodJob ?? "" },
                set: { state.setFoodProfile(job: $0) })) {
                Text("Choose job").tag("")
                ForEach(["WAR", "MNK", "WHM", "BLM", "RDM", "THF"], id: \.self) { Text($0).tag($0) }
            }
            Picker("Home nation", selection: Binding(get: { state.progress.homeNation ?? "" },
                set: { state.setFoodProfile(nation: $0) })) {
                Text("Choose nation").tag("")
                ForEach(["San d'Oria", "Bastok", "Windurst"], id: \.self) { Text($0).tag($0) }
            }
            Text(StarterFood.advice(job: state.progress.foodJob, nation: state.progress.homeNation))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    var stepDetail: some View {
        if let g = guide {
            VStack(alignment: .leading, spacing: 8) {
                Text(g.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.gold)
                    .lineLimit(2)
                if !state.guideSaveError.isEmpty {
                    Text(state.guideSaveError).font(.caption).foregroundStyle(Theme.ember)
                }
                let starts = g.steps.indices.filter { g.steps[$0].tags["START"] != nil }
                if !starts.isEmpty {
                    Picker(g.startingLocationLabel, selection: Binding<Int>(
                        get: { starts.first(where: { g.steps[$0].tags["START"] == state.progress.guideBookmarks?[g.progressKey]?.startingLocation }) ?? starts[0] },
                        set: { state.moveToStep($0) }
                    )) {
                        ForEach(starts, id: \.self) { index in
                            Text(g.steps[index].tags["START"] ?? "").tag(index)
                        }
                    }
                }
                if !g.desc.isEmpty {
                    Text(g.desc).font(.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if g.steps.indices.contains(state.stepIndex) {
                    let s = state.resolved(g.steps[state.stepIndex])
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            let route = g.activeStepIndices(startingLocation: state.progress.guideBookmarks?[g.progressKey]?.startingLocation)
                            SectionLabel(text: "Step \((route.firstIndex(of: state.stepIndex) ?? 0) + 1) of \(route.count)")
                            if StarterFood.isFoodStep(guide: g.name, title: s.title) {
                                foodProfile
                            }
                            stepCard(s)
                            stepStatus(s, in: g)
                            if state.devMode { devPanel(s) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(state.devMode ? 8 : 0)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(state.devMode ? Theme.alert.opacity(0.22) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(state.devMode ? Theme.alert : .clear, lineWidth: 1.5))
                    }
                }
                let route = g.activeStepIndices(startingLocation: state.progress.guideBookmarks?[g.progressKey]?.startingLocation)
                let isFinalCompleted = state.progress.completed(g) && route.first(where: { $0 > state.stepIndex }) == nil
                HStack {
                    Button("Back") { state.previousGuideStep() }
                    Button(isFinalCompleted ? "Not Completed" : "Done") {
                        if state.finishGuideStep() { expandedContent.insert("Completed") }
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
        if let job = s.tags["JOB"] {
            Label("Unlocks \(job)", systemImage: "person.badge.plus").font(.callout).foregroundStyle(Theme.gold)
        }
        if let lv = s.tags["LV"] {
            Label(s.goals.isEmpty ? "Recommended level \(lv)" : "Level goal: \(lv)", systemImage: "chart.bar").font(.caption).foregroundStyle(Theme.muted)
        }
        ForEach(Array(s.goals.enumerated()), id: \.offset) { _, goal in
            HStack(alignment: .top, spacing: 7) {
                Text("•").foregroundStyle(Theme.gold)
                (Text(goal.label + ": ").bold() + Text(goal.text))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
        if let n = s.note, let scripted = s.tags["WALK"] {
            // Walkthrough from the server's own quest script: numbered, after where to go.
            howToGetThere(s, npc: npc)
            SectionLabel(text: "What to do").padding(.top, 4)
            ForEach(Array(n.components(separatedBy: "\n").enumerated()), id: \.offset) { i, line in
                Text("\(i + 1). \(line)").font(.callout).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if scripted != "full" {
                Text(scripted == "stub" ? "This server has not scripted this one yet; it may not be completable."
                                        : "Only part of this one is scripted on the server; some steps may not work.")
                    .font(.caption).foregroundStyle(Theme.ember).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if let n = s.note {
                Text(n).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            howToGetThere(s, npc: npc)
        }
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
                Text("No current location available.").font(.caption).foregroundStyle(Theme.ember)
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
                Button("Suggest to Guide…") { state.suggestToGuide() }
                    .controlSize(.small).disabled(state.learned.givers.isEmpty)
                    .help("Opens GitHub with these givers as a suggested change to the guide.")
            }
            if !state.devNote.isEmpty { Text(state.devNote).font(.caption2).foregroundStyle(Theme.jade) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Theme.gold.opacity(0.5)))
        .padding(.top, 6)
    }

    @ViewBuilder
    func stepStatus(_ s: GuideStep, in g: Guide) -> some View {
        if let source = s.tags["SRC"], let url = URL(string: source), url.host == "horizonffxi.wiki" {
            Link("Horizon wiki", destination: url).font(.caption)
        }
        let route = g.activeStepIndices(startingLocation: state.progress.guideBookmarks?[g.progressKey]?.startingLocation)
        let isFinalCompleted = state.progress.completed(g) && route.first(where: { $0 > state.stepIndex }) == nil
        if let r = state.status(of: s) {
            Text(r.status == .completed ? "Completed · from your \(r.source)" : "Current · from your \(r.source)")
                .font(.caption).foregroundStyle(r.status == .completed ? Theme.jade : Theme.crystal)
        } else if isFinalCompleted {
            Text("Completed · click Not Completed below to mark incomplete.")
                .font(.caption).foregroundStyle(Theme.jade)
        } else if s.fixed && s.tags["LOG"] == nil {
            Text("Press Done once you have finished this in game.")
                .font(.caption).foregroundStyle(Theme.gold)
        }
        if g.name == LogSurvey.guideName {
            if s.tags["LOG"] != "none" && !capture.running {
                Text("Mark completed quests with Done as you follow a guide.")
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

    /// The whole achievement is a link (Daniel, 2026-10-28): to the quest or mission it names in
    /// Guides, else to an item it names on the Gear tab.
    @ViewBuilder
    func row(_ r: AchievementRow) -> some View {
        if let link = state.guideLink(for: r.info) {
            Button { state.openGuide(link.guide, at: link.step); tab = 0 } label: { linkedRow(r, to: "Open in Guides") }
                .buttonStyle(.plain).help("Open the guide for this achievement")
        } else if let item = achievementItem(r.info) {
            Button { wiki.openItem = item.id; wiki.category = nil; tab = 1 } label: { linkedRow(r, to: "Open \(item.name) in Gear") }
                .buttonStyle(.plain).help("Open how to get \(item.name)")
        } else {
            rowContent(r)
        }
    }

    func linkedRow(_ r: AchievementRow, to label: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            rowContent(r)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.crystal)
        }
        .contentShape(Rectangle())
        .accessibilityHint(label)
    }

    /// The longest gear name an achievement's description mentions ("obtain a Reverend Mail").
    func achievementItem(_ a: AchievementInfo) -> GearItem? {
        let text = " " + ScreenshotGuideMatcher.normalized(a.description) + " "
        return wiki.items.filter { $0.name.count >= 6 && text.contains(" " + ScreenshotGuideMatcher.normalized($0.name) + " ") }
            .max { $0.name.count < $1.name.count }
    }

    func rowContent(_ r: AchievementRow) -> some View {
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

enum Snapshot {
    static func write(to path: String) {
        let size = NSSize(width: CompanionView.width, height: CompanionView.height)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: CompanionView().preferredColorScheme(.dark).tint(Theme.crystal))
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
