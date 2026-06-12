// SPDX-License-Identifier: MIT

import AVFoundation
import XCTest
@testable import Scribe

final class CaptureServiceTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    // MARK: - Mock audio

    /// 16 kHz mono samples: silence (zeros) or a full-scale tone (speech-like).
    private func samples(speech: Bool, count: Int = 4096) -> [Float] {
        guard speech else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { sin(Float($0) * 0.1) }
    }

    // MARK: - Energy detection (mock audio → speech/silence)

    func testEnergyDetectorClassifiesMockAudio() async {
        let detector = EnergySilenceDetector()
        let speech = await detector.containsSpeech(samples(speech: true))
        let silence = await detector.containsSpeech(samples(speech: false))
        XCTAssertTrue(speech)
        XCTAssertFalse(silence)
    }

    func testZeroEnergyDetection() {
        XCTAssertTrue(AudioEnergy.isEffectivelySilent(samples(speech: false)))
        XCTAssertFalse(AudioEnergy.isEffectivelySilent(samples(speech: true)))
        XCTAssertEqual(AudioEnergy.rms([]), 0)
        XCTAssertEqual(AudioEnergy.rms([1, -1, 1, -1]), 1, accuracy: 1e-6)
    }

    // MARK: - Stop conditions (driven by mock audio classification)

    /// Run a timeline of (timeSeconds, speech?) frames through the monitor,
    /// classifying each frame with the real energy detector, and return the
    /// first stop decision (or nil).
    private func runTimeline(
        scheduledEnd: Date?,
        frames: [(TimeInterval, Bool)],
        manualStopAt: TimeInterval? = nil
    ) async -> StopConditionMonitor.Decision {
        var monitor = StopConditionMonitor(scheduledEnd: scheduledEnd, startedAt: base)
        let detector = EnergySilenceDetector()
        for (seconds, speech) in frames {
            let isSpeech = await detector.containsSpeech(samples(speech: speech))
            let manual = manualStopAt.map { seconds >= $0 } ?? false
            let decision = monitor.evaluate(now: at(seconds), isSpeech: isSpeech, manualStop: manual)
            if case .stop = decision { return decision }
        }
        return .keepRecording
    }

    func testManualStopEndsImmediately() async {
        let decision = await runTimeline(
            scheduledEnd: at(3600),
            frames: [(0, true), (10, true), (20, true)],
            manualStopAt: 15
        )
        XCTAssertEqual(decision, .stop(.manual))
    }

    func testManualRecordingNeverAutoStopsOnSilence() async {
        // No scheduled end: long silence must not stop it.
        let frames = stride(from: 0.0, through: 600, by: 30).map { ($0, false) }
        let decision = await runTimeline(scheduledEnd: nil, frames: frames)
        XCTAssertEqual(decision, .keepRecording)
    }

    func testSilenceBeforeScheduledEndDoesNotStop() async {
        // Meeting ends at 300s; silent the whole time, but we never reach the end.
        let frames = stride(from: 0.0, through: 250, by: 10).map { ($0, false) }
        let decision = await runTimeline(scheduledEnd: at(300), frames: frames)
        XCTAssertEqual(decision, .keepRecording)
    }

    func testSustainedSilencePostScheduleStops() async {
        // Speech up to the scheduled end (300s), then silence; should stop at
        // end + 90s via sustained silence (before the 120s grace cap).
        var frames: [(TimeInterval, Bool)] = stride(from: 0.0, through: 300, by: 30).map { ($0, true) }
        frames += stride(from: 310.0, through: 420, by: 10).map { ($0, false) }
        let decision = await runTimeline(scheduledEnd: at(300), frames: frames)
        XCTAssertEqual(decision, .stop(.sustainedSilence))
    }

    func testContinuedSpeechPastEndStopsAtGraceCap() async {
        // Talking continues well past the scheduled end; sustained-silence never
        // triggers, so the hard grace cap (end + 120s) stops it.
        let frames = stride(from: 0.0, through: 460, by: 20).map { ($0, true) }
        let decision = await runTimeline(scheduledEnd: at(300), frames: frames)
        XCTAssertEqual(decision, .stop(.gracePeriodElapsed))
    }

    func testSpeechResetsSilenceTimer() async {
        // Brief silence after end, then speech, then silence again — the silence
        // clock restarts so it should NOT stop within a short window.
        var monitor = StopConditionMonitor(scheduledEnd: at(300), startedAt: base)
        XCTAssertEqual(monitor.evaluate(now: at(300), isSpeech: true), .keepRecording)
        XCTAssertEqual(monitor.evaluate(now: at(350), isSpeech: false), .keepRecording)
        // Speech at 380 resets lastSpeech; 60s later (440) still under 90s silence.
        XCTAssertEqual(monitor.evaluate(now: at(380), isSpeech: true), .keepRecording)
        XCTAssertEqual(monitor.evaluate(now: at(415), isSpeech: false), .keepRecording)
    }

    // MARK: - Timing config

    func testStartLeadIsClampedToTwoMinutes() {
        XCTAssertEqual(CaptureTiming(startLead: -10).clampedStartLead, 0)
        XCTAssertEqual(CaptureTiming(startLead: 45).clampedStartLead, 45)
        XCTAssertEqual(CaptureTiming(startLead: 999).clampedStartLead, 120)
    }

    // MARK: - Crash-safe writer

    func testAudioWriterProducesReadable16kMonoCAF() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mic.caf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = AudioWriter(url: url)
        try await writer.open()
        try await writer.writeSamples(samples(speech: true))
        try await writer.writeSamples(samples(speech: true))
        let duration = await writer.durationSeconds
        await writer.close()

        XCTAssertEqual(duration, Double(4096 * 2) / 16_000.0, accuracy: 1e-6)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.length, 4096 * 2)
    }
}
