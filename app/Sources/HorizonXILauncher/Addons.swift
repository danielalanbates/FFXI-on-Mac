import Foundation

/// Ashita's plugin and addon suite, managed the way HorizonXI's own Windows launcher manages it.
///
/// Ashita does not take a list of addons in its .ini. It runs `scripts/default.txt` after
/// injecting, and that script's `/load` and `/addon load` lines are what actually enable
/// anything. HorizonXI's launcher owns two marked blocks in that file and rewrites them; this
/// does the same, touching only what is between the markers so a hand-written custom section
/// below them survives untouched.
struct AddonSuite {
    struct Item: Identifiable, Hashable {
        var name: String
        var isPlugin: Bool
        var enabled: Bool
        /// What the addon says about itself. Read out of its own Lua header rather than written
        /// here, so it cannot drift from what is installed and is never this project's guess at
        /// what somebody else's addon does.
        var desc: String = ""
        var author: String = ""
        var version: String = ""
        var id: String { (isPlugin ? "p:" : "a:") + name.lowercased() }

        /// "1.25 · Thorny", or whichever half exists.
        var byline: String {
            [version, author].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// Ashita addons open with a block of `addon.name = '...'` assignments. Pull them out of the
    /// first few KB; anything past that is code, and reading whole files for a tooltip is waste.
    static func metadata(ofLuaAt url: URL) -> (desc: String, author: String, version: String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", "", "") }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1) else { return ("", "", "") }

        func field(_ names: [String]) -> String {
            for line in TextFile.lines(of: text) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("addon.") else { continue }
                for n in names where t.lowercased().hasPrefix("addon.\(n)") {
                    guard let eq = t.firstIndex(of: "=") else { continue }
                    var v = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    // strip one layer of quotes, and a trailing comment or semicolon
                    if let q = v.first, q == "'" || q == "\"" {
                        v.removeFirst()
                        if let end = v.firstIndex(of: q) { v = String(v[v.startIndex..<end]) }
                    }
                    // Lua line-continuation inside a quoted string leaves a dangling backslash.
                    while v.hasSuffix("\\") { v.removeLast() }
                    let cleaned = v.trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty { return cleaned }
                }
            }
            return ""
        }
        return (field(["desc", "description"]), field(["author"]), field(["version"]))
    }

    static let pluginsStart = "# --HORIZON_PLUGINS_START--"
    static let pluginsStop  = "# --HORIZON_PLUGINS_STOP--"
    static let addonsStart  = "# --HORIZON_ADDONS_START--"
    static let addonsStop   = "# --HORIZON_ADDONS_STOP--"
    private static let launcherManagedAddons: Set<String> = ["vanavoice", "vanaguide"]

    /// Plugins are DLLs and carry no readable metadata block, unlike addons, which declare
    /// theirs in Lua. Three of these are the plugin's own description string, read verbatim out
    /// of the binary; the rest are this project's one-line summaries, written only where the
    /// plugin's job is unambiguous. Anything not listed shows no description rather than a guess.
    static let pluginDescriptions: [String: String] = [
        // read out of the binaries themselves
        "deeps":      "Damage meters for Ashita v4.",
        "thirdparty": "Enables third-party program usage with Ashita.",
        "screenshot": "Saves screenshots of the game.",
        // written here; each states only what the plugin is for
        "addons":     "Runs Lua addons. Every addon below needs this one loaded.",
        "minimap":    "Draws a minimap of the current zone.",
        "nameplate":  "Controls the name plates drawn above characters and monsters.",
        "packetflow": "Server-side packet handling required by some private servers.",
        "sequencer":  "Plays and manages animation sequences.",
    ]

    static func scriptURL(_ i: Install, profile: String = "horizonxi.ini") -> URL {
        let script = Narration.scriptName(in: i, profile: profile)
        return i.gameDir.appendingPathComponent("scripts/\(script)")
    }

