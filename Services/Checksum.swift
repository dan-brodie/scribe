// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// SHA-256 helpers for model-integrity validation.
enum Checksum {
    /// Streaming SHA-256 of a file's contents (chunked to bound memory), as a
    /// lowercase hex string. `nil` if the file can't be read.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// SHA-256 of in-memory data.
    static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Map of relative path → SHA-256 for every regular file under `directory`.
    static func directoryManifest(_ directory: URL) -> [String: String] {
        var result: [String: String] = [:]
        let basePath = directory.path
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return result }

        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular, let digest = sha256(of: url) else { continue }
            let relative = url.path.hasPrefix(basePath)
                ? String(url.path.dropFirst(basePath.count))
                : url.lastPathComponent
            result[relative] = digest
        }
        return result
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
