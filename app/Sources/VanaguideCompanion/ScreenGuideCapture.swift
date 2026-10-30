// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

import AppKit
import ScreenCaptureKit
import Vision

struct ChatCrop: Equatable {
    /// Percentages measured from the selected window's top left, independent of display scale.
    var left = 0.0
    var top = 65.0
    var width = 100.0
    var height = 35.0

    var valid: Bool {
        [left, top, width, height].allSatisfy { $0.isFinite }
            && left >= 0 && top >= 0 && width >= 5 && height >= 5
            && left + width <= 100 && top + height <= 100
    }

    func rect(width pixelsWide: Int, height pixelsHigh: Int) -> CGRect? {
        guard valid, pixelsWide > 0, pixelsHigh > 0 else { return nil }
        return CGRect(x: Double(pixelsWide) * left / 100, y: Double(pixelsHigh) * top / 100,
                      width: Double(pixelsWide) * width / 100, height: Double(pixelsHigh) * height / 100)
            .integral.intersection(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
    }
}

struct CaptureWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let owner: String
    var label: String { "\(title) · \(owner) · \(id)" }
}

enum GameWindowIdentity {
    /// A browser, terminal or editor can have "FFXI" in its title. Require independent OS app
    /// identity as well. Exact allowlists deliberately prefer no match over arbitrary capture.
    /// `gameProcess`: the window's process runs an FFXI loader or client (see `isGameProcess`).
    /// Private servers title the window with the character's name, so the title alone misses it.
    static func matches(title: String, owner: String, bundle: String, executable: String,
                        gameProcess: Bool = false) -> Bool {
        let title = title.lowercased()
        guard gameProcess || title.contains("ffxi") || title.contains("final fantasy xi")
                || title.contains("horizonxi") else {
            return false
        }
        let names: Set<String> = ["wine", "wine64", "wine-preloader", "wine64-preloader",
                                  "pol.exe", "ffxi.exe", "ffximain.exe", "horizon-loader.exe"]
        let bundles: Set<String> = ["org.winehq.wine", "org.winehq.wine64", "net.winehq.wine",
                                    "com.codeweavers.wineloader", "com.codeweavers.crossoverhelper"]
        func basename(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        }
        return names.contains(basename(owner)) || names.contains(basename(executable)) || bundles.contains(bundle.lowercased())
    }

    static let loaders = ["horizon-loader.exe", "xiloader.exe", "gxiloader.exe", "catseye-loader.exe",
                          "pol.exe", "ffximain.exe"]

    /// True when the process's arguments name an FFXI loader or client. The arguments can hold
    /// a login password, so they are only scanned here: never stored, logged or displayed.
    static func isGameProcess(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        let text = String(decoding: buffer.prefix(size).map { $0 == 0 ? 32 : $0 }, as: UTF8.self).lowercased()
        return loaders.contains { text.contains($0) }
    }
}

/// No screenshots, OCR transcripts, selected window IDs or chat are saved to disk or sent over
/// the network. Capture begins only with Start and ends on Stop, window disappearance or error.
@MainActor
final class ScreenGuideCapture: ObservableObject {
    @Published var windows: [CaptureWindow] = []
    @Published var selectedID: CGWindowID?
    @Published var crop = ChatCrop()
    /// Log pages sit mid-screen, not in the chat area: the Getting started steps read it all.
    @Published var fullWindow = false
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var note = ""
    private var timer: Timer?
    private var session = UUID()
    private var target: CaptureWindow?
    private var ocrFailures = 0
    var receivedText: ((String) -> Void)?
    /// Status-box text while a character-name search runs (CharacterDiscovery).
    var receivedStatus: ((String) -> Void)?
    @Published private(set) var discovering = false
    private var discoveryEnds: Date?
    var targetTitle: String? { target?.title }

    /// Read every 2 seconds, status box included, for up to `seconds`; then back to 10.
    func beginDiscovery(seconds: TimeInterval = 30) {
        guard running, !discovering else { return }
        discovering = true
        discoveryEnds = Date().addingTimeInterval(seconds)
        DevTrace.log("discovery", ["seconds": seconds])
        schedule(every: 2)
    }

    func endDiscovery() {
        guard discovering else { return }
        discovering = false
        discoveryEnds = nil
        if running { schedule(every: 10) }
    }

