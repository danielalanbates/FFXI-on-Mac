import Foundation
import AppKit

/// VanaVoice: cutscene dialogue read aloud.
///
/// FFXI's story is entirely silent text. VanaVoice (a separate menu-bar app, in this project's
/// own repository at github.com/danielalanbates/vanavoice) narrates it with a neural voice.
/// The split is deliberate: speech synthesis has nothing to do with launching a game, it wants
/// to keep running while the launcher is closed, and OCR mode needs a Screen Recording grant
/// this app should not be asking for.
///
/// All this file does is wire the two together at launch — put the Lua addon in the game
/// folder, switch it on in Ashita's start-up script, and make sure the narrator is running.
/// Everything it writes is confined to the addon folder and one line in `scripts/default.txt`,
/// outside the block AddonSuite owns, so the two never fight over the file.
enum Narration {
    static let appPath = "/Applications/VanaVoice.app"
    static let loadLine = "/addon load vanavoice"
    static let marker = "# VanaVoice narrator"

    /// Which start-up script the world being launched actually runs.
    ///
    /// Not always `default.txt`. A boot profile names its own script (`script=` in the v4 .ini,
    /// `boot_script` in the v3 .xml), and worlds in the same install can name different ones --
    /// this project's local LandSandBoat profile does exactly that, so that an addon enabled for
    /// the local world cannot load on HorizonXI. Assuming the filename would put the load line
    /// in a file nobody reads, or worse, in the one world where it must not appear.
    static func scriptName(in install: Install, profile: String) -> String {
        let name = install.bootProfileName(profile)
        let url = install.gameDir.appendingPathComponent("config/boot/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "default.txt" }

        if name.hasSuffix(".xml") {
            let v = Credentials.xmlSetting("boot_script", in: text) ?? ""
            return v.isEmpty ? "default.txt" : v
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), !t.hasPrefix(";"),
                  t.lowercased().hasPrefix("script"), let eq = t.firstIndex(of: "=") else { continue }
            let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return "default.txt"
    }

    /// Is the narrator app installed on this Mac?
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: appPath) }

    /// May this world run it at all?
    ///
    /// VanaVoice is on nobody's published allowlist. On a server that runs one -- HorizonXI and
    /// CatsEyeXI both do, and both say an unlisted addon can cost you the account -- the answer
    /// is no, and it is not a warning or a checkbox: the launcher simply will not install it.
    /// Balloon is approved on HorizonXI and does the same dialogue capture on screen; that is
    /// the route to ask them about, not this one.
    static func allowed(by policy: AddonPolicy) -> Bool {
        !policy.isRestricting || policy.allows("vanavoice")
    }

    static var addonSource: URL? {
        let bundled = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources/vanavoice")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let gdrive = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-danielalanbates@gmail.com/My Drive/Code/GitHub/vanavoice/addon/vanavoice")
        if FileManager.default.fileExists(atPath: gdrive.path) { return gdrive }
        return nil
    }

    /// Called on every launch. Never fatal: if any part of this fails the game still starts,
    /// silent, exactly as it did before.
    static func prepare(_ install: Install, enabled: Bool, policy: AddonPolicy,
                        profile: String = "horizonxi.ini", log: (String) -> Void) {
        let fm = FileManager.default
        let script = scriptName(in: install, profile: profile)
        let scripts = install.gameDir.appendingPathComponent("scripts/\(script)")

        // The server's rules come first, ahead of the user's own setting: an allowlist server
        // gets the addon removed, not merely left uninstalled, in case an older build of this
        // launcher (or the player) put it there.
        guard allowed(by: policy) else {
            let dest = install.gameDir.appendingPathComponent("addons/vanavoice", isDirectory: true)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            if removeLoadLine(from: scripts) || enabled {
                log("==> narration: not allowed here — this world runs an addon allowlist and "
                    + "VanaVoice is not on it")
            }
            return
        }

        guard enabled else {
            if removeLoadLine(from: scripts) { log("==> narration: off") }
            return
        }
        guard isAvailable, let src = addonSource else {
            log("==> narration: VanaVoice.app is not installed; skipping")
            return
        }

        // The addon and the app meet in /tmp/vanavoice. Create it before the game starts so the
        // addon's first write lands there rather than in the game folder.
        try? fm.createDirectory(atPath: "/tmp/vanavoice", withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o777])

        let dest = install.gameDir.appendingPathComponent("addons/vanavoice", isDirectory: true)
        // Copy every launch: the app updates, and a stale addon beside a new app is the kind of
        // mismatch nobody thinks to check.
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        do { try fm.copyItem(at: src, to: dest) }
        catch { log("==> narration: could not install the addon — \(error.localizedDescription)"); return }

        addLoadLine(to: scripts)
        launchNarrator(log: log)
        log("==> narration: on (VanaVoice, via scripts/\(script))")
    }

    /// Append the load line after everything AddonSuite manages, so rewriting that block never
    /// drops it and this never lands inside it.
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

    /// Start the narrator if it is not already up. VanaVoice refuses to run twice itself, but
    /// asking for a second copy would still steal focus, so check first.
    private static func launchNarrator(log: (String) -> Void) {
        let running = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "org.batesai.vanavoice" }
        guard !running else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath),
                                           configuration: cfg) { _, error in
            if let error { NSLog("VanaVoice launch failed: \(error.localizedDescription)") }
        }
    }
}
