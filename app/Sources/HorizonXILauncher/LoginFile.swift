import Foundation
import Darwin

/// PR #35: the password stays off the loader's command line, where `ps` shows it to anything on
/// the Mac for the whole session, and out of the boot profile on disk.
///
/// Loaders of the xiloader lineage (LandSandBoat's xiloader, horizon-loader, the AscensionXI and
/// Phoenix builds; measured 2026-11-24 on every client on this Mac) take `--json-file <path>`
/// (alias `--json`) and read `"username"` and `"password"` from it. Play writes one such file per
/// launch, here: the user's own temporary folder (macOS makes it 0700), never the game's folder,
/// which may sit on a shared or synced drive. The file is 0600 and is deleted once the loader is
/// up (`Runner`), or by the next Play at the latest. Loaders without the option (Gaia XI's,
/// Scythe's, DriftwoodXI's old one) keep `--pass`.
///
/// The loader runs under Wine and opens the file through `Z:`, which every prefix maps to `/`.
/// The Windows path must be one token on the boot command line, so a folder with a space or a
/// non-ASCII character in its path is not used (the caller then falls back to `--pass`).
enum LoginFile {
    static let option = "--json-file"
    /// Both spellings xiloader accepts; only `option` is ever written.
    static let options = ["--json-file", "--json"]
    static let namePrefix = "login-"

    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ffxi-on-mac-login", isDirectory: true)
    }

    // MARK: - Does this loader take it?

    private static var supportCache: [String: (size: Int, modified: Date, yes: Bool)] = [:]
    private static let cacheLock = NSLock()

    /// True when the loader binary carries the `--json-file` option. Read once per file version
    /// (size + modification date), since a client update can replace the loader.
    static func supported(loader: URL) -> Bool {
        let path = loader.path
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (a[.size] as? NSNumber)?.intValue, size > 0,
              let modified = a[.modificationDate] as? Date else { return false }
        cacheLock.lock()
        if let c = supportCache[path], c.size == size, c.modified == modified { cacheLock.unlock(); return c.yes }
        cacheLock.unlock()
        let yes = (try? Data(contentsOf: loader, options: .mappedIfSafe))?.range(of: Data(option.utf8)) != nil
        cacheLock.lock(); supportCache[path] = (size, modified, yes); cacheLock.unlock()
        return yes
    }

    // MARK: - Writing and finding

    /// The loader's view of `url`: `Z:` plus the POSIX path with backslashes. Nil when the path
    /// would not survive as one command-line token.
    static func windowsPath(_ url: URL) -> String? {
        let p = url.path
        guard p.hasPrefix("/"), p.allSatisfy({ $0.isASCII && $0 != " " && $0 != "\"" && $0 != "\t" })
        else { return nil }
        return "Z:" + p.replacingOccurrences(of: "/", with: "\\")
    }

    /// Write a one-time login file and return what the boot command passes `--json-file`, or nil
    /// (nothing is left behind) when it could not be written safely.
    static func write(user: String, password: String, in folder: URL = folder) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // An existing folder keeps its own mode: it must be ours and private.
        guard let a = try? fm.attributesOfItem(atPath: folder.path),
              (a[.type] as? FileAttributeType) == .typeDirectory,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
        else { return nil }
        let url = folder.appendingPathComponent(namePrefix + UUID().uuidString + ".json")
        guard let win = windowsPath(url),
              let data = try? JSONSerialization.data(withJSONObject: ["username": user, "password": password])
        else { return nil }
        // O_EXCL | O_NOFOLLOW: a fresh file, never one someone placed (or linked) there first.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var done = 0
            while done < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
        close(fd)
        guard ok else { try? fm.removeItem(at: url); return nil }
        return win
    }

    /// The file a `--json-file` value names, when it is one of ours (in `folder`, our name).
    static func localURL(windowsPath value: String, in folder: URL = folder) -> URL? {
        guard value.hasPrefix("Z:\\") || value.hasPrefix("z:\\") else { return nil }
        let posix = String(value.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        let url = URL(fileURLWithPath: posix)
        guard url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              url.lastPathComponent.hasPrefix(namePrefix), url.pathExtension == "json" else { return nil }
        return url
    }

    /// The login-file value of a boot command (`--json-file` or `--json`), if it has one.
    static func value(in command: String) -> String? {
        for o in options { if let v = Credentials.option(o, in: command) { return v } }
        return nil
    }

    /// `command` without its `--json-file`/`--json` option and value.
    static func strip(from command: String) -> String {
        var out: [Substring] = []
        var skip = false
        for t in command.split(separator: " ", omittingEmptySubsequences: false) {
            if skip { skip = false; continue }
            if options.contains(String(t)) { skip = true; continue }
            if options.contains(where: { t.hasPrefix($0 + "=") }) { continue }
            out.append(t)
        }
        return out.joined(separator: " ")
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete our login files older than `age` seconds (0: all of them). A launch removes its own
    /// file within minutes; anything older is left from a launcher that quit or crashed first.
    static func removeStale(olderThan age: TimeInterval = 600, in folder: URL = folder) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let now = Date()
        for n in names where n.hasPrefix(namePrefix) && n.hasSuffix(".json") {
            let u = folder.appendingPathComponent(n)
            let made = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date ?? .distantPast
            if age <= 0 || now.timeIntervalSince(made) >= age { try? fm.removeItem(at: u) }
        }
    }
}
