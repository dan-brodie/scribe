// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

/// Routes prompts to canned responses by matching distinctive phrases from the
/// shipped `Prompts/*.md` files, so the map-reduce orchestration can be tested
/// without a real LLM.
private struct MockLLMClient: LLMClient {
    let respond: @Sendable (String) -> String
    func complete(prompt: String) async throws -> String { respond(prompt) }
}

final class SummarizerTests: XCTestCase {
    private let attendees = ["Alice Smith", "Bob Jones", "Carol White"]

    // MARK: - Fixture / prompt loading

    private func repoFile(_ relativePath: String) throws -> String {
        // #filePath is Tests/SummarizerTests.swift → up two to the repo root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func prompts() throws -> (summarize: String, repair: String, extract: String) {
        (
            try repoFile("Prompts/summarize-meeting.md"),
            try repoFile("Prompts/repair-json.md"),
            try repoFile("Prompts/extract-actions.md")
        )
    }

    // MARK: - Canned model responses

    private let mapJSON = """
    {"partial_summary":"The team reviewed the Q3 budget and release planning.",
     "decisions":["Ship the beta on June 20th"],"action_items":[]}
    """

    private let reduceJSON = """
    {"title":"Q3 Planning Sync",
     "summary":"The team reviewed the Q3 budget, set the beta date, and assigned follow-ups.",
     "decisions":["Ship the beta on June 20th","Use Postgres for the new service"],
     "action_items":[]}
    """

    /// Owners given by first name only — the owner constraint must map these to
    /// the full attendee names.
    private let extractJSON = """
    [
     {"owner":"Alice","task":"Send the Q3 budget spreadsheet to Bob for review","due":"Friday","done":false,"source_quote":"I'll send the Q3 budget spreadsheet to Bob by Friday"},
     {"owner":"Bob","task":"Schedule the design review with the wider team","due":null,"done":false,"source_quote":"I'll schedule the design review with the wider team"},
     {"owner":"Carol","task":"Update the onboarding docs to match the new flow","due":"next Monday","done":false,"source_quote":"I'll update the onboarding docs by next Monday"},
     {"owner":"Alice","task":"Follow up with the vendor about the contract","due":"this week","done":false,"source_quote":"I'll follow up with the vendor about the contract this week"}
    ]
    """

    private func happyPathHandler() -> @Sendable (String) -> String {
        let map = mapJSON, reduce = reduceJSON, extract = extractJSON
        return { prompt in
            if prompt.contains("supposed to be valid JSON") { return "{}" }
            if prompt.contains("action item extractor") { return extract }
            if prompt.contains("Combine these partial") { return reduce }
            if prompt.contains("Summarize the following portion") { return map }
            return "{}"
        }
    }

    private func makeSummarizer(_ handler: @escaping @Sendable (String) -> String) throws -> Summarizer {
        let (summarize, repair, extract) = try prompts()
        return Summarizer(
            client: MockLLMClient(respond: handler),
            summarizeTemplate: summarize,
            repairTemplate: repair,
            extractTemplate: extract
        )
    }

    // MARK: - Integration: full map-reduce

    func testSummarizeProducesSummaryDecisionsAndActions() async throws {
        let transcript = try repoFile("Tests/Fixtures/sample-transcript.txt")
        let summarizer = try makeSummarizer(happyPathHandler())

        let result = try await summarizer.summarize(
            transcript: transcript,
            attendees: attendees,
            title: "Planning Sync",
            date: "June 13, 2026"
        )

        XCTAssertFalse(result.degraded)
        XCTAssertEqual(result.summary.title, "Q3 Planning Sync")
        XCTAssertFalse(result.summary.summary.isEmpty)
        XCTAssertTrue(result.summary.decisions.contains("Use Postgres for the new service"))

        // ≥90% of the planted action items extracted with correct owners.
        let expected = try decodeExpectedActions()
        let produced = result.summary.actionItems
        let matched = expected.filter { exp in
            produced.contains { $0.owner == exp.owner && $0.task == exp.task }
        }
        XCTAssertGreaterThanOrEqual(Double(matched.count) / Double(expected.count), 0.9)
    }

    func testActionOwnersAreConstrainedToAttendees() async throws {
        // Model invents an owner not on the attendee list → must become nil.
        let rogue = """
        [{"owner":"Dave","task":"Do something","due":null,"done":false,"source_quote":"x"}]
        """
        let handler: @Sendable (String) -> String = { prompt in
            if prompt.contains("action item extractor") { return rogue }
            if prompt.contains("Combine these partial") { return self.reduceJSON }
            if prompt.contains("Summarize the following portion") { return self.mapJSON }
            return "{}"
        }
        let summarizer = try makeSummarizer(handler)
        let result = try await summarizer.summarize(
            transcript: "Alice: Dave will handle it.", attendees: attendees, title: "T", date: "D"
        )
        XCTAssertEqual(result.summary.actionItems.first?.owner, nil)
    }

    // MARK: - Degrade & repair

    func testDegradesToSummaryOnlyWhenReduceUnparseable() async throws {
        let handler: @Sendable (String) -> String = { prompt in
            if prompt.contains("supposed to be valid JSON") { return "still not json" }
            if prompt.contains("action item extractor") { return self.extractJSON }
            if prompt.contains("Combine these partial") { return "not json at all" }
            if prompt.contains("Summarize the following portion") { return self.mapJSON }
            return "{}"
        }
        let summarizer = try makeSummarizer(handler)
        let result = try await summarizer.summarize(
            transcript: "Alice: hello there everyone.", attendees: attendees, title: "Fallback Title", date: "D"
        )

        XCTAssertTrue(result.degraded)
        XCTAssertEqual(result.summary.title, "Fallback Title")
        XCTAssertFalse(result.summary.summary.isEmpty)
        // Actions still survive the degrade.
        XCTAssertEqual(result.summary.actionItems.count, 4)
    }

