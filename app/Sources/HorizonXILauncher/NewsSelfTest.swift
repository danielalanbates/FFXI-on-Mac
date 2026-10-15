import Foundation

/// `--selftest-news`: the left panel's news, on HorizonXI's real feed as captured 2026-10-15
/// (`NewsFixture`) and on synthetic payloads. No network: the fetch is swapped for canned
/// answers, and the cache lives in a temporary folder.
extension Headless {
    @MainActor static func runNewsSelfTest() -> Never {
        var checks: [(String, Bool)] = []
        let fixture = Data(NewsFixture.horizonXI.utf8)
        let items = News.parse(fixture) ?? []
        func item(_ prefix: String) -> NewsItem? { items.first { $0.slug.hasPrefix(prefix) } }

        // Reading the real feed.
        checks.append(("the captured feed parses: 10 posts, every one with a slug, title and date",
                       items.count == 10 && items.allSatisfy { !$0.slug.isEmpty && !$0.title.isEmpty && $0.date != nil }))
        checks.append(("newest first: the 2026-10-09 14:32 server notice leads",
                       items.first?.slug == "2026-10-09_server-notices_1558124900110172271"
                           && zip(items, items.dropFirst()).allSatisfy { ($0.date ?? .distantPast) >= ($1.date ?? .distantPast) }))
        // The same posts in reverse feed order sort the same.
        if let arr = try? JSONSerialization.jsonObject(with: fixture) as? [Any],
           let reversed = try? JSONSerialization.data(withJSONObject: Array(arr.reversed())) {
            checks.append(("order comes from the dates, not the feed's order",
                           News.parse(reversed)?.map(\.slug) == items.map(\.slug)))
        } else {
            checks.append(("order comes from the dates, not the feed's order", false))
        }
        checks.append(("chips are the feed's labels",
                       item("2026-10-09_patch-notes")?.label == "Patch Notes"
                           && item("2026-10-09_server-notices_1558124900")?.label == "Server Notice"
                           && item("2026-09-28_known-issues")?.label == "Known Issue"
                           && item("2026-10-02_announcements")?.label == "Announcement"))
        checks.append(("a category the feed does not label is shown by its id, readable",
                       News.label(category: "launcher-notices", label: "") == "Launcher Notices"
                           && News.label(category: "patch-notes", label: " ") == "Patch Notes"))

        // Discord's tokens.
        let late = item("2026-10-09_server-notices_1557967530")?.title ?? ""
        checks.append(("\"@everyone\" is taken off a relayed title, and the \"()\" its timestamp left",
                       late == "Apologies for the late notice - We will be doing maintenance at the normal time tomorrow"))
        checks.append(("... in every title of the feed",
                       items.allSatisfy { !$0.title.contains("@everyone") && !$0.title.contains("()") }
                           && item("2026-09-23_server-notices")?.title == "Will be doing a quick maintenance to apply an important fix"
                           && item("2026-10-02_server-notices_1555417205")?.title == "Reminder: Maintenance will be at normal time tomorrow"))
        checks.append(("user, role, channel, timestamp and emoji tokens all go; the words stay",
                       News.clean("<@123> <@!45> <@&678> see <#9012> @here at <t:1700000000:R> now <:hxi:123> !")
                           == "see at now!"
                           && News.clean("Server is back up gamers! ❤️") == "Server is back up gamers! ❤️"))
        checks.append(("a stripped timestamp's leftovers: \"before: .\" reads \"before.\"",
                       item("2026-09-27_server-notices")?.excerpt
                           == "Please plan accordingly and make sure you do not start things like dynamis unless you can finish before."))

        // What a row shows.
        let patch = item("2026-10-09_patch-notes")
        checks.append(("patch notes show their summary; notices are their title alone",
                       patch?.showsExcerpt == true && patch?.excerpt.hasPrefix("Battlefields An issue") == true
                           && items.filter { $0.category != "patch-notes" }.allSatisfy { !$0.showsExcerpt }))
        checks.append(("the summary is the post's own sentences without its section headings",
                       patch?.summary.hasPrefix("An issue where the orbs in \"Pulling the Plug\" would sometimes chase players should be resolved. The Light Elemental") == true
                           && item("2026-09-27_server-notices")?.summary == item("2026-09-27_server-notices")?.body.first?.text
                           && News.parse(Data(#"[{"slug":"a","title":"t","excerpt":"Only this","category":"patch-notes"}]"#.utf8))?.first?.summary == "Only this"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-15T20:00:00Z")!
        func day(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T12:00:00Z")! }
        checks.append(("dates: Today, Yesterday, N days ago, then the short date (year only when not this year)",
                       News.shortDate(day("2026-10-15"), fallback: "", now: now, calendar: utc) == "Today"
                           && News.shortDate(day("2026-10-14"), fallback: "", now: now, calendar: utc) == "Yesterday"
                           && News.shortDate(day("2026-10-12"), fallback: "", now: now, calendar: utc) == "3 days ago"
                           && News.shortDate(day("2026-09-25"), fallback: "", now: now, calendar: utc) == "Sep 25"
                           && News.shortDate(day("2025-12-31"), fallback: "", now: now, calendar: utc) == "Dec 31, 2025"
                           && News.shortDate(nil, fallback: "October 9, 2026", now: now, calendar: utc) == "October 9, 2026"))
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let lateEvening = item("2026-09-27_server-notices")   // 2026-09-27T05:00:48Z, printDate September 27
        checks.append(("the sheet's date is on this Mac's calendar, like the row's; the feed's text without a date",
                       lateEvening?.printDate == "September 27, 2026"
                           && News.longDate(lateEvening?.date, fallback: "", calendar: pacific) == "September 26, 2026"
                           && News.shortDate(lateEvening?.date, fallback: "", now: now, calendar: pacific) == "Sep 26"
                           && News.longDate(lateEvening?.date, fallback: "", calendar: utc) == "September 27, 2026"
                           && News.longDate(nil, fallback: "October 9, 2026") == "October 9, 2026"))
        checks.append(("a post's page is horizonxi.com/news/<slug>; a slug that is not one path segment gets none",
                       News.pageURL(template: "https://horizonxi.com/news/{slug}", slug: patch?.slug ?? "")?.absoluteString
                           == "https://horizonxi.com/news/2026-10-09_patch-notes_1558118587439521824"
                           && News.pageURL(template: "https://horizonxi.com/news/{slug}", slug: "../x") == nil
                           && News.pageURL(template: "https://horizonxi.com/news/{slug}", slug: "a/b") == nil
                           && News.pageURL(template: "", slug: "a") == nil
                           && News.pageURL(template: "http://example.com/{slug}", slug: "a") == nil))
        let horizon = Server.all.first { $0.name == "HorizonXI" }
        checks.append(("HorizonXI carries its feed and page; no other world claims one",
                       horizon?.newsURL == "https://api.horizonxi.com/api/v1/news"
                           && horizon?.newsPageURL == "https://horizonxi.com/news/{slug}"
                           && Server.all.filter { $0.name != "HorizonXI" }.allSatisfy { $0.newsURL.isEmpty && $0.newsPageURL.isEmpty }))
        let saved = try? JSONEncoder().encode(Server(name: "HorizonXI", host: "h", bootProfile: "horizonxi.ini",
                                                     verified: true, note: "", newsURL: "https://evil.example/feed"))
        let reloaded = saved.flatMap { try? JSONDecoder().decode(Server.self, from: $0) }
        checks.append(("the feed address is the app's, not servers.json's",
                       reloaded?.newsURL == "https://api.horizonxi.com/api/v1/news"))

        // The post itself.
        let body = patch?.body ?? []
        checks.append(("a patch note reads as headings and list items",
                       body.first == .heading(AttributedString("Battlefields"))
                           && body.dropFirst().first?.text.hasPrefix("An issue where the orbs") == true
                           && body.filter { if case .heading = $0 { return true } else { return false } }.map(\.text)
                               == ["Battlefields", "Mobs", "Combat", "Quests", "Items"]
                           && body.filter { if case .bullet(0, _) = $0 { return true } else { return false } }.count == 13))
        let camps = item("2026-10-02_patch-notes_1555590181")?.body ?? []
        checks.append(("a nested list is a level deeper",
                       camps.first == .bullet(level: 0, AttributedString("The following provides a list of changes that were made to merit camps:"))
                           && camps.dropFirst().allSatisfy { if case .bullet(1, _) = $0 { return true } else { return false } }
                           && camps.count == 15))
        let tricky = NewsHTML.blocks("""
            <p>Fish &amp; chips &lt;3 &#39;x&#x2019; <em>soft</em> <strong>hard</strong>
            <a href="https://horizonxi.com/rules">rules</a> <a href="javascript:alert(1)">bad</a></p>
            <script>alert("no")</script><style>p{}</style><img src="https://x/y.png">
            <!-- <p>hidden</p> --><li>loose <b>item</b></li><br><h3>  Spaced   out  </h3><p>@everyone ping <@&1> ()</p>
            """)
        let first: AttributedString? = { if case .paragraph(let a)? = tricky.first { return a } else { return nil } }()
        checks.append(("entities decode; scripts, styles, images and comments leave nothing",
                       tricky.map(\.text) == ["Fish & chips <3 'x’ soft hard rules bad", "loose item", "Spaced out", "ping"]))
        checks.append(("emphasis is kept; only an http(s) link is a link",
                       first.map { a in
                           a.runs.contains { $0.inlinePresentationIntent == .emphasized && String(a[$0.range].characters) == "soft" }
                               && a.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized && String(a[$0.range].characters) == "hard" }
                               && a.runs.contains { $0.link?.absoluteString == "https://horizonxi.com/rules" && String(a[$0.range].characters) == "rules" }
                               && !a.runs.contains { $0.link != nil && String(a[$0.range].characters) == "bad" }
                       } == true))
        checks.append(("a notice with no body has no blocks; unclosed markup still ends",
                       item("2026-10-09_server-notices_1558124900")?.body.isEmpty == true
                           && NewsHTML.blocks("<ul><li>a<li>b").map(\.text) == ["a", "b"]
                           && NewsHTML.blocks("<p>x <a href='https://e.com/>'>y").map(\.text) == ["x y"]
                           && NewsHTML.blocks("<scr").isEmpty && NewsHTML.blocks("text <").map(\.text) == ["text"]))
        let afterList = NewsHTML.blocks("<ul><li>a<li>b</ul><p>c</p>")
        checks.append(("items left open end with their list: the paragraph after it is not a bullet",
                       afterList.map(\.text) == ["a", "b", "c"]
                           && afterList.last == .paragraph(AttributedString("c"))))
        checks.append(("<embed> and a self-closed <svg/> drop only themselves, not the rest of the post",
                       NewsHTML.blocks(#"<p>a</p><embed src="https://x/y.swf"><p>b</p><svg viewBox="0 0 1 1"/><p>c</p>"#).map(\.text)
                           == ["a", "b", "c"]))
        let long = News.parse(Data(("[{\"slug\":\"l\",\"title\":\"t\",\"category\":\"patch-notes\",\"html\":\""
                                    + String(repeating: "<li>An issue where something long was fixed.</li>", count: 400)
                                    + "\"}]").utf8))?.first
        checks.append(("a long post's row summary is worked out once and kept short",
                       long.map { $0.body.count == 400 && $0.summary.count < 700 && $0.summary.hasPrefix("An issue where") } == true))

        // Nothing to show is nothing shown.
        checks.append(("not the feed (empty, an object, an error page, garbage) is no news, not an empty panel's text",
                       News.parse(Data()) == nil && News.parse(Data("{}".utf8)) == nil
                           && News.parse(Data("<html>502</html>".utf8)) == nil
                           && News.parse(Data("[]".utf8)) == []
                           && News.parse(Data(#"[{"slug":"","title":"x"},{"slug":"a","title":"@everyone"},{"title":"y"}]"#.utf8)) == []))
        checks.append(("a repeated slug is one post",
                       News.parse(Data(#"[{"slug":"a","title":"x","date":"2026-01-01T00:00:00Z"},{"slug":"a","title":"y"}]"#.utf8))?.map(\.title) == ["x"]))

        // The cache, and what a fetch does to the panel.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("hxi-news-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let feedURL = URL(string: "https://api.horizonxi.com/api/v1/news")!
        checks.append(("cache round trip: what is saved reads back as the same posts",
                       News.saveCache(fixture, feed: feedURL, in: dir)
                           && News.loadCache(feed: feedURL, in: dir) == items
                           && News.cacheFile(for: feedURL, in: dir).lastPathComponent == "api.horizonxi.com-api-v1-news.json"))
        checks.append(("a payload that is not the feed is never cached",
                       !News.saveCache(Data("<html>".utf8), feed: URL(string: "https://e.com/f")!, in: dir)
                           && News.loadCache(feed: URL(string: "https://e.com/f")!, in: dir) == nil))
        try? Data("not json".utf8).write(to: News.cacheFile(for: URL(string: "https://e.com/g")!, in: dir))
        checks.append(("a damaged cache is no news", News.loadCache(feed: URL(string: "https://e.com/g")!, in: dir) == nil))

        let world = Server(name: "HorizonXI", host: "play.horizonxi.com", bootProfile: "horizonxi.ini",
                           verified: true, note: "", newsURL: "https://example.invalid/news")
        let noFeed = Server(name: "CatsEyeXI", host: "x", bootProfile: "x.ini", verified: false, note: "")
        let tmpFeed = URL(string: world.newsURL)!
        var asked = 0
        func run(_ feeds: ServerFeeds, _ answer: (items: [NewsItem], data: Data)?, minInterval: TimeInterval = 0) -> [NewsItem]? {
            var done = false
            Task { @MainActor in
                await feeds.refreshNews(servers: [world, noFeed], minInterval: minInterval) { _ in asked += 1; return answer }
                done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return feeds.news[world.name]
        }
        let a = ServerFeeds(newsCacheDir: dir)
        checks.append(("a failed fetch with nothing cached: no posts, so no panel (and no text)",
                       run(a, nil) == nil && a.news[noFeed.name] == nil && asked == 1))
        checks.append(("an empty feed: no posts, so no panel", run(a, ([], Data("[]".utf8))) == []))
        checks.append(("a good fetch shows its posts", run(a, (items, fixture)) == items))
        checks.append(("a failed fetch after a good one keeps the posts", run(a, nil) == items))
        let before = asked
        checks.append(("a second trigger within the interval does not fetch again",
                       run(a, nil, minInterval: 600) == items && asked == before))
        // The good fetch's cache write runs in the background.
        let deadline = Date().addingTimeInterval(5)
        while News.loadCache(feed: tmpFeed, in: dir) == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let b = ServerFeeds(newsCacheDir: dir)
        var loaded = false
        Task { @MainActor in await b.loadCachedNews(servers: [world, noFeed]); loaded = true }
        while !loaded { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        checks.append(("next start, offline: the cached posts show at once", b.news[world.name] == items && b.news[noFeed.name] == nil))
        checks.append(("worlds without a feed are never fetched", asked == before))

        var failures = 0
        for (name, ok) in checks {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
        }
        print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

/// `--news-preview [<feed.json>]`: the selected world's news panel as text, one row per post
/// (chip | title | date, then the summary line where a row shows one). Reads the file, or does
/// one GET of the world's feed; writes nothing, not even the cache.
extension Headless {
    @MainActor static func runNewsPreview() -> Never {
        let a = CommandLine.arguments
        let store = ServerStore()
        let world = worldArgument(after: "--news-preview").flatMap { w in store.servers.first { $0.name == w } }
            ?? store.servers.first { $0.name == "HorizonXI" }
        var items: [NewsItem]?
        if let k = a.firstIndex(of: "--news-preview"), k + 1 < a.count, a[k + 1].hasSuffix(".json") {
            items = (try? Data(contentsOf: URL(fileURLWithPath: a[k + 1]))).flatMap(News.parse)
        } else if let w = world, let url = URL(string: w.newsURL) {
            var got: [NewsItem]?
            var done = false
            Task { @MainActor in got = await News.fetch(url)?.items; done = true }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            items = got
        }
        guard let items, !items.isEmpty else {
            print("(no panel)")
            exit(1)
        }
        for i in items {
            print("\(i.label.uppercased()) | \(i.title) | \(News.shortDate(i.date, fallback: i.printDate))")
            if i.showsExcerpt { print("    \(i.summary)") }
        }
        exit(0)
    }
}
