// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation
import Security

/// RetroAchievements progress for Vanaguide (in game, on worlds that allow it) and for
/// VanaguideCompanion (outside the game, on HorizonXI and every other allowlist world).
///
/// **No network I/O in the game.** RetroAch, the approved HorizonXI addon, freezes the client for
/// seconds because it makes synchronous HTTP requests inside Ashita. Here the launcher does the
/// fetching, asynchronously and off the main actor, and writes one JSON snapshot next to the
/// addon's config:
///
///     <Ashita install>/config/addons/Vanaguide/retroachievements.json
///
/// The addon and the companion only ever read that file. Its shape is the shared contract
/// (`RASnapshot` below): `source`, `user`, `fetched_at` (unix seconds) and `games`, each with
/// `game_id`, `title`, `earned`, `total` and `achievements` keyed by achievement id, each holding
/// `earned_at` and `earned_hardcore_at` (ISO 8601 UTC, or null). The achievement objects also carry
/// `title`, `description`, `points` and `type` so a reader without Vanaguide's data files can still
/// name what is left; readers that do not want them ignore them.
///
/// **The web API key** lives in the login Keychain (`keychainService`), never in UserDefaults, a
/// file, a log line, or the game's environment. A key in the launcher's own environment
/// (`RETROACHIEVEMENTS_API_KEY`, for scripted runs) is taken into memory at start-up and removed
/// from the process environment before anything is spawned (`adoptEnvironmentKey`), and both game
/// spawn paths strip it again. The key travels in the request's query string (the API has no
/// other way to take it), so requests go through an ephemeral URLSession with no cache: the shared
/// session would keep the URL, key included, in `Caches/<bundle>/Cache.db`.
///
/// Rebuild caveat: an ad-hoc-signed rebuild changes the code signature the Keychain item's ACL
/// trusts, so the first read after a rebuild asks for the login password (see Credentials.swift).
/// The key is therefore read only when a fetch actually runs, never at start-up, and whether one
/// is saved is remembered separately (`keySaved`).
enum RetroAchievements {
    static let envKey = "RETROACHIEVEMENTS_API_KEY"
    static let keychainService = "org.batesai.horizonxi-on-mac.retroachievements"
    static let keychainAccount = "web-api-key"
    /// Automatic refreshes (window open, timer) run at most this often, failures included.
    static let refreshInterval: TimeInterval = 600
    /// Play refreshes regardless of the 10 minutes, but not twice within this.
    static let playFloor: TimeInterval = 60
    static let apiBase = URL(string: "https://retroachievements.org/API/")!
    static let snapshotFileName = "retroachievements.json"

    struct GameSet: Equatable {
        let id: Int
        let title: String
    }

    /// All populated HorizonXI sets in RA's official hub on 2026-10-27. These are legacy
    /// web-API game ids, not the `set=` ids used by newer website subset URLs.
    /// See docs/RETROACHIEVEMENTS.md for sources; future sets can use `extraSetIDs`.
    static let builtinSets: [GameSet] = [
        GameSet(id: 28275, title: "Final Fantasy XI"),
        GameSet(id: 28303, title: "Hero of Nations"),
        GameSet(id: 28317, title: "Rise of the Zilart"),
        GameSet(id: 28359, title: "Chains of Promathia"),
        GameSet(id: 28547, title: "Hardcore Hero"),
        GameSet(id: 41186, title: "Treasures of Aht Urhgan"),
        GameSet(id: 28409, title: "Paragon of Black Mage Excellence"),
        GameSet(id: 28414, title: "Paragon of Monk Excellence"),
        GameSet(id: 28321, title: "Paragon of Red Mage Excellence"),
        GameSet(id: 28420, title: "Paragon of Thief Excellence"),
        GameSet(id: 28421, title: "Paragon of Warrior Excellence"),
        GameSet(id: 28422, title: "Paragon of White Mage Excellence"),
    ]

    /// Extra set ids, comma or space separated, in UserDefaults `ra.extraSetIDs`.
    static var extraSetIDs: [Int] {
        get { parseSetIDs(UserDefaults.standard.string(forKey: "ra.extraSetIDs") ?? "") }
        set { UserDefaults.standard.set(newValue.map(String.init).joined(separator: ", "),
                                        forKey: "ra.extraSetIDs") }
    }

