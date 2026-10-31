// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import AppKit
import Foundation
import Network
import CryptoKit

/// Browser authentication and isolated installation. Session credentials remain in memory.
@MainActor final class PhoenixSetup {
    static let shared = PhoenixSetup()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: DispatchWorkItem?
    private var working = false
    private var gamePID: pid_t?
    private var wine: URL?
    private var bootstrapWine: URL?
    private var state = ""
    private var report: ((String) -> Void)?

    static func callbackToken(_ head: String, port: UInt16, state: String) -> String? {
        guard head.utf8.count <= 16384 else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              request[1].hasPrefix("/callback?"),
              let url = URLComponents(string: "http://127.0.0.1:\(port)\(request[1])"),
              url.path == "/callback", url.fragment == nil else { return nil }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)" else { return nil }
        let items = url.queryItems ?? []
        let states = items.filter { $0.name == "state" }, tokens = items.filter { $0.name == "token" }
        guard !state.isEmpty, states.count == 1, states[0].value == state,
              tokens.count == 1, let token = tokens[0].value, !token.isEmpty,
              token.utf8.count <= 8192, !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return token
    }

    static func sessionToken(_ data: Data, response: HTTPURLResponse) -> String? {
        guard response.statusCode == 200 else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let session = object?["session"] as? [String: Any]
        let token = response.value(forHTTPHeaderField: "set-auth-token") ?? session?["token"] as? String
        guard let token, !token.isEmpty, token.utf8.count <= 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return token
    }

    /// Only field names and types survive the diagnostic; all values (including URLs) are removed.
    static func shape(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { shape($0) } }
        if let array = value as? [Any] { return array.first.map { [shape($0)] } ?? [] }
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if value is NSNumber { return "number-or-boolean" }
        return "unknown"
    }

    func begin(wine: URL? = nil, bootstrapWine: URL? = nil, report: @escaping (String) -> Void) {
        guard gamePID.map(Detach.isAlive) != true, !PhoenixGameLaunch.running else {
            report("Phoenix is already running. Use the existing game window."); return
        }
        guard !working else {
            if let port = listener?.port?.rawValue { offerManualCallback(port: port) }
            else { report("Phoenix setup is already in progress.") }
            return
        }
        working = true; self.report = report
        self.wine = wine; self.bootstrapWine = bootstrapWine
        state = UUID().uuidString + UUID().uuidString
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let l = try NWListener(using: parameters)
            listener = l
            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            l.stateUpdateHandler = { [weak self, weak l] update in
                Task { @MainActor in
                    guard let self, let l, self.listener === l else { return }
                    switch update {
                    case .ready:
                        guard let port = l.port?.rawValue, port >= 1024,
                              let url = URL(string: "https://phoenix-xi.com/launcher-auth?port=\(port)&state=\(self.state)") else {
                            self.finish("Phoenix sign-in could not start."); return
                        }
                        self.report?("Sign in on Phoenix’s website. If the browser blocks the return page, click Connect Phoenix again to finish sign-in.")
                        if !NSWorkspace.shared.open(url) { self.finish("Could not open the Phoenix sign-in page.") }
                    case .failed: self.finish("Phoenix sign-in could not start its local callback.")
                    default: break
                    }
                }
            }
            let expiry = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.finish("Phoenix sign-in timed out. If Chrome blocked 127.0.0.1, retry and click Connect Phoenix again to paste the callback address.") }
            }
            timeout = expiry; DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: expiry)
            l.start(queue: .main)
        } catch { finish("Phoenix sign-in could not start its local callback.") }
    }

    /// Manual handoff for browsers which block navigating to loopback. The user explicitly
    /// pastes the callback, which is validated against this live listener and random state.
    private func offerManualCallback(port: UInt16) {
        let alert = NSAlert()
        alert.messageText = "Finish Phoenix sign-in"
        alert.informativeText = "If Phoenix approved sign-in but the browser blocked 127.0.0.1, paste that page’s full address here. It contains a temporary sign-in code; it is never saved."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "http://127.0.0.1:…/callback?…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Finish Sign-in")
        alert.addButton(withTitle: "Keep Waiting")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let token = Self.manualCallbackToken(field.stringValue, port: port, state: state) else {
            report?("That address does not match this Phoenix sign-in. Use the newest browser page."); return
        }
        listener?.cancel(); listener = nil; state = ""
        timeout?.cancel(); timeout = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        Task { await checkAccess(oneTimeToken: token) }
    }

    static func manualCallbackToken(_ text: String, port: UInt16, state: String) -> String? {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http", url.host == "127.0.0.1", url.port == Int(port),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path == "/callback", let query = url.percentEncodedQuery else { return nil }
        return callbackToken("GET /callback?\(query) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", port: port, state: state)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            Task { @MainActor in self?.connections.removeValue(forKey: id)?.cancel() }
        }
    }

    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let bytes = buffer + (data ?? Data())
                guard bytes.count <= 16384 else { self.connections.removeValue(forKey: id)?.cancel(); return }
                if let end = bytes.range(of: Data("\r\n\r\n".utf8)), let port = self.listener?.port?.rawValue {
                    let token = Self.callbackToken(String(decoding: bytes[..<end.lowerBound], as: UTF8.self), port: port, state: self.state)
                    let body = token == nil ? "Invalid sign-in callback." : "Phoenix sign-in received. Return to FFXI on Mac."
                    let reply = "HTTP/1.1 \(token == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    self.connections.removeValue(forKey: id)
                    if let token {
                        self.listener?.cancel(); self.listener = nil; self.state = ""
                        self.timeout?.cancel(); self.timeout = nil
                        Task { await self.checkAccess(oneTimeToken: token) }
                    }
                } else if complete || error != nil { self.connections.removeValue(forKey: id)?.cancel() }
                else { self.read(connection, id: id, buffer: bytes) }
            }
        }
    }

    private func checkAccess(oneTimeToken: String) async {
        let session = URLSession(configuration: .ephemeral, delegate: PhoenixNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var verify = URLRequest(url: URL(string: "https://api.phoenix-xi.com/api/auth/one-time-token/verify")!)
            verify.httpMethod = "POST"; verify.timeoutInterval = 30
            verify.setValue("application/json", forHTTPHeaderField: "Content-Type")
            verify.httpBody = try JSONSerialization.data(withJSONObject: ["token": oneTimeToken])
            let (data, response) = try await session.data(for: verify)
            guard let response = response as? HTTPURLResponse, let token = Self.sessionToken(data, response: response) else {
                finish("Phoenix did not verify sign-in. Retry, or use its website to check your account."); return
            }
            var profile = URLRequest(url: URL(string: "https://api.phoenix-xi.com/api/v1/auth/me")!)
            profile.timeoutInterval = 30; profile.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (profileData, profileResponse) = try await session.data(for: profile)
            guard let profileResponse = profileResponse as? HTTPURLResponse,
                  let username = PhoenixGameLaunch.username(from: profileData, response: profileResponse) else {
                finish("Phoenix could not provide your game account name. Check account setup on its website."); return
            }
            var request = URLRequest(url: URL(string: "https://gamefiles.phoenix-xi.com/manifest.json")!)
            request.timeoutInterval = 30; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (manifest, result) = try await session.data(for: request)
            guard (result as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: manifest) else {
                finish("Phoenix sign-in succeeded. Its game manifest is still unavailable to this integration; gameplay remains pending."); return
            }
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/FFXI-Phoenix")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let safe = try JSONSerialization.data(withJSONObject: Self.shape(object), options: [.prettyPrinted, .sortedKeys])
            try safe.write(to: root.appendingPathComponent("manifest-schema.json"), options: .atomic)
            guard let manifest = object as? [String: Any] else {
                finish("Phoenix returned an invalid game manifest."); return
            }
            report?("Phoenix sign-in received. Installing the required client components on x10…")
            let report = self.report
            let installResult = await Task.detached {
                await PhoenixInstaller.install(manifest: manifest, token: token, report: { message in
                    Task { @MainActor in report?(message) }
                })
            }.value
            guard PhoenixInstaller.ready else { finish(installResult); return }
            guard let wine = self.wine, let bootstrapWine = self.bootstrapWine else {
                finish("Phoenix is installed. Select your Wine installation before launching."); return
            }
            let prepared = await Task.detached {
                await PhoenixGameLaunch.prepare(wine: wine, bootstrapWine: bootstrapWine, report: { message in
                    Task { @MainActor in report?(message) }
                })
            }.value
            guard prepared else { finish("Phoenix’s separate Wine environment could not be prepared. Your other worlds are unchanged."); return }
            var launch = URLRequest(url: URL(string: "https://api.phoenix-xi.com/api/v1/auth/game/launch-token")!)
            launch.httpMethod = "POST"; launch.timeoutInterval = 30
            launch.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            launch.setValue("application/json", forHTTPHeaderField: "Content-Type")
            launch.httpBody = try JSONSerialization.data(withJSONObject: ["additionalClient": false])
            let (launchData, launchResponse) = try await session.data(for: launch)
            guard let launchResponse = launchResponse as? HTTPURLResponse,
                  let gameToken = PhoenixGameLaunch.token(from: launchData, response: launchResponse) else {
                finish("Phoenix did not issue a game session. Check account approval or two-factor requirements on its website."); return
            }
            gamePID = try PhoenixGameLaunch.start(gameToken: gameToken, username: username, wine: wine)
            self.report?("Phoenix is starting…")
            try await Task.sleep(nanoseconds: 10_000_000_000)
            if PhoenixGameLaunch.running { finish("Phoenix game process is running.") }
            else if gamePID.map(Detach.isAlive) == true { finish("Phoenix is still starting. Check the game window.") }
            else { finish("Phoenix exited before the game started. Its client remains installed; retry sign-in to launch again.") }

        } catch { finish("Phoenix sign-in could not complete. Check your connection and retry.") }
    }

    private func finish(_ message: String) {
        timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        working = false; state = ""; report?(message); report = nil
    }
}

