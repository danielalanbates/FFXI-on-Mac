import Foundation
import CoreFoundation

/// Refreshes what the launcher knows about each server from that server's own published pages,
/// on startup, in the background.
///
/// ## What is actually fetchable
///
/// **Addon lists: yes, for HorizonXI** (checked 2026-08-14). <https://horizonxi.info/addons> is
/// plain HTML and is the page HorizonXI's own wiki sends players to. It parses reliably. No other
/// server on the list publishes its addon rules anywhere this project could find.
///
/// **News: yes, for HorizonXI** (checked 2026-10-15, overturning the 2026-08-14 finding below).
/// `GET https://api.horizonxi.com/api/v1/news` answers `200 application/json` with an array of
/// the newest 30 posts, each `{slug, title, date (ISO 8601), author, excerpt, html, readingTime,
/// printReadingTime, printDate, category, categoryLabel}`. Categories seen: `server-notices`
/// ("Server Notice"), `patch-notes` ("Patch Notes"), `known-issues` ("Known Issue"),
/// `announcements` ("Announcement"); the site's bundle also knows `launcher-notices` and
/// `discord-notices`. It is what horizonxi.com's own news page reads (its JS bundle's news query
/// is `api.horizonxi.com/api/v1/` + `news`), it is relayed from their Discord, so titles carry
/// mention tokens ("@everyoneApologies for…") and the "()" a stripped Discord timestamp leaves;
/// `News.clean` takes those out. Each post's page is `https://horizonxi.com/news/<slug>`: the
/// site routes `/news/$slug` and declares that address as the post's `mainEntityOfPage`.
/// `Server.newsURL`/`newsPageURL` carry the source per world (`News`, `NewsPanel`).
///
/// What 2026-08-14 found, and why it was wrong for HorizonXI: `horizonxi.com/rss.xml`, `/feed`
/// and `/api/news` return the SPA shell, and `api.horizonxi.com` answered 404 on the obvious
/// paths tried then; the versioned `/api/v1/news` was not among them. Still true for the others:
/// CatsEyeXI, Eden, FFEra publish no feed (`/feed` is 404 or the SPA shell), and most of these
/// communities post news to Discord, which is not fetchable without a bot token and an invite.
///
/// So news is **only ever the server's own posts, never fabricated**: a world without a feed, or
/// whose feed has never been fetched (and has no cached copy), shows no panel and no text.
@MainActor
final class ServerFeeds: ObservableObject {
    @Published private(set) var lastRefresh: Date?
    /// World name -> that world's published news, newest first (`Server.newsURL`). Absent: the
    /// world has no feed, or it has never been fetched and nothing is cached. A failed fetch
    /// keeps the last good copy; it never empties the panel or puts text in it.
    @Published private(set) var news: [String: [NewsItem]] = [:]
    /// Feed address -> when it was last asked for (successfully or not), so the several
    /// triggers (start-up, the window coming into view, the 15-minute tick) cost one GET.
    private var newsAsked: [String: Date] = [:]
    private var newsInFlight: Set<String> = []
    private let newsCacheDir: URL
    /// Server name -> the addon list fetched from that server, if the fetch worked.
    @Published private(set) var fetchedAddonLists: [String: AddonPolicy] = [:]
    /// Server name -> the retail client version its login server currently requires, read from
    /// the server's own published settings (`Server.requiredClientURL`). Only present when the
    /// fetch worked; the compiled-in `Server.requiredClient` is the fallback.
    @Published private(set) var requiredClients: [String: String] = [:]
    /// Newest HorizonXI marketing version per api.horizonxi.com/api/v1/launcher/install-game.
    @Published private(set) var horizonLatest: String?
    /// Server name -> players online right now, from the server's own public counter. Only the
    /// servers that publish one appear here; absence means "don't show a number", never zero.
    @Published private(set) var populations: [String: Int] = [:]