    /// Everything installed, with the ones the script currently loads marked enabled.
    static func scan(_ i: Install, profile: String = "horizonxi.ini") -> [Item] {
        let fm = FileManager.default
        let text = Credentials.readFile(at: scriptURL(i, profile: profile)) ?? ""
        let onPlugins = Set(loadedNames(in: text, start: pluginsStart, stop: pluginsStop,
                                        prefix: "/load "))
        let onAddons = Set(loadedNames(in: text, start: addonsStart, stop: addonsStop,
                                       prefix: "/addon load "))

        var out: [Item] = []
        // Plugins are DLLs. `winefix` is this project's own compatibility shim rather than a
        // user-facing feature, and turning it off breaks the game on wine, so it is not offered.
        let pluginDir = i.gameDir.appendingPathComponent("plugins")
        if let kids = try? fm.contentsOfDirectory(at: pluginDir, includingPropertiesForKeys: nil) {
            for k in kids where k.pathExtension.lowercased() == "dll" {
                let name = k.deletingPathExtension().lastPathComponent
                if name.lowercased() == "winefix" { continue }
                out.append(Item(name: name, isPlugin: true,
                                enabled: onPlugins.contains(name.lowercased()),
                                desc: pluginDescriptions[name.lowercased()] ?? ""))
            }
        }
        // Addons are directories containing <name>.lua.
        let addonDir = i.gameDir.appendingPathComponent("addons")
        if let kids = try? fm.contentsOfDirectory(at: addonDir, includingPropertiesForKeys: nil) {
            for k in kids {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: k.path, isDirectory: &isDir), isDir.boolValue
                else { continue }
                let name = k.lastPathComponent
                guard !launcherManagedAddons.contains(name.lowercased()) else { continue }
                guard fm.fileExists(atPath: k.appendingPathComponent("\(name).lua").path)
                else { continue }
                let meta = metadata(ofLuaAt: k.appendingPathComponent("\(name).lua"))
                out.append(Item(name: name, isPlugin: false,
                                enabled: onAddons.contains(name.lowercased()),
                                desc: meta.desc, author: meta.author, version: meta.version))
            }
        }
        return out.sorted { ($0.isPlugin ? 0 : 1, $0.name.lowercased())
                          < ($1.isPlugin ? 0 : 1, $1.name.lowercased()) }
    }

    private static func loadedNames(in text: String, start: String, stop: String,
                                    prefix: String) -> [String] {
        var out: [String] = []
        // A default.txt with no markers is the normal case for an install whose script was
        // written by hand or by a server other than HorizonXI. Reading only between markers
        // there found nothing, so every addon the player actually runs showed as disabled.
        // Without markers, the whole file is the managed region.
        let hasMarkers = text.contains(start) && text.contains(stop)
        var inside = !hasMarkers
        for raw in TextFile.lines(of: text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == start { inside = true; continue }
            if line == stop { inside = false; continue }
            guard inside, line.lowercased().hasPrefix(prefix) else { continue }
            out.append(String(line.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces).lowercased())
        }
        return out
    }

    /// Rewrite both managed blocks. Returns false if the script is missing its markers, in which
    /// case nothing is written — better to do nothing than to guess where the block belongs in a
    /// file the server's own launcher also edits.
    @discardableResult
    static func write(_ items: [Item], to install: Install,
                      profile: String = "horizonxi.ini") -> Bool {
        let url = scriptURL(install, profile: profile)
        guard let text = Credentials.readFile(at: url) else { return false }
        let eol = TextFile.terminator(of: text)
        var lines = TextFile.lines(of: text)

        // Addons live below plugins in the file, so replacing the lower block first keeps the
        // upper block's indices valid.
        let addonBody = items.filter { !$0.isPlugin && $0.enabled }
            .map { "/addon load \($0.name)" }
        let pluginBody = items.filter { $0.isPlugin && $0.enabled }
            .map { "/load \($0.name)" }

        if !(text.contains(pluginsStart) && text.contains(addonsStart)) {
            adoptScript(&lines)
        }

        guard replace(&lines, start: addonsStart, stop: addonsStop, with: addonBody),
              replace(&lines, start: pluginsStart, stop: pluginsStop, with: pluginBody)
        else { return false }

        return Credentials.writeFile(TextFile.join(lines, terminator: eol), to: url)
    }

