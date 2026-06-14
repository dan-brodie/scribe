// SPDX-License-Identifier: MIT

import Foundation

/// Renders and writes the human-facing meeting artifacts (`transcript.txt`,
/// later `actions.json`). Writes are atomic (temp file + rename) so a crash
/// never leaves a half-written file, and reassignment can re-render both files
/// without re-running the pipeline.
struct ArtifactWriter {
    let meetingDir: URL

    static let linesName = "transcript-lines.json"
    static let transcriptName = "transcript.txt"
    static let actionsName = "actions.json"
    static let notesName = "notes.md"

    private var linesURL: URL { meetingDir.appendingPathComponent(Self.linesName) }
    private var transcriptURL: URL { meetingDir.appendingPathComponent(Self.transcriptName) }
    private var actionsURL: URL { meetingDir.appendingPathComponent(Self.actionsName) }
    private var notesURL: URL { meetingDir.appendingPathComponent(Self.notesName) }

    // MARK: - Speaker-labelled lines (re-render source)

    func writeLines(_ lines: [SpeakerLine]) throws {
        let data = try JSONEncoder().encode(lines)
        try atomicWrite(data, to: linesURL)
    }

    func loadLines() -> [SpeakerLine]? {
        guard let data = try? Data(contentsOf: linesURL) else { return nil }
        return try? JSONDecoder().decode([SpeakerLine].self, from: data)
    }

    /// The rendered `transcript.txt`, used as LLM input for summarization.
    func loadTranscriptText() -> String? {
        try? String(contentsOf: transcriptURL, encoding: .utf8)
    }

    // MARK: - Summarization artifacts

    /// Write `actions.json` — the structured action items (`source_quote` and
    /// `done` included), pretty-printed for greppability.
    func writeActions(_ actions: [ExtractedAction]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(try encoder.encode(actions), to: actionsURL)
    }

    /// Write the human-facing `notes.md` (summary + decisions + actions).
    func writeNotes(_ text: String) throws {
        try atomicWrite(Data(text.utf8), to: notesURL)
    }

    // MARK: - Rendering

    /// Render labelled lines to plain text, resolving each label to a display
    /// name. Consecutive lines from one speaker are grouped under one header.
    static func render(lines: [SpeakerLine], displayName: (String) -> String) -> String {
        var output: [String] = []
        var lastLabel: String?
        for line in lines {
            if line.speakerLabel != lastLabel {
                output.append("\n\(displayName(line.speakerLabel)):")
                lastLabel = line.speakerLabel
            }
            output.append(line.text)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Write `transcript.txt` from the supplied lines.
    func writeTranscript(lines: [SpeakerLine], displayName: (String) -> String) throws {
        let text = Self.render(lines: lines, displayName: displayName)
        try atomicWrite(Data(text.utf8), to: transcriptURL)
    }

    /// Re-render `transcript.txt` (and `actions.json` if present) after a
    /// reassignment. `ownerRename` maps old owner display names to new ones.
    func rewriteAfterReassignment(displayName: (String) -> String, ownerRename: [String: String] = [:]) throws {
        guard let lines = loadLines() else { return }
        try writeTranscript(lines: lines, displayName: displayName)

        guard !ownerRename.isEmpty,
              let data = try? Data(contentsOf: actionsURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return }

        for index in json.indices {
            if let owner = json[index]["owner"] as? String, let renamed = ownerRename[owner] {
                json[index]["owner"] = renamed
            }
        }
        let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(updated, to: actionsURL)
    }

    // MARK: - Atomic write

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        let temp = meetingDir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        // Replace destination in one rename.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
