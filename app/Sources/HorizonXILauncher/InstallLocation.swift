// Copyright (c) 2026 Bates LLC. All rights reserved.

import AppKit
import Foundation

/// Where FFXI on Mac keeps everything: one folder, "FFXI on Mac", inside a folder the user
/// chooses. Daniel, 2026-10-15: "it shouldn't be on the games drive. the user should have the
/// ability to choose where it goes. when i clicked set up ffxi on mac, it didn't let me choose
/// where the windows drive would be located. i want to choose" -- the old setup had built
/// `~/Applications/FFXI on Mac Wine.app` without asking, and the game's files were linked onto
/// a third drive that later went missing.
///
///     <chosen>/FFXI on Mac/
///         FFXI on Mac Wine.app/                    Wine and its Windows drive (prefix10)
///             Contents/SharedSupport/prefix10/drive_c/HorizonXI/   HorizonXI, SquareEnix included
///         wine-coop/wine/bin/wine                  the game's Wine (scripts/game-wine.sh)
///         Games/<world>/                           any other world's game files
///
/// Setup asks for the folder before it writes anything (`LocationPanel`), and refuses one it
/// cannot work in: not Mac-formatted, on the network, read-only, synced to a cloud, or short of
/// space. The choice is remembered (`remembered`), and discovery looks there first.
enum InstallLocation {
    static let folderName = "FFXI on Mac"
    static let wrapperName = "FFXI on Mac Wine.app"
    static let worldsFolder = "Games"
    static let gameWineFolder = "wine-coop"

    // MARK: - Layout

    /// The "FFXI on Mac" folder for what the user chose. Choosing that folder itself (a second
    /// Setup, or a Move back) uses it as it is rather than nesting another inside it.
    static func folder(for chosen: URL) -> URL {
        let c = chosen.standardizedFileURL
        return c.lastPathComponent == folderName ? c : c.appendingPathComponent(folderName, isDirectory: true)
    }

    static func wrapper(in folder: URL) -> URL { folder.appendingPathComponent(wrapperName, isDirectory: true) }

    /// The game's Wine Setup installs here (scripts/game-wine.sh), as `X87Sidecar.patchedWine` finds it.
    static func gameWine(in folder: URL) -> URL {
        folder.appendingPathComponent(gameWineFolder, isDirectory: true).appendingPathComponent("wine/bin/wine")
    }

    /// A world other than HorizonXI keeps its own client here (HorizonXI's is inside the
    /// wrapper's Windows drive, where its installer and the registry expect it).
    static func worldData(_ world: String, in folder: URL) -> URL {
        folder.appendingPathComponent(worldsFolder, isDirectory: true).appendingPathComponent(world, isDirectory: true)
    }

    /// The install Setup builds in `folder`.
    static func install(in folder: URL) -> Install { Install(wrapper: wrapper(in: folder), prefixName: Bootstrap.prefixName) }

    // MARK: - Remembered

    /// Swapped by the self-test, so it never changes the real choice.
    static var defaults: UserDefaults = AppDefaults.store
    private static let key = "install.location"

