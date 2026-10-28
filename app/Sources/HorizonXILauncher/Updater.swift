import Foundation
import AppKit
import Combine
import CryptoKit
import Security

/// Self-update from the project's GitHub Releases.
///
/// Quiet by design (Daniel: "I don't want needless text plaguing the user"). Checking,
/// downloading, staging, being offline and a failed check all show nothing. One line appears
/// only when there is something to act on:
///   * `ready`         "Launcher X ready" + Restart: newer, downloaded, staged and verified;
///   * `manual`        "Launcher X available" + Download: newer, downloaded and verified the
///                     same way, but this copy cannot replace itself (bundle or its folder not
///                     writable);
///   * `restartFailed` one short reason, when a Restart the user pressed did not go through.
///                     After two failed installs of one release, or one failure that every try
///                     would meet (the folder or the rename refused), `manual` instead.
///
/// When: once at launch, every 6 h, and on activation only if the last check is over an hour
/// old. Nothing is checked, downloaded or staged while a game client is live or starting, or a
/// Runner or local-server job is in flight; it retries 10 minutes later. A release that fails verification is remembered and
/// never downloaded again until a different tag appears.
///
/// Newer means (CFBundleShortVersionString, CFBundleVersion) as a tuple. The build rides in the
/// asset name, `FFXI-on-Mac-<version>-b<build>.dmg`; a legacy asset without it (v3.9) compares
/// by short version alone, so no 3.9 build is ever offered v3.9.
///
/// Ours means the staged app satisfies `UpdateRules.requirement` (Apple-anchored, this bundle id,
/// this team), passes Gatekeeper (notarized), and carries the version and build the release
/// names. An ad-hoc or other-team build of the launcher never checks at all.
///
/// Restart hands over to `apply-update.sh`, started detached so it survives this process. It
/// swaps the bundle with rollback and reopens whichever app ends up in place.
@MainActor
final class Updater: ObservableObject {
    /// One per process: a Dock-reopened window must not start a second download into the same
    /// paths.
    static let shared = Updater()

    enum State: Equatable {
        case idle                                   // shows nothing
        case ready(UpdateRelease)                   // staged + verified; waiting for Restart
        case manual(UpdateRelease)                  // verified, but this copy can't replace itself
        case installing(UpdateRelease)              // Restart pressed; the helper is taking over
        case restartFailed(UpdateRelease, RestartFailure)
    }

    /// Why a Restart did not go through. The UI shows `message`, one short line, and `detail`
    /// (the helper's own reason, from its log) only as a tooltip.
    enum RestartFailure: Equatable {
        case clientLive, companionLive, workInFlight, helperDidNotStart, notVerified
        case lastAttempt(String)
        var message: String {
            switch self {
            case .clientLive: return "Close the game, then restart to update"
            case .companionLive: return "Close VanaGuide, then restart to update"
            case .workInFlight: return "Finish the running job, then restart to update"
            case .helperDidNotStart: return "Update didn't start. Try Restart again"
            case .notVerified: return "Update failed verification; fetching it again"
            case .lastAttempt: return "Last update didn't install. Try Restart again"
            }
        }
        var detail: String? {
            if case .lastAttempt(let why) = self { return why }
            return nil
        }
        /// The staged update is still good, so Restart stays offered.
        var canRetry: Bool { self != .notVerified }
    }

    @Published private(set) var state: State = .idle

    private var started = false
    /// A check, download or stage is running. Never shown; only keeps them from overlapping.
    private var working = false
    private var checkTimer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var retryTask: Task<Void, Never>?
    /// Why the helper reopened this launcher after a failed update, shown once.
    private var lastAttemptFailure: UpdateRules.HelperFailure?

    private init() {}

    /// The running build, from its own Info.plist. Build 0 under `swift run`.
    nonisolated static var local: UpdateRules.Build {
        let info = Bundle.main.infoDictionary ?? [:]
        return UpdateRules.Build(version: info["CFBundleShortVersionString"] as? String ?? "0",
                                 build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0)
    }

    /// Only this project's Developer ID build of the launcher updates. Ad-hoc builds (no team),
    /// `swift run` (no bundle) and other people's signed forks stay completely quiet.
    private lazy var updatesEnabled: Bool =
        Bundle.main.bundlePath.hasSuffix(".app")
        && Bundle.main.bundleIdentifier == UpdateRules.bundleID
        && UpdateWork.runningTeamID() == UpdateRules.teamID

