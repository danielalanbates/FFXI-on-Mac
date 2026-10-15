import Foundation

/// First-run setup: build a working wine wrapper without the user installing anything by hand.
///
/// The manual route is Homebrew, then the Sikarugir cask, then Sikarugir Creator, then picking
/// the right engine out of a list where the wrong ones sit directly above and below it. Every
/// step of that is something a player can get wrong, and the punishment for getting it wrong is
/// a game that silently does not start.
///
/// None of it is actually necessary. A Sikarugir wrapper is two tarballs from two public GitHub
/// releases -- a template .app and a wine engine -- unpacked into each other. This does exactly
/// that, then applies the rpath fix and boots the prefix.
///
/// What it does NOT do is fetch the game: that is the next step of the main button's Setup
/// (HorizonXI's own published torrent, or the world's own installer). See docs/SETUP.md.
enum Bootstrap {

    // MARK: - What we fetch

    /// Pinned by version *and* by hash. An engine that changes under us would change the frame
    /// rate this whole project's numbers are measured against, so upgrades are deliberate.
    /// Both come from Sikarugir's own release pages; nothing is redistributed by us.
    enum Asset {
        static let template = (
            url: URL(string: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz")!,
            bytes: 84_533_420,
            name: "Template-1.0.11.app"
        )
        static let engine = (
            url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz")!,
            bytes: 166_304_096,
            sha256: "9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2",
            name: "WS12WineSikarugir10.0_6"
        )
    }

    /// The wrapper to build, or whose Wine to replace. Setup decides it and nothing else does:
    /// `<chosen>/FFXI on Mac/FFXI on Mac Wine.app` for a new install (the user picked the place
    /// in `LocationPanel`; Daniel, 2026-10-15: "i want to choose"), or the selected wrapper when
    /// only its Wine is missing (its prefix and game untouched, G11). nil: nothing has been
    /// chosen, and `run` builds nothing. There is no default location any more: until b60 it was
    /// `~/Applications/FFXI on Mac Wine.app`, made without asking (discovery still finds one).
    static var target: URL?

    static var prefixName: String { "prefix10" }

    /// The target already has a working Wine.
    static func isBuilt(_ wrapper: URL) -> Bool {
        FileManager.default.isExecutableFile(
            atPath: wrapper.appendingPathComponent("Contents/SharedSupport/wine/bin/wine").path)
    }

    /// The target is an existing wrapper (it has its SharedSupport): only its Wine is replaced.
    static var repairsInPlace: Bool {
        target.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/SharedSupport").path) } ?? false
    }

    /// The install this bootstrap produces, whether or not the game is in it yet.
    static var install: Install? { target.map { Install(wrapper: $0, prefixName: prefixName) } }

    /// The downloads and the unpacking, beside the wrapper (same drive, so the last step is a
    /// rename, and nothing lands anywhere the user did not choose). Removed once Wine is built.
    static func workDir(for wrapper: URL) -> URL {
        wrapper.deletingLastPathComponent().appendingPathComponent(".ffxi-on-mac-setup", isDirectory: true)
    }

    // MARK: - Steps

    enum Step: Int, CaseIterable {
        case rosetta, download, assemble, prefix

        var title: String {
            switch self {
            case .rosetta:  return "Rosetta 2"
            case .download: return "Downloading Wine"
            case .assemble: return "Building the wrapper"
            case .prefix:   return "Creating the Windows drive"
            }
        }

        var detail: String {
            switch self {
            case .rosetta:  return "Apple's translation layer. FFXI is a 32-bit Intel game."
            case .download: return "Two files, about 250 MB, from Sikarugir's GitHub releases."
            case .assemble: return "Unpacking them into the folder you chose, and fixing Wine's library links."
            case .prefix:   return "A blank C: drive for the game to install into."
            }
        }
    }

    // MARK: - Running it

