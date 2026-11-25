import Foundation

/// The small dylibs the launcher inserts into wine with `DYLD_INSERT_LIBRARIES`: audiofollow
/// (`audio/audiofollow.c`) and gamewindow (`window/gamewindow.c`). Finding them, and adding them to
/// the game's environment.
///
/// GOTCHA for anyone reworking the launch: the variable does NOT survive an exec through `arch(1)`
/// or any other system binary, nor through the hardened-runtime x87 sidecar — dyld strips DYLD_*
/// across those. The launch exports it in the shell script that execs wine (Detach), and
/// gamewindow.dylib carries it across the sidecar's exec (see that file's header).
enum InsertedLibrary {
    static let key = "DYLD_INSERT_LIBRARIES"

    /// The bundled `<name>.dylib`, or the repo's build of it under `swift run`. Returns nil unless
    /// the file exists *and* carries the architecture wine will be running as — a
    /// `DYLD_INSERT_LIBRARIES` naming a missing or wrong-arch file is a good way to turn a working
    /// launch into a failed one, and nothing these libraries do justifies that risk.
    static func bundled(_ name: String) -> URL? {
        var candidate: URL?
        if let u = Bundle.main.url(forResource: name, withExtension: "dylib") {
            candidate = u
        } else {
            let dev = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // HorizonXILauncher
                .deletingLastPathComponent()   // Sources
                .deletingLastPathComponent()   // app
                .appendingPathComponent("Resources/\(name).dylib")
            if FileManager.default.fileExists(atPath: dev.path) { candidate = dev }
        }
        guard let url = candidate, hasX86Slice(url) else { return nil }
        return url
    }

    /// Add `path` to the list in `env`, after whatever is already there; never twice.
    static func insert(_ path: String, into env: inout [String: String]) {
        guard let existing = env[key], !existing.isEmpty else { env[key] = path; return }
        if existing.split(separator: ":").contains(Substring(path)) { return }
        env[key] = existing + ":" + path
    }

    /// Wine on Apple Silicon runs under Rosetta, so the slice that has to be present is x86_64.
    /// Read the Mach-O header directly rather than shelling out to `lipo`, which is not
    /// guaranteed to exist on a Mac without the developer tools.
    static func hasX86Slice(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4096), head.count >= 8 else { return false }

        func be32(_ o: Int) -> UInt32 {
            UInt32(head[o]) << 24 | UInt32(head[o + 1]) << 16 | UInt32(head[o + 2]) << 8 | UInt32(head[o + 3])
        }
        func le32(_ o: Int) -> UInt32 {
            UInt32(head[o + 3]) << 24 | UInt32(head[o + 2]) << 16 | UInt32(head[o + 1]) << 8 | UInt32(head[o])
        }

        let cpuTypeX86_64: UInt32 = 0x0100_0007
        let magic = be32(0)

        // Fat binary (the normal case — the build scripts lipo arm64 + x86_64 together).
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            let count = Int(be32(4))
            let entry = magic == 0xCAFE_BABE ? 20 : 32
            for i in 0..<count {
                let off = 8 + i * entry
                guard off + 4 <= head.count else { break }
                if be32(off) == cpuTypeX86_64 { return true }
            }
            return false
        }
        // Thin Mach-O: cputype is the second word, little-endian on everything we ship to.
        if magic == 0xCFFA_EDFE || magic == 0xCEFA_EDFE { return le32(4) == cpuTypeX86_64 }
        return false
    }
}
