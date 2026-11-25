import Foundation

/// The three renderer pathways this project has actually measured on an M1/8GB MacBook Pro,
/// 2026-08-10. Every claim below came off an instrumented run — `WINEDEBUG=fps` for the wine
/// paths, DXVK's own HUD for DXVK, `ioreg IOAccelerator` for GPU load — and a screenshot.
///
/// Numbers are from the same machine, same zone (Selbina) or the same menu, so they compare.
enum Renderer: String, Codable, CaseIterable, Identifiable {
    /// D3D8 -> wined3d -> Apple OpenGL. Everything renders. It is the only pathway that has ever
    /// put a complete, textured frame of the game world on screen.
    case openGL

    /// D3D8 -> wined3d -> Vulkan -> MoltenVK -> Metal. The fastest pathway that draws the game
    /// correctly: 8-10 fps in a zone against OpenGL's 3.2, on the GPU.
    ///
    /// It used to render every model and terrain surface as untextured grey, because wined3d's
    /// Vulkan format table lists the D3D10-era names (WINED3DFMT_BC1_UNORM...) but not the D3D8
    /// FourCC aliases (WINED3DFMT_DXT1...), which are different enum values — and a D3D8 game
    /// asks for the latter. `patchDXTFormats` adds them back.
    case vulkan

    /// D3D8 -> d3d8to9 -> DXVK 1.10.3 (patched) -> MoltenVK -> Metal. Renders correctly, fog
    /// included. The world is playable at 4K with every setting at maximum.
    ///
    /// The long-standing black world was fixed-function fog: DXVK declared a zero-sized
    /// fragment push-constant range, so the fog constants arrived zeroed and every lit surface
    /// became the fog colour. Sky and UI skip FFP fog, which is why those always looked
    /// correct. The bundled d3d9 is DXVK 1.10.3 + patches/dxvk-1.10.3-horizonxi.patch, which
    /// fixes that properly rather than bypassing fog.
    ///
    /// The frame rate was never limited by this pathway -- discarding every draw call makes it
    /// slower, not faster. What limited it was FFXI blocking on a lens-flare occlusion read-back
    /// four times a frame; see docs/MAX4K.md and `PerfSettings.flareReadbackNoWait`.
    case metal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openGL: return "Classic (OpenGL)"
        case .vulkan: return "Vulkan"
        case .metal:  return "Metal (DXVK)"
        }
    }

    var blurb: String {
        switch self {
        case .openGL:
            return "Everything draws correctly, on the CPU. Slow: about 3 fps in a zone on an "
                 + "M1. Use it if Vulkan misbehaves."
        case .vulkan:
            return "Draws correctly on the GPU — 8-10 fps in a zone on an M1. The fallback if "
                 + "Metal/DXVK misbehaves on your machine."
        case .metal:
            return "Recommended. The world draws correctly, fog included, at 4K with every "
                 + "setting at maximum."
        }
    }

    /// All three pathways now draw the game correctly.
    var playable: Bool { true }

    /// Shown as the default and the recommendation.
    var recommended: Bool { self == .metal }

    /// Value for HKCU\Software\Wine\Direct3D\renderer. DXVK replaces d3d9 outright, so the
    /// wined3d renderer is irrelevant there and left on gl.
    var wineRendererKey: String { self == .vulkan ? "vulkan" : "gl" }

    /// Does this pathway need the d3d8to9 + DXVK DLLs dropped into the prefix?
    var needsDXVK: Bool { self == .metal }

    /// Extra process environment.
    var environment: [String: String] {
        switch self {
        case .vulkan:
            // Measured on an M1: these three together are worth roughly 30% on this pathway.
            // Argument buffers also avoid the descriptor-binding collision described below.
            return ["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS": "1",
                    "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS": "1",
                    "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS": "0"]
        case .metal:
            // The single fix that turned DXVK from a black window into a rendering one.
            // Without argument buffers, MoltenVK's SPIRV-Cross assigns render_state_t and
            // D3D9FixedFunctionPS both to [[buffer(0)]] and every fixed-function fragment
            // shader fails to compile: "cannot reserve 'buffer' resource location at index 0".
            // DXVK then draws nothing but its own HUD.
            return ["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS": "1"]
        default:
            return [:]
        }
    }

    /// Ashita boot-profile overrides this pathway needs, keyed by ini key.
    ///
    /// `behaviorflags.fpu_preserve = 1` matters a lot on DXVK: without it the entire 3D pass is
    /// missing, with it the sky, clouds and terrain silhouettes come back. FFXI changes the x87
    /// control word, and D3D9 without D3DCREATE_FPU_PRESERVE lets that corrupt its own maths.
    var iniOverrides: [String: String] {
        needsDXVK ? ["behaviorflags.fpu_preserve": "1"] : [:]
    }
}

