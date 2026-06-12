// SPDX-License-Identifier: MIT

import Foundation

/// Tunable timing for automatic recording start/stop.
struct CaptureTiming: Sendable, Equatable {
    /// How long before the scheduled start to begin recording (0–120 s).
    var startLead: TimeInterval = 0
    /// Extra time kept recording after the scheduled end (hard cap).
    var graceAfterScheduledEnd: TimeInterval = 120
    /// Continuous post-schedule silence that ends the recording early.
    var sustainedSilenceToStop: TimeInterval = 90
    /// How long a silent system channel is tolerated before warning the user.
    var zeroEnergyWarningDelay: TimeInterval = 30

    static let `default` = CaptureTiming()

    /// Clamp the configurable lead to the documented 0–2 minute range.
    var clampedStartLead: TimeInterval { min(max(startLead, 0), 120) }
}

/// Why a recording stopped.
enum StopReason: String, Sendable, Equatable {
    case manual
    case gracePeriodElapsed
    case sustainedSilence
}

/// Pure decision logic for when a recording should end. Driven by periodic
/// `evaluate` calls with a speech/silence classification for the latest audio,
/// so it is fully unit-testable with mock input and an injected clock.
struct StopConditionMonitor: Sendable {
    enum Decision: Sendable, Equatable {
        case keepRecording
        case stop(StopReason)
    }

    let timing: CaptureTiming
    /// The meeting's scheduled end, or `nil` for a manual ("Record now") session.
    let scheduledEnd: Date?

    private(set) var lastSpeechAt: Date

    init(timing: CaptureTiming = .default, scheduledEnd: Date?, startedAt: Date) {
        self.timing = timing
        self.scheduledEnd = scheduledEnd
        // Assume the session opens with speech so silence is measured from now.
        self.lastSpeechAt = startedAt
    }

    /// Evaluate whether to keep recording given the current moment.
    /// - Parameters:
    ///   - now: current time.
    ///   - isSpeech: whether the latest audio chunk contained speech.
    ///   - manualStop: the user pressed Stop.
    mutating func evaluate(now: Date, isSpeech: Bool, manualStop: Bool = false) -> Decision {
        if isSpeech {
            lastSpeechAt = now
        }

        if manualStop {
            return .stop(.manual)
        }

        // Manual recordings (no schedule) only end on an explicit stop.
        guard let end = scheduledEnd else {
            return .keepRecording
        }

        // Hard cap: scheduled end + grace period.
        if now >= end.addingTimeInterval(timing.graceAfterScheduledEnd) {
            return .stop(.gracePeriodElapsed)
        }

        // Sustained silence, counted only after the scheduled end.
        if now >= end {
            let silenceStart = max(lastSpeechAt, end)
            if now.timeIntervalSince(silenceStart) >= timing.sustainedSilenceToStop {
                return .stop(.sustainedSilence)
            }
        }

        return .keepRecording
    }
}
