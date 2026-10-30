// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation

struct GuideBookmark: Codable, Equatable {
    var step: Int
    var title: String
    var completed: Bool
    var startingLocation: String? = nil
}

extension Guide {
    func activeStepIndices(startingLocation: String?) -> [Int] {
        let location = startingLocation ?? steps.first(where: { $0.tags["START"] != nil })?.tags["START"]
        return steps.indices.filter { steps[$0].tags["HOME"] == nil || steps[$0].tags["HOME"] == location }
    }

    func progressKey(named name: String) -> String {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return key(server ?? "general") + ":" + key(name)
    }

    var progressKey: String { progressKey(named: progressID ?? name) }

}

extension CharacterProgress {
    mutating func migrateGuideAliases(_ guides: [Guide]) {
        for guide in guides {
            guard let alias = guide.legacyProgressID else { continue }
            let oldKey = guide.progressKey(named: alias)
            if guideBookmarks?[guide.progressKey] == nil, let old = guideBookmarks?[oldKey] {
                let location = old.startingLocation ?? homeNation ?? guide.steps.first(where: { $0.tags["START"] != nil })?.tags["START"]
                let route = guide.activeStepIndices(startingLocation: location)
                let band = old.title.range(of: #"Levels \d+-\d+:"#, options: .regularExpression).map { String(old.title[$0]) }
                let index = band.flatMap { prefix in route.first { guide.steps[$0].title.hasPrefix(prefix) } }
                    ?? (old.completed ? route.last : route.first) ?? 0
                // Finishing only the old EXP route does not complete the new quests and NM detours.
                var bookmarks = guideBookmarks ?? [:]
                bookmarks[guide.progressKey] = GuideBookmark(step: index, title: guide.steps.indices.contains(index) ? guide.steps[index].title : "",
                    completed: false, startingLocation: location)
                guideBookmarks = bookmarks
            }
            if lastGuide == oldKey { lastGuide = guide.progressKey }
        }
    }

    var completedGuideCount: Int { guideBookmarks?.values.filter(\.completed).count ?? 0 }

    func completed(_ guide: Guide) -> Bool { guideBookmarks?[guide.progressKey]?.completed ?? false }

    func resumeStep(in guide: Guide) -> Int {
        guard !guide.steps.isEmpty, let bookmark = guideBookmarks?[guide.progressKey] else { return 0 }
        let index = min(max(bookmark.step, 0), guide.steps.count - 1)
        if guide.steps[index].title == bookmark.title { return index }
        // Inserted steps should not shift a saved player onto a different instruction.
        return guide.steps.indices.filter { guide.steps[$0].title == bookmark.title }
            .min(by: { abs($0 - index) < abs($1 - index) }) ?? index
    }

    mutating func remember(_ guide: Guide, step: Int, completed: Bool? = nil) {
        guard !guide.steps.isEmpty else { return }
        let index = min(max(step, 0), guide.steps.count - 1)
        var bookmarks = guideBookmarks ?? [:]
        let previous = bookmarks[guide.progressKey]
        bookmarks[guide.progressKey] = GuideBookmark(step: index, title: guide.steps[index].title,
            completed: completed ?? previous?.completed ?? false,
            startingLocation: guide.steps[index].tags["HOME"] ?? guide.steps[index].tags["START"] ?? previous?.startingLocation)
        guideBookmarks = bookmarks
        lastGuide = guide.progressKey
        updated = Date()
    }
}

extension CompanionState {
    /// Select a route without resetting its cursor. Search step hits may request an exact step.
    func openGuide(_ index: Int, at step: Int? = nil, savingPrevious: Bool = true) {
        guard guides.indices.contains(index), guides[index].available(on: world) else { return }
        if savingPrevious { saveGuidePosition() }
        selected = index
        stepIndex = step.map { min(max($0, 0), max(guides[index].steps.count - 1, 0)) }
            ?? progress.resumeStep(in: guides[index])
        saveGuidePosition()
    }

    func openInitialGuide() {
        progress.migrateGuideAliases(guides)
        let index = guides.indices.first { guides[$0].progressKey == progress.lastGuide && guides[$0].available(on: world) }
            ?? startGuide
        openGuide(index, savingPrevious: false)
    }

    func moveToStep(_ index: Int) {
        guard guides.indices.contains(selected), !guides[selected].steps.isEmpty else { return }
        stepIndex = min(max(index, 0), guides[selected].steps.count - 1)
        saveGuidePosition()
    }

    @discardableResult
    func saveGuidePosition() -> Bool {
        guard guides.indices.contains(selected), guides[selected].available(on: world) else { return true }
        progress.remember(guides[selected], step: stepIndex)
        return saveGuideProgress()
    }

    @discardableResult
    func saveGuideProgress() -> Bool {
        // Hidden layout/logic fixtures must never touch a real character's file.
        guard storesGuideProgress else { return true }
        guard guideProgressWriter(progress) else {
            guideSaveError = "Progress could not be saved. Try again before closing the guide."
            return false
        }
        guideSaveError = ""
        return true
    }

    func previousGuideStep() {
        guard guides.indices.contains(selected) else { return }
        let guide = guides[selected]
        if let index = guide.activeStepIndices(startingLocation: progress.guideBookmarks?[guide.progressKey]?.startingLocation)
            .last(where: { $0 < stepIndex }) { moveToStep(index) }
    }

    /// True only after the last Done was saved successfully, so the view can close its window.
    @discardableResult
    func finishGuideStep() -> Bool {
        guard guides.indices.contains(selected), guides[selected].steps.indices.contains(stepIndex) else { return false }
        let guide = guides[selected]
        let step = guide.steps[stepIndex]
        let previous = progress, oldIndex = stepIndex
        if let key = Self.key(for: step) {
            let status: LogStatus = (step.kind == "A" || step.tags["QA"] != nil || step.tags["MA"] != nil) ? .current : .completed
            _ = progress.record(key, status, source: "done")
        }
        let route = guide.activeStepIndices(startingLocation: progress.guideBookmarks?[guide.progressKey]?.startingLocation)
        let next = route.first(where: { $0 > stepIndex })
        let finished = next == nil
        if let next { stepIndex = next }
        progress.remember(guide, step: stepIndex, completed: finished ? true : nil)
        guard saveGuideProgress() else {
            progress = previous; stepIndex = oldIndex
            return false
        }
        return finished
    }
}