    /// Call once (from the window's `.task`); later calls do nothing.
    func start() {
        guard !started else { return }
        started = true
        guard updatesEnabled else { return }
        if let failure = UpdateWork.takeHelperFailure() {
            lastAttemptFailure = failure
            if let tag = failure.tag {
                UpdateRules.recordRestartFailure(tag, lasting: failure.lasting, in: .standard)
            }
        }
        check()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let u = Updater.shared
                if Date().timeIntervalSince(u.lastCheck) > 3600 { u.check() }
            }
        }
    }

    private var lastCheck: Date {
        get { UserDefaults.standard.object(forKey: UpdateRules.lastCheckKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: UpdateRules.lastCheckKey) }
    }

    // MARK: - Check, download, stage (all silent)

    private func check() {
        guard updatesEnabled, !working else { return }
        switch state {
        case .idle, .manual: break
        default: return            // something is staged or a restart is under way
        }
        working = true
        Task {
            await checkAndStage()
            working = false
        }
    }

    /// Defer while a game, an install or a local-server job is running: no API call, no
    /// download, no hdiutil/codesign competing with the client for an 8 GB Mac.
    private func gameOrWorkBusy() async -> Bool {
        if Self.ownBlocker() != nil { return true }
        return await Task.detached(priority: .utility) { !LiveClients.snapshot().clients.isEmpty }.value
    }

    /// What this launcher knows without a scan stands in the way of quitting: a launch of its
    /// own (from the moment it passes its checks, before any client exists), a Runner job, or a
    /// local-server setup, start or stop (its build dies with the launcher).
    private static func ownBlocker() -> RestartFailure? {
        if Runner.anyPlaying { return .clientLive }
        if Runner.workInFlight || LocalServer.workInFlight { return .workInFlight }
        let applications = NSWorkspace.shared.runningApplications.map {
            UpdateRules.RunningApplication(bundleIdentifier: $0.bundleIdentifier,
                                           executablePath: $0.executableURL?.path)
        }
        if UpdateRules.embeddedCompanionIsRunning(in: Bundle.main.bundlePath, applications: applications) {
            return .companionLive
        }
        return nil
    }

    /// The same plus every game client on the Mac, another launcher's too. The scan runs off
    /// the main actor, so what this launcher knows is read again after it.
    private func restartBlocker() async -> RestartFailure? {
        if let why = Self.ownBlocker() { return why }
        let live = await Task.detached(priority: .userInitiated) {
            !LiveClients.snapshot().clients.isEmpty
        }.value
        return live ? .clientLive : Self.ownBlocker()
    }

    private func retryLater() {
        guard retryTask == nil else { return }
        retryTask = Task {
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            retryTask = nil
            check()
        }
    }

    private func checkAndStage() async {
        if await gameOrWorkBusy() { retryLater(); return }
        lastCheck = Date()
        let release: UpdateRelease
        do {
            guard let r = try await UpdateWork.fetchLatest() else {
                UpdateWork.note("no usable release")
                if case .manual = state { state = .idle }
                return
            }
            release = r
        } catch {
            UpdateWork.note("check failed: \(error.localizedDescription)")   // offline, rate limit
            return
        }
        switch UpdateRules.step(for: release, over: Self.local, in: .standard) {
        case .upToDate:
            UpdateWork.note("up to date (latest is \(release.tag) \(release.assetName))")
            UpdateWork.prune(keeping: nil)
            if case .manual = state { state = .idle }
            return
        case .rejected:
            if case .manual = state { state = .idle }
            return
        case .stage:
            break
        }
        // A line for an older release goes; this one shows only once it has verified.
        if case .manual(let shown) = state, shown != release { state = .idle }
        UpdateWork.prune(keeping: release.tag)

        do {
            // Staged by an earlier run? Check it again: it can outlive the process that made it.
            if let staged = UpdateWork.stagedApp(for: release) {
                let good = await Task.detached(priority: .utility) {
                    (try? UpdateWork.verify(app: staged, release: release)) != nil
                }.value
                if good { return offer(release) }
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            }
            let dmg = try await UpdateWork.download(release)
            if await gameOrWorkBusy() { retryLater(); return }   // the dmg is kept and reused
            _ = try await Task.detached(priority: .utility) {
                try UpdateWork.stage(dmg: dmg, release: release)
            }.value
            try? FileManager.default.removeItem(at: dmg)
            offer(release)
        } catch UpdateFailure.rejected(let why) {
            UpdateWork.note("\(release.tag) rejected: \(why)")
            UpdateRules.reject(release.tag, in: .standard)
            UpdateWork.prune(keeping: nil)
            if case .manual = state { state = .idle }
        } catch {
            UpdateWork.note("\(release.tag) not staged: \(error.localizedDescription)")
        }
    }

    /// Only a downloaded and verified copy is ever suggested. A copy that can't replace itself
    /// gets the Download link; it still stages first (in the work dir, which is always
    /// writable), so a release Gatekeeper would block is never offered there either.
    private func offer(_ release: UpdateRelease) {
        guard UpdateWork.canSelfUpdate else {
            UpdateWork.note("\(release.tag) verified; this copy can't replace itself")
            state = .manual(release)
            return
        }
        becomeReady(release)
    }

    private func becomeReady(_ release: UpdateRelease) {
        // Restart already failed for this release twice, or in a way every try would: the
        // Download link instead of a Restart that quits and reopens the launcher for nothing.
        // The staged copy stays, so later checks re-verify it rather than download it again.
        if UpdateRules.restartGivenUp(release.tag, in: .standard) {
            UpdateWork.note("\(release.tag) verified; Restart failed to install it before, offering the download")
            lastAttemptFailure = nil
            state = .manual(release)
            return
        }
        UpdateWork.note("\(release.tag) ready")
        let failure = lastAttemptFailure
        lastAttemptFailure = nil
        if let failure, failure.tag == nil || failure.tag == release.tag {
            state = .restartFailed(release, .lastAttempt(failure.reason))
        } else {
            state = .ready(release)
        }
    }

    // MARK: - Restart

    /// Swap in the staged update and relaunch. Refused while a client is live or starting, or a
    /// Runner or local-server job is running; a second press while one is under way does
    /// nothing. While `.installing`, Play and a handed-over --play are refused (ContentView).
    func restartToUpdate() {
        let release: UpdateRelease
        switch state {
        case .ready(let r): release = r
        case .restartFailed(let r, let why) where why.canRetry: release = r
        default: return
        }
        state = .installing(release)
        Task { await install(release) }
    }

    private func install(_ release: UpdateRelease) async {
        if let why = await restartBlocker() { return state = .restartFailed(release, why) }
        guard UpdateWork.canSelfUpdate else { return state = .manual(release) }
        // `.ready` never checks again, so ask once more: a release withdrawn (or replaced) since
        // it was staged is not installed, and the line goes. Briefly; no answer (offline, rate
        // limit) is no reason to hold back a release that verified.
        do {
            let latest = try await UpdateWork.fetchLatest(timeout: 8)
            if !UpdateRules.isStillLatest(release, latest: latest) {
                UpdateWork.note("\(release.tag) \(release.assetName) is no longer the latest release "
                                + "(\(latest.map { "\($0.tag) \($0.assetName)" } ?? "none usable")); not installing it")
                UpdateWork.prune(keeping: nil)
                state = .idle
                return check()
            }
        } catch {
            UpdateWork.note("could not recheck the latest release before installing: \(error.localizedDescription)")
        }
        guard let staged = UpdateWork.stagedApp(for: release),
              await Task.detached(priority: .userInitiated, operation: {
                  (try? UpdateWork.verify(app: staged, release: release)) != nil
              }).value else {
            UpdateWork.prune(keeping: nil)
            state = .restartFailed(release, .notVerified)
            // Not the release's fault (the staged copy changed): fetch it again shortly.
            Task {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                if case .restartFailed(_, .notVerified) = state { state = .idle; check() }
            }
            return
        }
        // Re-checked after the awaits: a download, a server job or a launch already past Play
        // (the local server starting first) could have begun meanwhile.
        if let why = await restartBlocker() { return state = .restartFailed(release, why) }
        let current = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = await Task.detached(priority: .userInitiated) {
            UpdateWork.startHelper(staged: staged, current: current, launcherPID: pid)
        }.value
        guard let helper else { return state = .restartFailed(release, .helperDidNotStart) }
        // The helper took up to 10 s to start. A last look with nothing awaited between it and
        // the quit; the helper is called off if anything began.
        if let why = Self.ownBlocker() {
            UpdateWork.cancelHelper(helper)
            return state = .restartFailed(release, why)
        }
        UpdateWork.note("restarting into \(release.tag) (helper pid \(helper))")
        NSApp.terminate(nil)
        // Still here: the quit was cancelled. Call the helper off so a later quit does not
        // swap the bundle by surprise.
        UpdateWork.cancelHelper(helper)
        state = .restartFailed(release, .workInFlight)
    }

    // MARK: - Version comparison (also used by the HorizonXI client banner)

    static func isNewer(_ a: String, than b: String) -> Bool { UpdateRules.compare(a, b) > 0 }
}

