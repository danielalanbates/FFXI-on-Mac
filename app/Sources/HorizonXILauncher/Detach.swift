import Foundation

/// Start a process that outlives this app.
///
/// Why this exists
/// ---------------
/// Everything the launcher started used to die with it. Two separate reasons, and both had to
/// go:
///
/// 1. **Session membership.** `Foundation.Process` children inherit the launcher's process
///    group and session, so anything that signals the group -- a force-quit, a crash, the
///    Dock's "Force Quit" -- takes the game with it.
/// 2. **The x87 sidecar.** It is attached to the running client for the whole session and does
///    not exit on its own, so the launcher terminated it when the game ended. Quitting the
///    launcher therefore killed the sidecar, and without it the client drops back to Rosetta's
///    stock x87 speed -- the difference between 28 fps and 11 (docs/X87-WALL.md). Surviving the
///    quit is no good if the game is left crawling.
///
/// AppleScript's `do shell script` starts the background child outside the launcher's session.
/// Keep this ancestry: direct posix_spawn caused external-drive/launch failures on the tested
/// install (docs/LAUNCH-DEATH.md). The shell script removes itself after its interpreter opens it.
enum Detach {

    /// Spawn `exe` detached. Returns the child's pid, or nil if the spawn failed.
    ///
    /// `stdoutPath`, when given, receives both stdout and stderr, appended. The launcher tails
    /// that file rather than holding a pipe -- a pipe would tie the child's writes to this
    /// process being alive to drain them, which is the coupling being removed.
    @discardableResult
    static func spawn(_ exe: URL, args: [String], env: [String: String],
                      cwd: URL?, stdoutPath: String?) -> pid_t? {
        // osascript reports the background PID before /bin/sh necessarily opens its script.
        // The child must remove the script itself; unlinking it on this function's return
        // races the interpreter and silently loses a successful-looking spawn.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hxi-launch-\(UUID().uuidString).sh")
        var script = "#!/bin/sh\n/bin/rm -f -- \(Bridge.shellQuote(scriptURL.path))\n"
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            script += "export \(k)=\(Bridge.shellQuote(v))\n"
        }
        if let cwd {
            script += "cd \(Bridge.shellQuote(cwd.path)) || exit $?\n"
        }
        let cmd = ([exe.path] + args).map(Bridge.shellQuote).joined(separator: " ")
        if let out = stdoutPath {
            script += "exec \(cmd) >> \(Bridge.shellQuote(out)) 2>&1\n"
        } else {
            script += "exec \(cmd) >/dev/null 2>&1\n"
        }
        // The script may contain launch credentials. Give it owner-only permissions from
        // creation, rather than first writing a world-readable file and chmodding afterward.
        guard FileManager.default.createFile(atPath: scriptURL.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else { return nil }
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: scriptURL) } }

        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let shell = "/bin/sh \(Bridge.shellQuote(scriptURL.path)) >/dev/null 2>&1 & echo $!"
        let escapedShell = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osaScript = "do shell script \"\(escapedShell)\""
        osa.arguments = ["-e", osaScript]
        let pipe = Pipe()
        osa.standardOutput = pipe
        guard (try? osa.run()) != nil else { return nil }
        osa.waitUntilExit()
        guard osa.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(outStr), pid > 0 else {
            return nil
        }
        handedOff = true
        return pid
    }

    /// Is this pid still alive? `kill(pid, 0)` asks without sending anything.
    ///
    /// A detached child is not ours any more, so `Process.isRunning` and `terminationHandler`
    /// are both unavailable -- this is what replaces them.
    static func isAlive(_ pid: pid_t) -> Bool {
        // A detached child is still *this process's* child until the launcher exits (a new
        // session does not reparent it), so when it dies it lingers as a zombie until someone
        // waits on it -- and `kill(pid, 0)` succeeds on a zombie. Found 2026-08-27: the previous
        // day's injector sat `<defunct>` for 12 hours, this returned true the whole time, the
        // "injector exited" callback never fired, and the Play button stayed at RUNNING until
        // the app was quit. Reap first; only a live process survives both checks.
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Arrange for `victim` to be killed once no process matching `whilePattern` is left.
    ///
    /// The sidecar has to die when the game does, and the launcher can no longer be the thing
    /// that notices -- it may not be running. So the job is handed to a detached shell, which
    /// costs one sleeping `sh` per session and survives the launcher exactly as the game does.
    static func killWhenGone(victim: pid_t, whilePattern: String) {
        let script = "while /usr/bin/pgrep -qf \(whilePattern.replacingOccurrences(of: "'", with: "")) ; "
                   + "do /bin/sleep 2; done; /bin/kill \(victim) 2>/dev/null"
        spawn(URL(fileURLWithPath: "/bin/sh"), args: ["-c", script],
              env: ["PATH": "/usr/bin:/bin"], cwd: nil, stdoutPath: nil)
    }
}
