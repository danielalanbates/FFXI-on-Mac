// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
// Developer test hooks, off unless launched with flags (local-server testing only):
//   --trace <file>          JSON lines of what Server-Safe saw and did, including OCR text
//   --auto-read <title>     pick the game window whose title contains <title> and start reading
//   --crop l,t,w,h          chat area for --auto-read (percent)
//   --ignore-title          find the character from the status box even if the title has it
//   --dev-autotest          Developer Mode: assign the newest heard speaker to the open quest, export
// Normal launches never write the trace or start reading by themselves.

import Foundation

enum DevTrace {
    static let args = CommandLine.arguments
    static func value(_ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    static let path: String? = value("--trace")
    private static let lock = NSLock()

    static func log(_ event: String, _ fields: [String: Any] = [:]) {
        guard let path else { return }
        var body = fields
        body["event"] = event
        body["t"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        lock.lock(); defer { lock.unlock() }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static var crop: ChatCrop? {
        guard let v = value("--crop") else { return nil }
        let n = v.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { return nil }
        return ChatCrop(left: n[0], top: n[1], width: n[2], height: n[3])
    }
}
