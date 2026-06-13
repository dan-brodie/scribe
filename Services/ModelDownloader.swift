// SPDX-License-Identifier: MIT

import FluidAudio
import Foundation

/// Downloads and loads the Parakeet ASR models, with progress reporting and
/// SHA-256 integrity validation.
///
/// Integrity uses trust-on-first-use: after the initial download we record a
/// SHA-256 manifest of the model files; on later launches we re-validate
/// against it to catch on-disk corruption. A failed validation (or load) is
/// retried once with a fresh download, then surfaced as an error.
actor ModelDownloader {
    enum ModelError: Error, CustomStringConvertible {
        case checksumMismatch
        case downloadFailed(String)

        var description: String {
            switch self {
            case .checksumMismatch: return "model checksum validation failed after retry"
            case let .downloadFailed(reason): return "model download failed: \(reason)"
            }
        }
    }

    private let version: AsrModelVersion = .v3
    private let logger = Log.make("ModelDownloader")
    private var cached: AsrModels?

    /// Load the models, downloading on first use. `progress` is 0...1 over the
    /// download phase. Validates checksums and retries once on failure.
    func ensureModels(progress: @escaping @Sendable (Double) -> Void) async throws -> AsrModels {
        if let cached { return cached }

        let directory = AsrModels.defaultCacheDirectory(for: version)
        let firstDownload = !AsrModels.modelsExist(at: directory)

        do {
            let models = try await downloadAndLoad(progress: progress)
            if firstDownload {
                writeManifest(for: directory)
            } else if !validate(directory) {
                throw ModelError.checksumMismatch
            }
            cached = models
            return models
        } catch {
            logger.error("model load failed (\(error, privacy: .public)); wiping and retrying once")
            try? FileManager.default.removeItem(at: directory)
            let models = try await downloadAndLoad(progress: progress)
            writeManifest(for: directory)
            cached = models
            return models
        }
    }

    private func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws -> AsrModels {
        do {
            return try await AsrModels.downloadAndLoad(
                version: version,
                progressHandler: { downloadProgress in
                    progress(downloadProgress.fractionCompleted)
                }
            )
        } catch {
            throw ModelError.downloadFailed(String(describing: error))
        }
    }

    // MARK: - Checksum manifest (TOFU)

    private static let manifestName = "model-checksums-v3.json"

    private func manifestURL() -> URL? {
        guard let support = try? Database.defaultURL().deletingLastPathComponent() else { return nil }
        return support.appendingPathComponent(Self.manifestName, isDirectory: false)
    }

    /// Record SHA-256 of every model file (relative path → hex digest).
    private func writeManifest(for directory: URL) {
        guard let manifestURL = manifestURL() else { return }
        let manifest = Checksum.directoryManifest(directory)
        guard !manifest.isEmpty,
              let data = try? JSONEncoder().encode(manifest)
        else { return }
        try? data.write(to: manifestURL)
        logger.info("wrote checksum manifest with \(manifest.count, privacy: .public) entries")
    }

    /// Recompute checksums and compare to the recorded manifest.
    private func validate(_ directory: URL) -> Bool {
        guard let manifestURL = manifestURL(),
              let data = try? Data(contentsOf: manifestURL),
              let expected = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            // No manifest to validate against — record one now (TOFU) and pass.
            writeManifest(for: directory)
            return true
        }
        let actual = Checksum.directoryManifest(directory)
        let matches = actual == expected
        if !matches {
            logger.error("checksum mismatch: \(actual.count, privacy: .public) files vs \(expected.count, privacy: .public) expected")
        }
        return matches
    }
}
