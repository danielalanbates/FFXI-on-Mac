// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation
import Darwin

/// Ending a job and everything it started: the Stop beside the main button, and Quit.
///
/// Daniel, 2026-10-15: "the launcher is supposed to be a completely self contained system". A
/// Setup that hung at "registering FFXI COM servers" had no way out but the terminal: its
/// regsvr32 sat on a crash-looping explorer.exe, and quitting the launcher left the script, the
/// wine programs and their wineserver running. Every job a Runner starts (a script, curl, ditto,
/// an installer) is tracked here with the Wine prefix it works in, if any, so Stop and Quit end
/// its child processes, then the job, then that prefix's Wine session.
enum JobKill {
    /// The Wine session a job runs in: its prefix, and the wineserver of the Wine it runs.
    struct Wine: Sendable, Equatable {
        let server: URL
        let prefix: URL
    }

    /// Every process `root` started, children before their parents (one `ps`, read-only).
    static func descendants(of root: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var kids: [pid_t: [pid_t]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 2, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { continue }
            kids[ppid, default: []].append(pid)
        }
        var order: [pid_t] = []
        var queue = kids[root] ?? []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard pid != root, !order.contains(pid) else { continue }
            order.append(pid)
            queue += kids[pid] ?? []
        }
        return order.reversed()
    }

    /// SIGTERM to what `root` started, then to `root` itself (so a script's own trap tidies up
    /// after them), then the prefix's Wine session.
    static func end(_ root: pid_t?, wine: Wine?) {
        if let root, root > 1 {
            for pid in descendants(of: root) { kill(pid, SIGTERM) }
            kill(root, SIGTERM)
        }
        if let wine { endSession(wine) }
    }

    /// `wineserver -k` for the prefix: every Wine program in it ends. At most `limit` seconds.
    static func endSession(_ w: Wine, limit: Double = 5) {
        guard FileManager.default.isExecutableFile(atPath: w.server.path) else { return }
        let k = Process()
        k.executableURL = w.server
        k.arguments = ["-k"]
        k.environment = ["WINEPREFIX": w.prefix.path]
        k.standardOutput = FileHandle.nullDevice
        k.standardError = FileHandle.nullDevice
        guard (try? k.run()) != nil else { return }
        let end = Date().addingTimeInterval(limit)
        while k.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        if k.isRunning { k.terminate() }
    }

    // MARK: - What is running, for Quit

    private static let lock = NSLock()
    private static var live: [pid_t: Wine?] = [:]

    static func track(_ pid: pid_t, wine: Wine?) {
        lock.lock(); defer { lock.unlock() }
        live[pid] = .some(wine)
    }

    static func untrack(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        live[pid] = nil
    }

    /// Quit: every job still running ends, with what it started and its Wine session. The
    /// quit question (LauncherDelegate) has already said the job stops.
    static func endAll() {
        lock.lock()
        let jobs = live
        live = [:]
        lock.unlock()
        var sessions: [Wine] = []
        for (pid, wine) in jobs {
            end(pid, wine: nil)
            if let w = wine, !sessions.contains(w) { sessions.append(w) }
        }
        for w in sessions { endSession(w, limit: 3) }
    }
}

/// Raised by Stop, read by work this process does itself on another thread (a copy's ditto,
/// Wine's prefix update), which then ends its own child and says it stopped.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raisedValue = false

    var raised: Bool { lock.lock(); defer { lock.unlock() }; return raisedValue }
    func raise() { lock.lock(); raisedValue = true; lock.unlock() }
    func reset() { lock.lock(); raisedValue = false; lock.unlock() }
}