/// A GitHub release the updater could install.
struct UpdateRelease: Equatable {
    let tag: String                 // "v3.10"
    let build: UpdateRules.Build    // (3.10, 60); build 0 for a legacy asset name
    let assetName: String           // "FFXI-on-Mac-3.10-b60.dmg"
    let dmgURL: URL                 // browser_download_url, on github.com
    let pageURL: URL                // the release page, for the manual Download link
    let sha256: String?             // GitHub's asset digest, when the API gives one

    var version: String { build.version }

    /// "3.10", or "3.10 b60" when only the build differs from the running app.
    var label: String {
        build.build > 0 && build.version == Updater.local.version
            ? "\(build.version) b\(build.build)" : build.version
    }
}

enum UpdateFailure: LocalizedError {
    /// Worth trying again later: network, timeouts, a busy disk.
    case transient(String)
    /// The release itself is wrong: remembered so it is never downloaded again.
    case rejected(String)
    var errorDescription: String? {
        switch self { case .transient(let m), .rejected(let m): return m }
    }
}

/// The update policy as pure functions: what counts as newer, which tags and URLs are accepted,
/// which release was refused. No I/O and no actor, so `--selftest-updater` checks every rule.
enum UpdateRules {
    /// owner/repo the releases come from. v3.9 clients still ask the old name, which GitHub
    /// redirects here, so never create a new repo called HorizonXI-on-Mac.
    static let repo = "danielalanbates/FFXI-on-Mac"
    static let bundleID = "org.batesai.horizonxi-on-mac"
    static let companionBundleID = "org.batesai.vanaguide-companion"
    static let teamID = "MG4YW8XX2Z"
    /// What an update must satisfy (`codesign -R`), here and in apply-update.sh.
    static let requirement = "anchor apple generic and identifier \"\(bundleID)\" "
        + "and certificate leaf[subject.OU] = \"\(teamID)\""
    static let lastCheckKey = "updater.lastCheck"
    static let rejectedKey = "updater.rejectedTag"
    static let failedTagKey = "updater.failedTag"
    static let failedCountKey = "updater.failedCount"
    /// Failed Restarts of one release before the Download link replaces Restart.
    static let restartTries = 2
    /// Hosts a request may be redirected to. A download's first URL must be github.com; the API
    /// itself redirects within api.github.com when a repo is renamed (v3.9 clients rely on it).
    static let redirectHosts: Set<String> = [
        "api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    struct Build: Equatable {
        let version: String     // CFBundleShortVersionString
        let build: Int          // CFBundleVersion; 0 = unknown (legacy asset name)
    }

