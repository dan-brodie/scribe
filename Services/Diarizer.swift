// SPDX-License-Identifier: MIT

import FluidAudio
import Foundation

/// Runs FluidAudio's offline diarizer on the system-audio channel and returns a
/// timeline of anonymous speakers with embeddings (ADR-005: the system channel
/// carries everyone except the local user, who is captured cleanly on the mic).
actor Diarizer {
    enum DiarizerError: Error, CustomStringConvertible {
        case noAudio
        var description: String { "no system-audio channel to diarize" }
    }

    private let manager = OfflineDiarizerManager()
    private let audioConverter = AudioConverter(sampleRate: 16_000)
    private var prepared = false
    private let logger = Log.make("Diarizer")

    func prepareModels() async throws {
        guard !prepared else { return }
        try await manager.prepareModels()
        prepared = true
        logger.info("diarizer models ready")
    }

    /// Diarize a system-audio file into labelled segments.
    func diarize(systemURL: URL) async throws -> [DiarizedSegment] {
        guard FileManager.default.fileExists(atPath: systemURL.path) else { throw DiarizerError.noAudio }
        try await prepareModels()

        let samples = try audioConverter.resampleAudioFile(systemURL)
        guard !samples.isEmpty else { return [] }

        let result = try await manager.process(audio: samples)
        let segments = result.segments.map {
            DiarizedSegment(
                speakerLabel: normalize($0.speakerId),
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds),
                embedding: $0.embedding
            )
        }
        logger.info("diarized \(segments.count, privacy: .public) segments, \(self.speakerCount(segments), privacy: .public) speakers")
        return segments
    }

    /// Representative embedding per speaker (mean of their segment embeddings),
    /// for voice enrollment.
    nonisolated func embeddings(from segments: [DiarizedSegment]) -> [String: [Float]] {
        let grouped = Dictionary(grouping: segments.filter { !$0.embedding.isEmpty }, by: \.speakerLabel)
        return grouped.mapValues { VoiceMath.mean($0.map(\.embedding)) }
    }

    private func speakerCount(_ segments: [DiarizedSegment]) -> Int {
        Set(segments.map(\.speakerLabel)).count
    }

    /// Normalize FluidAudio's speaker ids to a stable `SPEAKER_N` form.
    private func normalize(_ speakerId: String) -> String {
        if speakerId.uppercased().hasPrefix("SPEAKER") { return speakerId.uppercased() }
        return "SPEAKER_\(speakerId)"
    }
}
