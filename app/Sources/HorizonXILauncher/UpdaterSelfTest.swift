import Foundation

/// `--selftest-updater`: the update rules, headless. Version/build comparison, asset-name and tag
/// parsing, the API-response fixture, the rejected-tag memory, the URL checks, tool exit statuses,
/// failed-Restart counting, and the helper's clean environment (a probe script started through
/// the real detached spawn, in a temporary folder). No network, no download, nothing staged or
/// swapped. The rejected-tag and failure checks use their own defaults domain, never the
/// launcher's (that would make a real launcher skip a real release).
///
/// `--selftest-updater --dmg <file> --tag <vX.Y> [--expect-rejected]` instead stages a release
/// disk image exactly as the updater would (mount read-only, copy out, bundle id, version and
/// build, signing requirement, Gatekeeper), in a temporary folder that is deleted afterwards.
/// The build comes from the file name, as it would from the release asset. Nothing is installed.
///
/// `--selftest-updater --fetch` runs the network half for real against the current latest release:
/// the API call, the download through GitHub's redirect (the redirect guard), GitHub's digest,
/// then the same staging, all in a temporary folder. Read-only on GitHub; nothing is installed.
/// Passes when the release stages or is rejected for a stated reason; fails on anything else.
extension Headless {
    @MainActor static func runUpdaterSelfTest() -> Never {
        let args = CommandLine.arguments
        if let d = args.firstIndex(of: "--dmg"), d + 1 < args.count {
            let tag = args.firstIndex(of: "--tag").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
            exit(updaterStageCheck(dmg: URL(fileURLWithPath: args[d + 1]), tag: tag,
                                   expectRejected: args.contains("--expect-rejected")))
        }
        if args.contains("--fetch") { exit(updaterFetchCheck()) }
        typealias B = UpdateRules.Build
        func offered(_ local: (String, Int), _ asset: String, tag: String) -> Bool {
            guard let v = UpdateRules.version(fromTag: tag) else { return false }
            return UpdateRules.isOffered(B(version: v, build: UpdateRules.build(fromAssetName: asset)),
                                         over: B(version: local.0, build: local.1))
        }
        var checks: [(String, Bool, Bool)] = [
            // The table the release plan depends on.
            ("3.9 b58 vs v3.9 legacy asset: not offered",
             offered(("3.9", 58), "FFXI-on-Mac-3.9.dmg", tag: "v3.9"), false),
            ("3.9 b59 vs v3.10 b60: offered",
             offered(("3.9", 59), "FFXI-on-Mac-3.10-b60.dmg", tag: "v3.10"), true),
            ("3.10 b65 vs v3.10 b64: not offered",
             offered(("3.10", 65), "FFXI-on-Mac-3.10-b64.dmg", tag: "v3.10"), false),
            ("3.10 b59 vs v3.10 b65: offered",
             offered(("3.10", 59), "FFXI-on-Mac-3.10-b65.dmg", tag: "v3.10"), true),
            ("equal version and build: not offered",
             offered(("3.10", 60), "FFXI-on-Mac-3.10-b60.dmg", tag: "v3.10"), false),
            ("older short version with a higher build: not offered",
             offered(("3.10", 1), "FFXI-on-Mac-3.9-b99.dmg", tag: "v3.9"), false),
            ("3.8 b48 branch build vs v3.9 legacy: offered (newer short version)",
             offered(("3.8", 48), "FFXI-on-Mac-3.9.dmg", tag: "v3.9"), true),
            ("3.9.1 > 3.9", UpdateRules.compare("3.9.1", "3.9") > 0, true),
            ("3.10 > 3.9 (numeric, not text)", UpdateRules.compare("3.10", "3.9") > 0, true),
            ("3.9 == 3.9.0", UpdateRules.compare("3.9", "3.9.0") == 0, true),
            // Asset names.
            ("asset build parsed", UpdateRules.build(fromAssetName: "FFXI-on-Mac-3.10-b60.dmg") == 60, true),
            ("legacy asset has build 0", UpdateRules.build(fromAssetName: "FFXI-on-Mac-3.9.dmg") == 0, true),
            ("build must sit right before .dmg",
             UpdateRules.build(fromAssetName: "FFXI-on-Mac-3.10-b60-x.dmg") == 0, true),
            ("upper-case .DMG still parsed", UpdateRules.build(fromAssetName: "FFXI-on-Mac-3.10-b7.DMG") == 7, true),
            // Tags.
            ("tag v3.10 accepted", UpdateRules.version(fromTag: "v3.10") == "3.10", true),
            ("tag v3.9.1 accepted", UpdateRules.version(fromTag: "v3.9.1") == "3.9.1", true),
            ("tag v4.0-rc1 refused", UpdateRules.version(fromTag: "v4.0-rc1") == nil, true),
            ("tag without v refused", UpdateRules.version(fromTag: "3.10") == nil, true),
            ("tag v4 refused", UpdateRules.version(fromTag: "v4") == nil, true),
            ("tag with trailing newline refused", UpdateRules.version(fromTag: "v4.0\n") == nil, true),
        ]

        // URL checks: the first link must be github.com under this repo; redirects only to
        // GitHub's own hosts; always https.
        let asset = "https://github.com/danielalanbates/FFXI-on-Mac/releases/download/v3.10/FFXI-on-Mac-3.10-b60.dmg"
        checks += [
            ("asset on github.com under the repo", UpdateRules.isTrustedAssetURL(URL(string: asset)!), true),
            ("asset over http refused",
             UpdateRules.isTrustedAssetURL(URL(string: asset.replacingOccurrences(of: "https:", with: "http:"))!), false),
            ("asset on another repo refused",
             UpdateRules.isTrustedAssetURL(URL(string: "https://github.com/someone/FFXI-on-Mac/releases/download/v3.10/x.dmg")!), false),
            ("asset on a lookalike host refused",
             UpdateRules.isTrustedAssetURL(URL(string: "https://github.com.evil.example/danielalanbates/FFXI-on-Mac/releases/download/v3.10/x.dmg")!), false),
            ("asset first link on the CDN refused",
             UpdateRules.isTrustedAssetURL(URL(string: "https://release-assets.githubusercontent.com/x")!), false),
            ("redirect to release-assets.githubusercontent.com allowed",
             UpdateRules.isTrustedRedirect(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/x")!), true),
            ("redirect to objects.githubusercontent.com allowed",
             UpdateRules.isTrustedRedirect(URL(string: "https://objects.githubusercontent.com/x")!), true),
            ("API redirect within api.github.com allowed (renamed repo)",
             UpdateRules.isTrustedRedirect(URL(string: "https://api.github.com/repositories/1328293562/releases/latest")!), true),
            ("redirect over http refused",
             UpdateRules.isTrustedRedirect(URL(string: "http://release-assets.githubusercontent.com/x")!), false),
            ("redirect elsewhere refused",
             UpdateRules.isTrustedRedirect(URL(string: "https://example.com/x.dmg")!), false),
        ]

        // The /releases/latest shape (v3.9's real fields, the asset renamed to carry a build).
        func api(tag: String, name: String, link: String? = nil, prerelease: Bool = false) -> [String: Any] {
            ["tag_name": tag, "draft": false, "prerelease": prerelease,
             "published_at": "2026-10-20T12:00:00Z",
             "html_url": "https://github.com/danielalanbates/FFXI-on-Mac/releases/tag/\(tag)",
             "assets": [["name": "README.txt", "browser_download_url": "https://github.com/x"],
                        ["name": name, "state": "uploaded",
                         "browser_download_url": link ?? "https://github.com/danielalanbates/FFXI-on-Mac/releases/download/\(tag)/\(name)",
                         "digest": "sha256:629DFBC91A901EEC4FEF2EC488A9448B99D4DF6570944318DD7A53753E091191"]]]
        }
        let parsed = UpdateRules.release(fromAPI: api(tag: "v3.10", name: "FFXI-on-Mac-3.10-b60.dmg"))
        checks += [
            ("API release parsed: tag, version, build",
             parsed.map { $0.tag == "v3.10" && $0.version == "3.10" && $0.build.build == 60 } ?? false, true),
            ("API digest lower-cased without its prefix",
             parsed?.sha256 == "629dfbc91a901eec4fef2ec488a9448b99d4df6570944318dd7a53753e091191", true),
            ("API page link kept", parsed?.pageURL.absoluteString.hasSuffix("/releases/tag/v3.10") ?? false, true),
            ("API prerelease ignored",
             UpdateRules.release(fromAPI: api(tag: "v3.10", name: "FFXI-on-Mac-3.10-b60.dmg", prerelease: true)) == nil, true),
            ("API rc tag ignored",
             UpdateRules.release(fromAPI: api(tag: "v3.10-rc1", name: "FFXI-on-Mac-3.10-b60.dmg")) == nil, true),
            ("API asset off github.com ignored",
             UpdateRules.release(fromAPI: api(tag: "v3.10", name: "FFXI-on-Mac-3.10-b60.dmg",
                                              link: "https://example.com/FFXI-on-Mac-3.10-b60.dmg")) == nil, true),
            ("API legacy v3.9 asset has build 0",
             UpdateRules.release(fromAPI: api(tag: "v3.9", name: "FFXI-on-Mac-3.9.dmg"))?.build.build == 0, true),
            ("API unrelated version asset ignored",
             UpdateRules.release(fromAPI: api(tag: "v3.10", name: "FFXI-on-Mac-3.9-b99.dmg")) == nil, true),
            ("API beta-named asset attached to stable tag ignored",
             UpdateRules.release(fromAPI: api(tag: "v3.10", name: "FFXI-on-Mac-3.10-beta-b99.dmg")) == nil, true),
            ("API asset from another tag ignored",
             UpdateRules.release(fromAPI: api(tag: "v3.10", name: "FFXI-on-Mac-3.10-b60.dmg",
                                              link: asset.replacingOccurrences(of: "/v3.10/", with: "/v3.9/"))) == nil, true),
            ("API overflowing build ignored",
             UpdateRules.release(fromAPI: api(tag: "v3.10", name: "FFXI-on-Mac-3.10-b999999999999999999999.dmg")) == nil, true),
        ]

        let fixture = api(tag: "v3.10", name: "FFXI-on-Mac-3.10-b60.dmg")
        for field in ["draft", "prerelease", "published_at"] {
            var missing = fixture
            missing.removeValue(forKey: field)
            checks.append(("API missing \(field) is not a published stable release",
                           UpdateRules.release(fromAPI: missing) == nil, true))
        }
        var draft = fixture
        draft["draft"] = true
        checks.append(("API draft ignored", UpdateRules.release(fromAPI: draft) == nil, true))
        var uploading = fixture
        var uploadAssets = uploading["assets"] as! [[String: Any]]
        uploadAssets[1]["state"] = "starter"
        uploading["assets"] = uploadAssets
        checks.append(("API unfinished upload ignored", UpdateRules.release(fromAPI: uploading) == nil, true))
        var malformedDigest = fixture
        var digestAssets = malformedDigest["assets"] as! [[String: Any]]
        digestAssets[1]["digest"] = "sha256:broken"
        malformedDigest["assets"] = digestAssets
        checks.append(("API malformed sha256 ignored", UpdateRules.release(fromAPI: malformedDigest) == nil, true))
        var multiple = fixture
        let other = api(tag: "v3.10", name: "FFXI-on-Mac-3.10-b61.dmg")["assets"] as! [[String: Any]]
        multiple["assets"] = (fixture["assets"] as! [[String: Any]]) + other
        checks.append(("API chooses newest matching build independent of attachment order",
                       UpdateRules.release(fromAPI: multiple)?.build.build == 61, true))

        // An authoritative absence clears a staged offer; network/server failures preserve the
        // last verified copy. No network requests are made by these response-policy checks.
        do {
            let absent = try UpdateWork.latestRelease(data: Data(), statusCode: 404)
            checks.append(("HTTP 404 means no current published update", absent == nil, true))
            let json = try JSONSerialization.data(withJSONObject: fixture)
            let current = try UpdateWork.latestRelease(data: json, statusCode: 200)
            checks.append(("HTTP 200 parses the published release", current == parsed, true))
        } catch {
            checks.append(("latest-release response parsing: \(error)", false, true))
        }
        for status in [403, 429, 500, -1] {
            do {
                _ = try UpdateWork.latestRelease(data: Data(), statusCode: status)
                checks.append(("HTTP \(status) is transient, not a withdrawn release", false, true))
            } catch {
                checks.append(("HTTP \(status) is transient, not a withdrawn release", true, true))
            }
        }

        // Restart re-asks GitHub: only the release that is still exactly the latest installs.
        if let staged = parsed {
            func latest(_ tag: String, _ name: String) -> UpdateRelease? {
                UpdateRules.release(fromAPI: api(tag: tag, name: name))
            }
            checks += [
                ("Restart: still the latest release, installed",
                 UpdateRules.isStillLatest(staged, latest: latest("v3.10", "FFXI-on-Mac-3.10-b60.dmg")), true),
                ("Restart: withdrawn (nothing usable is latest), not installed",
                 UpdateRules.isStillLatest(staged, latest: nil), false),
                ("Restart: latest rolled back to v3.9, not installed",
                 UpdateRules.isStillLatest(staged, latest: latest("v3.9", "FFXI-on-Mac-3.9.dmg")), false),
                ("Restart: same tag, rebuilt asset b61, not installed",
                 UpdateRules.isStillLatest(staged, latest: latest("v3.10", "FFXI-on-Mac-3.10-b61.dmg")), false),
                ("Restart: overtaken by v3.11, not installed (v3.11 is staged instead)",
                 UpdateRules.isStillLatest(staged, latest: latest("v3.11", "FFXI-on-Mac-3.11-b62.dmg")), false),
            ]
            let replaced = UpdateRelease(tag: staged.tag, build: staged.build, assetName: staged.assetName,
                                         dmgURL: staged.dmgURL, pageURL: staged.pageURL,
                                         sha256: String(repeating: "a", count: 64))
            checks.append(("Restart: same name and build with a replacement digest, not installed",
                           UpdateRules.isStillLatest(staged, latest: replaced), false))
        }

        // Rejected-tag memory, in a scratch domain so the real defaults are never touched. One
        // fixed name, emptied before and after (cfprefsd may leave its empty plist behind).
        let suite = "org.batesai.horizonxi-on-mac.selftest-updater"
        if let d = UserDefaults(suiteName: suite), let newer = parsed {
            d.removePersistentDomain(forName: suite)
            let here = B(version: "3.9", build: 59)
            checks.append(("nothing rejected at first", UpdateRules.isRejected("v3.10", in: d), false))
            // Every offer, Restart or Download, waits for a staged and verified copy.
            checks.append(("a newer release is staged before any line shows",
                           UpdateRules.step(for: newer, over: here, in: d) == .stage, true))
            checks.append(("the same release is up to date",
                           UpdateRules.step(for: newer, over: B(version: "3.10", build: 60), in: d) == .upToDate, true))
            UpdateRules.reject("v3.10", in: d)
            checks.append(("a rejected tag is remembered", UpdateRules.isRejected("v3.10", in: d), true))
            checks.append(("a different tag is not rejected", UpdateRules.isRejected("v3.11", in: d), false))
            checks.append(("a rejected tag is dropped before the Download line could show",
                           UpdateRules.step(for: newer, over: here, in: d) == .rejected, true))
            // Failed Restarts, per release: the Download link after two, or after one that
            // every try would meet.
            checks.append(("Restart offered before any failure", UpdateRules.restartGivenUp("v3.10", in: d), false))
            UpdateRules.recordRestartFailure("v3.10", lasting: false, in: d)
            checks.append(("Restart still offered after one failure", UpdateRules.restartGivenUp("v3.10", in: d), false))
            UpdateRules.recordRestartFailure("v3.10", lasting: false, in: d)
            checks.append(("Download link after two failures", UpdateRules.restartGivenUp("v3.10", in: d), true))
            checks.append(("another release still gets Restart", UpdateRules.restartGivenUp("v3.11", in: d), false))
            UpdateRules.recordRestartFailure("v3.11", lasting: false, in: d)
            checks.append(("a failure of another release starts its own count",
                           UpdateRules.restartGivenUp("v3.11", in: d), false))
            UpdateRules.recordRestartFailure("v3.12", lasting: true, in: d)
            checks.append(("Download link after one failure that would recur",
                           UpdateRules.restartGivenUp("v3.12", in: d), true))
            d.removePersistentDomain(forName: suite)
        } else {
            checks.append(("scratch defaults suite", false, true))
        }
        // A copy run from the work dir (a kept previous copy) never replaces itself.
        let updates = "/Users/x/Library/Application Support/HorizonXI-on-Mac/updates"
        checks += [
            ("a previous copy in the work dir is inside it",
             UpdateRules.isInside(updates + "/previous-3.9-b59.app", dir: updates), true),
            ("the installed app is not", UpdateRules.isInside("/Applications/FFXI-on-Mac.app", dir: updates), false),
            ("a folder that merely starts the same is not",
             UpdateRules.isInside(updates + "-old/FFXI-on-Mac.app", dir: updates), false),
            ("a path with .. is resolved first",
             UpdateRules.isInside(updates + "/../updates/previous-3.9-b59.app", dir: updates), true),
        ]

        let launcherPath = "/Applications/FFXI-on-Mac.app"
        let embeddedGuide = launcherPath + "/Contents/Helpers/Vanaguide Server-Safe.app/Contents/MacOS/VanaguideCompanion"
        func guideBlocks(_ id: String?, _ path: String?) -> Bool {
            UpdateRules.embeddedCompanionIsRunning(in: launcherPath, applications: [
                UpdateRules.RunningApplication(bundleIdentifier: id, executablePath: path),
            ])
        }
        checks += [
            ("running embedded guide blocks a launcher swap",
             guideBlocks(UpdateRules.companionBundleID, embeddedGuide), true),
            ("embedded guide executable blocks even without bundle metadata",
             guideBlocks(nil, embeddedGuide), true),
            ("known guide with unreadable process path stays conservative",
             guideBlocks(UpdateRules.companionBundleID, nil), true),
            ("independent Applications guide permits the launcher swap",
             guideBlocks(UpdateRules.companionBundleID,
                         "/Applications/Vanaguide Server-Safe.app/Contents/MacOS/VanaguideCompanion"), false),
            ("guide under a lookalike launcher folder is independent",
             guideBlocks(UpdateRules.companionBundleID,
                         launcherPath + "-old/Contents/Helpers/Vanaguide.app/Contents/MacOS/VanaguideCompanion"), false),
            ("ordinary launcher process is not its embedded guide",
             guideBlocks(UpdateRules.bundleID, launcherPath + "/Contents/MacOS/FFXI-on-Mac"), false),
            ("guide path normalizes dot components before matching",
             guideBlocks(nil, launcherPath + "/Contents/Helpers/../Helpers/Vanaguide.app/Contents/MacOS/VanaguideCompanion"), true),
            ("unknown process without a path does not invent a live guide",
             guideBlocks(nil, nil), false),
        ]

        // The helper starts with a clean environment, through the launcher's real spawn path.
        checks += updaterSpawnChecks()

        // What apply-update.sh leaves in last-failure.
        let lasting = UpdateRules.helperFailure(from: "reason=could not move the current app aside\ntag=v3.10\nlasting=1\n")
        let once = UpdateRules.helperFailure(from: "reason=the launcher did not quit within 60 s\ntag=v3.10\nlasting=0\n")
        checks += [
            ("helper failure: reason, tag and lasting read",
             lasting == UpdateRules.HelperFailure(reason: "could not move the current app aside", tag: "v3.10", lasting: true), true),
            ("helper failure: a one-off is not lasting", once?.lasting == false && once?.tag == "v3.10", true),
            ("helper failure: a reason with = in it is kept whole",
             UpdateRules.helperFailure(from: "reason=a=b\ntag=v3.10\nlasting=0")?.reason == "a=b", true),
            ("helper failure: plain text is all reason, no tag",
             UpdateRules.helperFailure(from: "interrupted\n") == UpdateRules.HelperFailure(reason: "interrupted", tag: nil, lasting: false), true),
            ("helper failure: an empty file is nothing", UpdateRules.helperFailure(from: "\n") == nil, true),
        ]

        // Exit statuses: only a verdict rejects a release for good; a tool that failed, crashed or
        // ran out of time is tried again later.
        checks += [
            ("codesign 1 (signature broken or missing) is a refusal", UpdateRules.isRefusal(codesign: 1), true),
            ("codesign 3 (requirement not met) is a refusal", UpdateRules.isRefusal(codesign: 3), true),
            ("codesign 2 (bad arguments) is no verdict", UpdateRules.isRefusal(codesign: 2), false),
            ("codesign killed by a signal is no verdict", UpdateRules.isRefusal(codesign: -3), false),
            ("codesign past its deadline is no verdict", UpdateRules.isRefusal(codesign: -2), false),
            ("spctl 3 (Gatekeeper said no) is a refusal", UpdateRules.isRefusal(spctl: 3), true),
            ("spctl 1 (assessment failed) is no verdict", UpdateRules.isRefusal(spctl: 1), false),
            ("spctl killed by a signal is no verdict", UpdateRules.isRefusal(spctl: -3), false),
            ("a tool killed by a signal reports -3, not the signal's number",
             UpdateWork.run("/bin/sh", ["-c", "kill -KILL $$"], timeout: 10) == -3, true),
            ("a tool's own exit status is passed through",
             UpdateWork.run("/bin/sh", ["-c", "exit 3"], timeout: 10) == 3, true),
        ]
        checks.append(("requirement pins Apple anchor, bundle id and team",
                       UpdateRules.requirement == #"anchor apple generic and identifier "org.batesai.horizonxi-on-mac" and certificate leaf[subject.OU] = "MG4YW8XX2Z""#,
                       true))

        var failures = 0
        for (name, got, expected) in checks {
            let passed = got == expected
            if !passed { failures += 1 }
            print("  \(passed ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// `UpdateWork.spawnHelper` with a probe in place of apply-update.sh, and a test hook plus a
    /// marker set in this process's own environment: neither may reach the probe.
    private static func updaterSpawnChecks() -> [(String, Bool, Bool)] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("hxi-selftest-updater spawn '\"\\-\(getpid())")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("staged-v0.0/FFXI-on-Mac.app")
        let current = "/nonexistent/FFXI-on-Mac.app"
        let probe = dir.appendingPathComponent("probe.sh")
        let cmd = UpdateWork.helperCommand(script: probe, launcherPID: 1, staged: staged, current: current, dir: dir)
        var checks: [(String, Bool, Bool)] = [
            ("helper command: env -i, PATH alone, zsh -f",
             Array(cmd.prefix(5)) == ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "/bin/zsh", "-f"], true),
            ("helper command: the script and its five arguments, no test hook", cmd.count == 11, true),
        ]
        // Written to a side file and renamed, so a half-written result is never read.
        let script = #"print -rl -- "args=$#" "$(/usr/bin/env)" > "$4/probe.tmp" && /bin/mv "$4/probe.tmp" "$4/probe.out""#
        guard (try? (script + "\n").write(to: probe, atomically: true, encoding: .utf8)) != nil else {
            return checks + [("probe written", false, true)]
        }
        setenv("HXI_UPDATE_TEST_STUBS", dir.path, 1)
        setenv("HXI_SELFTEST_LEAK", "1", 1)
        defer { unsetenv("HXI_UPDATE_TEST_STUBS"); unsetenv("HXI_SELFTEST_LEAK") }
        let started = UpdateWork.spawnHelper(script: probe, launcherPID: 1, staged: staged,
                                             current: current, dir: dir) != nil
        checks.append(("probe started through the launcher's detached spawn", started, true))
        let out = dir.appendingPathComponent("probe.out")
        let deadline = Date().addingTimeInterval(15)
        while started, Date() < deadline, !fm.fileExists(atPath: out.path) { usleep(100_000) }
        let lines = ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        checks += [
            ("probe ran with the helper's five arguments", lines.first == "args=5", true),
            ("nothing from the launcher's environment reaches it", lines.contains { $0.hasPrefix("HXI_") }, false),
            ("its PATH is the fixed one", lines.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), true),
        ]
        return checks
    }

    private static func updaterFetchCheck() -> Int32 {
        final class Outcome: @unchecked Sendable { var checks: [(String, Bool)] = [] }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("hxi-selftest-updater-fetch-\(getpid())")
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let release: UpdateRelease
            do {
                guard let r = try await UpdateWork.fetchLatest() else {
                    outcome.checks.append(("latest release has a usable .dmg", false)); return
                }
                release = r
            } catch {
                outcome.checks.append(("GitHub API answered: \(error.localizedDescription)", false)); return
            }
            print("  latest: \(release.tag) \(release.assetName) (build \(release.build.build))")
            outcome.checks.append(("asset link is on github.com under the repo", UpdateRules.isTrustedAssetURL(release.dmgURL)))
            let dmg: URL
            do {
                dmg = try await UpdateWork.download(release, into: dir)
            } catch {
                outcome.checks.append(("downloaded through GitHub's redirect: \(error.localizedDescription)", false)); return
            }
            let size = ((try? fm.attributesOfItem(atPath: dmg.path))?[.size] as? Int) ?? 0
            outcome.checks.append(("downloaded through GitHub's redirect (\(size) bytes)", size > 0))
            if let want = release.sha256 {
                outcome.checks.append(("matches GitHub's sha256 digest", UpdateWork.sha256(of: dmg) == want))
            } else {
                print("  note: GitHub gave no digest for this asset")
            }
            do {
                try UpdateWork.stage(dmg: dmg, release: release, in: dir)
                outcome.checks.append(("staged and verified (an update would be offered as ready)", true))
            } catch UpdateFailure.rejected(let why) {
                print("  rejected: \(why)")
                outcome.checks.append(("staging ended in a verdict (rejected, see above)", true))
            } catch {
                outcome.checks.append(("staging ended in a verdict: \(error.localizedDescription)", false))
            }
        }
        done.wait()
        var failures = 0
        for (label, passed) in outcome.checks {
            if !passed { failures += 1 }
            print("  \(passed ? "ok  " : "FAIL") \(label)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    private static func updaterStageCheck(dmg: URL, tag: String, expectRejected: Bool) -> Int32 {
        guard let version = UpdateRules.version(fromTag: tag) else {
            print("  FAIL --tag must look like v3.10 (got \"\(tag)\")")
            return 2
        }
        let name = dmg.lastPathComponent
        let release = UpdateRelease(
            tag: tag, build: UpdateRules.Build(version: version, build: UpdateRules.build(fromAssetName: name)),
            assetName: name,
            dmgURL: URL(string: "https://github.com/\(UpdateRules.repo)/releases/download/\(tag)/\(name)")!,
            pageURL: URL(string: "https://github.com/\(UpdateRules.repo)/releases/latest")!, sha256: nil)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("hxi-selftest-updater-\(getpid())")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let staged: Bool
        do {
            let app = try UpdateWork.stage(dmg: dmg, release: release, in: dir)
            print("  staged and verified as \(tag) b\(release.build.build): \(app.lastPathComponent)")
            staged = true
        } catch UpdateFailure.rejected(let why) {
            print("  rejected as \(tag) b\(release.build.build): \(why)")
            staged = false
        } catch {
            print("  FAIL could not finish: \(error.localizedDescription)")
            return 1
        }
        // A rejected stage leaves nothing behind; an accepted one leaves only its staged copy.
        let left = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        let clean = staged ? left == ["staged-\(tag)"] : left.isEmpty
        let checks = [("outcome is \(expectRejected ? "rejected" : "accepted")", staged != expectRejected),
                      ("work dir clean afterwards (\(left.joined(separator: ", ")))", clean)]
        var failures = 0
        for (label, passed) in checks {
            if !passed { failures += 1 }
            print("  \(passed ? "ok  " : "FAIL") \(label)")
        }
        print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
