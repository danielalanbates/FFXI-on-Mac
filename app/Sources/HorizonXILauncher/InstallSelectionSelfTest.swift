// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// `--selftest-install-selection`: which install the launcher uses, with the picker gone (b65).
///
/// - The rule on plain values (`InstallSelection.decide`): `install.last` on disk is kept;
///   `install.last` not on disk is kept too (nothing else is used, nothing is switched to); with
///   no `install.last` the one in use stays, else the scan's best is adopted (under
///   `install.location` first, then with the game, then the one Wine ran last); and no number of
///   rescans, in any order, with the drive coming and going, ever lands on another install.
/// - The same with what is on disk (`resolve`), on fixture wrappers in a temporary folder and a
///   throwaway defaults suite, never the real one: the scan is not even asked while there is an
///   `install.last`; an `install.last` on a drive that is not there gives the b60 line
///   "The '<drive>' drive isn't connected — reconnect it or press Setup."; an adopted install is
///   kept by the next rescan once remembered.
extension Headless {
    @MainActor static func runInstallSelectionSelfTest() -> Never {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { results.append((name, ok)) }
        typealias S = InstallSelection
        let fm = FileManager.default

        // MARK: The rule, on plain values
        let loc = URL(fileURLWithPath: "/Volumes/x10/Video Games/Mac/FFXI/FFXI on Mac")
        let ours = Install(wrapper: loc.appendingPathComponent("FFXI on Mac Wine.app"), prefixName: "prefix10")
        let siku = Install(wrapper: URL(fileURLWithPath: "/Volumes/x10/Video Games/Mac/FFXI/siku.app"), prefixName: "prefix10")
        let other = Install(wrapper: URL(fileURLWithPath: "/Applications/Other.app"), prefixName: "prefix")
        let old = Date(timeIntervalSince1970: 1_700_000_000), recent = Date(timeIntervalSince1970: 1_790_000_000)
        func c(_ i: Install, game: Bool = true, used: Date? = nil) -> S.Candidate { .init(install: i, hasGame: game, lastUsed: used) }

        check("install.last on disk -> kept, though another install ranks first",
              S.decide(last: ours, lastOnDisk: true, current: ours, found: [c(siku, used: recent), c(ours, game: false)], location: loc) == .last(ours))
        check("install.last on disk, the scan did not reach it -> kept",
              S.decide(last: ours, lastOnDisk: true, current: nil, found: [c(siku)], location: nil) == .last(ours))
        let gone = S.decide(last: ours, lastOnDisk: false, current: nil, found: [c(siku, used: recent), c(other)], location: loc)
        check("install.last not on disk (drive gone) -> kept, nothing in use, never switched to siku.app",
              gone == .unreachable(ours) && gone.install == nil)
        check("install.last not on disk while another is in memory -> still install.last, not the other",
              S.decide(last: ours, lastOnDisk: false, current: siku, found: [c(siku)], location: nil) == .unreachable(ours))
        check("no install.last, one in use this session -> that one, remembered",
              S.decide(last: nil, lastOnDisk: false, current: other, found: [c(siku, used: recent)], location: loc) == .adopted(other))
        check("no install.last: one under install.location first, even without the game or a recent run",
              S.decide(last: nil, lastOnDisk: false, current: nil,
                       found: [c(siku, used: recent), c(other, used: recent), c(ours, game: false)], location: loc) == .adopted(ours))
        check("no install.last, none under install.location: with the game, then the one Wine ran last",
              S.decide(last: nil, lastOnDisk: false, current: nil,
                       found: [c(other, game: false, used: recent), c(ours, used: old), c(siku, used: recent)],
                       location: URL(fileURLWithPath: "/Users/someone/Elsewhere")) == .adopted(siku))
        check("no install.last, nothing to tell them apart -> discovery's own order",
              S.decide(last: nil, lastOnDisk: false, current: nil, found: [c(other), c(siku)], location: nil) == .adopted(other))
        check("a folder beside install.location with a longer name is not under it",
              S.rank([c(siku), c(Install(wrapper: URL(fileURLWithPath: loc.path + " 2/FFXI on Mac Wine.app"), prefixName: "prefix10"))],
                     location: loc).first?.install == siku)
        check("nothing remembered, nothing found -> none (Setup)",
              S.decide(last: nil, lastOnDisk: false, current: nil, found: [], location: loc) == .none)

        // Many rescans: the scan's order shuffled, the drive coming and going, the window's own
        // `selected` fed back each time. Only install.last, or nothing while its drive is gone.
        var orders: [[S.Candidate]] = [[c(siku, used: recent), c(ours), c(other)], [c(other), c(siku)], [], [c(ours, game: false)]]
        var selected: Install? = ours
        var stray: [String] = []
        for round in 0..<40 {
            orders.append(orders.removeFirst())
            let onDisk = round % 3 != 1
            let d = S.decide(last: ours, lastOnDisk: onDisk, current: selected, found: orders[0], location: round % 2 == 0 ? loc : nil)
            selected = d.install
            if d != (onDisk ? .last(ours) : .unreachable(ours)) { stray.append("round \(round): \(d)") }
        }
        check("40 rescans with several installs found, the drive coming and going -> never another install"
              + (stray.isEmpty ? "" : " (\(stray.prefix(2).joined(separator: "; ")))"), stray.isEmpty)

        // MARK: With what is on disk
        let tmp = fm.temporaryDirectory.appendingPathComponent("ffxi-install-selection-\(UUID().uuidString)", isDirectory: true)
        let suite = "org.batesai.horizonxi-on-mac.selftest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { print("FAIL  no throwaway defaults suite"); exit(1) }
        func wrapper(_ rel: String, game: Bool, used: Date) -> Install {
            let i = Install(wrapper: tmp.appendingPathComponent(rel), prefixName: "prefix10")
            let wine = i.wine
            try? fm.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: wine.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            try? fm.createDirectory(at: i.driveC, withIntermediateDirectories: true)
            fm.createFile(atPath: i.systemReg.path, contents: Data("WINE REGISTRY Version 2\n".utf8))
            try? fm.setAttributes([.modificationDate: used], ofItemAtPath: i.systemReg.path)
            if game {
                try? fm.createDirectory(at: i.gameDir, withIntermediateDirectories: true)
                fm.createFile(atPath: i.gameDir.appendingPathComponent("Ashita-cli.exe").path, contents: Data())
            }
            return i
        }
        let place = tmp.appendingPathComponent("Chosen/FFXI on Mac")
        let fresh = wrapper("Chosen/FFXI on Mac/FFXI on Mac Wine.app", game: false, used: old)
        let sikuFixture = wrapper("Old/siku.app", game: true, used: recent)
        let facts = S.candidates([sikuFixture, fresh])
        func near(_ d: Date?, _ want: Date) -> Bool { d.map { abs($0.timeIntervalSince(want)) < 2 } ?? false }
        check("facts: the game and when Wine last wrote the registry are read from the prefix",
              facts.map(\.hasGame) == [true, false] && near(facts[0].lastUsed, recent) && near(facts[1].lastUsed, old))

        // By id: a URL read back from defaults gains a trailing slash once its folder exists.
        func tag(_ d: S.Decision) -> String {
            switch d {
            case .last(let i): return "last " + i.id
            case .unreachable(let i): return "unreachable " + i.id
            case .adopted(let i): return "adopted " + i.id
            case .none: return "none"
            }
        }
        var scanned = 0
        func scan() -> [Install] { scanned += 1; return [sikuFixture, fresh] }
        check("a fresh suite has no install.last", Install.lastChosen(defaults) == nil)
        let first = S.resolve(defaults: defaults, location: place, found: scan)
        check("no install.last: the fresh install under install.location is adopted over siku.app with the game",
              tag(first) == tag(.adopted(fresh)) && scanned == 1)
        first.install?.remember(defaults)
        scanned = 0
        check("remembered, then rescanned (siku.app found first again) -> the same install, the scan not asked",
              tag(S.resolve(current: fresh, defaults: defaults, location: place, found: scan)) == tag(.last(fresh)) && scanned == 0)

        let drive = "ffxi-selftest-gone-\(UUID().uuidString.prefix(8))"
        let away = Install(wrapper: URL(fileURLWithPath: "/Volumes/\(drive)/Video Games/Mac/FFXI/FFXI on Mac/FFXI on Mac Wine.app"),
                           prefixName: "prefix10")
        away.remember(defaults)
        let missing = S.resolve(current: nil, defaults: defaults, location: place, found: scan)
        check("install.last on a drive that is not there -> kept (unreachable), the scan not asked, siku.app not used",
              tag(missing) == tag(.unreachable(away)) && scanned == 0 && Install.lastChosen(defaults)?.id == away.id
                && Install.remembered(defaults) == nil)
        // What the window's main button then says: the b60 path (no install, remembered drive).
        var x = PrimaryInputs()
        x.hasInstall = missing.install != nil
        if let d = Preflight.unavailableDrive(for: away.wrapper.path) { x.rememberedDrive = d; x.driveStates[d] = .absent }
        let button = Primary.decide(x)
        check("-> Setup, \"\(button.reason ?? "")\"",
              x.rememberedDrive == drive && button.action == .setup(.wrapperDrive(drive)) && button.enabled
                && button.reason == "The '\(drive)' drive isn't connected — reconnect it or press Setup.")

        let deleted = tmp.appendingPathComponent("Deleted/FFXI on Mac Wine.app")
        Install(wrapper: deleted, prefixName: "prefix10").remember(defaults)
        check("install.last whose folder is gone (drive there) -> kept, not switched to a found one",
              tag(S.resolve(defaults: defaults, location: place, found: scan)) == tag(.unreachable(Install(wrapper: deleted, prefixName: "prefix10")))
                && scanned == 0)
        fresh.remember(defaults)
        check("install.last on disk again -> in use again", tag(S.resolve(defaults: defaults, location: place, found: scan)) == tag(.last(fresh)))

        for bad in ["", "no-hash", "#prefix10", "/Applications/x.app#", "a#b#c"] {
            defaults.set(bad, forKey: "install.last")
            if Install.lastChosen(defaults) != nil { check("install.last \"\(bad)\" is not an install", false) }
        }
        check("malformed install.last values are not installs", Install.lastChosen(defaults) == nil)

        var failed = 0
        for (name, ok) in results {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failed += 1 }
        }
        print("\(results.count - failed)/\(results.count) passed")
        defaults.removePersistentDomain(forName: suite)
        try? fm.removeItem(at: tmp)
        exit(failed == 0 ? 0 : 1)
    }
}