    /// The "FFXI on Mac" folder chosen last, whether or not its drive is there right now.
    static var remembered: URL? {
        guard let p = defaults.string(forKey: key), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static func remember(_ folder: URL) {
        let now = folder.standardizedFileURL.path
        if let was = defaults.string(forKey: key), !was.isEmpty, was != now {
            let list = [was] + (defaults.stringArray(forKey: earlierKey) ?? []).filter { $0 != was && $0 != now }
            defaults.set(Array(list.prefix(3)), forKey: earlierKey)
        }
        defaults.set(now, forKey: key)
    }

    private static let earlierKey = "install.location.earlier"

    /// The folders chosen before the last one, newest first (three at most). The game's Wine Setup
    /// put in one of them is still found (X87Sidecar.patchedWineCandidates), so choosing a new
    /// place, or using an older install, never downloads it a second time.
    static var earlier: [URL] {
        (defaults.stringArray(forKey: earlierKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Space

    /// What a fresh HorizonXI install takes at its peak, measured (docs/BETA-60.md): Wine and its
    /// Windows drive about 1.4 GB; HorizonXI's base zip 9,426,920,806 bytes (manifest 2.0.2),
    /// unpacked about 15.5 GB beside it until update-client.sh deletes the zip. The game's Wine:
    /// its 203,696,924-byte tarball and the 1.13 GB it unpacks to (game-wine.sh).
    enum Need {
        static let wine: Int64 = 1_400_000_000
        static let gameWine: Int64 = 203_696_924 + 1_130_000_000
        static let gameZip: Int64 = 9_426_920_806
        static let gameUnpacked: Int64 = 15_500_000_000
        static let fresh: Int64 = wine + gameWine + gameZip + gameUnpacked
        /// Roughly what an update takes, zip and unzip, for a client found a version or more behind.
        static let update: Int64 = 1_000_000_000
    }

    /// What stays free on the Mac's own disk, for macOS (and swap on an 8 GB Mac).
    static let bootFloor: Int64 = 8_000_000_000

    // MARK: - Can it go here?

    /// What decides whether a folder can hold the install. Read by `facts(for:)`; injected by the
    /// self-test.
    struct Facts: Equatable {
        var fsType = "apfs"
        var isLocal = true
        var isReadOnly = false
        var isWritable = true
        var freeBytes: Int64 = 0
        var isBootVolume = false
        var isCloud = false
        var insideApp = false
        /// The `/Volumes/<name>` on the way there is not (or another drive answers for it).
        var missingDrive: String? = nil
    }

    enum Verdict: Equatable {
        case ok(free: Int64, need: Int64)
        case refused(String)

        var line: String {
            switch self {
            case .ok(let free, let need): return InstallLocation.spaceLine(free: free, need: need)
            case .refused(let why): return why
            }
        }
        var isOK: Bool { if case .ok = self { return true } else { return false } }
    }

    static let networkTypes: Set<String> = ["smbfs", "afpfs", "nfs", "webdav", "ftp", "cifs", "cd9660"]

    /// One plain line for each refusal, the first that applies.
    static func verdict(_ f: Facts, need: Int64) -> Verdict {
        if let d = f.missingDrive { return .refused("The '\(d)' drive isn't connected. Choose another place.") }
        if f.isCloud { return .refused("This folder syncs to iCloud or another cloud. Choose one that doesn't.") }
        if f.insideApp { return .refused("Choose a folder outside an app.") }
        let fs = f.fsType.lowercased()
        if !f.isLocal || networkTypes.contains(fs) {
            return .refused("This is a network drive. Choose a drive connected to this Mac.")
        }
        if fs != "apfs" && fs != "hfs" {
            return .refused("This drive is \(formatName(fs)). Choose one formatted APFS or Mac OS Extended.")
        }
        if f.isReadOnly { return .refused("This drive is read-only. Choose another.") }
        if !f.isWritable { return .refused("This folder can't be written to. Choose another.") }
        // Nothing left to write (everything Setup needs was found here): no space to keep.
        if need <= 0 { return .ok(free: f.freeBytes, need: 0) }
        let total = need + (f.isBootVolume ? bootFloor : 0)
        if f.freeBytes < total {
            return .refused("Not enough space here: \(gb(f.freeBytes)) free, about \(gbUp(total)) needed.")
        }
        return .ok(free: f.freeBytes, need: total)
    }

    static func formatName(_ fs: String) -> String {
        switch fs {
        case "exfat": return "exFAT"
        case "msdos": return "FAT (MS-DOS)"
        case "ntfs", "ufsd_ntfs", "tuxera_ntfs", "fusefs_ntfs": return "NTFS"
        default: return fs.isEmpty ? "in an unknown format" : fs.uppercased()
        }
    }

    /// "120.4 GB free here · about 27 GB needed".
    static func spaceLine(free: Int64, need: Int64) -> String {
        need <= 0 ? "\(gb(free)) free here · nothing more to download"
                  : "\(gb(free)) free here · about \(gbUp(need)) needed"
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
    static func gbUp(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1e9).rounded(.up))) GB" }

    /// The real facts for an existing folder. Read-only: statfs, resource values, access(2).
    static func facts(for url: URL) -> Facts {
        var f = Facts()
        let path = url.standardizedFileURL.path
        f.missingDrive = Preflight.unavailableDrive(for: path)
        if f.missingDrive != nil { return f }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        f.isCloud = path.hasPrefix(home + "/Library/Mobile Documents") || path.hasPrefix(home + "/Library/CloudStorage")
            || (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        f.insideApp = url.standardizedFileURL.pathComponents.contains { ($0 as NSString).pathExtension.lowercased() == "app" }
        var st = statfs()
        if statfs(path, &st) == 0 {
            var t = st.f_fstypename
            f.fsType = withUnsafePointer(to: &t) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            f.isReadOnly = (st.f_flags & UInt32(MNT_RDONLY)) != 0
            f.isLocal = (st.f_flags & UInt32(MNT_LOCAL)) != 0
            let mp = Preflight.mountPoint(of: path) ?? "/"
            f.isBootVolume = mp == "/" || mp == "/System/Volumes/Data"
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        if let v = try? url.resourceValues(forKeys: keys) {
            if f.isBootVolume, let important = v.volumeAvailableCapacityForImportantUsage, important > 0 {
                f.freeBytes = important
            } else if let avail = v.volumeAvailableCapacity {
                f.freeBytes = Int64(avail)
            }
        }
        f.isWritable = access(path, W_OK) == 0
        return f
    }

    /// Where the chooser opens: the last choice, else the drive with the most room that would
    /// be accepted (its top level; the home folder when that is the Mac's own disk), else home.
    /// The user still decides; nothing is created.
    static func defaultDirectory(need: Int64 = Need.fresh) -> URL {
        let fm = FileManager.default
        if let r = remembered?.deletingLastPathComponent(), fm.fileExists(atPath: r.path) { return r }
        let home = fm.homeDirectoryForCurrentUser
        let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        var best: (URL, Int64)?
        for v in vols {
            // The Mac's own disk is judged by the home folder: its top level is not writable.
            let f = facts(for: v.path == "/" ? home : v)
            guard verdict(f, need: need).isOK else { continue }
            if best == nil || f.freeBytes > best!.1 { best = (f.isBootVolume ? home : v, f.freeBytes) }
        }
        guard let pick = best?.0 else { return home }
        let games = home.appendingPathComponent("Games")
        return pick == home && fm.fileExists(atPath: games.path) ? games : pick
    }
}

/// The folder chooser for Setup and Move: an open panel for folders, with a line under it that
/// says how much room the selected drive has against what is needed, or why it can't be used.
/// Choosing a folder that can't be used is refused in the panel, which stays open; Cancel
/// returns nil and nothing has been written.
///
/// Setup's chooser also looks for an install already in the selected folder (ExistingInstall),
/// off the main thread while the user browses: a second line says what it found ("Found
/// HorizonXI 2.0.4 here — Setup will use it."), and the space line then counts only what is
/// still missing. Inside Desktop, Documents and Downloads it looks only once a folder there has
/// been chosen (macOS asks the user before anything there is read).
@MainActor final class LocationPanel: NSObject, NSOpenSavePanelDelegate {
    /// What the user chose: the "FFXI on Mac" folder Setup works in (or the folder an older
    /// install found there is in), and what was found.
    struct Choice {
        let folder: URL
        let found: ExistingInstall.Found?
    }

    private let need: (ExistingInstall.Found?) -> Int64
    private let detect: Bool
    private let extra: (URL) -> String?
    private let foundLabel = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    /// What `ExistingInstall.find` said for each folder looked at (nil inside: nothing there).
    private var found: [String: ExistingInstall.Found?] = [:]
    private var looking: Set<String> = []
    private var shown: URL?

    private init(need: @escaping (ExistingInstall.Found?) -> Int64, detect: Bool, extra: @escaping (URL) -> String?) {
        self.need = need; self.detect = detect; self.extra = extra
    }

    /// The "FFXI on Mac" folder for the chosen place, or nil when cancelled. `extra` adds
    /// refusals of its own (Move: not inside the install being moved).
    static func choose(title: String, message: String, prompt: String, need: Int64,
                       extra: @escaping (URL) -> String? = { _ in nil }) -> URL? {
        run(title: title, message: message, prompt: prompt, need: { _ in need }, detect: false, extra: extra)?.folder
    }

    /// Setup's chooser: what is already in the chosen folder is found, and `need` is asked what
    /// is still missing given it.
    static func chooseForSetup(title: String, message: String, prompt: String,
                               need: @escaping (ExistingInstall.Found?) -> Int64) -> Choice? {
        run(title: title, message: message, prompt: prompt, need: need, detect: true, extra: { _ in nil })
    }

    private static func run(title: String, message: String, prompt: String, need: @escaping (ExistingInstall.Found?) -> Int64,
                            detect: Bool, extra: @escaping (URL) -> String?) -> Choice? {
        let d = LocationPanel(need: need, detect: detect, extra: extra)
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = InstallLocation.defaultDirectory(need: need(nil))
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: detect ? 48 : 30))
        for (k, l) in [d.label, d.foundLabel].enumerated() {
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: 10, y: 4 + CGFloat(k) * 20, width: 460, height: 20)
            if k == 0 || detect { box.addSubview(l) }
        }
        d.foundLabel.textColor = .labelColor
        panel.accessoryView = box
        panel.isAccessoryViewDisclosed = true
        panel.delegate = d
        d.show(panel.directoryURL)
        let ok = panel.runModal() == .OK
        panel.delegate = nil
        guard ok, let url = panel.url else { return nil }
        // The panel validated it; a drive that went away since is refused here.
        let f = d.foundNow(url)
        guard d.verdict(url, f).isOK else { return nil }
        return Choice(folder: f?.home ?? InstallLocation.folder(for: url), found: f)
    }

    /// What is in `url`, looked for now if the browsing look has not finished (the user pressed
    /// the button: a short wait on a bounded look, which is also the one look inside Downloads).
    private func foundNow(_ url: URL) -> ExistingInstall.Found? {
        guard detect else { return nil }
        if let f = found[url.path] { return f }
        let f = ExistingInstall.find(in: url)
        found[url.path] = .some(f)
        return f
    }

    private func verdict(_ url: URL, _ f: ExistingInstall.Found?) -> InstallLocation.Verdict {
        if let why = extra(url) ?? ExistingInstall.refusal(f) { return .refused(why) }
        // Asked of where Setup will write: the folder an install found here is in, or the chosen
        // folder (its "FFXI on Mac" folder may not exist yet).
        var at = (f?.home ?? url).standardizedFileURL
        while !FileManager.default.fileExists(atPath: at.path), at.path != "/" { at = at.deletingLastPathComponent() }
        return InstallLocation.verdict(InstallLocation.facts(for: at), need: need(f))
    }

    private func show(_ url: URL?) {
        shown = url
        guard let url else { label.stringValue = ""; foundLabel.stringValue = ""; return }
        if detect, found[url.path] == nil, !ExistingInstall.isGated(url) {
            foundLabel.stringValue = "Looking for an earlier install here…"
            foundLabel.textColor = .secondaryLabelColor
            label.stringValue = ""
            if looking.insert(url.path).inserted {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let f = ExistingInstall.find(in: url)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.looking.remove(url.path)
                        self.found[url.path] = .some(f)
                        if self.shown == url { self.show(url) }
                    }
                }
            }
            return
        }
        let f = found[url.path] ?? nil
        foundLabel.stringValue = f?.line ?? ""
        foundLabel.textColor = f?.unreachableDrive == nil ? .labelColor : .systemOrange
        let v = verdict(url, f)
        label.stringValue = v.line
        label.textColor = v.isOK ? .secondaryLabelColor : .systemRed
    }

    func panelSelectionDidChange(_ sender: Any?) {
        let p = sender as? NSOpenPanel
        show(p?.url ?? p?.directoryURL)
    }

    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        if (sender as? NSOpenPanel)?.url == nil { show(url) }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        if case .refused(let why) = verdict(url, foundNow(url)) {
            throw NSError(domain: "FFXIOnMac.location", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
        }
    }
}
