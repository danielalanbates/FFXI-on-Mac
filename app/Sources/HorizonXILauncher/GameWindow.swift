import Foundation

/// gamewindow: the game's picture keeps its shape when the player resizes the window.
///
/// FFXI draws into a back buffer of exactly `[ffxi.registry] 0001 x 0002`, created once at
/// start-up and never resized, and the renderer scales it to whatever shape the window is dragged
/// to — wider squeezes everything sideways, taller stretches it. `window/gamewindow.c` is a small
/// dylib inserted into wine (like audiofollow) that calls `-[NSWindow setContentAspectRatio:]` on
/// the game's window, so AppKit keeps every drag of an edge or a corner in the client's proportion.
///
/// The ratio comes from here: `HXI_GAME_ASPECT` is the profile's own 0001/0002, read at Play after
/// the Play-time fit (`Runner.launch`), so it is exactly what the client is started with. With
/// that and the fit, the size `WindowMemory` remembers keeps the same shape too.
///
/// The same dylib keeps the window's title "FFXI on Mac" (`HXI_WINDOW_TITLE`): Ashita retitles the
/// game window with the character's name at login, and wine shows whatever the game sets.
///
/// The dylib also carries `DYLD_INSERT_LIBRARIES` across the x87 sidecar's exec, which strips it
/// (hardened runtime); without that no inserted library reaches an accelerated client. See the
/// header of `window/gamewindow.c` and `docs/BETA-69.md`.
enum GameWindow {
    /// The variable the dylib reads: "<width>x<height>".
    static let aspectKey = "HXI_GAME_ASPECT"
    /// The variable the dylib reads for the game window's title, and the title.
    static let titleKey = "HXI_WINDOW_TITLE"
    static let title = "FFXI on Mac"

    /// The bundled dylib, or the repo's build of it under `swift run`; nil unless it exists and
    /// has the x86_64 slice wine runs as (see `InsertedLibrary.bundled`).
    static func dylib() -> URL? { InsertedLibrary.bundled("gamewindow") }

    /// "<width>x<height>" for the dylib, or nil for a size it would refuse: it takes whole numbers
    /// in 1...32768 with the ratio between 1:4 and 4:1, and ignores anything else.
    static func aspect(_ s: WindowMemory.Size) -> String? {
        guard (1...32768).contains(s.width), (1...32768).contains(s.height),
              s.width <= 4 * s.height, s.height <= 4 * s.width else { return nil }
        return "\(s.width)x\(s.height)"
    }

    /// The size the client will be started at: the boot profile's own 0001 and 0002. Nil when the
    /// profile does not name both (or names one outside Ashita's range): the client then opens at
    /// a size the launcher cannot know, and no ratio is better than a guessed one.
    static func launchSize(_ install: Install, profile: String) -> WindowMemory.Size? {
        var none = GraphicsSettings()
        none.width = 0
        none.height = 0
        guard let g = GraphicsSettings.read(from: install, profile: profile, fallback: none),
              g.width > 0, g.height > 0 else { return nil }
        return .init(width: g.width, height: g.height)
    }

    /// Insert the dylib into `env` with the game window's title and, when the launch size is known
    /// and acceptable, the ratio. No dylib (missing, or no x86_64 slice): `env` is left exactly as
    /// it was.
    static func apply(to env: inout [String: String], dylib: URL?, size: WindowMemory.Size?) {
        guard let dylib else { return }
        InsertedLibrary.insert(dylib.path, into: &env)
        env[titleKey] = title
        if let size, let value = aspect(size) { env[aspectKey] = value }
    }
}
