// SPDX-License-Identifier: MIT

import Foundation

/// An extracted action item, matching the LLM JSON schema in
/// `Prompts/extract-actions.md` and `summarize-meeting.md`.
struct ExtractedAction: Codable, Sendable, Equatable {
    var owner: String?
    var task: String
    var due: String?
    var done: Bool
    var sourceQuote: String?

    enum CodingKeys: String, CodingKey {
        case owner, task, due, done
        case sourceQuote = "source_quote"
    }

    init(owner: String? = nil, task: String, due: String? = nil, done: Bool = false, sourceQuote: String? = nil) {
        self.owner = owner
        self.task = task
        self.due = due
        self.done = done
        self.sourceQuote = sourceQuote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        task = try container.decode(String.self, forKey: .task)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        // Models sometimes omit `done`; default to false.
        done = (try? container.decodeIfPresent(Bool.self, forKey: .done)) ?? false
        sourceQuote = try container.decodeIfPresent(String.self, forKey: .sourceQuote)
    }
}

/// One chunk's map-phase output.
struct PartialSummary: Codable, Sendable, Equatable {
    var partialSummary: String
    var decisions: [String]
    var actionItems: [ExtractedAction]

    enum CodingKeys: String, CodingKey {
        case partialSummary = "partial_summary"
        case decisions
        case actionItems = "action_items"
    }
}

/// The reduce-phase (final) summary.
struct MeetingSummary: Codable, Sendable, Equatable {
    var title: String
    var summary: String
    var decisions: [String]
    var actionItems: [ExtractedAction]

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case actionItems = "action_items"
    }

    init(title: String, summary: String, decisions: [String], actionItems: [ExtractedAction]) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
    }
}

/// Constrains action-item owners to the attendee list (or `nil`/Unassigned), so
/// the model can never invent a person (spec criterion).
enum OwnerConstraint {
    static let unassigned = "Unassigned"

    /// Map a raw owner to a valid attendee name, or `nil` if it matches none.
    static func resolve(_ owner: String?, attendees: [String]) -> String? {
        guard let owner, !owner.isEmpty, owner.lowercased() != "null" else { return nil }
        if owner == unassigned { return nil }
        // Exact, then case-insensitive, then given-name match.
        if attendees.contains(owner) { return owner }
        if let ci = attendees.first(where: { $0.lowercased() == owner.lowercased() }) { return ci }
        let firstName = owner.split(separator: " ").first.map(String.init)?.lowercased()
        return attendees.first {
            $0.split(separator: " ").first.map(String.init)?.lowercased() == firstName
        }
    }

    static func apply(_ actions: [ExtractedAction], attendees: [String]) -> [ExtractedAction] {
        actions.map { action in
            var copy = action
            copy.owner = resolve(action.owner, attendees: attendees)
            return copy
        }
    }
}

/// Renders the human-facing `notes.txt`.
enum NotesRenderer {
    static func render(_ summary: MeetingSummary, date: Date? = nil, dateString: String? = nil) -> String {
        var lines: [String] = []
        lines.append("# \(summary.title)")
        if let dateString {
            lines.append(dateString)
        } else if let date {
            lines.append(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
        }
        lines.append("")
        lines.append("## Summary")
        lines.append(summary.summary)

        if !summary.decisions.isEmpty {
            lines.append("")
            lines.append("## Decisions")
            for decision in summary.decisions {
                lines.append("- \(decision)")
            }
        }

        if !summary.actionItems.isEmpty {
            lines.append("")
            lines.append("## Action Items")
            for action in summary.actionItems {
                let owner = action.owner ?? OwnerConstraint.unassigned
                let due = action.due.map { " (due \($0))" } ?? ""
                lines.append("- [\(owner)] \(action.task)\(due)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
