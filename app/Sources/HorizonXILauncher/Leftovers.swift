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
///
/// **A Wine session that already died (b70).** On 2026-10-16 at 14:15:40 the X10 drive holding
/// wine-coop and prefix10 dropped off USB for ~3 s. The session's wineserver died (SIGBUS on its
/// own paged-out code) and every Wine program of that session was left spinning, parent launchd,
/// its executable path unreadable (`proc_pidpath` fails on a revoked mount): `ownSystemPrograms`
/// never saw them, `serverless` gave up beside the next session's wineserver, and five were still
/// running next to it at 16:37. `stale` finds them by what they map instead (see there); only
/// wine's own programs, never a loader or an injector, which only the player's Stop ends.
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

    /// The server folder of `prefix`, from its `stat` (symlinks followed, as wine's own `stat` of
    /// WINEPREFIX does); nil when the prefix cannot be read (its drive is not there).
    static func serverDir(forPrefix prefix: String) -> String? {
        var st = stat()
        guard stat(prefix, &st) == 0 else { return nil }
        return serverDir(dev: UInt64(UInt32(bitPattern: st.st_dev)), ino: UInt64(st.st_ino))
    }

    static func prefixSocketExists(_ prefix: String) -> Bool {
        guard let dir = serverDir(forPrefix: prefix) else { return false }
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

    // MARK: - A Wine session that already died (b70)

    /// What a process is for as long as it lives: when it started (a reused pid starts later),
    /// whose it is, and its parent. `PROC_PIDTBSDINFO`, the read `parentPID` makes, and the
    /// monotonic start from `proc_pid_rusage`.
    struct ProcID: Hashable {
        let startSec: UInt64
        let startUsec: UInt64
        /// When it started on the monotonic clock, in seconds (`ri_proc_start_abstime`, mach
        /// time, sleep not counted). The start above is the wall clock at fork (XNU's `p_start`),
        /// which a manual change or a correction on wake can step back; this one cannot.
        let startUptime: Double
        let uid: uid_t
        let ppid: pid_t

        /// `startUptime` defaults to the wall-clock start: fixtures, where both clocks agree.
        init(startSec: UInt64, startUsec: UInt64 = 0, startUptime: Double? = nil, uid: uid_t, ppid: pid_t) {
            self.startSec = startSec; self.startUsec = startUsec; self.uid = uid; self.ppid = ppid
            self.startUptime = startUptime ?? Double(startSec) + Double(startUsec) / 1_000_000
        }

        /// Seconds since 1970.
        var start: Double { Double(startSec) + Double(startUsec) / 1_000_000 }
    }

    /// nil when either read fails (the process is gone, or not this user's): nothing is decided
    /// about a process that cannot be read.
    static func procID(_ pid: pid_t) -> ProcID? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var usage = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &usage) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard read == 0 else { return nil }
        return ProcID(startSec: info.pbi_start_tvsec, startUsec: info.pbi_start_tvusec,
                      startUptime: seconds(machTime: usage.ri_proc_start_abstime),
                      uid: info.pbi_uid, ppid: pid_t(info.pbi_ppid))
    }

    private static let timebase: (numer: Double, denom: Double) = {
        var t = mach_timebase_info_data_t()
        guard mach_timebase_info(&t) == KERN_SUCCESS, t.denom != 0 else { return (1, 1) }
        return (Double(t.numer), Double(t.denom))
    }()

    /// Mach time (`mach_absolute_time`, `ri_proc_start_abstime`) in seconds.
    static func seconds(machTime t: UInt64) -> Double {
        Double(t) * timebase.numer / timebase.denom / 1_000_000_000
    }

    /// Now, on the clock `ProcID.startUptime` is read on.
    static func uptimeNow() -> Double { seconds(machTime: mach_absolute_time()) }

    /// What F_GETLK says about a server folder's lock.
    enum LockRead: Equatable {
        /// Someone holds it: a wineserver, for a folder of wine's.
        case holder(pid_t)
        /// The file is there and nobody holds it.
        case unlocked
        /// There is no lock file.
        case missing
        /// It could not be asked: the file would not open for another reason (EMFILE, EINTR,
        /// EACCES), F_GETLK failed, or it named a holder with no pid.
        case failed
    }

    /// Who holds the lock of the server folder `dir`. Asked the way wine asks (`kill_lock_owner`,
    /// server/request.c): F_GETLK for a write lock on the first byte of `<dir>/lock`, which a
    /// wineserver holds for its whole life. Opened read-only and never created, and F_GETLK only
    /// reports: nothing is taken. Read on the live session 2026-10-16: WRLCK, pid 44464, its
    /// wineserver. (A lock this process held itself would not show; it never holds one.)
    static func lockOwner(_ dir: String) -> LockRead {
        let fd = open(dir + "/lock", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .failed }
        defer { close(fd) }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 1
        guard fcntl(fd, F_GETLK, &fl) == 0 else { return .failed }
        if fl.l_type == Int16(F_UNLCK) { return .unlocked }
        return fl.l_pid > 0 ? .holder(fl.l_pid) : .failed
    }

    /// Who serves a server folder, as `staleInstance` needs it.
    enum ServerLock: Equatable {
        /// No wineserver holds the lock: nothing serves that prefix.
        case free
        /// A wineserver holds it.
        case held(pid_t, ProcID)
        /// Not known: decide nothing.
        case unreadable
    }

    /// Free only when F_GETLK says nobody holds the lock, or when the lock file and the socket
    /// are both gone (a wineserver that exits unlinks its socket; one that crashes leaves both,
    /// and its lock then reads unlocked, as at 16:25 on 2026-10-16). Anything else is
    /// unreadable, never free (b70 review): wine writes the lock file once, at start, and macOS's
    /// tmp_cleaner (`/usr/libexec/tmp_cleaner`, daily at 00:00) deletes files in /tmp untouched
    /// for 3 days, so a session played for 4 days has its socket (not a regular file, kept) and
    /// no lock file; and an open can fail for a moment (EMFILE, EINTR). Read as free, every
    /// program of that live session would pass the rule.
    static func serverLock(_ dir: String) -> ServerLock {
        switch lockOwner(dir) {
        case .holder(let pid): return procID(pid).map { ServerLock.held(pid, $0) } ?? .unreadable
        case .unlocked: return .free
        case .missing:
            if access(dir + "/socket", F_OK) == 0 { return .unreadable }
            return errno == ENOENT ? .free : .unreadable
        case .failed: return .unreadable
        }
    }

    /// The wineserver holding a server folder's lock, by pid and start time: a server that died
    /// and one started in its place are two different holders even if the pid came round again.
    struct LockHolder: Equatable {
        let pid: pid_t
        let startSec: UInt64
        let startUsec: UInt64
    }

    /// The wineserver holding `dir`'s lock, with its start time; nil unless one could be read
    /// holding it (`serverLock`). Off the main actor: one open, one fcntl, one identity read.
    static func lockHolder(_ dir: String) -> LockHolder? {
        guard case .held(let pid, let id) = serverLock(dir) else { return nil }
        return LockHolder(pid: pid, startSec: id.startSec, startUsec: id.startUsec)
    }

    /// What became of a wineserver once seen holding a lock (`lockHolder`).
    enum ServerState: Equatable {
        case running
        /// No process has its pid any more, or the one that has it started at another time.
        case gone
        /// It could not be read: nothing is said.
        case unknown
    }

    /// Asked of the process itself, never of the lock file again: that file can vanish under a
    /// healthy wineserver (tmp_cleaner, see `serverLock`) and an open can fail for a moment, and
    /// either read as "gone" would offer Force Stop on a game that is fine (b70 review). One
    /// identity read; `kill(pid, 0)`, which sends nothing, only when that read fails.
    static func state(of holder: LockHolder, identity: (pid_t) -> ProcID? = Leftovers.procID,
                      alive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> ServerState {
        if let id = identity(holder.pid) {
            return id.startSec == holder.startSec && id.startUsec == holder.startUsec ? .running : .gone
        }
        return alive(holder.pid) ? .unknown : .gone
    }

    /// `path` is `dir` or inside it, by whole path components (`/tmp/x2/a` is not inside
    /// `/tmp/x`), with `/tmp` and `/private/tmp` the same folder: wine names its server folder
    /// under `/tmp`, the kernel reports a mapped file's path under `/private/tmp`.
    static func isUnder(_ path: String, dir: String) -> Bool {
        func canonical(_ p: String) -> String {
            let s = trimmed(p)
            return s == "/private/tmp" || s.hasPrefix("/private/tmp/") ? String(s.dropFirst("/private".count)) : s
        }
        let p = canonical(path), d = canonical(dir)
        guard d.hasPrefix("/"), d != "/" else { return false }
        return p == d || p.hasPrefix(d + "/")
    }

    /// The folder of every file `pid` maps, from one walk of its regions (PROC_PIDREGIONPATHINFO,
    /// one call each: 778-3784 for one Wine program, measured 2026-10-16); nil when not even its
    /// first region could be read. Off the main actor.
    static func mappedFolders(of pid: pid_t) -> Set<String>? {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        var folders: Set<String> = []
        var read = false
        // A bound, not a limit anyone meets: a Wine program has a few thousand regions.
        for _ in 0..<200_000 {
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size) == size else { break }
            read = true
            let path = withUnsafeBytes(of: &info.prp_vip.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if let slash = path.lastIndex(of: "/"), slash != path.startIndex { folders.insert(String(path[..<slash])) }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            guard next > address else { break }
            address = next
        }
        return read ? folders : nil
    }

    /// Does `pid` map a file in `dir`? Every Wine process maps `tmpmap-*` files from its
    /// wineserver's folder (lsof on the 2026-10-16 orphans and on the live session beside them).
    static func mapsFile(under dir: String, pid: pid_t) -> Bool {
        mappedFolders(of: pid)?.contains(where: { isUnder($0, dir: dir) }) ?? false
    }

    /// `mapsFile` as the rule asks it: at most one walk per process (pid and identity) for its
    /// life, whatever the folders. A refresh every 15 s otherwise walked each of a live session's
    /// programs, and another Wine install's, once for every folder whose lock was free (b70
    /// review). What a program maps is kept once it is `staleMargin` old: by then a Wine program
    /// maps its own wineserver's folder, and it never maps another's.
    static func mapsFileOnce(under dir: String, pid: pid_t, id: ProcID) -> Bool {
        let key = Stale(pid: pid, id: id)
        let folders: Set<String>
        if let known = walked[key] {
            folders = known
        } else {
            guard let read = mappedFolders(of: pid) else { return false }
            if id.startUptime < uptimeNow() - staleMargin { walked[key] = read }
            folders = read
        }
        return folders.contains { isUnder($0, dir: dir) }
    }

    /// A table the refresh, Play and the after-exit cleanup share, each from its own thread. Kept
    /// small: emptied past 256 entries, which costs one walk, or one log line, again.
    final class Remembered<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Stale: Value] = [:]

        subscript(key: Stale) -> Value? {
            get { lock.lock(); defer { lock.unlock() }; return values[key] }
            set {
                lock.lock(); defer { lock.unlock() }
                if values.count >= 256 { values.removeAll() }
                values[key] = newValue
            }
        }
    }

    /// The folders each program maps (`mapsFileOnce`).
    static let walked = Remembered<Set<String>>()
    /// What `signalStale` sent SIGKILL to. One still running after it (stuck in the kernel on the
    /// drive that went away) is not flagged again: otherwise every refresh signalled it again,
    /// wrote another "ended" line and held the launch lock for the scan (b70 review).
    static let killed = Remembered<Bool>()

    /// How much earlier than the wineserver holding its prefix a Wine program must have started
    /// to count as another session's. A wineserver's own programs start after it (the `wine`
    /// process that started it, a moment before, has never been a system program), so a minute
    /// is only slack.
    static let staleMargin: Double = 60

    /// The rule, for one of wine's own programs (`LiveClients.wineSystemPrograms`) and one server
    /// folder: it is this user's, re-parented to launchd, of a Wine session no wineserver serves
    /// any more — none holds the folder's lock, or the one that does started more than
    /// `staleMargin` after it, on the wall clock and on the monotonic one — and it maps a file in
    /// that folder (`maps`, asked last: it is the costly test). A Wine client connects to its
    /// wineserver once, at start, and never again, so nothing that started before the current
    /// wineserver can be one of its clients. A program of another prefix, or of another Wine
    /// install, maps another folder and never matches.
    static func staleInstance(_ id: ProcID?, uid: uid_t = getuid(), lock: ServerLock, maps: () -> Bool) -> Bool {
        guard let id, id.uid == uid, id.ppid == 1 else { return false }
        switch lock {
        case .free: break
        case .held(_, let owner):
            // Both clocks: the wall clock alone, stepped back between a wineserver's start and its
            // programs', would make them look older than it (b70 review).
            guard id.start < owner.start - staleMargin, id.startUptime < owner.startUptime - staleMargin
            else { return false }
        case .unreadable: return false
        }
        return maps()
    }

    /// One program `stale` flagged, with the identity it had then: what every signal is checked
    /// against.
    struct Stale: Hashable {
        let pid: pid_t
        let id: ProcID
    }

    /// Of the scan's Wine system programs (`Snapshot.systemPrograms`: this launcher's wine's, and
    /// any whose executable can no longer be read), the ones `staleInstance` flags for any of
    /// `dirs` (server folders). Each folder's lock is read before the programs and again after,
    /// and a program is kept only where it is unchanged: a wineserver that took a free folder
    /// meanwhile has programs that started after the first read, which must never be judged
    /// against "free" (b70 review). `skip`: what is never looked at again (`killed`). Stops at
    /// `deadline` (Play waits at most `Runner.staleEndLimit`) with what it has. Reads the Mac
    /// unless told otherwise: off the main actor.
    static func stale(_ snap: LiveClients.Snapshot, dirs: Set<String>,
                      identity: (pid_t) -> ProcID? = Leftovers.procID,
                      lock: (String) -> ServerLock = Leftovers.serverLock,
                      maps: (String, pid_t, ProcID) -> Bool = { Leftovers.mapsFileOnce(under: $0, pid: $1, id: $2) },
                      skip: (Stale) -> Bool = { Leftovers.killed[$0] != nil },
                      until deadline: DispatchTime = .distantFuture) -> [Stale] {
        guard !dirs.isEmpty, !snap.systemPrograms.isEmpty else { return [] }
        let locks = dirs.sorted().map { (dir: $0, lock: lock($0)) }
        var found: [(stale: Stale, dir: String, lock: ServerLock)] = []
        for pid in snap.systemPrograms {
            guard DispatchTime.now() < deadline else { break }
            guard let id = identity(pid) else { continue }
            let s = Stale(pid: pid, id: id)
            guard !skip(s) else { continue }
            if let d = locks.first(where: { d in staleInstance(id, lock: d.lock, maps: { maps(d.dir, pid, id) }) }) {
                found.append((stale: s, dir: d.dir, lock: d.lock))
            }
        }
        var again: [String: ServerLock] = [:]
        return found.filter { f in
            let now = again[f.dir] ?? lock(f.dir)
            again[f.dir] = now
            return now == f.lock
        }.map(\.stale)
    }

    /// The signals for what `stale` flagged, with the Mac injectable (`--selftest-leftovers`).
    /// Each pid is read again right before every signal and must still be the same process
    /// (start time, owner, parent): a pid the system has since handed to something else is never
    /// signalled. One whose executable can no longer be read (its drive went away under it) gets
    /// SIGKILL at once: it can run no shutdown code, and one winedevice ignored SIGTERM on
    /// 2026-10-16. The rest get SIGTERM, then SIGKILL `grace` seconds later. Every SIGKILL is
    /// remembered (`killedOne`, `killed`). Returns what was signalled.
    static func signalStale(_ flagged: [Stale], grace: Double,
                            identity: (pid_t) -> ProcID? = Leftovers.procID,
                            pathGone: (pid_t) -> Bool = { LiveClients.executablePath(of: $0) == nil },
                            send: (pid_t, Int32) -> Void = { _ = kill($0, $1) },
                            sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                            killedOne: (Stale) -> Void = { Leftovers.killed[$0] = true }) -> [pid_t] {
        var signalled: [pid_t] = []
        var termed: [Stale] = []
        for s in flagged where identity(s.pid) == s.id {
            if pathGone(s.pid) {
                send(s.pid, SIGKILL)
                killedOne(s)
            } else {
                send(s.pid, SIGTERM)
                termed.append(s)
            }
            signalled.append(s.pid)
        }
        guard !termed.isEmpty else { return signalled }
        sleep(grace)
        for s in termed where identity(s.pid) == s.id {
            send(s.pid, SIGKILL)
            killedOne(s)
        }
        return signalled
    }

    /// The rule run again under the launch lock, so no launch is half-way through starting a
    /// wineserver: taken here unless the caller holds it already (Play: a second
    /// `LaunchLock.acquire` in the same process fails, the flock being per open file, and this
    /// would silently do nothing). Another holder (a launch in another launcher, a Stop's
    /// wineserver flush, Repair) means: not now. Returns what it flagged.
    static func flagStale(dirs: Set<String>, lockHeld: Bool, lockAt: URL = LaunchLock.defaultPath,
                          flag: (Set<String>) -> [Stale] = { Leftovers.stale(LiveClients.snapshot(), dirs: $0) }) -> [Stale] {
        guard !dirs.isEmpty else { return [] }
        if lockHeld { return flag(dirs) }
        guard let lock = LaunchLock.acquire(at: lockAt) else { return [] }
        defer { LaunchLock.release(lock) }
        return flag(dirs)
    }

    /// End what a Wine session that already died left running in `dirs` (the refresh, the
    /// after-exit cleanup): `flagStale`, taking the launch lock, then `signalStale` once it is let
    /// go, so a Play pressed during the grace is not refused as "Busy". The rule is decided under
    /// the lock; a signal, pinned to the identity read then, can land after it is released.
    /// Blocks for up to `grace` seconds: never on the main actor. Returns what was signalled.
    static func endStale(dirs: Set<String>, grace: Double = 1.5, lockAt: URL = LaunchLock.defaultPath,
                         flag: (Set<String>) -> [Stale] = { Leftovers.stale(LiveClients.snapshot(), dirs: $0) },
                         signal: ([Stale], Double) -> [pid_t] = { Leftovers.signalStale($0, grace: $1) }) -> [pid_t] {
        let flagged = flagStale(dirs: dirs, lockHeld: false, lockAt: lockAt, flag: flag)
        guard !flagged.isEmpty else { return [] }
        return signal(flagged, grace)
    }

    /// What Play's bounded scan flagged (`Runner.launch`), handed back from the thread Play waits
    /// on for at most `Runner.staleEndLimit`.
    final class Flagged: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Stale] = []

        var result: [Stale] {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// The launcher.log line for what `endStale` ended.
    static func endedLine(_ pids: [pid_t]) -> String {
        "i  ended \(pids.count) wine program(s) of a Wine session that had already died (pid "
            + pids.map(String.init).joined(separator: ",") + ")"
    }
}
