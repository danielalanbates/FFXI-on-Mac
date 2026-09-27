import Foundation
import AppKit

/// What a launch was asked to do from the command line: `--world <name>` and `--play`. The
/// same value drives a launch's own arguments and a request another launch forwarded to it
/// (`SingleInstance`), so both take the one path through `ContentView.handleCommand`.
struct LaunchCommand: Equatable {
    var world: String?
    var play = false

    init(world: String? = nil, play: Bool = false) {
        self.world = world
        self.play = play
    }

    /// Anything else on the command line (`-psn_…`, `-NSDocumentRevisionsDebugMode`, a flag
    /// this build does not know) is not a request and is not forwarded.
    init(_ args: [String]) {
        if let w = args.firstIndex(of: "--world"), w + 1 < args.count { world = args[w + 1] }
        play = args.contains("--play")
    }

    var arguments: [String] {
        (world.map { ["--world", $0] } ?? []) + (play ? ["--play"] : [])
    }
}

/// Never more than one launcher (Daniel's standing rule). A second launch hands its request
/// to the running one and exits before it has touched anything: no window, no log rotation,
/// no scan, no file of the game's.
///
/// The running launcher is the one holding an flock on `instance.lock` in Application
/// Support. flock is atomic, so of two launches started together exactly one gets it, and it
/// is released by the kernel when its holder exits or crashes. A launch that cannot get it:
///
///  1. writes its request (`LaunchCommand.arguments`) to `instance/requests/<uuid>.json`, mode
///     0600, via a temporary name and a rename, so it is never read half-written;
///  2. posts a distributed notification named for this bundle, so the holder looks now
///     rather than on its next one-second poll (the notification carries nothing: the file is
///     the request, and only files in this user's own Application Support, owned by this user,
///     are read);
///  3. waits up to five seconds for the holder to take the file (it deletes it), activates the
///     holder, and exits 0. Unanswered, it withdraws the file; if the file is already gone the
///     holder took it after all (exit 0). Otherwise it takes the lock itself if the holder has
///     since quit, and else exits 1 saying so.
///
/// The holder registers for the notification and drains the folder once at start-up, so a
/// request written between the flock and the registration is not lost. A request older than
/// `maxRequestAge` is thrown away unread: a `--play` from a launch that gave up must not start
/// a game minutes later. The same age limit holds after a request is taken: one no window has
/// acted on by then is dropped and logged. Once the app is quitting nothing more is taken.
///
/// A launcher from before this existed holds no lock. One is recognised by bundle id or by
/// executable path and, since it cannot take a request, this launch activates it and exits
/// without doing anything else (1 when there was a `--play`/`--world` to hand over).
///
/// `--selftest-*` and `--check` are exempt: they open no window, touch nothing, exit on their
/// own (`Headless.runIfAsked` runs first), and must work while a launcher is open.
enum SingleInstance {
    static let bundleID = "org.batesai.horizonxi-on-mac"
    static let notificationName = Notification.Name("org.batesai.horizonxi-on-mac.request")
    /// Posted in this process once a forwarded request is queued in `pending`.
    static let arrived = Notification.Name("org.batesai.horizonxi-on-mac.request-arrived")
    static let maxRequestAge: TimeInterval = 30

    static let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HorizonXI-on-Mac/instance", isDirectory: true)

    static func isExempt(_ args: [String]) -> Bool {
        args.contains { $0.hasPrefix("--selftest-") } || args.contains("--check")
    }

    // MARK: - The lock

    private static func lockURL(_ dir: URL) -> URL { dir.appendingPathComponent("instance.lock") }
    private static func requestsDir(_ dir: URL) -> URL { dir.appendingPathComponent("requests", isDirectory: true) }

