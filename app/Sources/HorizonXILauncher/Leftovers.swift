import Foundation
import Darwin
import AppKit

/// What an earlier run of this launcher left behind, and what becomes of it.
///
/// **Its game.** A game is spawned detached (Detach), so it outlives the launcher that started
/// it — on purpose: installing a launcher update relaunches the launcher under a running game.
/// The new launcher's sessions are empty, so the scan filed that client under "elsewhere": the
/// button said "Running…" with "Already running from another launcher." and offered no Stop, and
/// the RUNNING list had none either (Daniel, 2026-10-15: nothing on screen could end it).
/// A client is this launcher's own, and is adopted as a session with its Stop and exit watcher
/// (`Runner.adopt`), when all of these hold:
///
/// - no other launcher process is alive (`SingleInstance.otherLauncherAlive`), so nobody else
///   is tracking it;
/// - every process in its group runs this launcher's wine (`OwnWine`: the patched wine-coop,
///   the wrapper's own wine, or the x87 sidecar), and every one is a loader or injector: a group
///   that also holds a Windows program nobody can name (CatsEyeXI's own launcher run inside the
///   wrapper, an installer, a tool) was not started by Play, and its Stop would end that too;
/// - it is not in this launcher's own process group, which only holds what this process started
///   (a job such as CatsEyeXI's launcher), never what an earlier run left;
/// - it runs in the selected install's prefix: a process of its group whose environment can be
///   read (the x87 sidecar, which wine does not rewrite) names that `WINEPREFIX`; or, when none
///   can be read (no sidecar), every wineserver of this launcher's wine serves that prefix, and
///   one does — a wine client is always served by its own prefix's wineserver;
/// - its `--server` is a world on the list (`Sessions.refreshElsewhere`): the session writes its
///   window size into that world's boot profile when it ends, and a client of no listed world
///   has no profile of its own to write to;
/// - no job of this launcher (Repair, an update, CatsEyeXI's launcher) is under way: the world's
///   session may be the one running it.
///
/// Anything else — another wine (CrossOver, Whisky, XIV on Mac), another prefix, CatsEyeXI's own
/// launcher, a launcher process that is still alive — stays "Running…" without a Stop.
///
/// **Wine's own programs.** `services.exe`, `explorer.exe`, `winedevice.exe` and the rest run for
/// as long as their wineserver does, and when that wineserver is killed rather than stopped
/// they can outlive it, re-parented to launchd, serving nothing, for good (seen 2026-10-15 after
/// a loader was killed). With no wineserver of this launcher's wine left, and none serving the
/// selected prefix's socket, such a program (parent launchd) is ended quietly. Programs of other
/// wine installs are never looked at: only `LiveClients.Snapshot.ownSystemPrograms` count.
enum Leftovers {
    struct Orphan: Equatable {
        let group: pid_t
        let host: String
        /// Every process of the group the scan knows as wine (loader, sidecar), sorted.
        let pids: [pid_t]
    }

    /// The clients elsewhere that are this launcher's own (see the type's comment).
    /// `prefixOfGroup`: the `WINEPREFIX` read from a process of that group, where one could be
    /// read. `serverPrefixes`: this launcher's wine's wineservers -> the prefix each serves
    /// (nil when its environment could not be read). Prefixes are compared without a trailing
    /// slash.
    static func adoptable(_ snap: LiveClients.Snapshot, ownGroups: Set<pid_t>, ownHostsWithoutGroup: Set<String>,
                          prefix: String, prefixOfGroup: [pid_t: String], serverPrefixes: [pid_t: String?],
                          otherLauncherAlive: Bool, selfGroup: pid_t = getpgrp()) -> [Orphan] {
        guard !otherLauncherAlive, !prefix.isEmpty else { return [] }
        let want = trimmed(prefix)
        let loaders = snap.clients.filter(\.knownLoader)
        var out: [Orphan] = []
        for group in candidates(snap, ownGroups: ownGroups, ownHostsWithoutGroup: ownHostsWithoutGroup,
                                selfGroup: selfGroup).sorted() {
            if let p = prefixOfGroup[group] {
                guard trimmed(p) == want else { continue }
            } else {
                let served = Array(serverPrefixes.values)
                guard !served.isEmpty, served.allSatisfy({ $0.map(trimmed) == want }) else { continue }
            }
            let host = loaders.first { $0.group == group && !$0.host.isEmpty }?.host ?? ""
            let pids = snap.groups.filter { $0.value == group && snap.wine.contains($0.key) }.map(\.key).sorted()
            out.append(Orphan(group: group, host: host, pids: pids))
        }
        return out
    }

    /// wine's own programs left with no wineserver to serve them: this launcher's wine's, parent
    /// launchd, while no wineserver of this launcher's wine runs at all. When the selected
    /// prefix's server socket is still there and some wineserver (any wine's) is running, nothing
    /// is flagged: that socket may be live.
    static func serverless(_ snap: LiveClients.Snapshot, parentOf: (pid_t) -> pid_t?,
                           prefixSocketExists: Bool) -> [pid_t] {
        guard snap.ownWineservers.isEmpty else { return [] }
        if prefixSocketExists, !snap.wineservers.isEmpty { return [] }
        return snap.ownSystemPrograms.filter { parentOf($0) == 1 }.sorted()
    }

