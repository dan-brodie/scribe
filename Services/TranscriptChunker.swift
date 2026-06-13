// SPDX-License-Identifier: MIT

import Foundation

/// Splits a long transcript into token-bounded chunks for map-reduce
/// summarization. Token counts are estimated (no tokenizer dependency) so this
/// stays pure and testable; the estimate is deliberately conservative.
enum TranscriptChunker {
    /// Rough token estimate: ~1.3 tokens per whitespace-delimited word.
    static func estimateTokens(_ text: String) -> Int {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return Int(Double(words) * 1.3) + 1
    }

    /// Greedily pack lines into chunks of at most `maxTokens` estimated tokens.
    /// A single oversized line is split on word boundaries.
    static func chunk(_ text: String, maxTokens: Int = 1800) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0

        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { chunks.append(joined) }
            current = []
            currentTokens = 0
        }

        for line in lines {
            let lineTokens = estimateTokens(line)
            if lineTokens > maxTokens {
                flush()
                chunks.append(contentsOf: splitOversizedLine(line, maxTokens: maxTokens))
                continue
            }
            if currentTokens + lineTokens > maxTokens {
                flush()
            }
            current.append(line)
            currentTokens += lineTokens
        }
        flush()
        return chunks
    }

    private static func splitOversizedLine(_ line: String, maxTokens: Int) -> [String] {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var chunks: [String] = []
        var current: [String] = []
        for word in words {
            current.append(word)
            if estimateTokens(current.joined(separator: " ")) >= maxTokens {
                chunks.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
        return chunks
    }
}

/// Extracts named sections from a markdown prompt file (split on `## ` headers).
enum PromptSections {
    static func sections(_ markdown: String) -> [(title: String, body: String)] {
        var result: [(String, String)] = []
        var currentTitle: String?
        var currentBody: [String] = []

        func flush() {
            if let title = currentTitle {
                let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                result.append((title, body))
            }
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentBody = []
            } else if currentTitle != nil {
                currentBody.append(line)
            }
        }
        flush()
        return result
    }

    /// First section whose title contains `keyword` (case-insensitive).
    static func section(_ markdown: String, containing keyword: String) -> String? {
        sections(markdown).first { $0.title.lowercased().contains(keyword.lowercased()) }?.body
    }
}

/// Pulls the JSON payload out of an LLM response that may include fences or prose.
enum JSONExtraction {
    static func object(from text: String) -> String? {
        slice(text, open: "{", close: "}")
    }

    static func array(from text: String) -> String? {
        slice(text, open: "[", close: "]")
    }

    private static func slice(_ text: String, open: Character, close: Character) -> String? {
        guard let start = text.firstIndex(of: open),
              let end = text.lastIndex(of: close),
              start < end
        else { return nil }
        return String(text[start...end])
    }
}
