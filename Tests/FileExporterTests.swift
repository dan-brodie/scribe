// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

final class FileExporterTests: XCTestCase {
    private var root: URL!
    private var workingDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-export-tests-\(UUID().uuidString)", isDirectory: true)
        workingDir = root.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seedWorkingDir(
        notes: String = "notes",
        transcript: String = "transcript",
        lines: String = "[]",
        actions: String = "[]"
    ) throws {
        try notes.write(to: workingDir.appendingPathComponent(ArtifactWriter.notesName), atomically: true, encoding: .utf8)
        try transcript.write(to: workingDir.appendingPathComponent(ArtifactWriter.transcriptName), atomically: true, encoding: .utf8)
        try lines.write(to: workingDir.appendingPathComponent(ArtifactWriter.linesName), atomically: true, encoding: .utf8)
        try actions.write(to: workingDir.appendingPathComponent(ArtifactWriter.actionsName), atomically: true, encoding: .utf8)
    }

    private func makeExporter() -> FileExporter {
        FileExporter(outputRoot: root.appendingPathComponent("out", isDirectory: true))
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    // MARK: - Naming

    func testDirectoryNameUsesDatePrefixAndTitle() {
        let exporter = makeExporter()
        let name = exporter.directoryName(title: "Weekly Sync", date: date("2026-06-13T15:00:00Z"))
        XCTAssertEqual(name, "2026-06-13 Weekly Sync")
    }

    func testSanitizeStripsPathHostileCharacters() {
        XCTAssertEqual(FileExporter.sanitize("Q3 Plan: Roadmap / Budget"), "Q3 Plan Roadmap Budget")
        XCTAssertEqual(FileExporter.sanitize("  spaced   out \n title "), "spaced out title")
        XCTAssertEqual(FileExporter.sanitize("///"), "")
    }

    func testEmptyTitleFallsBackToDateOnly() {
        let exporter = makeExporter()
        XCTAssertEqual(exporter.directoryName(title: "///", date: date("2026-06-13T00:00:00Z")), "2026-06-13")
    }

    // MARK: - Export

    func testExportWritesAllFourArtifacts() throws {
        try seedWorkingDir(notes: "the notes", transcript: "the transcript", lines: "[1]", actions: "[2]")
        let exporter = makeExporter()

        let dir = try exporter.export(title: "Standup", date: date("2026-06-13T09:00:00Z"), workingDir: workingDir)

        XCTAssertEqual(dir.lastPathComponent, "2026-06-13 Standup")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8), "the notes")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8), "the transcript")
        // transcript-lines.json surfaces to the user as transcript.json.
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("transcript.json"), encoding: .utf8), "[1]")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("actions.json"), encoding: .utf8), "[2]")
    }

    func testExportThrowsWhenNoArtifactsPresent() {
        let exporter = makeExporter()
        XCTAssertThrowsError(try exporter.export(title: "Empty", date: Date(), workingDir: workingDir)) { error in
            guard case FileExporter.ExportError.noArtifacts = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCollidingTitlesGetSuffixed() throws {
        try seedWorkingDir()
        let exporter = makeExporter()
        let day = date("2026-06-13T10:00:00Z")

        let first = try exporter.export(title: "Sync", date: day, workingDir: workingDir)
        let second = try exporter.export(title: "Sync", date: day, workingDir: workingDir)
        let third = try exporter.export(title: "Sync", date: day, workingDir: workingDir)

        XCTAssertEqual(first.lastPathComponent, "2026-06-13 Sync")
        XCTAssertEqual(second.lastPathComponent, "2026-06-13 Sync (2)")
        XCTAssertEqual(third.lastPathComponent, "2026-06-13 Sync (3)")
    }

    func testReExportReusesExistingDirectory() throws {
        try seedWorkingDir(notes: "v1")
        let exporter = makeExporter()
        let day = date("2026-06-13T10:00:00Z")

        let first = try exporter.export(title: "Sync", date: day, workingDir: workingDir)

        // Re-render with corrected content and re-export into the same dir.
        try seedWorkingDir(notes: "v2 corrected")
        let again = try exporter.export(title: "Sync", date: day, workingDir: workingDir, existingExportDir: first)

        XCTAssertEqual(first, again)
        XCTAssertEqual(try String(contentsOf: again.appendingPathComponent("notes.md"), encoding: .utf8), "v2 corrected")
        // No suffixed sibling was created.
        let outRoot = root.appendingPathComponent("out", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: outRoot.path)
        XCTAssertEqual(entries.sorted(), ["2026-06-13 Sync"])
    }
}
