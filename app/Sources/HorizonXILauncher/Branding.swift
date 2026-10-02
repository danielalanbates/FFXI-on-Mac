import Foundation

/// Which server's branding the client shows on its title screen.
///
/// The client Daniel plays on was installed by HorizonXI, and their installer bakes their logo
/// into the game's own data -- entry `menu/titlwin` in `ROM/119/50.dat`. So when he connects to
/// his own LandSandBoat world, or to any other private server, the title screen still says
/// HORIZON XI. It should say what stock FFXI says.
///
/// The fix is an XIPivot overlay (`stockbrand`) holding one patched copy of that DAT with the
/// logo region replaced by the client's own untouched `menu/xilogo` artwork. XIPivot side-loads
/// it, so nothing under `SquareEnix/` is ever modified and the change is undone by dropping one
/// line from `pivot.ini`. `scripts/brandpatch.py` builds the overlay; `docs/BRANDING.md` explains
/// how the texture was found and what else was tried.
///
/// Two things this deliberately does not do:
///
///  * It does not touch the top ~296 rows of that texture, which are not branding at all -- they
///    hold the shared menu wordlist (OK, はい, いいえ, キャンセル ...) and the copyright line.
///  * It does not apply on HorizonXI. Playing on their server showing their branding is correct.
enum Branding {
    static let overlayName = "stockbrand"

    private static func pivotINI(_ install: Install) -> URL {
        install.gameDir.appendingPathComponent("config/pivot/pivot.ini")
    }

    /// Is the overlay present on disk? Without it, enabling it in the ini would do nothing.
    static func overlayInstalled(_ install: Install) -> Bool {
        let dat = install.gameDir
            .appendingPathComponent("polplugins/DATs/\(overlayName)/ROM/119/50.dat")
        return FileManager.default.fileExists(atPath: dat.path)
    }

    /// Turn the stock-branding overlay on or off, leaving every other overlay and every other
    /// setting in the file exactly as it was. Returns false if the file could not be read or
    /// written, or if the overlay is not installed.
    @discardableResult
    static func apply(stockBranding: Bool, to install: Install) -> Bool {
        let url = pivotINI(install)
        guard let text = Credentials.readFile(at: url) else { return false }
        if stockBranding && !overlayInstalled(install) { return false }

        var head: [String] = []
        var overlays: [String] = []
        var inOverlays = false
        let eol = TextFile.terminator(of: text)
        for raw in TextFile.lines(of: text) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased() == "[overlays]" { inOverlays = true; continue }
            if inOverlays {
                if t.hasPrefix("[") { inOverlays = false; head.append(line); continue }
                if let eq = t.firstIndex(of: "=") {
                    let name = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { overlays.append(name) }
                }
                continue
            }
            head.append(line)
        }

        overlays.removeAll { $0.caseInsensitiveCompare(overlayName) == .orderedSame }
        // First in the list wins in XIPivot, and HorizonXI's own overlay would otherwise take
        // precedence for any path they both provide.
        if stockBranding { overlays.insert(overlayName, at: 0) }

        var out = TextFile.join(head, terminator: eol)
        if !out.hasSuffix(eol) { out += eol }
        out += "[overlays]" + eol
        for (i, name) in overlays.enumerated() { out += "\(i)=\(name)" + eol }

        return Credentials.writeFile(out, to: url)
    }

    /// What the selected server should show. HorizonXI keeps its own branding; everything else,
    /// including the local world, gets the stock screen.
    static func wantsStockBranding(_ server: Server) -> Bool {
        server.name != "HorizonXI"
    }
}
