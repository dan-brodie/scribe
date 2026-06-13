// SPDX-License-Identifier: MIT

import Foundation

/// An ``LLMClient`` that must download/load weights before first use. The
/// summarizer forwards model-download progress through this when available so
/// the menu bar can show a percentage on first run.
protocol PreparableLLMClient: LLMClient {
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Generates a meeting summary, decisions, and structured action items from a
/// diarized transcript using a local LLM, with chunked map-reduce for long
/// meetings (ADR-001: MLX for the LLM).
///
/// An `actor` so the single-job processing invariant holds even if the UI
/// triggers re-summarization. All model-specific work lives behind the injected
/// ``LLMClient`` — the orchestration here is pure and unit-tested with a mock.
actor Summarizer {
    enum SummarizerError: Error, CustomStringConvertible {
        case emptyTranscript

        var description: String {
            switch self {
            case .emptyTranscript: return "no transcript text to summarize"
            }
        }
    }

    /// The outcome of one summarization run.
    struct Result: Sendable, Equatable {
        var summary: MeetingSummary
        /// True when the model's JSON could not be parsed (even after repair) and
        /// we fell back to a summary-only result — the spec's degrade path.
        var degraded: Bool
    }

    private let client: LLMClient
    private let extractor: ActionExtractor
    /// Token budget per chunk; conservative headroom under a ~2048-ctx 4B model.
    private let maxChunkTokens: Int
    private let logger = Log.make("Summarizer")

    /// Injectable prompt overrides so tests don't depend on the app bundle.
    private let summarizeTemplate: String?

    init(
        client: LLMClient = MLXLLMClient(),
        maxChunkTokens: Int = 1800,
        summarizeTemplate: String? = nil,
        repairTemplate: String? = nil,
        extractTemplate: String? = nil
    ) {
        self.client = client
        self.maxChunkTokens = maxChunkTokens
        self.summarizeTemplate = summarizeTemplate
        self.extractor = ActionExtractor(
            client: client,
            repairTemplate: repairTemplate,
            extractTemplate: extractTemplate
        )
    }

    /// Load (downloading on first use) the LLM weights. No-op for clients that
    /// don't need preparation (e.g. test mocks).
    func prepareModel(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let preparable = client as? PreparableLLMClient else { return }
        try await preparable.prepare(progress: progress)
    }

    /// Summarize a diarized transcript.
    ///
    /// - Parameters:
    ///   - transcript: speaker-labelled plain text (`transcript.txt`).
    ///   - attendees: display names; owners are constrained to this set.
    ///   - title: the calendar title (the model may propose a better one).
    ///   - date: human-readable meeting date, passed to the reduce prompt.
    func summarize(
        transcript: String,
        attendees: [String],
        title: String,
        date: String
    ) async throws -> Result {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummarizerError.emptyTranscript }

        guard let template = summarizeTemplate ?? PromptTemplate.load("summarize-meeting"),
              let mapPrompt = PromptSections.section(template, containing: "map"),
              let reducePrompt = PromptSections.section(template, containing: "reduce")
        else {
            // No prompts → cannot run; surface an empty degraded summary.
            logger.error("summarize-meeting prompt unavailable")
            return degraded(title: title, summary: trimmed, decisions: [], attendees: attendees, actions: [])
        }

        let chunks = TranscriptChunker.chunk(trimmed, maxTokens: maxChunkTokens)
        let attendeeList = attendees.isEmpty ? "(none provided)" : attendees.joined(separator: ", ")

        // Map: summarize each chunk. Chunks are processed sequentially (one
        // inference at a time) — this is also the low-power throttle.
        let partials = await mapChunks(chunks, template: mapPrompt, attendees: attendeeList)

        // Actions come from the dedicated extract-actions path (spec criterion),
        // owner-constrained and deduplicated across chunks.
        let actions = await extractor.extract(transcript: trimmed, attendees: attendees, maxTokens: maxChunkTokens)

        // Reduce: synthesize the final summary from the partials.
        let reduced = await reduce(
            partials: partials,
            template: reducePrompt,
            attendees: attendeeList,
            title: title,
            date: date
        )

        guard var summary = reduced else {
            // Reduce JSON could not be parsed → degrade to summary-only, but keep
            // the actions we did manage to extract.
            logger.error("reduce step failed; degrading to summary-only")
            return degraded(
                title: title,
                summary: joinedSummaries(partials, fallback: trimmed),
                decisions: mergedDecisions(partials),
                attendees: attendees,
                actions: actions
            )
        }

        summary.actionItems = actions
        if summary.title.trimmingCharacters(in: .whitespaces).isEmpty { summary.title = title }
        return Result(summary: summary, degraded: false)
    }

    // MARK: - Map / Reduce

    private func mapChunks(_ chunks: [String], template: String, attendees: String) async -> [PartialSummary] {
        var partials: [PartialSummary] = []
        for (index, chunk) in chunks.enumerated() {
            let prompt = PromptTemplate.fill(template, [
                "ATTENDEES": attendees,
                "CHUNK": chunk,
            ])
            guard let raw = try? await client.complete(prompt: prompt),
                  let partial = await extractor.decodeObject(raw, as: PartialSummary.self)
            else {
                logger.error("map chunk \(index, privacy: .public) unparseable; skipping")
                continue
            }
            partials.append(partial)
        }
        return partials
    }

    private func reduce(
        partials: [PartialSummary],
        template: String,
        attendees: String,
        title: String,
        date: String
    ) async -> MeetingSummary? {
        let joined = partials.enumerated()
            .map { "### Part \($0.offset + 1)\n\($0.element.partialSummary)" }
            .joined(separator: "\n\n")
        let prompt = PromptTemplate.fill(template, [
            "ATTENDEES": attendees,
            "TITLE": title,
            "DATE": date,
            "PARTIAL_SUMMARIES": joined.isEmpty ? "(no content extracted)" : joined,
        ])
        guard let raw = try? await client.complete(prompt: prompt) else { return nil }
        return await extractor.decodeObject(raw, as: MeetingSummary.self)
    }

    // MARK: - Degrade helpers

    private func degraded(
        title: String,
        summary: String,
        decisions: [String],
        attendees: [String],
        actions: [ExtractedAction]
    ) -> Result {
        let meeting = MeetingSummary(
            title: title,
            summary: summary,
            decisions: decisions,
            actionItems: OwnerConstraint.apply(actions, attendees: attendees)
        )
        return Result(summary: meeting, degraded: true)
    }

    private func joinedSummaries(_ partials: [PartialSummary], fallback: String) -> String {
        let text = partials.map(\.partialSummary).filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? fallback : text
    }

    private func mergedDecisions(_ partials: [PartialSummary]) -> [String] {
        var seen = Set<String>()
        return partials.flatMap(\.decisions).filter { seen.insert($0.lowercased()).inserted }
    }
}
