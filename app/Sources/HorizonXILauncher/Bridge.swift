import Foundation

/// Bridge for executing headless commands and filesystem operations outside the LaunchServices
/// app sandbox / Seatbelt restrictions on external volumes (/Volumes/).
enum Bridge {

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Execute a command synchronously via headless osascript (do shell script).
    /// This runs outside the app's seatbelt sandbox domain via com.apple.OSAScriptingProvider.
    @discardableResult
    static func runShell(_ command: String) -> (status: Int32, output: String) {
        let scriptURL = URL(fileURLWithPath: "/tmp/hxi-cmd-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\n\(command)\n"
        guard (try? script.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil else {
            return (-1, "")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let osaScript = "do shell script \"/bin/sh '\(scriptURL.path)'\""
        osa.arguments = ["-e", osaScript]
        let pipe = Pipe()
        osa.standardOutput = pipe
        osa.standardError = pipe
        guard (try? osa.run()) != nil else { return (-1, "") }
        osa.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: data, encoding: .utf8) ?? ""
        return (osa.terminationStatus, outStr)
    }

    /// Read file content as UTF-8 string, falling back to base64 via headless shell
    /// if direct file read is blocked by external volume sandbox permissions.
    static func readFile(at url: URL) -> String? {
        if let direct = try? String(contentsOf: url, encoding: .utf8) {
            return direct
        }
        let res = runShell("/usr/bin/base64 < \(shellQuote(url.path))")
        guard res.status == 0,
              let data = Data(base64Encoded: res.output.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    /// Write text to target file, falling back to headless shell copy if direct file write
    /// is blocked by external volume sandbox permissions.
    @discardableResult
    static func writeFile(_ text: String, to target: URL) -> Bool {
        if (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        }
        if (try? text.write(to: target, atomically: false, encoding: .utf8)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let res = runShell("/bin/cp -f \(shellQuote(tmp.path)) \(shellQuote(target.path)) && /bin/chmod 600 \(shellQuote(target.path))")
        return res.status == 0
    }
}
