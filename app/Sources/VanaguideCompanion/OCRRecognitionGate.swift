// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org

import Foundation

/// Owns the single Vision worker, including a request whose caller has timed out.
/// Timeout and UI Stop never release this slot: the worker must actually return first.
final class OCRRecognitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: UUID?
    private var warmed = false

    var isWarm: Bool { lock.withLock { warmed } }

    func claim(warmUp: Bool = false) -> UUID? {
        lock.withLock {
            guard active == nil, !warmUp || !warmed else { return nil }
            let token = UUID()
            active = token
            return token
        }
    }

    @discardableResult
    func finish(_ token: UUID, succeeded: Bool) -> Bool {
        lock.withLock {
            guard active == token else { return false }
            warmed = warmed || succeeded
            active = nil
            return true
        }
    }
}
