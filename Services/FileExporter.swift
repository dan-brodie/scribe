// SPDX-License-Identifier: MIT

import Foundation

/// Copies the final meeting artifacts from the per-meeting working directory
/// into the user-facing output folder:
///
/// ```
/// <output folder>/<YYYY-MM-DD> <title>/
///   notes.txt
///   transcript.txt
///   transcript.json
///   actions.json
/// ```
///
/// Every file is written atomically (temp + rename) so a crash — or a re-export
/// triggered mid-write by a speaker reassignment — never leaves a half-written
/// file. Re-exporting reuses the meeting's existing directory; a fresh export
/// whose name collides with another meeting is suffixed ` (2)`, ` (3)`, ….
struct FileExporter {
    let outputRoot: URL

    enum ExportError: Error, CustomStringConvertible {
        case noArtifacts(workingDir: URL)

        var description: String {
            switch self {
            case let .noArtifacts(dir):
                return "no artifacts found to export in \(dir.path)"
            }
        }
    }

    /// Source filename (in the working dir) → destination filename (in the
    /// export dir). `transcript-lines.json` is the structured re-render source;
    /// it surfaces to the user as `transcript.json`.
    private static let artifacts: [(source: String, destination: String)] = [
        (ArtifactWriter.notesName, "notes.txt"),
        (ArtifactWriter.transcriptName, "transcript.txt"),
        (ArtifactWriter.linesName, "transcript.json"),
        (ArtifactWriter.actionsName, "actions.json"),
    ]

    /// Export a meeting's artifacts and return the directory they were written
    /// to (also the "Reveal in Finder" target).
    ///
    /// - Parameters:
    ///   - title: meeting title (sanitized for the folder name)
    ///   - date:  meeting start (its date prefixes the folder name)
    ///   - workingDir: per-meeting recordings dir holding the rendered artifacts
    ///   - existingExportDir: the dir a prior export used; reused verbatim so
    ///     reassignment re-exports overwrite in place instead of forking a copy
    @discardableResult
    func export(
        title: String,
        date: Date,
        workingDir: URL,
        existingExportDir: URL? = nil
    ) throws -> URL {
        let dir = existingExportDir ?? uniqueDirectory(title: title, date: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var copiedAny = false
        for (source, destination) in Self.artifacts {
            let sourceURL = workingDir.appendingPathComponent(source)
            guard let data = try? Data(contentsOf: sourceURL) else { continue }
            try atomicWrite(data, to: dir.appendingPathComponent(destination))
            copiedAny = true
        }
        guard copiedAny else { throw ExportError.noArtifacts(workingDir: workingDir) }
        return dir
    }

    // MARK: - Naming

    /// `<YYYY-MM-DD> <sanitized title>` (or just the date when the title is empty).
    func directoryName(title: String, date: Date) -> String {
        let datePart = Self.dateFormatter.string(from: date)
        let safeTitle = Self.sanitize(title)
        return safeTitle.isEmpty ? datePart : "\(datePart) \(safeTitle)"
    }

    private func uniqueDirectory(title: String, date: Date) -> URL {
        let base = directoryName(title: title, date: date)
        var candidate = outputRoot.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputRoot.appendingPathComponent("\(base) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    /// Remove path-hostile characters (`/`, `:`, and other reserved/control
    /// characters), collapse runs of whitespace, and trim.
    static func sanitize(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let pieces = title.components(separatedBy: illegal).joined(separator: " ")
        return pieces.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Atomic write

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
