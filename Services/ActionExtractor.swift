// SPDX-License-Identifier: MIT

import Foundation

/// Decodes LLM JSON output into Codable types, with a one-shot repair retry and
/// a graceful degrade path — the JSON-discipline mitigation from the Phase 5
/// spec. Pure orchestration over an injected ``LLMClient``; the MLX-backed
/// client is supplied in production, a mock in tests.
struct ActionExtractor {
    let client: LLMClient
    /// `Prompts/repair-json.md`, injectable so tests don't touch the bundle.
    var repairTemplate: String?
    /// `Prompts/extract-actions.md`, used by ``extract(transcript:attendees:)``.
    var extractTemplate: String?

    private let logger = Log.make("ActionExtractor")

    init(client: LLMClient, repairTemplate: String? = nil, extractTemplate: String? = nil) {
        self.client = client
        self.repairTemplate = repairTemplate
        self.extractTemplate = extractTemplate
    }

    // MARK: - Decode with repair

    /// Decode `raw` as a JSON object of type `T`. On failure, ask the model once
    /// to repair the JSON, then decode again. Returns `nil` if both attempts
    /// fail (the caller's degrade path takes over).
    func decodeObject<T: Decodable & Sendable>(_ raw: String, as type: T.Type) async -> T? {
        await decode(raw, as: type, extractor: JSONExtraction.object)
    }

    /// Decode `raw` as a JSON array of type `[T]`, with the same repair retry.
    func decodeArray<T: Decodable & Sendable>(_ raw: String, of type: T.Type) async -> [T]? {
        await decode(raw, as: [T].self, extractor: JSONExtraction.array)
    }

    private func decode<T: Decodable & Sendable>(
        _ raw: String,
        as type: T.Type,
        extractor: (String) -> String?
    ) async -> T? {
        if let value = Self.tryDecode(type, from: extractor(raw) ?? raw) {
            return value
        }
        guard let repaired = await repair(raw) else { return nil }
        if let value = Self.tryDecode(type, from: extractor(repaired) ?? repaired) {
            logger.info("recovered JSON via repair prompt")
            return value
        }
        logger.error("JSON repair failed; degrading")
        return nil
    }

    private static func tryDecode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Single repair round-trip via `repair-json.md`.
    private func repair(_ broken: String) async -> String? {
        guard let template = repairTemplate ?? PromptTemplate.load("repair-json") else {
            logger.error("repair-json prompt unavailable")
            return nil
        }
        let prompt = PromptTemplate.fill(template, ["BROKEN_JSON": broken])
        return try? await client.complete(prompt: prompt)
    }

    // MARK: - Standalone action extraction

    /// Extract action items directly from a transcript using
    /// `Prompts/extract-actions.md`, validated against ``ExtractedAction`` and
    /// constrained to the attendee list. Long transcripts are chunked and the
    /// results unioned + deduplicated.
    func extract(transcript: String, attendees: [String], maxTokens: Int = 1800) async -> [ExtractedAction] {
        guard let template = extractTemplate ?? PromptTemplate.load("extract-actions") else {
            logger.error("extract-actions prompt unavailable")
            return []
        }
        let attendeeList = attendees.isEmpty ? "(none provided)" : attendees.joined(separator: ", ")
        var collected: [ExtractedAction] = []

        for chunk in TranscriptChunker.chunk(transcript, maxTokens: maxTokens) {
            let prompt = PromptTemplate.fill(template, [
                "ATTENDEES": attendeeList,
                "TRANSCRIPT": chunk,
            ])
            guard let raw = try? await client.complete(prompt: prompt),
                  let actions = await decodeArray(raw, of: ExtractedAction.self)
            else { continue }
            collected.append(contentsOf: actions)
        }

        return Self.deduplicate(OwnerConstraint.apply(collected, attendees: attendees))
    }

    /// Drop actions whose (owner, task) pair already appeared — the same
    /// commitment can surface in overlapping chunks or multiple speakers.
    static func deduplicate(_ actions: [ExtractedAction]) -> [ExtractedAction] {
        var seen = Set<String>()
        return actions.filter { action in
            let key = "\(action.owner ?? "")|\(action.task.lowercased().trimmingCharacters(in: .whitespaces))"
            return seen.insert(key).inserted
        }
    }
}