    struct RunningApplication {
        let bundleIdentifier: String?
        let executablePath: String?
    }

    /// Pure OS-metadata rule. A running embedded GUI owns resources inside the launcher and
    /// must be closed by its user before an enclosing bundle swap. An independent standalone
    /// guide does not prevent this launcher from updating. Missing path plus known identity
    /// stays conservative, since it cannot establish that the copy is independent.
    static func embeddedCompanionIsRunning(in bundlePath: String, applications: [RunningApplication]) -> Bool {
        let helpers = URL(fileURLWithPath: bundlePath).standardizedFileURL.path + "/Contents/Helpers/"
        return applications.contains { app in
            guard let executablePath = app.executablePath, !executablePath.isEmpty else {
                return app.bundleIdentifier == companionBundleID
            }
            let path = URL(fileURLWithPath: executablePath).standardizedFileURL.path
            guard path.hasPrefix(helpers) else { return false }
            return app.bundleIdentifier == companionBundleID || path.hasSuffix("/Contents/MacOS/VanaguideCompanion")
        }
    }

    /// "v3.10" -> "3.10". Only v<major>.<minor>[.<patch>]: an rc or beta tag is never offered.
    static func version(fromTag tag: String) -> String? {
        guard tag.range(of: #"\Av[0-9]+(\.[0-9]+){1,2}\z"#, options: .regularExpression) != nil else { return nil }
        return String(tag.dropFirst())
    }

    /// The build in `FFXI-on-Mac-<version>-b<build>.dmg`; 0 when the name carries none.
    static func build(fromAssetName name: String) -> Int {
        guard let r = name.range(of: #"-b[0-9]+\.dmg$"#, options: [.regularExpression, .caseInsensitive])
        else { return 0 }
        return Int(name[r].dropFirst(2).dropLast(4)) ?? 0
    }

    /// Dotted numeric compare: 3.10 > 3.9 > 3.8.1. Returns -1, 0 or 1.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0, yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi ? 1 : -1 }
        }
        return 0
    }