    /// The held lock's fd for the life of this process, or nil when another launcher holds it.
    /// Close-on-exec, like LaunchLock: a game spawned by the holder must not carry it off.
    /// The holder's pid is written into the file, for activating it.
    static func claim(dir: URL = defaultDir) -> Int32? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(lockURL(dir).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
        let pid = Array("\(getpid())\n".utf8)
        ftruncate(fd, 0)
        _ = pid.withUnsafeBufferPointer { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return fd
    }

    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// The pid the current holder wrote, if it has yet.
    static func holderPID(dir: URL = defaultDir) -> pid_t? {
        guard let d = FileManager.default.contents(atPath: lockURL(dir).path),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Requests

    /// Write `args` as a request. The file is the request; see the type's comment.
    static func writeRequest(_ args: [String], dir: URL = defaultDir) -> URL? {
        let fm = FileManager.default
        let reqs = requestsDir(dir)
        try? fm.createDirectory(at: reqs, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: ["args": args, "pid": Int(getpid())])
        else { return nil }
        let id = UUID().uuidString
        let tmp = reqs.appendingPathComponent(".\(id).tmp")
        let url = reqs.appendingPathComponent("\(id).json")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        guard rename(tmp.path, url.path) == 0 else { try? fm.removeItem(at: tmp); return nil }
        return url
    }

    /// Every waiting request, oldest first, each deleted as it is taken (the deletion is the
    /// sender's acknowledgement). Stale ones, and any file not owned by this user or readable
    /// by anyone else, are deleted unread.
    static func takeRequests(dir: URL = defaultDir, now: Date = Date()) -> [[String]] {
        takeDatedRequests(dir: dir, now: now).map(\.args)
    }

    /// `takeRequests`, with when each was written: a taken request still expires
    /// `maxRequestAge` after that (`PendingRequests`).
    static func takeDatedRequests(dir: URL = defaultDir, now: Date = Date()) -> [(written: Date, args: [String])] {
        let fm = FileManager.default
        let reqs = requestsDir(dir)
        guard let names = try? fm.contentsOfDirectory(atPath: reqs.path) else { return [] }
        var found: [(Date, [String])] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = reqs.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            let date = attrs[.modificationDate] as? Date ?? .distantPast
            let data = fm.contents(atPath: url.path)
            // Taken only if this call is the one that removed it: never acted on twice.
            guard (try? fm.removeItem(at: url)) != nil else { continue }
            guard owner == getuid(), mode & 0o077 == 0, now.timeIntervalSince(date) <= maxRequestAge,
                  let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let args = obj["args"] as? [String] else { continue }
            found.append((date, args))
        }
        return found.sorted { $0.0 < $1.0 }.map { (written: $0.0, args: $0.1) }
    }

    /// Take back a request nobody took in time. False when it was already gone: the holder
    /// took it between the last look and this delete, so it *was* handed over, and this launch
    /// must say so rather than "nothing was done" (or become a second launcher).
    static func withdraw(_ request: URL) -> Bool {
        if unlink(request.path) == 0 { return true }
        return errno != ENOENT
    }

    /// Poll until `request` has been taken, or `timeout` runs out.
    static func waitForTaken(_ request: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: request.path) { return true }
            usleep(50_000)
        }
        return !FileManager.default.fileExists(atPath: request.path)
    }

    // MARK: - Sending

    enum Outcome: Equatable {
        /// This process is the launcher now; `fd` is its lock.
        case primary(fd: Int32)
        /// The running launcher took the request.
        case forwarded(holder: pid_t?)
        /// Nobody took it and the lock is still held (a launcher that is quitting, or wedged).
        case unanswered
    }

    /// Claim the lock, or hand `command` to whoever holds it. `dir` and `name` are only
    /// changed by the self-test, so it never talks to a real launcher.
    static func claimOrForward(_ command: LaunchCommand, dir: URL = defaultDir,
                               name: Notification.Name = notificationName,
                               timeout: TimeInterval = 5) -> Outcome {
        if let fd = claim(dir: dir) { return .primary(fd: fd) }
        guard let request = writeRequest(command.arguments, dir: dir) else { return .unanswered }
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        if waitForTaken(request, timeout: timeout) || !withdraw(request) {
            return .forwarded(holder: holderPID(dir: dir))
        }
        // The holder may have quit while this waited; then this launch is the launcher.
        if let fd = claim(dir: dir) { return .primary(fd: fd) }
        return .unanswered
    }

    /// Launchers without the lock: same bundle id or same executable, not this process. A
    /// launch of this build that started within `racing` seconds of this one may simply not
    /// have reached the lock yet, and is left to it.
    static func lockless(racing: TimeInterval = 5) -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let started = NSRunningApplication.current.launchDate ?? Date()
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != me, !app.isTerminated else { return false }
            let same = app.bundleIdentifier == bundleID
                || (exe != nil && app.executableURL?.resolvingSymlinksInPath() == exe)
            guard same else { return false }
            guard let d = app.launchDate else { return true }
            return started.timeIntervalSince(d) > racing
        }
    }

    // MARK: - Start-up

    private static var heldFD: Int32?

    /// Called first thing at start-up (after `Headless.runIfAsked`, which runs and exits every
    /// self-test and `--check`). Returns only in the process that is to be the launcher.
    @MainActor static func enforce(_ args: [String] = CommandLine.arguments) {
        guard !isExempt(args) else { return }
        let command = LaunchCommand(args)
        let what = command.arguments.isEmpty ? "" : " (" + command.arguments.joined(separator: " ") + ")"
        switch claimOrForward(command) {
        case .primary(let fd):
            if let old = lockless().first {
                // An older launcher, which holds no lock and cannot take a request. Two copies
                // is the one outcome that is never right, so this one goes.
                release(fd)
                old.activate(options: [.activateAllWindows])
                say("FFXI on Mac is already running (pid \(old.processIdentifier)), and it is a build "
                    + "that cannot take a request from another launch"
                    + (what.isEmpty ? "" : ", so\(what) was not carried out")
                    + ". Use that window, or quit it and run this again.")
                exit(what.isEmpty ? 0 : 1)
            }
            heldFD = fd
            listen()
        case .forwarded(let holder):
            if let holder, let app = NSRunningApplication(processIdentifier: holder) {
                app.activate(options: [.activateAllWindows])
            }
            say("FFXI on Mac is already running" + (holder.map { " (pid \($0))" } ?? "")
                + "; handed it the request\(what) and left it to act on it. Its log has the result.")
            exit(0)
        case .unanswered:
            say("Another FFXI on Mac holds the launcher lock but did not take the request\(what) "
                + "within five seconds (it may be quitting or busy). Nothing was done; try again.")
            exit(1)
        }
    }

    private static func say(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    // MARK: - Receiving

    /// Requests taken but not yet acted on, oldest first. A window takes them in turn
    /// (`takePending`). One that no window has acted on `maxRequestAge` after it was written
    /// is dropped and logged: a `--play` must never start a game long after it was asked for,
    /// for instance when a window opens minutes later.
    @MainActor private(set) static var pending = PendingRequests()

    /// Where a dropped request is reported: the launcher log (there may be no window to show it).
    @MainActor static var log: (String) -> Void = { Runner.appendToLogFile($0) }

    /// The next request a window may act on, or nil. Expired ones are dropped first.
    @MainActor static func takePending(now: Date = Date()) -> LaunchCommand? {
        guard !terminating else { return nil }
        expirePending(now: now)
        return pending.next()
    }

    @MainActor static func expirePending(now: Date = Date()) {
        for (cmd, written) in pending.expire(now: now, maxAge: maxRequestAge) {
            log("!! request (\(cmd.arguments.joined(separator: " "))) from another launch dropped: no window "
                + "acted on it within \(Int(maxRequestAge)) s of \(written.formatted(date: .omitted, time: .standard))")
        }
    }

    /// Set once the app has been asked to quit: nothing more is taken, so a launch that hands a
    /// request over now sees it untaken, withdraws it and says nothing was done. Cleared if the
    /// quit is cancelled.
    @MainActor static var terminating = false

    /// This process's own `--world`/`--play`, handed out once per process. A window created
    /// later (Dock reopen after the last one was closed) must not play it again.
    @MainActor private static var own = OwnCommand()
    @MainActor static func takeOwnCommand(_ args: [String] = CommandLine.arguments) -> LaunchCommand? {
        own.take(args)
    }

    private static var observer: NSObjectProtocol?
    private static var poll: Timer?

    /// Take requests when told to, once a second in case a notification is lost, and once now
    /// for any written before this was listening.
    @MainActor static func listen(dir: URL = defaultDir, name: Notification.Name = notificationName,
                                  onRequest: @escaping @MainActor ([String], Date) -> Void = queue) {
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil,
                                                                      queue: .main) { _ in
            Task { @MainActor in drain(dir: dir, onRequest: onRequest) }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                drain(dir: dir, onRequest: onRequest)
                expirePending()
            }
        }
        drain(dir: dir, onRequest: onRequest)
    }

    @MainActor static func stopListening() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        poll?.invalidate()
        poll = nil
    }

    @MainActor private static func drain(dir: URL, onRequest: @MainActor ([String], Date) -> Void) {
        guard !terminating else { return }
        for r in takeDatedRequests(dir: dir) { onRequest(r.args, r.written) }
    }

    /// The real launcher's handler: queue it, come to the front, and tell the windows.
    @MainActor static func queue(_ args: [String], written: Date) {
        pending.add(LaunchCommand(args), written: written)
        if NSApp != nil { LauncherDelegate.showMainWindow() }
        NotificationCenter.default.post(name: arrived, object: nil)
    }
}

/// Taken requests waiting for a window, each with when it was written. Kept apart from the
/// window and the clock so the self-test can drive it.
struct PendingRequests {
    private(set) var items: [(command: LaunchCommand, written: Date)] = []

    mutating func add(_ command: LaunchCommand, written: Date) {
        items.append((command, written))
    }

    /// Drop and return every request written more than `maxAge` before `now`.
    mutating func expire(now: Date, maxAge: TimeInterval) -> [(command: LaunchCommand, written: Date)] {
        let old = items.filter { now.timeIntervalSince($0.written) > maxAge }
        items.removeAll { now.timeIntervalSince($0.written) > maxAge }
        return old
    }

    mutating func next() -> LaunchCommand? {
        items.isEmpty ? nil : items.removeFirst().command
    }
}

/// A launch's own `--world`/`--play` runs once per process, however many windows are created.
struct OwnCommand {
    private(set) var taken = false

    mutating func take(_ args: [String]) -> LaunchCommand? {
        guard !taken else { return nil }
        taken = true
        return LaunchCommand(args)
    }
}
