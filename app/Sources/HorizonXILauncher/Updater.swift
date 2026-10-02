import Foundation
import AppKit
import Combine

/// Self-update from the project's GitHub Releases.
///
/// On launch (and every few hours after) this checks the latest public release. A newer version
/// is offered in the UI; downloading and restarting each require a deliberate click.
///
/// Everything here is public data over plain HTTPS (no token). Nothing runs with elevated
/// privileges: the app replaces its own bundle, which the user owns because they installed it.
/// The downloaded app is Developer-ID signed by the same identity as the running one, so the swap
/// keeps a valid signature; its quarantine flag is stripped so the relaunch does not re-prompt.
@MainActor
final class Updater: ObservableObject {
    /// owner/repo the releases come from. One place to change if the repo ever moves.
    static let repo = "danielalanbates/HorizonXI-on-Mac"

    enum State: Equatable {
        case idle                     // nothing to do / up to date
        case checking
        case available(Release)       // newer release found; no download started
        case downloading(Double)      // 0...1
        case staging
        case ready(Release)           // downloaded and staged; waiting for the user to restart
        case failed(String)
    }

    struct Release: Equatable {
        let version: String           // "2.7"
        let tag: String               // "v2.7"
        let dmgURL: URL
        let notes: String
    }

    @Published private(set) var state: State = .idle
    /// The last check's result, whether or not it was newer — lets the UI say "you're on the latest".
    @Published private(set) var latestSeen: String?

    private var checkTimer: Timer?
    private var started = false

    /// The version this build reports. Falls back to a sentinel under `swift run` (no Info.plist),
    /// which makes every release look newer — fine, because self-update is a no-op off a `.app`.
    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// True only when running from an installed `.app` we can actually replace. Under `swift run`
    /// there is no bundle to swap, so the whole feature stays dark.
    static var canSelfUpdate: Bool {
        let p = Bundle.main.bundlePath
        return p.hasSuffix(".app") && FileManager.default.isWritableFile(atPath: p)
    }

