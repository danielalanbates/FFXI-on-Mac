import Foundation
import AppKit

/// Remember the size the user leaves the game window at, and launch at that size next time.
///
/// FFXI creates its Direct3D device once, at `[ffxi.registry] 0001/0002`, and never handles a
/// resize: dragging the frame bigger just stretches (or letterboxes) that fixed back buffer, which
/// is why an enlarged window looks soft and "not filled". The only way to actually render at the
/// new size is to start the client at it. So while the client runs, its window is sampled; when
/// it exits, the last size is written into the world's boot profile (and the world's stored
/// graphics settings, so the panel agrees), and the next Play opens at the size the user chose.
///
/// Per world, because the profiles are per world: a maximised local-test window must not change
/// how HorizonXI opens, and the reverse.
///
/// Units: wine's Mac driver runs with `RetinaMode=y` on this install, so one screen point is two
/// game pixels — a 1280x720 client is a 640x360-point window. The factor is read from the
/// prefix's user.reg rather than assumed; without Retina mode it is 1.
enum WindowMemory {
    struct Size: Equatable { var width: Int; var height: Int }

    /// The game's main window, in *game pixels* (points × wine's Retina factor), or nil when no
    /// window of the game is on screen yet. `pids` are the client's processes (`pgrep -f` of the
    /// loader exe): the detached launch pid is a shell that exits with the injector, and the
    /// loader is reparented to launchd, so ancestry from the launch pid cannot be used. With two
    /// clients up at once (`pids` spanning more than one process) nothing is sampled — a size
    /// from the wrong client must never be remembered.
    static func currentSize(pids: [pid_t], scale: Int) -> Size? {
        guard !pids.isEmpty else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let titleBar = Int(NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height.rounded())
        var best: Size?
        var owners = Set<pid_t>()
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t,
                  (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bw = b["Width"], let bh = b["Height"] else { continue }
            guard pids.contains(owner) else { continue }
            owners.insert(owner)
            // Content area: wine's frame is a standard titled window. Tiny windows are wine's
            // helper/IME windows, not the client.
            let s = Size(width: Int(bw) * scale, height: (Int(bh) - titleBar) * scale)
            guard s.width >= 640, s.height >= 480 else { continue }
            if best == nil || s.width * s.height > best!.width * best!.height { best = s }
        }
        // `pgrep -f` matches the loader's sidecar wrapper too, so the pid count says nothing;
        // distinct window owners is what tells one client from two.
        return owners.count == 1 ? best : nil
    }

    /// Wine's Retina factor for this prefix: 2 when the Mac driver has `RetinaMode=y`, else 1.
    static func scale(for install: Install) -> Int {
        let reg = install.prefix.appendingPathComponent("user.reg")
        guard let text = try? String(contentsOf: reg, encoding: .utf8) else { return 1 }
        return text.contains("\"RetinaMode\"=\"y\"") ? 2 : 1
    }

    /// Persist the size for `world`, if the window changed size while it ran. Returns a log line.
    ///
    /// `first` is the window as it appeared right after launch and `last` as it was seen last;
    /// both in game pixels. The client opens at exactly the profile's size, so the profile's
    /// numbers plus the *delta* between the two samples is the new size. That sidesteps wine's
    /// window frame (a 1-point border either side of the content, on top of the title bar):
    /// subtracting a guessed frame drifted by a few pixels and re-wrote the profile every run.
    @discardableResult
    static func remember(first: Size, last: Size, install: Install, profile: String, world: String) -> String? {
        guard first != last else { return nil }
        // The profile is the truth for sizes; the preference itself has no ini key and lives
        // only in the stored settings.
        let stored = GraphicsSettings.load(world: world)
        guard stored.rememberWindowSize else { return nil }
        var g = GraphicsSettings.read(from: install, profile: profile, fallback: stored) ?? stored
        g.rememberWindowSize = true
        // Even numbers only: the client rounds odd back buffers and the next sample would then
        // differ by a pixel forever.
        let w = (g.width + last.width - first.width) & ~1
        let h = (g.height + last.height - first.height) & ~1
        guard w >= 640, h >= 480, w != g.width || h != g.height else { return nil }
        let old = "\(g.width)x\(g.height)"
        g.width = w
        g.height = h
        // The size only, in the profile and in the stored settings (b64). Every other key stays
        // as it was: a profile an older build wrote wrong keys into must not be rewritten, nor
        // copied into the stored choice that Setup gives a new install.
        g.write(to: install, profile: profile, only: g.sizeKeys)
        // Only a value the user saved for this world is updated. `stored` may be the fallback
        // (the shared value, the defaults, the local world's Low); saving it here would make it
        // this world's own choice, which a new profile is then made with.
        if var s = GraphicsSettings.stored(forWorld: world) {
            s.width = w
            s.height = h
            s.save(world: world)
        }
        return "==> window size remembered for \(world): \(w)x\(h) (was \(old)); next Play opens at that size"
    }
}
