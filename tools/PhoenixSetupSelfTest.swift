// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import Foundation
@main struct Checks {
    @MainActor static func main() async throws {
        let state = "fixture-state"
        func head(_ path: String, _ host: String = "127.0.0.1:23456", _ method: String = "GET") -> String {
            "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n"
        }
        func token(_ value: String) -> String? { PhoenixSetup.callbackToken(value, port: 23456, state: state) }
        precondition(token(head("/callback?token=fixture&state=fixture-state")) == "fixture")
        precondition(token(head("/callback?token=fixture&state=wrong")) == nil)
        precondition(token(head("/callback?token=one&token=two&state=fixture-state")) == nil)
        precondition(token(head("/callback?token=fixture&state=fixture-state&state=wrong")) == nil)
        precondition(token(head("/callback?token=fixture&state=fixture-state", "evil.example")) == nil)
        precondition(token(head("/callback?token=fixture&state=fixture-state", "127.0.0.1:23456", "POST")) == nil)
        precondition(token(head("/callback?token=%0D%0Ainjection&state=fixture-state")) == nil)
        precondition(token(head("/callback?token=fixture&state=fixture-state#fragment")) == nil)
        precondition(token(head("https://evil.example/callback?token=fixture&state=fixture-state")) == nil)
        precondition(token(head("/callback?token=fixture&state=fixture-state") + String(repeating: "X", count: 17000)) == nil)
        let good = HTTPURLResponse(url: URL(string: "https://api.phoenix-xi.com/")!, statusCode: 200, httpVersion: nil, headerFields: ["set-auth-token":"fixture-session"])!
        let bad = HTTPURLResponse(url: good.url!, statusCode: 401, httpVersion: nil, headerFields: ["set-auth-token":"fixture-session"])!
        precondition(PhoenixSetup.sessionToken(Data(), response: good) == "fixture-session")
        precondition(PhoenixSetup.sessionToken(Data(), response: bad) == nil)
        let body = Data(#"{"session":{"token":"body-session"}}"#.utf8)
        let plain = HTTPURLResponse(url: good.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        precondition(PhoenixSetup.sessionToken(body, response: plain) == "body-session")
        let shape = PhoenixSetup.shape(["archive":["url":"SECRET_SIGNED_URL","size":123],"files":[["name":"PRIVATE_FILE"]]])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: shape), as: UTF8.self)
        precondition(!text.contains("SECRET") && !text.contains("PRIVATE") && !text.contains("123") && text.contains("archive"))
        let callback = "http://127.0.0.1:23456/callback?token=fixture&state=fixture-state"
        precondition(PhoenixSetup.manualCallbackToken(callback, port: 23456, state: state) == "fixture")
        for badURL in [callback.replacingOccurrences(of: "23456", with: "23457"), callback.replacingOccurrences(of: "127.0.0.1", with: "evil.example"), callback + "&token=other", callback + "#fragment", callback.replacingOccurrences(of: "http:", with: "https:")] {
            precondition(PhoenixSetup.manualCallbackToken(badURL, port: 23456, state: state) == nil)
        }
        let sha = String(repeating: "a", count: 64)
        let valid: [String: Any] = ["archive": ["url": "https://gamefiles.phoenix-xi.com/stable/game.zip", "size": 100, "sha256": sha]]
        precondition((try? PhoenixInstaller.Archive(valid)) != nil)
        let relative: [String: Any] = ["archive": ["url": "archive/game-client-v1.zip", "size": 100, "sha256": sha]]
        let resolved = try PhoenixInstaller.Archive(relative, base: URL(string: "https://gamefiles.phoenix-xi.com/manifest.json"))
        precondition(resolved.url.absoluteString == "https://gamefiles.phoenix-xi.com/archive/game-client-v1.zip")
        precondition((try? PhoenixInstaller.Archive(["archive": ["url": "//evil.example/file", "size": 100, "sha256": sha]], base: URL(string: "https://gamefiles.phoenix-xi.com/manifest.json"))) == nil)
        for badURL in ["https://evilphoenix-xi.com/file", "https://phoenix-xi.com.evil.example/file", "http://gamefiles.phoenix-xi.com/file", "https://user:pass@gamefiles.phoenix-xi.com/file", "https://gamefiles.phoenix-xi.com:444/file"] {
            precondition((try? PhoenixInstaller.Archive(["archive": ["url": badURL, "size": 100, "sha256": sha]])) == nil)
        }
        for badSize: Any in [0, -1, true, 1.5, 2_000_000_000_000] {
            precondition((try? PhoenixInstaller.Archive(["archive": ["url": "https://gamefiles.phoenix-xi.com/file", "size": badSize, "sha256": sha]])) == nil)
        }
        let launch = Data(#"{"data":{"token":"fixture-game-token","expiresAt":"fixture","multiClientAllowed":false}}"#.utf8)
        precondition(PhoenixGameLaunch.token(from: launch, response: plain) == "fixture-game-token")
        precondition(PhoenixGameLaunch.token(from: launch, response: bad) == nil)
        precondition(PhoenixGameLaunch.token(from: Data(#"{"data":{"token":""}}"#.utf8), response: plain) == nil)
        precondition(PhoenixGameLaunch.token(from: Data(#"{"data":{"token":"bad\nvalue"}}"#.utf8), response: plain) == nil)
        precondition(PhoenixGameLaunch.windowsPath(URL(fileURLWithPath: "/Volumes/Games Drive/Phoenix")) == "Z:\\Volumes\\Games Drive\\Phoenix")
        let profile = Data(#"{"data":{"username":"fixture-user","email":"do-not-persist@example.test"}}"#.utf8)
        precondition(PhoenixGameLaunch.username(from: profile, response: plain) == "fixture-user")
        precondition(PhoenixGameLaunch.username(from: profile, response: bad) == nil)
        precondition(PhoenixGameLaunch.username(from: Data(#"{"data":{"username":""}}"#.utf8), response: plain) == nil)
        precondition(PhoenixGameLaunch.username(from: Data(#"{"data":{"username":"bad\nvalue"}}"#.utf8), response: plain) == nil)
        let downloads = ProcessInfo.processInfo.environment["PHOENIX_TEST_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/FFXI-on-Mac-build/phoenix-selftest-fixtures")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let file = downloads.appendingPathComponent("archive.part")
        for (status, bytes, expected, succeeds) in [(200, 4, 4, true), (200, 5, 4, false), (200, 3, 4, false), (403, 4, 4, false)] {
            FixtureProtocol.status = status; FixtureProtocol.bytes = bytes
            do {
                try await PhoenixArchiveDownload.fetch(URLRequest(url: URL(string: "https://gamefiles.phoenix-xi.com/fixture")!), to: file, expected: Int64(expected), configuration: config)
                precondition(succeeds)
                let written = try Data(contentsOf: file)
                precondition(written.count == expected)
                try FileManager.default.removeItem(at: file)
            } catch {
                precondition(!succeeds)
                precondition(!FileManager.default.fileExists(atPath: file.path))
            }
        }
        print("PASS: callback validation, manual handoff, redaction archive trust/size and launch-token checks")

    }
}

private final class FixtureProtocol: URLProtocol {
    static var status = 200
    static var bytes = 4
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: Self.bytes))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
