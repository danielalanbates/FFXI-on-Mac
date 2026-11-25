import Foundation
import CryptoKit
import Darwin

/// Opt-in Windows configuration for one world, beside the existing drive on the same volume.
/// Game data and Wine remain shared. A fresh wineboot avoids cloning a live registry or copying
/// the multi-gigabyte client. The completion marker is published only after a successful boot,
/// runtime supplementation and wineserver exit.
/// Copyright (c) 2026 Bates LLC. All rights reserved.
enum WorldPrefix {
    static let namePrefix = "prefix-multiserver-"
    static let estimatedBytes: Int64 = 1_000_000_000
    static let headroomBytes: Int64 = 2_000_000_000
    private static let markerName = ".ffxi-on-mac-world-prefix-v1"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static func isManaged(name: String) -> Bool { name.hasPrefix(namePrefix) }

    /// JSON encoding keeps identities unambiguous even when a custom world contains punctuation
    /// or a path separator. Only a digest ever becomes a directory name.
    static func prefixName(base: Install, server: Server) -> String {
        let identity = [base.basePrefixName ?? base.prefixName, server.name,
                        LiveClients.normalize(server.host), server.bootProfile.lowercased()]
        let data = (try? JSONEncoder().encode(identity)) ?? Data()
        return namePrefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func markerURL(_ install: Install) -> URL { install.prefix.appendingPathComponent(markerName) }

    static func ready(_ install: Install) -> Bool {
        guard install.isWorldPrefix else { return true }
        let fm = FileManager.default
        return fm.fileExists(atPath: install.systemReg.path)
            && fm.fileExists(atPath: install.driveC.appendingPathComponent("windows/syswow64/ntdll.dll").path)
            && (try? String(contentsOf: markerURL(install), encoding: .utf8)) == install.prefixName + "\n"
    }

    static func prepare(base: Install, server: Server, stop: StopFlag? = nil,
                        log: @escaping @Sendable (String) -> Void) async throws {
        try await prepare(base: base, server: server, log: log,
                          availableBytes: availableBytes,
                          boot: { install in
                              await Task.detached(priority: .utility) {
                                  initialize(install, stop: stop)
                              }.value
                          }, stop: stop)
    }

    /// Dependency injection keeps transaction and low-space tests local; no test needs Wine,
    /// another application, a hosted server or the user's real preferences.
    static func prepare(base: Install, server: Server,
                        log: @escaping @Sendable (String) -> Void,
                        availableBytes: @Sendable (URL) -> Int64?,
                        boot: @escaping @Sendable (Install) async -> Bool,
                        lockURL: URL = LaunchLock.defaultPath, stop: StopFlag? = nil) async throws {
        guard server.multiServerPlay else { return }
        let target = base.forServer(server)
        if ready(target) { return }
        guard let lock = LaunchLock.acquire(at: lockURL) else {
            throw Failure("A game is starting or Windows configuration is busy. Try enabling multi-server play again in a moment.")
        }
        defer { LaunchLock.release(lock) }
        if ready(target) { return }
        let fm = FileManager.default
        // Only a newly owned staging drive is ever booted or removed. An incomplete final
        // drive may belong to an older build or a running Wine; never repair it by replacement.
        guard !fm.fileExists(atPath: target.prefix.path) else {
            throw Failure("This world's separate Windows configuration is incomplete. Choose another Wine installation or repair its separate drive before playing.")
        }
        guard fm.fileExists(atPath: base.sharedSupport.path) else {
            throw Failure("The Wine installation isn't available. Reconnect its drive and try again.")
        }
        guard let free = availableBytes(target.sharedSupport), free >= estimatedBytes + headroomBytes else {
            throw Failure("Multi-server play needs about 1 GB for this world's Windows configuration and 2 GB of free headroom on the Wine drive. Free space there and try again.")
        }
        try Task.checkCancellation()
        guard stop?.raised != true else { throw Failure("Multi-server setup stopped.") }
        let stagingName = "." + target.prefixName + ".preparing-" + UUID().uuidString
        var staging = target
        staging.prefixName = stagingName
        try fm.createDirectory(at: staging.prefix, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging.prefix) }
        log("==> creating \(server.name)'s separate Windows configuration (about 1 GB; game files are reused)")
        guard await boot(staging) else {
            throw Failure("The separate Windows configuration didn't finish. Your existing installation is unchanged; enable multi-server play again to retry.")
        }
        try Task.checkCancellation()
        guard stop?.raised != true else { throw Failure("Multi-server setup stopped.") }
        guard fm.fileExists(atPath: staging.systemReg.path),
              fm.fileExists(atPath: staging.driveC.appendingPathComponent("windows/syswow64/ntdll.dll").path) else {
            throw Failure("Wine did not finish creating the separate Windows drive. Enable multi-server play again to retry.")
        }
        try copyRuntimeSupplements(from: base, to: staging)
        guard let remaining = availableBytes(target.sharedSupport), remaining >= headroomBytes else {
            throw Failure("The Wine drive is low on free space. The unfinished separate configuration was removed; free space and try again.")
        }
        try Data((target.prefixName + "\n").utf8).write(to: markerURL(staging), options: .atomic)
        // Same-volume rename makes readiness atomic. Wine has exited before this point, so no
        // process retains the staging prefix or its temporary wineserver socket identity.
        guard rename(staging.prefix.path, target.prefix.path) == 0 else {
            throw Failure("Could not finish saving this world's Windows configuration. Check the Wine drive and try again.")
        }
        log("==> \(server.name)'s multi-server configuration is ready")
    }

