// SPDX-License-Identifier: MIT

import Foundation

/// Which captured channel a piece of transcript came from. Used later as a
/// diarization prior (your mic vs. everyone else's system audio).
enum TranscriptChannel: String, Codable, Sendable {
    case mic
    case system
}

/// A contiguous run of speech on one channel, with timestamps.
struct TranscriptSegment: Codable, Sendable, Equatable {
    var channel: TranscriptChannel
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Float
}

/// Non-fatal issues surfaced to the user rather than thrown.
enum TranscriptWarning: String, Codable, Sendable {
    case possiblyUnsupportedLanguage
    case lowConfidence
}

/// The merged result of transcribing both channels. Serialized to
/// `segments.json` in the meeting's recording folder.
struct Transcript: Codable, Sendable, Equatable {
    var segments: [TranscriptSegment]
    var rtfx: Float
    var warnings: [TranscriptWarning]

    init(segments: [TranscriptSegment], rtfx: Float = 0, warnings: [TranscriptWarning] = []) {
        self.segments = segments
        self.rtfx = rtfx
        self.warnings = warnings
    }

    /// Readable rendering, one line per segment, channel-tagged.
    var plainText: String {
        segments
            .map { "[\($0.channel.rawValue)] \($0.text)" }
            .joined(separator: "\n")
    }

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }
}

/// Builds timestamped segments from a flat list of ASR token timings, and
/// merges per-channel transcripts into a single timeline. Pure and testable.
enum TranscriptBuilder {
    /// A minimal token timing, decoupled from FluidAudio's `TokenTiming` so this
    /// is testable without the dependency.
    struct Token: Sendable, Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var confidence: Float
    }

    /// Group tokens into segments, splitting whenever the silent gap between two
    /// tokens exceeds `gapThreshold`. SentencePiece word-boundary markers
    /// (`▁`) become spaces.
    static func segments(
        from tokens: [Token],
        channel: TranscriptChannel,
        gapThreshold: TimeInterval = 0.6
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: [Token] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = renderText(current)
            guard !text.isEmpty else { current = []; return }
            let avgConfidence = current.map(\.confidence).reduce(0, +) / Float(current.count)
            result.append(
                TranscriptSegment(
                    channel: channel,
                    text: text,
                    start: first.start,
                    end: last.end,
                    confidence: avgConfidence
                )
            )
            current = []
        }

        for token in tokens {
            if let previous = current.last, token.start - previous.end > gapThreshold {
                flush()
            }
            current.append(token)
        }
        flush()
        return result
    }

    /// Join SentencePiece tokens into clean text.
    static func renderText(_ tokens: [Token]) -> String {
        let joined = tokens.map(\.text).joined()
        return joined
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merge two channels into one timeline, sorted by start time (ties keep mic
    /// first, since the local speaker's words anchor the conversation).
    static func merge(
        mic: [TranscriptSegment],
        system: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        (mic + system).sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.channel == .mic && rhs.channel == .system
            }
            return lhs.start < rhs.start
        }
    }
}