    /// Offer `remote` over `local` only if it is strictly newer. With a build in the asset name
    /// the pair is compared as a tuple; without one only the short version counts.
    static func isOffered(_ remote: Build, over local: Build) -> Bool {
        let c = compare(remote.version, local.version)
        if c != 0 { return c > 0 }
        return remote.build > 0 && remote.build > local.build
    }

    /// The asset link the API hands out: https, github.com, under this repo's downloads.
    static func isTrustedAssetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com" else { return false }
        return url.path.lowercased().hasPrefix("/\(repo.lowercased())/releases/download/")
    }

    /// Every redirect hop: https, and one of GitHub's own hosts.
    static func isTrustedRedirect(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && redirectHosts.contains(url.host?.lowercased() ?? "")
    }

    static func isTrustedPageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
            && url.path.lowercased().hasPrefix("/\(repo.lowercased())/releases")
    }

    /// Only an asset naming this exact release version can represent its build. In particular,
    /// an old dmg or a beta dmg attached to a stable release must not hide the real update.
    static func assetBuild(from name: String, version: String) -> Int? {
        let stem = "FFXI-on-Mac-\(version)"
        if name.caseInsensitiveCompare(stem + ".dmg") == .orderedSame { return 0 }
        let pattern = #"\A"# + NSRegularExpression.escapedPattern(for: stem) + #"-b([0-9]+)\.dmg\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name), let build = Int(name[range]), build > 0
        else { return nil }
        return build
    }

    /// The installable published stable release in a `/releases/latest` response, or nil.
    static func release(fromAPI obj: [String: Any]) -> UpdateRelease? {
        guard obj["draft"] as? Bool == false, obj["prerelease"] as? Bool == false,
              let published = obj["published_at"] as? String, !published.isEmpty,
              let tag = obj["tag_name"] as? String, let version = version(fromTag: tag),
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)).flatMap {
            isTrustedPageURL($0) ? $0 : nil
        } ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        let candidates: [UpdateRelease] = assets.compactMap { dmg in
            guard dmg["state"] as? String == "uploaded",
                  let name = dmg["name"] as? String, let build = assetBuild(from: name, version: version),
                  let link = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  isTrustedAssetURL(link), link.path.hasSuffix("/releases/download/\(tag)/\(name)")
            else { return nil }
            let digest = (dmg["digest"] as? String).flatMap {
                $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil
            }
            if let digest, digest.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) == nil { return nil }
            return UpdateRelease(tag: tag, build: Build(version: version, build: build),
                                 assetName: name, dmgURL: link, pageURL: page, sha256: digest)
        }
        return candidates.max { $0.build.build < $1.build.build }
    }

    /// codesign exits 1 when the signature is broken or missing and 3 when it does not meet the
    /// requirement; 2 is bad arguments. Measured: unsigned 1, ad-hoc 3, another team's app 3.
    static func isRefusal(codesign status: Int32) -> Bool { status == 1 || status == 3 }

    /// spctl exits 3 when Gatekeeper says no (unsigned and ad-hoc apps measured 3) and 1 when the
    /// assessment itself failed (a missing path measured 1), which is no verdict at all.
    static func isRefusal(spctl status: Int32) -> Bool { status == 3 }

    /// Restart installs a staged release only while it is still exactly the latest one: same
    /// tag, same version and build. Withdrawn (nothing usable is latest), rolled back to an older
    /// tag, replaced by a rebuilt asset, or overtaken by a newer release (which is staged and
    /// offered instead) all say no.
    static func isStillLatest(_ staged: UpdateRelease, latest: UpdateRelease?) -> Bool {
        guard let latest else { return false }
        return latest.tag == staged.tag && latest.build == staged.build
            && latest.assetName == staged.assetName && latest.dmgURL == staged.dmgURL
            && latest.sha256 == staged.sha256
    }

    enum CheckStep: Equatable { case upToDate, rejected, stage }

    /// What a check does with the latest release. A tag that failed verification is dropped
    /// before anything else, so it is never suggested, not even as a Download link. Whether this
    /// copy can replace itself plays no part: every offer, Restart or Download, waits for a
    /// staged and verified copy.
    static func step(for release: UpdateRelease, over local: Build, in defaults: UserDefaults) -> CheckStep {
        guard isOffered(release.build, over: local) else { return .upToDate }
        return isRejected(release.tag, in: defaults) ? .rejected : .stage
    }

    static func isRejected(_ tag: String, in defaults: UserDefaults) -> Bool {
        defaults.string(forKey: rejectedKey) == tag
    }

    static func reject(_ tag: String, in defaults: UserDefaults) {
        defaults.set(tag, forKey: rejectedKey)
    }

    /// `path` is `dir` or anywhere under it (not merely a name that starts the same).
    static func isInside(_ path: String, dir: String) -> Bool {
        let p = (path as NSString).standardizingPath, d = (dir as NSString).standardizingPath
        return p == d || p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }

    /// What apply-update.sh left in `last-failure` after putting the old app back.
    struct HelperFailure: Equatable {
        let reason: String
        let tag: String?        // the release it was installing
        let lasting: Bool       // every later try would fail the same way
    }

    /// `reason=…`, `tag=…`, `lasting=0|1`, one per line. A file without them is all reason.
    static func helperFailure(from text: String) -> HelperFailure? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        let reason = (fields["reason"] ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return nil }
        return HelperFailure(reason: reason, tag: fields["tag"].flatMap { $0.isEmpty ? nil : $0 },
                             lasting: fields["lasting"] == "1")
    }

    /// Count a failed Restart of `tag`; a failure that will recur counts as every try at once.
    static func recordRestartFailure(_ tag: String, lasting: Bool, in defaults: UserDefaults) {
        let before = defaults.string(forKey: failedTagKey) == tag ? defaults.integer(forKey: failedCountKey) : 0
        defaults.set(tag, forKey: failedTagKey)
        defaults.set(lasting ? max(before + 1, restartTries) : before + 1, forKey: failedCountKey)
    }

    static func restartGivenUp(_ tag: String, in defaults: UserDefaults) -> Bool {
        defaults.string(forKey: failedTagKey) == tag && defaults.integer(forKey: failedCountKey) >= restartTries
    }
}

