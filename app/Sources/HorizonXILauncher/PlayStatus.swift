import Foundation

/// The one line at the foot of the sidebar. Daniel: "I don't want needless text plaguing the
/// user" -- so it says nothing when Play is ready or the game is running (the button says that),
/// and otherwise exactly why Play is grey or what is under way, in one short line.
///
/// 2026-10-14, why this exists: HorizonXI's SquareEnix folder links to /Volumes/Games, which was
/// ghost-mounted, and all the launcher showed was a grey PLAY and a small "setup incomplete".
enum PlayStatus {
    static func footer(hasInstall: Bool, scanning: Bool, busyReason: String?, starting: Bool,
                       world: String, hasGame: Bool?, checks: [Check]) -> String? {
        guard hasInstall else { return scanning ? "Looking for your install…" : "Nothing installed yet" }
        if let busy = busyReason { return (busy.isEmpty ? "Working" : busy) + "…" }
        if starting { return "Starting…" }
        let bad = checks.filter { $0.state == .bad }
        // A missing drive first: it is also why the game looks "not installed".
        if let c = bad.first(where: { $0.drive != nil }) { return c.footer }
        if hasGame == false { return "\(world) not installed" }
        return bad.first?.footer
    }
}
