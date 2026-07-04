// SPDX-License-Identifier: MIT

import FluidAudio
import Foundation

/// On-device speech recognition for both captured channels.
///
/// Uses FluidAudio's batch `AsrManager` (Parakeet TDT v3, multilingual). Batch
/// was chosen over streaming for v1: it is simpler and, at ~190× RTF on Apple
/// Silicon, comfortably meets the ≥5× requirement. Streaming (for live
/// captions) is a Phase 7 stretch.
actor ASREngine {
    enum EngineError: Error, CustomStringConvertible {
        case noAudio
        case notPrepared

        var description: String {
            switch self {
            case .noAudio: return "no audio found to transcribe"
            case .notPrepared: return "ASR models are not loaded"
            }
        }
    }

    struct Output: Sendable {
        var transcript: Transcript
        var segmentsURL: URL
    }

    /// Below this average token confidence we flag a possibly-unsupported
    /// language rather than trusting a garbled transcript.
    private let unsupportedConfidenceThreshold: Float = 0.35

    private let downloader = ModelDownloader()
    private let audioConverter = AudioConverter(sampleRate: 16_000)
    private var manager: AsrManager?
    private let logger = Log.make("ASREngine")

    /// Load (downloading on first use) the ASR models. Safe to call repeatedly.
    func prepareModels(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if manager != nil { return }
        let models = try await downloader.ensureModels(progress: progress)
        manager = AsrManager(config: .default, models: models)
        logger.info("ASR models ready")
    }

    /// Transcribe a meeting's mic + system channels, merge them into one
    /// timeline, and write `segments.json` into the recording folder.
    func transcribeMeeting(
        eventID: String,
        recordingsRoot: URL,
        modelProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Output {
        try await prepareModels(progress: modelProgress)
        guard let manager else { throw EngineError.notPrepared }

        let dir = RecordingPaths.directory(root: recordingsRoot, eventID: eventID)
        let mic = try await transcribeChannel(
            url: dir.appendingPathComponent("mic.caf"),
            channel: .mic,
            manager: manager
        )
        let system = try await transcribeChannel(
            url: dir.appendingPathComponent("system.caf"),
            channel: .system,
            manager: manager
        )

        guard mic != nil || system != nil else { throw EngineError.noAudio }

        let merged = TranscriptBuilder.merge(
            mic: mic?.segments ?? [],
            system: system?.segments ?? []
        )
        let results = [mic?.result, system?.result].compactMap { $0 }
        let transcript = Transcript(
            segments: merged,
            rtfx: combinedRTFx(results),
            warnings: languageWarnings(results)
        )

        let url = dir.appendingPathComponent("segments.json")
        try writeJSON(transcript, to: url)
        logger.info("transcribed \(eventID, privacy: .public): \(merged.count, privacy: .public) segments, RTFx \(transcript.rtfx, privacy: .public)")
        return Output(transcript: transcript, segmentsURL: url)
    }

    /// Transcribe a single audio file as one channel — used by the integration
    /// test and any single-source path.
    func transcribeFile(_ url: URL, channel: TranscriptChannel = .mic, modelProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Transcript {
        try await prepareModels(progress: modelProgress)
        guard let manager else { throw EngineError.notPrepared }
        guard let channelResult = try await transcribeChannel(url: url, channel: channel, manager: manager) else {
            throw EngineError.noAudio
        }
        return Transcript(
            segments: channelResult.segments,
            rtfx: combinedRTFx([channelResult.result]),
            warnings: languageWarnings([channelResult.result])
        )
    }

    // MARK: - Per channel

    private struct ChannelResult {
        var segments: [TranscriptSegment]
        var result: ASRResult
    }

    private func transcribeChannel(
        url: URL,
        channel: TranscriptChannel,
        manager: AsrManager
    ) async throws -> ChannelResult? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let samples = try audioConverter.resampleAudioFile(url)
        guard !samples.isEmpty else { return nil }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)

        let tokens = (result.tokenTimings ?? []).map {
            TranscriptBuilder.Token(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        }
        let segments = TranscriptBuilder.segments(from: tokens, channel: channel)
        return ChannelResult(segments: segments, result: result)
    }

    // MARK: - Metrics & warnings

    private func combinedRTFx(_ results: [ASRResult]) -> Float {
        let duration = results.map(\.duration).reduce(0, +)
        let processing = results.map(\.processingTime).reduce(0, +)
        guard processing > 0 else { return 0 }
        return Float(duration / processing)
    }

    private func languageWarnings(_ results: [ASRResult]) -> [TranscriptWarning] {
        guard !results.isEmpty else { return [] }
        let weightedConfidence = results
            .map { $0.confidence * Float($0.duration) }
            .reduce(0, +)
        let totalDuration = Float(results.map(\.duration).reduce(0, +))
        guard totalDuration > 0 else { return [] }
        let average = weightedConfidence / totalDuration

        if average < unsupportedConfidenceThreshold {
            return [.possiblyUnsupportedLanguage, .lowConfidence]
        }
        return []
    }

    private func writeJSON(_ transcript: Transcript, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(transcript)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
