// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// Bounded worker-ownership regression; no Vision, screen capture, app or model starts.
import Foundation

@main
struct OCRGateTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            checks += 1
        }

        let gate = OCRRecognitionGate()
        check(!gate.isWarm, "new OCR is cold")
        let first = gate.claim(warmUp: true)!
        check(gate.claim() == nil && gate.claim(warmUp: true) == nil,
              "warm-up and captures share one worker")
        check(!gate.finish(UUID(), succeeded: true) && !gate.isWarm,
              "unowned callbacks cannot warm or release the worker")
        // Caller timeout/Stop only invalidates its UI result. The actual worker is still owned.
        check(gate.claim() == nil, "a timed-out worker cannot be overlapped")
        check(gate.finish(first, succeeded: false) && !gate.isWarm,
              "failed model preparation must not declare OCR ready")
        let second = gate.claim()!
        check(!gate.finish(first, succeeded: true) && gate.claim() == nil,
              "an old completion cannot release a newer worker")
        check(gate.finish(second, succeeded: true) && gate.isWarm,
              "successful recognition records readiness")
        check(gate.claim(warmUp: true) == nil, "ready OCR is not warmed again")
        let third = gate.claim()!
        check(gate.finish(third, succeeded: false) && gate.isWarm,
              "a later failed sample preserves established readiness")

        // All callers race for the same held slot. Exactly one may enter before it finishes.
        let contention = OCRRecognitionGate()
        let resultLock = NSLock()
        var winners: [UUID] = []
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if let token = contention.claim(warmUp: index % 2 == 0) {
                resultLock.withLock { winners.append(token) }
            }
        }
        check(winners.count == 1, "simultaneous warm-up/capture workers never stack")
        check(contention.finish(winners[0], succeeded: true), "the sole worker releases its slot")
        let next = contention.claim()!
        check(contention.finish(next, succeeded: true), "the next explicit sample can run")
        print("\(checks) OCR worker ownership regressions passed")
    }
}
