import Foundation

/// One post from a world's own news feed (HorizonXI: `api.horizonxi.com/api/v1/news`), as the
/// left panel shows it. Everything here is the server's own text, cleaned of Discord mention
/// tokens; nothing is written by the launcher.
struct NewsItem: Identifiable, Equatable {
    var id: String { slug }
    let slug: String
    let title: String
    let date: Date?
    /// The feed's own long date ("October 9, 2026"), shown in the detail sheet.
    let printDate: String
    let author: String
    /// The feed's category id (`patch-notes`, `server-notices`, `known-issues`, `announcements`).
    let category: String
    /// The chip: the feed's own label ("Patch Notes", "Server Notice"), or the id made readable.
    let label: String
    /// Plain-text summary; "" when there is none or it only repeats the title.
    let excerpt: String
    /// The post's HTML, already turned into plain blocks (`NewsHTML`) off the main actor.
    let body: [NewsBlock]

    /// Patch notes carry a one- or two-line summary under the title; notices are their title.
    var showsExcerpt: Bool { category == "patch-notes" && !summary.isEmpty }

    /// The row's summary: the post's own sentences, section headings left out. The feed's
    /// excerpt runs a heading into the first item ("Battlefields An issue where the orbs…"),
    /// so it is used only for a post without a body.
    var summary: String {
        let lines = body.compactMap { b -> String? in if case .heading = b { return nil } else { return b.text } }
        return lines.isEmpty ? excerpt : lines.joined(separator: " ")
    }
}

/// The detail sheet's content. No HTML engine is involved: tags are read here and only text,
/// headings, list items, emphasis and http(s) links survive. Nothing is fetched to show a post.
enum NewsBlock: Equatable {
    case heading(AttributedString)
    case paragraph(AttributedString)
    /// `level` 0 is a top-level list item; nested lists count up from there.
    case bullet(level: Int, AttributedString)

    var text: String {
        switch self {
        case .heading(let a), .paragraph(let a), .bullet(_, let a): return String(a.characters)
        }
    }
}

enum News {
    // MARK: - Reading the feed