    /// Put the managed markers into a script that has none, so the launcher can own the load
    /// lines from then on. The existing `/load` and `/addon load` lines are removed and the two
    /// empty blocks take their place; everything else in the file — `/wait`, `/ambient`, aliases,
    /// whatever the player added — keeps its position. `winefix` is deliberately left where it
    /// is: it is this project's compatibility shim, not a user-facing addon, and the UI never
    /// offers it, so it must not be swept into a block the UI rewrites.
    private static func adoptScript(_ lines: inout [String]) {
        var insertAt: Int? = nil
        var kept: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            let isLoad = (t.hasPrefix("/load ") || t.hasPrefix("/addon load "))
                && t != "/load winefix"
            let launcherManaged = t == "/addon load vanavoice" || t == "/addon load vanaguide"
            if isLoad && !launcherManaged {
                if insertAt == nil { insertAt = kept.count }
                continue
            }
            kept.append(line)
        }
        let at = insertAt ?? kept.count
        kept.insert(contentsOf: [pluginsStart, pluginsStop, addonsStart, addonsStop], at: at)
        lines = kept
    }

    private static func replace(_ lines: inout [String], start: String, stop: String,
                                with body: [String]) -> Bool {
        guard let a = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == start }),
              let b = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == stop }),
              a < b
        else { return false }
        lines.replaceSubrange((a + 1)..<b, with: body)
        return true
    }

    /// Ashita refuses any plugin built against a different interface version than its core, and
    /// the client's log is the only place that shows it. Surfacing it matters: a mismatch means
    /// the Lua host (`addons`) does not load either, so *every* addon silently does nothing while
    /// the script still lists them as loaded.
    static func mismatchedPlugins(_ i: Install) -> [String] {
        let logs = i.gameDir.appendingPathComponent("logs")
        guard let kids = try? FileManager.default.contentsOfDirectory(
                at: logs, includingPropertiesForKeys: [.contentModificationDateKey]),
              let newest = kids.filter({ $0.pathExtension == "txt" }).max(by: {
                  (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
                      ?? .distantPast
                  < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
                      ?? .distantPast
              }),
              let text = try? String(contentsOf: newest, encoding: .utf8)
        else { return [] }

        var out: [String] = []
        for line in text.split(separator: "\n") where line.contains("different interface version") {
            // ...Failed to load plugin 'addons'; plugin is compiled with...
            guard let a = line.range(of: "'"),
                  let b = line.range(of: "'", range: a.upperBound..<line.endIndex)
            else { continue }
            out.append(String(line[a.upperBound..<b.lowerBound]))
        }
        return Array(Set(out)).sorted()
    }
}

/// Addons this project recommends for the local LandSandBoat world and can fetch on request.
/// Only offered where the addon policy is unrestricted — nothing here is on HorizonXI's list.
enum LocalWorldAddons {
    struct Entry { let name, title, blurb, zip: String; let unzippedDir: String }

    /// SQLCommit/GMTools — an ImGui browser for LandSandBoat's `!` GM commands: 184 commands in
    /// 11 categories with typed inputs, item search by name, favorites, presets, per-job gear.
    /// MIT. Requires `chars.gmlevel` on the character (lsb-server.sh's test accounts have 99).
    static let gmtools = Entry(
        name: "gmtools",
        title: "GM Tools (SQLCommit)",
        blurb: "GUI for LandSandBoat's !commands — browse 184 GM commands by category, search items "
             + "by name, presets and job gear. Local world only; needs a GM-level character.",
        zip: "https://github.com/SQLCommit/GMTools/archive/refs/heads/main.zip",
        unzippedDir: "GMTools-main")

    static let all = [gmtools]

    static func isInstalled(_ e: Entry, in i: Install) -> Bool {
        FileManager.default.fileExists(
            atPath: i.gameDir.appendingPathComponent("addons/\(e.name)/\(e.name).lua").path)
    }

    /// Download the GitHub zip, unpack with ditto, move into addons/<name>, apply the JIT guard.
    /// Fails cleanly: nothing is left in `addons` unless the whole thing worked.
    static func install(_ e: Entry, into i: Install, log: @escaping (String) -> Void) async -> Bool {
        guard let url = URL(string: e.zip) else { return false }
        log("==> fetching \(e.title) from \(e.zip)")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("hxi-addon-\(e.name)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let (file, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else {
                log("==> download failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"); return false
            }
            let zip = tmp.appendingPathComponent("addon.zip")
            try fm.moveItem(at: file, to: zip)
            let unz = tmp.appendingPathComponent("x")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-xk", zip.path, unz.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { log("==> unzip failed"); return false }
            let src = unz.appendingPathComponent(e.unzippedDir)
            guard fm.fileExists(atPath: src.appendingPathComponent("\(e.name).lua").path) else {
                log("==> archive layout unexpected — no \(e.name).lua"); return false
            }
            let dst = i.gameDir.appendingPathComponent("addons/\(e.name)")
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            _ = LuaJITGuard.patch(dst.appendingPathComponent("\(e.name).lua"))
            log("==> installed addons/\(e.name)")
            return true
        } catch {
            log("==> \(e.title) install failed: \(error.localizedDescription)")
            return false
        }
    }
}
