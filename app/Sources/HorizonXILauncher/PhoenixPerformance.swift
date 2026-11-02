// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation

/// The shared performance settings resolved for Phoenix's isolated prefix. No credentials.
struct PhoenixPerformance {
    var environment: [String: String]
    var renderer: String
    var rendererTitle: String
    var dlls: [String: URL]
    var dxvkConfig: URL?

    var usesDXVK: Bool { renderer == "metal" }

    func gameEnvironment(prefix: URL) -> [String: String] {
        var env = environment
        env["WINEPREFIX"] = prefix.path
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        // Process-local overrides also take precedence over old registry settings.
        let overrides = usesDXVK ? "d3d8,d3d9=n" : "d3d8,d3d9=b"
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml=;" + overrides
        env.removeValue(forKey: "ROSETTA_DISABLE_AOT")
        return env
    }

    /// Called only while this prefix is idle. Keep vendor game files untouched: Windows
    /// finds native DLLs in syswow64, with original prefix DLLs backed up once.
    func prepareFiles(prefix: URL) throws {
        guard usesDXVK else { return }
        let fm = FileManager.default
        guard Set(dlls.keys) == ["d3d8.dll", "d3d9.dll"], let dxvkConfig,
              fm.fileExists(atPath: dxvkConfig.path),
              dlls.values.allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
            throw NSError(domain: "PhoenixPerformance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled Metal renderer files are missing."])
        }
        let system = prefix.appendingPathComponent("drive_c/windows/syswow64")
        let backup = prefix.appendingPathComponent("drive_c/dll-backup/phoenix-performance")
        try fm.createDirectory(at: system, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for (name, source) in dlls {
            let target = system.appendingPathComponent(name)
            if fm.contentsEqual(atPath: source.path, andPath: target.path) { continue }
            let original = backup.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: original.path) {
                try fm.copyItem(at: target, to: original)
            }
            try Data(contentsOf: source).write(to: target, options: .atomic)
        }
        let config = prefix.appendingPathComponent("drive_c/dxvk-cache/dxvk.conf")
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: dxvkConfig).write(to: config, options: .atomic)
    }
}
