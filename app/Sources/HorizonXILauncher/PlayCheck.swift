import Foundation

/// What about the Mac itself will slow the game, checked when Play is pressed: Low Power Mode,
/// memory, heat, and (from App) a local server left running beside a hosted world. Warnings only,
/// never a reason not to play, and silent when nothing is wrong: each is one short line, shown
/// only while the condition is real.
///
/// Why these: the worst sessions on record were 0.4-5 fps from swap and a local server running
/// alongside (CHECKPOINT-2026-09-26), and Low Power Mode caps the CPU the client is bound by.
enum PlayCheck {
    static let lowPowerLine = "Low Power Mode is on — the game will run slower."
    static let thermalLine = "This Mac is hot and macOS is slowing it — the game will run slower."
    static let localServerLine = "The local server is still running and slows this game."

    static func lowPower(_ on: Bool) -> String? { on ? lowPowerLine : nil }

    /// `.fair` is normal under load; only the states where macOS throttles count.
    static func thermal(_ state: ProcessInfo.ThermalState) -> String? {
        state == .serious || state == .critical ? thermalLine : nil
    }

    /// `lines` without the ones whose condition has ended: Low Power Mode off, heat back to
    /// normal. Memory and the local server are left to their own triggers.
    static func stillTrue(_ lines: [String], lowPower: Bool, thermal state: ProcessInfo.ThermalState) -> [String] {
        lines.filter { line in
            if line == lowPowerLine { return lowPower }
            if line == thermalLine { return thermal(state) != nil }
            return true
        }
    }

    /// This moment's lines, in the order they matter. `othersRunning`: another client is live.
    static func current(othersRunning: Bool) -> [String] {
        let p = ProcessInfo.processInfo
        return [lowPower(p.isLowPowerModeEnabled),
                MultiWorld.currentMemoryWarning(othersRunning: othersRunning),
                thermal(p.thermalState)].compactMap { $0 }
    }
}
