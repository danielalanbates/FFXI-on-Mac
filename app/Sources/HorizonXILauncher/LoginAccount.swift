import Foundation
import Network

/// Creating an account on a LandSandBoat world whose accounts are made by the loader, not a website
/// (Vanadreams, Supernova): what xiloader's "Create New Account" menu sends, sent from here.
///
/// Under this launcher the loader's console is never shown -- its output is read into the log, and
/// a loader waiting at its menu is stopped (Runner, LoaderOutput.menuMarkers) -- so before this a
/// player of those worlds had no way to make an account at all. The protocol, from LandSandBoat's
/// xiloader v2.2.0 (`src/network.cpp` VerifyAccount, `src/command_handler.h`):
///
///  * TLS 1.3 to the login host, port 54231. The certificate is not checked (xiloader sets
///    `MBEDTLS_SSL_VERIFY_OPTIONAL`: these servers use self-signed ones).
///  * One JSON object: `{"username","password","otp":"","new_password":"","version":[x,y,z],
///    "command":32}` (0x20, create; 0x10 is a login).
///  * The answer: `{"result":3}` created, `{"result":4}` the name is taken, or
///    `{"error_message":"…"}` (a version the server does not take, a name or password it refuses).
///
/// The version is the server's: a request with 0.0.0 is answered "Please update to version
/// '2.2.x'" before anything is created, and the request is then sent again with that version.
enum LoginAccount {
    enum Outcome: Equatable {
        case created
        case taken
        /// The server's own words.
        case refused(String)
        /// No answer, or one this cannot read.
        case failed(String)
    }

    static let port: UInt16 = 54231

    /// The JSON request, as xiloader builds it.
    static func request(user: String, password: String, version: [Int], command: Int = 0x20) -> Data {
        let o: [String: Any] = ["username": user, "password": password, "otp": "", "new_password": "",
                                "version": version, "command": command]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    /// What an answer means.
    static func outcome(of reply: Data) -> Outcome {
        guard let end = reply.firstIndex(of: 0) ?? Optional(reply.endIndex),
              let o = (try? JSONSerialization.jsonObject(with: reply[reply.startIndex..<end])) as? [String: Any] else {
            return .failed(reply.isEmpty ? "The login server closed the connection without answering."
                                         : "The login server sent an answer this launcher cannot read.")
        }
        if let msg = o["error_message"] as? String, !msg.isEmpty {
            return .refused(msg.replacingOccurrences(of: "\n", with: " "))
        }
        // `login_result` in LandSandBoat's src/login/auth_session.h.
        switch (o["result"] as? NSNumber)?.intValue {
        case 3?: return .created
        case 4?: return .taken
        case 8?: return .refused("This world does not let new accounts be made here (account creation is off on its server).")
        case 9?: return .refused("The server could not create the account. Try again, or ask the world's staff.")
        case 11?: return .refused("This world's server does not take this loader version.")
        case let r?: return .failed("The login server answered \(r).")
        case nil: return .failed("The login server's answer has no result.")
        }
    }

    /// The version the server asks for, in either wording LandSandBoat has used: "Please update to
    /// version '2.1.x'" (older) and "Unsupported xiloader version 0.0.0. This server requires
    /// version 2.2.x." (current) -> [2, 2, 0]. The version the request reported is never taken.
    static func requiredVersion(in message: String) -> [Int]? {
        guard let r = message.range(of: #"(update to|requires) version '?(\d+)\.(\d+)\.[0-9x]+"#, options: .regularExpression) else { return nil }
        let nums = message[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return nums.count >= 2 ? [nums[0], nums[1], 0] : nil
    }

    /// What the server would refuse without a word (`isStringMalformed`: it closes the connection),
    /// said before anything is sent. LandSandBoat takes names up to 16 and passwords up to 32.
    static func problem(user: String, password: String) -> String? {
        if user.isEmpty || password.isEmpty { return "Type the account name and password you want first." }
        if user.count > 16 { return "Account names are 16 characters at most." }
        if !user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return "Use letters and numbers only in the account name." }
        if password.count > 32 { return "Passwords are 32 characters at most." }
        if !password.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) { return "Passwords cannot contain spaces." }
        return nil
    }

    /// Create `user` with `password` on `host`. Two connections at most: one to learn the version,
    /// one to create. Never retries a creation.
    static func create(host: String, user: String, password: String, port: UInt16 = port) async -> Outcome {
        if let why = problem(user: user, password: password) { return .refused(why) }
        let probe = await exchange(host: host, port: port, body: request(user: user, password: password, version: [0, 0, 0]))
        guard case .success(let first) = probe else {
            if case .failure(let e) = probe { return .failed(e.description) }
            return .failed("No answer.")
        }
        let o = outcome(of: first)
        guard case .refused(let msg) = o, let v = requiredVersion(in: msg) else {
            // An old login server that never checks versions, or one that answered something else:
            // nothing was created with 0.0.0 unless it says so.
            return o
        }
        switch await exchange(host: host, port: port, body: request(user: user, password: password, version: v)) {
        case .success(let d): return outcome(of: d)
        case .failure(let e): return .failed(e.description)
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// One TLS connection: send `body`, read the answer (up to 4 KB), close.
    static func exchange(host: String, port: UInt16, body: Data, timeout: TimeInterval = 15) async -> Result<Data, Failure> {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        // As xiloader: a self-signed certificate is not a reason to refuse.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let params = NWParameters(tls: tls)
        guard let p = NWEndpoint.Port(rawValue: port) else { return .failure(Failure(description: "bad port")) }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        let queue = DispatchQueue(label: "login-account")
        return await withCheckedContinuation { (c: CheckedContinuation<Result<Data, Failure>, Never>) in
            let once = OnceFlag()
            func finish(_ r: Result<Data, Failure>) {
                guard once.claim() else { return }
                conn.cancel()
                c.resume(returning: r)
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(Failure(description: "The login server at \(host) didn't answer."))) }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: body, completion: .contentProcessed { err in
                        if let err { finish(.failure(Failure(description: "Sending to \(host) failed: \(err)"))); return }
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                            if let data, !data.isEmpty { finish(.success(data)) }
                            else { finish(.failure(Failure(description: err.map { "\($0)" } ?? "\(host) closed the connection."))) }
                        }
                    })
                case .failed(let e): finish(.failure(Failure(description: "Couldn't reach \(host): \(e)")))
                case .waiting(let e): finish(.failure(Failure(description: "Couldn't reach \(host): \(e)")))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
