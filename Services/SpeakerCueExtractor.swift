// SPDX-License-Identifier: MIT

import Foundation

/// A cue-based name suggestion for one speaker.
struct CueAssignment: Sendable, Equatable {
    var speakerLabel: String
    var email: String
    var confidence: SpeakerConfidence
    var evidence: String
}

/// Extracts speaker → attendee suggestions from a speaker-labelled transcript,
/// strictly constrained to the supplied attendee list.
protocol SpeakerCueExtractor: Sendable {
    func extract(lines: [SpeakerLine], attendees: [NamedAttendee]) async -> [CueAssignment]
}

/// A minimal text-completion interface. The MLX-backed implementation arrives
/// in Phase 5; tests inject a mock.
protocol LLMClient: Sendable {
    func complete(prompt: String) async throws -> String
}

/// Fills and loads `Prompts/*.md` templates.
enum PromptTemplate {
    /// Replace `{{KEY}}` placeholders with values.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    /// Load a prompt template bundled under `Prompts/` in the app bundle.
    static func load(_ name: String, bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "Prompts")
            ?? bundle.url(forResource: name, withExtension: "md")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Deterministic, model-free cue extractor: scans for self-introductions and
/// matches the introduced name to an attendee. The default for v1 and a
/// reliable fallback when no LLM is available.
struct HeuristicSpeakerCueExtractor: SpeakerCueExtractor {
    /// Capture-group 1 is the introduced name. Ordered strongest-first.
    private static let patterns: [String] = [
        #"(?:i'?m|i am)\s+([A-Z][a-z]+)"#,
        #"my name(?:'?s| is)\s+([A-Z][a-z]+)"#,
        #"this is\s+([A-Z][a-z]+)"#,
        #"\bit'?s\s+([A-Z][a-z]+)\s+here\b"#,
        #"\b([A-Z][a-z]+)\s+here\b"#,
    ]

    func extract(lines: [SpeakerLine], attendees: [NamedAttendee]) async -> [CueAssignment] {
        var assignments: [String: CueAssignment] = [:]

        for line in lines {
            guard let name = firstIntroducedName(in: line.text),
                  let attendee = matchAttendee(name: name, attendees: attendees)
            else { continue }

            let candidate = CueAssignment(
                speakerLabel: line.speakerLabel,
                email: attendee.email,
                confidence: .high,
                evidence: "Self-introduction: “\(name)”"
            )
            // First strong cue per speaker wins.
            if assignments[line.speakerLabel] == nil {
                assignments[line.speakerLabel] = candidate
            }
        }

        // Drop assignments where the same attendee was matched to two speakers
        // (ambiguous) — keep none rather than guess.
        return dedupedByEmail(Array(assignments.values))
    }

    private func firstIntroducedName(in text: String) -> String? {
        for pattern in Self.patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
               let nameRange = Range(match.range(at: 1), in: text) {
                return String(text[nameRange])
            }
        }
        return nil
    }

    /// Match by case-insensitive first-name (given name) equality.
    private func matchAttendee(name: String, attendees: [NamedAttendee]) -> NamedAttendee? {
        let lowered = name.lowercased()
        return attendees.first { attendee in
            attendee.name.split(separator: " ").first?.lowercased() == lowered
        }
    }

    private func dedupedByEmail(_ assignments: [CueAssignment]) -> [CueAssignment] {
        let counts = Dictionary(grouping: assignments, by: \.email).mapValues(\.count)
        return assignments.filter { (counts[$0.email] ?? 0) == 1 }
    }
}

/// LLM-backed cue extractor using `Prompts/name-speakers.md`. Parses the JSON
/// schema from the prompt and filters strictly to the attendee list, so the
/// model can never invent an email. Falls back to no assignments on any error.
struct LLMSpeakerCueExtractor: SpeakerCueExtractor {
    let client: LLMClient
    /// Injectable so tests don't depend on the bundled file.
    var template: String?

    private let logger = Log.make("LLMSpeakerCueExtractor")

    init(client: LLMClient, template: String? = nil) {
        self.client = client
        self.template = template
    }

    func extract(lines: [SpeakerLine], attendees: [NamedAttendee]) async -> [CueAssignment] {
        guard let template = template ?? PromptTemplate.load("name-speakers") else {
            logger.error("name-speakers prompt unavailable")
            return []
        }
        let attendeesJSON = renderAttendees(attendees)
        let transcript = lines.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
        let prompt = PromptTemplate.fill(template, [
            "ATTENDEES_JSON": attendeesJSON,
            "TRANSCRIPT": transcript,
        ])

        do {
            let response = try await client.complete(prompt: prompt)
            return Self.parse(response, attendees: attendees)
        } catch {
            logger.error("LLM cue extraction failed: \(error, privacy: .public)")
            return []
        }
    }

    private func renderAttendees(_ attendees: [NamedAttendee]) -> String {
        let entries = attendees.map { "  \"\($0.name)\": \"\($0.email)\"" }.joined(separator: ",\n")
        return "{\n\(entries)\n}"
    }

    /// Parse the prompt's JSON array, dropping anything not in the attendee list.
    static func parse(_ response: String, attendees: [NamedAttendee]) -> [CueAssignment] {
        let validEmails = Set(attendees.map(\.email))
        guard let data = stripToJSONArray(response)?.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry -> CueAssignment? in
            guard let label = entry["speaker_label"] as? String,
                  let email = entry["attendee_email"] as? String,
                  validEmails.contains(email)
            else { return nil }
            let confidence = SpeakerConfidence(rawValue: (entry["confidence"] as? String) ?? "low") ?? .low
            let evidence = (entry["evidence"] as? String) ?? ""
            return CueAssignment(speakerLabel: label, email: email, confidence: confidence, evidence: evidence)
        }
    }

    /// Trim any stray prose/fences around the JSON array.
    private static func stripToJSONArray(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return nil }
        return String(text[start...end])
    }
}