    /// The groups that could be an earlier run's game at all, before any prefix is read: a
    /// loader's group that is not one of this launcher's sessions (by group, or by host while one
    /// is starting), not this process's own group, and whose every client (the loader's sidecar
    /// included) runs this launcher's wine and is a loader or injector.
    static func candidates(_ snap: LiveClients.Snapshot, ownGroups: Set<pid_t>, ownHostsWithoutGroup: Set<String>,
                           selfGroup: pid_t = getpgrp()) -> Set<pid_t> {
        let loaders = snap.clients.filter {
            $0.knownLoader && $0.group > 1 && $0.group != selfGroup
                && !ownGroups.contains($0.group) && !ownHostsWithoutGroup.contains($0.host)
        }
        return Set(loaders.map(\.group)).filter { g in
            snap.clients.filter { $0.group == g }.allSatisfy { $0.ownWine && ($0.knownLoader || $0.injecting) }
        }
    }

    private static func trimmed(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The value of `key` in a `ps -E` line (the command, then the environment as `KEY=value`
    /// words). A value runs to the next ` NAME=` word, so a path with spaces survives. nil when
    /// the line has no such variable.
    static func envValue(_ key: String, in line: String) -> String? {
        let text = " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = text.range(of: " \(key)=", options: .backwards) else { return nil }
        let rest = text[r.upperBound...]
        if let next = rest.range(of: #" [A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    // MARK: - Reading the Mac (off the main actor)

    /// The wineserver socket folder for a prefix, as wine names it: `/tmp/.wine-<uid>/server-
    /// <st_dev hex>-<st_ino hex>` (read on the live client 2026-10-15: server-1000016-d7c73b for
    /// a prefix whose `stat` is dev 0x1000016, inode 0xd7c73b).
    static func serverDir(dev: UInt64, ino: UInt64, uid: uid_t = getuid()) -> String {
        "/tmp/.wine-\(uid)/server-\(String(dev, radix: 16))-\(String(ino, radix: 16))"
    }

    static func prefixSocketExists(_ prefix: String) -> Bool {
        var st = stat()
        guard stat(prefix, &st) == 0 else { return false }
        let dir = serverDir(dev: UInt64(UInt32(bitPattern: st.st_dev)), ino: UInt64(st.st_ino))
        return FileManager.default.fileExists(atPath: dir + "/socket")
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// `WINEPREFIX` of each pid whose environment `ps -E` can read (this user's, not rewritten by
    /// wine). Only that one variable is kept: these command lines carry the account password.
    static func prefixes(of pids: [pid_t]) -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-E", "-ww", "-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var found: [pid_t: String] = [:]
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let f = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard f.count == 2, let pid = pid_t(f[0]), let v = envValue("WINEPREFIX", in: String(f[1])) else { continue }
            found[pid] = OwnWine.resolve(v)
        }
        return found
    }

    /// Everything `adoptable` needs beyond the scan: the prefix each candidate group names and
    /// the prefix each of this launcher's wineservers serves. Read only for groups that could be
    /// adopted at all (elsewhere, all own wine), so a Mac with nothing left over pays nothing.
    static func evidence(_ snap: LiveClients.Snapshot, ownGroups: Set<pid_t>,
                         ownHostsWithoutGroup: Set<String>) -> (groups: [pid_t: String], servers: [pid_t: String?]) {
        let candidates = Leftovers.candidates(snap, ownGroups: ownGroups, ownHostsWithoutGroup: ownHostsWithoutGroup)
        guard !candidates.isEmpty else { return ([:], [:]) }
        let members = candidates.flatMap { snap.members(ofGroup: $0) }
        let env = prefixes(of: members + snap.ownWineservers)
        var groups: [pid_t: String] = [:]
        for g in candidates {
            if let p = snap.members(ofGroup: g).compactMap({ env[$0] }).first { groups[g] = p }
        }
        var servers: [pid_t: String?] = [:]
        for s in snap.ownWineservers { servers[s] = env[s] }
        return (groups, servers)
    }

    /// End `pids` (from `serverless`), quietly: checked again under the launch lock, so no launch
    /// of this launcher or another can be starting a wineserver meanwhile, then SIGTERM, and
    /// SIGKILL a few seconds later for any that is still the same leftover. Returns what was
    /// signalled. Never a pid the second scan does not flag again.
    static func endServerless(_ pids: [pid_t], prefix: String) async -> [pid_t] {
        guard !pids.isEmpty else { return [] }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let lock = LaunchLock.acquire() else { return [] }
        let snap = LiveClients.snapshot()
        let again = Set(serverless(snap, parentOf: parentPID, prefixSocketExists: prefixSocketExists(prefix)))
        let mine = pids.filter { again.contains($0) }.compactMap { p in snap.groups[p].map { (p, $0) } }
        for (pid, _) in mine { kill(pid, SIGTERM) }
        LaunchLock.release(lock)
        guard !mine.isEmpty else { return [] }
        for _ in 0..<6 {
            if !mine.contains(where: { Detach.isAlive($0.0) }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let now = LiveClients.snapshot()
        for (pid, group) in mine where Detach.isAlive(pid)
            && now.ownSystemPrograms.contains(pid) && now.groups[pid] == group {
            kill(pid, SIGKILL)
        }
        return mine.map(\.0)
    }
}
