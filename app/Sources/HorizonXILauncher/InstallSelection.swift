// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// Which install the launcher uses: at launch, on every rescan (↻, a drive mounting, Setup's
/// chain, Install dependencies…, Move…'s last step) and in `--check` / `--next-action` / `--fix`.
///
/// Daniel, 2026-10-15: "why under remember me is there 2 options? that box doesn't need to
/// exist". b65 took the install picker out of the window, so nothing may switch installs where
/// the user cannot see it. The rule:
///
/// - The install in use is `install.last`: the one Setup made or adopted, Move… moved, or the
///   user chose with the folder button. A rescan never replaces it, whatever else it finds
///   (siku.app, a second prefix, an older wrapper).
/// - `install.last` not on disk (its drive unplugged or ghost-mounted, its folder gone): it stays
///   `install.last`, and nothing else is used meanwhile. The main button then names the drive
///   ("The 'x10' drive isn't connected — reconnect it or press Setup.", `Primary.rememberedDrive`)
///   or offers Setup, and reconnecting the drive brings it back as it was. Up to b64 the rescan
///   switched to the first install it found and wrote that into `install.last`.
/// - No `install.last` at all (a first run, or an install from before b60): the one in use this
///   session, else the best of what the scan found -- one under `install.location` first, then
///   one with the game, then the one Wine ran most recently, then discovery's own order -- and it
///   becomes `install.last`.
///
/// The world never changes the install: each world plays this wrapper and prefix pointed at its
/// own game folder (`Install.forServer`, from the world's `dataPath`).
enum InstallSelection {
    /// What the scan knows about one install it found, read off the main actor.
    struct Candidate: Equatable {
        var install: Install
        var hasGame: Bool
        /// When Wine last wrote this prefix's registry (system.reg, user.reg): every Play does.
        var lastUsed: Date?
    }

    enum Decision: Equatable {
        /// `install.last`, on disk: the install in use.
        case last(Install)
        /// `install.last`, not on disk right now. Nothing is used and nothing else is picked.
        case unreachable(Install)
        /// No `install.last`: this one is used, and remembered as `install.last` from now on.
        case adopted(Install)
        /// No `install.last` and nothing found.
        case none

        /// What the window sets `selected` to.
        var install: Install? {
            switch self {
            case .last(let i), .adopted(let i): return i
            case .unreachable, .none: return nil
            }
        }
    }

    /// The rule above, on plain values. `current` is the install the window is using, if any.
    static func decide(last: Install?, lastOnDisk: Bool, current: Install?,
                       found: [Candidate], location: URL?) -> Decision {
        if let l = last { return lastOnDisk ? .last(l) : .unreachable(l) }
        if let c = current { return .adopted(c) }
        return rank(found, location: location).first.map { .adopted($0.install) } ?? .none
    }

    /// `found` best first: under `location`, then with the game, then most recently used, then
    /// in the order given (discovery's: preconditions met, internal disk before external).
    static func rank(_ found: [Candidate], location: URL?) -> [Candidate] {
        func underLocation(_ c: Candidate) -> Bool {
            guard let l = location else { return false }
            let root = l.standardizedFileURL.path
            let p = c.install.wrapper.standardizedFileURL.path
            return p == root || p.hasPrefix(root + "/")
        }
        return found.enumerated().sorted { a, b in
            let la = underLocation(a.element), lb = underLocation(b.element)
            if la != lb { return la }
            if a.element.hasGame != b.element.hasGame { return a.element.hasGame }
            let ua = a.element.lastUsed ?? .distantPast, ub = b.element.lastUsed ?? .distantPast
            if ua != ub { return ua > ub }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Facts (disk)

    static func candidates(_ found: [Install]) -> [Candidate] {
        found.map { Candidate(install: $0, hasGame: $0.hasGame, lastUsed: lastUsed($0)) }
    }

    /// The newer of the prefix's two registry files' modification dates.
    static func lastUsed(_ i: Install) -> Date? {
        let fm = FileManager.default
        return ["system.reg", "user.reg"].compactMap {
            (try? fm.attributesOfItem(atPath: i.prefix.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }.max()
    }

    /// The rule with what is on disk. `found` is called only when there is no `install.last`
    /// and nothing in use: it is the scan of /Volumes. Reads only; remembering an adopted
    /// install is the caller's (the window does, the headless commands never write).
    static func resolve(current: Install? = nil, defaults: UserDefaults = AppDefaults.store,
                        location: URL? = InstallLocation.remembered,
                        found: () -> [Install]) -> Decision {
        let last = Install.lastChosen(defaults)
        let onDisk = last.map { FileManager.default.fileExists(atPath: $0.prefix.path) } ?? false
        let scanned = last == nil && current == nil ? candidates(found()) : []
        return decide(last: last, lastOnDisk: onDisk, current: current, found: scanned, location: location)
    }

    /// The install the window would use now, for a process with no window: never one it would
    /// not use. Nothing is remembered.
    static func inUse() -> Install? {
        resolve(found: { Install.dedupe(Install.discover()) }).install
    }
}