    static func parseSetIDs(_ text: String) -> [Int] {
        var seen = Set<Int>()
        return text.split(whereSeparator: { ", \n\t;".contains($0) })
            .compactMap { Int($0) }.filter { $0 > 0 && seen.insert($0).inserted }
    }

    static func sets(extra: [Int]) -> [GameSet] {
        var seen = Set(builtinSets.map(\.id))
        return builtinSets + extra.filter { $0 > 0 && seen.insert($0).inserted }
            .map { GameSet(id: $0, title: "RetroAchievements set \($0)") }
    }

    static var sets: [GameSet] { sets(extra: extraSetIDs) }

    static var username: String {
        get { UserDefaults.standard.string(forKey: "ra.username") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                        forKey: "ra.username") }
    }

    /// Whether a key was saved to the Keychain, so the window can say so without reading it.
    static var keySaved: Bool {
        get { UserDefaults.standard.bool(forKey: "ra.keySaved") }
        set { UserDefaults.standard.set(newValue, forKey: "ra.keySaved") }
    }

    /// A key given in the launcher's environment, held in memory only.
    private(set) static var environmentKey: String?

    /// Call first thing at start-up: take `RETROACHIEVEMENTS_API_KEY` out of the process
    /// environment so no child (wine, the game, VanaVoice, an installer) can inherit it.
    static func adoptEnvironmentKey() {
        if let v = ProcessInfo.processInfo.environment[envKey] {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { environmentKey = t }
            unsetenv(envKey)
        }
    }

    static var hasKey: Bool { environmentKey != nil || keySaved }

    /// The key for a fetch: the environment's, else the Keychain's. May prompt after a rebuild.
    static func apiKey() -> String? {
        environmentKey ?? RAKeychain.read(service: keychainService, account: keychainAccount)
    }

    static func saveKey(_ key: String) throws {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try RAKeychain.save(t, service: keychainService, account: keychainAccount)
        keySaved = true
    }

    static func removeKey() {
        RAKeychain.delete(service: keychainService, account: keychainAccount)
        keySaved = false
    }

    static func snapshotURL(gameDir: URL) -> URL {
        gameDir.appendingPathComponent("config/addons/Vanaguide", isDirectory: true)
            .appendingPathComponent(snapshotFileName)
    }

    /// Where the companion learns which snapshot files exist (it has no idea where installs are).
    static var registryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac", isDirectory: true)
            .appendingPathComponent("retroachievements-snapshots.json")
    }

    /// Should a refresh run now? `lastFetched` is the newest of the last attempt and the
    /// snapshot on disk, so a relaunched launcher does not refetch a minute-old snapshot.
    static func shouldFetch(_ trigger: RATrigger, now: Date, lastAttempt: Date?,
                            snapshotFetchedAt: Date?) -> Bool {
        switch trigger {
        case .manual:
            return true
        case .play:
            guard let a = lastAttempt else { return true }
            return now.timeIntervalSince(a) >= playFloor
        case .automatic:
            let newest = [lastAttempt, snapshotFetchedAt].compactMap { $0 }.max()
            guard let n = newest else { return true }
            return now.timeIntervalSince(n) >= refreshInterval
        }
    }

    /// HTTP 429 cooldown applies even to manual/Play refreshes. No retry loop or sleeping task.
    static func cooldownFinished(now: Date, retryNotBefore: Date?) -> Bool {
        retryNotBefore.map { now >= $0 } ?? true
    }

    /// Retry-After permits delta seconds or an HTTP date. Missing/invalid/past values use
    /// the normal ten-minute interval, so repeatedly clicking Refresh cannot hammer RA.
    static func retryDate(_ value: String?, now: Date) -> Date {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = TimeInterval(value), seconds.isFinite, seconds > 0 {
                return now.addingTimeInterval(seconds)
            }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = f.date(from: value), date > now { return date }
        }
        return now.addingTimeInterval(refreshInterval)
    }

    /// Replace every occurrence of the key in a string that is about to be shown or logged.
    static func redact(_ text: String, key: String?) -> String {
        guard let key, key.count >= 4 else { return text }
        return text.replacingOccurrences(of: key, with: "***")
    }

    /// RA writes dates as `2016-03-12 17:47:29` (UTC). The snapshot carries ISO 8601.
    static func isoDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.contains("T") { return raw }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let d = f.date(from: raw) else { return raw }
        let o = ISO8601DateFormatter()
        o.formatOptions = [.withInternetDateTime]
        return o.string(from: d)
    }
}

