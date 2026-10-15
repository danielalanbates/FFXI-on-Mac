import Foundation

/// One verifiable precondition for the game launching. Every check here corresponds to a failure
/// that was actually hit and diagnosed — see docs/FINDINGS.md.
struct Check: Identifiable {
    enum State { case ok, bad, warn }
    let id: String
    let title: String
    let state: State
    let detail: String
    /// One plain line for when this is what keeps Play grey and no button fixes it. Empty: the
    /// title. (Setup & Diagnostics shows `detail`.)
    var short: String = ""
    /// Name of the drive (`/Volumes/<name>`) the failing path lives on, or passes through by a
    /// symlink, when that drive is not there. Its own line says everything; `detail` adds paths.
    var drive: String? = nil

    /// The line under the main button for a failing check (see Primary.decide).
    var footer: String {
        if let d = drive { return Preflight.driveMessage(d) }
        return short.isEmpty ? title : short
    }
}

enum Preflight {

    /// `loader` and `template` are the world's (`Server.loader`, `Server.bootTemplate`); with
    /// either set, the boot profile is checked against them too.
    static func run(_ install: Install, profile: String = "horizonxi.ini",
                    loader: String = "", template: String = "") -> [Check] {
        let fm = FileManager.default
        var out: [Check] = []

        func add(_ id: String, _ title: String, _ ok: Bool, _ okText: String, _ badText: String,
                 warnOnly: Bool = false, short: String = "", path: String? = nil) {
            // A missing file on a drive that is not there is the drive's problem, not the
            // install's: say which drive, not "missing <path>" (2026-10-14: HorizonXI's SquareEnix
            // links to /Volumes/Games, which was listed as mounted but did not resolve).
            let drive = ok ? nil : path.flatMap { unavailableDrive(for: $0) }
            out.append(Check(id: id, title: title,
                             state: ok ? .ok : (warnOnly ? .warn : .bad),
                             detail: ok ? okText : drive.map { driveMessage($0) + " (\(badText))" } ?? badText,
                             short: short, drive: drive))
        }

        add("volume", "Volume mounted", install.isMounted,
            install.volume?.path ?? "/",
            "\(install.volume?.path ?? "?") is not mounted",
            path: install.wrapper.path)

        guard install.isMounted else { return out }

        // A drive that is also the Time Machine destination is protected as a whole: macOS gives
        // "Operation not permitted" to any app without Full Disk Access, and never prompts. That
        // is exactly what happened when the game data moved to such a drive — every file check
        // below failed with EPERM while Finder and Terminal could read it fine. Say so up front,
        // because the individual failures below look like a broken install rather than a
        // permission.
        if let vol = install.volume, vol.path != "/" {
            var denied = false
            do { _ = try fm.contentsOfDirectory(atPath: install.sharedSupport.path) }
            catch let e as NSError { denied = e.code == NSFileReadNoPermissionError || ((e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM)) }
            if denied {
                add("fda", "Drive readable by this app", false, "",
                    "macOS is refusing to let this app read \(vol.path)"
                    + (Self.isTimeMachineDestination(vol) ? " — it is your Time Machine backup drive, which only apps with Full Disk Access may read." : ".")
                    + " Give FFXI on Mac Full Disk Access (System Settings › Privacy & Security › Full Disk Access), then quit and reopen it — or keep the game on a different drive.",
                    short: "Allow FFXI on Mac in Full Disk Access.")
                return out
            }
        }

        add("wine", "Wine binary", fm.isExecutableFile(atPath: install.wine.path),
            install.wine.path, "missing \(install.wine.path)",
            short: "Wine isn't installed yet.", path: install.wine.path)

        add("client", "Game folder", fm.fileExists(atPath: install.gameDir.path),
            install.gameDir.path, "no client at \(install.gameDir.path)",
            short: "The game isn't installed yet.", path: install.gameDir.path)

        let se = install.squareEnix
        let ffxi = se.appendingPathComponent("FINAL FANTASY XI")
        add("squareenix", "FINAL FANTASY XI data", fm.fileExists(atPath: ffxi.path),
            se.path, "no SquareEnix/FINAL FANTASY XI under \(se.deletingLastPathComponent().path)",
            short: "Some game files are missing.", path: ffxi.path)

        add("ashita", "Ashita-cli.exe", fm.fileExists(atPath: install.ashitaCLI.path),
            "present — launch must go through Ashita, not xiloader",
            "missing \(install.ashitaCLI.path)",
            short: "Some game files are missing.", path: install.ashitaCLI.path)

        // The wrong-client trap. A world pointed at a folder that holds several clients gets
        // whichever one the search reached first, and every downstream step then succeeds --
        // Ashita injects, the loader connects, the registry points somewhere valid -- against
        // another world's game data. It cost this project a full "Eden doesn't work" cycle in
        // August 2026. Blocking, not a warning: there is no safe guess to fall back to.
        if let why = install.clientAmbiguity {
            add("worldclient", "Client belongs to this world", false, "", why,
                short: "Choose this world's game folder.")
        } else if let w = install.worldName, install.dataRoot != nil || !install.ownsWrapperClient {
            add("worldclient", "Client belongs to this world", true, install.gameDir.path,
                "not \(w)'s own client")
        }

        // FINDINGS #1/#2: the wrapper's rpath points at SharedSupport/wine/lib, the dylibs ship in
        // Contents/Frameworks. Symlinking is what removes the DYLD_* dependency that SIP strips.
        let libDir = install.sharedSupport.appendingPathComponent("wine/lib")
        var libErr = ""
        let linked: Int
        do { linked = try fm.contentsOfDirectory(atPath: libDir.path).filter { $0.hasSuffix(".dylib") }.count }
        catch { linked = 0; libErr = " (\(error.localizedDescription))" }
        add("rpath", "dylib rpath fix", linked > 0,
            "\(linked) dylibs linked into wine/lib",
            "no dylibs in wine/lib\(libErr) — wineserver will fail to load (run Repair)",
            short: "Wine needs a quick repair.", path: libDir.path)

        // FINDINGS #3: must exist in the 32-bit (Wow6432Node) view or the game reads nothing.
        var regErr = ""
        let reg: String
        do { reg = try String(contentsOf: install.systemReg, encoding: .utf8) }
        catch { reg = ""; regErr = " (\(error.localizedDescription))" }
        let (hasWow, layoutOK, comOK) = registryState(reg)
        add("reg32", "PlayOnline registry (32-bit view)", hasWow,
            "Wow6432Node\\PlayOnlineUS present",
            "missing from the 32-bit view\(regErr) — the game will exit silently (run Repair)",
            short: "Play sets the game up on the way in.", path: install.systemReg.path)

        // The layout itself: 0001 must be the FINAL FANTASY XI dir, not PlayOnlineViewer.
        add("reglayout", "InstallFolder layout", layoutOK,
            "0001 = FINAL FANTASY XI (correct)",
            "0001 does not point at the FINAL FANTASY XI dir — FFXiMain.dll will not load",
            short: "Play sets the game up on the way in.", path: install.systemReg.path)

        // FINDINGS #4: three in-proc COM servers, all required.
        add("com", "FFXI COM servers registered", comOK,
            "FFXi.FFXiEntry + FFXiMain.GameMain registered",
            "COM servers not registered (run Repair)",
            short: "Play sets the game up on the way in.", path: install.systemReg.path)

        let polcore = install.squareEnix
            .appendingPathComponent("PlayOnlineViewer/viewer/com/polcore.dll")
        add("polcore", "polcore.dll", fm.fileExists(atPath: polcore.path),
            "present", "missing \(polcore.path)", warnOnly: true)

        // The single setting that silently kills the game: Sandbox's patch.ver interface-id
        // bypass. Off + sandbox loaded == "Successfully logged in", then exit two seconds later,
        // with no window and no error anywhere. See Sandbox.swift for the measured table.
        let sbOn = Sandbox.isEnabled(in: install, profile: profile)
        let sbBypass = Sandbox.interfaceBypass(install)
        if sbOn {
            add("sandbox", "Sandbox interface bypass", sbBypass != false,
                sbBypass == nil ? "not set — Ashita's default (on) applies" : "on",
                "off, while the Sandbox POL plugin is loaded — the game will log in and then "
                + "exit about two seconds later with no error. Run Repair, or set "
                + "use_interface_bypass = 1 in config/sandbox/sandbox.ini.",
                short: "Play sets the game up on the way in.")
        }

        add("d3dmetal", "D3DMetal renderer", fm.fileExists(atPath: install.d3dMetal.path),
            install.d3dMetal.path,
            "no D3DMetal in the wrapper — falls back to wine's slower GL path", warnOnly: true)

        // b61: a HorizonXI profile copied from Ashita's example booted pol.exe and never logged
        // in. Play puts the loader and the missing settings right itself (Primary.fixedByPlay),
        // so this never greys Play or says anything under it; Setup & Diagnostics shows it.
        if !loader.isEmpty || !template.isEmpty {
            let wrong = BootProfile.problems(profile, in: install, loader: loader, template: template)
            let name = install.bootProfileName(profile)
            add("bootprofile", "Boot profile", wrong.isEmpty,
                "config/boot/\(name)",
                "config/boot/\(name): " + wrong.joined(separator: "; ") + " — Play fixes this on the way in",
                short: "Play sets the game up on the way in.")
        }

        return out
    }

