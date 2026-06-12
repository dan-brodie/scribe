// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

final class ASREngineTests: XCTestCase {
    // MARK: - Segment building from token timings

    private func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval, conf: Float = 0.9) -> TranscriptBuilder.Token {
        TranscriptBuilder.Token(text: text, start: start, end: end, confidence: conf)
    }

    func testSegmentsJoinSentencePieceTokens() {
        // "▁Hello ▁world" → "Hello world"
        let tokens = [token("\u{2581}Hello", 0, 0.4), token("\u{2581}world", 0.4, 0.8)]
        let segments = TranscriptBuilder.segments(from: tokens, channel: .mic)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "Hello world")
        XCTAssertEqual(segments.first?.channel, .mic)
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.first?.end, 0.8)
    }

    func testSegmentsSplitOnSilentGap() {
        let tokens = [
            token("\u{2581}one", 0, 0.3),
            token("\u{2581}two", 0.3, 0.6),
            // 1.0s gap → new segment
            token("\u{2581}three", 1.6, 2.0),
        ]
        let segments = TranscriptBuilder.segments(from: tokens, channel: .system, gapThreshold: 0.6)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "one two")
        XCTAssertEqual(segments[1].text, "three")
    }

    func testSegmentConfidenceIsAveraged() {
        let tokens = [token("\u{2581}a", 0, 0.1, conf: 0.6), token("\u{2581}b", 0.1, 0.2, conf: 1.0)]
        let segments = TranscriptBuilder.segments(from: tokens, channel: .mic)
        XCTAssertEqual(segments.first?.confidence ?? 0, 0.8, accuracy: 1e-6)
    }

    func testEmptyTokensProduceNoSegments() {
        XCTAssertTrue(TranscriptBuilder.segments(from: [], channel: .mic).isEmpty)
    }

    // MARK: - Timeline merge

    func testMergeSortsByStartMicFirstOnTie() {
        let mic = [
            TranscriptSegment(channel: .mic, text: "m0", start: 0, end: 1, confidence: 1),
            TranscriptSegment(channel: .mic, text: "m2", start: 2, end: 3, confidence: 1),
        ]
        let system = [
            TranscriptSegment(channel: .system, text: "s0", start: 0, end: 1, confidence: 1),
            TranscriptSegment(channel: .system, text: "s1", start: 1, end: 2, confidence: 1),
        ]
        let merged = TranscriptBuilder.merge(mic: mic, system: system)
        XCTAssertEqual(merged.map(\.text), ["m0", "s0", "s1", "m2"])
    }

    // MARK: - Transcript serialization

    func testTranscriptRoundTripsThroughJSON() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(channel: .mic, text: "hi", start: 0, end: 1, confidence: 0.9)],
            rtfx: 7.5,
            warnings: [.lowConfidence]
        )
        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(decoded.plainText, "[mic] hi")
    }

    // MARK: - WER

    func testWERIdenticalIsZero() {
        XCTAssertEqual(WER.compute(reference: "the quick brown fox", hypothesis: "the quick brown fox"), 0)
    }

    func testWERIgnoresCaseAndPunctuation() {
        XCTAssertEqual(WER.compute(reference: "Hello, world.", hypothesis: "hello world"), 0)
    }

    func testWERCountsEdits() {
        // 1 substitution out of 4 reference words = 0.25
        XCTAssertEqual(WER.compute(reference: "a b c d", hypothesis: "a x c d"), 0.25, accuracy: 1e-9)
        // 1 deletion out of 4 = 0.25
        XCTAssertEqual(WER.compute(reference: "a b c d", hypothesis: "a b c"), 0.25, accuracy: 1e-9)
        // 1 insertion out of 4 = 0.25
        XCTAssertEqual(WER.compute(reference: "a b c d", hypothesis: "a b c d e"), 0.25, accuracy: 1e-9)
    }

    func testWEREmptyReference() {
        XCTAssertEqual(WER.compute(reference: "", hypothesis: ""), 0)
        XCTAssertEqual(WER.compute(reference: "", hypothesis: "extra"), 1)
    }

    // MARK: - Checksum

    func testChecksumIsStableAndDetectsChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-cksum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("model.bin")
        try Data("weights".utf8).write(to: file)

        let first = Checksum.directoryManifest(dir)
        XCTAssertEqual(first.count, 1)
        // Stable across recomputation.
        XCTAssertEqual(Checksum.directoryManifest(dir), first)

        // Mutation changes the digest (corruption detection).
        try Data("tampered".utf8).write(to: file)
        XCTAssertNotEqual(Checksum.directoryManifest(dir), first)
    }

    func testChecksumKnownVector() {
        // SHA-256("abc")
        XCTAssertEqual(
            Checksum.sha256(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - Integration (requires fixture + model download)

    /// Full pipeline: a real speech WAV → transcript, WER < 20%, RTFx ≥ 5×.
    /// Skipped unless `Tests/Fixtures/sample-10min.wav` is present (fetch via
    /// `make download-fixtures`); it downloads ~hundreds of MB of models.
    func testFixtureTranscriptionMeetsWERAndRTF() async throws {
        let bundle = Bundle(for: type(of: self))
        guard let wav = bundle.url(forResource: "sample-10min", withExtension: "wav"),
              let referenceURL = bundle.url(forResource: "sample-10min-reference", withExtension: "txt"),
              let reference = try? String(contentsOf: referenceURL, encoding: .utf8)
        else {
            throw XCTSkip("Fixture sample-10min.wav not present — run `make download-fixtures`.")
        }

        let engine = ASREngine()
        let transcript = try await engine.transcribeFile(wav)

        let wer = WER.compute(reference: reference, hypothesis: transcript.fullText)
        XCTAssertLessThan(wer, 0.20, "WER \(wer) exceeds 20%")
        XCTAssertGreaterThanOrEqual(transcript.rtfx, 5, "RTFx \(transcript.rtfx) below 5×")
    }
}
