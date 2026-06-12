// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// Vector math for voice-embedding comparison.
enum VoiceMath {
    /// Cosine similarity of two equal-length vectors (0 if mismatched/empty).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = (normA.squareRoot() * normB.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }

    /// Average of several embeddings (for incremental enrollment).
    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first, !first.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        var count = 0
        for vector in vectors where vector.count == first.count {
            for i in vector.indices { sum[i] += vector[i] }
            count += 1
        }
        guard count > 0 else { return [] }
        return sum.map { $0 / Float(count) }
    }
}

/// Encode/decode `[Float]` embeddings to the `voiceProfiles.embeddingBlob` BLOB.
enum EmbeddingCodec {
    static func encode(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: count))
        }
    }
}

/// Persistent voice enrollment: stores per-person embeddings and matches
/// diarized speakers against them on later meetings. Off by default behind the
/// "Remember voices" toggle (ADR-005); all data is deletable.
actor VoiceEnrollmentStore {
    private let database: Database
    private(set) var isEnabled: Bool
    private let logger = Log.make("VoiceEnrollmentStore")

    init(database: Database, enabled: Bool) {
        self.database = database
        self.isEnabled = enabled
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Record (or update by averaging) an embedding for a confirmed person.
    func enroll(email: String, name: String, embedding: [Float]) async {
        guard isEnabled, !embedding.isEmpty else { return }
        do {
            try await database.upsertVoiceProfile(email: email, name: name, embedding: embedding)
            logger.info("enrolled voice for \(email, privacy: .public)")
        } catch {
            logger.error("voice enrollment failed: \(error, privacy: .public)")
        }
    }

    /// Best matching person for an embedding above `threshold`, else nil.
    func bestMatch(for embedding: [Float], threshold: Float) async -> (email: String, score: Float)? {
        guard isEnabled, !embedding.isEmpty else { return nil }
        let profiles = (try? await database.allVoiceProfiles()) ?? []
        var best: (email: String, score: Float)?
        for profile in profiles {
            let score = VoiceMath.cosine(embedding, EmbeddingCodec.decode(profile.embeddingBlob))
            if score >= threshold, score > (best?.score ?? -1) {
                best = (profile.personEmail, score)
            }
        }
        return best
    }

    func deleteAll() async {
        try? await database.deleteAllVoiceProfiles()
        logger.info("deleted all voice profiles")
    }
}