    /// The PlayOnline registry checks (32-bit view, InstallFolder layout, COM servers) on the text
    /// of `system.reg`. FINDINGS #3/#4.
    static func registryState(_ reg: String) -> (wow: Bool, layout: Bool, com: Bool) {
        let wow = reg.contains(#"Wow6432Node\\PlayOnlineUS\\InstallFolder"#)
            || reg.contains(#"[Software\\Wow6432Node\\PlayOnlineUS\\InstallFolder]"#)
            || reg.range(of: "Wow6432Node\\\\+PlayOnlineUS", options: .regularExpression) != nil
        let layout = reg.range(of: #""0001"=".*FINAL FANTASY XI""#, options: .regularExpression) != nil
        let com = reg.contains("FFXi.FFXiEntry") && reg.contains("FFXiMain.GameMain")
        return (wow, layout, com)
    }

    /// The registry and COM entries Play writes are in the prefix right now (a fresh read).
    static func registryPointed(_ install: Install) -> Bool {
        guard let reg = try? String(contentsOf: install.systemReg, encoding: .utf8) else { return false }
        let r = registryState(reg)
        return r.wow && r.layout && r.com
    }

    static var blocking: (([Check]) -> Bool) = { $0.contains { $0.state == .bad } }

    /// Daniel, 2026-10-15: "restarting the mac shouldn't be listed." The drive is reconnected,
    /// or Setup puts the game somewhere else.
    static func driveMessage(_ name: String) -> String {
        "The '\(name)' drive isn't connected — reconnect it or press Setup."
    }

    /// The `/Volumes/<name>` that `path` lives on, or reaches through a symlink anywhere along
    /// it, when that volume does not resolve. nil when every drive on the way is there (the
    /// file itself may still be missing; that is the caller's to say).
    ///
    /// Both cases are real on this Mac: a path under `/Volumes/<name>` whose drive is unplugged,
    /// and a folder on one drive that is a symlink into another (`drive_c/HorizonXI/SquareEnix`
    /// -> `/Volumes/Games/FFXI/SquareEnix`). The mount table is not asked: on 2026-10-14 it
    /// listed `/Volumes/Games` while the path itself did not exist (a ghost mount), so only
    /// resolving the path tells the truth. lstat/readlink only; nothing is followed twice.
    static func unavailableDrive(for path: String, hops: Int = 0) -> String? {
        let fm = FileManager.default
        let parts = (path as NSString).standardizingPath.split(separator: "/").map(String.init)
        var cur = ""
        for (n, part) in parts.enumerated() {
            if cur.isEmpty, part == "Volumes", n + 1 < parts.count {
                let vol = "/Volumes/" + parts[n + 1]
                if !fm.fileExists(atPath: vol) { return parts[n + 1] }
                // /Volumes is case-insensitive: with 'Games' ghost-mounted, a USB stick named
                // 'GAMES' answered at /Volumes/Games (2026-10-15) and the data looked deleted
                // rather than on a drive that is not there.
                if isImpostor(volume: vol, mountPoint: mountPoint(of: vol)) { return parts[n + 1] }
            }
            let next = cur + "/" + part
            var st = stat()
            guard lstat(next, &st) == 0 else { return nil }   // simply missing
            if st.st_mode & S_IFMT == S_IFLNK {
                guard hops < 16, let dest = try? fm.destinationOfSymbolicLink(atPath: next) else { return nil }
                let base = dest.hasPrefix("/") ? dest : (cur.isEmpty ? "/" : cur) + "/" + dest
                let rest = parts[(n + 1)...].joined(separator: "/")
                return unavailableDrive(for: rest.isEmpty ? base : base + "/" + rest, hops: hops + 1)
            }
            cur = next
        }
        return nil
    }

    /// The mount point that serves `path` (statfs), or nil.
    static func mountPoint(of path: String) -> String? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        var mp = st.f_mntonname
        return withUnsafePointer(to: &mp) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// `/Volumes/<name>` is answered by a different drive: another volume's mount point (exact
    /// case) rather than its own. A folder under /Volumes that is not a mount point at all, or
    /// the boot volume's link, is served by "/" and does not count.
    static func isImpostor(volume: String, mountPoint mp: String?) -> Bool {
        guard let mp, mp.hasPrefix("/Volumes/") else { return false }
        return mp != volume
    }

    // MARK: - Why a drive is missing (b60)

    /// Ghost: the mount table lists `/Volumes/<name>` but the path does not exist (2026-10-14,
    /// 'Games' on Daniel's Mac). Unmounted: macOS knows the volume but it is not mounted --
    /// `diskutil mount` fixes it without admin rights (Repair). Absent: neither knows it. Ghost
    /// and absent read the same to the user: reconnect the drive, or press Setup and put the
    /// game somewhere else.
    enum DriveState: Equatable { case ghost, unmounted(device: String), absent }

    static func driveState(_ name: String) -> DriveState {
        if mountTableLists("/Volumes/\(name)") { return .ghost }
        if let dev = unmountedDevice(named: name) { return .unmounted(device: dev) }
        return .absent
    }

    static func mountTableLists(_ path: String) -> Bool {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let b = buf else { return false }
        for k in 0..<Int(n) {
            var mp = b[k].f_mntonname
            let s = withUnsafePointer(to: &mp) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if s == path { return true }
        }
        return false
    }

    /// The device id (`disk9s1`) of a volume called `name` that is not mounted, from
    /// `diskutil list -plist` (read-only).
    static func unmountedDevice(named name: String) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["list", "-plist"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = root["AllDisksAndPartitions"] as? [[String: Any]] else { return nil }
        var vols: [[String: Any]] = []
        for d in disks {
            vols.append(d)
            vols += (d["Partitions"] as? [[String: Any]]) ?? []
            vols += (d["APFSVolumes"] as? [[String: Any]]) ?? []
        }
        for v in vols where (v["VolumeName"] as? String) == name {
            let mp = (v["MountPoint"] as? String) ?? ""
            if mp.isEmpty, let dev = v["DeviceIdentifier"] as? String { return dev }
        }
        return nil
    }

    /// The one line for a missing drive, by why it is missing.
    static func driveLine(_ name: String, _ state: DriveState?) -> String {
        switch state {
        case .unmounted?: return "The '\(name)' drive isn't mounted."
        case .ghost?, .absent?, nil: return driveMessage(name)
        }
    }

    /// `tmutil destinationinfo` lists the mount points Time Machine backs up to.
    static func isTimeMachineDestination(_ vol: URL) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil"); p.arguments = ["destinationinfo"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("Mount Point   : \(vol.path)")
    }
}
