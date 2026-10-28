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
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var note = ""
    private var timer: Timer?
    private var session = UUID()
    private var target: CaptureWindow?
    private var ocrFailures = 0
    var receivedText: ((String) -> Void)?

    func refreshWindows() {
        guard !running, !busy else { return }
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
        note = "Reading the selected chat area every 10 seconds."
        // First sample is immediate; subsequent samples never overlap a pending capture/OCR.
        capture()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.capture() }
        }
    }

    func stop(note: String = "Screenshot reading stopped.") {
        timer?.invalidate()
        timer = nil
        running = false
        target = nil
        session = UUID() // invalidates callbacks from any already-running OCR request
        self.note = note
    }

    private func capture() {
        guard #available(macOS 14.0, *), running, !busy, let target else { return }
        busy = true
        let token = session
        let crop = crop
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
                let ocr = Task.detached(priority: .utility) { () throws -> String in
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: chat, options: [:]).perform([request])
                    return (request.results ?? []).compactMap { observation -> String? in
                        guard let candidate = observation.topCandidates(1).first,
                              candidate.confidence >= 0.6 else { return nil }
                        return candidate.string
                    }.joined(separator: "\n")
                }
                let text: String
                do { text = try await ocr.value } catch {
                    guard session == token, running else { return }
                    ocrFailures += 1
                    if ocrFailures >= 3 { stop(note: "Text recognition keeps failing. Try Start again.") }
                    else { note = "Skipped one unreadable sample." }
                    return
                }
                ocrFailures = 0
                guard session == token, running else { return }
                receivedText?(text)
            } catch {
                guard session == token else { return }
                stop(note: "Screenshot reading stopped. Check the game window and permission.")
            }
        }
    }
}
