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

    // MARK: - Opening whole on this screen

    /// The biggest client, in game pixels, that opens whole on the screen wine's Mac driver puts
    /// it on: the menu-bar screen (wine's primary; Ashita centres the window there), less the menu
    /// bar, the Dock and wine's title bar and frame. Nil without a screen.
    @MainActor
    static func screenLimit(scale: Int) -> Size? {
        guard let screen = NSScreen.screens.first else { return nil }
        let titleBar = Int(NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height.rounded())
        let v = screen.visibleFrame
        return Size(width: (Int(v.width) - 2) * scale, height: (Int(v.height) - titleBar - 2) * scale)
    }

    /// `size` scaled down, both sides by one factor, until it fits `limit`, so the picture keeps
    /// its shape; even numbers. Unchanged when it already fits. A shape so wide or tall that one
    /// factor would go under the client's 640x480 floor is clamped side by side instead: a back
    /// buffer of a new shape is better than one macOS squeezes.
    static func fitted(_ size: Size, into limit: Size) -> Size {
        guard size.width > limit.width || size.height > limit.height,
              size.width > 0, size.height > 0 else { return size }
        let f = min(Double(limit.width) / Double(size.width), Double(limit.height) / Double(size.height))
        let out = Size(width: Int(Double(size.width) * f) & ~1, height: Int(Double(size.height) * f) & ~1)
        if out.width >= 640 && out.height >= 480 { return out }
        return Size(width: max(640, min(size.width, limit.width)) & ~1, height: max(480, min(size.height, limit.height)) & ~1)
    }

    /// The settings Play opens the client with, given the profile `g`, the world's stored choice
    /// and the screen `limit`; nil when the profile can stay as it is.
    ///
    /// A size remembered on a bigger display, or by an older build, can be wider or taller than
    /// the screen. macOS then cuts the window down on that side only, and FFXI, which never
    /// resizes its back buffer, draws everything squeezed (2026-10-16: a 2074x784 profile on a
    /// 1440-point-wide screen drew every name about 30% too narrow). Both sides are scaled by one
    /// factor instead, so the window opens whole and keeps its shape.
    ///
    /// - When the profile is an earlier fit of the stored choice (same shape, smaller), the stored
    ///   choice is fitted again, so a bigger screen gets the bigger size back.
    /// - An interface drawn at its own size (0037/0038) that is bigger than the new window is
    ///   scaled down to fit inside it.
    static func playSettings(_ g: GraphicsSettings, stored: GraphicsSettings?, limit: Size) -> GraphicsSettings? {
        let size = Size(width: g.width, height: g.height)
        var want = size
        var storedUI: Size?
        // Same shape within what rounding both sides down to even numbers can move it.
        if let s = stored, s.width > g.width, s.height > g.height, s.height > 0, g.height > 0,
           (-2 * s.width ... 2 * s.height).contains(s.width * g.height - s.height * g.width) {
            want = Size(width: s.width, height: s.height)
            if !s.uiFollowsResolution, !g.uiFollowsResolution { storedUI = Size(width: s.uiWidth, height: s.uiHeight) }
        }
        let fit = fitted(want, into: limit)
        guard fit != size else { return nil }
        // A profile that fits is only ever grown back toward the stored choice, never cut.
        if size.width <= limit.width, size.height <= limit.height,
           !(fit.width > size.width && fit.height > size.height) { return nil }
        var n = g
        n.width = fit.width
        n.height = fit.height
        if let ui = storedUI { n.uiWidth = ui.width; n.uiHeight = ui.height }
        if !n.uiFollowsResolution, n.uiWidth > fit.width || n.uiHeight > fit.height, n.uiWidth > 0, n.uiHeight > 0 {
            let f = min(Double(fit.width) / Double(n.uiWidth), Double(fit.height) / Double(n.uiHeight))
            n.uiWidth = max(640, Int(Double(n.uiWidth) * f) & ~1)
            n.uiHeight = max(480, Int(Double(n.uiHeight) * f) & ~1)
        }
        return n
    }
}
