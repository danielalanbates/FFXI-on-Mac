// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// `--selftest-retroachievements`: decoding of documented-shape responses, the snapshot file,
/// cache timing, failure handling and the Keychain wrapper. No network: every request goes to
/// a fake transport. Files go to a temporary folder; the Keychain test uses a service name of
/// its own and deletes it. Never touches a game folder, the real key or the real registry.
extension Headless {
    /// Verbatim raw HTTP example from api-docs.retroachievements.org,
    /// v1/get-game-info-and-user-progress (read 2026-09-26).
    static let raDocumentedProgress = #"""
    {
      "ID": 1,
      "Title": "Sonic the Hedgehog",
      "ConsoleID": 1,
      "ForumTopicID": 112,
      "Flags": null,
      "ImageIcon": "/Images/067895.png",
      "ImageTitle": "/Images/054993.png",
      "ImageIngame": "/Images/000010.png",
      "ImageBoxArt": "/Images/051872.png",
      "Publisher": "",
      "Developer": "",
      "Genre": "",
      "Released": "1992-06-02 00:00:00",
      "ReleasedAtGranularity": "day",
      "IsFinal": false,
      "RichPresencePatch": "cce60593880d25c97797446ed33eaffb",
      "GuideURL": null,
      "ConsoleName": "Mega Drive",
      "ParentGameID": null,
      "NumDistinctPlayers": 27080,
      "NumAchievements": 23,
      "Achievements": {
        "9": {
          "ID": 9,
          "NumAwarded": 24273,
          "NumAwardedHardcore": 10831,
          "Title": "That Was Easy",
          "Description": "Complete the first act in Green Hill Zone",
          "Points": 3,
          "TrueRatio": 3,
          "Author": "Scott",
          "AuthorULID": "00003EMFWR7XB8SDPEHB3K56ZQ",
          "DateModified": "2023-08-08 00:36:59",
          "DateCreated": "2012-11-02 00:03:12",
          "BadgeName": "250336",
          "DisplayOrder": 1,
          "MemAddr": "22c9d5e2cd7571df18a1a1b43dfe1fea",
          "type": "progression",
          "DateEarnedHardcore": "2016-03-12 17:47:29",
          "DateEarned": "2016-03-12 17:47:29"
        }
      },
      "NumAwardedToUser": 23,
      "NumAwardedToUserHardcore": 23,
      "NumDistinctPlayersCasual": 27080,
      "NumDistinctPlayersHardcore": 27080,
      "UserCompletion": "100.00%",
      "UserCompletionHardcore": "100.00%",
      "UserTotalPlaytime": 60,
      "HighestAwardKind": "mastered",
      "HighestAwardDate": "2024-04-23T21:28:49+00:00"
    }
    """#

    /// Same documented shape for an FFXI set: one earned (softcore only), one not earned (RA
    /// leaves the date keys out), numbers served as strings once.
    static func raFFXIFixture(id: Int, title: String) -> String {
        #"""
        {"ID": \#(id), "Title": "\#(title)", "ConsoleID": 78, "NumAchievements": "2",
         "Achievements": {
           "\#(id * 10 + 1)": {"ID": \#(id * 10 + 1), "Title": "A \"quoted\" start", "Description": "Complete \"Smoke on the Mountain\".",
                   "Points": 5, "BadgeName": "1", "DisplayOrder": 1, "type": "progression",
                   "DateEarned": "2026-09-20 03:04:05"},
           "\#(id * 10 + 2)": {"ID": "\#(id * 10 + 2)", "Title": "Not yet", "Description": "Obtain the Rank 2 key item.",
                   "Points": "10", "BadgeName": "2", "DisplayOrder": 2, "type": null}
         },
         "NumAwardedToUser": 1, "NumAwardedToUserHardcore": 0,
         "UserCompletion": "50.00%", "UserCompletionHardcore": "0.00%"}
        """#
    }

    @MainActor static func runRetroAchievementsSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ra-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let key = "SELFTESTKEY0123456789abcdef"

        // 1. Decoding the documented example.
        let doc = try? JSONDecoder().decode(RAUserProgress.self, from: Data(raDocumentedProgress.utf8))
        check("documented example decodes", doc != nil)
        if let doc {
            check("documented example: id, title, counts",
                  doc.id == 1 && doc.title == "Sonic the Hedgehog" && doc.numAchievements == 23
                      && doc.numAwardedToUser == 23 && doc.achievements.count == 1)
            let a = doc.achievements.first
            check("documented example: achievement fields",
                  a?.id == 9 && a?.title == "That Was Easy" && a?.points == 3 && a?.type == "progression"
                      && a?.dateEarned == "2016-03-12 17:47:29" && a?.dateEarnedHardcore == "2016-03-12 17:47:29")
            let g = RASnapshotGame(doc, fallbackID: 1, fallbackTitle: "x")
            check("documented example: snapshot game (total from NumAchievements, earned counted)",
                  g.gameID == 1 && g.total == 23 && g.earned == 1
                      && g.achievements["9"]?.earnedAt == "2016-03-12T17:47:29Z"
                      && g.achievements["9"]?.earnedHardcoreAt == "2016-03-12T17:47:29Z")
        }
        let ffxi = try? JSONDecoder().decode(RAUserProgress.self, from: Data(raFFXIFixture(id: 28275, title: "Final Fantasy XI").utf8))
        check("string numbers and missing dates decode", ffxi?.achievements.count == 2
                  && ffxi?.numAchievements == 2
                  && ffxi?.achievements.first(where: { $0.id == 282752 })?.points == 10
                  && ffxi?.achievements.first(where: { $0.id == 282752 })?.dateEarned == nil)
        let emptyArray = try? JSONDecoder().decode(RAUserProgress.self, from: Data(#"{"ID": 5, "Title": "t", "NumAchievements": 0, "Achievements": []}"#.utf8))
        check("PHP empty-array Achievements decodes as none", emptyArray?.achievements.isEmpty == true)
        check("RA dates become ISO 8601 UTC",
              RetroAchievements.isoDate("2016-03-12 17:47:29") == "2016-03-12T17:47:29Z"
                  && RetroAchievements.isoDate(nil) == nil && RetroAchievements.isoDate("") == nil
                  && RetroAchievements.isoDate("2024-04-23T21:28:49+00:00") == "2024-04-23T21:28:49+00:00")

        // 2. Fetching every set through a fake transport, and the snapshot it writes.
        final class Seen: @unchecked Sendable { var urls: [URL] = []; let lock = NSLock()
            func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() } }
        let seen = Seen()
        let ok = RAFetcher { req in
            seen.add(req.url!)
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let g = Int(q.first { $0.name == "g" }?.value ?? "") ?? 0
            let title = RetroAchievements.builtinSets.first { $0.id == g }?.title ?? "?"
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(raFFXIFixture(id: g, title: title).utf8), r)
        }
        let snapURL = RetroAchievements.snapshotURL(gameDir: dir.appendingPathComponent("HorizonXI"))
        let registry = dir.appendingPathComponent("support/retroachievements-snapshots.json")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let good = runBlocking {
            await RARefresh.run(user: "Daniel", key: key, sets: RetroAchievements.builtinSets,
                                fetcher: ok, to: snapURL, registry: registry, now: t0)
        }
        check("snapshot path is config/addons/Vanaguide/retroachievements.json",
              snapURL.path.hasSuffix("HorizonXI/config/addons/Vanaguide/retroachievements.json"))
        check("fetch of every built-in set succeeds", good.error == nil && good.snapshot?.games.count == 5)
        check("one request per set, in order, to the progress endpoint with y/u/g",
              seen.urls.count == 5 && zip(seen.urls, RetroAchievements.builtinSets).allSatisfy { u, s in
                  let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
                  return u.path == "/API/API_GetGameInfoAndUserProgress.php" && u.host == "retroachievements.org"
                      && q.contains { $0.name == "y" && $0.value == key }
                      && q.contains { $0.name == "u" && $0.value == "Daniel" }
                      && q.contains { $0.name == "g" && $0.value == String(s.id) }
              })
        let written = try? Data(contentsOf: snapURL)
        check("snapshot file written", written != nil)
        let json = written.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let games = json?["games"] as? [[String: Any]]
        let first = games?.first
        let ach = first?["achievements"] as? [String: [String: Any]]
        check("snapshot top level matches the contract",
              json?["source"] as? String == "RetroAchievements" && json?["user"] as? String == "Daniel"
                  && json?["fetched_at"] as? Int == 1_790_000_000 && games?.count == 5)
        check("snapshot game matches the contract",
              first?["game_id"] as? Int == 28275 && first?["title"] as? String == "Final Fantasy XI"
                  && first?["earned"] as? Int == 1 && first?["total"] as? Int == 2 && ach?.count == 2)
        check("earned achievement: ISO date, hardcore null",
              ach?["282751"]?["earned_at"] as? String == "2026-09-20T03:04:05Z"
                  && ach?["282751"]?["earned_hardcore_at"] is NSNull)
        check("unearned achievement: both dates present as null",
              ach?["282752"]?["earned_at"] is NSNull && ach?["282752"]?["earned_hardcore_at"] is NSNull)
        check("achievement names travel with it for readers without the data file",
              ach?["282751"]?["title"] as? String == "A \"quoted\" start" && ach?["282752"]?["points"] as? Int == 10)
        check("the key is not in the snapshot",
              written.map { !String(decoding: $0, as: UTF8.self).contains(key) } ?? false)
        check("snapshot reads back equal", RASnapshotStore.read(snapURL) == good.snapshot)
        let reg = (try? Data(contentsOf: registry)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        check("registry names the snapshot for the companion", reg == [snapURL.path])
        let leftovers = (try? fm.contentsOfDirectory(atPath: snapURL.deletingLastPathComponent().path)) ?? []
        check("atomic write leaves only the snapshot behind", leftovers == ["retroachievements.json"])

        // 3. Failures keep the last good snapshot.
        let before = try? Data(contentsOf: snapURL)
        let unauthorized = RAFetcher { req in
            (Data(#"{"message":"Unauthenticated."}"#.utf8),
             HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let r401 = runBlocking {
            await RARefresh.run(user: "Daniel", key: "wrong-key-xyz", sets: RetroAchievements.builtinSets,
                                fetcher: unauthorized, to: snapURL, registry: registry)
        }
        check("401 is reported as unauthorized", r401.error == .unauthorized && r401.snapshot == nil)
        check("401 keeps the last good snapshot byte for byte", (try? Data(contentsOf: snapURL)) == before)
        let offline = RAFetcher { _ in throw URLError(.notConnectedToInternet) }
        let rOff = runBlocking {
            await RARefresh.run(user: "Daniel", key: key, sets: RetroAchievements.builtinSets,
                                fetcher: offline, to: snapURL, registry: registry)
        }
        check("offline is reported as offline", rOff.error == .offline("offline"))
        check("offline keeps the last good snapshot", (try? Data(contentsOf: snapURL)) == before)
        check("error messages never carry the key",
              [r401.error, rOff.error, RAError.http(500), RAError.badResponse("x")].compactMap { $0?.message }
                  .allSatisfy { !$0.contains(key) })
        let partial = RAFetcher { req in
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let g = Int(q.first { $0.name == "g" }?.value ?? "") ?? 0
            if g == 28303 {  // a 500 part-way through fails the whole fetch
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(raFFXIFixture(id: g, title: "t").utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let rPart = runBlocking {
            await RARefresh.run(user: "Daniel", key: key, sets: RetroAchievements.builtinSets,
                                fetcher: partial, to: snapURL, registry: registry)
        }
        check("a server error part-way fails the fetch and keeps the file",
              rPart.error == .http(500) && (try? Data(contentsOf: snapURL)) == before)
        let unknown = RAFetcher { req in
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let g = Int(q.first { $0.name == "g" }?.value ?? "") ?? 0
            let body = g == 99999 ? #"{"ID": null, "Title": null, "Achievements": []}"# : raFFXIFixture(id: g, title: "t")
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let other = dir.appendingPathComponent("Local/config/addons/Vanaguide/retroachievements.json")
        let rUnknown = runBlocking {
            await RARefresh.run(user: "Daniel", key: key, sets: RetroAchievements.sets(extra: [99999]),
                                fetcher: unknown, to: other, registry: registry)
        }
        check("an unknown extra set is skipped with a note, the rest written",
              rUnknown.error == nil && rUnknown.snapshot?.games.count == 5 && rUnknown.notes.count == 1)
        let reg2 = (try? Data(contentsOf: registry)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        check("registry lists the newest snapshot first", reg2 == [other.path, snapURL.path])
        let noKey = runBlocking {
            await RARefresh.run(user: "Daniel", key: nil, sets: RetroAchievements.builtinSets,
                                fetcher: ok, to: dir.appendingPathComponent("nokey.json"), registry: nil)
        }
        let noUser = runBlocking {
            await RARefresh.run(user: " ", key: key, sets: RetroAchievements.builtinSets,
                                fetcher: ok, to: dir.appendingPathComponent("nouser.json"), registry: nil)
        }
        check("no key / no user fail before any request and write nothing",
              noKey.error == .noKey && noUser.error == .noUser
                  && !fm.fileExists(atPath: dir.appendingPathComponent("nokey.json").path)
                  && !fm.fileExists(atPath: dir.appendingPathComponent("nouser.json").path))

        // 4. Cache timing.
        let now = Date(timeIntervalSince1970: 2_000_000)
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        let sf = RetroAchievements.shouldFetch
        check("automatic: first time fetches", sf(.automatic, now, nil, nil))
        check("automatic: a 5-minute-old snapshot is kept", !sf(.automatic, now, nil, ago(300)))
        check("automatic: an 11-minute-old snapshot is refreshed", sf(.automatic, now, nil, ago(660)))
        check("automatic: a failure 2 minutes ago is not retried yet", !sf(.automatic, now, ago(120), ago(3600)))
        check("automatic: exactly 10 minutes is due", sf(.automatic, now, ago(600), ago(600)))
        check("play: refreshes a fresh snapshot", sf(.play, now, nil, ago(30)))
        check("play: not twice within a minute", !sf(.play, now, ago(30), nil) && sf(.play, now, ago(90), nil))
        check("manual: always", sf(.manual, now, ago(1), ago(1)))

        // 5. Sets, redaction, environment.
        check("set ids parse and de-duplicate",
              RetroAchievements.parseSetIDs("28275, 99999 x;123,99999") == [28275, 99999, 123])
        check("built-in sets are the known HorizonXI ids",
              RetroAchievements.builtinSets.map(\.id) == [28275, 28303, 28317, 28359, 28547])
        check("extra ids extend the built-in table once",
              RetroAchievements.sets(extra: [28275, 99999]).map(\.id) == [28275, 28303, 28317, 28359, 28547, 99999])
        check("redaction hides the key",
              RetroAchievements.redact("y=\(key)&u=x", key: key) == "y=***&u=x")
        setenv(RetroAchievements.envKey, "selftest-env-key", 1)
        RetroAchievements.adoptEnvironmentKey()
        check("an environment key is adopted and removed from the environment",
              RetroAchievements.environmentKey == "selftest-env-key"
                  && ProcessInfo.processInfo.environment[RetroAchievements.envKey] == nil
                  && getenv(RetroAchievements.envKey) == nil)

        // 6. Keychain wrapper, on a service name of this run's own, cleaned up.
        let svc = "org.batesai.horizonxi-on-mac.retroachievements.selftest-\(UUID().uuidString)"
        let acct = RetroAchievements.keychainAccount
        defer { RAKeychain.delete(service: svc, account: acct) }
        check("keychain: nothing there at first", RAKeychain.read(service: svc, account: acct) == nil)
        var saved = true
        do { try RAKeychain.save("first", service: svc, account: acct) } catch { saved = false; print("  keychain save: \(error)") }
        check("keychain: save then read", saved && RAKeychain.read(service: svc, account: acct) == "first")
        do { try RAKeychain.save("second", service: svc, account: acct) } catch { saved = false }
        check("keychain: save again replaces", saved && RAKeychain.read(service: svc, account: acct) == "second")
        check("keychain: delete", RAKeychain.delete(service: svc, account: acct)
                  && RAKeychain.read(service: svc, account: acct) == nil)
        check("keychain: deleting nothing is fine", RAKeychain.delete(service: svc, account: acct))

        var failures = 0
        for (name, passed) in checks {
            print("  \(passed ? "ok  " : "FAIL") \(name)")
            if !passed { failures += 1 }
        }
        print(failures == 0 ? "retroachievements: all \(checks.count) checks passed" : "retroachievements: \(failures) FAILED")
        try? fm.removeItem(at: dir)
        RAKeychain.delete(service: svc, account: acct)
        exit(failures == 0 ? 0 : 1)
    }

    /// Run async work to completion from a synchronous self-test.
    static func runBlocking<T>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = RABlockingBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { box.value = await work(); sem.signal() }
        sem.wait()
        return box.value!
    }
}

private final class RABlockingBox<T>: @unchecked Sendable { var value: T? }