enum RATrigger { case automatic, play, manual }

// MARK: - Keychain

enum RAKeychain {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    static func save(_ secret: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "FFXI on Mac: RetroAchievements web API key"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let s = SecItemDelete(query as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}

// MARK: - API response (API_GetGameInfoAndUserProgress.php, raw PascalCase shape)

private extension KeyedDecodingContainer {
    /// RA has served numbers both as JSON numbers and as strings over the years.
    func flexInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }
    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        return nil
    }
}

struct RAAchievementProgress: Decodable, Equatable {
    var id: Int
    var title: String
    var description: String
    var points: Int
    var type: String?
    var dateEarned: String?
    var dateEarnedHardcore: String?

    enum K: String, CodingKey {
        case ID, Title, Description, Points, type, DateEarned, DateEarnedHardcore
        case achievementType = "Type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        guard let id = c.flexInt(.ID) else {
            throw DecodingError.dataCorruptedError(forKey: .ID, in: c, debugDescription: "no ID")
        }
        self.id = id
        title = c.flexString(.Title) ?? ""
        description = c.flexString(.Description) ?? ""
        points = c.flexInt(.Points) ?? 0
        // The current endpoint uses Type; older API responses used lowercase type.
        type = (c.flexString(.achievementType) ?? c.flexString(.type)).flatMap { $0.isEmpty ? nil : $0 }
        dateEarned = c.flexString(.DateEarned)
        dateEarnedHardcore = c.flexString(.DateEarnedHardcore)
    }
}

struct RAUserProgress: Decodable {
    var id: Int?
    var title: String
    var numAchievements: Int?
    var numAwardedToUser: Int?
    var achievements: [RAAchievementProgress]
    var hasAchievementList = false

    enum K: String, CodingKey {
        case ID, Title, NumAchievements, NumAwardedToUser, Achievements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.flexInt(.ID)
        title = c.flexString(.Title) ?? ""
        numAchievements = c.flexInt(.NumAchievements)
        numAwardedToUser = c.flexInt(.NumAwardedToUser)
        // An object keyed by id; PHP serialises an empty one as `[]`.
        if let m = try? c.decodeIfPresent([String: RAAchievementProgress].self, forKey: .Achievements) {
            achievements = Array(m.values)
            hasAchievementList = true
        } else if let a = try? c.decodeIfPresent([RAAchievementProgress].self, forKey: .Achievements) {
            achievements = a
            hasAchievementList = true
        } else if c.contains(.Achievements), (try? c.decodeNil(forKey: .Achievements)) != true {
            throw DecodingError.dataCorruptedError(forKey: .Achievements, in: c,
                                                   debugDescription: "Achievements is neither a map nor a list")
        } else {
            achievements = []
        }
    }
}

// MARK: - Snapshot (the shared contract)

struct RASnapshotEarned: Codable, Equatable {
    var earnedAt: String?
    var earnedHardcoreAt: String?
    var title: String?
    var description: String?
    var points: Int?
    var type: String?

    enum CodingKeys: String, CodingKey {
        case earnedAt = "earned_at", earnedHardcoreAt = "earned_hardcore_at"
        case title, description, points, type
    }

    var earned: Bool { earnedAt != nil || earnedHardcoreAt != nil }

    /// The two dates are always written, as null when not earned: the contract names them.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(earnedAt, forKey: .earnedAt)
        try c.encode(earnedHardcoreAt, forKey: .earnedHardcoreAt)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(points, forKey: .points)
        try c.encodeIfPresent(type, forKey: .type)
    }
}

