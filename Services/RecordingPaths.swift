// SPDX-License-Identifier: MIT

import Foundation

/// Maps meeting event identifiers to on-disk recording locations.
///
/// Calendar event identifiers derive from the iCalendar `UID`, which the
/// meeting's *inviter* controls — they can contain `/`, `..`, or any other
/// path-hostile characters. Every recording path therefore goes through
/// `directoryName(for:)`, which keeps a readable sanitized prefix and appends
/// a short SHA-256 digest of the raw identifier, so hostile or colliding IDs
/// still map to unique directories strictly inside the recordings root.
enum RecordingPaths {
    /// Characters kept verbatim in a directory name; everything else becomes `_`.
    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    /// A filesystem-safe, collision-resistant directory name for an event ID.
    /// Stable: the same ID always maps to the same name.
    static func directoryName(for eventID: String) -> String {
        let digest = String(Checksum.sha256(of: Data(eventID.utf8)).prefix(12))
        let sanitized = String(eventID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let prefix = String(sanitized.prefix(40))
        return prefix.isEmpty ? digest : "\(prefix)-\(digest)"
    }

    /// The recording directory for an event, always directly under `root`.
    ///
    /// Recordings made before v0.2.0 used the raw ID as the directory name;
    /// when no sanitized directory exists yet but such a legacy directory does
    /// — and the raw ID is provably a single, traversal-free path component —
    /// the legacy directory is reused so existing meetings keep working.
    static func directory(root: URL, eventID: String) -> URL {
        let dir = root.appendingPathComponent(directoryName(for: eventID), isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), isSafeLegacyComponent(eventID) {
            let legacy = root.appendingPathComponent(eventID, isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path) {
                return legacy
            }
        }
        return dir
    }

    /// Whether a raw ID can be trusted as one path component: nothing that a
    /// path resolver could treat as a separator or parent reference.
    private static func isSafeLegacyComponent(_ id: String) -> Bool {
        !id.isEmpty
            && !id.contains("/")
            && !id.contains("\\")
            && !id.contains("\u{0}")
            && id != "."
            && id != ".."
    }
}