    private func schedule(every seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.capture() }
        }
    }

    func refreshWindows() {
        guard !running, !busy else { return }
        Self.warmUp()
        guard #available(macOS 14.0, *) else { note = "Screenshot mode needs macOS 14 or later."; return }
        // Permission is requested only after this explicit button press; never on app launch.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            note = "Allow Screen Recording for this app, then refresh windows."
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                windows = content.windows.filter(Self.isGameWindow).compactMap { window in
                    guard let owner = window.owningApplication else { return nil }
                    return CaptureWindow(id: window.windowID, pid: owner.processID,
                                         title: window.title ?? "FFXI", owner: owner.applicationName)
                }.sorted { $0.label < $1.label }
                if !windows.contains(where: { $0.id == selectedID }) { selectedID = nil }
                note = windows.isEmpty ? "No visible FFXI game window found." : "Choose the game window and chat area."
            } catch { note = "Could not list game windows. Check Screen Recording permission." }
        }
    }

    static func isGameWindow(_ window: SCWindow) -> Bool {
        guard let owner = window.owningApplication,
              owner.processID != ProcessInfo.processInfo.processIdentifier,
              window.isOnScreen, window.windowLayer == 0,
              window.frame.width >= 320, window.frame.height >= 200 else { return false }
        let bundle = owner.bundleIdentifier.lowercased()
        guard bundle != "org.batesai.horizonxi-on-mac" else { return false }
        let executable = NSRunningApplication(processIdentifier: owner.processID)?.executableURL?.lastPathComponent ?? ""
        return GameWindowIdentity.matches(title: window.title ?? "", owner: owner.applicationName,
                                          bundle: bundle, executable: executable,
                                          gameProcess: GameWindowIdentity.isGameProcess(owner.processID))
    }

    func start() {
        guard !running, !busy, crop.valid,
              let target = windows.first(where: { $0.id == selectedID }) else { return }
        guard #available(macOS 14.0, *) else { note = "Screenshot mode needs macOS 14 or later."; return }
        guard CGPreflightScreenCaptureAccess() else {
            note = "Screen Recording permission is required."
            return
        }
        self.target = target
        session = UUID()
        ocrFailures = 0
        running = true
        UserDefaults.standard.set(true, forKey: "reading.used")
        note = Self.warm ? "Reading the selected chat area every 10 seconds."
                         : "Preparing text recognition (about a minute, once per launch)…"
        // First sample is immediate; subsequent samples never overlap a pending capture/OCR.
        capture()
        schedule(every: 10)
    }

    func stop(note: String = "Screenshot reading stopped.") {
        DevTrace.log("stop", ["note": note])
        timer?.invalidate()
        timer = nil
        discovering = false
        discoveryEnds = nil
        running = false
        target = nil
        session = UUID() // invalidates callbacks from any already-running OCR request
        self.note = note
    }

    private func capture() {
        guard #available(macOS 14.0, *), running, !busy, let target else { return }
        // The name search's 30 s only count once the recognizer is ready.
        if discovering, !Self.warm { discoveryEnds = Date().addingTimeInterval(30) }
        if discovering, let ends = discoveryEnds, Date() > ends { endDiscovery() }
        let readStatus = discovering
        busy = true
        let token = session
        let crop = fullWindow ? ChatCrop(left: 0, top: 0, width: 100, height: 100) : crop
        Task {
            defer { busy = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard session == token, running else { return }
                guard let window = content.windows.first(where: {
                    $0.windowID == target.id && $0.owningApplication?.processID == target.pid
                        && Self.isGameWindow($0)
                }) else { stop(note: "The selected game window changed or closed. Choose it again."); return }
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width)
                config.height = Int(window.frame.height)
                config.showsCursor = false
                config.capturesAudio = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                guard session == token, running else { return }
                guard let rect = crop.rect(width: image.width, height: image.height),
                      let chat = image.cropping(to: rect) else {
                    stop(note: "Choose a valid chat area.")
                    return
                }
                // Vision occasionally fails one request on the Neural Engine and succeeds on the
                // next (seen 2026-10-28). Skip that sample; stop only when it keeps failing.
                let text: String
                do { text = try await Self.recognizeWithTimeout(chat) } catch {
                    guard session == token, running else { return }
                    ocrFailures += 1
                    // macOS compiles the recognizer for the Neural Engine on first use (minutes,
                    // seen 2026-10-28); requests fail or hang meanwhile. Keep trying, say why.
                    note = !Self.warm
                        ? "Preparing text recognition (about a minute, once per launch)…"
                        : (ocrFailures >= 3 ? "Text recognition is not responding; still trying."
                                            : "Skipped one unreadable sample.")
                    return
                }
                ocrFailures = 0
                guard session == token, running else { return }
                receivedText?(text)
                if readStatus, let r = CharacterDiscovery.statusCrop.rect(width: image.width, height: image.height),
                   let box = image.cropping(to: r),
                   let status = try? await Self.recognizeWithTimeout(box) {
                    guard session == token, running else { return }
                    receivedStatus?(status)
                }
            } catch {
                guard session == token else { return }
                stop(note: "Screenshot reading stopped. Check the game window and permission.")
            }
        }
    }

    struct RecognitionTimeout: Error {}
    /// The recognizer's first request in a process loads its model: about 65 s on this Mac
    /// (2026-10-28), then 0.1 s per read. Warm it up before reading starts.
    nonisolated private static let recognition = OCRRecognitionGate()
    nonisolated static var warm: Bool { recognition.isWarm }

    nonisolated static func warmUp() {
        guard let token = recognition.claim(warmUp: true) else { return }
        DispatchQueue.global(qos: .utility).async {
            let t = Date()
            let result = Result { try recognize(sampleImage()) }
            recognition.finish(token, succeeded: (try? result.get()) != nil)
            DevTrace.log("warm", ["seconds": Date().timeIntervalSince(t)])
        }
    }

    /// A few words of black text on white, enough to load detection and recognition.
    nonisolated static func sampleImage() -> CGImage {
        let size = NSSize(width: 320, height: 60)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        ("Port San d'Oria" as NSString).draw(at: NSPoint(x: 10, y: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    /// Gives up after `seconds`; a hung request is left to finish on its own, never stacked.
    /// (A task group would wait for the hung child, so the first result resumes a continuation.)
    nonisolated static func recognizeWithTimeout(_ image: CGImage, seconds: Double = 8) async throws -> String {
        guard let token = recognition.claim() else { throw RecognitionTimeout() }
        let lock = NSLock() // This request's reply arbitration, separate from worker ownership.
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<String, Error>) in
            var resumed = false
            func finish(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                done.resume(with: result)
            }
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try recognize(image) }
                recognition.finish(token, succeeded: (try? result.get()) != nil)
                finish(result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(.failure(RecognitionTimeout())) }
        }
    }

    /// On-device text recognition; lines under 60% confidence are dropped. Vision returns a
    /// chat row as separate pieces when the game spaces them out ("Gulemont" and "It's been…"
    /// with the colon lost, 2026-10-28), so pieces are put back into rows by position.
    nonisolated static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let pieces: [OCRPiece] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.6 else { return nil }
            let r = observation.boundingBox
            return OCRPiece(text: candidate.string, x: r.minX, midY: r.midY, height: r.height, width: r.width)
        }
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        return OCRPiece.rows(pieces, aspect: aspect).joined(separator: "\n")
    }
}

