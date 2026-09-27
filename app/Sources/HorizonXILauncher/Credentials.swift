import Foundation
import Security

/// Account handling. Remembered passwords live in a mode-600 Application Support JSON file and
/// are written to Ashita's mode-600 boot profile for autologin. The loader also receives the
/// password in its command line; see RELEASE-WHEN-STABLE.md for the unresolved exposure.
enum Credentials {
    private static let service = "org.batesai.horizonxi-on-mac"

    static var username: String {
        get { UserDefaults.standard.string(forKey: "account.user") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "account.user") }
    }

    // Accounts are per server on LandSandBoat worlds, so remember which account name was last
    // used on each world and recall it when the user switches back. Falls back to the global
    // last-used name so existing installs keep their filled-in field.
    static func username(forWorld world: String) -> String {
        UserDefaults.standard.string(forKey: "account.user.\(world)") ?? username
    }

    static func setUsername(_ name: String, forWorld world: String) {
        username = name
        UserDefaults.standard.set(name, forKey: "account.user.\(world)")
    }

    static var remember: Bool {
        get { UserDefaults.standard.bool(forKey: "account.remember") }
        set { UserDefaults.standard.set(newValue, forKey: "account.remember") }
    }

    // MARK: - Stored password
    //
    // This used to live in the login Keychain, which prompted for the Keychain password on
    // startup after every single rebuild: the ACL is bound to the signing identity, and each
    // build gets a fresh ad-hoc signature. That prompt is also the only thing the Keychain was
    // buying here, because Ashita cannot take a password any other way than as cleartext on the
    // boot loader's command line -- the launcher writes it into `config/boot/<profile>.ini`
    // (mode 600) on every launch, so the secret is already on disk in the clear either way.
    // Storing it in the app's own support directory at mode 600 is the same exposure with no
    // prompt. If this ever ships with a stable Developer ID, the Keychain becomes worth it
    // again; until then it is a prompt for nothing.

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }

    private static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: storeURL),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    private static func store(_ m: [String: String]) {
        guard let d = try? JSONEncoder().encode(m) else { return }
        try? d.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: storeURL.path)
    }

    /// Passwords are keyed per world AND user, because the same account name on two servers is
    /// two different accounts with two different passwords — keying on the name alone let a
    /// CatsEye login overwrite the HorizonXI password for "danielalanbates" (2026-08-19). The
    /// bare-username key survives as a read fallback for stores written before this.
    static func passwordKey(_ user: String, world: String) -> String {
        world.isEmpty ? user : "\(world)|\(user)"
    }

    static func savePassword(_ password: String, for user: String, world: String = "") {
        var m = load()
        let storageKey = passwordKey(user, world: world)
        if password.isEmpty { m.removeValue(forKey: storageKey) }
        else { m[storageKey] = password }
        store(m)
    }

    static func password(for user: String, world: String = "") -> String {
        let m = load()
        if let p = m[passwordKey(user, world: world)], !p.isEmpty { return p }
        if let p = m[user], !p.isEmpty { return p }
        return ""
    }

    static func deletePassword(for user: String) {
        var m = load()
        m.removeValue(forKey: user)
        store(m)
    }

    /// One-time pickup of a password already sitting in a boot profile, so moving to per-world
    /// storage does not silently present an empty password box. Reads only `--pass` from the live
    /// `command` line and adopts it under that world's key.
    static func adoptPasswordFromProfile(user: String, world: String, install: Install, profile: String) {
        let current = password(for: user, world: world)
        let url = install.gameDir.appendingPathComponent("config/boot/\(profile)")
        guard let text = readFile(at: url) else { return }
        guard let adoption = passwordAdoption(from: text, user: user, world: world,
                                              currentWorldPassword: current) else { return }
        savePassword(adoption.password, for: user, world: world)
    }

    static func passwordAdoption(from text: String, user: String, world: String,
                                 currentWorldPassword: String) -> (key: String, password: String)? {
        guard currentWorldPassword.isEmpty,
              let password = passwordInBootProfile(text) else { return nil }
        return (passwordKey(user, world: world), password)
    }

    private static func passwordInBootProfile(_ text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix(";"), line.hasPrefix("command"),
                  let r = line.range(of: "--pass ") else { continue }
            let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            let pass = rest.split(separator: " ").first.map(String.init) ?? ""
            return pass.isEmpty ? nil : pass
        }
        return nil
    }

    // MARK: - Ashita boot profile

    /// Write a file safely, falling back to headless shell copy if GUI process file write
    /// is denied by macOS TCC / Seatbelt sandbox on an external volume.
    @discardableResult
    static func writeFile(_ text: String, to target: URL) -> Bool {
        Bridge.writeFile(text, to: target)
    }

    /// Read a file safely, falling back to headless shell base64 read if GUI process file read
    /// is denied by macOS TCC / Seatbelt sandbox on an external volume.
    static func readFile(at url: URL) -> String? {
        Bridge.readFile(at: url)
    }

    /// Make sure `config/boot/<profile>` exists, seeding it from a profile that already works.
    ///
    /// A boot profile is mostly graphics and input settings that have nothing to do with which
    /// server it points at, so copying the configured one and letting `apply` rewrite the single
    /// `command` line gives a new world the same working setup rather than Ashita's bare example.
    /// Needed for the local server, whose profile no HorizonXI install ships.
    @discardableResult
    static func ensureProfile(_ profile: String, in install: Install) -> Bool {
        let fm = FileManager.default
        let dir = install.gameDir.appendingPathComponent("config/boot")
        let name = install.bootProfileName(profile)
        let target = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path) { return true }

        // Ashita v3 client (Eden): seed from whichever <name>.xml its own installer shipped —
        // those already name the right loader and the right server, so only the credentials in
        // `boot_command` need rewriting afterwards. Prefer the largest window size on offer.
        if name.hasSuffix(".xml") {
            // Eden ships one XML per window size (Eden800600 / Eden1024768 / Eden1600900).
            // Pick the largest by the `window_x` each one declares — sorting the *names* picks
            // "Eden800600" because '8' sorts after '1', i.e. the smallest window.
            let xmls = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".xml") }.sorted()
            let widest = xmls.max { a, b in
                func width(_ n: String) -> Int {
                    guard let t = readFile(at: dir.appendingPathComponent(n))
                    else { return 0 }
                    return Int(xmlSetting("window_x", in: t) ?? "0") ?? 0
                }
                return width(a) < width(b)
            }
            // FFEra's client ships Ashita v3 with **no config folder at all** — v3 normally
            // writes its boot XML from its own GUI configurator, which is not a pathway here.
            // So when there is nothing to seed from, write a minimal one.
            let text: String
            if let seed = widest,
               let t = readFile(at: dir.appendingPathComponent(seed)) {
                text = t
            } else {
                text = v3Profile(loader: defaultLoaderName(in: install),
                                 folder: install.bootLoaderDir.lastPathComponent)
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard writeFile(text, to: target) else { return false }
            return true
        }

        // Seed order: a profile the world's own installer shipped (any non-example .ini in the
        // folder), then HorizonXI's, then Ashita's examples. Whatever it came from, `file =` is
        // then made to name the boot loader that actually exists in this install's bootloader/
        // folder — a profile copied from horizonxi.ini into a CatsEye or Eden install would
        // otherwise try to run horizon-loader.exe, which is not there.
        var seeds = ["horizonxi.ini", "example-privateserver.ini", "example.ini"]
        if let kids = try? fm.contentsOfDirectory(atPath: dir.path) {
            let own = kids.filter { $0.hasSuffix(".ini") && !$0.hasPrefix("example") && $0 != "horizonxi.ini" }.sorted()
            seeds = own + seeds
        }
        for seed in seeds {
            let src = dir.appendingPathComponent(seed)
            guard fm.fileExists(atPath: src.path),
                  let text = readFile(at: src) else { continue }
            guard writeFile(text, to: target) else { continue }
            fixBootLoader(profile, in: install)
            return true
        }
        return false
    }


    /// The loader to boot when a client ships no profile naming one: whatever executable is
    /// actually sitting in this client's loader folder, preferring the names we know.
    static func defaultLoaderName(in install: Install) -> String {
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: install.bootLoaderDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".exe") }
        return knownLoaders.first { k in present.contains { $0.caseInsensitiveCompare(k) == .orderedSame } }
            ?? present.sorted().first ?? "xiloader.exe"
    }

    /// A minimal Ashita v3 boot profile. Only the settings v3 actually reads at boot; the rest
    /// of its schema is display defaults it fills in itself. `boot_command` is rewritten with the
    /// account by `apply` before every launch, exactly as for a v4 `.ini`.
    static func v3Profile(loader: String, folder: String, width: Int = 1600, height: Int = 900) -> String {
        """
        <?xml version="1.0" encoding="utf-8" standalone="yes"?>
        <settings>
          <setting name="config_name">FFXI on Mac</setting>
          <setting name="pol_version">2</setting>
          <setting name="window_x">\(width)</setting>
          <setting name="window_y">\(height)</setting>
          <setting name="windowed">True</setting>
          <setting name="boot_file">.\\\(folder)\\\(loader)</setting>
          <setting name="boot_command"></setting>
          <setting name="startup_script">Default.txt</setting>
          <setting name="test_server">False</setting>
          <setting name="auto_close">False</setting>
          <setting name="show_border">True</setting>
          <setting name="unhook_mouse">True</setting>
          <setting name="startpos_x">-1</setting>
          <setting name="startpos_y">-1</setting>
          <setting name="background_x">\(width)</setting>
          <setting name="background_y">\(height)</setting>
          <setting name="menu_x">\(width)</setting>
          <setting name="menu_y">\(height)</setting>
          <setting name="language">2</setting>
          <setting name="log_level">4</setting>
        </settings>
        """
    }


    /// Boot loaders this launcher knows how to find, in preference order, when a profile names one
    /// that is not in the install.
    static let knownLoaders = ["horizon-loader.exe", "xiloader.exe", "pol.exe", "catseye-loader.exe", "gxiloader.exe"]

    /// Make `[ashita.boot] file =` name a loader that exists in `bootloader/`.
    static func fixBootLoader(_ profile: String, in install: Install) {
        let fm = FileManager.default
        let name = install.bootProfileName(profile)
        // v3 profiles are seeded from the world's own XML, which already names its own loader.
        guard name.hasSuffix(".ini") else { return }
        let url = install.gameDir.appendingPathComponent("config/boot/\(name)")
        guard let text = readFile(at: url) else { return }
        let bl = install.bootLoaderDir
        let present = ((try? fm.contentsOfDirectory(atPath: bl.path)) ?? []).filter { $0.lowercased().hasSuffix(".exe") }
        guard !present.isEmpty else { return }
        let named = bootLoaderName(in: install, profile: profile) ?? ""
        if present.contains(where: { $0.caseInsensitiveCompare(named) == .orderedSame }) { return }
        let pick = knownLoaders.first { k in present.contains { $0.caseInsensitiveCompare(k) == .orderedSame } } ?? present.sorted()[0]
        let eol = TextFile.terminator(of: text)
        var replaced = false
        let lines = TextFile.lines(of: text).map { l -> String in
            let t = l.trimmingCharacters(in: .whitespaces)
            if !t.hasPrefix(";"), t.hasPrefix("file"), t.contains("="), !replaced {
                replaced = true
                return "file        = .\\\\bootloader\\\\\(pick)"
            }
            return String(l)
        }
        guard replaced else { return }
        writeFile(TextFile.join(lines, terminator: eol), to: url)
    }


    // MARK: - Ashita v3 boot profiles (XML)
    //
    // Eden's client is Ashita v3, whose boot config is
    //   <settings><setting name="boot_file">.\\ffxi-bootmod\\xiloader.exe</setting>
    //             <setting name="boot_command">--server play.edenxi.com</setting>...</settings>
    // rather than v4's `[ashita.boot] file = / command =` ini. Same two facts, different file
    // format, so everything below is the XML spelling of what the ini functions do. Rewritten
    // textually rather than through XMLDocument: these files are written by Ashita's own
    // configuration editor and round-tripping them through a parser reorders and re-indents the
    // whole thing for no reason.

    /// Value of `<setting name="key">…</setting>`, or nil.
    static func xmlSetting(_ key: String, in text: String) -> String? {
        guard let r = text.range(of: "<setting name=\"\(key)\">"),
              let end = text.range(of: "</setting>", range: r.upperBound..<text.endIndex)
        else { return nil }
        return String(text[r.upperBound..<end.lowerBound])
    }

    /// Replace `<setting name="key">…</setting>` in place. Returns nil when the key is absent —
    /// a v3 profile that does not declare the setting is not one we should be inventing keys in.
    static func xmlSetting(_ key: String, to value: String, in text: String) -> String? {
        guard let r = text.range(of: "<setting name=\"\(key)\">"),
              let end = text.range(of: "</setting>", range: r.upperBound..<text.endIndex)
        else { return nil }
        let escaped = value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return text.replacingCharacters(in: r.upperBound..<end.lowerBound, with: escaped)
    }

    /// Basename of the executable the profile boots (`[ashita.boot] file`), e.g. horizon-loader.exe.
    static func bootLoaderName(in install: Install, profile: String) -> String? {
        let name = install.bootProfileName(profile)
        let url = install.gameDir.appendingPathComponent("config/boot/\(name)")
        guard let text = readFile(at: url) else { return nil }
        if name.hasSuffix(".xml") {
            guard let v = xmlSetting("boot_file", in: text), !v.isEmpty else { return nil }
            let base = v.replacingOccurrences(of: "/", with: "\\")
                .split(separator: "\\").last.map(String.init) ?? v
            return base.isEmpty ? nil : base
        }
        for raw in TextFile.lines(of: text) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix(";"), t.hasPrefix("file"), let eq = t.firstIndex(of: "=") else { continue }
            let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            let name = v.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").last.map(String.init) ?? v
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// The `--server` the profile's boot command really passes the loader, which is what a
    /// running client is filed under. `apply` rewrites it only when a user and password are set,
    /// so it can differ from the world's Host field.
    static func bootServer(in install: Install, profile: String) -> String? {
        let name = install.bootProfileName(profile)
        guard let text = readFile(at: install.gameDir.appendingPathComponent("config/boot/\(name)"))
        else { return nil }
        var command: String?
        if name.hasSuffix(".xml") {
            command = xmlSetting("boot_command", in: text)
        } else {
            for raw in TextFile.lines(of: text) {
                let t = raw.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix(";"), t.hasPrefix("command"), let eq = t.firstIndex(of: "=") else { continue }
                command = String(t[t.index(after: eq)...]); break
            }
        }
        let tokens = (command ?? "").split(separator: " ").map(String.init)
        for (n, t) in tokens.enumerated() {
            if t == "--server", n + 1 < tokens.count { return tokens[n + 1] }
            if t.hasPrefix("--server=") { return String(t.dropFirst("--server=".count)) }
        }
        return nil
    }

    /// Rewrite the `command = ...` line of the Ashita boot profile with these credentials.
    /// Returns false if the profile is missing or unwritable.
    @discardableResult
    static func apply(user: String, password: String, to install: Install,
                      profile: String = "horizonxi.ini",
                      server: String = "play.horizonxi.com") -> Bool {
        let name = install.bootProfileName(profile)
        let url = install.gameDir.appendingPathComponent("config/boot/\(name)")
        guard var text = readFile(at: url) else { return false }

        if name.hasSuffix(".xml") {
            guard let out = xmlSetting("boot_command",
                                       to: "--server \(server) --user \(user) --pass \(password)",
                                       in: text)
            else { return false }
            return writeFile(out, to: url)
        }

        let line = "command     = --server \(server) --user \(user) --pass \(password)"
        var replaced = false
        let eol = TextFile.terminator(of: text)
        let lines = TextFile.lines(of: text).map { l -> String in
            // Only the live setting, never the commented examples.
            if !l.hasPrefix(";"), l.trimmingCharacters(in: .whitespaces).hasPrefix("command"),
               l.contains("=") , !replaced {
                replaced = true
                return line
            }
            return String(l)
        }
        text = TextFile.join(lines, terminator: eol)
        guard replaced else { return false }
        return writeFile(text, to: url)
    }

    /// Set `key = value` lines in the boot profile, leaving commented examples alone.
    /// Used for the per-renderer overrides — `behaviorflags.fpu_preserve` in particular.
    static func applyIniOverrides(_ overrides: [String: String], to install: Install,
                                  profile: String) {
        guard !overrides.isEmpty else { return }
        let name = install.bootProfileName(profile)
        // v3's XML has no `[ffxi.direct3d8]` section, so there is nothing to override there.
        guard name.hasSuffix(".ini") else { return }
        let url = install.gameDir.appendingPathComponent("config/boot/\(name)")
        guard let text = readFile(at: url) else { return }

        let eol = TextFile.terminator(of: text)
        let out = TextFile.lines(of: text).map { l -> String in
            let line = String(l)
            guard !line.hasPrefix(";"), line.contains("=") else { return line }
            let key = line.split(separator: "=", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let v = overrides[key] else { return line }
            // keep the column alignment the file already uses
            let pad = max(1, 48 - key.count)
            return key + String(repeating: " ", count: pad) + "= " + v
        }.joined(separator: eol)

        writeFile(out, to: url)
    }
}