struct RASnapshotGame: Codable, Equatable {
    var gameID: Int
    var title: String
    var earned: Int
    var total: Int
    var achievements: [String: RASnapshotEarned]

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id", title, earned, total, achievements
    }

    init(gameID: Int, title: String, earned: Int, total: Int,
         achievements: [String: RASnapshotEarned]) {
        self.gameID = gameID; self.title = title; self.earned = earned
        self.total = total; self.achievements = achievements
    }

    init(_ p: RAUserProgress, fallbackID: Int, fallbackTitle: String) {
        var m: [String: RASnapshotEarned] = [:]
        for a in p.achievements {
            m[String(a.id)] = RASnapshotEarned(
                earnedAt: RetroAchievements.isoDate(a.dateEarned),
                earnedHardcoreAt: RetroAchievements.isoDate(a.dateEarnedHardcore),
                title: a.title, description: a.description, points: a.points, type: a.type)
        }
        let counted = m.values.filter(\.earned).count
        self.init(gameID: p.id ?? fallbackID,
                  title: p.title.isEmpty ? fallbackTitle : p.title,
                  earned: m.isEmpty ? (p.numAwardedToUser ?? 0) : counted,
                  total: m.isEmpty ? (p.numAchievements ?? 0) : max(m.count, p.numAchievements ?? 0),
                  achievements: m)
    }
}

struct RASnapshot: Codable, Equatable {
    var source = "RetroAchievements"
    var user: String
    var fetchedAt: Int
    var games: [RASnapshotGame]

    enum CodingKeys: String, CodingKey {
        case source, user, fetchedAt = "fetched_at", games
    }

    var fetchedDate: Date { Date(timeIntervalSince1970: TimeInterval(fetchedAt)) }

    var summary: String {
        games.map { "\($0.title) \($0.earned)/\($0.total)" }.joined(separator: " · ")
    }
}

enum RASnapshotStore {
    static func encode(_ s: RASnapshot) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(s)
    }

    /// Atomic: written to a temporary file in the same folder, then renamed over the old one,
    /// so a reader never sees half a file.
    static func write(_ s: RASnapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encode(s).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) -> RASnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RASnapshot.self, from: d)
    }

    /// Remember a snapshot path for the companion, newest first, at most ten.
    static func register(_ url: URL, registry: URL) {
        var list = (try? Data(contentsOf: registry))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        list = Array(list.prefix(10))
        try? FileManager.default.createDirectory(at: registry.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: registry, options: .atomic) }
    }
}

// MARK: - Fetching

enum RAError: Error, Equatable {
    case noUser, noKey, unauthorized, unknownGame(Int)
    case rateLimited(retryNotBefore: Date)
    case http(Int), offline(String), badResponse(String)

    var message: String {
        switch self {
        case .noUser: return "no RetroAchievements username set"
        case .noKey: return "no RetroAchievements web API key saved"
        case .unauthorized: return "RetroAchievements refused the web API key (HTTP 401); check the key and username"
        case .rateLimited: return "RetroAchievements is rate limiting requests (HTTP 429); try again later"
        case .unknownGame(let id): return "RetroAchievements has no game \(id)"
        case .http(let c): return "RetroAchievements answered HTTP \(c)"
        case .offline(let why): return "could not reach RetroAchievements (\(why))"
        case .badResponse(let why): return "unexpected answer from RetroAchievements (\(why))"
        }
    }
}

typealias RATransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

struct RAFetcher {
    var clock: @Sendable () -> Date = { Date() }
    let transport: RATransport

