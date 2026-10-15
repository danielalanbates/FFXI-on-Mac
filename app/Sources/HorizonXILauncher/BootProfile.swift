import Foundation

/// What Play makes sure of in a world's Ashita v4 boot profile before Ashita reads it, beyond the
/// account line `Credentials.apply` writes.
///
/// b60, 2026-10-15, Daniel's Setup-built install: PLAY said "Starting…" and nothing came. A client
/// this launcher installs has no `horizonxi.ini` at all -- HorizonXI's own launcher writes that
/// file each time it starts the game -- so `Credentials.ensureProfile` had copied Ashita's
/// `example-privateserver.ini`, whose `file =` is `bootloader\pol.exe`: Ashita's DarkStar-era
/// loader. It connected, could not log in, and sat at its account menu reading a stdin nobody
/// can type into. `fixBootLoader` kept it, because it only replaced a loader that was missing.
///
/// Now a world names the loader it needs (`Server.loader`), a new HorizonXI profile is made from
/// a template shipped in the app (`Server.bootTemplate`, app/Resources/horizonxi-boot.ini), and an
/// existing one is given the settings `required` lists when it lacks them. Nothing a user set is
/// changed, and the `command` line that carries the account is only ever added, never rewritten.
enum BootProfile {
    static let horizonTemplate = "horizonxi-boot.ini"

    struct Setting: Equatable, CustomStringConvertible {
        let section: String
        let key: String
        let value: String
        var description: String { "[\(section)] \(key)" }
    }

    /// Settings a profile for a world with this template cannot do without, each added only when
    /// the profile has no live line for it. Every one of them is in the template with the same
    /// value (`--selftest-boot-profile` checks), and docs/BETA-61.md says why the rest of the
    /// template is not on this list.
    static func required(template: String, host: String) -> [Setting] {
        guard template == horizonTemplate else { return [] }
        return [
            // `Credentials.apply` writes the account into this line, and fails when there is none.
            Setting(section: "ashita.boot", key: "command", value: "--server \(host)"),
            // Without a script Ashita runs none: no addons or plugins load, and nothing the
            // launcher's addon steps write (LuaJITGuard, Narration, Guide) takes effect.
            Setting(section: "ashita.boot", key: "script", value: "default.txt"),
            // HorizonXI's own DATs and music are XIPivot overlays (config/pivot/pivot.ini lists
            // horizonmusic and horizonoverrides). Without the plugin the client shows stock data.
            Setting(section: "ashita.polplugins", key: "pivot", value: "1"),
            // The renderer's override (fpu_preserve = 1 on the DXVK pathway, Renderer.iniOverrides)
            // only rewrites a line that is there.
            Setting(section: "ffxi.direct3d8", key: "behaviorflags.fpu_preserve", value: "0"),
        ]
    }

    /// With the Sandbox plugin loaded, the game's PlayOnline install paths come from here rather
    /// than from the registry `GameRegistry.point` writes. HorizonXI's stock values are relative to
    /// the client (`..\SquareEnix\…`); a client whose SquareEnix folder is elsewhere gets its
    /// real Windows path instead.
    static func sandboxPaths(for install: Install) -> [Setting] {
        let direct = install.gameDir.appendingPathComponent("SquareEnix").standardizedFileURL.path
        let se = install.squareEnix.standardizedFileURL.path == direct ? "..\\SquareEnix" : install.squareEnixWine
        return [
            Setting(section: "sandbox.paths", key: "common", value: "C:\\Program Files (x86)\\Common Files"),
            Setting(section: "sandbox.paths", key: "pol", value: se + "\\PlayOnlineViewer"),
            Setting(section: "sandbox.paths", key: "ffxi", value: se + "\\FINAL FANTASY XI"),
        ]
    }

    // MARK: - The template