    /// Runs the whole setup, reporting progress as human-readable lines.
    ///
    /// Every step is skipped if it is already done, so a failed run is re-run rather than undone.
    /// Throws on the first genuine failure with a message worth showing to a player.
    static func run(log: @escaping @Sendable (String) -> Void,
                    step: @escaping @Sendable (Step) -> Void) async throws {
        guard let wrapperURL = target else {
            throw Err("Choose where FFXI on Mac goes first: press Setup.")
        }

        step(.rosetta)
        try await ensureRosetta(log: log)

        step(.download)
        let work = workDir(for: wrapperURL)
        let templateTar = work.appendingPathComponent("template.tar.xz")
        let engineTar   = work.appendingPathComponent("engine.tar.xz")

        if !isBuilt(wrapperURL) {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try await download(Asset.template.url, to: templateTar,
                               expecting: Asset.template.bytes, label: "wrapper template", log: log)
            try await download(Asset.engine.url, to: engineTar,
                               expecting: Asset.engine.bytes, label: "wine", log: log)

            log("verifying the download")
            let sum = try sha256(of: engineTar)
            guard sum == Asset.engine.sha256 else {
                throw Err("The wine download did not match its expected checksum, so it was not "
                          + "installed. Try again; if it keeps happening, something between this "
                          + "Mac and GitHub is altering the file.")
            }

            step(.assemble)
            try assemble(template: templateTar, engine: engineTar, into: wrapperURL, work: work, log: log)
            // Our own downloads, now unpacked: kept on a failure above so a second press resumes.
            try? FileManager.default.removeItem(at: work)
        } else {
            log("wine is already installed at \(wrapperURL.path)")
        }

        step(.prefix)
        try await bootPrefix(Install(wrapper: wrapperURL, prefixName: prefixName), log: log)
        log("")
        log("Wine is ready. Close this; the main button shows the next step.")
    }

    // MARK: - Step 1: Rosetta

