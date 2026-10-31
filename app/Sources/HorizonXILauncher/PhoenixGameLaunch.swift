// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import Foundation
import CryptoKit

/// Uses Phoenix's own loader and authenticated token, in a prefix which contains no other world.
/// No optional addons are loaded. The short-lived loader JSON is private and removed after use.
enum PhoenixGameLaunch {
    static let root = PhoenixInstaller.root
    static var prefix: URL { root.appendingPathComponent("prefix") }
    static var client: URL { root.appendingPathComponent("client") }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        for key in ["DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "WINELOADER", "WINESERVER", "WINEARCH", "ROSETTA_X87_PATH", "ROSETTA_DISABLE_AOT"] { env.removeValue(forKey: key) }
        return env
    }

    /// Checks the real loader, not the injector (Ashita-cli exits after injection).
    static var running: Bool {
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-f", "[p]hoenix-loader.exe"]
        check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return true }
        check.waitUntilExit(); return check.terminationStatus == 0
    }

    private static func diagnostic(_ text: String) {
        guard ProcessInfo.processInfo.environment["PHOENIX_SETUP_DIAGNOSTICS"] == "1" else { return }
        try? FileHandle.standardError.write(contentsOf: Data(("Phoenix setup: " + text + "\n").utf8))
    }

    private static func run(_ executable: URL, _ args: [String], limit: TimeInterval = 300, acceptedExitCodes: Set<Int32> = [0]) -> Bool {
        let process = Process(); process.executableURL = executable; process.arguments = args
        process.environment = environment(); process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let diagnostics = ProcessInfo.processInfo.environment["PHOENIX_SETUP_DIAGNOSTICS"] == "1"
        let errorFile = root.appendingPathComponent("setup-" + executable.lastPathComponent + ".log")
        var errors: FileHandle?
        if diagnostics, FileManager.default.createFile(atPath: errorFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            errors = try? FileHandle(forWritingTo: errorFile); process.standardError = errors
        }
        defer {
            try? errors?.close()
            if diagnostics, let data = try? Data(contentsOf: errorFile), data.count < 32768,
               let text = String(data: data, encoding: .utf8) { diagnostic(text) }
        }
        do { try process.run() } catch {
            diagnostic("\(executable.lastPathComponent) failed to start, code \((error as NSError).code)"); return false
        }
        let deadline = Date().addingTimeInterval(limit)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning { process.terminate(); diagnostic("\(executable.lastPathComponent) timed out"); return false }
        diagnostic("\(executable.lastPathComponent) exited \(process.terminationStatus)")
        return acceptedExitCodes.contains(process.terminationStatus)
    }

    static func prepare(wine: URL, bootstrapWine: URL, report: @escaping (String) -> Void) async -> Bool {
        guard !running else { diagnostic("a Phoenix loader is already running"); return false }
        guard PhoenixInstaller.ready else { diagnostic("client installation is incomplete"); return false }
        let fm = FileManager.default
        func stopOwnServer() -> Bool {
            guard !running else { return false }
            // A prefix just initialized by the wrapper and one previously played through
            // CrossOver may have different wineserver protocols. Use the matching binary.
            for executable in [wine, bootstrapWine] {
                let server = executable.deletingLastPathComponent().appendingPathComponent("wineserver")
                // Wine returns 1 when -k finds no server. A following -w verifies the prefix is
                // actually quiescent; an idle prefix must not be treated as failed setup.
                if run(server, ["-k"], limit: 30, acceptedExitCodes: [0, 1]),
                   run(server, ["-w"], limit: 30) { return true }
            }
            return false
        }
        let kernel = prefix.appendingPathComponent("drive_c/windows/syswow64/kernel32.dll")
        if !fm.fileExists(atPath: kernel.path) {
            report("Preparing Phoenix’s separate Wine environment…")
            guard stopOwnServer(), run(bootstrapWine, ["wineboot", "-u"]), fm.fileExists(atPath: kernel.path) else { return false }
        }
        let runtime = prefix.appendingPathComponent("drive_c/windows/syswow64/vcruntime140.dll")
        let runtimeMarker = root.appendingPathComponent(".vcrun2022-native-installed")
        if !fm.fileExists(atPath: runtime.path) || !fm.fileExists(atPath: runtimeMarker.path) {
            report("Installing Phoenix’s Microsoft x86 runtime…")
            let installer = root.appendingPathComponent("VC_redist.x86.exe")
            // Official Microsoft download and digest checked 2026-10-30. A changed package fails closed.
            let url = URL(string: "https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe")!
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == 13953392,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64" else { return false }
                try data.write(to: installer, options: .atomic)
            } catch { return false }
            guard stopOwnServer(), run(bootstrapWine, [installer.path, "/install", "/quiet", "/norestart"]), fm.fileExists(atPath: runtime.path) else { return false }
            do { try Data("Microsoft VC x86 installed; package SHA256 0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64\n".utf8).write(to: runtimeMarker, options: .atomic) } catch { return false }
        }
        // Wine versions cannot share a live wineserver. Only this isolated prefix is stopped;
        // no game has been launched in it, and the running-loader guard precedes all maintenance.
        guard stopOwnServer() else { return false }
        return run(wine, ["wineboot", "-u"])
    }

    static func token(from data: Data, response: HTTPURLResponse) -> String? {
        guard response.statusCode == 200,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = body["data"] as? [String: Any], let token = result["token"] as? String,
              !token.isEmpty, token.utf8.count <= 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return token
    }

    static func windowsPath(_ url: URL) -> String { "Z:" + url.path.replacingOccurrences(of: "/", with: "\\") }

    static func start(gameToken: String, wine: URL) throws -> pid_t {
        guard !running, PhoenixInstaller.ready else { throw PhoenixInstaller.SetupError.extraction }
        let fm = FileManager.default
        let privateDir = root.appendingPathComponent("private")
        try fm.createDirectory(at: privateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateDir.path)
        let config = privateDir.appendingPathComponent("launch-\(UUID().uuidString).json")
        let payload: [String: Any] = ["server": "play.phoenix-xi.com", "authport": 54231, "dataport": 54230,
            "viewport": 54001, "profileport": 51220, "hide": true, "login_token": gameToken, "language": 1]
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: config.path, contents: try JSONSerialization.data(withJSONObject: payload), attributes: [.posixPermissions: 0o600]) else { throw PhoenixInstaller.SetupError.extraction }
        do {
            // Start from the vendor's installed profile, preserving its documented graphics defaults.
            let template = client.appendingPathComponent("config/boot/example-privateserver.ini")
            var text = try String(contentsOf: template, encoding: .utf8)
            func section(_ name: String, _ values: [String: String]) {
                // Replace only keys in this section; leave the remainder of the vendor template intact.
                var lines = text.components(separatedBy: .newlines)
                let header = "[\(name)]"
                guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
                    text += "\n\(header)\n" + values.keys.sorted().map { "\($0) = \(values[$0]!)" }.joined(separator: "\n") + "\n"; return
                }
                let end = lines.indices.dropFirst(first + 1).first { lines[$0].hasPrefix("[") } ?? lines.count
                var used = Set<String>()
                for index in (first + 1)..<end {
                    let key = lines[index].split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if let value = values[key] { lines[index] = "\(key) = \(value)"; used.insert(key) }
                }
                lines.insert(contentsOf: values.keys.sorted().filter { !used.contains($0) }.map { "\($0) = \(values[$0]!)" }, at: end)
                text = lines.joined(separator: "\n")
            }
            section("ashita.launcher", ["name": "Phoenix XI on Mac"])
            section("ashita.boot", ["file": ".\\bootloader\\phoenix-loader.exe", "command": "--json \"\(windowsPath(config))\"", "script": "phoenix-mac.txt"])
            section("ashita.polplugins", ["sandbox": "1", "pivot": "1"])
            section("sandbox.paths", ["ffxi": windowsPath(client.appendingPathComponent("SquareEnix/FINAL FANTASY XI")), "pol": windowsPath(client.appendingPathComponent("SquareEnix/PlayOnlineViewer")), "common": "C:\\Program Files (x86)\\Common Files"])
            section("ffxi.registry", ["0001": "1280", "0002": "720", "0003": "1280", "0004": "720"])
            try text.write(to: client.appendingPathComponent("config/boot/phoenix-mac.ini"), atomically: true, encoding: .utf8)
            try "# Phoenix native launch; no optional addons.\n".write(to: client.appendingPathComponent("scripts/phoenix-mac.txt"), atomically: true, encoding: .utf8)
            try "[settings]\ndebug_log=false\n[overlays]\n0=EraDATs\n[cache]\nenabled=false\n".write(to: client.appendingPathComponent("config/pivot/pivot.ini"), atomically: true, encoding: .utf8)
            let log = privateDir.appendingPathComponent("game-\(UUID().uuidString).log")
            guard fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PhoenixInstaller.SetupError.extraction }
            var env = environment()
            env["PHOENIX_LAUNCH_CONFIG"] = config.path
            // Reuse the launcher's established detached bridge, including a real disk file for
            // output. Foundation ancestry and /dev/null are not the measured working path.
            let script = "( /bin/sleep 120; /bin/rm -f -- \"$PHOENIX_LAUNCH_CONFIG\" ) >/dev/null 2>&1 & exec \"$@\""
            guard let pid = Detach.spawn(URL(fileURLWithPath: "/bin/sh"), args: ["-c", script, "phoenix-launch", wine.path,
                    windowsPath(client.appendingPathComponent("Ashita-cli.exe")), "phoenix-mac.ini"],
                    env: env, cwd: client, stdoutPath: log.path) else { throw PhoenixInstaller.SetupError.extraction }
            // The injector exits before the resumed loader necessarily reads JSON. A detached,
            // single delayed cleanup preserves the handoff and still runs after this app quits.
            return pid
        } catch { try? fm.removeItem(at: config); throw error }
    }
}