/// The updater's blocking and network work. Nothing here touches UI state; the slow calls
/// (`stage`, `verify`, `startHelper`) are meant for a detached task.
enum UpdateWork {
    /// Downloads, the staged app, the helper and its log: Application Support, so they survive
    /// the swap (a temp dir could be reaped mid-restart).
    static func workDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac/updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The bundle and the folder it sits in must both be writable: the helper renames it. A copy
    /// run from the work dir (a kept previous copy) never replaces itself: the helper prunes
    /// the previous copies there.
    static var canSelfUpdate: Bool {
        let p = Bundle.main.bundlePath
        let fm = FileManager.default
        return p.hasSuffix(".app") && !UpdateRules.isInside(p, dir: workDir().path)
            && fm.isWritableFile(atPath: p)
            && fm.isWritableFile(atPath: (p as NSString).deletingLastPathComponent)
    }

    /// The running app's TeamIdentifier; nil when ad-hoc or unsigned.
    static func runningTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// One line per outcome, so "why no update?" has an answer without any UI.
    static func note(_ line: String) {
        let url = workDir().appendingPathComponent("updater.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 256 * 1024 {
            try? FileManager.default.removeItem(at: url)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: Network

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 15 * 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    static func fetchLatest(timeout: TimeInterval = 30) async throws -> UpdateRelease? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateRules.repo)/releases/latest")!)
        req.timeoutInterval = timeout
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FFXI-on-Mac", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        return try latestRelease(data: data, statusCode: (resp as? HTTPURLResponse)?.statusCode ?? -1)
    }

