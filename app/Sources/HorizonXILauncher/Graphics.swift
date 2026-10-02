import Foundation

/// FFXI's graphics settings.
///
/// Retail FFXI exposes these through `FINAL FANTASY XI Config.exe`, which HorizonXI's install
/// does not ship — the launcher's old "Graphics…" button tried to run it and silently did
/// nothing. Ashita applies the same values itself: every key under `[ffxi.registry]` in the boot
/// profile is written into the registry before the client starts, so writing that section is
/// equivalent to using the retail config tool, and it is per-profile rather than global.
///
/// Only keys whose meaning is established are exposed. FFXI's registry is a flat list of
/// numbered values and several are still guesswork; a settings panel that writes a guess into
/// somebody's config is worse than one that leaves it alone.
struct GraphicsSettings: Codable, Equatable {
    /// Renderer resolution — what the world is actually drawn at (`0001`/`0002`).
    var width: Int = 1280
    var height: Int = 720
    /// Menu/UI resolution (`0037`/`0038`).
    ///
    /// FFXI draws the interface at this resolution and scales the result up to the window, so it
    /// is independent of what the world is drawn at — and **a lower interface resolution means a
    /// larger interface**, which is the whole point of exposing it. At 4K the stock behaviour of
    /// matching the two leaves the UI unreadably small.
    ///
    /// `uiFollowsResolution` keeps the old behaviour (match the renderer). When it is off,
    /// `uiWidth`/`uiHeight` are written instead.
    var uiFollowsResolution: Bool = true
    var uiWidth: Int = 1920
    var uiHeight: Int = 1080
    /// Background (environment) texture resolution, `0003`, and its texture-set twin `0004`.
    /// 512 / 1024 / 2048 / 4096; the stock HorizonXI profile ships 2048, "max" is 4096.
    var textureResolution: Int = 2048
    /// Mip mapping, `0018`. 0–4, higher is more aggressive filtering of distant textures.
    var mipMapping: Int = 2
    /// Texture compression, `0011`. 0 = uncompressed (best), 2 = compressed.
    var textureCompression: Int = 2
    /// Bump mapping, `0019`.
    var bumpMapping: Bool = true
    /// Environmental animation (water, weather effects), `0021`.
    var environmentAnimation: Bool = true
    /// Sound channels, `0029`. Not graphics, but it lives in the same section and the max-
    /// settings profile raises it, so leaving it out would mean "max" silently was not max.
    var soundChannels: Int = 12
    /// Launch at whatever size the window was left at last time (see WindowMemory). On by
    /// default: a resized window that snaps back to the profile's size on the next Play reads
    /// as the launcher forgetting.
    var rememberWindowSize: Bool = true

    static let key = "graphics.settings"

    // A hand-written decoder, because the synthesised one fails on a missing key rather than
    // using the default. The blob on disk was written by whichever build the user had before, so
    // every field added since then is absent from it -- and a decode failure resets the lot.
    init() {}

    init(width: Int, height: Int, uiFollowsResolution: Bool, textureResolution: Int,
         mipMapping: Int, textureCompression: Int, bumpMapping: Bool,
         environmentAnimation: Bool, soundChannels: Int,
         uiWidth: Int = 1920, uiHeight: Int = 1080) {
        self.width = width; self.height = height
        self.uiFollowsResolution = uiFollowsResolution
        self.uiWidth = uiWidth; self.uiHeight = uiHeight
        self.textureResolution = textureResolution
        self.mipMapping = mipMapping; self.textureCompression = textureCompression
        self.bumpMapping = bumpMapping; self.environmentAnimation = environmentAnimation
        self.soundChannels = soundChannels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GraphicsSettings()
        width  = try c.decodeIfPresent(Int.self, forKey: .width)  ?? d.width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? d.height
        uiFollowsResolution = try c.decodeIfPresent(Bool.self, forKey: .uiFollowsResolution)
            ?? d.uiFollowsResolution
        uiWidth  = try c.decodeIfPresent(Int.self, forKey: .uiWidth)  ?? d.uiWidth
        uiHeight = try c.decodeIfPresent(Int.self, forKey: .uiHeight) ?? d.uiHeight
        textureResolution = try c.decodeIfPresent(Int.self, forKey: .textureResolution)
            ?? d.textureResolution
        mipMapping = try c.decodeIfPresent(Int.self, forKey: .mipMapping) ?? d.mipMapping
        textureCompression = try c.decodeIfPresent(Int.self, forKey: .textureCompression)
            ?? d.textureCompression
        bumpMapping = try c.decodeIfPresent(Bool.self, forKey: .bumpMapping) ?? d.bumpMapping
        environmentAnimation = try c.decodeIfPresent(Bool.self, forKey: .environmentAnimation)
            ?? d.environmentAnimation
        soundChannels = try c.decodeIfPresent(Int.self, forKey: .soundChannels) ?? d.soundChannels
        rememberWindowSize = try c.decodeIfPresent(Bool.self, forKey: .rememberWindowSize)
            ?? d.rememberWindowSize
    }

    /// Interface resolutions, smallest first — and smaller means a *bigger* on-screen interface.
    /// The labels say so, because "960 × 540" on its own reads like a downgrade.
    static let uiResolutions: [(String, Int, Int)] = [
        ("960 × 540 — largest interface", 960, 540),
        ("1280 × 720 — larger", 1280, 720),
        ("1920 × 1080 — standard", 1920, 1080),
        ("2560 × 1440 — smaller", 2560, 1440),
        ("3840 × 2160 — smallest", 3840, 2160),
    ]