    func testEmptyTranscriptThrows() async throws {
        let summarizer = try makeSummarizer(happyPathHandler())
        do {
            _ = try await summarizer.summarize(transcript: "   \n ", attendees: attendees, title: "T", date: "D")
            XCTFail("expected emptyTranscript error")
        } catch Summarizer.SummarizerError.emptyTranscript {
            // expected
        }
    }

    // MARK: - ActionExtractor JSON repair

    func testDecodeRecoversViaRepairPrompt() async throws {
        let (_, repair, _) = try prompts()
        // Broken: trailing comma. Repair returns the fixed object.
        let broken = #"{"title":"x","summary":"y","decisions":[],"action_items":[],}"#
        let fixed = #"{"title":"x","summary":"y","decisions":[],"action_items":[]}"#
        let handler: @Sendable (String) -> String = { prompt in
            prompt.contains("supposed to be valid JSON") ? fixed : ""
        }
        let extractor = ActionExtractor(client: MockLLMClient(respond: handler), repairTemplate: repair)
        let value = await extractor.decodeObject(broken, as: MeetingSummary.self)
        XCTAssertEqual(value?.title, "x")
    }

    func testDecodeReturnsNilWhenRepairAlsoFails() async throws {
        let (_, repair, _) = try prompts()
        let handler: @Sendable (String) -> String = { _ in "garbage" }
        let extractor = ActionExtractor(client: MockLLMClient(respond: handler), repairTemplate: repair)
        let value = await extractor.decodeObject("garbage", as: MeetingSummary.self)
        XCTAssertNil(value)
    }

    func testActionExtractorDeduplicates() {
        let dupes = [
            ExtractedAction(owner: "Alice Smith", task: "Send report"),
            ExtractedAction(owner: "Alice Smith", task: "send report  "),
            ExtractedAction(owner: "Bob Jones", task: "Send report"),
        ]
        XCTAssertEqual(ActionExtractor.deduplicate(dupes).count, 2)
    }

    // MARK: - Helpers

    private func decodeExpectedActions() throws -> [ExtractedAction] {
        let json = try repoFile("Tests/Fixtures/sample-actions-expected.json")
        return try JSONDecoder().decode([ExtractedAction].self, from: Data(json.utf8))
    }
}

// MARK: - Pure helper units

final class TranscriptChunkerTests: XCTestCase {
    func testChunkRespectsTokenBudget() {
        let line = String(repeating: "word ", count: 50)
        let text = Array(repeating: line, count: 20).joined(separator: "\n")
        let chunks = TranscriptChunker.chunk(text, maxTokens: 200)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(TranscriptChunker.estimateTokens(chunk), 260) // budget + one line slack
        }
    }

    func testOversizedSingleLineIsSplit() {
        let huge = String(repeating: "token ", count: 5000)
        let chunks = TranscriptChunker.chunk(huge, maxTokens: 100)
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testPromptSectionsSplitsMapAndReduce() {
        let md = "# Title\n\n## Map Prompt\nmap body\n\n## Reduce Prompt\nreduce body\n"
        XCTAssertEqual(PromptSections.section(md, containing: "map"), "map body")
        XCTAssertEqual(PromptSections.section(md, containing: "reduce"), "reduce body")
    }

    func testJSONExtractionStripsFencesAndProse() {
        let wrapped = "Here you go:\n```json\n{\"a\":1}\n```\nThanks!"
        XCTAssertEqual(JSONExtraction.object(from: wrapped), "{\"a\":1}")
        XCTAssertEqual(JSONExtraction.array(from: "noise [1,2,3] noise"), "[1,2,3]")
    }
}

final class OwnerConstraintTests: XCTestCase {
    private let attendees = ["Alice Smith", "Bob Jones"]

    func testResolveExactAndFirstName() {
        XCTAssertEqual(OwnerConstraint.resolve("Alice Smith", attendees: attendees), "Alice Smith")
        XCTAssertEqual(OwnerConstraint.resolve("alice smith", attendees: attendees), "Alice Smith")
        XCTAssertEqual(OwnerConstraint.resolve("Bob", attendees: attendees), "Bob Jones")
    }

    func testResolveRejectsUnknownAndUnassigned() {
        XCTAssertNil(OwnerConstraint.resolve("Dave", attendees: attendees))
        XCTAssertNil(OwnerConstraint.resolve(OwnerConstraint.unassigned, attendees: attendees))
        XCTAssertNil(OwnerConstraint.resolve(nil, attendees: attendees))
        XCTAssertNil(OwnerConstraint.resolve("null", attendees: attendees))
    }

    func testNotesRendererFormatsSections() {
        let summary = MeetingSummary(
            title: "Sync",
            summary: "We talked.",
            decisions: ["Ship it"],
            actionItems: [ExtractedAction(owner: "Alice Smith", task: "Send report", due: "Friday")]
        )
        let notes = NotesRenderer.render(summary, dateString: "June 13, 2026")
        XCTAssertTrue(notes.contains("# Sync"))
        XCTAssertTrue(notes.contains("## Decisions"))
        XCTAssertTrue(notes.contains("- Ship it"))
        XCTAssertTrue(notes.contains("[Alice Smith] Send report (due Friday)"))
    }
}
