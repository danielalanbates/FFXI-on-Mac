import Foundation

enum AddonInstaller {
    static func replaceDirectory(at destination: URL, with source: URL,
                                 fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let suffix = UUID().uuidString
        let staged = parent.appendingPathComponent(".\(destination.lastPathComponent).installing-\(suffix)")
        let backup = parent.appendingPathComponent(".\(destination.lastPathComponent).previous-\(suffix)")
        defer { try? fileManager.removeItem(at: staged) }

        try fileManager.copyItem(at: source, to: staged)

        let hadPrevious = fileManager.fileExists(atPath: destination.path)
        if hadPrevious { try fileManager.moveItem(at: destination, to: backup) }

        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            if hadPrevious { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }

        if hadPrevious { try? fileManager.removeItem(at: backup) }
    }
}
