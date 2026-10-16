import Foundation

/// `--selftest-graphics`: the graphics panel's registry keys (b64), headless.
///
/// - The key table against Ashita's own documentation: `addons/lsb2.ini.example` (the repo's copy
///   under `swift build`, or `$HXI_ASHITA_DOC`), else the excerpt embedded below. When the file is
///   there the excerpt is checked against it too.
/// - Writing and reading a profile: LF and CRLF, `k = v` and `k=v`, keys added in `[ffxi.registry]`
///   only when missing, 0021 and every line the panel does not own kept byte for byte.
/// - What builds up to b63 stored: Daniel's own three values, every old panel value, JSON that is
///   not what it should be, and the one-time conversion of every `graphics.settings*` key.
/// - Profiles an older build damaged (0018 = 4): shown as the stored value, never written unless
///   applied; a remembered window size rewrites the size only.
/// - Setup's fresh profile gets the world's saved graphics; a profile that is there is not touched.
///
/// Preferences go to a throwaway suite (removed afterwards; the real ones are compared before
/// and after), files to a folder under $TMPDIR (removed afterwards). launcher.log is not touched.
///
/// Optional, read-only: `HXI_GRAPHICS_PROFILE_SAMPLE=<copy of a horizonxi.ini, password masked>`
/// prints what the panel would show for it and which lines Apply would change.
extension Headless {
    @MainActor static func runGraphicsSelfTest() -> Never {
        let fm = FileManager.default
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
        let env = ProcessInfo.processInfo.environment
        let tmp = fm.temporaryDirectory.appendingPathComponent("ffxi-graphics-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // The real preferences, only read: the same before and after.
        func realGraphics() -> [String: Data] {
            var out: [String: Data] = [:]
            for d in [UserDefaults.standard, UserDefaults(suiteName: UpdateRules.bundleID)].compactMap({ $0 }) {
                for (k, v) in d.dictionaryRepresentation() where k.hasPrefix(GraphicsSettings.key) {
                    out[k] = (v as? Data) ?? Data("\(v)".utf8)
                }
            }
            return out
        }
        let realBefore = realGraphics()
        let suite = "org.batesai.horizonxi-on-mac.selftest-graphics-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { print("  FAIL no throwaway defaults suite"); exit(1) }
        let savedDefaults = GraphicsSettings.defaults
        GraphicsSettings.defaults = d
        func finish() -> Never {
            GraphicsSettings.defaults = savedDefaults
            d.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: tmp)
            check("the real preferences' graphics values are unchanged", realGraphics() == realBefore)
            var failures = 0
            for (name, ok) in checks {
                if !ok { failures += 1 }
                print("  \(ok ? "ok  " : "FAIL") \(name)")
            }
            print(failures == 0 ? "all \(checks.count) checks passed" : "\(failures) of \(checks.count) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        typealias G = GraphicsSettings

        // MARK: 1. The keys, against Ashita's documentation
        let docURL: URL? = {
            if let p = env["HXI_ASHITA_DOC"] { return URL(fileURLWithPath: p) }
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let u = repo.appendingPathComponent("addons/lsb2.ini.example")
            return fm.fileExists(atPath: u.path) ? u : nil
        }()
        let embedded = registryDoc(ashitaRegistryExcerpt)
        var doc = embedded
        if let u = docURL, let text = try? String(contentsOf: u, encoding: .utf8) {
            let file = registryDoc(text)
            print("     Ashita's key list: \(u.path)")
            check("the embedded excerpt says what Ashita's file says, key for key",
                  !file.isEmpty && embedded.allSatisfy { k, e in file[k]?.title == e.title && file[k]?.values == e.values })
            doc = file
        } else {
            print("     Ashita's key list: the embedded excerpt (no addons/lsb2.ini.example here)")
        }
        for k in G.registry {
            let e = doc[k.key]
            var range: ClosedRange<Int>? = nil
            if let v = e?.values, let lo = v.min(), let hi = v.max() { range = lo...hi }
            check("\(k.key) is \(k.title)" + (range.map { ", \($0.lowerBound)-\($0.upperBound)" } ?? ""),
                  e?.title == k.title && (range == nil || range == k.range))
        }
        check("0021 is Hardware Mouse, and has no place in the panel's table",
              doc[G.hardwareMouse]?.title == "Hardware Mouse" && G.range(G.hardwareMouse) == nil)
        func choices(_ c: [(String, Int)]) -> [Int] { c.map(\.1) }
        check("every documented value has a choice in the panel, and nothing else does",
              choices(G.mipMappingChoices) == Array(G.range("0000")!)
                && choices(G.environmentChoices) == Array(G.range("0011")!)
                && choices(G.textureCompressionChoices) == Array(G.range("0018")!)
                && choices(G.mapCompressionChoices) == Array(G.range("0019")!)
                && G.soundChannelChoices == Array(G.range("0029")!))
        check("the choices read as the game's own words",
              G.mipMappingChoices.first?.0 == "Off" && G.mipMappingChoices.last?.0 == "6 (best)"
                && G.environmentChoices.map(\.0) == ["Off", "Normal", "Smooth"]
                && G.textureCompressionChoices.map(\.0) == ["High (least memory)", "Low", "Uncompressed (best)"]
                && G.mapCompressionChoices.map(\.0) == ["Compressed", "Uncompressed"])
        let panelKeys = Set(G.registry.map(\.key))
        let presets: [(String, G)] = [("Max (4K)", .max4K), ("Low", .lowSpec), ("Balanced", .balanced), ("defaults", G())]
        check("each preset writes exactly the panel's 12 keys, never 0021",
              presets.allSatisfy { Set($0.1.iniOverrides.keys) == panelKeys && $0.1.iniOverrides[G.hardwareMouse] == nil })
        func docMax(_ k: String) -> Int { doc[k]?.values.max() ?? G.range(k)!.upperBound }
        let mx = G.max4K.iniOverrides
        check("Max: every quality key at its documented maximum (mip 6, environment 2, textures 2, maps 1, sounds 20, background 4096); bump mapping 0, as the template",
              ["0000", "0011", "0018", "0019", "0029"].allSatisfy { mx[$0] == String(docMax($0)) }
                && mx["0003"] == "4096" && mx["0004"] == "4096" && mx["0001"] == "3840" && mx["0002"] == "2160"
                && mx["0000"] == "6" && mx["0029"] == "20" && mx["0017"] == "0")
        var low = G.lowSpec; low.width = 3840; low.height = 2160
        var bal = G.balanced; bal.width = 3840; bal.height = 2160; bal.textureResolution = 4096; bal.soundChannels = 20
        check("Low is Max at 640 × 480; Balanced is Max at 1080p with 2048 textures and 12 sounds",
              low == .max4K && G.lowSpec.width == 640 && bal == .max4K && G.balanced.width == 1920
                && G.balanced.textureResolution == 2048 && G.balanced.soundChannels == 12)
        let dflt = G().iniOverrides
        check("the defaults' quality keys are at max (mip 6, environment 2, textures 2, maps 1); bump mapping 0, as the template",
              dflt["0000"] == "6" && dflt["0011"] == "2" && dflt["0017"] == "0" && dflt["0018"] == "2" && dflt["0019"] == "1")
        var odd = G.max4K; odd.mipMapping = 9; odd.textureCompression = 4; odd.soundChannels = 40
        check("a value outside Ashita's range is never written (left out)",
              odd.iniOverrides["0000"] == nil && odd.iniOverrides["0018"] == nil && odd.iniOverrides["0029"] == nil
                && odd.iniOverrides["0011"] == "2")

        // MARK: 2. What builds up to b63 stored
        func json(_ s: String) -> G? { G.decoded(Data(s.utf8)) }
        let danielJSON = #"{"uiWidth":960,"environmentAnimation":false,"textureCompression":2,"uiFollowsResolution":false,"width":1280,"bumpMapping":false,"soundChannels":12,"mipMapping":4,"height":720,"textureResolution":512,"rememberWindowSize":true,"uiHeight":540}"#
        let sharedJSON = #"{"width": 1920, "height": 1080, "uiFollowsResolution": false, "uiWidth": 960, "uiHeight": 540, "textureResolution": 2048, "mipMapping": 2, "textureCompression": 2, "bumpMapping": true, "environmentAnimation": true, "soundChannels": 12, "rememberWindowSize": true}"#
        let localJSON = #"{"width": 3840, "height": 2160, "uiWidth": 1920, "uiHeight": 1080, "uiFollowsResolution": false, "textureResolution": 2048, "mipMapping": 2, "textureCompression": 2, "bumpMapping": true, "environmentAnimation": true, "soundChannels": 12, "rememberWindowSize": false}"#
        let danielKeys = ["0000": "6", "0001": "1280", "0002": "720", "0003": "512", "0004": "512", "0011": "0",
                          "0017": "0", "0018": "0", "0019": "0", "0029": "12", "0037": "960", "0038": "540"]
        let daniel = json(danielJSON)
        check("Daniel's HorizonXI settings: mip 4 -> 6, Compressed -> 0018 = 0 and 0019 = 0, environment off -> 0011 = 0, bump off -> 0017 = 0",
              daniel?.iniOverrides == danielKeys && daniel?.rememberWindowSize == true && daniel?.uiFollowsResolution == false)
        let shared = json(sharedJSON), localS = json(localJSON)
        let defaultQuality = { (g: G?) in g.map { $0.mipMapping == G().mipMapping && $0.textureCompression == G().textureCompression
            && $0.mapCompression == G().mapCompression && $0.environmentAnimations == G().environmentAnimations
            && $0.bumpMapping == G().bumpMapping } == true }
        check("his shared value (the old panel's untouched four): this build's defaults for them, 1920 × 1080, 2048, UI 960 × 540",
              defaultQuality(shared) && shared?.width == 1920 && shared?.height == 1080 && shared?.textureResolution == 2048
                && shared?.uiFollowsResolution == false && shared?.uiWidth == 960 && shared?.soundChannels == 12
                && shared?.iniOverrides["0018"] == "2" && shared?.iniOverrides["0019"] == "1" && shared?.iniOverrides["0000"] == "6")
        check("his local-server value: the same, 4K, remember-window off kept",
              defaultQuality(localS) && localS?.width == 3840 && localS?.rememberWindowSize == false)
        // b63's own encoding of its presets: what Max / Balanced / Low stored.
        let oldMax = #"{"width":3840,"height":2160,"uiFollowsResolution":true,"uiWidth":1920,"uiHeight":1080,"textureResolution":4096,"mipMapping":2,"textureCompression":2,"bumpMapping":true,"environmentAnimation":true,"soundChannels":20,"rememberWindowSize":true}"#
        let oldLow = oldMax.replacingOccurrences(of: #""width":3840,"height":2160"#, with: #""width":640,"height":480"#)
        check("an old Max / Low preset converts to this build's Max / Low; an old blob holding nothing but untouched or impossible values (mip -1, textures 1) to the defaults",
              json(oldMax) == .max4K && json(oldLow) == .lowSpec && json(#"{"mipMapping":2}"#) == G()
                && json(#"{"mipMapping":-1,"textureCompression":1,"bumpMapping":true}"#) == G())
        // With one control moved (environment off), the rest is read in the old panel's terms.
        func oldMip(_ m: Int) -> Int? { json(#"{"mipMapping":\#(m),"environmentAnimation":false}"#)?.mipMapping }
        check("old mip mapping 0, 1, 2, 3, 4 -> 0, 1, 3, 4, 6; anything else keeps the default (6)",
              [0, 1, 2, 3, 4].map(oldMip) == [0, 1, 3, 4, 6] && oldMip(5) == 6 && oldMip(-1) == 6)
        func oldTex(_ t: Int) -> (Int, Int)? {
            json(#"{"textureCompression":\#(t),"environmentAnimation":false}"#).map { ($0.textureCompression, $0.mapCompression) }
        }
        check("old Textures Uncompressed (0) -> 2 / maps 1; Compressed (2) -> 0 / maps 0; 1 -> 1 / maps 0; 7 -> defaults",
              oldTex(0)! == (2, 1) && oldTex(2)! == (0, 0) && oldTex(1)! == (1, 0) && oldTex(7)! == (2, 1))
        check("old environmental animation on -> 2 (smooth), off -> 0; an old bump mapping, on or off, never turns 0017 on",
              json(#"{"environmentAnimation":true}"#)?.environmentAnimations == 2
                && json(#"{"environmentAnimation":false}"#)?.environmentAnimations == 0
                && json(#"{"bumpMapping":false}"#)?.bumpMapping == false && json(#"{"bumpMapping":true}"#)?.bumpMapping == false
                && json(#"{"bumpMapping":true,"environmentAnimation":false}"#)?.bumpMapping == false)
        check("an old value missing a field keeps the default for it",
              json(#"{"width":1600,"height":900}"#).map { $0.width == 1600 && $0.mipMapping == 6 && $0.textureCompression == 2
                  && $0.environmentAnimations == 2 && $0.soundChannels == 12 } == true)
        let samples: [G] = [.max4K, .lowSpec, .balanced, daniel ?? G(), {
            var g = G(); g.width = 2560; g.height = 1440; g.uiFollowsResolution = false; g.uiWidth = 1280; g.uiHeight = 720
            g.mipMapping = 1; g.environmentAnimations = 1; g.bumpMapping = false; g.textureCompression = 1
            g.mapCompression = 0; g.soundChannels = 15; g.rememberWindowSize = false; g.textureResolution = 1024
            return g }()]
        check("this build's JSON reads back exactly", samples.allSatisfy { s in
            (try? JSONEncoder().encode(s)).flatMap { G.decoded($0) } == s })
        let encodedKeys = (try? JSONEncoder().encode(G.max4K)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("it says schema 2 and never uses an old name for a changed value (an older build sees them missing)",
              encodedKeys?["schema"] as? Int == 2 && encodedKeys?["mipMapping"] == nil
                && encodedKeys?["textureCompression"] == nil && encodedKeys?["environmentAnimation"] == nil
                && encodedKeys?["mipMappingLevel"] as? Int == 6 && encodedKeys?["textureCompressionLevel"] as? Int == 2)
        let wild = json(#"{"schema":2,"mipMappingLevel":9,"textureCompressionLevel":4,"environmentAnimations":-1,"mapCompression":2,"soundChannels":40,"textureResolution":100,"width":0,"uiWidth":99999}"#)
        check("schema 2 with values outside Ashita's ranges: those fields keep their defaults",
              wild.map { $0.mipMapping == 6 && $0.textureCompression == 2 && $0.environmentAnimations == 2
                  && $0.mapCompression == 1 && $0.soundChannels == 12 && $0.textureResolution == 2048
                  && $0.width == 1280 && $0.uiWidth == 1920 } == true)
        check("a later schema is read in this one's terms",
              json(#"{"schema":3,"mipMappingLevel":2,"mipMapping":4}"#)?.mipMapping == 2)
        check("JSON that is not an object does not decode (load falls back, as before): text, [], null, a number",
              json("not json") == nil && json("[]") == nil && json("null") == nil && json("42") == nil && G.decoded(Data()) == nil)
        let typed = json(#"{"width":"big","bumpMapping":"yes","environmentAnimation":1,"schema":"two","mipMapping":4,"soundChannels":16}"#)
        check("wrong types: each such field keeps its default, the rest is read (a non-number schema is the old one)",
              typed.map { $0.width == 1280 && !$0.bumpMapping && $0.environmentAnimations == 2 && $0.mipMapping == 6
                  && $0.soundChannels == 16 } == true && json("{}") == G())

        // load(world:) on the throwaway suite.
        d.set(Data("garbage".utf8), forKey: G.key(for: "HorizonXI"))
        d.set(Data(sharedJSON.utf8), forKey: G.key)
        check("an unreadable per-world value falls back to the shared one, as before",
              G.load(world: "HorizonXI") == shared && G.stored(forWorld: "HorizonXI") == nil)
        d.set(Data(danielJSON.utf8), forKey: G.key(for: "HorizonXI"))
        check("load: HorizonXI's own (old) value, read in the new terms", G.load(world: "HorizonXI") == daniel
                && G.stored(forWorld: "HorizonXI") == daniel)
        check("load: the local world with nothing of its own starts at Low; a world never saved has no stored value",
              G.load(world: "Local server") == .lowSpec && G.stored(forWorld: "CatsEyeXI") == nil && G.stored(forWorld: "") == nil)

        // The one-time conversion.
        d.set(Data(localJSON.utf8), forKey: G.key(for: "Local server"))
        d.set(Data("garbage".utf8), forKey: "graphics.settings.broken")
        d.set(Data("[]".utf8), forKey: "graphics.settings.array")
        d.set(Data(danielJSON.utf8), forKey: "graphics.settingsx")
        d.set("left alone", forKey: "graphics.other")
        let said = G.migrateStored()
        func raw(_ k: String) -> Data? { d.data(forKey: k) }
        func schemaOf(_ k: String) -> Int? {
            raw(k).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["schema"] as? Int
        }
        check("every graphics.settings* value converted once (3), each saying so for launcher.log",
              said.count == 3 && said.allSatisfy { $0.hasPrefix("graphics: graphics.settings") }
                && [G.key, G.key(for: "HorizonXI"), G.key(for: "Local server")].allSatisfy { schemaOf($0) == 2 })
        check("...to the same settings: Daniel's, his shared one, the local server's",
              G.decoded(raw(G.key(for: "HorizonXI"))) == daniel && G.decoded(raw(G.key)) == shared
                && G.decoded(raw(G.key(for: "Local server"))) == localS)
        check("what is not a stored JSON object, and keys that only look alike, are left byte for byte",
              raw("graphics.settings.broken") == Data("garbage".utf8) && raw("graphics.settings.array") == Data("[]".utf8)
                && raw("graphics.settingsx") == Data(danielJSON.utf8) && d.string(forKey: "graphics.other") == "left alone")
        let afterFirst = [G.key, G.key(for: "HorizonXI"), G.key(for: "Local server")].map(raw)
        check("a second run changes nothing", G.migrateStored().isEmpty
                && [G.key, G.key(for: "HorizonXI"), G.key(for: "Local server")].map(raw) == afterFirst)

        // MARK: 3. Writing and reading a profile
        guard let template = BootProfile.templateText(BootProfile.horizonTemplate) else {
            check("the HorizonXI template ships", false); finish()
        }
        let lines = { (t: String) in TextFile.lines(of: t) }
        /// Lines that differ, as (old, new); nil when the line count changed.
        func changed(_ a: String, _ b: String) -> [(String, String)]? {
            let x = lines(a), y = lines(b)
            return x.count == y.count ? zip(x, y).filter { $0 != $1 } : nil
        }
        func registryKeyOf(_ line: String) -> String? {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { return nil }
            return t[..<eq].trimmingCharacters(in: .whitespaces)
        }
        for (name, text) in [("LF", template), ("CRLF", template.replacingOccurrences(of: "\n", with: "\r\n"))] {
            let ok = samples.allSatisfy { s in
                let out = s.applied(to: text)
                guard let back = G.parse(out), back.iniOverrides == s.iniOverrides,
                      back.uiFollowsResolution == s.uiFollowsResolution, let diff = changed(text, out),
                      diff.allSatisfy({ registryKeyOf($0.0).map { panelKeys.contains($0) } == true }),
                      s.applied(to: out) == out else { return false }
                return name == "LF" ? !out.contains("\r") : !out.replacingOccurrences(of: "\r\n", with: "").contains("\n")
            }
            check("template (\(name)): write then read gives the same keys, only the panel's lines change, keeps \(name), a second write is a no-op", ok)
            check("template (\(name)): 0021, 0017 = 0 and the account line stay as they were",
                  BootProfile.value("0021", section: "ffxi.registry", in: G.max4K.applied(to: text)) == "1"
                    && BootProfile.value("0017", section: "ffxi.registry", in: text) == "0"
                    && BootProfile.value("0017", section: "ffxi.registry", in: G.max4K.applied(to: text)) == "0"
                    && BootProfile.value("command", section: "ashita.boot", in: G.max4K.applied(to: text))
                        == BootProfile.value("command", section: "ashita.boot", in: text))
        }
        let compact = "[ffxi.registry]\n0000=6\n0001=800\n0002=600\n0003=1024\n0004=1024\n0011=2\n0017=0\n0018=2\n0019=1\n0021=0\n0029=20\n0037=800\n0038=600\n"
        let compactOut = (daniel ?? G()).applied(to: compact)
        check("`k=v` with no spaces: read, rewritten in place as `k=v`, an unchanged value's line and 0021=0 kept byte for byte",
              G.parse(compact)?.iniOverrides["0001"] == "800" && G.parse(compactOut)?.iniOverrides == danielKeys
                && lines(compactOut).contains("0001=1280") && lines(compactOut).contains("0000=6")
                && lines(compactOut).contains("0021=0") && lines(compactOut).count == lines(compact).count
                && changed(compact, compactOut)?.count == 10)
        let padded = "[ffxi.registry]\n0001                                            = 1920\n0002 =1080\n0021 = 1\n"
        check("`k = v` with any spacing is read", G.parse(padded).map { $0.width == 1920 && $0.height == 1080 } == true)
        let sparse = "[ashita.boot]\nfile = x\n0001 = 5\n\n[ffxi.registry]\n0001 = 800\n0002 = 600\n;0018 = 4\n0021 = 0\n\n[ffxi.direct3d8]\nbehaviorflags.fpu_preserve = 0\n"
        let sparseOut = G.max4K.applied(to: sparse)
        check("missing keys are added in [ffxi.registry] only; a 0001 in another section, a comment and 0021 stay",
              panelKeys.allSatisfy { BootProfile.value($0, section: "ffxi.registry", in: sparseOut) != nil }
                && BootProfile.value("0001", section: "ashita.boot", in: sparseOut) == "5"
                && BootProfile.value("0021", section: "ffxi.registry", in: sparseOut) == "0"
                && lines(sparseOut).contains(";0018 = 4")
                && BootProfile.value("behaviorflags.fpu_preserve", section: "ffxi.direct3d8", in: sparseOut) == "0"
                && lines(sparseOut).filter { $0.hasPrefix("[") }.count == 3
                && G.parse(sparseOut)?.iniOverrides == G.max4K.iniOverrides)
        let none = "[ashita.boot]\nfile = x\n"
        check("a profile with no [ffxi.registry] gets one, at the end", G.parse(none) == nil
                && G.parse(G.max4K.applied(to: none))?.iniOverrides == G.max4K.iniOverrides
                && G.max4K.applied(to: none).hasPrefix(none))

        /// A v4 client fixture, as `--selftest-boot-profile` builds them.
        func client(_ name: String) -> Install {
            let i = Install(wrapper: tmp.appendingPathComponent("\(name).app"), prefixName: "prefix")
            for dir in ["bootloader", "config/boot", "SquareEnix/FINAL FANTASY XI"] {
                try? fm.createDirectory(at: i.gameDir.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            fm.createFile(atPath: i.gameDir.appendingPathComponent("Ashita-cli.exe").path, contents: Data())
            fm.createFile(atPath: i.bootLoaderDir.appendingPathComponent("horizon-loader.exe").path, contents: Data())
            return i
        }
        func profileURL(_ i: Install, _ p: String = "horizonxi.ini") -> URL { i.gameDir.appendingPathComponent("config/boot/\(p)") }
        func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        func write(_ t: String, _ u: URL) { try? t.write(to: u, atomically: true, encoding: .utf8) }

        let onDisk = client("ondisk")
        let crlfTemplate = template.replacingOccurrences(of: "\n", with: "\r\n")
        write(crlfTemplate, profileURL(onDisk))
        (daniel ?? G()).write(to: onDisk, profile: "horizonxi.ini")
        let onDiskText = read(profileURL(onDisk))
        check("through the file (CRLF): Apply then the panel's read give Daniel's keys; still CRLF; 0021 = 1 kept",
              G.read(from: onDisk, profile: "horizonxi.ini")?.iniOverrides == danielKeys
                && !onDiskText.replacingOccurrences(of: "\r\n", with: "").contains("\n")
                && BootProfile.value("0021", section: "ffxi.registry", in: onDiskText) == "1")

        // MARK: 4. Profiles an older build damaged
        let damaged = """
            [ashita.boot]
            command = --server play.horizonxi.com

            [ffxi.registry]
            0000 = 6
            0001 = 1280
            0002 = 720
            0003 = 512
            0004 = 512
            0011 = 2
            0017 = 0
            0018 = 4
            0019 = 0
            0021 = 0
            0029 = 12
            0037 = 960
            0038 = 540

            """
        let stored = daniel ?? G()
        let shown = G.parse(damaged, fallback: stored)
        check("siku.app's profile (0018 = 4, written by mip mapping 4): the panel shows the stored 0 for it, the file for the rest",
              shown?.textureCompression == 0 && shown?.environmentAnimations == 2 && shown?.mipMapping == 6
                && shown?.width == 1280 && shown?.uiFollowsResolution == false && shown?.uiWidth == 960)
        let wrecked = "[ffxi.registry]\n0000 = 9\n0001 = -1\n0003 = 100\n0011 = 7\n0017 = 2\n0018 = -1\n0019 = 5\n0029 = 40\n0037 = 0\n0038 = 0\n"
        var other = G.max4K; other.width = 1600; other.height = 900; other.textureResolution = 1024
        check("every key out of range (-1, 9, 7, 40, 0 …): each shows the fallback, nothing crashes",
              G.parse(wrecked, fallback: other) == other && G.parse(wrecked) == G())
        check("and is never written back as it was: Apply writes the shown values, in range",
              G.parse(G.parse(wrecked, fallback: other)!.applied(to: wrecked))?.iniOverrides == other.iniOverrides)
        let sizeOnly = { () -> String in var g = shown ?? stored; g.width = 1600; g.height = 900; return g.applied(to: damaged, only: g.sizeKeys) }()
        check("a size-only write (the remembered window) changes 0001/0002 and nothing else: 0018 = 4 and 0021 = 0 stay",
              changed(damaged, sizeOnly).map { $0.map { registryKeyOf($0.0) ?? "" }.sorted() } == ["0001", "0002"]
                && lines(sizeOnly).contains("0018 = 4") && lines(sizeOnly).contains("0021 = 0"))
        let wm = client("windowmemory")
        write(damaged, profileURL(wm))
        d.set(Data(danielJSON.utf8), forKey: G.key(for: "HorizonXI"))
        let remembered = WindowMemory.remember(first: .init(width: 1280, height: 720), last: .init(width: 1600, height: 900),
                                               install: wm, profile: "horizonxi.ini", world: "HorizonXI")
        let wmText = read(profileURL(wm))
        check("WindowMemory: 1280 × 720 -> 1600 × 900 in the profile and the stored value; 0018 = 4, 0021 = 0, 0011 = 2 untouched, none of them copied into the stored choice",
              remembered != nil && changed(damaged, wmText).map { $0.map { registryKeyOf($0.0) ?? "" }.sorted() } == ["0001", "0002"]
                && G.load(world: "HorizonXI").width == 1600 && G.load(world: "HorizonXI").height == 900
                && G.load(world: "HorizonXI").textureCompression == 0 && G.load(world: "HorizonXI").environmentAnimations == 0)
        let wmFresh = client("windowmemory-unsaved")
        write(damaged, profileURL(wmFresh))
        d.removeObject(forKey: G.key(for: "HorizonXI"))
        let rememberedFresh = WindowMemory.remember(first: .init(width: 1280, height: 720), last: .init(width: 1600, height: 900),
                                                    install: wmFresh, profile: "horizonxi.ini", world: "HorizonXI")
        check("WindowMemory with nothing saved for the world: the profile gets the size, and no stored value is made from the fallback",
              rememberedFresh != nil && BootProfile.value("0001", section: "ffxi.registry", in: read(profileURL(wmFresh))) == "1600"
                && G.stored(forWorld: "HorizonXI") == nil)
        let wmSame = client("windowmemory-same")
        write(damaged, profileURL(wmSame))
        check("WindowMemory: a window that never changed size writes nothing",
              WindowMemory.remember(first: .init(width: 1282, height: 716), last: .init(width: 1282, height: 716),
                                    install: wmSame, profile: "horizonxi.ini", world: "HorizonXI") == nil
                && read(profileURL(wmSame)) == damaged)
        let squeezed = WindowMemory.fitted(.init(width: 2074, height: 784), into: .init(width: 1438, height: 848))
        check("fitted: 2074 × 784 on a 1438 × 848 screen keeps its shape and fits (\(squeezed.width) × \(squeezed.height))",
              squeezed.width <= 1438 && squeezed.height <= 848 && squeezed.width >= 1430
                && abs(Double(squeezed.width) / Double(squeezed.height) - 2074.0 / 784.0) < 0.01
                && squeezed.width % 2 == 0 && squeezed.height % 2 == 0)
        let tall = WindowMemory.fitted(.init(width: 2560, height: 1440), into: .init(width: 1438, height: 848))
        check("fitted: 2560 × 1440 is held by the width and stays 16:9 (\(tall.width) × \(tall.height))",
              tall.width <= 1438 && tall.width >= 1430 && tall.height <= 848 && abs(Double(tall.width) / Double(tall.height) - 16.0 / 9.0) < 0.01)
        check("fitted: a size that fits is left alone, and a shape one factor would take under 640 × 480 is clamped side by side",
              WindowMemory.fitted(.init(width: 1280, height: 720), into: .init(width: 1438, height: 848)) == .init(width: 1280, height: 720)
                && WindowMemory.fitted(.init(width: 2560, height: 784), into: .init(width: 1438, height: 848)) == .init(width: 1438, height: 784))
        let screen = WindowMemory.Size(width: 1438, height: 848)
        var wide = G(); wide.width = 2074; wide.height = 784; wide.uiFollowsResolution = false; wide.uiWidth = 960; wide.uiHeight = 540
        let wideFit = WindowMemory.playSettings(wide, stored: nil, limit: screen)
        check("Play: the 2074 × 784 profile opens whole at \(wideFit?.width ?? 0) × \(wideFit?.height ?? 0), its 960 × 540 interface untouched",
              wideFit.map { $0.width <= 1438 && $0.height <= 848 && $0.width >= 1430 && $0.uiWidth == 960 && $0.uiHeight == 540 } == true)
        var fine = G(); fine.width = 1280; fine.height = 720
        check("Play: a profile that fits and matches its stored choice is left alone",
              WindowMemory.playSettings(fine, stored: fine, limit: screen) == nil)
        let firstFit = WindowMemory.fitted(.init(width: 2560, height: 1440), into: screen)
        var shrunk = G(); shrunk.width = firstFit.width; shrunk.height = firstFit.height; shrunk.uiFollowsResolution = true
        var chosen = shrunk; chosen.width = 2560; chosen.height = 1440
        let regrown = WindowMemory.playSettings(shrunk, stored: chosen, limit: .init(width: 2558, height: 1410))
        check("Play: an earlier fit grows back toward the stored 2560 × 1440 on a bigger screen (\(regrown?.width ?? 0) × \(regrown?.height ?? 0)), still 16:9",
              regrown.map { $0.width > firstFit.width && $0.width <= 2558 && $0.height <= 1410 && abs(Double($0.width) / Double($0.height) - 16.0 / 9.0) < 0.01 } == true
                && WindowMemory.playSettings(shrunk, stored: chosen, limit: screen) == nil)
        var bigUI = G(); bigUI.width = 2560; bigUI.height = 1440; bigUI.uiFollowsResolution = false; bigUI.uiWidth = 1920; bigUI.uiHeight = 1080
        let bigUIFit = WindowMemory.playSettings(bigUI, stored: nil, limit: screen)
        check("Play: an own-size interface bigger than the fitted window is scaled to fit inside it",
              bigUIFit.map { $0.uiWidth <= $0.width && $0.uiHeight <= $0.height && $0.uiWidth >= 640 } == true)

        // MARK: 5. Setup's fresh profile, and one that is already there
        guard let horizon = Server.all.first(where: { $0.name == "HorizonXI" }),
              let local = Server.all.first(where: \.local) else {
            check("the HorizonXI and local worlds exist", false); finish()
        }
        d.removeObject(forKey: G.key(for: "HorizonXI"))
        let plain = client("plain")
        _ = Credentials.ensureProfile(horizon.bootProfile, in: plain, loader: horizon.loader,
                                      template: horizon.bootTemplate, host: horizon.host, world: horizon.name)
        let plainText = read(profileURL(plain))
        check("no saved value for the world: the template's own graphics, as before (1920 × 1080, 4096, 0018 = 2)",
              BootProfile.value("0001", section: "ffxi.registry", in: plainText) == "1920"
                && BootProfile.value("0003", section: "ffxi.registry", in: plainText) == "4096"
                && BootProfile.value("0018", section: "ffxi.registry", in: plainText) == "2"
                && BootProfile.loaderName(in: plainText) == "horizon-loader.exe")
        d.set(Data(danielJSON.utf8), forKey: G.key(for: "HorizonXI"))
        let seeded = client("seeded")
        let made = Credentials.ensureProfile(horizon.bootProfile, in: seeded, loader: horizon.loader,
                                             template: horizon.bootTemplate, host: horizon.host, world: horizon.name)
        let seededText = read(profileURL(seeded))
        check("Setup's fresh profile carries Daniel's saved HorizonXI graphics (1280 × 720, 512, 0011/0017/0018/0019 = 0, 12 sounds, UI 960 × 540)",
              made && G.read(from: seeded, profile: horizon.bootProfile)?.iniOverrides == danielKeys)
        check("...and differs from the template's only in the panel's keys; 0021 stays 1",
              changed(plainText, seededText).map { !$0.isEmpty && $0.allSatisfy { registryKeyOf($0.0).map { panelKeys.contains($0) } == true } } == true
                && BootProfile.value("0021", section: "ffxi.registry", in: seededText) == "1"
                && BootProfile.value("command", section: "ashita.boot", in: seededText) == "--server play.horizonxi.com")
        let anon = client("anon")
        _ = Credentials.ensureProfile(horizon.bootProfile, in: anon, loader: horizon.loader,
                                      template: horizon.bootTemplate, host: horizon.host)
        check("a caller that names no world gets the template as before", read(profileURL(anon)) == plainText)
        let adopt = client("adopt")
        write(damaged, profileURL(adopt))
        let adopted = Credentials.ensureProfile(horizon.bootProfile, in: adopt, loader: horizon.loader,
                                                template: horizon.bootTemplate, host: horizon.host, world: horizon.name)
        check("a profile that is already there (an adopted install) is not touched, byte for byte",
              adopted && read(profileURL(adopt)) == damaged)
        d.set(Data(localJSON.utf8), forKey: G.key(for: local.name))
        let l = client("local")
        let example = "[ashita.boot]\nfile = .\\\\bootloader\\\\pol.exe\ncommand = --server 127.0.0.1\n\n[ffxi.registry]\n0001 = 800\n0002 = 600\n"
        write(example, profileURL(l, "example-privateserver.ini"))
        _ = Credentials.ensureProfile(local.bootProfile, in: l, loader: local.loader, template: local.bootTemplate,
                                      host: local.host, world: local.name)
        check("the local world (no template) is copied as before; only a template-made profile is seeded",
              BootProfile.value("0001", section: "ffxi.registry", in: read(profileURL(l, local.bootProfile))) == "800")

        // MARK: 6. Optional: a real profile, read only
        if let sample = env["HXI_GRAPHICS_PROFILE_SAMPLE"], let text = try? String(contentsOfFile: sample, encoding: .utf8) {
            let reg = { (t: String, k: String) in BootProfile.value(k, section: "ffxi.registry", in: t) ?? "-" }
            let keys = (G.registry.map(\.key) + [G.hardwareMouse]).sorted()
            print("     sample \(URL(fileURLWithPath: sample).lastPathComponent): " + keys.map { "\($0)=\(reg(text, $0))" }.joined(separator: " "))
            // The real stored HorizonXI value, only read (the panel's fallback), else Daniel's copy above.
            let real = UserDefaults(suiteName: UpdateRules.bundleID)?.data(forKey: G.key(for: "HorizonXI")).flatMap(G.decoded)
            let fallback = real ?? stored
            print("     stored HorizonXI value: " + (real == nil ? "none readable; Daniel's copy above" : "the real one")
                  + (real.map { $0 == stored ? " (the same as Daniel's copy)" : " (differs from Daniel's copy)" } ?? ""))
            let panel = G.parse(text, fallback: fallback)
            print("     the panel would show: " + (panel.map { p in G.registry.map { "\($0.key)=\(p.iniOverrides[$0.key] ?? "-")" }.joined(separator: " ") } ?? "nothing (no registry values)"))
            func diff(_ out: String) -> String {
                let d = (changed(text, out) ?? []).map { "\(registryKeyOf($0.0) ?? "?"): \(reg(text, registryKeyOf($0.0) ?? "")) -> \(reg(out, registryKeyOf($0.0) ?? ""))" }
                return d.isEmpty ? "nothing" : d.joined(separator: ", ")
            }
            let asShown = (panel ?? fallback).applied(to: text)
            print("     Apply, nothing changed in the panel, would change: " + diff(asShown))
            let applied = fallback.applied(to: text)
            print("     Apply of the stored settings would change: " + diff(applied))
            check("sample: Apply never changes 0021, and reads back as applied",
                  reg(applied, G.hardwareMouse) == reg(text, G.hardwareMouse) && reg(asShown, G.hardwareMouse) == reg(text, G.hardwareMouse)
                    && G.parse(applied)?.iniOverrides == fallback.iniOverrides
                    && G.parse(asShown)?.iniOverrides == (panel ?? fallback).iniOverrides)
        }

        finish()
    }

    /// Ashita's `[ffxi.registry]` documentation: key -> its title and the values it lists
    /// (`0=Off, 1 = On; …` gives 0 and 1). Read from the comment block after `; ffxi.registry`.
    static func registryDoc(_ text: String) -> [String: (title: String, values: [Int])] {
        var out: [String: (title: String, values: [Int])] = [:]
        var started = false, pending: [String] = [], current: [String] = []
        for raw in TextFile.lines(of: text) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { if started { break } else { continue } }
            guard t.hasPrefix(";") else { continue }
            let body = t.dropFirst().trimmingCharacters(in: .whitespaces)
            if body == "ffxi.registry" { started = true; continue }
            guard started, !body.isEmpty else { continue }
            if body.count > 7, body.prefix(4).allSatisfy(\.isNumber), body.dropFirst(4).hasPrefix(" - (") {
                if !current.isEmpty { current = [] }
                pending.append(String(body.prefix(4)))
            } else if !pending.isEmpty {
                for k in pending { out[k] = (body, []) }
                current = pending; pending = []
            } else if !current.isEmpty {
                let values = body.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap { piece -> Int? in
                    guard let eq = piece.firstIndex(of: "=") else { return nil }
                    return Int(piece[..<eq].trimmingCharacters(in: .whitespaces))
                }
                for k in current { out[k]?.values += values }
            }
        }
        return out
    }

    /// The part of addons/lsb2.ini.example the panel depends on, word for word, for a binary that
    /// runs without the repo beside it.
    static let ashitaRegistryExcerpt = """
        ;---------------------------------------------------------------------------------------------------
        ; ffxi.registry
        ;
        ;   0000 - (number) Default: -1
        ;       Mip Mapping
        ;
        ;       0=Off, 1 = On; Lowest Quality, 6 = On; Best Quality
        ;
        ;   0001 - (number) Default: -1
        ;       Window Width
        ;
        ;   0002 - (number) Default: -1
        ;       Window Height
        ;
        ;   0003 - (number) Default: -1
        ;       Background Width
        ;
        ;       Best if divisible by 2. (4096 recommended.)
        ;
        ;   0004 - (number) Default: -1
        ;       Background Height
        ;
        ;       Best if divisible by 2. (4096 recommended.)
        ;
        ;   0011 - (number) Default: -1
        ;       Environment Animations
        ;
        ;        0=Off, 1 = Normal, 2 = Smooth
        ;
        ;   0017 - (number) Default: -1
        ;       Bump Mapping
        ;
        ;       0=Off, 1 = On
        ;
        ;   0018 - (number) Default: -1
        ;       Texture Compression
        ;
        ;       0=High, 1 = Low, 2 = Uncompressed
        ;
        ;   0019 - (number) Default: -1
        ;       Map Compression
        ;
        ;       0=Compressed, 1 = Uncompressed
        ;
        ;   0021 - (number) Default: -1
        ;       Hardware Mouse
        ;
        ;       0=Off, 1 = On
        ;
        ;   0029 - (number) Default: -1
        ;       Maximum Number Of Sounds
        ;
        ;       12=Lowest, 20 = Highest
        ;
        ;   0037 - (number) Default: -1
        ;       Menu Width
        ;
        ;       Recommended to match Window Width.
        ;
        ;   0038 - (number) Default: -1
        ;       Menu Height
        ;
        ;       Recommended to match Window Height.
        ;---------------------------------------------------------------------------------------------------
        """
}