    /// Call once from the view's `.task`. Checks now, then every 6 hours, and again whenever the
    /// app is reactivated (someone came back to it after a day).
    func start() {
        guard !started else { return }
        started = true
        Task { await checkAndMaybeDownload() }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.checkAndMaybeDownload() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { await self?.checkAndMaybeDownload() }
        }
    }

    /// A manual check uses the same quiet result when the app is current.
    func checkNow() { Task { await checkAndMaybeDownload(manual: true) } }

    /// Called only when the player accepts the offered update.
    func downloadAvailable() {
        guard case .available(let release) = state else { return }
        Task {
            do { try await download(release) }
            catch { state = .failed("Couldn't download update: \(error.localizedDescription)") }
        }
    }

    // MARK: - Check + download

    private func checkAndMaybeDownload(manual: Bool = false) async {
        // Never interrupt work in progress, and never re-download something already staged.
        switch state {
        case .checking, .downloading, .staging: return
        case .ready: return
        default: break
        }
        state = .checking
        do {
            guard let release = try await latestRelease() else {
                latestSeen = Self.currentVersion
                state = .idle
                return
            }
            latestSeen = release.version
            guard Self.isNewer(release.version, than: Self.currentVersion) else {
                state = .idle            // already current
                return
            }
            guard Self.canSelfUpdate else {
                // A newer version exists but we cannot replace this bundle (dev build, or a
                // read-only location). Say so; do not pretend to update.
                state = .failed("Version \(release.version) is available, but this copy can't update itself here. Download it from the project's Releases page.")
                return
            }
            // A staged update from a previous run may be offered directly for restart.
            if let staged = Self.stagedApp(for: release.version) {
                state = .ready(release)
                _ = staged
                return
            }
            state = .available(release)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = manual ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
            if !manual { /* stay quiet on a routine background failure (offline, rate limit) */ }
        }
    }

    /// The newest release with a `.dmg` asset, or nil if the API gives nothing usable.
    private func latestRelease() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FFXI-on-Mac", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        // Prefer the .dmg; that is what every release ships.
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let urlStr = dmg["browser_download_url"] as? String,
              let url = URL(string: urlStr), url.scheme == "https",
              url.host == "github.com" else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = (obj["body"] as? String) ?? ""
        return Release(version: version, tag: tag, dmgURL: url, notes: notes)
    }

    private func download(_ release: Release) async throws {
        state = .downloading(0)
        let tmpDmg = Self.workDir().appendingPathComponent("update-\(release.version).dmg")
        try? FileManager.default.removeItem(at: tmpDmg)

        // Stream to disk with a per-task progress delegate so a 150 MB dmg shows a bar, not a
        // hang. The delegate reports progress only; the async download(for:delegate:) owns the
        // finished file, so the delegate must not implement didFinishDownloadingTo.
        let delegate = DownloadProgress { [weak self] frac in
            Task { @MainActor in
                if case .downloading = self?.state { self?.state = .downloading(frac) }
            }
        }
        var req = URLRequest(url: release.dmgURL)
        req.setValue("FFXI-on-Mac", forHTTPHeaderField: "User-Agent")
        let (fileURL, resp) = try await URLSession.shared.download(for: req, delegate: delegate)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Err("download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        try? FileManager.default.removeItem(at: tmpDmg)
        try FileManager.default.moveItem(at: fileURL, to: tmpDmg)

        state = .staging
        try await Self.stage(dmg: tmpDmg, version: release.version)
        try? FileManager.default.removeItem(at: tmpDmg)
        state = .ready(release)
    }

    // MARK: - Mount + stage

    /// Where downloads and the staged app live: Application Support, so it survives across the
    /// swap (a temp dir could be reaped mid-restart) and is on the same volume as nothing critical.
    nonisolated private static func workDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac/updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func stagedApp(for version: String) -> URL? {
        let app = workDir().appendingPathComponent("staged-\(version)/FFXI-on-Mac.app")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    /// Mount the dmg, copy the `.app` out of it into `staged-<version>/`, strip its quarantine
    /// flag, and detach. Runs off the main actor (hdiutil + ditto are blocking).
    nonisolated private static func stage(dmg: URL, version: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let mount = workDir().appendingPathComponent("mnt-\(version)")
            try? fm.removeItem(at: mount)
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            defer {
                _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
                try? fm.removeItem(at: mount)
            }
            let attach = run("/usr/bin/hdiutil",
                             ["attach", dmg.path, "-nobrowse", "-noverify", "-quiet",
                              "-mountpoint", mount.path])
            guard attach.status == 0 else { throw Err("could not mount the update disk image") }

            guard let app = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
                throw Err("the update disk image had no app in it")
            }
            let stageDir = workDir().appendingPathComponent("staged-\(version)")
            try? fm.removeItem(at: stageDir)
            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            let dest = stageDir.appendingPathComponent("FFXI-on-Mac.app")
            let cp = run("/usr/bin/ditto", [app.path, dest.path])
            guard cp.status == 0 else { throw Err("could not copy the update out of the disk image") }
            guard run("/usr/bin/codesign", ["--verify", "--strict", "--deep", dest.path]).status == 0 else {
                try? fm.removeItem(at: dest)
                throw Err("the update app's code signature is invalid")
            }
            let currentTeam = teamID(Bundle.main.bundlePath)
            let updateTeam = teamID(dest.path)
            if let currentTeam, currentTeam != updateTeam {
                try? fm.removeItem(at: dest)
                throw Err("the update was signed by a different developer")
            }
            // Downloaded => quarantined; strip it so the relaunch does not re-prompt Gatekeeper.
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        }.value
    }

    // MARK: - Install + relaunch

    /// Swap the running bundle for the staged one and relaunch. Because an app cannot overwrite
    /// itself while running, this hands the job to a tiny detached shell script that waits for
    /// this process to exit, ditto's the new bundle over the old path, and reopens it — then the
    /// app quits itself.
    func restartToUpdate() {
        guard case .ready(let release) = state,
              let staged = Self.stagedApp(for: release.version),
              Self.canSelfUpdate else { return }
        let current = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = Self.workDir().appendingPathComponent("apply-update.sh")
        let body = """
        #!/bin/zsh
        # Wait for FFXI on Mac (pid \(pid)) to quit, then swap in the update and relaunch.
        for i in {1..600}; do kill -0 \(pid) 2>/dev/null || break; sleep 0.5; done
        /usr/bin/ditto "\(staged.path)" "\(current)" || exit 1
        /usr/bin/xattr -dr com.apple.quarantine "\(current)" 2>/dev/null
        /bin/rm -rf "\(staged.deletingLastPathComponent().path)"
        /usr/bin/open "\(current)"
        /bin/rm -f "\(script.path)"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            state = .failed("Couldn't prepare the update: \(error.localizedDescription)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path]
        do { try p.run() } catch {
            state = .failed("Couldn't start the update: \(error.localizedDescription)")
            return
        }
        // Give the helper a beat to start waiting, then quit so it can take over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: - Version comparison

    /// Dotted numeric compare: 2.10 > 2.9 > 2.6. Non-numeric parts are treated as 0, so a tag that
    /// isn't a clean version never spuriously looks newer than a real one.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0, yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    // MARK: - Small helpers

    struct Err: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }

    nonisolated private static func teamID(_ path: String) -> String? {
        let output = run("/usr/bin/codesign", ["-dv", "--verbose=4", path]).out
        return output.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
    }

    @discardableResult
    nonisolated private static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }
}

/// URLSession download delegate that reports fractional progress. `didFinishDownloadingTo` is
/// required by the protocol but is a no-op here: the async `download(for:delegate:)` API owns the
/// finished file and hands it back as its return value.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        guard e > 0 else { return }
        onProgress(Double(w) / Double(e))
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
