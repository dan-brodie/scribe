// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

/// Event IDs derive from the iCalendar `UID`, which a meeting's inviter
/// controls — these tests pin the guarantee that no ID can escape the
/// recordings root (the H2 path-traversal fix).
final class RecordingPathsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/scribe-recordings", isDirectory: true)

    func testHostileEventIDStaysInsideRoot() {
        let hostile = "../../../../Users/victim/.ssh"
        let dir = RecordingPaths.directory(root: root, eventID: hostile)
        XCTAssertEqual(
            dir.standardizedFileURL.deletingLastPathComponent().path,
            root.standardizedFileURL.path,
            "hostile IDs must map to a directory directly under the root"
        )
    }

    func testDirectoryNameNeverContainsSeparatorsOrTraversal() {
        for hostile in ["a/b/c", "..", "../x", "a\\b", "/etc/passwd", "a:b", "\u{0}null"] {
            let name = RecordingPaths.directoryName(for: hostile)
            XCTAssertFalse(name.contains("/"), "separator survived for \(hostile)")
            XCTAssertFalse(name.contains(".."), "traversal survived for \(hostile)")
            XCTAssertFalse(name.isEmpty, "empty name for \(hostile)")
        }
    }

    func testDistinctIDsMapToDistinctDirectories() {
        // Sanitization alone would collide these; the digest keeps them apart.
        XCTAssertNotEqual(
            RecordingPaths.directoryName(for: "a/b"),
            RecordingPaths.directoryName(for: "a_b")
        )
    }

    func testMappingIsStable() {
        XCTAssertEqual(
            RecordingPaths.directoryName(for: "evt-123#1700000000"),
            RecordingPaths.directoryName(for: "evt-123#1700000000")
        )
    }

    func testPlainIDKeepsReadablePrefix() {
        let name = RecordingPaths.directoryName(for: "manual-1700000000")
        XCTAssertTrue(name.hasPrefix("manual-1700000000-"), "got \(name)")
    }

    func testLegacyDirectoryIsReusedWhenPresent() throws {
        // Pre-v0.2.0 recordings used the raw ID as the directory name.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let legacy = tempRoot.appendingPathComponent("old-event-id", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let dir = RecordingPaths.directory(root: tempRoot, eventID: "old-event-id")
        XCTAssertEqual(dir.path, legacy.path)
    }

    func testLegacyFallbackNeverAppliesToHostileIDs() throws {
        // Even if an attacker-controlled path exists on disk, a traversal ID
        // must not be reused as a legacy component.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let outside = tempRoot.deletingLastPathComponent()
            .appendingPathComponent("scribe-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let hostile = "../\(outside.lastPathComponent)"
        let dir = RecordingPaths.directory(root: tempRoot, eventID: hostile)
        XCTAssertEqual(
            dir.standardizedFileURL.deletingLastPathComponent().path,
            tempRoot.standardizedFileURL.path
        )
    }
}
