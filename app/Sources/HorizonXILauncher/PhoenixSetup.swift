// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import AppKit
import Foundation
import Network

/// Phoenix's website owns Discord authentication. No password form, embedded Windows webview,
/// saved session or game connection. Live installer/loader contracts remain unverified.
@MainActor final class PhoenixSetup {
    static let shared = PhoenixSetup()
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: DispatchWorkItem?
    private var working = false
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

    func begin(report: @escaping (String) -> Void) {
        guard !working else { report("Phoenix sign-in is already in progress."); return }
        working = true; self.report = report
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
                        self.report?("Sign in on Phoenix’s website. This step checks account access; game setup is not ready yet.")
                        if !NSWorkspace.shared.open(url) { self.finish("Could not open the Phoenix sign-in page.") }
                    case .failed: self.finish("Phoenix sign-in could not start its local callback.")
                    default: break
                    }
                }
            }
            let expiry = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.finish("Phoenix sign-in timed out. Click Connect Phoenix to retry.") }
            }
            timeout = expiry; DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: expiry)
            l.start(queue: .main)
        } catch { finish("Phoenix sign-in could not start its local callback.") }
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
            finish("Phoenix sign-in and manifest access succeeded. Installer verification is the next step; Play is not enabled yet.")
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