    /// The template's text: the app bundle's copy, or the repo's under `swift build`.
    static func templateText(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        if let u = Bundle.main.url(forResource: base, withExtension: ext),
           let t = try? String(contentsOf: u, encoding: .utf8) { return t }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name)")
        return try? String(contentsOf: dev, encoding: .utf8)
    }

    /// A new profile for this install from the template: the template, with the Sandbox paths
    /// this client needs and the world's own login host.
    static func seed(_ template: String, for install: Install, host: String) -> String? {
        guard var text = templateText(template) else { return nil }
        for s in sandboxPaths(for: install) { text = setting(s, in: text) }
        if !host.isEmpty { text = setting(Setting(section: "ashita.boot", key: "command", value: "--server \(host)"), in: text) }
        return text
    }

    // MARK: - Reading and editing profile text

    private static func sectionName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return nil }
        return String(t[t.index(after: t.startIndex)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The key of a live `key = value` line (lowercased), or nil for comments, headers, blanks.
    private static func key(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix(";"), !t.hasPrefix("#"), !t.hasPrefix("["),
              let eq = t.firstIndex(of: "=") else { return nil }
        let k = t[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        return k.isEmpty ? nil : k
    }

    /// Index of the live line for `key` in `section`, if there is one.
    private static func lineIndex(_ key: String, section: String, in lines: [String]) -> Int? {
        var current = ""
        for (n, l) in lines.enumerated() {
            if let s = sectionName(l) { current = s; continue }
            if current == section.lowercased(), Self.key(l) == key.lowercased() { return n }
        }
        return nil
    }

    /// The value of `[section] key`, trimmed, or nil when the profile has no live line for it.
    static func value(_ key: String, section: String, in text: String) -> String? {
        let lines = TextFile.lines(of: text)
        guard let n = lineIndex(key, section: section, in: lines),
              let eq = lines[n].firstIndex(of: "=") else { return nil }
        return lines[n][lines[n].index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }

    static func has(_ s: Setting, in text: String) -> Bool {
        lineIndex(s.key, section: s.section, in: TextFile.lines(of: text)) != nil
    }

    /// `text` with `setting` added when it has no live line for it: after the last setting of its
    /// section, or as a new section at the end. Line endings are the file's own.
    static func adding(_ s: Setting, to text: String) -> String {
        var lines = TextFile.lines(of: text)
        guard lineIndex(s.key, section: s.section, in: lines) == nil else { return text }
        let line = "\(s.key) = \(s.value)"
        var current = "", header: Int?, lastKey: Int?
        for (n, l) in lines.enumerated() {
            if let name = sectionName(l) {
                if header != nil, current == s.section.lowercased() { break }
                current = name
                if name == s.section.lowercased() { header = n }
                continue
            }
            if header != nil, current == s.section.lowercased(), key(l) != nil { lastKey = n }
        }
        if let at = lastKey ?? header {
            lines.insert(line, at: at + 1)
        } else {
            // A new section, after the last non-empty line, separated by one blank line.
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += ["", "[\(s.section)]", line, ""]
        }
        return TextFile.join(lines, terminator: TextFile.terminator(of: text))
    }

    /// `text` with `[section] key` set to `value`, added if absent. For the launcher's own seed only:
    /// an existing profile's values are never rewritten by this file.
    static func setting(_ s: Setting, in text: String) -> String {
        var lines = TextFile.lines(of: text)
        guard let n = lineIndex(s.key, section: s.section, in: lines),
              let eq = lines[n].firstIndex(of: "=") else { return adding(s, to: text) }
        lines[n] = String(lines[n][...eq]) + " " + s.value
        return TextFile.join(lines, terminator: TextFile.terminator(of: text))
    }

    /// Basename of the executable `[ashita.boot] file` boots, or nil.
    static func loaderName(in text: String) -> String? {
        guard let v = value("file", section: "ashita.boot", in: text), !v.isEmpty else { return nil }
        let base = v.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").last.map(String.init) ?? v
        return base.isEmpty ? nil : base
    }

    /// `text` booting `loader` out of bootloader/, written the way `fixBootLoader` always has.
    /// A profile with no `file` line gets one only when `addIfMissing`.
    static func withLoader(_ loader: String, in text: String, addIfMissing: Bool) -> String? {
        let line = "file        = .\\\\bootloader\\\\\(loader)"
        var lines = TextFile.lines(of: text)
        if let n = lineIndex("file", section: "ashita.boot", in: lines) {
            lines[n] = line
            return TextFile.join(lines, terminator: TextFile.terminator(of: text))
        }
        guard addIfMissing else { return nil }
        // `adding` writes "key = value"; the loader line keeps fixBootLoader's own spelling.
        let added = adding(Setting(section: "ashita.boot", key: "file", value: ""), to: text)
        var out = TextFile.lines(of: added)
        if let n = lineIndex("file", section: "ashita.boot", in: out) { out[n] = line }
        return TextFile.join(out, terminator: TextFile.terminator(of: text))
    }

    /// Boot loaders this launcher knows, in preference order, for a profile whose own is missing.
    static let knownLoaders = ["horizon-loader.exe", "xiloader.exe", "pol.exe", "catseye-loader.exe", "gxiloader.exe"]

    /// The loader `[ashita.boot] file` should be changed to, or nil to leave it as it is.
    ///
    /// The world's own loader wins whenever it is in bootloader/ -- even over another loader that
    /// is there too, which is the whole b61 fix: HorizonXI's client carries pol.exe and
    /// xiloader.exe beside horizon-loader.exe. Otherwise, as before: a loader that exists is
    /// kept, and a missing one is replaced by the first known one present.
    static func loaderToName(named: String?, present: [String], worldLoader: String) -> String? {
        guard !present.isEmpty else { return nil }
        func found(_ n: String) -> String? { present.first { $0.caseInsensitiveCompare(n) == .orderedSame } }
        if !worldLoader.isEmpty, let w = found(worldLoader) {
            return named.map { $0.caseInsensitiveCompare(w) == .orderedSame } == true ? nil : w
        }
        if let n = named, found(n) != nil { return nil }
        return knownLoaders.lazy.compactMap(found).first ?? present.sorted().first
    }

    /// What `complete` would add to `text`, in order.
    static func missing(in text: String, template: String, host: String, install: Install) -> [Setting] {
        var want = required(template: template, host: host)
        // Sandbox's paths matter only where Sandbox is loaded.
        if !template.isEmpty, value("sandbox", section: "ashita.polplugins", in: text)?.hasPrefix("1") == true {
            want += sandboxPaths(for: install)
        }
        return want.filter { !has($0, in: text) }
    }

    /// `text` with every missing required setting added, and what was added.
    static func completed(_ text: String, template: String, host: String,
                          install: Install) -> (text: String, added: [Setting]) {
        let add = missing(in: text, template: template, host: host, install: install)
        return (add.reduce(text) { adding($1, to: $0) }, add)
    }

    // MARK: - XIPivot's overlay folder

    /// The Mac path a Windows path in this prefix names (`C:\…` is drive_c, other letters go
    /// through wine's dosdevices links), or nil for a relative or empty one.
    static func macPath(forWine p: String, in install: Install) -> URL? {
        let t = p.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, t.dropFirst().first == ":", let letter = t.first?.lowercased(),
              t.dropFirst(2).first == "\\" || t.dropFirst(2).first == "/" else { return nil }
        let rest = t.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        let root: URL
        switch letter {
        case "c": root = install.driveC
        case "z": root = URL(fileURLWithPath: "/")
        default: root = install.prefix.appendingPathComponent("dosdevices/\(letter):").resolvingSymlinksInPath()
        }
        return rest.isEmpty ? root : root.appendingPathComponent(rest)
    }

    static func pivotINI(_ install: Install) -> URL {
        install.gameDir.appendingPathComponent("config/pivot/pivot.ini")
    }

    /// pivot.ini with `[settings] root_path` aimed at this client's own polplugins\DATs, or nil
    /// when it needs nothing: the folder it names is there, it names none, or this client has no
    /// DATs folder of its own to point at.
    ///
    /// HorizonXI's client download carries the root of some Windows install (Daniel's Setup on
    /// 2026-10-15: `C:\Games\HorizonXI\polplugins\DATs`) and their launcher rewrites it at Play.
    /// Under this launcher that folder does not exist, so XIPivot would load none of HorizonXI's
    /// overlays even with the plugin on.
    static func pivotRootFixed(_ text: String, install: Install) -> String? {
        let fm = FileManager.default
        let own = install.gameDir.appendingPathComponent("polplugins/DATs")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: own.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        var lines = TextFile.lines(of: text)
        guard let n = lineIndex("root_path", section: "settings", in: lines),
              let eq = lines[n].firstIndex(of: "=") else { return nil }
        let current = lines[n][lines[n].index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard let named = macPath(forWine: current, in: install) else { return nil }
        if fm.fileExists(atPath: named.path, isDirectory: &isDir), isDir.boolValue { return nil }
        lines[n] = String(lines[n][...eq]) + install.gameDirWine + "\\polplugins\\DATs"
        return TextFile.join(lines, terminator: TextFile.terminator(of: text))
    }

    // MARK: - On disk

    /// What is wrong with this world's profile that Play puts right on the way in: one phrase
    /// each, empty when nothing is. For Preflight, read-only.
    static func problems(_ profile: String, in install: Install, loader: String, template: String) -> [String] {
        guard install.ashitaGeneration == .v4 else { return [] }
        let fm = FileManager.default
        let url = install.gameDir.appendingPathComponent("config/boot/\(install.bootProfileName(profile))")
        // Existence first, as ensureProfile decides it: a read of a missing file falls back to a
        // shell (Bridge.readFile), and Preflight runs often.
        guard fm.fileExists(atPath: url.path), let text = Credentials.readFile(at: url)
        else { return template.isEmpty ? [] : ["not made yet"] }
        var out: [String] = []
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: install.bootLoaderDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".exe") }
        let named = loaderName(in: text)
        if let want = loaderToName(named: named, present: present, worldLoader: loader) {
            out.append("boots \(named ?? "nothing"), not \(want)")
        }
        let lacks = missing(in: text, template: template, host: "", install: install)
        if !lacks.isEmpty { out.append("lacks " + lacks.map(\.description).joined(separator: ", ")) }
        if !template.isEmpty, fm.fileExists(atPath: pivotINI(install).path),
           let p = Credentials.readFile(at: pivotINI(install)), pivotRootFixed(p, install: install) != nil {
            out.append("pivot.ini's overlay folder is not in this client")
        }
        return out
    }

    /// Give an existing profile what it lacks, and point XIPivot at this client's overlays, for a
    /// world with a template. Returns one line per change, for launcher.log.
    static func complete(_ profile: String, in install: Install, template: String, host: String) -> [String] {
        guard !template.isEmpty else { return [] }
        let name = install.bootProfileName(profile)
        guard name.hasSuffix(".ini") else { return [] }
        var said: [String] = []
        let url = install.gameDir.appendingPathComponent("config/boot/\(name)")
        Credentials.profileLock.lock()
        if let text = Credentials.readFile(at: url) {
            let (out, added) = completed(text, template: template, host: host, install: install)
            if !added.isEmpty, Credentials.writeFile(out, to: url) {
                said.append("boot profile: added " + added.map(\.description).joined(separator: ", ")
                            + " to \(name)")
            }
        }
        Credentials.profileLock.unlock()
        if FileManager.default.fileExists(atPath: pivotINI(install).path),
           let p = Credentials.readFile(at: pivotINI(install)), let fixed = pivotRootFixed(p, install: install),
           Credentials.writeFile(fixed, to: pivotINI(install)) {
            said.append("pivot.ini: overlay folder set to \(install.gameDirWine)\\polplugins\\DATs")
        }
        return said
    }
}
