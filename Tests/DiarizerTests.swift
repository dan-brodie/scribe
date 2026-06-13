// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

final class DiarizerTests: XCTestCase {
    // MARK: - Attribution by time overlap

    private func micSeg(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(channel: .mic, text: text, start: start, end: end, confidence: 0.9)
    }

    private func sysSeg(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(channel: .system, text: text, start: start, end: end, confidence: 0.9)
    }

    func testMicSegmentsGoToLocalUser() {
        let attributed = SpeakerAttribution.attribute(
            transcript: [micSeg("hi", 0, 1)],
            diarized: [],
            localUserLabel: "you"
        )
        XCTAssertEqual(attributed.first?.speakerLabel, "you")
    }

    func testSystemSegmentsGoToMostOverlappingSpeaker() {
        let diarized = [
            DiarizedSegment(speakerLabel: "SPEAKER_0", start: 0, end: 2),
            DiarizedSegment(speakerLabel: "SPEAKER_1", start: 2, end: 5),
        ]
        let attributed = SpeakerAttribution.attribute(
            transcript: [sysSeg("a", 0, 1.5), sysSeg("b", 3, 4)],
            diarized: diarized,
            localUserLabel: "you"
        )
        XCTAssertEqual(attributed.map(\.speakerLabel), ["SPEAKER_0", "SPEAKER_1"])
    }

    func testSystemSegmentWithNoOverlapIsUnknown() {
        let attributed = SpeakerAttribution.attribute(
            transcript: [sysSeg("x", 10, 11)],
            diarized: [DiarizedSegment(speakerLabel: "SPEAKER_0", start: 0, end: 2)],
            localUserLabel: "you",
            unknownLabel: "SPEAKER_?"
        )
        XCTAssertEqual(attributed.first?.speakerLabel, "SPEAKER_?")
    }

    // MARK: - Heuristic cue extraction

