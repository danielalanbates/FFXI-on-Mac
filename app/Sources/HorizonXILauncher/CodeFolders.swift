import Foundation

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
