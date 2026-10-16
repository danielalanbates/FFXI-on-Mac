import Foundation

/// FFXI's graphics settings.
///
/// Retail FFXI exposes these through `FINAL FANTASY XI Config.exe`, which HorizonXI's install
/// does not ship — the launcher's old "Graphics…" button tried to run it and silently did
/// nothing. Ashita applies the same values itself: every key under `[ffxi.registry]` in the boot
/// profile is written into the registry before the client starts, so writing that section is
/// equivalent to using the retail config tool, and it is per-profile rather than global.
///
/// Only keys whose meaning Ashita documents are exposed (`registry`), and the panel writes only
/// the keys it shows. FFXI's registry is a flat list of numbered values; a settings panel that
/// writes a guess into somebody's config is worse than one that leaves it alone.
///
/// **b64.** Up to b63 four of the keys were the wrong numbers: texture compression went to 0011,
/// mip mapping to 0018, bump mapping to 0019 and environmental animation to 0021. So
/// "Environmental animation" off turned the *hardware mouse* off, and mip mapping 4 wrote texture
/// compression 4, a value the game does not have. The keys are Ashita's now, the panel shows the
/// game's own values for them, and what older builds stored is read in the old panel's terms
/// (`init(from:)`, docs/BETA-64.md).
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
    /// Background (environment) texture resolution, `0003`, and its twin `0004`.
    /// 512 / 1024 / 2048 / 4096; the stock HorizonXI profile ships 2048, "max" is 4096.
    var textureResolution: Int = 2048
    /// Mip mapping, `0000`: 0 off, 1 lowest quality … 6 best.
    var mipMapping: Int = 6
    /// Environment animations (water, weather), `0011`: 0 off, 1 normal, 2 smooth.
    var environmentAnimations: Int = 2
    /// Bump mapping, `0017`.
    var bumpMapping: Bool = true
    /// Texture compression, `0018`: 0 high, 1 low, 2 uncompressed (best, most memory).
    var textureCompression: Int = 2
    /// Map compression, `0019`: 0 compressed, 1 uncompressed.
    var mapCompression: Int = 1
    /// Sound channels, `0029`, 12–20. Not graphics, but it lives in the same section and the max-
    /// settings profile raises it, so leaving it out would mean "max" silently was not max.
    var soundChannels: Int = 12
    /// Launch at whatever size the window was left at last time (see WindowMemory). On by
    /// default: a resized window that snaps back to the profile's size on the next Play reads
    /// as the launcher forgetting.
    var rememberWindowSize: Bool = true

    init() {}

    // MARK: - The registry keys

    /// One `[ffxi.registry]` key the panel writes, as Ashita documents it.
    struct RegistryKey: Equatable {
        let key: String
        /// Ashita's name for it, word for word.
        let title: String
        /// What the panel takes from a profile, stores and writes. Anything else in a profile
        /// (-1, "whatever the real registry says", or a value an older build wrote to the wrong
        /// key) shows as the stored or default value, and the line is left alone until Apply.
        let range: ClosedRange<Int>
    }

    static let sizes: ClosedRange<Int> = 1...16384

    /// Ashita's own list, addons/lsb2.ini.example (the comment block above `[ffxi.registry]`):
    ///
    ///     0000 Mip Mapping               0=Off, 1 = On; Lowest Quality, 6 = On; Best Quality
    ///     0001 / 0002 Window Width / Window Height
    ///     0003 / 0004 Background Width / Height    Best if divisible by 2. (4096 recommended.)
    ///     0011 Environment Animations    0=Off, 1 = Normal, 2 = Smooth
    ///     0017 Bump Mapping              0=Off, 1 = On
    ///     0018 Texture Compression       0=High, 1 = Low, 2 = Uncompressed
    ///     0019 Map Compression           0=Compressed, 1 = Uncompressed
    ///     0021 Hardware Mouse            0=Off, 1 = On             (never written here)
    ///     0029 Maximum Number Of Sounds  12=Lowest, 20 = Highest
    ///     0037 / 0038 Menu Width / Menu Height
    ///
    /// `--selftest-graphics` checks this table against that file.
    static let registry: [RegistryKey] = [
        RegistryKey(key: "0000", title: "Mip Mapping", range: 0...6),
        RegistryKey(key: "0001", title: "Window Width", range: sizes),
        RegistryKey(key: "0002", title: "Window Height", range: sizes),
        RegistryKey(key: "0003", title: "Background Width", range: 512...4096),
        RegistryKey(key: "0004", title: "Background Height", range: 512...4096),
        RegistryKey(key: "0011", title: "Environment Animations", range: 0...2),
        RegistryKey(key: "0017", title: "Bump Mapping", range: 0...1),
        RegistryKey(key: "0018", title: "Texture Compression", range: 0...2),
        RegistryKey(key: "0019", title: "Map Compression", range: 0...1),
        RegistryKey(key: "0029", title: "Maximum Number Of Sounds", range: 12...20),
        RegistryKey(key: "0037", title: "Menu Width", range: sizes),
        RegistryKey(key: "0038", title: "Menu Height", range: sizes),
    ]

    /// Hardware Mouse. The panel has no control for it and never writes it.
    static let hardwareMouse = "0021"

    static func range(_ key: String) -> ClosedRange<Int>? { registry.first { $0.key == key }?.range }

    /// The panel's choices, in the game's own terms. `--selftest-graphics` checks that each
    /// value is one Ashita documents and that every documented value has one.
    static let mipMappingChoices: [(String, Int)] = [
        ("Off", 0), ("1 (lowest)", 1), ("2", 2), ("3", 3), ("4", 4), ("5", 5), ("6 (best)", 6),
    ]
    static let environmentChoices: [(String, Int)] = [("Off", 0), ("Normal", 1), ("Smooth", 2)]
    static let textureCompressionChoices: [(String, Int)] = [
        ("High (least memory)", 0), ("Low", 1), ("Uncompressed (best)", 2),
    ]
    static let mapCompressionChoices: [(String, Int)] = [("Compressed", 0), ("Uncompressed", 1)]
    static let soundChannelChoices = Array(12...20)

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

    // MARK: - Presets

    /// Every quality key at the top of Ashita's range, 4K. The configuration every performance
    /// measurement in this project was taken against (`scripts/max4k.json`, `docs/X87-WALL.md`).
    static var max4K: GraphicsSettings {
        var g = GraphicsSettings()
        g.width = 3840; g.height = 2160; g.uiFollowsResolution = true
        g.textureResolution = 4096
        g.mipMapping = 6; g.environmentAnimations = 2; g.bumpMapping = true
        g.textureCompression = 2; g.mapCompression = 1
        g.soundChannels = 20
        return g
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
    /// full-size textures at distance. So this preset drops the window size and nothing else:
    /// every quality value is `max4K`'s (4096 textures, 20 sound channels). It is here to save
    /// memory and battery on a machine running a server, a launcher, a narrator and a client at
    /// once, not to gain frames.
    static var lowSpec: GraphicsSettings {
        var g = max4K
        g.width = 640
        g.height = 480
        return g
    }

    /// 1080p with the stock 2048 background textures and 12 sound channels; every other quality
    /// key as `max4K` (as before b64, where it differed from Max in exactly those).
    static var balanced: GraphicsSettings {
        var g = max4K
        g.width = 1920; g.height = 1080
        g.textureResolution = 2048
        g.soundChannels = 12
        return g
    }

    // MARK: - Writing

    /// The `[ffxi.registry]` keys this represents. A value outside the range Ashita documents is
    /// left out rather than written.
    var iniOverrides: [String: String] {
        let all: [String: Int] = [
            "0000": mipMapping,
            "0001": width, "0002": height,
            "0003": textureResolution, "0004": textureResolution,
            "0011": environmentAnimations,
            "0017": bumpMapping ? 1 : 0,
            "0018": textureCompression,
            "0019": mapCompression,
            "0029": soundChannels,
            "0037": uiFollowsResolution ? width : uiWidth,
            "0038": uiFollowsResolution ? height : uiHeight,
        ]
        return all.filter { Self.range($0.key)?.contains($0.value) == true }.mapValues(String.init)
    }

    /// The keys a remembered window size changes (WindowMemory): the size, and the interface's
    /// when it follows the size. Nothing else is rewritten behind the user's back.
    var sizeKeys: Set<String> {
        uiFollowsResolution ? ["0001", "0002", "0037", "0038"] : ["0001", "0002"]
    }

    /// `text` with these keys set in `[ffxi.registry]` (each added at the end of the section when
    /// the profile has no line for it), `only` limiting which. A line that already says the value
    /// is not touched; every other line, 0021 included, stays byte for byte, and the file keeps its
    /// line endings.
    func applied(to text: String, only: Set<String>? = nil) -> String {
        iniOverrides.sorted { $0.key < $1.key }
            .filter { only?.contains($0.key) ?? true }
            .filter { BootProfile.value($0.key, section: "ffxi.registry", in: text) != $0.value }
            .reduce(text) { BootProfile.setting(BootProfile.Setting(section: "ffxi.registry", key: $1.key, value: $1.value), in: $0) }
    }

    func write(to install: Install, profile: String, only: Set<String>? = nil) {
        let name = install.bootProfileName(profile)
        // v3's XML has no `[ffxi.registry]` section.
        guard name.hasSuffix(".ini") else { return }
        let url = install.gameDir.appendingPathComponent("config/boot/\(name)")
        Credentials.profileLock.lock(); defer { Credentials.profileLock.unlock() }
        guard let text = Credentials.readFile(at: url) else { return }
        let out = applied(to: text, only: only)
        if out != text { Credentials.writeFile(out, to: url) }
    }

    // MARK: - Reading a profile

    /// Read what is actually in the profile, so the panel opens showing the real state rather
    /// than whatever this app last wrote. Nil when it has no numeric `[ffxi.registry]` value.
    ///
    /// - Parameter fallback: shown for a key the profile lacks or holds a value outside Ashita's
    ///   range for (the stored settings, normally), and the source of `rememberWindowSize`.
    static func read(from install: Install, profile: String,
                     fallback: GraphicsSettings = GraphicsSettings()) -> GraphicsSettings? {
        let url = install.gameDir.appendingPathComponent("config/boot/\(profile)")
        guard let text = Credentials.readFile(at: url) else { return nil }
        return parse(text, fallback: fallback)
    }

    static func parse(_ text: String, fallback: GraphicsSettings = GraphicsSettings()) -> GraphicsSettings? {
        var vals: [String: Int] = [:]
        var inSection = false
        for raw in TextFile.lines(of: text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line.hasPrefix("[ffxi.registry]"); continue }
            guard inSection, !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // The first line for a key: the one `applied(to:)` rewrites.
            if let n = Int(v), vals[k] == nil { vals[k] = n }
        }
        guard !vals.isEmpty else { return nil }
        func v(_ k: String) -> Int? { vals[k].flatMap { range(k)?.contains($0) == true ? $0 : nil } }
        var g = fallback
        g.width = v("0001") ?? g.width
        g.height = v("0002") ?? g.height
        g.textureResolution = v("0003") ?? g.textureResolution
        g.mipMapping = v("0000") ?? g.mipMapping
        g.environmentAnimations = v("0011") ?? g.environmentAnimations
        g.bumpMapping = v("0017").map { $0 != 0 } ?? g.bumpMapping
        g.textureCompression = v("0018") ?? g.textureCompression
        g.mapCompression = v("0019") ?? g.mapCompression
        g.soundChannels = v("0029") ?? g.soundChannels
        if let uw = v("0037"), let uh = v("0038") {
            g.uiFollowsResolution = uw == g.width && uh == g.height
            g.uiWidth = uw
            g.uiHeight = uh
        }
        return g
    }

    // MARK: - Stored per world

    static let key = "graphics.settings"
    /// Which meaning the stored JSON has: none (builds up to b63) is the old panel's, 2 is this
    /// file's. See `init(from:)`.
    static let schema = 2
    /// Swapped by `--selftest-graphics`, so it never reads or writes the real preferences.
    static var defaults: UserDefaults = .standard

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
        if let s = stored(forWorld: world) { return s }
        // No per-world value yet. The local world starts small (see lowSpec); everything else
        // inherits whatever was stored before this became per-world, so nobody's settings
        // vanish on upgrade.
        if let world, world.lowercased().contains("local") { return .lowSpec }
        return decoded(defaults.data(forKey: key)) ?? .init()
    }

    /// What the user saved for this world itself, or nil: never the shared value or a default.
    static func stored(forWorld world: String?) -> GraphicsSettings? {
        guard let world, !world.isEmpty else { return nil }
        let k = key(for: world)
        return k == key ? nil : decoded(defaults.data(forKey: k))
    }

    static func decoded(_ data: Data?) -> GraphicsSettings? {
        data.flatMap { try? JSONDecoder().decode(GraphicsSettings.self, from: $0) }
    }

    func save(world: String? = nil) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults.set(data, forKey: world.map { Self.key(for: $0) } ?? Self.key)
    }

    /// Every stored `graphics.settings*` value rewritten in this file's terms: an old one is read
    /// through the table at `init(from:)` and saved back with `schema`. Run once per launch, before
    /// the window; a value already in this schema, or one that is not a JSON object (it reads as
    /// the defaults, as it always did), is left as it is. One line per value changed, for
    /// launcher.log.
    @discardableResult
    static func migrateStored() -> [String] {
        var said: [String] = []
        for (k, v) in defaults.dictionaryRepresentation() where k == key || k.hasPrefix(key + ".") {
            guard let data = v as? Data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (object["schema"] as? Int ?? 0) < schema,
                  let s = decoded(data), let out = try? JSONEncoder().encode(s) else { continue }
            defaults.set(out, forKey: k)
            said.append("graphics: \(k) converted to Ashita's registry keys (mip \(s.mipMapping), environment "
                        + "\(s.environmentAnimations), bump \(s.bumpMapping ? 1 : 0), texture compression "
                        + "\(s.textureCompression), map compression \(s.mapCompression))")
        }
        return said.sorted()
    }

    // MARK: - JSON, and what older builds stored

    private enum CodingKeys: String, CodingKey {
        case schema, width, height, uiFollowsResolution, uiWidth, uiHeight, textureResolution
        case soundChannels, rememberWindowSize, bumpMapping
        // New names for the values whose meaning changed, so a build up to b63 reading this
        // never takes them in its own terms (it sees them missing, and keeps its defaults).
        case mipMapping = "mipMappingLevel"
        case environmentAnimations
        case textureCompression = "textureCompressionLevel"
        case mapCompression
    }

    /// What builds up to b63 stored, in their panel's terms.
    private enum LegacyKeys: String, CodingKey {
        case mipMapping, textureCompression, environmentAnimation
    }

    /// The old panel's mip mapping, 0 (Off) to 4 ("higher values use stronger filtering"), onto
    /// Ashita's 0 (off) to 6 (best): Off stays off, the ends stay the ends (1 lowest, 4 best), and
    /// 2 and 3 are spread evenly between, rounded (1 + (old - 1) × 5/3).
    static let legacyMipMapping = [0, 1, 3, 4, 6]

    /// The old panel's choices in Ashita's terms. nil where the old value is missing or is not one
    /// the old panel could hold; the field then keeps its default.
    ///
    /// | old panel (stored)                 | now                                         |
    /// |------------------------------------|---------------------------------------------|
    /// | Mip mapping 0 / 1 / 2 / 3 / 4      | 0000 = 0 / 1 / 3 / 4 / 6                    |
    /// | Textures "Uncompressed" (0)        | 0018 = 2 uncompressed, 0019 = 1 uncompressed |
    /// | Textures "Compressed" (2)          | 0018 = 0 high, 0019 = 0 compressed          |
    /// | (1, only ever read from a profile) | 0018 = 1 low, 0019 = 0 compressed           |
    /// | Environmental animation on / off   | 0011 = 2 smooth / 0 off                     |
    /// | Bump mapping on / off              | 0017 = 1 / 0 (same meaning, same JSON key)  |
    ///
    /// Map compression had no control: it follows the texture choice ("Compressed uses less
    /// graphics memory" covered the maps too, and 0019 is what a user who turned that down had
    /// been running whenever bump mapping was off).
    ///
    /// **Untouched is not a choice.** Mip 2, "Compressed", bump on and environment on were the old
    /// panel's defaults, and every old preset (Max, Balanced, Low) stored exactly them; so did an
    /// Apply that never moved those four, and an old panel opened on the template or max.json
    /// (it read 0018 = 2, 0011 = 2, 0019 = 1, 0021 = 1 as those four). What such a user ran was
    /// the template's max quality, so all four keep this build's defaults. Read in the table's
    /// terms, they came out as high compression and mip 3 — Daniel's shared and local-server
    /// values among them. A value the old panel could not offer (mip -1, textures 1) counts as
    /// its default here. Any other combination moved a control and is read through the table.
    static func legacy(mipMapping: Int?, textureCompression: Int?, environmentAnimation: Bool?,
                       bumpMapping: Bool? = nil)
        -> (mipMapping: Int?, textureCompression: Int?, mapCompression: Int?, environmentAnimations: Int?) {
        let offered = (mipMapping.flatMap { (0...4).contains($0) ? $0 : nil } ?? 2,
                       textureCompression.flatMap { [0, 2].contains($0) ? $0 : nil } ?? 2)
        if offered == (2, 2), bumpMapping ?? true, environmentAnimation ?? true { return (nil, nil, nil, nil) }
        let mip = mipMapping.flatMap { legacyMipMapping.indices.contains($0) ? legacyMipMapping[$0] : nil }
        let tex = textureCompression.flatMap { (0...2).contains($0) ? 2 - $0 : nil }
        return (mip, tex, tex.map { $0 == 2 ? 1 : 0 }, environmentAnimation.map { $0 ? 2 : 0 })
    }

    /// A field that is missing, of the wrong type or outside Ashita's range keeps its default; a
    /// blob written by another build must never reset the rest. Only something that is not a JSON
    /// object at all fails, and `load` then falls back as it always has.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ k: CodingKeys, _ r: ClosedRange<Int>) -> Int? {
            guard let v = try? c.decodeIfPresent(Int.self, forKey: k), r.contains(v) else { return nil }
            return v
        }
        func bool(_ k: CodingKeys) -> Bool? { try? c.decodeIfPresent(Bool.self, forKey: k) }
        let r = { (k: String) in Self.range(k) ?? Self.sizes }
        width = int(.width, r("0001")) ?? width
        height = int(.height, r("0002")) ?? height
        uiFollowsResolution = bool(.uiFollowsResolution) ?? uiFollowsResolution
        uiWidth = int(.uiWidth, r("0037")) ?? uiWidth
        uiHeight = int(.uiHeight, r("0038")) ?? uiHeight
        textureResolution = int(.textureResolution, r("0003")) ?? textureResolution
        bumpMapping = bool(.bumpMapping) ?? bumpMapping
        soundChannels = int(.soundChannels, r("0029")) ?? soundChannels
        rememberWindowSize = bool(.rememberWindowSize) ?? rememberWindowSize
        if (try? c.decodeIfPresent(Int.self, forKey: .schema)).map({ $0 >= 2 }) == true {
            mipMapping = int(.mipMapping, r("0000")) ?? mipMapping
            environmentAnimations = int(.environmentAnimations, r("0011")) ?? environmentAnimations
            textureCompression = int(.textureCompression, r("0018")) ?? textureCompression
            mapCompression = int(.mapCompression, r("0019")) ?? mapCompression
        } else if let old = try? decoder.container(keyedBy: LegacyKeys.self) {
            let m = Self.legacy(mipMapping: try? old.decodeIfPresent(Int.self, forKey: .mipMapping),
                                textureCompression: try? old.decodeIfPresent(Int.self, forKey: .textureCompression),
                                environmentAnimation: try? old.decodeIfPresent(Bool.self, forKey: .environmentAnimation),
                                bumpMapping: bool(.bumpMapping))
            mipMapping = m.mipMapping ?? mipMapping
            textureCompression = m.textureCompression ?? textureCompression
            mapCompression = m.mapCompression ?? mapCompression
            environmentAnimations = m.environmentAnimations ?? environmentAnimations
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schema, forKey: .schema)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(uiFollowsResolution, forKey: .uiFollowsResolution)
        try c.encode(uiWidth, forKey: .uiWidth)
        try c.encode(uiHeight, forKey: .uiHeight)
        try c.encode(textureResolution, forKey: .textureResolution)
        try c.encode(mipMapping, forKey: .mipMapping)
        try c.encode(environmentAnimations, forKey: .environmentAnimations)
        try c.encode(bumpMapping, forKey: .bumpMapping)
        try c.encode(textureCompression, forKey: .textureCompression)
        try c.encode(mapCompression, forKey: .mapCompression)
        try c.encode(soundChannels, forKey: .soundChannels)
        try c.encode(rememberWindowSize, forKey: .rememberWindowSize)
    }
}