    /// Fresh Wine configuration with the same Wine Play will use, no Mac window driver, and no
    /// Gecko/Mono prompts. Every process is owned and bounded; Stop/Quit affects this staging
    /// prefix only. In particular this never stops the ordinary drive's wineserver.
    private static func initialize(_ install: Install, stop: StopFlag?) -> Bool {
        let wine = Runner.playWine(install)
        let session = JobKill.Wine(server: wine.deletingLastPathComponent().appendingPathComponent("wineserver"),
                                   prefix: install.prefix)
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = install.prefix.path
        env["WINEDEBUG"] = "-all"
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml=;winemac.drv=d"
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        for key in ["DYLD_FALLBACK_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "WINEMSYNC", "WINEESYNC"] {
            env.removeValue(forKey: key)
        }
        func run(_ executable: URL, _ args: [String], limit: Double) -> Bool {
            guard stop?.raised != true else { return false }
            let p = Process(); p.executableURL = executable; p.arguments = args; p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            JobKill.track(p.processIdentifier, wine: session)
            defer { JobKill.untrack(p.processIdentifier) }
            let deadline = Date().addingTimeInterval(limit)
            while p.isRunning {
                if Date() >= deadline || stop?.raised == true {
                    JobKill.end(p.processIdentifier, wine: session)
                    let end = Date().addingTimeInterval(2)
                    while p.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.1) }
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    return false
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return p.terminationStatus == 0
        }
        defer { JobKill.endSession(session) }
        guard run(wine, ["wineboot", "-u"], limit: 300) else { return false }
        // These are independent prefix settings from install.sh: preserve the Option key as
        // Alt so enabling isolation does not silently break the player's macro shortcuts.
        for key in ["LeftOptionIsAlt", "RightOptionIsAlt"] {
            guard run(wine, ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", key,
                             "/d", "y", "/f"], limit: 30) else { return false }
        }
        JobKill.endSession(session)
        return run(session.server, ["-w"], limit: 30)
    }

    static func availableBytes(_ url: URL) -> Int64? {
        // Actual available blocks, never purgeable space: this user is also downloading a file.
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    /// CRT forwarders missing from a Wine build prevent Ashita/DXVK from loading. Preserve only
    /// these small runtime files, never hives, game data, DLL renderer overrides or user folders.
    static func copyRuntimeSupplements(from base: Install, to target: Install) throws {
        let fm = FileManager.default
        let baseName = base.basePrefixName ?? base.prefixName
        let sourcePrefix = base.sharedSupport.appendingPathComponent(baseName)
        let sources = [sourcePrefix.appendingPathComponent("drive_c/windows/syswow64"),
                       base.sharedSupport.appendingPathComponent("wine.cx32bak/lib32on64/wine")]
        let destination = target.driveC.appendingPathComponent("windows/syswow64")
        for source in sources {
            guard let files = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for file in files where file.lastPathComponent.lowercased().hasPrefix("api-ms-win-crt-")
                && file.pathExtension.lowercased() == "dll" {
                let out = destination.appendingPathComponent(file.lastPathComponent)
                guard !fm.fileExists(atPath: out.path) else { continue }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                try fm.copyItem(at: file, to: out)
            }
        }
    }
}
