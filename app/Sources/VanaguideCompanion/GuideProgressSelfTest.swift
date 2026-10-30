// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import Foundation

extension CompanionSelfTest {
    @MainActor static func guideProgressChecks() -> [(String, Bool)] {
        let a = Guide(name: "Starting Out", desc: "", levels: "", steps: [
            GuideStep(kind: "t", title: "One"), GuideStep(kind: "t", title: "Two"),
            GuideStep(kind: "C", title: "Three", tags: ["Q": "bastok,10"])])
        let b = Guide(name: "Another Guide", desc: "", levels: "", steps: [GuideStep(kind: "t", title: "Other")])
        let state = CompanionState(loadData: false)
        state.guides = [a, b]
        state.progress = CharacterProgress(character: "Layout", world: "Local fixture")
        state.openGuide(0)
        var checks: [(String, Bool)] = []
        checks.append(("Done on an intermediate step leaves the window open", !state.finishGuideStep() && state.stepIndex == 1))
        state.openGuide(1)
        state.openGuide(0)
        checks.append(("switching guides restores the exact unfinished step", state.stepIndex == 1))
        state.moveToStep(2)
        checks.append(("last Done requests window closure only after completion", state.finishGuideStep()))
        checks.append(("guide completion records one star and the quest result", state.progress.completed(a) && state.progress.completedGuideCount == 1 && state.progress.entries["Q:bastok,10"]?.status == .completed))
        _ = state.finishGuideStep()
        checks.append(("repeated final Done cannot duplicate the completed guide", state.progress.completedGuideCount == 1))
        state.openGuide(1)
        state.openGuide(0)
        checks.append(("completed routes reopen at the saved last step", state.stepIndex == 2 && state.progress.completed(a)))
        state.moveToStep(0)
        checks.append(("reviewing earlier steps keeps the completion star", state.progress.completed(a)))
        var shifted = a
        shifted.steps.insert(GuideStep(kind: "t", title: "New setup"), at: 0)
        checks.append(("new content before a saved step preserves the instruction", state.progress.resumeStep(in: shifted) == 1))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        if let data = try? encoder.encode(state.progress), let restored = try? decoder.decode(CharacterProgress.self, from: data) {
            checks.append(("saved bookmarks and stars survive JSON round-trip", restored == state.progress && restored.completed(a) && restored.resumeStep(in: a) == 0))
        } else { checks.append(("saved bookmarks and stars survive JSON round-trip", false)) }
        let legacy = Data(#"{"character":"Old","world":"Local fixture","entries":{},"updated":0}"#.utf8)
        let old = try? decoder.decode(CharacterProgress.self, from: legacy)
        checks.append(("legacy character files load without bookmark fields", old != nil && old?.guideBookmarks == nil && old?.lastGuide == nil))
        let separate = CharacterProgress(character: "Other", world: "Local fixture")
        checks.append(("another character does not inherit route progress", separate.resumeStep(in: a) == 0 && !separate.completed(a)))
        state.progress.guideBookmarks?[a.progressKey]?.step = Int.max
        state.progress.guideBookmarks?[a.progressKey]?.title = "Removed instruction"
        checks.append(("obsolete or invalid saved indices are clamped", state.progress.resumeStep(in: a) == a.steps.count - 1))
        checks.append(("display capitalization does not reset a bookmark", a.progressKey == Guide(name: "Starting out", desc: "", levels: "", steps: []).progressKey))
        state.progress.guideBookmarks = nil
        state.progress.lastGuide = nil
        state.openGuide(0, at: 1)
        state.openGuide(1)
        state.openInitialGuide()
        checks.append(("reopening a character restores its last selected route", state.selected == 1))
        checks.append(("hidden progress fixtures never enable disk writes", !state.storesGuideProgress))
        let branched = Guide(name: "Branched", desc: "", levels: "", steps: [
            GuideStep(kind: "t", title: "Windurst first", tags: ["HOME": "Windurst", "START": "Windurst"]),
            GuideStep(kind: "t", title: "Bastok first", tags: ["HOME": "Bastok", "START": "Bastok"]),
            GuideStep(kind: "t", title: "Shared camp")])
        state.guides = [branched]
        state.openGuide(0, at: 0, savingPrevious: false)
        checks.append(("city route count excludes the other starting branch", branched.activeStepIndices(startingLocation: "Windurst") == [0, 2]))
        checks.append(("finishing a city branch joins the shared camp", !state.finishGuideStep() && state.stepIndex == 2))
        state.previousGuideStep()
        checks.append(("Back from a shared camp returns to the chosen city", state.stepIndex == 0))
        state.openGuide(0, at: 1)
        _ = state.finishGuideStep()
        checks.append(("changing starting city remains selected in shared camps", state.stepIndex == 2 && state.progress.guideBookmarks?[branched.progressKey]?.startingLocation == "Bastok"))
        let beforeFailure = state.progress
        state.storesGuideProgress = true
        state.guideProgressWriter = { _ in false }
        checks.append(("failed save keeps the last step open and does not award completion", !state.finishGuideStep() && state.progress == beforeFailure && state.stepIndex == 2 && !state.guideSaveError.isEmpty))
        state.storesGuideProgress = false
        return checks
    }
}
