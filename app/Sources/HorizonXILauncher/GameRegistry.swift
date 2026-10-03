import Foundation

/// Points the prefix's PlayOnline registry at the selected world's game files.
///
/// FFXI does not find its own files: `HKLM\SOFTWARE\PlayOnlineUS\InstallFolder` (0001 = the
/// FINAL FANTASY XI folder, 1000 = PlayOnlineViewer) plus the in-proc COM registrations of
/// FFXi.dll / FFXiMain.dll / FFXiVersions.dll / polcore.dll (whose paths are baked into the
/// class keys) tell it where they are. Those are prefix-global. With one wrapper serving several
/// worlds — HorizonXI's client here, CatsEyeXI's there — they have to name the *selected* world's
/// SquareEnix folder before Ashita starts, or the game loads the other world's FFXiMain.dll (or
/// none). `scripts/install.sh` §2–3 does the same thing once, for HorizonXI; this does it per
/// launch, for whichever folder `Install.squareEnix` resolved to.
///
/// Both registry views are written: the 32-bit game reads `Wow6432Node`, and 64-bit `reg.exe`
/// writes only the 64-bit view (see install.sh). Cached by a marker file in the prefix so the
/// ~2 s of wine process spawns only happen when the target changes.
enum GameRegistry {
    private static func marker(_ i: Install) -> URL { i.prefix.appendingPathComponent(".ffxi-on-mac-registry-target") }

    /// What the registry currently names, if this code wrote it.
    static func current(_ i: Install) -> String? {
        try? String(contentsOf: marker(i), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-point if needed. Must run while no wineserver holds the registry (Runner calls it right
    /// after `RendererSetup.apply`, which stops it). Returns false if the world's SquareEnix folder
    /// is not there to point at.
    @discardableResult
    static func point(_ i: Install, log: (String) -> Void) -> Bool {
        let se = i.squareEnix
        let fm = FileManager.default
        guard fm.fileExists(atPath: se.appendingPathComponent("FINAL FANTASY XI").path) else {
            log("!! no FINAL FANTASY XI folder under \(se.path) — cannot point the game at it")
            return false
        }
        let target = i.squareEnixWine
        if current(i) == target { return true }
        log("==> pointing PlayOnline registry at \(target)")
        let ffxi = target + "\\FINAL FANTASY XI"
        let pol = target + "\\PlayOnlineViewer"
        for regExe in ["C:\\windows\\syswow64\\reg.exe", "reg"] {
            wine(i, [regExe, "add", "HKLM\\SOFTWARE\\PlayOnlineUS\\InstallFolder", "/v", "0001", "/d", ffxi, "/f"])
            wine(i, [regExe, "add", "HKLM\\SOFTWARE\\PlayOnlineUS\\InstallFolder", "/v", "1000", "/d", pol, "/f"])
            wine(i, [regExe, "add", "HKLM\\SOFTWARE\\PlayOnlineUS\\Interface", "/v", "0001", "/d", "0", "/f"])
        }
        // COM: three in-proc servers in FINAL FANTASY XI plus polcore. /s or FFXi.dll opens a
        // dialog nobody can click (see install.sh).
        for d in ["FFXi.dll", "FFXiMain.dll", "FFXiVersions.dll"] {
            wine(i, ["regsvr32", "/s", ffxi + "\\" + d])
        }
        wine(i, ["regsvr32", "/s", pol + "\\viewer\\com\\polcore.dll"])
        // polu.reg = HKCU video settings the game needs present; ships with every client.
        let polu = se.deletingLastPathComponent().appendingPathComponent("polu.reg")
        for cand in [polu, i.driveC.appendingPathComponent("polu.reg")] where fm.fileExists(atPath: cand.path) {
            wine(i, ["regedit", "/S", Install.winePath(cand, driveC: i.driveC)]); break
        }
        Credentials.writeFile(target, to: marker(i))
        RendererSetup.stopWineserver(i)
        return true
    }

    private static func wine(_ i: Install, _ args: [String]) {
        let cmd = "export WINEPREFIX=\(Bridge.shellQuote(i.prefix.path)); export WINEDEBUG=-all; export WINEBOOT_HIDE_DIALOG=1; \(Bridge.shellQuote(Runner.playWine(i).path)) " + args.map(Bridge.shellQuote).joined(separator: " ")
        Bridge.runShell(cmd)
    }
}
