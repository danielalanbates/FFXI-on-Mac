// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import Foundation

extension CompanionSelfTest {
    static func characterSettingsChecks(in root: URL) -> [(String, Bool)] {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks: [(String, Bool)] = []
        do {
            var original = try CharacterProfiles.add("  First  ", world: "Fixture", in: directory)
            checks.append(("settings add trims names and saves a selectable profile", original.character == "First" && ProgressStore.saved(in: directory).count == 1))
            let guide = Guide(name: "Test Guide", desc: "", levels: "", steps: [GuideStep(kind: "t", title: "Last step")])
            original.foodJob = "BLM"; original.homeNation = "Windurst"
            _ = original.record("Q:windurst,34", .completed, source: "done")
            original.remember(guide, step: 0, completed: true)
            guard ProgressStore.save(original, in: directory) else { throw CharacterEditError(message: "fixture save failed") }
            // Match the persisted ISO-8601 timestamp precision before comparing all records.
            original = ProgressStore.load(character: "First", world: "Fixture", in: directory)
            let renamed = try CharacterProfiles.rename("First", world: "Fixture", to: "Renamed", in: directory)
            let loaded = ProgressStore.load(character: "Renamed", world: "Fixture", in: directory)
            checks.append(("rename preserves quest records, bookmarks, stars and food settings", loaded.character == "Renamed" && loaded.entries == original.entries && loaded.guideBookmarks == original.guideBookmarks && loaded.lastGuide == original.lastGuide && loaded.foodJob == "BLM" && loaded.homeNation == "Windurst"))
            checks.append(("rename removes the old list entry", ProgressStore.saved(in: directory).map(\.character) == ["Renamed"]))
            let caseOnly = try CharacterProfiles.rename("Renamed", world: "Fixture", to: "renamed", in: directory)
            checks.append(("case-only rename keeps one intact profile", caseOnly.character == "renamed" && ProgressStore.saved(in: directory).count == 1 && ProgressStore.load(character: "renamed", world: "Fixture", in: directory).completed(guide)))
            _ = try CharacterProfiles.add("Other", world: "Fixture", in: directory)
            do {
                _ = try CharacterProfiles.rename("renamed", world: "Fixture", to: "OTHER", in: directory)
                checks.append(("rename refuses an existing character without overwriting it", false))
            } catch { checks.append(("rename refuses an existing character without overwriting it", ProgressStore.saved(in: directory).count == 2 && ProgressStore.load(character: "renamed", world: "Fixture", in: directory).completed(guide))) }
            do {
                _ = try CharacterProfiles.add("RENAMED", world: "Fixture", in: directory)
                checks.append(("add rejects a duplicate name ignoring case", false))
            } catch { checks.append(("add rejects a duplicate name ignoring case", true)) }
            _ = try CharacterProfiles.add("renamed", world: "Another Server", in: directory)
            try CharacterProfiles.remove("renamed", world: "Fixture", in: directory)
            checks.append(("remove affects only the chosen server's list", ProgressStore.saved(in: directory).filter { $0.world == "Fixture" }.map(\.character) == ["Other"] && ProgressStore.saved(in: directory).contains { $0.world == "Another Server" && $0.character == "renamed" }))
            checks.append(("normal profile loading does not silently restore removed progress", !ProgressStore.load(character: "renamed", world: "Fixture", in: directory).completed(guide)))
            let restored = try CharacterProfiles.add("renamed", world: "Fixture", in: directory)
            checks.append(("adding a removed name restores progress and completion", restored.guideBookmarks == renamed.guideBookmarks && restored.entries == original.entries && restored.foodJob == "BLM" && restored.completed(guide)))
            var latest = restored
            latest.homeNation = "Bastok"
            guard ProgressStore.save(latest, in: directory) else { throw CharacterEditError(message: "fixture save failed") }
            try CharacterProfiles.remove("renamed", world: "Fixture", in: directory)
            _ = try CharacterProfiles.add("renamed", world: "Fixture", in: directory)
            checks.append(("repeated remove and restore preserves the latest profile", ProgressStore.load(character: "renamed", world: "Fixture", in: directory).homeNation == "Bastok"))
            for name in ["", "../escape", "a/b", "a\\b", "a:b", "x\ny"] {
                do { _ = try CharacterProfiles.add(name, world: "Fixture", in: directory); checks.append(("unsafe name is rejected", false)) }
                catch { checks.append(("unsafe name is rejected", true)) }
            }
            do { _ = try CharacterProfiles.add("New", world: "", in: directory); checks.append(("a server is required", false)) }
            catch { checks.append(("a server is required", true)) }
            let broken = directory.appendingPathComponent(ProgressStore.fileName(character: "Broken", world: "Fixture"))
            let raw = Data("unreadable original".utf8)
            try raw.write(to: broken)
            do { _ = try CharacterProfiles.add("Broken", world: "Fixture", in: directory); checks.append(("add does not overwrite an unreadable existing profile", false)) }
            catch { checks.append(("add does not overwrite an unreadable existing profile", (try? Data(contentsOf: broken)) == raw)) }
        } catch { checks.append(("profile-edit fixture completed: \(error.localizedDescription)", false)) }
        return checks
    }
}
