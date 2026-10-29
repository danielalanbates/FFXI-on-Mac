// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation

extension CompanionSelfTest {
    @MainActor static func artifactJobChecks() -> [(String, Bool)] {
        let wiki = WikiState()
        func piece(_ id: Int, _ name: String, _ job: String, _ category: String = "artifact") -> GearItem {
            GearItem(id: id, name: name, level: 60, slot: "body", jobs: job,
                     rare: true, ex: true, categories: [category], how: [])
        }
        wiki.items = [piece(1, "Warrior fixture", "WAR"), piece(2, "Mage fixture", "BLM"),
                      piece(3, "Second warrior", "WAR"), piece(4, "Beastmaster fixture", "BST"),
                      piece(5, "Other category", "WAR", "quest"), piece(6, "Shared quest reward", "All jobs", "quest")]
        var checks: [(String, Bool)] = []
        checks.append(("artifact job menu groups only available artifact jobs alphabetically",
                       wiki.artifactJobs.map(\.id) == ["BST", "BLM", "WAR"]))
        checks.append(("artifact job menu uses full names and counts",
                       wiki.artifactJobs.last == ArtifactJob(id: "WAR", name: "Warrior", count: 2)))
        wiki.job = "BLM"; wiki.search = "stale search"; wiki.openItem = 5
        wiki.selectArtifactJob("WAR")
        checks.append(("choosing an artifact job opens only its pieces, independently of other gear filters",
                       wiki.shown.map(\.id) == [1, 3] && wiki.search.isEmpty && wiki.openItem == nil))
        wiki.search = "second"
        checks.append(("artifact search remains within the chosen job", wiki.shown.map(\.id) == [3]))
        wiki.selectArtifactJob("NOT_A_JOB")
        checks.append(("unavailable artifact jobs cannot be selected", wiki.artifactJob == "WAR"))
        wiki.selectGearCategory("artifact")
        checks.append(("returning to Artifact Armor opens the job menu", wiki.artifactJob == nil && wiki.openItem == nil))
        wiki.search = ""; wiki.selectGearCategory("quest")
        checks.append(("other categories retain their normal job filter and all-jobs gear",
                       wiki.shown.map(\.id) == [6]))
        wiki.job = "WAR"
        checks.append(("normal gear job filtering remains available", wiki.shown.map(\.id) == [5, 6]))

        if let root = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"],
           let data = WikiData.gear(URL(fileURLWithPath: root).appendingPathComponent("data/gear_guide.lua")) {
            wiki.categories = data.categories; wiki.items = data.items
            wiki.selectGearCategory("artifact")
            let artifactCount = data.items.filter { $0.categories.contains("artifact") }.count
            checks.append(("real artifact gear is reachable through job menus",
                           artifactCount > 0 && wiki.artifactJobs.reduce(0, { $0 + $1.count }) >= artifactCount))
            let expected = Set(data.items.filter { $0.categories.contains("artifact") }.map(\.id))
            var found = Set<Int>()
            for job in wiki.artifactJobs {
                wiki.selectArtifactJob(job.id)
                found.formUnion(wiki.shown.map(\.id))
            }
            checks.append(("job menus cover every real artifact piece without leaking other categories", found == expected))
        }
        return checks
    }
}
