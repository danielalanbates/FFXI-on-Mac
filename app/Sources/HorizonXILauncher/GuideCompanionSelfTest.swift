// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// https://batesai.org · help@batesai.org

import Foundation

enum GuideCompanionSelfTest {
    static func run() -> Never {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("guide-choice-\(UUID().uuidString)")
        var checks: [(String, Bool)] = []
        do {
            func app(_ name: String, version: String = "3.10", build: String,
                     minimum: String = "14.0", id: String = "org.batesai.vanaguide-companion",
                     executable: Bool = true) throws -> URL {
                let url = root.appendingPathComponent(name + ".app")
                let binary = url.appendingPathComponent("Contents/MacOS/VanaguideCompanion")
                try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
                let info = ["CFBundleIdentifier": id, "CFBundleExecutable": "VanaguideCompanion",
                            "CFBundleShortVersionString": version, "CFBundleVersion": build,
                            "LSMinimumSystemVersion": minimum]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: url.appendingPathComponent("Contents/Info.plist"))
                if executable {
                    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                }
                return url
            }
            func choose(_ urls: [URL]) -> URL? { Guide.companionURL(in: urls, osVersion: "27.2") }
            let embedded = try app("embedded", build: "96")
            let standalone = try app("standalone", build: "98")
            checks.append(("newer standalone wins over embedded", choose([embedded, standalone]) == standalone))
            checks.append(("candidate order cannot downgrade a newer build", choose([standalone, embedded]) == standalone))
            let equal = try app("equal", build: "98")
            checks.append(("equal builds keep embedded-first order", choose([standalone, equal]) == standalone))
            let release = try app("release", version: "3.11", build: "1")
            checks.append(("version takes priority over build number", choose([standalone, release]) == release))
            let future = try app("future", build: "999", minimum: "28.0")
            let broken = try app("broken", build: "999", executable: false)
            let other = try app("other", build: "999", id: "org.example.other")
            let invalid = try app("invalid", version: "not-a-version", build: "999")
            checks.append(("incompatible, incomplete and unrelated copies are skipped",
                           choose([future, broken, other, invalid, embedded]) == embedded))
            checks.append(("no usable copy returns nil", choose([future, broken, other, invalid]) == nil))
            // Swap metadata at the same path, just like a standalone update while the launcher runs.
            _ = try app("embedded", build: "100")
            checks.append(("replacement metadata is read without a stale Bundle cache",
                           choose([embedded, standalone]) == embedded))
        } catch {
            print("FAIL: fixture error: \(error.localizedDescription)")
            checks.append(("fixture setup", false))
        }
        try? fm.removeItem(at: root)
        for (name, passed) in checks { print("  \(passed ? "ok" : "FAIL") \(name)") }
        let failures = checks.filter { !$0.1 }.count
        print(failures == 0 ? "all companion choice checks passed" : "\(failures) checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
