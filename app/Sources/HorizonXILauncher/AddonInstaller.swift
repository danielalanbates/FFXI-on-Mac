import Foundation

enum AddonInstaller {
    /// `preserving` lists paths inside the old install (e.g. "data/nav") that the source does
    /// not ship and must survive the swap: Vanaguide's navigation grids are generated on the
    /// player's machine from LandSandBoat's navmeshes and can never be bundled, so replacing
    /// the folder wholesale on every Play used to delete them.
    static func replaceDirectory(at destination: URL, with source: URL,
                                 preserving: [String] = [],
                                 fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let suffix = UUID().uuidString
        let staged = parent.appendingPathComponent(".\(destination.lastPathComponent).installing-\(suffix)")
        let backup = parent.appendingPathComponent(".\(destination.lastPathComponent).previous-\(suffix)")
        defer { try? fileManager.removeItem(at: staged) }

        try fileManager.copyItem(at: source, to: staged)

        let hadPrevious = fileManager.fileExists(atPath: destination.path)
        for rel in preserving where hadPrevious {
            let old = destination.appendingPathComponent(rel)
            let new = staged.appendingPathComponent(rel)
            guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else { continue }
            try? fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.copyItem(at: old, to: new)
        }
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
