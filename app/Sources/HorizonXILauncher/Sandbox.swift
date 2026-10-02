import Foundation

/// Ashita's **Sandbox** POL plugin, and the one setting in it that decides whether the game
/// starts at all.
///
/// Sandbox virtualises the PlayOnline registry for the game. Its `use_interface_bypass` hook
/// patches FFXI's `patch.ver` interface-id check — the check that reads
/// `HKLM\SOFTWARE\PlayOnlineUS\Interface` (`Wow6432Node` in the 32-bit view) to decide whether the
/// installed game data is the version PlayOnline expects.
///
/// A private server's client never has valid `Interface` values, so with the bypass **off** that
/// check fails. FFXI does not report it: it reads `patch.ver`, takes an unadvertised failure
/// path, calls `UnregisterClassA("FFXiClass")` for a window class it never registered, and exits
/// about two seconds after `xiloader` prints "Connected to server!". No error, no crash dump, no
/// window, zero d3d8 calls — the exact "logs in, then Closing…" signature in docs/FINDINGS.md
/// that resisted diagnosis for weeks.
///
/// Measured 2026-08-16 on the live HorizonXI install, boot profile unchanged otherwise:
///
/// | `[ashita.polplugins]`      | `use_interface_bypass` | result                         |
/// | -------------------------- | ---------------------- | ------------------------------ |
/// | `sandbox=0 pivot=0`        | (not loaded)           | launches, renders              |
/// | `sandbox=0 pivot=1`        | (not loaded)           | launches, renders              |
/// | `sandbox=1 pivot=0`        | `0`                    | **exits ~2 s after login**     |
/// | `sandbox=1 pivot=1`        | `0`                    | **exits ~2 s after login**     |
/// | `sandbox=1 pivot=1`        | `1`                    | launches, reaches character select |
///
/// Ashita ships this defaulted to `1` and documents it as `Default: 1`; the value in this install
/// had been set to `0`. Nothing else in the boot profile, the game data, the wine prefix, the
/// registry or the wrapper mattered — a byte-identical fresh 2.0.3 client in the same prefix ran
/// fine, because its stock `sandbox.ini` still had the bypass on.
enum Sandbox {

    /// Is the Sandbox POL plugin switched on for this boot profile?
    static func isEnabled(in install: Install, profile: String) -> Bool {
        let url = install.gameDir.appendingPathComponent("config/boot/\(profile)")
        guard let text = Credentials.readFile(at: url) else { return false }
        var inSection = false
        for raw in TextFile.lines(of: text) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                inSection = t.lowercased().hasPrefix("[ashita.polplugins]")
                continue
            }
            guard inSection, !t.hasPrefix(";"), let eq = t.firstIndex(of: "=") else { continue }
            guard t[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "sandbox" else { continue }
            return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces).hasPrefix("1")
        }
        return false
    }

    static func iniURL(_ install: Install) -> URL {
        install.gameDir.appendingPathComponent("config/sandbox/sandbox.ini")
    }

    /// The current value of `use_interface_bypass`, or nil if the file or key is absent.
    /// Absent means Ashita's own default (1) applies, which is fine.
    static func interfaceBypass(_ install: Install) -> Bool? {
        guard let text = Credentials.readFile(at: iniURL(install)) else { return nil }
        for raw in TextFile.lines(of: text) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix(";"), t.lowercased().hasPrefix("use_interface_bypass"),
                  let eq = t.firstIndex(of: "=") else { continue }
            return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces).hasPrefix("1")
        }
        return nil
    }

    /// True when this install is in the configuration that silently kills the game.
    static func isBroken(_ install: Install, profile: String) -> Bool {
        isEnabled(in: install, profile: profile) && interfaceBypass(install) == false
    }

    /// Turn the bypass back on, preserving the file's line endings. Returns true if it changed
    /// anything. The previous file is kept beside it once, as `sandbox.ini.bak`.
    @discardableResult
    static func repair(_ install: Install, log: (String) -> Void = { _ in }) -> Bool {
        let url = iniURL(install)
        guard let text = Credentials.readFile(at: url) else { return false }
        guard interfaceBypass(install) == false else { return false }

        let eol = TextFile.terminator(of: text)
        var changed = false
        let lines = TextFile.lines(of: text).map { l -> String in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix(";"), t.lowercased().hasPrefix("use_interface_bypass") else { return String(l) }
            changed = true
            return "use_interface_bypass = 1"
        }
        guard changed else { return false }

        let backup = url.deletingLastPathComponent().appendingPathComponent("sandbox.ini.bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            Credentials.writeFile(text, to: backup)
        }
        guard Credentials.writeFile(TextFile.join(lines, terminator: eol), to: url)
        else { return false }
        log("sandbox: use_interface_bypass turned back on (the game exits ~2s after login without it)")
        return true
    }
}