    /// Where each server publishes its live online count, and how the payload reads. All three
    /// are the same numbers the servers' own websites display (verified 2026-08-19); nothing is
    /// scraped from HTML, so a redesign of their pages cannot silently break this.
    nonisolated static let populationSources: [(server: String, url: String, jsonKey: String?)] = [
        // Plain integer body, the counter horizonxi.com shows.
        ("HorizonXI", "https://api.horizonxi.com/api/v1/misc/status", nil),
        // {"online":true,"playerCount":647,...} — catseyexi.com's homepage counter.
        ("CatsEyeXI", "https://www.catseyexi.com/api/online-count", "playerCount"),
        // Plain integer body — edenxi.com's "active" counter.
        ("Eden", "https://edenxi.com/api/v1/misc/active", nil),
        // {"state":"online","client_ver":…,"stats":{"online":22,…}} — the counter their launcher shows.
        ("Vanadreams", "https://vanadreams.org/api/public/vanadreams/status", "stats.online"),
        // {"playersOnline":44} -- the count on their home page.
        ("DriftwoodXI", "https://xi.driftwoodgaming.com/api/players", "playersOnline"),
        // {"status":"online","server":"play.pegasusxi.com","playerCount":0,"levelCap":99} -- their header bar.
        ("PegasusXI", "https://pegasusxi.com/api/status", "playerCount"),
        // {"ok":true,"status":"online","onlinePlayers":0,"totalCharacters":34,"clientVersion":"30260805_0",…}
        ("MistXI", "https://api.mistxi.com/status.php", "onlinePlayers"),
        // {"online":true,"maintenance":false,"playersOnline":2,…} -- their site's counter.
        ("Olympus XI", "https://olympus-games.dev/api/status", "playersOnline"),
    ]

    /// A world's Discord, live: members online and in all, from Discord's public invite API
    /// (`/api/v9/invites/<code>?with_counts=true`, no account, no key). Only for a world that
    /// publishes no players-online counter of its own (Daniel, 2026-10-24: "if there's no such data
    /// for a server, maybe it can pull the active discord numbers"), and always said to be the
    /// Discord's: people online in a world's Discord are not players in it.
    struct DiscordCount: Equatable { var online: Int; var members: Int }
    @Published private(set) var discordCounts: [String: DiscordCount] = [:]
    private var discordFetched: [String: Date] = [:]

    /// The invite code of a `discord.gg/<code>` or `discord.com/invite/<code>` link, or nil.
    nonisolated static func inviteCode(_ link: String) -> String? {
        guard let u = URL(string: link), let host = u.host?.lowercased() else { return nil }
        var parts = u.path.split(separator: "/").map(String.init)
        switch host {
        case "discord.gg", "www.discord.gg": break
        case "discord.com", "www.discord.com", "discordapp.com", "www.discordapp.com":
            guard parts.first == "invite" else { return nil }
            parts.removeFirst()
        default: return nil
        }
        guard parts.count == 1, let c = parts.first,
              c.range(of: #"^[A-Za-z0-9-]{2,64}$"#, options: .regularExpression) != nil else { return nil }
        return c
    }

    /// Discord's answer for an invite: `approximate_presence_count` online of
    /// `approximate_member_count`; nil when either is missing or makes no sense.
    nonisolated static func parseInvite(_ d: Data) -> DiscordCount? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let on = (o["approximate_presence_count"] as? NSNumber)?.intValue,
              let all = (o["approximate_member_count"] as? NSNumber)?.intValue, on >= 0, all >= on else { return nil }
        return DiscordCount(online: on, members: all)
    }

    /// Whether a world's page falls back to its Discord: it has an invite, and no counter of its own.
    nonisolated static func wantsDiscord(_ s: Server) -> Bool {
        !s.local && inviteCode(s.discordURL) != nil && !populationSources.contains { $0.server == s.name }
    }