    /// Ephemeral and cache-free: the request URL carries the key.
    static let live: RAFetcher = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        let session = URLSession(configuration: cfg)
        return RAFetcher { try await session.data(for: $0) }
    }()

    static func progressRequest(user: String, key: String, gameID: Int) -> URLRequest {
        var c = URLComponents(url: RetroAchievements.apiBase
            .appendingPathComponent("API_GetGameInfoAndUserProgress.php"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "y", value: key), URLQueryItem(name: "u", value: user),
                        URLQueryItem(name: "g", value: String(gameID))]
        var r = URLRequest(url: c.url!)
        r.setValue("FFXI-on-Mac (help@batesai.org)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    func fetchGame(user: String, key: String, set: RetroAchievements.GameSet) async throws -> RASnapshotGame {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(Self.progressRequest(user: user, key: key, gameID: set.id))
        } catch let e as URLError {
            // Never the error's own description: it can carry the failing URL, key included.
            throw RAError.offline(Self.describe(e.code))
        } catch {
            throw RAError.offline("network error")
        }
        guard let http = response as? HTTPURLResponse else { throw RAError.badResponse("not HTTP") }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw RAError.unauthorized
        case 404: throw RAError.unknownGame(set.id)
        case 429:
            throw RAError.rateLimited(retryNotBefore: RetroAchievements.retryDate(
                http.value(forHTTPHeaderField: "Retry-After"), now: clock()))
        default: throw RAError.http(http.statusCode)
        }
        // The current PHP endpoint returns [] for an unknown game (older versions returned
        // an object with ID null). Both must follow the same built-in/extra policy below.
        if let json = try? JSONSerialization.jsonObject(with: data),
           let array = json as? [Any], array.isEmpty {
            throw RAError.unknownGame(set.id)
        }
        let p: RAUserProgress
        do { p = try JSONDecoder().decode(RAUserProgress.self, from: data) }
        catch { throw RAError.badResponse("could not decode game \(set.id)") }
        // An id RA does not know comes back as an empty game, not an error status.
        guard let id = p.id, id > 0 else { throw RAError.unknownGame(set.id) }
        guard id == set.id else { throw RAError.badResponse("wrong game id for set \(set.id)") }
        let ids = p.achievements.map(\.id)
        // A successful HTTP status can still carry partial data. Never replace a complete
        // snapshot with missing rows, duplicate IDs or an empty formerly populated built-in.
        guard let total = p.numAchievements, total >= 0, p.hasAchievementList,
              ids.count == total, Set(ids).count == total, ids.allSatisfy({ $0 > 0 }),
              total > 0 || !RetroAchievements.builtinSets.contains(where: { $0.id == set.id }) else {
            throw RAError.badResponse("incomplete achievement list for set \(set.id)")
        }
        return RASnapshotGame(p, fallbackID: set.id, fallbackTitle: set.title)
    }

    /// Every set, one request at a time. An unknown extra is skipped with a note; a missing
    /// built-in or any other failure keeps the last good snapshot, including its full coverage.
    func fetchAll(user: String, key: String, sets: [RetroAchievements.GameSet],
                  now: Date) async throws -> (RASnapshot, [String]) {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { throw RAError.noUser }
        guard !key.isEmpty else { throw RAError.noKey }
        var games: [RASnapshotGame] = []
        var notes: [String] = []
        for s in sets {
            do { games.append(try await fetchGame(user: u, key: key, set: s)) }
            catch RAError.unknownGame(let id) {
                guard !RetroAchievements.builtinSets.contains(where: { $0.id == id }) else {
                    throw RAError.unknownGame(id)
                }
                notes.append("skipped set \(id) (\(s.title)): RetroAchievements does not know it")
            }
        }
        guard !games.isEmpty else { throw RAError.badResponse("no set could be read") }
        return (RASnapshot(user: u, fetchedAt: Int(now.timeIntervalSince1970), games: games), notes)
    }

    static func describe(_ c: URLError.Code) -> String {
        switch c {
        case .notConnectedToInternet: return "offline"
        case .timedOut: return "timed out"
        case .cannotFindHost, .dnsLookupFailed: return "host not found"
        case .cannotConnectToHost: return "cannot connect"
        case .networkConnectionLost: return "connection lost"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS failure"
        default: return "network error \(c.rawValue)"
        }
    }
}

/// One refresh, start to finish, with no UI: read the key, fetch, write. Used by the window and
/// by the self-test (with a fake transport, a temporary folder and a key it passes in).
enum RARefresh {
    struct Outcome {
        var snapshot: RASnapshot?
        var error: RAError?
        var notes: [String] = []
    }

