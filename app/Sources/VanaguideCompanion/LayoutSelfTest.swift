// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org

import AppKit
import SwiftUI

/// A bounded, hidden layout check, independent of the installed app's single-instance guard.
/// No visible windows, screen capture, input, network, or character progress writes.
@MainActor
enum CompanionLayoutSelfTest {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var failures = 0
        let output = DevTrace.value("--layout-output").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output {
            do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            catch { print("FAIL: cannot create layout output: \(error)"); exit(1) }
        }
        let sizes = [NSSize(width: CompanionView.width, height: CompanionView.height),
                     NSSize(width: 1000, height: 720)]
        let gear = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"].flatMap {
            WikiData.gear(URL(fileURLWithPath: $0).appendingPathComponent("data/gear_guide.lua"))
        }
        let monsters = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"].map {
            MonsterEntry.load(roots: [URL(fileURLWithPath: $0)], world: "HorizonXI")
        } ?? []
        let scenarios: [(name: String, tab: Int, job: String?)] = [
            ("fruit-punches", 1, nil), ("tab-0", 0, nil), ("tab-1", 1, nil), ("artifact-war", 1, "WAR"),
            ("solo-goals", 0, nil), ("guide-completed", 0, nil), ("guide-completed-step", 0, nil), ("search-rabbit", 0, nil), ("monster-jack", 0, nil), ("gil-start", 0, nil), ("food-melee", 0, "WAR"), ("food-caster", 0, "BLM"),
            ("tab-2", 2, nil), ("tab-3", 3, nil), ("tab-4", 4, nil), ("settings", 5, nil)
        ]
        for scenario in scenarios {
            autoreleasepool {
                let wiki = WikiState()
                wiki.categories = gear?.categories ?? [GearCategory(id: "artifact", name: "Artifact Armor", desc: "", count: 2)]
                wiki.items = gear?.items ?? ["WAR", "BLM"].enumerated().map { index, job in
                    GearItem(id: index, name: "\(job) fixture armor", level: 60, slot: "body", jobs: job,
                             rare: true, ex: true, categories: ["artifact"], how: [])
                }
                wiki.monsters = monsters
                if let root = ProcessInfo.processInfo.environment["VANAGUIDE_ROOT"] {
                    wiki.nmDetails = NMDetails.load(roots: [URL(fileURLWithPath: root)], world: "HorizonXI")
                }
                if scenario.name == "fruit-punches" { wiki.openItem = 16443 }
                wiki.note = ""
                if let job = scenario.job { wiki.selectArtifactJob(job) }
                let view = NSHostingView(rootView: CompanionView(layoutTest: true, tab: scenario.tab, wiki: wiki,
                    foodFixture: scenario.name.hasPrefix("food-") ? scenario.job : nil, gilFixture: scenario.name == "gil-start",
                    searchFixture: scenario.name == "search-rabbit" ? "rabbit" : nil,
                    monsterFixture: scenario.name == "monster-jack" ? monsters.first(where: { $0.name == "Jaggedy-Eared Jack" && $0.zone == 100 })?.id : nil, completedFixture: scenario.name.hasPrefix("guide-completed"), completedStepFixture: scenario.name == "guide-completed-step", goalsFixture: scenario.name == "solo-goals")
                    .preferredColorScheme(.dark).tint(Theme.crystal))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: sizes[0]),
                                      styleMask: [.titled, .closable, .resizable],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = view
                for size in sizes {
                    window.setContentSize(size)
                    view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    view.layoutSubtreeIfNeeded()
                    let fits = abs(view.bounds.width - size.width) < 1
                        && abs(view.bounds.height - size.height) < 1
                        && view.fittingSize.width <= size.width + 1
                        && view.fittingSize.height <= size.height + 1
                    print("\(fits ? "ok" : "FAIL") \(scenario.name), \(Int(size.width))×\(Int(size.height)); "
                          + "content \(view.bounds.size), minimum \(view.fittingSize)")
                    if !fits { failures += 1 }
                    if let output {
                        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                            print("FAIL: cannot render \(scenario.name)"); failures += 1; continue
                        }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        do {
                            guard let data = rep.representation(using: .png, properties: [:]) else {
                                print("FAIL: cannot encode \(scenario.name)"); failures += 1; continue
                            }
                            try data.write(to: output.appendingPathComponent("\(scenario.name)-\(Int(size.width)).png"))
                        } catch { print("FAIL: cannot write \(scenario.name): \(error)"); failures += 1 }
                    }
                }
                // Shrinking after expansion catches a layout that keeps the enlarged minimum.
                window.setContentSize(sizes[0])
                view.layoutSubtreeIfNeeded()
                if abs(view.bounds.width - sizes[0].width) >= 1 || abs(view.bounds.height - sizes[0].height) >= 1 {
                    print("FAIL: \(scenario.name) cannot shrink after expanding"); failures += 1
                }
                window.close()
            }
        }
        print(failures == 0 ? "all layout checks passed" : "\(failures) layout checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
