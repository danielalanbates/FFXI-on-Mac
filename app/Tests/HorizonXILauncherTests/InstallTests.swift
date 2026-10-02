import Foundation
import XCTest
@testable import HorizonXILauncher

final class InstallTests: XCTestCase {
    private func fixture() throws -> (root: URL, install: Install, game: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hxi-install-test-\(UUID().uuidString)")
        let wrapper = root.appendingPathComponent("wrapper.app")
        let game = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(
            at: wrapper.appendingPathComponent("Contents/SharedSupport/prefix10/drive_c"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        return (root, Install(wrapper: wrapper, prefixName: "prefix10", gameDirOverride: game), game)
    }

    func testInstallerPrefixIsNotPlayable() {
        XCTAssertTrue(Install.isGamePrefixName("prefix10"))
        XCTAssertTrue(Install.isGamePrefixName("prefix-test"))
        XCTAssertFalse(Install.isGamePrefixName(Install.installerPrefixName))
        XCTAssertFalse(Install.isGamePrefixName("something-else"))
    }

    func testClassicGameLinkIsCreatedAndIdempotent() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var log: [String] = []

        XCTAssertTrue(f.install.ensureClassicGameLink { log.append($0) })
        XCTAssertTrue(f.install.ensureClassicGameLink { log.append($0) })

        let link = f.install.driveC.appendingPathComponent("HorizonXI")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), f.game.path)
        XCTAssertEqual(log.count, 1)
    }

    func testClassicGameLinkReplacesOnlyAnotherSymlink() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let link = f.install.driveC.appendingPathComponent("HorizonXI")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/old/game")

        XCTAssertTrue(f.install.ensureClassicGameLink { _ in })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), f.game.path)
    }

    func testClassicGameLinkPreservesRealDirectory() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let existing = f.install.driveC.appendingPathComponent("HorizonXI")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        var log = ""

        XCTAssertFalse(f.install.ensureClassicGameLink { log = $0 })
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(log.contains("not replacing"))
    }
}