    static func run(user: String, key: String?, sets: [RetroAchievements.GameSet],
                    fetcher: RAFetcher, to url: URL, registry: URL?, now: Date = Date()) async -> Outcome {
        guard !user.trimmingCharacters(in: .whitespaces).isEmpty else { return Outcome(error: .noUser) }
        guard let key, !key.isEmpty else { return Outcome(error: .noKey) }
        do {
            let (snap, notes) = try await fetcher.fetchAll(user: user, key: key, sets: sets, now: now)
            do {
                try RASnapshotStore.write(snap, to: url)
            } catch {
                return Outcome(error: .badResponse("could not write \(url.lastPathComponent): \(error.localizedDescription)"),
                               notes: notes)
            }
            if let registry {
                RASnapshotStore.register(url, registry: registry)
                // VanaGuide Server-Safe cannot read a game folder on a drive that needs Full Disk
                // Access (x10, 2026-10-28: "No achievements to show"), so it gets its own copy.
                if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    try? RASnapshotStore.write(snap, to: base.appendingPathComponent("VanaGuide Server-Safe/\(RetroAchievements.snapshotFileName)"))
                }
            }
            return Outcome(snapshot: snap, notes: notes)
        } catch let e as RAError {
            return Outcome(error: e)
        } catch {
            return Outcome(error: .badResponse("unexpected failure"))
        }
    }
}

/// The window's view of it: status for the settings section, refreshes on a schedule.
@MainActor
final class RAProgress: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var lastError: String?
    private var lastAttempt: Date?
    private var retryNotBefore: Date?

    init() {
        status = RetroAchievements.username.isEmpty ? "not set up" : "not fetched yet"
    }

    /// Show what the snapshot on disk already says, without fetching. Read off the main actor:
    /// the game folder may be on an external volume that blocks on privacy access.
    func showExisting(gameDir: URL?) {
        guard let d = gameDir else { return }
        let url = RetroAchievements.snapshotURL(gameDir: d)
        Task.detached(priority: .utility) {
            guard let s = RASnapshotStore.read(url) else { return }
            await MainActor.run { self.show(s) }
        }
    }

    private func show(_ s: RASnapshot) {
        status = "\(s.user): \(s.summary) (as of \(Self.stamp(s.fetchedDate)))"
    }

    func refresh(_ trigger: RATrigger, gameDir: URL?, log: @escaping (String) -> Void) {
        guard !busy, let gameDir else { return }
        let user = RetroAchievements.username
        guard !user.isEmpty, RetroAchievements.hasKey else {
            if trigger == .manual {
                lastError = user.isEmpty ? RAError.noUser.message : RAError.noKey.message
            }
            return
        }
        let now = Date()
        guard RetroAchievements.cooldownFinished(now: now, retryNotBefore: retryNotBefore) else { return }
        let previous = lastAttempt
        // Cheap gate first, without touching the disk.
        guard RetroAchievements.shouldFetch(trigger, now: now, lastAttempt: previous,
                                            snapshotFetchedAt: nil) else { return }
        busy = true
        let url = RetroAchievements.snapshotURL(gameDir: gameDir)
        let sets = RetroAchievements.sets
        let registry = RetroAchievements.registryURL
        Task.detached(priority: .utility) {
            let existing = RASnapshotStore.read(url)
            guard RetroAchievements.shouldFetch(trigger, now: now, lastAttempt: previous,
                                                snapshotFetchedAt: existing?.fetchedDate) else {
                await MainActor.run {
                    self.busy = false
                    if let existing { self.show(existing) }
                }
                return
            }
            await MainActor.run { self.lastAttempt = now }
            let key = RetroAchievements.apiKey()
            let outcome = await RARefresh.run(user: user, key: key, sets: sets,
                                              fetcher: .live, to: url, registry: registry, now: now)
            await MainActor.run {
                self.busy = false
                for n in outcome.notes { log("i  retroachievements: \(n)") }
                if let s = outcome.snapshot {
                    self.retryNotBefore = nil
                    self.lastError = nil
                    self.show(s)
                    log("==> retroachievements: \(s.summary)")
                } else if let e = outcome.error {
                    if case .rateLimited(let date) = e { self.retryNotBefore = date }
                    let msg = RetroAchievements.redact(e.message, key: key)
                    self.lastError = msg + (existing != nil ? "; kept the last good snapshot" : "")
                    // Only a refresh the user asked for reaches the window; an automatic or
                    // Play-time one failing (offline, RA down) changes nothing about play, and
                    // the RetroAchievements section shows the error either way.
                    log((trigger == .manual ? "!! " : "i  ") + "retroachievements: \(self.lastError ?? msg)")
                }
            }
        }
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}
