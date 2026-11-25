// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org
import AppKit

/// Phoenix bypasses Runner, so it needs its own window sampling. Save preferences as
/// the window changes; the live client's profile and rendering buffers stay untouched.
@MainActor final class PhoenixWindowMemory {
    static let shared = PhoenixWindowMemory()
    private var task: Task<Void, Never>?
    private var owner: pid_t?
    private var first: WindowMemory.Size?
    private var last: WindowMemory.Size?
    private var initial: GraphicsSettings?
    private var scale = 1

    static func resized(_ initial: GraphicsSettings, first: WindowMemory.Size,
                        last: WindowMemory.Size) -> GraphicsSettings? {
        guard initial.rememberWindowSize else { return nil }
        let width = (initial.width + last.width - first.width) & ~1
        let height = (initial.height + last.height - first.height) & ~1
        guard width >= 640, height >= 480,
              GraphicsSettings.range("0001")?.contains(width) == true,
              GraphicsSettings.range("0002")?.contains(height) == true else { return nil }
        var out = initial
        out.width = width; out.height = height
        return out
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let pids = await Task.detached(priority: .utility) { () -> [pid_t] in
                    let p = Process(); let pipe = Pipe()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                    p.arguments = ["-f", "[p]hoenix-loader.exe"]
                    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                    guard (try? p.run()) != nil else { return [] }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
                }.value
                guard let self else { return }
                if pids.count == 1, let pid = pids.first {
                    if owner != pid {
                        owner = pid; first = nil; last = nil
                        let settings = GraphicsSettings.load(world: "Phoenix XI")
                        let profile = PhoenixGameLaunch.client.appendingPathComponent("config/boot/phoenix-mac.ini")
                        initial = (try? String(contentsOf: profile, encoding: .utf8)).flatMap {
                            GraphicsSettings.parse($0, fallback: settings)
                        } ?? settings
                        let reg = try? String(contentsOf: PhoenixGameLaunch.prefix.appendingPathComponent("user.reg"), encoding: .utf8)
                        scale = reg?.contains("\"RetinaMode\"=\"y\"") == true ? 2 : 1
                    }
                    if let size = WindowMemory.currentSize(pids: pids, scale: scale) {
                        if first == nil { first = size }
                        if last != nil, size != last, let first, let initial,
                           let updated = Self.resized(initial, first: first, last: size) {
                            // Phoenix regenerates its profile from these settings on launch.
                            if GraphicsSettings.shared != nil { updated.saveShared() }
                            else { updated.save(world: "Phoenix XI") }
                        }
                        last = size
                    }
                } else if pids.isEmpty {
                    owner = nil; first = nil; last = nil; initial = nil
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
