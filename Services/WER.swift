// SPDX-License-Identifier: MIT

import Foundation

/// Word Error Rate — used by the integration test to score a transcript against
/// a reference. WER = (substitutions + insertions + deletions) / reference words.
enum WER {
    /// Lowercase, strip punctuation, collapse whitespace, split into words.
    static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(stripped).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// WER of `hypothesis` against `reference` (0 = perfect). An empty reference
    /// yields 0 for an empty hypothesis, else 1.
    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        let distance = levenshtein(ref, hyp)
        return Double(distance) / Double(ref.count)
    }

    /// Word-level Levenshtein edit distance (two-row DP).
    static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,      // deletion
                    current[j - 1] + 1,   // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