    /// A 404 from the public latest-release endpoint means nothing is published now. Treating
    /// it as an offline error would let Restart install a release withdrawn since staging.
    static func latestRelease(data: Data, statusCode: Int) throws -> UpdateRelease? {
        if statusCode == 404 { return nil }
        // A rate limit or server error is not evidence that this app is current.
        guard statusCode == 200 else {
            throw UpdateFailure.transient("GitHub answered HTTP \(statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateFailure.transient("GitHub returned an unreadable release")
        }
        return UpdateRules.release(fromAPI: obj)
    }

    /// Download the release's dmg into the work dir. A complete one left by a deferred attempt
    /// is reused when GitHub's digest vouches for it.
    static func download(_ r: UpdateRelease, into dir: URL = workDir()) async throws -> URL {
        let fm = FileManager.default
        let dest = dir.appendingPathComponent("update-\(r.tag).dmg")
        if let want = r.sha256, fm.fileExists(atPath: dest.path), sha256(of: dest) == want { return dest }
        try? fm.removeItem(at: dest)
        var req = URLRequest(url: r.dmgURL)
        req.setValue("FFXI-on-Mac", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await session.download(for: req)
        defer { try? fm.removeItem(at: tmp) }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateFailure.transient("download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        if let want = r.sha256, sha256(of: tmp) != want {
            throw UpdateFailure.transient("download does not match GitHub's digest")
        }
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Stage + verify

    static func stagedApp(for r: UpdateRelease) -> URL? {
        let app = workDir().appendingPathComponent("staged-\(r.tag)/FFXI-on-Mac.app")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    /// Remove downloads and staged copies other than `tag`'s (all of them for nil). Leaves the
    /// helper, its log, its lock and the previous app alone.
    static func prune(keeping tag: String?) {
        let fm = FileManager.default
        let dir = workDir()
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let mine = tag.map { name == "staged-\($0)" || name == "update-\($0).dmg" } ?? false
            if !mine, name.hasPrefix("staged-") || (name.hasPrefix("update-") && name.hasSuffix(".dmg")) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Mount the dmg read-only, copy the app out into `staged-<tag>/`, and verify it. Blocking.
    /// `dir` is the work dir; `--selftest-updater --dmg` points it at a temporary folder.
    @discardableResult
    static func stage(dmg: URL, release r: UpdateRelease, in dir: URL = workDir()) throws -> URL {
        let fm = FileManager.default
        let mount = dir.appendingPathComponent("mnt-\(r.tag)")
        if fm.fileExists(atPath: mount.path) {
            run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"], timeout: 60)
            rmdir(mount.path)
        }
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"], timeout: 60)
            rmdir(mount.path)       // only ever removes an empty folder, never a still-mounted image
        }
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                              "-noverify", "-quiet", "-mountpoint", mount.path], timeout: 120)
        guard attach == 0 else { throw UpdateFailure.transient("could not mount the disk image (\(attach))") }
        let app = mount.appendingPathComponent("FFXI-on-Mac.app")
        guard fm.fileExists(atPath: app.path) else { throw UpdateFailure.rejected("no FFXI-on-Mac.app in the disk image") }

        let stageDir = dir.appendingPathComponent("staged-\(r.tag)")
        try? fm.removeItem(at: stageDir)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        var keep = false
        defer { if !keep { try? fm.removeItem(at: stageDir) } }
        let dest = stageDir.appendingPathComponent("FFXI-on-Mac.app")
        guard run("/usr/bin/ditto", [app.path, dest.path], timeout: 300) == 0 else {
            throw UpdateFailure.transient("could not copy the app out of the disk image")
        }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path], timeout: 60)
        try verify(app: dest, release: r)
        keep = true
        return dest
    }

