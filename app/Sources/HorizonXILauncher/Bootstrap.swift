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
/// What it does NOT do is fetch the game. FFXI's data is Square Enix's, and this project does
/// not touch it: the last step hands the user's own server installer to the prefix and lets it
/// run. See docs/SETUP.md.
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

    /// Where the wrapper is built. `~/Applications` rather than `/Applications` because it needs
    /// no admin rights, and because `Install.discover()` already looks there.
    static var wrapperURL: URL {
        target ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/FFXI on Mac Wine.app")
    }

    /// Set by the main button's Install Wine when the selected wrapper is the one whose wine is
    /// missing: its wine is replaced in place, its prefix and game untouched (G11). nil: build
    /// the default wrapper.
    static var target: URL?

    static var prefixName: String { "prefix10" }

    static var isBuilt: Bool {
        FileManager.default.isExecutableFile(
            atPath: wrapperURL.appendingPathComponent("Contents/SharedSupport/wine/bin/wine").path)
    }

    /// The install this bootstrap produces, whether or not the game is in it yet.
    static var install: Install { Install(wrapper: wrapperURL, prefixName: prefixName) }

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
            case .assemble: return "Unpacking them into ~/Applications, and fixing wine's dylib paths."
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

        step(.rosetta)
        try await ensureRosetta(log: log)

        step(.download)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffxi-on-mac-setup", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let templateTar = tmp.appendingPathComponent("template.tar.xz")
        let engineTar   = tmp.appendingPathComponent("engine.tar.xz")

        if !isBuilt {
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
            try assemble(template: templateTar, engine: engineTar, log: log)
        } else {
            log("wine is already installed at \(wrapperURL.path)")
        }

        step(.prefix)
        try await bootPrefix(log: log)
        log("")
        log("Wine is ready. Close this; the main button shows the next step.")
    }

    // MARK: - Step 1: Rosetta

    private static func ensureRosetta(log: @escaping @Sendable (String) -> Void) async throws {
        // The honest test is whether an x86_64 binary actually runs, not whether some file exists.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        probe.arguments = ["-x86_64", "/usr/bin/true"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        if probe.terminationStatus == 0 {
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

    private static func assemble(template: URL, engine: URL,
                                 log: @escaping @Sendable (String) -> Void) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("ffxi-on-mac-staging",
                                                                   isDirectory: true)
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

    private static func bootPrefix(log: @escaping @Sendable (String) -> Void) async throws {
        let i = install
        if FileManager.default.fileExists(atPath: i.driveC.path) {
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
        // wine writes its first-run chatter to stderr; it is noise unless it fails.
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard FileManager.default.fileExists(atPath: i.driveC.path) else {
            throw Err("Wine could not create its Windows drive:\n"
                      + text.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        log("the Windows drive is ready")
    }

    // MARK: - Installing the game into it

    /// Runs a Windows installer (the server's own) inside the prefix. The user picks the file;
    /// we never fetch game data ourselves.
    static func runInstaller(_ exe: URL, log: @escaping @Sendable (String) -> Void) throws {
        let i = install
        guard isBuilt else { throw Err("Wine is not set up yet.") }
        log("running \(exe.lastPathComponent) inside the prefix…")
        let p = Process()
        p.executableURL = i.wine
        p.arguments = [exe.path]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = i.prefix.path
        p.environment = env
        try p.run()
        log("The installer is open. Follow its own steps; this window will notice when it "
            + "finishes and the game files appear.")
    }

    struct Err: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