/// Applies a renderer choice to a wine prefix: registry value, DLL overrides, MoltenVK link.
///
/// Every change is reversible and every original is backed up beside the file it replaces —
/// switching back to Classic must always restore a working game.
enum RendererSetup {
    /// wined3d asks for an OpenGL 4.4 context, macOS caps at 4.1, and the failed request drops it
    /// onto a legacy path. Pinning the version it asks for is worth ~55% on the OpenGL pathway:
    /// measured 5.1 -> 7.9 fps at the same screen, with no visual change.
    static let maxVersionGL: UInt32 = 0x0004_0001

    /// What `apply` may do right now. Every client shares this prefix, and changing a renderer
    /// means `wineserver -k`, which kills whatever is already playing.
    enum Step: Equatable {
        /// Nothing is running: stop the wineserver and rewrite registry and DLLs.
        case stopAndApply
        /// A client is running and the prefix already has this renderer: leave it alone.
        case skip
        case refuse(String)
    }

    static let refuseChangeMessage =
        "stop the other world first, the renderer cannot change under a running client"

    /// `current` nil means the prefix's renderer could not be read. A client running on an
    /// unknown renderer is still not worth killing, so that is a skip as well.
    static func step(for requested: Renderer, current: Renderer?, clientsLive: Bool) -> Step {
        guard clientsLive else { return .stopAndApply }
        if let c = current, c != requested {
            return .refuse("\(requested.title) was asked for but the running world uses \(c.title): "
                           + refuseChangeMessage)
        }
        return .skip
    }

    /// The renderer a prefix is set up for, read from its user.reg as `apply` wrote it.
    static func current(_ install: Install) -> Renderer? {
        Credentials.readFile(at: install.prefix.appendingPathComponent("user.reg"))
            .flatMap(renderer(fromUserReg:))
    }

