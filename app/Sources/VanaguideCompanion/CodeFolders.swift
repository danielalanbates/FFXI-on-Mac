// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.

import Foundation

/// The launcher's `CodeFolders` (HorizonXILauncher/CodeFolders.swift), repeated here because two
/// executable targets cannot share a source file. Finds `My Drive/Code` under every Google Drive
/// account mounted in ~/Library/CloudStorage, so no account name is written into the source.
enum CodeFolders {
    static var googleDriveCodeRoots: [URL] {
        let storage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let volumes = try? FileManager.default.contentsOfDirectory(
            at: storage, includingPropertiesForKeys: nil
        ) else { return [] }
        return volumes
            .filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }
            .map { $0.appendingPathComponent("My Drive/Code", isDirectory: true) }
    }
}
