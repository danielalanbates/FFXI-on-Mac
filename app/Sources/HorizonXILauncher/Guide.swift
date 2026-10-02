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
    static let companionPath = "/Applications/Vanaguide.app"
    static var companionAvailable: Bool { FileManager.default.fileExists(atPath: companionPath) }
    static let loadLine = "/addon load vanaguide"
    static let marker = "# Vanaguide quest guide"
    /// Folder name matches `vanaguide/tools/install.sh` (`addons/Vanaguide`).
    static let addonDirName = "Vanaguide"

    /// Candidate source trees, first hit wins.
    ///
    /// Prefer the bundled, tested snapshot; fall back to source checkouts for older builds.
    private static var candidateSources: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let gdriveCode = home
            .appendingPathComponent("Library/CloudStorage/GoogleDrive-danielalanbates@gmail.com/My Drive/Code")
        let icloudCode = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Code")
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Vanaguide", isDirectory: true)
        return [
            bundled,
            gdriveCode.appendingPathComponent("GitHub/vanaguide/Vanaguide", isDirectory: true),
            gdriveCode.appendingPathComponent("GitHub/Vanaguide/Vanaguide", isDirectory: true),
            gdriveCode.appendingPathComponent("vanaguide/Vanaguide", isDirectory: true),
            gdriveCode.appendingPathComponent("Vanaguide/Vanaguide", isDirectory: true),
            icloudCode.appendingPathComponent("Vanaguide/Vanaguide", isDirectory: true),
            icloudCode.appendingPathComponent("GitHub/vanaguide/Vanaguide", isDirectory: true),
            icloudCode.appendingPathComponent("GitHub/Vanaguide/Vanaguide", isDirectory: true),
            home.appendingPathComponent("Downloads/Vanaguide", isDirectory: true),
            home.appendingPathComponent("Downloads/vanaguide/Vanaguide", isDirectory: true),
        ].compactMap { $0 }
    }

    /// Is a Vanaguide addon tree present somewhere we can copy from?
    static var isAvailable: Bool { addonSource != nil }

    /// May this world run it at all?
    ///
    /// Same gate as VanaVoice: allowlist servers get a hard no. Local LandSandBoat
    /// (`AddonPolicies.localWorld`) and any `.unrestricted` / `.unknown` policy may install.
    static func allowed(by policy: AddonPolicy) -> Bool {
        !policy.isRestricting || policy.allows("vanaguide")
    }

    /// Directory that contains `Vanaguide.lua` (the Ashita addon root).
    static var addonSource: URL? {
        let fm = FileManager.default
        for u in candidateSources {
            let entry = u.appendingPathComponent("Vanaguide.lua")
            if fm.fileExists(atPath: entry.path) { return u }
        }
        return nil
    }

    /// Reuse Narration's boot-script resolution so a world that points `script=` at `lsb.txt`
    /// (or any other file) gets the load line in the file Ashita actually runs.
    static func scriptName(in install: Install, profile: String) -> String {
        Narration.scriptName(in: install, profile: profile)
    }

    /// Called on every launch. Never fatal: if any part fails the game still starts without
    /// the guide, exactly as it did before.
    static func prepare(_ install: Install, enabled: Bool, policy: AddonPolicy,
                        profile: String = "horizonxi.ini", log: (String) -> Void) {
        let fm = FileManager.default
        let script = scriptName(in: install, profile: profile)
        let scripts = install.gameDir.appendingPathComponent("scripts/\(script)")
        let dest = install.gameDir.appendingPathComponent("addons/\(addonDirName)",
                                                          isDirectory: true)

        // Server rules first: scrub leftovers from older manual installs or prior launcher
        // builds so an allowlist world never carries Vanaguide into a session.
        guard allowed(by: policy) else {
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            if removeLoadLine(from: scripts) || enabled {
                log("==> vanaguide: not allowed here — this world runs an addon allowlist and "
                    + "Vanaguide is not on it")
            }
            return
        }

        guard enabled else {
            if removeLoadLine(from: scripts) { log("==> vanaguide: off") }
            return
        }
        guard let src = addonSource else {
            log("==> vanaguide: no source tree found (expected Code/Vanaguide/Vanaguide or "
                + "Downloads/Vanaguide); skipping")
            return
        }

        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        do { try fm.copyItem(at: src, to: dest) }
        catch {
            log("==> vanaguide: could not install the addon — \(error.localizedDescription)")
            return
        }

        addLoadLine(to: scripts)
        log("==> vanaguide: on (from \(src.path), via scripts/\(script))")
    }

    /// Append the load line after everything AddonSuite manages.
    private static func addLoadLine(to scripts: URL) {
        var text = (try? String(contentsOf: scripts, encoding: .utf8)) ?? "/load Addons\n"
        guard !text.contains(loadLine) else { return }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "\n\(marker)\n\(loadLine)\n"
        try? text.write(to: scripts, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func removeLoadLine(from scripts: URL) -> Bool {
        guard let text = try? String(contentsOf: scripts, encoding: .utf8),
              text.contains(loadLine) else { return false }
        let kept = TextFile.lines(of: text).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t != loadLine && t != marker
        }
        try? kept.joined(separator: "\n").write(to: scripts, atomically: true, encoding: .utf8)
        return true
    }
}
