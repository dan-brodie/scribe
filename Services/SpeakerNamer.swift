// SPDX-License-Identifier: MIT

import Foundation

/// Maps anonymous speaker labels to attendees using the ADR-005 heuristic
/// pipeline, in order of signal strength:
///
/// 1. Channel prior — the mic speaker is the local user.
/// 2. Self-introduction / address cues (LLM or heuristic), constrained to the
///    attendee list.
/// 3. Voice enrollment matches (precomputed cosine scores).
/// 4. Count matching — if unresolved speakers == unresolved attendees, pair them.
///
/// Everything is best-effort and confidence-scored; unresolved speakers stay
/// anonymous. Pure and testable (cue extractor + enrollment are injected).
struct SpeakerNamer {
    var cueExtractor: SpeakerCueExtractor
    /// Minimum cosine score to accept an enrollment match.
    var enrollmentThreshold: Float = 0.7

    init(cueExtractor: SpeakerCueExtractor = HeuristicSpeakerCueExtractor()) {
        self.cueExtractor = cueExtractor
    }

    func assign(
        speakerLabels: [String],
        localUserLabel: String,
        localUserEmail: String?,
        lines: [SpeakerLine],
        attendees: [NamedAttendee],
        enrollment: [String: (email: String, score: Float)] = [:]
    ) async -> [SpeakerAssignment] {
        var assignments: [String: SpeakerAssignment] = [:]
        var usedEmails = Set<String>()

        // 1. Channel prior: mic → local user.
        if let localUserEmail {
            assignments[localUserLabel] = SpeakerAssignment(
                speakerLabel: localUserLabel,
                attendeeEmail: localUserEmail,
                confidence: .high,
                provenance: .channel
            )
            usedEmails.insert(localUserEmail)
        }

        // Attendees available for system speakers (exclude the local user).
        let systemAttendees = attendees.filter { $0.email != localUserEmail }

        // 2. Cues.
        let cues = await cueExtractor.extract(lines: lines, attendees: systemAttendees)
        for cue in cues where speakerLabels.contains(cue.speakerLabel) {
            guard assignments[cue.speakerLabel] == nil, !usedEmails.contains(cue.email) else { continue }
            assignments[cue.speakerLabel] = SpeakerAssignment(
                speakerLabel: cue.speakerLabel,
                attendeeEmail: cue.email,
                confidence: cue.confidence,
                provenance: .cue
            )
            usedEmails.insert(cue.email)
        }

        // 3. Voice enrollment.
        for label in speakerLabels where assignments[label] == nil {
            guard let match = enrollment[label],
                  match.score >= enrollmentThreshold,
                  !usedEmails.contains(match.email)
            else { continue }
            assignments[label] = SpeakerAssignment(
                speakerLabel: label,
                attendeeEmail: match.email,
                confidence: match.score >= 0.85 ? .high : .medium,
                provenance: .enrollment
            )
            usedEmails.insert(match.email)
        }

        // 4. Count matching for whatever is left.
        let unresolved = speakerLabels.filter { assignments[$0] == nil }
        let remaining = systemAttendees.filter { !usedEmails.contains($0.email) }
        if !unresolved.isEmpty, unresolved.count == remaining.count {
            for (label, attendee) in zip(unresolved, remaining) {
                assignments[label] = SpeakerAssignment(
                    speakerLabel: label,
                    attendeeEmail: attendee.email,
                    confidence: .low,
                    provenance: .countMatch
                )
                usedEmails.insert(attendee.email)
            }
        }

        // 5. Anything still unresolved stays anonymous.
        for label in speakerLabels where assignments[label] == nil {
            assignments[label] = SpeakerAssignment(
                speakerLabel: label,
                attendeeEmail: nil,
                confidence: .low,
                provenance: .unassigned
            )
        }

        // Stable order: local user first, then speaker labels in input order.
        var ordered: [SpeakerAssignment] = []
        if let local = assignments[localUserLabel] {
            ordered.append(local)
        }
        for label in speakerLabels where label != localUserLabel {
            if let assignment = assignments[label] {
                ordered.append(assignment)
            }
        }
        return ordered
    }
}