    /// Accept only this project's notarized build, at exactly the version (and build) the release
    /// names. Reads Info.plist directly: `Bundle(url:)` caches and can return a stale copy.
    static func verify(app: URL, release r: UpdateRelease) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == UpdateRules.bundleID else {
            throw UpdateFailure.rejected("not this app's bundle id")
        }
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        guard short == r.version else { throw UpdateFailure.rejected("app is \(short), tag says \(r.tag)") }
        let build = info["CFBundleVersion"] as? String ?? "?"
        if r.build.build > 0, build != String(r.build.build) {
            throw UpdateFailure.rejected("app is build \(build), asset says b\(r.build.build)")
        }
        // Only a verdict rejects the release for good. Any other status (bad arguments, a crash,
        // a signal, the deadline, syspolicyd unavailable) says nothing about it: try again later.
        let sig = run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R", "=" + UpdateRules.requirement,
                                            app.path], timeout: 300)
        guard sig == 0 else {
            throw UpdateRules.isRefusal(codesign: sig)
                ? UpdateFailure.rejected("signature does not meet the release requirement")
                : UpdateFailure.transient("codesign did not finish (\(sig))")
        }
        let gk = run("/usr/sbin/spctl", ["-a", "-t", "execute", app.path], timeout: 180)
        guard gk == 0 else {
            throw UpdateRules.isRefusal(spctl: gk)
                ? UpdateFailure.rejected("Gatekeeper rejected it (not notarized?)")
                : UpdateFailure.transient("spctl did not finish (\(gk))")
        }
    }

    // MARK: Helper

    private static var lockDir: URL { workDir().appendingPathComponent("apply.lock") }

    /// Start apply-update.sh detached and wait until it holds the update lock. Its pid, or nil
    /// when it could not be started (the launcher then stays open and says so).
    static func startHelper(staged: URL, current: String, launcherPID: pid_t) -> pid_t? {
        let fm = FileManager.default
        let dir = workDir()
        // Copied out of the bundle: the bundle is what the helper replaces.
        let script = dir.appendingPathComponent("apply-update.sh")
        guard let bundled = Bundle.main.url(forResource: "apply-update", withExtension: "sh") else { return nil }
        do {
            try? fm.removeItem(at: script)
            try fm.copyItem(at: bundled, to: script)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch { return nil }
        // A lock whose owner lives means a helper is running. One with no owner, a dead owner,
        // or older than any helper run (a minute's wait plus copy and checks) is stale.
        if let owner = lockOwner() {
            let since = (try? fm.attributesOfItem(atPath: lockDir.path))?[.modificationDate] as? Date
            let fresh = since.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false
            if owner > 0, fresh, kill(owner, 0) == 0 { return nil }
            try? fm.removeItem(at: lockDir)
        }
        // The copy in the work dir is what runs: it must still be the bundle's own, byte for byte.
        guard let want = sha256(of: bundled), sha256(of: script) == want else { return nil }
        guard let helper = spawnHelper(script: script, launcherPID: launcherPID, staged: staged,
                                       current: current, dir: dir) else { return nil }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if lockOwner() == helper { return helper }
            if !Detach.isAlive(helper) { return nil }
            usleep(100_000)
        }
        cancelHelper(helper)
        return nil
    }

    /// The helper's command line: `env -i` with PATH alone and zsh without startup files, so
    /// nothing from the launcher's environment (`launchctl setenv`, a test hook) or ~/.zshenv
    /// reaches it. Detach.spawn passes the caller's whole environment through osascript.
    static func helperCommand(script: URL, launcherPID: pid_t, staged: URL, current: String,
                              dir: URL) -> [String] {
        ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "/bin/zsh", "-f", script.path,
         String(launcherPID), staged.path, current, dir.path, UpdateRules.requirement]
    }

    /// Start `script` detached as the helper, logging to the work dir's apply-update.log.
    /// `--selftest-updater` runs a probe through it to see the environment the helper gets.
    static func spawnHelper(script: URL, launcherPID: pid_t, staged: URL, current: String, dir: URL) -> pid_t? {
        let cmd = helperCommand(script: script, launcherPID: launcherPID, staged: staged, current: current, dir: dir)
        return Detach.spawn(URL(fileURLWithPath: cmd[0]), args: Array(cmd.dropFirst()), env: [:], cwd: dir,
                            stdoutPath: dir.appendingPathComponent("apply-update.log").path)
    }

    /// Tell a waiting helper to leave the app alone (the launcher is not quitting after all).
    static func cancelHelper(_ helper: pid_t) {
        FileManager.default.createFile(atPath: workDir().appendingPathComponent("apply.cancel-\(helper)").path,
                                       contents: nil)
    }

    private static func lockOwner() -> pid_t? {
        let pidFile = lockDir.appendingPathComponent("pid")
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8) else {
            return FileManager.default.fileExists(atPath: lockDir.path) ? 0 : nil
        }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// What a helper left before reopening this launcher, consumed so it counts once.
    static func takeHelperFailure() -> UpdateRules.HelperFailure? {
        let url = workDir().appendingPathComponent("last-failure")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return UpdateRules.helperFailure(from: s)
    }

    // MARK: Processes

    /// Run a tool with no stdin and no output, and a deadline. Status -1: could not start;
    /// -2: killed at the deadline; -3: died of a signal (a signal's number is no exit status).
    /// None of them is a verdict on the update.
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        // stdin at /dev/null: hdiutil answers a licence prompt with "no" instead of waiting.
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        guard (try? p.run()) != nil else { return -1 }
        if exited.wait(timeout: .now() + timeout) == .success {
            return p.terminationReason == .uncaughtSignal ? -3 : p.terminationStatus
        }
        // Not reaped until the handler has run, so this pid is still the tool's.
        p.terminate()
        if exited.wait(timeout: .now() + 10) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 10)
        }
        return -2
    }
}

/// Follows a release download's redirects only to GitHub's own download hosts, over https.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // nil stops at the redirect, which then fails the HTTP 200 check.
        completionHandler(request.url.map(UpdateRules.isTrustedRedirect) == true ? request : nil)
    }
}