    /// The feed's JSON array, newest first. nil when the payload is not an array of posts (an
    /// error page, a redesign): a payload that cannot be read is no news, never invented news.
    /// A post without a slug or a title is skipped; a repeated slug is kept once.
    static func parse(_ data: Data) -> [NewsItem]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var seen: Set<String> = []
        var out: [(Int, NewsItem)] = []
        for (n, any) in array.enumerated() {
            guard let o = any as? [String: Any] else { continue }
            let slug = (o["slug"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = clean(o["title"] as? String ?? "")
            guard !slug.isEmpty, !title.isEmpty, !seen.contains(slug) else { continue }
            seen.insert(slug)
            let raw = o["date"] as? String ?? ""
            let date = iso.date(from: raw) ?? isoPlain.date(from: raw)
            let category = (o["category"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var excerpt = clean(o["excerpt"] as? String ?? "")
            if excerpt == title { excerpt = "" }
            out.append((n, NewsItem(
                slug: slug, title: title, date: date,
                printDate: (o["printDate"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                author: clean(o["author"] as? String ?? ""),
                category: category,
                label: label(category: category, label: o["categoryLabel"] as? String ?? ""),
                excerpt: excerpt,
                body: NewsHTML.blocks(o["html"] as? String ?? ""))))
        }
        // Newest first; posts without a readable date after the dated ones, in feed order.
        out.sort { a, b in
            switch (a.1.date, b.1.date) {
            case let (x?, y?): return x != y ? x > y : a.0 < b.0
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.0 < b.0
            }
        }
        return out.map(\.1)
    }

    /// The chip text. The feed labels its own categories; one it does not label is shown by its
    /// id with the dashes taken out ("launcher-notices" -> "Launcher Notices").
    static func label(category: String, label: String) -> String {
        let l = label.trimmingCharacters(in: .whitespaces)
        if !l.isEmpty { return l }
        return category.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func regex(_ p: String) -> NSRegularExpression {
        // Literal patterns below; a typo is a crash on first use, caught by --selftest-news.
        try! NSRegularExpression(pattern: p)
    }
    private static let mentionPatterns: [NSRegularExpression] = [
        // HorizonXI's posts are relayed from Discord ("@everyoneApologies for the late notice").
        regex("(?i)@(everyone|here)"),
        regex("<@[!&]?[0-9]+>"),            // user and role mentions
        regex("<#[0-9]+>"),                 // channel mentions
        regex("<t:-?[0-9]+(:[A-Za-z])?>"),  // Discord timestamps
        regex("<a?:[A-Za-z0-9_~]+:[0-9]+>"),// custom emoji
    ]
    /// What a stripped Discord timestamp leaves behind: "at the normal time tomorrow ()".
    private static let emptyParens = regex("\\(\\s*\\)")
    private static let spaceBeforePunctuation = regex(" +([.,!?;:])")
    private static let colonBeforeStop = regex("([:;,]) *([.!?])")
    private static let spaces = regex("\\s+")

    private static func replace(_ r: NSRegularExpression, in s: String, with t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    /// Discord's mention, channel, timestamp and emoji tokens taken out; nothing else changed.
    static func stripMentions(_ s: String) -> String {
        mentionPatterns.reduce(s) { replace($1, in: $0, with: "") }
    }

    /// A title, excerpt or author as shown: mention tokens and the "()" an empty timestamp leaves
    /// taken out, whitespace collapsed, no space before punctuation, trimmed.
    static func clean(_ s: String) -> String {
        var t = stripMentions(s)
        t = replace(emptyParens, in: t, with: "")
        t = replace(spaces, in: t, with: " ")
        t = replace(spaceBeforePunctuation, in: t, with: "$1")
        t = replace(colonBeforeStop, in: t, with: "$2")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One run of HTML text: the same clean-up, but a single space at either end is kept, since
    /// it separates this run from the next ("foo <em>bar</em>").
    static func cleanRun(_ s: String) -> String {
        var t = stripMentions(s)
        t = replace(emptyParens, in: t, with: "")
        t = replace(spaces, in: t, with: " ")
        t = replace(spaceBeforePunctuation, in: t, with: "$1")
        return replace(colonBeforeStop, in: t, with: "$2")
    }

    // MARK: - Showing it

    /// The row's date: "Today", "Yesterday", "3 days ago", then "Sep 25" (with the year when it is
    /// not this year). The feed's own date text when the date could not be read.
    static func shortDate(_ d: Date?, fallback: String, now: Date = Date(),
                          calendar: Calendar = .current) -> String {
        guard let d else { return fallback }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = calendar.component(.year, from: d) == calendar.component(.year, from: now)
            ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    /// The post's own page on the world's site, from `Server.newsPageURL` ("…/news/{slug}").
    /// nil without a template, or for a slug that is not a plain path segment.
    static func pageURL(template: String, slug: String) -> URL? {
        guard template.contains("{slug}"), !slug.isEmpty,
              slug.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }),
              slug != ".", slug != ".."
        else { return nil }
        guard let u = URL(string: template.replacingOccurrences(of: "{slug}", with: slug)),
              u.scheme == "https" else { return nil }
        return u
    }

    // MARK: - Cache

    /// The last good copy of each feed, raw as fetched, so the panel shows at once and offline.
    static let defaultCacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HorizonXI-on-Mac/news", isDirectory: true)

    /// One file per feed address, not per world name, so a world whose feed moves never shows
    /// the old feed's posts as the new one's.
    static func cacheFile(for feed: URL, in dir: URL) -> URL {
        let name = (feed.host ?? "feed") + feed.path
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" })
        return dir.appendingPathComponent(safe + ".json")
    }

    /// Only a payload that parses is kept; written atomically.
    @discardableResult
    static func saveCache(_ data: Data, feed: URL, in dir: URL = defaultCacheDir) -> Bool {
        guard parse(data) != nil else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: cacheFile(for: feed, in: dir), options: .atomic)) != nil
    }

    static func loadCache(feed: URL, in dir: URL = defaultCacheDir) -> [NewsItem]? {
        guard let d = try? Data(contentsOf: cacheFile(for: feed, in: dir)) else { return nil }
        return parse(d)
    }

    // MARK: - Fetching

    /// One GET with a short timeout; the parse runs off the caller's actor. nil on any failure
    /// (offline, a non-200, a payload that is not the feed).
    static func fetch(_ url: URL, timeout: TimeInterval = 10) async -> (items: [NewsItem], data: Data)? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("FFXI-on-Mac launcher", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let items = await Task.detached(priority: .utility) { parse(data) }.value
        return items.map { ($0, data) }
    }
}

/// A post's HTML as plain blocks. HorizonXI's posts use h3, ul/li (nested), p, em and strong
/// (all 30 posts read 2026-10-15); anything else is reduced to its text, and script, style and
/// embedded content are dropped with their contents. Images are dropped: showing a post never
/// loads anything.
enum NewsHTML {
    private struct Run { var text: String; var em: Bool; var strong: Bool; var link: URL? }
    private enum Kind: Equatable { case paragraph, heading, bullet(Int) }

    private static let dropped: Set<String> = ["script", "style", "iframe", "object", "embed", "noscript",
                                               "template", "svg", "head", "title", "video", "audio", "canvas"]

    static func blocks(_ html: String) -> [NewsBlock] {
        var out: [NewsBlock] = []
        var runs: [Run] = []
        var kinds: [Kind] = []
        var depth = 0
        var em = 0, strong = 0
        var link: URL?

        func flush() {
            defer { runs = [] }
            // Collapse the space where two runs meet, trim the ends.
            var parts: [Run] = []
            for var r in runs {
                if let last = parts.last, last.text.hasSuffix(" ") || last.text.hasSuffix("\n") {
                    while r.text.hasPrefix(" ") { r.text.removeFirst() }
                }
                if r.text.isEmpty { continue }
                parts.append(r)
            }
            while let f = parts.first, f.text.first?.isWhitespace == true {
                parts[0].text = String(f.text.drop { $0.isWhitespace })
                if parts[0].text.isEmpty { parts.removeFirst() }
            }
            while let l = parts.last, l.text.last?.isWhitespace == true {
                parts[parts.count - 1].text = String(l.text.reversed().drop { $0.isWhitespace }.reversed())
                if parts[parts.count - 1].text.isEmpty { parts.removeLast() }
            }
            guard !parts.isEmpty else { return }
            var a = AttributedString()
            for r in parts {
                var s = AttributedString(r.text)
                var intent: InlinePresentationIntent = []
                if r.em { intent.insert(.emphasized) }
                if r.strong { intent.insert(.stronglyEmphasized) }
                if !intent.isEmpty { s.inlinePresentationIntent = intent }
                if let l = r.link { s.link = l }
                a += s
            }
            switch kinds.last ?? .paragraph {
            case .paragraph: out.append(.paragraph(a))
            case .heading: out.append(.heading(a))
            case .bullet(let n): out.append(.bullet(level: n, a))
            }
        }

        func text(_ raw: Substring) {
            let t = News.cleanRun(decodeEntities(String(raw)))
            guard !t.isEmpty else { return }
            runs.append(Run(text: t, em: em > 0, strong: strong > 0, link: link))
        }

        var i = html.startIndex
        var textStart = i
        while i < html.endIndex {
            guard html[i] == "<" else { i = html.index(after: i); continue }
            text(html[textStart..<i])
            // A comment.
            if html[i...].hasPrefix("<!--") {
                i = html[i...].range(of: "-->")?.upperBound ?? html.endIndex
                textStart = i
                continue
            }
            // The tag, with quoted attribute values allowed to hold ">".
            var j = html.index(after: i)
            var quote: Character?
            while j < html.endIndex {
                let c = html[j]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == ">" { break }
                j = html.index(after: j)
            }
            let inner = html[html.index(after: i)..<j]
            i = j < html.endIndex ? html.index(after: j) : html.endIndex
            textStart = i
            let closing = inner.hasPrefix("/")
            let name = String(inner.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }).lowercased()
            guard !name.isEmpty else { continue }

            if !closing, dropped.contains(name) {
                // Skip to the matching close tag, contents and all.
                if let end = html.range(of: "</\(name)", options: .caseInsensitive, range: i..<html.endIndex) {
                    i = html[end.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                } else {
                    i = html.endIndex
                }
                textStart = i
                continue
            }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if closing { if kinds.last == .heading { kinds.removeLast() } } else { kinds.append(.heading) }
            case "p", "div", "blockquote", "pre", "section", "article", "table", "tr":
                flush()
                if closing {
                    if !kinds.isEmpty, kinds.last != .heading { kinds.removeLast() }
                } else {
                    // A paragraph inside a list item continues that item.
                    if case .bullet(let n)? = kinds.last { kinds.append(.bullet(n)) } else { kinds.append(.paragraph) }
                }
            case "ul", "ol":
                flush()
                depth = closing ? max(0, depth - 1) : depth + 1
            case "li":
                flush()
                if closing { if case .bullet? = kinds.last { kinds.removeLast() } }
                else { kinds.append(.bullet(min(max(depth - 1, 0), 3))) }
            case "br":
                runs.append(Run(text: "\n", em: false, strong: false, link: nil))
            case "hr":
                flush()
            case "em", "i":
                em = max(0, em + (closing ? -1 : 1))
            case "strong", "b":
                strong = max(0, strong + (closing ? -1 : 1))
            case "a":
                link = closing ? nil : href(in: inner)
            default:
                break   // img, span, code, …: their text (if any) stays, the tag goes
            }
        }
        text(html[textStart..<html.endIndex])
        flush()
        return out
    }

    /// An http(s) link only; anything else (javascript:, file:, a relative path) is plain text.
    private static func href(in tag: Substring) -> URL? {
        guard let r = tag.range(of: #"href\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var v = String(tag[r]).drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") || v.hasPrefix("'") { v = String(v.dropFirst().dropLast()) }
        guard let u = URL(string: decodeEntities(v)), let s = u.scheme?.lowercased(),
              s == "https" || s == "http", u.host != nil else { return nil }
        return u
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘",
        "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "bull": "•",
    ]

    /// `&amp;`, `&#39;`, `&#x2019;` and the common named entities. Anything else stays as written.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = s[s.index(after: i)..<semi]
                var rep: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    rep = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if body.hasPrefix("#") {
                    rep = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    rep = named[String(body)]
                }
                if let rep {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