    static let resolutions: [(String, Int, Int)] = [
        ("1280 × 720", 1280, 720),
        ("1920 × 1080", 1920, 1080),
        ("2560 × 1440", 2560, 1440),
        ("3840 × 2160 (4K)", 3840, 2160),
    ]

    /// The configuration every performance measurement in this project was taken against
    /// (`scripts/max4k.json`, `docs/X87-WALL.md`).
    static var max4K: GraphicsSettings {
        GraphicsSettings(width: 3840, height: 2160, uiFollowsResolution: true,
                         textureResolution: 4096, mipMapping: 2, textureCompression: 2,
                         bumpMapping: true, environmentAnimation: true, soundChannels: 20)
    }

    /// As small as FFXI goes, for the local test world.
    ///
    /// **This is for the local LandSandBoat world only.** Daniel's standing rule for this
    /// project is max settings — every benchmark, every release note and every fps figure in
    /// docs/ is measured at maximum, and `scripts/profiles/max.json` exists because the stock
    /// config is *not* max. Low settings must never reach `horizonxi.ini` or anything a release
    /// measures, or the next person reads the numbers and concludes the port got faster.
    ///
    /// Note also that turning *quality* down does not help on this Mac: docs/SETTINGS-SWEEP.md
    /// measured it and "all low" was the slowest variant of the lot (9.71 fps against a 12.85
    /// baseline), because the client is CPU-bound and mip mapping off makes the GPU sample
    /// full-size textures at distance. So this preset drops resolution and leaves quality alone
    /// — fewer pixels, same work per pixel. It is here to save memory and battery on a machine
    /// running a server, a launcher, a narrator and a client at once, not to gain frames.
    static var lowSpec: GraphicsSettings {
        GraphicsSettings(width: 640, height: 480, uiFollowsResolution: true,
                         textureResolution: 1024, mipMapping: 2, textureCompression: 2,
                         bumpMapping: true, environmentAnimation: true, soundChannels: 12)
    }

    static var balanced: GraphicsSettings {
        GraphicsSettings(width: 1920, height: 1080, uiFollowsResolution: true,
                         textureResolution: 2048, mipMapping: 2, textureCompression: 2,
                         bumpMapping: true, environmentAnimation: true, soundChannels: 12)
    }

    /// The `[ffxi.registry]` keys this represents, in the form `applyIniOverrides` wants.
    var iniOverrides: [String: String] {
        var out: [String: String] = [
            "0001": String(width),
            "0002": String(height),
            "0003": String(textureResolution),
            "0004": String(textureResolution),
            "0011": String(textureCompression),
            "0018": String(mipMapping),
            "0019": bumpMapping ? "1" : "0",
            "0021": environmentAnimation ? "1" : "0",
            "0029": String(soundChannels),
        ]
        if uiFollowsResolution {
            out["0037"] = String(width)
            out["0038"] = String(height)
        } else {
            out["0037"] = String(uiWidth)
            out["0038"] = String(uiHeight)
        }
        return out
    }

    /// Stored per world, not globally.
    ///
    /// One stored value shared by every world means the local test world and HorizonXI fight
    /// over the same keys: set one to 640x480 for testing and the next Apply on the other
    /// writes 1920x1080 over it, or the reverse — and whichever was written last wins, which
    /// from the user's chair looks like the launcher forgetting settings at random.
    static func key(for world: String) -> String {
        let slug = world.lowercased().filter { $0.isLetter || $0.isNumber }
        return slug.isEmpty ? key : "\(key).\(slug)"
    }

    /// - Parameter world: the world's name; nil falls back to the old shared value.
    static func load(world: String? = nil) -> GraphicsSettings {
        let d = UserDefaults.standard
        if let world, let data = d.data(forKey: key(for: world)),
           let s = try? JSONDecoder().decode(GraphicsSettings.self, from: data) {
            return s
        }
        // No per-world value yet. The local world starts small (see lowSpec); everything else
        // inherits whatever was stored before this became per-world, so nobody's settings
        // vanish on upgrade.
        if let world, world.lowercased().contains("local") { return .lowSpec }
        guard let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(GraphicsSettings.self, from: data) else { return .init() }
        return s
    }

    func save(world: String? = nil) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: world.map { Self.key(for: $0) } ?? Self.key)
    }

    /// Read what is actually in the profile, so the panel opens showing the real state rather
    /// than whatever this app last wrote.
    static func read(from install: Install, profile: String) -> GraphicsSettings? {
        let url = install.gameDir.appendingPathComponent("config/boot/\(profile)")
        guard let text = Credentials.readFile(at: url) else { return nil }
        var vals: [String: Int] = [:]
        var inSection = false
        for raw in TextFile.lines(of: text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line.hasPrefix("[ffxi.registry]"); continue }
            guard inSection, !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let n = Int(v) { vals[k] = n }
        }
        guard !vals.isEmpty else { return nil }
        var g = GraphicsSettings()
        g.width = vals["0001"] ?? g.width
        g.height = vals["0002"] ?? g.height
        g.textureResolution = vals["0003"] ?? g.textureResolution
        g.mipMapping = vals["0018"] ?? g.mipMapping
        g.textureCompression = vals["0011"] ?? g.textureCompression
        g.bumpMapping = (vals["0019"] ?? 1) != 0
        g.environmentAnimation = (vals["0021"] ?? 1) != 0
        g.soundChannels = vals["0029"] ?? g.soundChannels
        let uw = vals["0037"] ?? g.width
        let uh = vals["0038"] ?? g.height
        g.uiFollowsResolution = uw == g.width && uh == g.height
        g.uiWidth = uw
        g.uiHeight = uh
        return g
    }

    func write(to install: Install, profile: String) {
        Credentials.applyIniOverrides(iniOverrides, to: install, profile: profile)
    }
}
