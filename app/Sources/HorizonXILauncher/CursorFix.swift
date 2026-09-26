import Foundation

enum CursorFix {
    static let loadLine = "/addon load winecursor"
    static let marker = "# Horizon cursor visibility fix"
    static let addonDirName = "winecursor"

    static func allowed(by policy: AddonPolicy) -> Bool {
        if case .unrestricted = policy { return true }
        return false
    }

    static var addonSource: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("winecursor", isDirectory: true),
           isCompleteAddon(at: bundled) {
            return bundled
        }
        for root in CodeFolders.googleDriveCodeRoots {
            let source = root.appendingPathComponent("GitHub/HorizonXI-on-Mac/addons/winecursor",
                                                      isDirectory: true)
            if isCompleteAddon(at: source) { return source }
        }
        return nil
    }

    static func isCompleteAddon(at source: URL) -> Bool {
        FileManager.default.fileExists(atPath: source.appendingPathComponent("winecursor.lua").path)
    }

    static func prepare(_ install: Install, policy: AddonPolicy,
                        profile: String = "horizonxi.ini", log: (String) -> Void) {
        let fm = FileManager.default
        let script = Narration.scriptName(in: install, profile: profile)
        let scripts = install.gameDir.appendingPathComponent("scripts/\(script)")
        let dest = install.gameDir.appendingPathComponent("addons/\(addonDirName)",
                                                          isDirectory: true)
        guard allowed(by: policy) else {
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            if removeLoadLine(from: scripts) {
                log("==> winecursor: removed — custom addons are not enabled on this world")
            }
            return
        }
        guard let source = addonSource else {
            log("==> winecursor: addon source unavailable; cursor fix not loaded")
            return
        }
        do {
            try AddonInstaller.replaceDirectory(at: dest, with: source, fileManager: fm)
        } catch {
            log("==> winecursor: could not install addon — \(error.localizedDescription)")
            return
        }
        addLoadLine(to: scripts)
        log("==> winecursor: on (via scripts/\(script))")
    }

    static func addLoadLine(to scripts: URL) {
        var text = Credentials.readFile(at: scripts) ?? "/load Addons\n"
        guard !text.contains(loadLine) else { return }
        if !text.hasSuffix("\n") { text += "\n" }
        text += "\n\(marker)\n\(loadLine)\n"
        Credentials.writeFile(text, to: scripts)
    }

    @discardableResult
    static func removeLoadLine(from scripts: URL) -> Bool {
        guard let text = Credentials.readFile(at: scripts), text.contains(loadLine) else { return false }
        let kept = TextFile.lines(of: text).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line != loadLine && line != marker
        }
        Credentials.writeFile(kept.joined(separator: "\n"), to: scripts)
        return true
    }
}