    static func renderer(fromUserReg text: String) -> Renderer? {
        var section = ""
        var d3dNative = false
        var key: String?
        for raw in TextFile.lines(of: text) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                section = String(t.prefix { $0 != "]" }.dropFirst()).lowercased()
                continue
            }
            let v = t.lowercased()
            if section == #"software\\wine\\dlloverrides"#,
               v.hasPrefix(#""*d3d8"="native"#) || v.hasPrefix(#""d3d8"="native"#) {
                d3dNative = true
            }
            if section == #"software\\wine\\direct3d"#, v.hasPrefix(#""renderer"=""#) {
                key = String(v.dropFirst(#""renderer"=""#.count).prefix { $0 != "\"" })
            }
        }
        if d3dNative { return .metal }
        switch key {
        case "vulkan": return .vulkan
        case "gl": return .openGL
        default: return nil
        }
    }

    /// The file half of `apply` for a `.skip`: put the DXVK shim beside this world's own client
    /// if it is not there yet. No registry write, no wineserver.
    static func ensureFiles(_ renderer: Renderer, for install: Install, sharedGameLive: Bool = false,
                            log: (String) -> Void) {
        guard renderer.needsDXVK,
              let d3d8to9 = Bundle.main.url(forResource: "d3d8to9", withExtension: "dll"),
              let dxvk = Bundle.main.url(forResource: "dxvk-1.10.3-x32-d3d9-horizonxi", withExtension: "dll")
        else { return }
        let fm = FileManager.default
        var placed = 0
        for dir in dllDirs(install, prefixOnly: sharedGameLive) where fm.fileExists(atPath: dir.path) {
            for (src, name) in [(d3d8to9, "d3d8.dll"), (dxvk, "d3d9.dll")] {
                let dst = dir.appendingPathComponent(name)
                guard !fm.contentsEqual(atPath: src.path, andPath: dst.path) else { continue }
                replace(src, at: dst); placed += 1
            }
        }
        if placed > 0 { log("renderer: placed \(placed) DXVK DLLs beside this world's client") }
        if syncDXVKConfig(install) { log("renderer: dxvk.conf updated") }
    }

    /// Runs on every Play with no client live, so it only writes what differs: each `reg add`
    /// is a wine start under Rosetta through osascript, and the old unconditional dozen of them
    /// (plus re-copying the DLLs into five folders) was most of the Play beach-ball in #25.
    /// The order is unchanged; steps that find nothing to do are skipped, and say nothing.
    static func apply(_ renderer: Renderer, to install: Install, sharedGameLive: Bool = false,
                      sharedRuntimeLive: Bool = false, log: (String) -> Void) {
        stopWineserver(install)
        // Read after the stop: a wineserver flushes the registry as it exits, so this is what the
        // next wine will see. nil (unreadable) means every value is written, as before.
        let hive = userHive(install)
        var changed = 0
        changed += regIfNeeded(install, hive, add: #"HKCU\Software\Wine\Direct3D"#, name: "renderer",
                               type: "REG_SZ", data: renderer.wineRendererKey)
        changed += regIfNeeded(install, hive, add: #"HKCU\Software\Wine\Direct3D"#, name: "MaxVersionGL",
                               type: "REG_DWORD", data: String(format: "0x%x", maxVersionGL))

        if renderer.needsDXVK {
            changed += installDXVK(install, hive: hive, sharedGameLive: sharedGameLive,
                                   sharedRuntimeLive: sharedRuntimeLive, log: log)
        } else {
            changed += removeDXVK(install, hive: hive, sharedGameLive: sharedGameLive,
                                  sharedRuntimeLive: sharedRuntimeLive, log: log)
        }
        if renderer == .vulkan {
            if !sharedRuntimeLive { patchDXTFormats(install, log: log) }
            // wined3d's Vulkan renderer needs a MoltenVK that is not the ancient bundled one.
            if !sharedRuntimeLive, linkMoltenVK(install, toCX: true) { changed += 1 }
        }
        stopWineserver(install)
        if changed > 0 { log("renderer: \(renderer.title)") }
    }

    // MARK: - Registry, read-only

    /// `user.reg` as values: section as written, lowercased (`software\\wine\\direct3d`) ->
    /// value name, lowercased -> the value exactly as stored (`"gl"`, `dword:00040001`). Only
    /// ever read: hive files are wine's, and rewriting one by hand is how prefixes get damaged
    /// (docs/HANDOFF.md).
    typealias Hive = [String: [String: String]]

    static func hiveValues(_ text: String) -> Hive {
        var out: Hive = [:]
        var section: String?
        for raw in TextFile.lines(of: text) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                section = t.firstIndex(of: "]").map { String(t[t.index(after: t.startIndex)..<$0]).lowercased() }
                continue
            }
            guard let sec = section, t.hasPrefix("\""), let eq = t.range(of: "\"=") else { continue }
            let name = String(t[t.index(after: t.startIndex)..<eq.lowerBound]).lowercased()
            out[sec, default: [:]][name] = String(t[eq.upperBound...])
        }
        return out
    }

    /// The prefix's user.reg, parsed; nil when it cannot be read directly.
    static func userHive(_ i: Install) -> Hive? {
        (try? String(contentsOf: i.prefix.appendingPathComponent("user.reg"), encoding: .utf8)).map(hiveValues)
    }

    /// `HKCU\Software\Wine\X` -> the section name user.reg files it under.
    private static func hiveSection(_ key: String) -> String {
        var k = key
        for p in [#"HKCU\"#, #"HKEY_CURRENT_USER\"#] where k.uppercased().hasPrefix(p) { k = String(k.dropFirst(p.count)) }
        return k.replacingOccurrences(of: #"\"#, with: #"\\"#).lowercased()
    }

    /// Does the hive already hold exactly what `reg add` would write? Only the two types this
    /// file writes are understood; anything else (or a string needing escapes) is "no".
    static func hiveHas(_ hive: Hive, key: String, name: String, type: String, data: String) -> Bool {
        guard let stored = hive[hiveSection(key)]?[name.lowercased()]?.lowercased() else { return false }
        switch type {
        case "REG_SZ":
            guard !data.contains("\""), !data.contains(#"\"#) else { return false }
            return stored == "\"" + data.lowercased() + "\""
        case "REG_DWORD":
            let d = data.lowercased()
            guard let v = d.hasPrefix("0x") ? UInt32(d.dropFirst(2), radix: 16) : UInt32(d) else { return false }
            return stored == String(format: "dword:%08x", v)
        default:
            return false
        }
    }

    /// `reg add` unless the hive shows the value is already there. Returns 1 if it wrote.
    private static func regIfNeeded(_ i: Install, _ hive: Hive?, add key: String, name: String,
                                    type: String, data: String) -> Int {
        if let hive, hiveHas(hive, key: key, name: name, type: type, data: data) { return 0 }
        reg(i, add: key, name: name, type: type, data: data)
        return 1
    }

    // MARK: - DXVK

    /// DXVK_CONFIG_FILE, as the client sees it (Settings), and the same file on the Mac side.
    static let dxvkConfigWinePath = #"C:\dxvk-cache\dxvk.conf"#
    static func dxvkConfigFile(_ i: Install) -> URL {
        i.driveC.appendingPathComponent("dxvk-cache/dxvk.conf")
    }

    /// vendor/dxvk.conf: in the bundle, or the repo copy under `swift run`.
    static func bundledDXVKConfig() -> URL? {
        if let u = Bundle.main.url(forResource: "dxvk", withExtension: "conf") { return u }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("vendor/dxvk.conf")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// Put the shipped dxvk.conf where DXVK_CONFIG_FILE points, only when it differs. Written
    /// beside it and renamed over it, so a client starting at that moment reads a whole file.
    /// A client already running read its copy at start-up; replacing the file does not reach it.
    /// Returns whether the file was written.
    @discardableResult
    static func syncDXVKConfig(_ i: Install) -> Bool {
        guard let src = bundledDXVKConfig() else { return false }
        let fm = FileManager.default
        let dst = dxvkConfigFile(i)
        if fm.contentsEqual(atPath: src.path, andPath: dst.path) { return false }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".dxvk.conf.\(getpid()).tmp")
        try? fm.removeItem(at: tmp)
        guard (try? fm.copyItem(at: src, to: tmp)) != nil else { return false }
        guard rename(tmp.path, dst.path) == 0 else { try? fm.removeItem(at: tmp); return false }
        return true
    }

    /// Directories whose processes load d3d8: Ashita injects into the loader, so the shim has to
    /// sit beside every one of them, not only the game directory.
    private static func dllDirs(_ i: Install, prefixOnly: Bool = false) -> [URL] {
        if prefixOnly { return [i.driveC.appendingPathComponent("windows/syswow64")] }
        return [i.driveC.appendingPathComponent("windows/syswow64"),
         i.gameDir,
         // v3 clients (Eden, ValhallaXI, FFEra) call it ffxi-bootmod, not bootloader.
         i.bootLoaderDir,
         i.squareEnix.appendingPathComponent("PlayOnlineViewer"),
         i.squareEnix.appendingPathComponent("FINAL FANTASY XI")]
    }

    /// Returns how many things it changed (DLLs, registry values, links, config).
    private static func installDXVK(_ i: Install, hive: Hive?, sharedGameLive: Bool,
                                    sharedRuntimeLive: Bool, log: (String) -> Void) -> Int {
        let fm = FileManager.default
        guard let d3d8to9 = Bundle.main.url(forResource: "d3d8to9", withExtension: "dll"),
              let dxvk = Bundle.main.url(forResource: "dxvk-1.10.3-x32-d3d9-horizonxi", withExtension: "dll")
        else { log("renderer: bundled DXVK not found — staying on Classic"); return 0 }

        var changed = 0
        backupBuiltins(i)
        try? fm.createDirectory(at: i.driveC.appendingPathComponent("dxvk-cache"), withIntermediateDirectories: true)
        // wine ships no api-ms-win-crt-* forwarders; without them the shim silently fails to load
        let crt = i.sharedSupport.appendingPathComponent("wine.cx32bak/lib32on64/wine")
        let syswow = i.driveC.appendingPathComponent("windows/syswow64")
        if let kids = try? fm.contentsOfDirectory(at: crt, includingPropertiesForKeys: nil) {
            for k in kids where k.lastPathComponent.hasPrefix("api-ms-win-crt-") {
                let dst = syswow.appendingPathComponent(k.lastPathComponent)
                if !fm.fileExists(atPath: dst.path), (try? fm.copyItem(at: k, to: dst)) != nil { changed += 1 }
            }
        }
        // Same guard as ensureFiles: a DLL that is already the bundled one is left alone.
        for dir in dllDirs(i, prefixOnly: sharedGameLive) where fm.fileExists(atPath: dir.path) {
            for (src, name) in [(d3d8to9, "d3d8.dll"), (dxvk, "d3d9.dll")] {
                let dst = dir.appendingPathComponent(name)
                guard !fm.contentsEqual(atPath: src.path, andPath: dst.path) else { continue }
                replace(src, at: dst); changed += 1
            }
        }
        changed += regIfNeeded(i, hive, add: #"HKCU\Software\Wine\DllOverrides"#, name: "*d3d8", type: "REG_SZ", data: "native")
        changed += regIfNeeded(i, hive, add: #"HKCU\Software\Wine\DllOverrides"#, name: "*d3d9", type: "REG_SZ", data: "native")
        if !sharedRuntimeLive {
            if linkMoltenVK(i, toCX: true) { changed += 1 }
            if upgradeCoopMoltenVK(log: log) { changed += 1 }
        }
        if syncDXVKConfig(i) { log("renderer: dxvk.conf updated"); changed += 1 }
        if changed > 0 { log("renderer: DXVK 1.10.3 + d3d8to9 installed") }
        return changed
    }

    /// Returns how many things it changed.
    private static func removeDXVK(_ i: Install, hive: Hive?, sharedGameLive: Bool,
                                   sharedRuntimeLive: Bool, log: (String) -> Void) -> Int {
        let fm = FileManager.default
        var changed = 0
        for dir in dllDirs(i, prefixOnly: sharedGameLive) {
            for name in ["d3d8.dll", "d3d9.dll"] {
                let f = dir.appendingPathComponent(name)
                // syswow64 holds wine's own builtins — restore, do not delete
                if dir.lastPathComponent == "syswow64" {
                    let backup = i.driveC.appendingPathComponent("dll-backup")
                        .appendingPathComponent(name.replacingOccurrences(of: ".dll", with: ".builtin.dll"))
                    if fm.fileExists(atPath: backup.path), !fm.contentsEqual(atPath: backup.path, andPath: f.path) {
                        replace(backup, at: f); changed += 1
                    }
                } else if fm.fileExists(atPath: f.path) {
                    try? fm.removeItem(at: f); changed += 1
                }
            }
        }
        // Both spellings. This launcher writes `*d3d8`, but a prefix set up by an older build
        // (or by hand, or by install.sh) carries a plain `d3d8` = native, and *that* is the one
        // that was left behind: switching to Classic then leaves d3d8 forced native with no
        // native d3d8.dll anywhere the loader looks. Measured 2026-08-21 on Gaia XI, whose
        // client folder ships no d3d8.dll:
        //   err:module:import_dll Library d3d8.dll (which is needed by …\Ashita.dll) not found
        //   [E] Injection failed!
        // Deleting only the asterisked name is why that survived a renderer switch.
        let overrides = hive?[hiveSection(#"HKCU\Software\Wine\DllOverrides"#)]
        for name in ["*d3d8", "*d3d9", "d3d8", "d3d9"] where hive == nil || overrides?[name] != nil {
            regDelete(i, key: #"HKCU\Software\Wine\DllOverrides"#, name: name)
            changed += 1
        }
        if !sharedRuntimeLive, linkMoltenVK(i, toCX: false) { changed += 1 }
        return changed
    }

    private static func backupBuiltins(_ i: Install) {
        let fm = FileManager.default
        let dir = i.driveC.appendingPathComponent("dll-backup")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let syswow = i.driveC.appendingPathComponent("windows/syswow64")
        for name in ["d3d8", "d3d9"] {
            let src = syswow.appendingPathComponent("\(name).dll")
            let dst = dir.appendingPathComponent("\(name).builtin.dll")
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    /// DXVK 2.x/3.x cannot replace 1.10.3 here: they require geometryShader, which MoltenVK
    /// does not expose ("No adapters found", measured 2026-09-26 with 3.1.1).
    /// The patched launch wine (X87Sidecar.patchedWine) loads MoltenVK from its own lib/external,
    /// not through linkMoltenVK. Its CrossOver copy stalls command submission under macOS 27's
    /// Metal 4 (0.4-7 fps in-world); 1.4.2 held 49 fps avg. Replace it once, keeping a backup.
    @discardableResult
    private static func upgradeCoopMoltenVK(log: (String) -> Void) -> Bool {
        let fm = FileManager.default
        guard let bundled = Bundle.main.url(forResource: "libMoltenVK-1.4.2", withExtension: "dylib"),
              let wine = X87Sidecar.patchedWine() else { return false }
        let live = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/external/libMoltenVK.dylib")
        guard fm.fileExists(atPath: live.path), !fm.contentsEqual(atPath: live.path, andPath: bundled.path) else { return false }
        let backup = live.appendingPathExtension("bak-pre-1.4.2")
        if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: live, to: backup) }
        replace(bundled, at: live)
        log("renderer: MoltenVK 1.4.2 installed into the launch wine")
        return true
    }

    /// DXVK needs a MoltenVK that can create a Vulkan 1.2 device; the wrapper's default
    /// one is 1.1 and DXVK refuses it with "DxvkAdapter: Failed to create device".
    /// Returns whether the link had to be changed.
    @discardableResult
    private static func linkMoltenVK(_ i: Install, toCX: Bool) -> Bool {
        let fm = FileManager.default
        let link = i.sharedSupport.appendingPathComponent("wine/lib/libMoltenVK.dylib")
        let cx = i.wrapper.appendingPathComponent("Contents/Frameworks/moltenvkcx/libMoltenVK.dylib")
        let stock = i.wrapper.appendingPathComponent("Contents/Frameworks/libMoltenVK.dylib")
        let target = toCX && fm.fileExists(atPath: cx.path) ? cx : stock
        guard fm.fileExists(atPath: target.path) else { return false }
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target.path { return false }
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: target)
        return true
    }

    /// Every dylib in `wine/lib` is a symlink into the wrapper's own `Contents/Frameworks`.
    /// Copying or moving a wrapper with `cp -R`/`rsync` preserves those symlinks *verbatim*, so
    /// all 94 of them keep pointing at the **old** location. While the old copy is still on a
    /// mounted disk nothing looks wrong -- and then the day it is unplugged or deleted, wine
    /// stops loading. Worse, `libMoltenVK.dylib` silently keeps resolving to the previous
    /// wrapper's MoltenVK rather than this one's, which is a renderer difference, not a
    /// missing file.
    ///
    /// Re-point anything that escapes this wrapper at the matching file inside it.
    /// Returns the number of links repaired.
    @discardableResult
    static func relinkStrayDylibs(_ i: Install, log: (String) -> Void = { _ in }) -> Int {
        let fm = FileManager.default
        let libDir = i.sharedSupport.appendingPathComponent("wine/lib")
        let frameworks = i.wrapper.appendingPathComponent("Contents/Frameworks")
        guard let kids = try? fm.contentsOfDirectory(atPath: libDir.path) else { return 0 }
        var fixed = 0
        for name in kids where name.hasSuffix(".dylib") {
            let link = libDir.appendingPathComponent(name)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            // Already inside this wrapper: leave it alone.
            guard !dest.hasPrefix(i.wrapper.path) else { continue }
            let local = frameworks.appendingPathComponent(name)
            guard fm.fileExists(atPath: local.path) else { continue }
            try? fm.removeItem(at: link)
            guard (try? fm.createSymbolicLink(at: link, withDestinationURL: local)) != nil else { continue }
            fixed += 1
        }
        if fixed > 0 { log("wrapper: re-pointed \(fixed) dylib links that still referenced the previous copy") }
        return fixed
    }

    // MARK: - The DXT fix

    /// Add DXT1-5 to wined3d's Vulkan format table.
    ///
    /// The table is an array of {u32 wined3d_format_id, u32 VkFormat, u32 fixup_ptr} in the PE's
    /// read-only data. Upstream's fix is five extra rows; we cannot grow a static array in a
    /// shipped binary, so we rewrite five rows that a 2002 D3D8 game can never ask for — the
    /// BC4/BC5/BC6H/BC7 entries — to carry the DXT ids instead. Same size, no relocation, and the
    /// original is kept beside it as wined3d.dll.orig.
    private static func patchDXTFormats(_ i: Install, log: (String) -> Void) {
        let dll = i.sharedSupport
            .appendingPathComponent("wine/lib/wine/i386-windows/wined3d.dll")
        guard var data = try? Data(contentsOf: dll) else { return }

        func u32(_ o: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
        }
        func put(_ o: Int, _ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { src in
                data.replaceSubrange(o..<(o + 4), with: src)
            }
        }
        func fourCC(_ s: String) -> UInt32 {
            var v: UInt32 = 0
            for (n, c) in s.utf8.enumerated() { v |= UInt32(c) << (8 * n) }
            return v
        }

        // Anchor on the VkFormat column: BC1_RGBA_UNORM(133) ... BC7_SRGB(146) at a 12-byte stride.
        var base = -1
        var o = 0
        while o + 12 * 14 + 8 < data.count {
            if u32(o) == 133, (0..<14).allSatisfy({ u32(o + 12 * $0) == 133 + UInt32($0) }) {
                base = o - 4
                break
            }
            o += 4
        }
        guard base >= 0 else { log("renderer: wined3d format table not found; leaving it alone"); return }

        // donor VkFormat -> (new wined3d id, new VkFormat).  135 = BC2_UNORM, 137 = BC3_UNORM.
        let plan: [(UInt32, UInt32, UInt32)] = [
            (139, fourCC("DXT1"), 133), (140, fourCC("DXT2"), 135), (143, fourCC("DXT3"), 135),
            (144, fourCC("DXT4"), 137), (145, fourCC("DXT5"), 137),
        ]
        var patched = 0
        for (donor, newID, newVk) in plan {
            for k in 0..<14 {
                let row = base + 12 * k
                if u32(row + 4) == donor, u32(row + 8) == 0 {
                    put(row, newID); put(row + 4, newVk); patched += 1
                    break
                }
            }
        }
        guard patched == plan.count else {
            log("renderer: DXT rows already applied, or the table is not the expected shape")
            return
        }
        let backup = dll.appendingPathExtension("orig")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: dll, to: backup)
        }
        try? data.write(to: dll)
        log("renderer: taught wined3d's Vulkan backend about DXT1-5")
    }

    private static func replace(_ src: URL, at dst: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        if (try? fm.copyItem(at: src, to: dst)) == nil {
            Bridge.runShell("/bin/rm -f \(Bridge.shellQuote(dst.path)) && /bin/cp -f \(Bridge.shellQuote(src.path)) \(Bridge.shellQuote(dst.path))")
        }
    }

    // MARK: - wine plumbing

    /// `reg` edits do not reach a running wineserver, and a stale one silently keeps the old
    /// value — which is how an earlier pass of this project produced a "success" screenshot from
    /// the pathway it thought it had just switched away from.
    /// Returns whether a wineserver was actually running when asked, so callers can say so.
    @discardableResult
    static func stopWineserver(_ i: Install, log: (String) -> Void = { _ in }) -> Bool {
        let wine = Runner.playWine(i)
        let wineserver = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        let chk = Process()
        chk.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        chk.arguments = ["-x", "wineserver"]
        chk.standardOutput = Pipe(); chk.standardError = Pipe()
        var wasUp = false
        if (try? chk.run()) != nil {
            chk.waitUntilExit()
            wasUp = chk.terminationStatus == 0
            // pgrep's 1 is "no such process": no wineserver at all, so none for this prefix and
            // nothing to flush. Skip the -k and -w, each an osascript plus a wine start under
            // Rosetta. A pgrep that errored or did not run falls through to both, as before.
            if chk.terminationStatus == 1 { return false }
        }

        let killCmd = "export WINEPREFIX=\(Bridge.shellQuote(i.prefix.path)); \(Bridge.shellQuote(wineserver.path)) -k"
        Bridge.runShell(killCmd)

        // `-k` only *sends* the kill; the server then flushes the registry and exits on its own
        // time. A fixed 1.5 s covered that on the SSD, but after the wrapper moved to the x10
        // (spinning disk) the flush can outlive it — and a game spawned while the old server is
        // still dying gets torn down with it about a second after login ("Closing…", every
        // world, 2026-08-19). `wineserver -w` blocks until the server has actually terminated.
        //
        // Bounded since b61: `-w` waits on the server's lock with no limit, and Play runs this on
        // the main thread, so a server stuck flushing to a drive that went away held the window
        // for good. Past `waitLimit` Play goes on and launcher.log says so. (b60's silent first
        // Play on 2026-10-15 was not this: the system log has the registry session's last
        // wineserver gone 0.35 s before the game was spawned. See docs/BETA-61.md.)
        let ws = Bridge.shellQuote(wineserver.path)
        let waitCmd = "export WINEPREFIX=\(Bridge.shellQuote(i.prefix.path)); \(ws) -w & w=$!; n=0; "
            + "while kill -0 $w 2>/dev/null; do n=$((n+1)); "
            + "if [ $n -ge \(Int(waitLimit * 10)) ]; then kill $w 2>/dev/null; echo still-running; exit 0; fi; "
            + "sleep 0.1; done"
        if Bridge.runShell(waitCmd).output.contains("still-running") {
            log("i  wineserver still closing after \(Int(waitLimit)) s; going on without waiting longer")
        }
        return wasUp
    }

    /// How long `stopWineserver` waits for the old wineserver to be gone.
    static let waitLimit: Double = 30

    private static func reg(_ i: Install, add key: String, name: String, type: String, data: String) {
        wine(i, ["reg", "add", key, "/v", name, "/t", type, "/d", data, "/f"])
    }

    private static func regDelete(_ i: Install, key: String, name: String) {
        wine(i, ["reg", "delete", key, "/v", name, "/f"])
    }

    private static func wine(_ i: Install, _ args: [String]) {
        let cmd = "export WINEPREFIX=\(Bridge.shellQuote(i.prefix.path)); export WINEDEBUG=-all; export WINEBOOT_HIDE_DIALOG=1; \(Bridge.shellQuote(Runner.playWine(i).path)) " + args.map(Bridge.shellQuote).joined(separator: " ")
        Bridge.runShell(cmd)
    }
}
