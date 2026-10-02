import Foundation

/// Vanaguide: Zygor-style quest / mission guide for Vana'diel.
///
/// Lives in its own repository (`github.com/danielalanbates/vanaguide`). This file only wires
/// the launcher to it at launch — copy the Lua addon into the game folder and switch it on in
/// Ashita's start-up script. Everything it writes is confined to `addons/Vanaguide` and one
/// line in the world's script, outside the block AddonSuite owns, so the two never fight.
///
/// **LSB / unrestricted only.** Vanaguide is on nobody's published allowlist. On HorizonXI,
/// CatsEyeXI, FFEra, and any other allowlist world the launcher refuses to install it and
/// removes any leftover copy, same safety model as `Narration.swift` for VanaVoice.
enum Guide {
    static let loadLine = "/addon load vanaguide"
    static let marker = "# Vanaguide quest guide"
    /// Folder name matches `vanaguide/tools/install.sh` (`addons/Vanaguide`).
    static let addonDirName = "Vanaguide"

    /// Candidate source trees, first hit wins.
    ///
    /// Prefer this launcher's bundled snapshot, then live Drive/iCloud checkouts and a Downloads
    /// copy for development. Never read from `/Applications/*.app` playable trees as edit sources.
    private static var candidateSources: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloudCode = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Code")
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Vanaguide", isDirectory: true)
        let drive = CodeFolders.googleDriveCodeRoots.flatMap { codeRoot in [
            codeRoot.appendingPathComponent("GitHub/vanaguide/Vanaguide", isDirectory: true),
            codeRoot.appendingPathComponent("GitHub/Vanaguide/Vanaguide", isDirectory: true),
            codeRoot.appendingPathComponent("vanaguide/Vanaguide", isDirectory: true),
            codeRoot.appendingPathComponent("Vanaguide/Vanaguide", isDirectory: true),
        ] }
        let fallbacks = [
            icloudCode.appendingPathComponent("Vanaguide/Vanaguide", isDirectory: true),
            icloudCode.appendingPathComponent("GitHub/vanaguide/Vanaguide", isDirectory: true),
            icloudCode.appendingPathComponent("GitHub/Vanaguide/Vanaguide", isDirectory: true),
            home.appendingPathComponent("Downloads/Vanaguide", isDirectory: true),
            home.appendingPathComponent("Downloads/vanaguide/Vanaguide", isDirectory: true),
        ]
        return (bundled.map { [$0] } ?? []) + drive + fallbacks
    }

    /// Is a Vanaguide addon tree present somewhere we can copy from?
    static var isAvailable: Bool { addonSource != nil }

    /// May this world run it at all?
    ///
    /// This project only permits the guide on its own local LandSandBoat world. An unknown
    /// hosted-server policy is not permission to install an unapproved addon.
    static func allowed(by policy: AddonPolicy) -> Bool {
        if case .unrestricted = policy { return true }
        return false
    }

    /// Directory that contains `Vanaguide.lua` (the Ashita addon root).
    static var addonSource: URL? {
        let fm = FileManager.default
        for u in candidateSources {
            guard isCompleteAddon(at: u, fileManager: fm) else { continue }
            return u
        }
        return nil
    }

    static func isCompleteAddon(at source: URL, fileManager: FileManager) -> Bool {
        let requiredFiles = [
            "Vanaguide.lua", "core/guide.lua", "core/progress.lua", "core/story.lua",
            "core/conditions.lua", "core/util.lua", "core/lookup.lua", "core/verify.lua",
            "core/walk.lua", "guides/init.lua", "routing/zonegraph.lua", "routing/router.lua",
            "routing/path.lua", "routing/zonepoints.lua", "routing/navgrid.lua",
            "ui/arrow.lua", "ui/window.lua", "ui/line.lua", "ui/project.lua",
            "data/zone_names.lua", "data/zonelines.lua", "data/zonepoints.lua",
            "data/drops.lua", "data/gear.lua", "data/missions.lua", "data/nm.lua",
            "data/quests.lua", "data/travel.lua", "data/vendors.lua",
        ]
        let filesExist = requiredFiles.allSatisfy {
            fileManager.fileExists(atPath: source.appendingPathComponent($0).path)
        }
        let directoriesExist = ["guides", "data", "routing", "ui"].allSatisfy {
            var isDirectory = ObjCBool(false)
            return fileManager.fileExists(
                atPath: source.appendingPathComponent($0, isDirectory: true).path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
        return filesExist && directoriesExist
    }

    /// Reuse Narration's boot-script resolution so a world that points `script=` at `lsb.txt`
    /// (or any other file) gets the load line in the file Ashita actually runs.
    static func scriptName(in install: Install, profile: String) -> String {
        Narration.scriptName(in: install, profile: profile)
    }

    /// Called on every launch. Never fatal: if any part fails the game still starts without
    /// the guide, exactly as it did before.
    ///
    /// `othersLive`: another client shares this game folder right now. Its addons stay on disk
    /// (it may have them loaded); only this world's load line is taken out.
    static func prepare(_ install: Install, enabled: Bool, policy: AddonPolicy,
                        profile: String = "horizonxi.ini", othersLive: Bool = false,
                        log: (String) -> Void) {
        let fm = FileManager.default
        let script = scriptName(in: install, profile: profile)
        let scripts = install.gameDir.appendingPathComponent("scripts/\(script)")
        let dest = install.gameDir.appendingPathComponent("addons/\(addonDirName)",
                                                          isDirectory: true)

        // Server rules first: scrub leftovers from older manual installs or prior launcher
        // builds so an allowlist world never carries Vanaguide into a session.
        guard allowed(by: policy) else {
            if fm.fileExists(atPath: dest.path) {
                if othersLive { log("==> vanaguide: addons/\(addonDirName) kept on disk — another world is running") }
                else { try? fm.removeItem(at: dest) }
            }
            if removeLoadLine(from: scripts) || enabled {
                log("==> vanaguide: not allowed here — this world runs an addon allowlist and "
                    + "Vanaguide is not on it")
            }
            return
        }

        guard enabled else {
            let removedAddon = !othersLive && fm.fileExists(atPath: dest.path)
            if removedAddon { try? fm.removeItem(at: dest) }
            if removeLoadLine(from: scripts) || removedAddon { log("==> vanaguide: off") }
            return
        }
        guard let src = addonSource else {
            log("==> vanaguide: no source tree found (expected Code/Vanaguide/Vanaguide or "
                + "Downloads/Vanaguide); skipping")
            return
        }

        // Replacing swaps the folder out from under a client that has it loaded.
        if othersLive, isCompleteAddon(at: dest, fileManager: fm) {
            log("==> vanaguide: another world is running; using the copy already installed")
        } else {
            do { try AddonInstaller.replaceDirectory(at: dest, with: src, preserving: ["data/nav"], fileManager: fm) }
            catch {
                log("==> vanaguide: could not install the addon — \(error.localizedDescription)")
                return
            }
        }

        addLoadLine(to: scripts)
        log("==> vanaguide: on (from \(src.path), via scripts/\(script))")
    }

    /// Append the load line after everything AddonSuite manages.
    private static func addLoadLine(to scripts: URL) {
        var text = Credentials.readFile(at: scripts) ?? "/load Addons\n"
        guard !text.contains(loadLine) else { return }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "\n\(marker)\n\(loadLine)\n"
        Credentials.writeFile(text, to: scripts)
    }

    @discardableResult
    private static func removeLoadLine(from scripts: URL) -> Bool {
        guard let text = Credentials.readFile(at: scripts),
              text.contains(loadLine) else { return false }
        let kept = TextFile.lines(of: text).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t != loadLine && t != marker
        }
        Credentials.writeFile(kept.joined(separator: "\n"), to: scripts)
        return true
    }
}
