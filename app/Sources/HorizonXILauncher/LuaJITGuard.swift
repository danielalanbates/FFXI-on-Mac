import Foundation

/// Works around a LuaJIT fault in Ashita 4.3 as it runs on this Mac.
///
/// Under Wine/Rosetta, Ashita 4.3's Addons.dll intermittently dies with
/// EXCEPTION_ACCESS_VIOLATION at Addons.dll+0xA0761A the first time a hot addon draws or handles a
/// command. That address disassembles to LuaJIT's `lj_mcode_patch` walking a NULL machine-code
/// area chain — the JIT's trace patcher, not the addon's own logic. Ashita's reaction is to unload
/// the addon, and sometimes every addon along with the Addons plugin. Two unrelated addons
/// (FFXIFriendList, GMTools) reproduced it identically; both were cured by `jit.off()` at the top
/// of their entry file, so that is what this applies, to every installed addon, before launch.
///
/// The change is one guarded line under a marker comment. It is idempotent (the marker is the
/// check), skips files that already call `jit.off()` themselves, and leaves anything it cannot
/// read as UTF-8 alone rather than risk mangling it. Removing the marker line opts an addon out.
///
/// See docs/FRIENDLIST.md ("Ashita 4.3 LuaJIT fault") for the disassembly and the evidence.
enum LuaJITGuard {
    static let marker = "-- HXI_MAC_JIT_GUARD"
    static let shim = """
    \(marker): added by the FFXI-on-Mac launcher. Ashita 4.3's LuaJIT trace patcher faults inside
    -- Addons.dll under Wine/Rosetta (EXCEPTION_ACCESS_VIOLATION, lj_mcode_patch); interpreted Lua
    -- does not. Delete these lines to opt this addon out.
    if jit and jit.off then jit.off() end

    """

    /// Apply to every `addons/<name>/<name>.lua`. Returns how many files were changed this run.
    @discardableResult
    static func apply(_ install: Install, policy: AddonPolicy? = nil, log: (String) -> Void = { _ in }) -> Int {
        let fm = FileManager.default
        let addonDir = install.gameDir.appendingPathComponent("addons")
        guard let kids = try? fm.contentsOfDirectory(at: addonDir, includingPropertiesForKeys: nil)
        else { return 0 }
        var changed = 0
        for k in kids {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: k.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = k.lastPathComponent
            if name.lowercased() == "libs" { continue }
            if let p = policy, p.isRestricting, !p.allows(name) { continue }
            let entry = k.appendingPathComponent("\(name).lua")
            guard fm.fileExists(atPath: entry.path) else { continue }
            if patch(entry) { changed += 1; log("==> jit guard: \(name)") }
        }
        if changed > 0 { log("==> jit guard applied to \(changed) addon(s)") }
        return changed
    }

    /// True if the file was rewritten.
    static func patch(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return false }
        if text.contains(marker) { return false }
        // Respect an addon that already turns the JIT off itself (FFXIFriendList's fork does).
        let head = text.prefix(8192)
        if head.contains("jit.off()") { return false }
        // Keep a UTF-8 BOM, if any, at the very front where Lua tolerates it.
        var body = text
        var bom = ""
        if body.hasPrefix("\u{FEFF}") { bom = "\u{FEFF}"; body.removeFirst() }
        let out = bom + shim + body
        return Credentials.writeFile(out, to: url)
    }
}