    /// An x86_64 program runs on this Mac (Rosetta 2 is installed, or the Mac is Intel). The
    /// honest test is whether one actually runs, not whether some file exists.
    static func rosettaRuns() -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        probe.arguments = ["-x86_64", "/usr/bin/true"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    /// Once it runs it stays installed; only a "no" is asked again.
    private static let rosettaSeen = NSLock()
    private static var rosettaKnownGood = false

    /// What the main button reads: Rosetta 2 is missing, so every Wine here (all x86_64) cannot
    /// run and Setup installs it first. `FFXI_ON_MAC_ROSETTA=missing|present` stands in for the
    /// answer in tests; it never makes Setup run softwareupdate (`ensureRosetta` asks the Mac).
    static func rosettaMissing() -> Bool {
        switch ProcessInfo.processInfo.environment["FFXI_ON_MAC_ROSETTA"] {
        case "missing": return true
        case "present": return false
        default: break
        }
        rosettaSeen.lock(); defer { rosettaSeen.unlock() }
        if rosettaKnownGood { return false }
        rosettaKnownGood = rosettaRuns()
        return !rosettaKnownGood
    }

    /// Installs Rosetta 2 through macOS's own administrator prompt (never Terminal), unless an
    /// x86_64 program already runs. Setup's first step, in the sheet and on the main button.
    static func ensureRosetta(log: @escaping @Sendable (String) -> Void) async throws {
        if rosettaRuns() {
            log("Rosetta 2 is already installed.")
            return
        }

        log("Installing Rosetta 2 — macOS will ask for your password.")
        // Needs root, so it goes through the standard authorisation prompt rather than asking
        // the user to open a terminal.
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta "
                   + "--agree-to-license\" with administrator privileges"
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        let err = Pipe()
        osa.standardError = err
        try osa.run()
        osa.waitUntilExit()
        guard osa.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.contains("User canceled") || text.contains("-128") {
                throw Err("Rosetta 2 is required and the install was cancelled. Run setup again "
                          + "when you are ready to allow it.")
            }
            throw Err("Rosetta 2 failed to install: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        log("Rosetta 2 installed.")
    }

    // MARK: - Step 2: download

    private static func download(_ url: URL, to dest: URL, expecting bytes: Int,
                                 label: String,
                                 log: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int, size == bytes {
            log("already downloaded: \(label)")
            return
        }

        log("downloading \(label) (\(bytes / 1_048_576) MB)…")
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Err("Could not download \(label): the server answered \(http.statusCode). "
                      + "Check your internet connection and try again.")
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: temp, to: dest)
        log("downloaded \(label)")
    }

    private static func sha256(of file: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", file.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(text.prefix(64))
    }

    // MARK: - Step 3: assemble

    private static func assemble(template: URL, engine: URL, into wrapperURL: URL, work: URL,
                                 log: @escaping @Sendable (String) -> Void) throws {
        let fm = FileManager.default
        let staging = work.appendingPathComponent("staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        log("unpacking the wrapper template")
        try untar(template, into: staging)
        let unpacked = staging.appendingPathComponent(Asset.template.name)
        guard fm.fileExists(atPath: unpacked.path) else {
            throw Err("The wrapper template unpacked into an unexpected shape. "
                      + "Expected \(Asset.template.name).")
        }

        log("unpacking wine")
        try untar(engine, into: staging)
        let wswine = staging.appendingPathComponent("wswine.bundle")
        guard fm.fileExists(atPath: wswine.path) else {
            throw Err("The wine engine unpacked into an unexpected shape. Expected wswine.bundle.")
        }

        if fm.fileExists(atPath: wrapperURL.appendingPathComponent("Contents/SharedSupport").path) {
            // An existing wrapper whose wine is broken: swap the wine alone. Deleting the
            // wrapper would delete its prefix -- and a 27 GB game inside it.
            let wine = wrapperURL.appendingPathComponent("Contents/SharedSupport/wine")
            let old = wrapperURL.appendingPathComponent("Contents/SharedSupport/wine.broken-\(Int(Date().timeIntervalSince1970))")
            if fm.fileExists(atPath: wine.path) { try fm.moveItem(at: wine, to: old) }
            try fm.moveItem(at: wswine, to: wine)
            try? fm.removeItem(at: old)
            log("replaced wine in \(wrapperURL.path)")
        } else {
            try fm.moveItem(at: wswine,
                            to: unpacked.appendingPathComponent("Contents/SharedSupport/wine"))
            try? fm.createDirectory(at: wrapperURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try fm.moveItem(at: unpacked, to: wrapperURL)
        }
        try? fm.removeItem(at: staging)
        log("built \(wrapperURL.path)")

        // wine and wineserver are linked with an rpath that resolves to a directory the dylibs
        // are not in; without this, wineserver dies on @rpath/libinotify.0.dylib before anything
        // else happens. See scripts/fix-wine-rpath.sh for the full story.
        log("fixing wine's library paths")
        let devScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/fix-wine-rpath.sh")
        guard let script = Bundle.main.url(forResource: "fix-wine-rpath", withExtension: "sh")
                ?? (FileManager.default.fileExists(atPath: devScript.path) ? devScript : nil) else {
            throw Err("fix-wine-rpath.sh is missing from this app.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path, wrapperURL.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") { log(String(line)) }
        guard p.terminationStatus == 0 else {
            throw Err("Could not fix wine's library paths:\n\(text)")
        }
    }

    private static func untar(_ archive: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xJf", archive.path, "-C", dir.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Err("Could not unpack \(archive.lastPathComponent): \(text)")
        }
    }

    // MARK: - Step 4: the prefix

    private static func bootPrefix(_ i: Install, log: @escaping @Sendable (String) -> Void) async throws {
        // system.reg, not drive_c: a wineboot that was killed half way leaves drive_c without it.
        if FileManager.default.fileExists(atPath: i.systemReg.path) {
            log("the Windows drive already exists")
            return
        }
        log("creating the Windows drive (this takes a minute)")
        let p = Process()
        p.executableURL = i.wine
        p.arguments = ["wineboot", "-u"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = i.prefix.path
        env["WINEDEBUG"] = "-all"
        // Mono's and Gecko's install prompts would wait for a click nobody knows to make.
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        env.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH"); env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        // wine writes its first-run chatter to stderr; it is noise unless it fails.
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard FileManager.default.fileExists(atPath: i.systemReg.path) else {
            throw Err("Wine could not create its Windows drive:\n"
                      + text.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        log("the Windows drive is ready")
    }

    struct Err: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
