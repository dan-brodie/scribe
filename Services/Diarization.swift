// SPDX-License-Identifier: MIT

import Foundation

/// A diarized speech region attributed to an anonymous speaker label.
struct DiarizedSegment: Sendable, Equatable {
    var speakerLabel: String
    var start: TimeInterval
    var end: TimeInterval
    /// Speaker embedding, when available (used for voice enrollment).
    var embedding: [Float]

    init(speakerLabel: String, start: TimeInterval, end: TimeInterval, embedding: [Float] = []) {
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
        self.embedding = embedding
    }

    var duration: TimeInterval { max(0, end - start) }
}

/// Confidence bucket for a name assignment (ADR-005).
enum SpeakerConfidence: String, Codable, Sendable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: SpeakerConfidence, rhs: SpeakerConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Numeric form for the `speakers.confidence` (REAL) column.
    var score: Double {
        switch self {
        case .low: return 0.3
        case .medium: return 0.6
        case .high: return 0.9
        }
    }

    init(score: Double) {
        switch score {
        case ..<0.45: self = .low
        case ..<0.75: self = .medium
        default: self = .high
        }
    }
}

/// How a name assignment was derived (ADR-005 provenance).
enum SpeakerProvenance: String, Codable, Sendable {
    case channel
    case cue
    case enrollment
    case countMatch
    case unassigned
    /// Set by an explicit user reassignment in the Review popover.
    case manual
}

/// A speaker → attendee assignment with confidence + provenance.
struct SpeakerAssignment: Sendable, Equatable {
    var speakerLabel: String
    var attendeeEmail: String?
    var confidence: SpeakerConfidence
    var provenance: SpeakerProvenance

    /// The minimum confidence at which an assignment is applied automatically
    /// rather than only suggested in the Review popover.
    static let autoApplyThreshold: SpeakerConfidence = .medium

    var isAutoApplied: Bool {
        attendeeEmail != nil && confidence >= Self.autoApplyThreshold
    }
}

/// An attendee with a resolvable name, for cue matching.
struct NamedAttendee: Sendable, Equatable {
    var name: String
    var email: String
}

/// One speaker-labelled transcript line, fed to cue extraction and persisted as
/// `transcript-lines.json` so the transcript can be re-rendered on reassignment.
struct SpeakerLine: Codable, Sendable, Equatable {
    var speakerLabel: String
    var text: String
}

/// Attributes transcript segments to diarized speakers by time overlap. Pure.
enum SpeakerAttribution {
    /// Assign each transcript segment a speaker label: mic-channel segments go to
    /// `localUserLabel`; system-channel segments go to the diarized speaker with
    /// the greatest time overlap (or `unknownLabel` if none).
    static func attribute(
        transcript: [TranscriptSegment],
        diarized: [DiarizedSegment],
        localUserLabel: String,
        unknownLabel: String = "SPEAKER_?"
    ) -> [(segment: TranscriptSegment, speakerLabel: String)] {
        transcript.map { segment in
            switch segment.channel {
            case .mic:
                return (segment, localUserLabel)
            case .system:
                let label = bestOverlap(for: segment, in: diarized)?.speakerLabel ?? unknownLabel
                return (segment, label)
            }
        }
    }

    /// The diarized segment overlapping `segment` the most (nil if none overlap).
    static func bestOverlap(for segment: TranscriptSegment, in diarized: [DiarizedSegment]) -> DiarizedSegment? {
        var best: DiarizedSegment?
        var bestOverlap: TimeInterval = 0
        for candidate in diarized {
            let overlap = min(segment.end, candidate.end) - max(segment.start, candidate.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = candidate
            }
        }
        return best
    }

    /// Build speaker-labelled lines from attributed segments (for cue extraction
    /// and transcript.txt).
    static func lines(from attributed: [(segment: TranscriptSegment, speakerLabel: String)]) -> [SpeakerLine] {
        attributed.map { SpeakerLine(speakerLabel: $0.speakerLabel, text: $0.segment.text) }
    }
}