private final class PhoenixNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward authentication to a redirect target.
    }
}

/// Isolated installer: all archives stream to x10, never the startup disk.
enum PhoenixInstaller {
    static let root = URL(fileURLWithPath: "/Volumes/x10/Video Games/Mac/FFXI/Phoenix")

    static var ready: Bool {
        let fm = FileManager.default
        return ["install-complete.json", "client/Ashita-cli.exe", "client/bootloader/phoenix-loader.exe",
                "client/polplugins/sandbox.dll", "client/config/sandbox/sandbox.ini",
                "client/config/sandbox/sandbox.registry.ini", "client/SquareEnix/FINAL FANTASY XI/FFXiMain.dll"].allSatisfy {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    private static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct FileRepair {
        let url: URL
        let file: URL
        let size: Int64
        let sha: String
    }
    private static func repairFiles(_ manifest: [String: Any], name: String, destination: URL, token: String,
                                    report: @escaping (String) -> Void) async throws {
        guard let files = manifest["files"] as? [String: [String: Any]], !files.isEmpty else { throw SetupError.invalidManifest }
        let host = name == "game" ? "gamefiles" : name
        let fm = FileManager.default
        var jobs: [FileRepair] = []
        for path in files.keys.sorted() {
            let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !pieces.isEmpty, !pieces.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }),
                  !path.contains("\\"), !path.contains(":"),
                  let info = files[path], let size = info["size"] as? NSNumber,
                  CFGetTypeID(size) != CFBooleanGetTypeID(), size.doubleValue == Double(size.int64Value),
                  size.int64Value >= 0, size.int64Value < 2_000_000_000_000,
                  let sha = info["sha256"] as? String, sha.count == 64,
                  sha.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw SetupError.invalidManifest }
            let file = destination.appendingPathComponent(path)
            guard file.resolvingSymlinksInPath().path.hasPrefix(destination.resolvingSymlinksInPath().path + "/") else { throw SetupError.invalidManifest }
            let attributes = try? fm.attributesOfItem(atPath: file.path)
            if attributes?[.type] as? FileAttributeType == .typeRegular,
               (attributes?[.size] as? NSNumber)?.int64Value == size.int64Value,
               try hash(file) == sha { continue }
            let url = URL(string: "https://\(host).phoenix-xi.com/files/")!.appendingPathComponent(path)
            jobs.append(FileRepair(url: url, file: file, size: size.int64Value, sha: sha))
        }
        let session = URLSession(configuration: .ephemeral, delegate: PhoenixNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var iterator = jobs.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(6, jobs.count) {
                if let job = iterator.next() { group.addTask { try await repair(job, token: token, session: session) } }
            }
            var completed = 0
            while try await group.next() != nil {
                completed += 1
                if completed % 100 == 0 || completed == jobs.count { report("Updating Phoenix \(name): \(completed)/\(jobs.count)…") }
                if let job = iterator.next() { group.addTask { try await repair(job, token: token, session: session) } }
            }
        }
    }
    private static func repair(_ job: FileRepair, token: String, session: URLSession) async throws {
        var request = URLRequest(url: job.url); request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let fm = FileManager.default
        try fm.createDirectory(at: job.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if job.size <= 16 << 20 {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == job.size,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == job.sha else { throw SetupError.invalidArchive }
            try data.write(to: job.file, options: .atomic)
        } else {
            let part = job.file.appendingPathExtension("phoenix-part")
            try await PhoenixArchiveDownload.fetch(request, to: part, expected: job.size)
            guard try hash(part) == job.sha else { try? fm.removeItem(at: part); throw SetupError.invalidArchive }
            if fm.fileExists(atPath: job.file.path) { try fm.removeItem(at: job.file) }
            try fm.moveItem(at: part, to: job.file)
        }
    }

    struct Archive {
        let url: URL
        let sha: String
        let size: Int64
        init(_ manifest: [String: Any], base: URL? = nil) throws {
            guard let archive = manifest["archive"] as? [String: Any],
                  let text = archive["url"] as? String, let url = URL(string: text, relativeTo: base)?.absoluteURL,
                  Self.trusted(url), let sha = (archive["sha256"] as? String)?.lowercased(),
                  sha.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let number = archive["size"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.int64Value),
                  number.int64Value > 0, number.int64Value < 2_000_000_000_000 else {
                throw SetupError.invalidManifest
            }
            self.url = url; self.sha = sha; size = number.int64Value
        }
        static func trusted(_ url: URL) -> Bool {
            guard url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
            return host == "phoenix-xi.com" || host.hasSuffix(".phoenix-xi.com")
        }
    }
    enum SetupError: Error { case invalidManifest, http(Int), invalidArchive, extraction }

    static func install(manifest: [String: Any], token: String, report: @escaping (String) -> Void) async -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: "/Volumes/x10") else { return "Connect the x10 drive to install Phoenix." }
        do {
            // Validate all three manifests before starting any large download.
            let session = URLSession(configuration: .ephemeral, delegate: PhoenixNoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var packages: [(String, Archive, [String: Any])] = [("game", try Archive(manifest, base: URL(string: "https://gamefiles.phoenix-xi.com/manifest.json")), manifest)]
            for (name, host) in [("ashita", "ashita"), ("eradats", "eradats")] {
                var request = URLRequest(url: URL(string: "https://\(host).phoenix-xi.com/manifest.json")!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 30
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw SetupError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SetupError.invalidManifest }
                packages.append((name, try Archive(object, base: request.url), object))
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let marker = root.appendingPathComponent("install-complete.json")
            let saved = (try? Data(contentsOf: marker)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let records = saved?["packages"] as? [String: [String: Any]] ?? [:]
            if saved?["schema"] as? Int == 1,
               packages.allSatisfy({ records[$0.0]?["sha256"] as? String == $0.1.sha && records[$0.0]?["version"] as? String == $0.2["version"] as? String }), ready {
                return "Phoenix client is current."
            }
            try? fm.removeItem(at: marker)
            let total = packages.reduce(Int64(0)) { $0 + $1.1.size }
            let free = (try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])).volumeAvailableCapacityForImportantUsage ?? 0
            guard free > total * 4 + 8_000_000_000 else { return "Not enough space on x10 for Phoenix archives and extraction." }
            for (name, archive, fileManifest) in packages {
                report("Downloading Phoenix \(name) to x10…")
                let zip = root.appendingPathComponent("\(name).zip")
                let part = root.appendingPathComponent("\(name).zip.part")
                var request = URLRequest(url: archive.url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 60
                let existing = try? FileHandle(forReadingFrom: zip)
                var reusable = false
                if let existing {
                    var digest = SHA256()
                    while let chunk = try existing.read(upToCount: 4 << 20), !chunk.isEmpty { digest.update(data: chunk) }
                    try? existing.close()
                    reusable = digest.finalize().map({ String(format: "%02x", $0) }).joined() == archive.sha
                }
                if !reusable { try await PhoenixArchiveDownload.fetch(request, to: part, expected: archive.size) }

                report("Verifying Phoenix \(name)…")
                let handle = try FileHandle(forReadingFrom: reusable ? zip : part)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == archive.sha else {
                    try? fm.removeItem(at: part); return "Phoenix \(name) failed verification. Retry setup."
                }
                if !reusable {
                    if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
                    try fm.moveItem(at: part, to: zip)
                }
                // ditto extracts the authenticated, SHA-256 checked vendor archive only.
                report("Extracting Phoenix \(name) on x10…")
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                let destination = name == "eradats" ? "client/polplugins/DATs/EraDATs" : "client"
                process.arguments = ["-xk", zip.path, root.appendingPathComponent(destination).path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw SetupError.extraction }
                report("Checking and updating Phoenix \(name) files…")
                try await repairFiles(fileManifest, name: name, destination: root.appendingPathComponent(destination), token: token, report: report)

            }
            let complete: [String: Any] = ["schema": 1, "packages": Dictionary(uniqueKeysWithValues: packages.map { ($0.0, ["sha256": $0.1.sha, "version": $0.2["version"] as? String ?? ""]) })]
            try JSONSerialization.data(withJSONObject: complete).write(to: marker, options: .atomic)
            return "Phoenix client installed and verified."
        } catch SetupError.http(let code) {
            return "Phoenix refused a required download (HTTP \(code)). Sign in again to retry."
        } catch {
            // Do not expose signed archive URLs or session details in localized network errors.
            return "Phoenix installation stopped. Check x10 and your connection, then retry. Game launch is still pending."
        }
    }
}

/// URLSession data delegate writes each received chunk directly to the external destination.
/// Download tasks use system temporary storage, which can exhaust the startup volume.
final class PhoenixArchiveDownload: NSObject, URLSessionDataDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private let handle: FileHandle
    private let expected: Int64
    private var received: Int64 = 0
    private var failed: Error?
    private init(handle: FileHandle, expected: Int64) { self.handle = handle; self.expected = expected }
    static func fetch(_ request: URLRequest, to file: URL, expected: Int64, configuration: URLSessionConfiguration = .ephemeral) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        let delegate = PhoenixArchiveDownload(handle: handle, expected: expected)
        let config = configuration
        config.timeoutIntervalForResource = 24 * 60 * 60
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel(); try? handle.close() }
        do {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            failed = PhoenixInstaller.SetupError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Int64(data.count)
        guard received <= expected else { failed = PhoenixInstaller.SetupError.invalidArchive; dataTask.cancel(); return }
        do { try handle.write(contentsOf: data) } catch { failed = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = failed ?? error ?? (received == expected ? nil : PhoenixInstaller.SetupError.invalidArchive)
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
        continuation = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
