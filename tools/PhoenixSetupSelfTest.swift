// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import Foundation
@main struct Checks {
    @MainActor static func main() throws {
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
        print("PASS: 14 callback, state, host, token and schema-redaction assertions")
    }
}