/// One recognized text box, in Vision's normalized coordinates (origin bottom left).
struct OCRPiece {
    let text: String
    let x: CGFloat
    let midY: CGFloat
    let height: CGFloat
    var width: CGFloat = 0

    /// Pieces on the same row (centres within half a line) joined left to right, rows top down.
    /// A row that begins with a lone name gets its speaker separator back: "Name : text".
    static func rows(_ pieces: [OCRPiece], aspect: CGFloat = 1) -> [String] {
        var rows: [[OCRPiece]] = []
        for p in pieces.sorted(by: { $0.midY > $1.midY }) {
            if let i = rows.firstIndex(where: { abs($0[0].midY - p.midY) < max($0[0].height, p.height) * 0.5 }) {
                rows[i].append(p)
            } else {
                rows.append([p])
            }
        }
        return rows.map { row in
            let sorted = row.sorted { $0.x < $1.x }
            let parts = sorted.map(\.text)
            guard parts.count > 1 else { return parts.first ?? "" }
            let first = parts[0].trimmingCharacters(in: .whitespaces)
            // The game's " : " leaves a gap of about a line height; ordinary word spacing is far
            // smaller ("Deleted San d'Oria | quest 6…" must not become a speaker).
            let gap = (sorted[1].x - (sorted[0].x + sorted[0].width)) * aspect
            let lone = gap >= sorted[0].height * 0.8 && sorted[0].width > 0
                && !first.contains(":") && (1...3).contains(first.split(separator: " ").count)
                && first.first?.isUppercase == true
                && first.allSatisfy { $0.isLetter || $0 == " " || $0 == "'" || $0 == "-" }
            return lone ? first + " : " + parts.dropFirst().joined(separator: " ")
                        : parts.joined(separator: " ")
        }
    }
}