    /// The selected world's Discord count, at most once every ten minutes per world (one small GET);
    /// a failed fetch removes the number rather than keeping a stale one.
    func refreshDiscord(for server: Server?, minInterval: TimeInterval = 600,
                        api: String = "https://discord.com/api/v9/invites/") async {
        guard let s = server, Self.wantsDiscord(s), let code = Self.inviteCode(s.discordURL) else { return }
        if let t = discordFetched[s.name], Date().timeIntervalSince(t) < minInterval { return }
        discordFetched[s.name] = Date()
        var count: DiscordCount?
        if let url = URL(string: api + code + "?with_counts=true"),
           let (data, resp) = try? await URLSession.shared.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            count = Self.parseInvite(data)
        }
        discordCounts[s.name] = count
    }

    /// Strict public-counter parser. A JSON bool, fractional/negative value or error page is
    /// not a player count. Zero is a valid live count and must override the offline estimate.
    nonisolated static func parsePopulation(_ data: Data, key: String?) -> Int? {
        let count: Int?
        if let key {
            var node: Any? = try? JSONSerialization.jsonObject(with: data)
            for part in key.split(separator: ".") { node = (node as? [String: Any])?[String(part)] }
            guard let number = node as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
            count = Int(exactly: number.doubleValue)
        } else {
            count = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let count, (0...1_000_000).contains(count) else { return nil }
        return count
    }

    /// Fetch every published online counter, silently on failure. A
    /// stale number is worse than none: a failed fetch removes the entry rather than keeping it.
    func refreshPopulations() async {
        for src in Self.populationSources {
            var count: Int?
            if let url = URL(string: src.url),
               let (data, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                count = Self.parsePopulation(data, key: src.jsonKey)
            }
            populations[src.server] = count
        }
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("addon-lists.json")
    }

    init(newsCacheDir: URL = News.defaultCacheDir) {
        self.newsCacheDir = newsCacheDir
        loadCache()
    }

    /// Each world's cached feed, read off the main actor; a world already showing fetched news
    /// keeps it.
    func loadCachedNews(servers: [Server]) async {
        let feeds = servers.compactMap { s in URL(string: s.newsURL).map { (s.name, $0) } }
        guard !feeds.isEmpty else { return }
        let dir = newsCacheDir
        let cached = await Task.detached(priority: .utility) { () -> [String: [NewsItem]] in
            var out: [String: [NewsItem]] = [:]
            for (world, url) in feeds { if let items = News.loadCache(feed: url, in: dir) { out[world] = items } }
            return out
        }.value
        for (world, items) in cached where news[world] == nil { news[world] = items }
    }

    /// Fetch every world's feed not asked for in the last `minInterval` seconds. In the
    /// background, one short GET per feed; a good answer replaces what is shown and the cache,
    /// a failure changes nothing. `fetch` is `News.fetch`, swapped out by --selftest-news.
    func refreshNews(servers: [Server], minInterval: TimeInterval = 60,
                     fetch: @escaping (URL) async -> (items: [NewsItem], data: Data)? = { await News.fetch($0) }) async {
        for s in servers {
            guard !s.newsURL.isEmpty, let url = URL(string: s.newsURL) else { continue }
            let key = url.absoluteString
            if let last = newsAsked[key], Date().timeIntervalSince(last) < minInterval { continue }
            guard !newsInFlight.contains(key) else { continue }
            newsInFlight.insert(key)
            newsAsked[key] = Date()
            let got = await fetch(url)
            newsInFlight.remove(key)
            guard let got else { continue }
            // Every world on this feed (normally one).
            for w in servers where w.newsURL == s.newsURL && news[w.name] != got.items {
                news[w.name] = got.items
            }
            let dir = newsCacheDir
            Task.detached(priority: .utility) { News.saveCache(got.data, feed: url, in: dir) }
        }
    }

    /// Called once when the launcher window appears. Never blocks the UI, and a failure is
    /// silent by design: a launcher that cannot reach the internet must still start the game.
    func refresh(servers: [Server]) {
        Task { await refreshAsync(servers: servers) }
    }

    func refreshAsync(servers: [Server]) async {
        var lists: [String: AddonPolicy] = [:]
        var cacheable: [String: [String]] = [:]

        for server in servers {
            guard let url = AddonPolicies.publishedListURL(for: server) else { continue }
            guard let names = await fetchAddonNames(from: url) else { continue }

            // Sanity-bound the parse before trusting it. The parser is deliberately loose -- it
            // is reading somebody else's HTML -- so it also picks up headings and stray page
            // text, and an over-permissive allowlist is the dangerous direction: it would permit
            // an addon the server does not, which is what gets accounts banned.
            //
            // Against the known-good page it yields 189 candidates for 158 published entries,
            // about 1.2x. A parse far outside that band means the page was redesigned, and the
            // compiled-in snapshot is the safer thing to keep using.
            let expected = AddonPolicies.horizonPlugins.count + AddonPolicies.horizonAddons.count
            guard names.count >= expected / 2, names.count <= expected * 2 else { continue }
            // Counting is not enough, and trusting a count nearly cost Daniel his account's
            // addons. On 2026-08-22 the page returned 189 *slash commands and HTML entities*
            // -- "&lt;call&gt;", "/macromaster", "/map" -- which sailed through the band above
            // and became an allowlist that permitted nothing installed. The addon screen went
            // blank and Apply wrote an empty managed block, which is what removed the cursor
            // fix from scripts/default.txt. So: the parse must also *look* like the thing it
            // claims to be.
            guard Self.resembles(AddonPolicies.horizonAddons, names) else { continue }
            lists[server.name] = AddonPolicy.allowlist(
                published: names,
                source: "\(url.host ?? "the server's site"), fetched \(Self.today())")
            cacheable[server.name] = names
        }

        fetchedAddonLists = lists
        lastRefresh = Date()
        saveCache(cacheable)

        var required: [String: String] = [:]
        for server in servers where !server.requiredClientURL.isEmpty {
            if let url = URL(string: server.requiredClientURL),
               let v = await fetchRequiredClient(from: url) { required[server.name] = v }
        }
        requiredClients = required
        horizonLatest = await fetchHorizonLatest()
    }

    private func fetchHorizonLatest() async -> String? {
        guard let url = URL(string: "https://api.horizonxi.com/api/v1/launcher/install-game") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.setValue("FFXI-on-Mac launcher", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let ups = o["updateData"] as? [[String: Any]], let last = ups.last,
           let v = last["marketingVersion"] as? String { return v }
        if let base = o["installData"] as? [String: Any],
           let v = base["baseGameMarketingVersion"] as? String { return v }
        return nil
    }

    /// Reads `CLIENT_VER = '30251204_1'` out of a LandSandBoat `login.lua`. Anything that does
    /// not look like a retail patch id is ignored rather than trusted.
    private func fetchRequiredClient(from url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("FFXI-on-Mac launcher", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return ClientVersion.parseClientVer(text)
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func fetchAddonNames(from url: URL) async -> [String]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("FFXI-on-Mac launcher", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return Self.namesFromHTML(html)
    }

    /// Pull candidate addon names out of a published list page. Deliberately loose: the page is
    /// somebody else's HTML and will be redesigned without warning, so this takes text out of
    /// list items and links and lets `AddonPolicy.normalize` do the matching.
    nonisolated static func namesFromHTML(_ html: String) -> [String] {
        var out: [String] = []
        var text = ""
        var inTag = false
        var tagName = ""
        for ch in html {
            if ch == "<" { inTag = true; tagName = ""; flush(&text, into: &out); continue }
            if ch == ">" { inTag = false; continue }
            if inTag { tagName.append(ch); continue }
            text.append(ch)
        }
        flush(&text, into: &out)
        return Array(Set(out)).sorted()
    }

    nonisolated private static func flush(_ text: inout String, into out: inout [String]) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard !t.isEmpty, t.count <= 40 else { return }
        // Split "A, B, C" runs, which is how the known page lays the addons out.
        for piece in t.components(separatedBy: ",") {
            let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.count >= 2, p.count <= 32 else { continue }
            guard p.rangeOfCharacter(from: .letters) != nil else { continue }
            guard !p.contains("."), !p.contains(":"), !p.contains("©") else { continue }
            out.append(p)
        }
    }

    /// Does a fetched list actually look like a list of addons?
    ///
    /// The test is overlap with what this launcher already knows the server publishes: a page
    /// that still lists addons will name most of the same ones, and a page that now lists
    /// something else entirely will name almost none. Half is a generous floor -- the real
    /// page overlapped completely -- and it is the direction that fails safe, because the
    /// consequence of accepting a wrong list is an allowlist that hides every addon the player
    /// has installed and an Apply that writes that emptiness to disk.
    nonisolated static func resembles(_ known: [String], _ fetched: [String]) -> Bool {
        guard !known.isEmpty else { return true }
        let have = Set(fetched.map { AddonPolicy.normalize($0) })
        let hits = known.filter { have.contains(AddonPolicy.normalize($0)) }.count
        return hits * 2 >= known.count
    }

    private func saveCache(_ lists: [String: [String]]) {
        guard let d = try? JSONEncoder().encode(lists) else { return }
        try? d.write(to: Self.cacheURL)
    }

    private func loadCache() {
        guard let d = try? Data(contentsOf: Self.cacheURL),
              let lists = try? JSONDecoder().decode([String: [String]].self, from: d)
        else { return }
        for (name, names) in lists where names.count > 10 && Self.resembles(AddonPolicies.horizonAddons, names) {
            fetchedAddonLists[name] = AddonPolicy.allowlist(
                published: names, source: "cached from that server's published list")
        }
    }
}