    func testHeuristicExtractsSelfIntroduction() async {
        let lines = [
            SpeakerLine(speakerLabel: "SPEAKER_0", text: "Hi everyone, I'm Priya and I'll lead today."),
            SpeakerLine(speakerLabel: "SPEAKER_1", text: "Sounds good."),
        ]
        let attendees = [
            NamedAttendee(name: "Priya Patel", email: "priya@example.com"),
            NamedAttendee(name: "John Smith", email: "john@example.com"),
        ]
        let cues = await HeuristicSpeakerCueExtractor().extract(lines: lines, attendees: attendees)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.speakerLabel, "SPEAKER_0")
        XCTAssertEqual(cues.first?.email, "priya@example.com")
        XCTAssertEqual(cues.first?.confidence, .high)
    }

    func testHeuristicIgnoresNamesNotInAttendeeList() async {
        let lines = [SpeakerLine(speakerLabel: "SPEAKER_0", text: "I'm Gandalf.")]
        let attendees = [NamedAttendee(name: "Priya Patel", email: "priya@example.com")]
        let cues = await HeuristicSpeakerCueExtractor().extract(lines: lines, attendees: attendees)
        XCTAssertTrue(cues.isEmpty)
    }

    // MARK: - SpeakerNamer pipeline

    func testChannelPriorAssignsLocalUser() async {
        let assignments = await SpeakerNamer().assign(
            speakerLabels: [],
            localUserLabel: "you",
            localUserEmail: "me@example.com",
            lines: [],
            attendees: [NamedAttendee(name: "Me", email: "me@example.com")]
        )
        XCTAssertEqual(assignments.first?.attendeeEmail, "me@example.com")
        XCTAssertEqual(assignments.first?.provenance, .channel)
        XCTAssertEqual(assignments.first?.confidence, .high)
    }

    func testCueAssignmentWins() async {
        let lines = [SpeakerLine(speakerLabel: "SPEAKER_0", text: "Hello, I'm John.")]
        let attendees = [
            NamedAttendee(name: "Me", email: "me@example.com"),
            NamedAttendee(name: "John Smith", email: "john@example.com"),
        ]
        let assignments = await SpeakerNamer().assign(
            speakerLabels: ["SPEAKER_0"],
            localUserLabel: "you",
            localUserEmail: "me@example.com",
            lines: lines,
            attendees: attendees
        )
        let john = assignments.first { $0.speakerLabel == "SPEAKER_0" }
        XCTAssertEqual(john?.attendeeEmail, "john@example.com")
        XCTAssertEqual(john?.provenance, .cue)
    }

    func testCountMatchFallbackAssignsWhenCountsEqual() async {
        // Two unknown speakers, two non-local attendees, no cues → count match.
        let attendees = [
            NamedAttendee(name: "Me", email: "me@example.com"),
            NamedAttendee(name: "Alice", email: "alice@example.com"),
            NamedAttendee(name: "Bob", email: "bob@example.com"),
        ]
        let assignments = await SpeakerNamer().assign(
            speakerLabels: ["SPEAKER_0", "SPEAKER_1"],
            localUserLabel: "you",
            localUserEmail: "me@example.com",
            lines: [SpeakerLine(speakerLabel: "SPEAKER_0", text: "no cue here")],
            attendees: attendees
        )
        let system = assignments.filter { $0.speakerLabel != "you" }
        XCTAssertEqual(system.count, 2)
        XCTAssertTrue(system.allSatisfy { $0.provenance == .countMatch })
        XCTAssertEqual(Set(system.compactMap(\.attendeeEmail)), ["alice@example.com", "bob@example.com"])
    }

    func testNoCountMatchWhenCountsDiffer() async {
        let attendees = [
            NamedAttendee(name: "Me", email: "me@example.com"),
            NamedAttendee(name: "Alice", email: "alice@example.com"),
        ]
        let assignments = await SpeakerNamer().assign(
            speakerLabels: ["SPEAKER_0", "SPEAKER_1"],
            localUserLabel: "you",
            localUserEmail: "me@example.com",
            lines: [],
            attendees: attendees
        )
        let system = assignments.filter { $0.speakerLabel != "you" }
        XCTAssertTrue(system.allSatisfy { $0.provenance == .unassigned && $0.attendeeEmail == nil })
    }

    // MARK: - Integration: 3-speaker scripted self-introductions

    /// ≥2/3 speakers auto-named from scripted self-introductions (ADR-005). This
    /// runs without audio or models by feeding the diarized + transcribed result
    /// directly, exercising attribution + naming end to end.
    func testThreeSpeakerSelfIntrosNameAtLeastTwo() async {
        let diarized = [
            DiarizedSegment(speakerLabel: "SPEAKER_0", start: 0, end: 3),
            DiarizedSegment(speakerLabel: "SPEAKER_1", start: 3, end: 6),
            DiarizedSegment(speakerLabel: "SPEAKER_2", start: 6, end: 9),
        ]
        let transcript = [
            sysSeg("Hi, I'm Alice, product lead.", 0, 3),
            sysSeg("Hey, this is Bob from engineering.", 3, 6),
            sysSeg("And Carol here, design.", 6, 9),
        ]
        let attendees = [
            NamedAttendee(name: "Alice Adams", email: "alice@example.com"),
            NamedAttendee(name: "Bob Brown", email: "bob@example.com"),
            NamedAttendee(name: "Carol Clark", email: "carol@example.com"),
        ]

        let attributed = SpeakerAttribution.attribute(transcript: transcript, diarized: diarized, localUserLabel: "you")
        let lines = SpeakerAttribution.lines(from: attributed)
        let assignments = await SpeakerNamer().assign(
            speakerLabels: ["SPEAKER_0", "SPEAKER_1", "SPEAKER_2"],
            localUserLabel: "you",
            localUserEmail: nil,
            lines: lines,
            attendees: attendees
        )

        let correct = [
            ("SPEAKER_0", "alice@example.com"),
            ("SPEAKER_1", "bob@example.com"),
            ("SPEAKER_2", "carol@example.com"),
        ].filter { label, email in
            assignments.first { $0.speakerLabel == label }?.attendeeEmail == email
        }
        XCTAssertGreaterThanOrEqual(correct.count, 2, "expected ≥2/3 correctly auto-named, got \(correct.count)")
    }

    // MARK: - Voice math

    func testCosineSimilarity() {
        XCTAssertEqual(VoiceMath.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(VoiceMath.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(VoiceMath.cosine([1, 1], [-1, -1]), -1, accuracy: 1e-6)
        XCTAssertEqual(VoiceMath.cosine([], [1]), 0)
        XCTAssertEqual(VoiceMath.cosine([1, 2], [1]), 0)
    }

    func testEmbeddingCodecRoundTrips() {
        let embedding: [Float] = [0.1, -0.5, 3.14, 0]
        let decoded = EmbeddingCodec.decode(EmbeddingCodec.encode(embedding))
        XCTAssertEqual(decoded, embedding)
    }

    // MARK: - Prompt template

    func testPromptFillReplacesPlaceholders() {
        let filled = PromptTemplate.fill(
            "Attendees: {{ATTENDEES_JSON}}\nTranscript: {{TRANSCRIPT}}",
            ["ATTENDEES_JSON": "{}", "TRANSCRIPT": "SPEAKER_0: hi"]
        )
        XCTAssertEqual(filled, "Attendees: {}\nTranscript: SPEAKER_0: hi")
    }

    func testLLMCueParsingFiltersToAttendeeList() {
        let attendees = [NamedAttendee(name: "Priya", email: "priya@example.com")]
        let response = """
        Here you go:
        [
          {"speaker_label": "SPEAKER_0", "attendee_email": "priya@example.com", "confidence": "high", "evidence": "intro"},
          {"speaker_label": "SPEAKER_1", "attendee_email": "intruder@evil.com", "confidence": "high", "evidence": "x"}
        ]
        """
        let cues = LLMSpeakerCueExtractor.parse(response, attendees: attendees)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.email, "priya@example.com")
    }

    // MARK: - Transcript rendering

    func testTranscriptRenderGroupsBySpeaker() {
        let lines = [
            SpeakerLine(speakerLabel: "you", text: "Hello."),
            SpeakerLine(speakerLabel: "you", text: "How are you?"),
            SpeakerLine(speakerLabel: "SPEAKER_0", text: "Good thanks."),
        ]
        let rendered = ArtifactWriter.render(lines: lines) { $0 == "you" ? "You" : "Alice" }
        XCTAssertEqual(rendered, "You:\nHello.\nHow are you?\n\nAlice:\nGood thanks.\n")
    }
}
