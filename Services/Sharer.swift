// SPDX-License-Identifier: MIT

import AppKit
import Foundation

/// Builds a pre-addressed email draft for a meeting's notes and hands it to the
/// user's mail client (ADR-006: the user always presses Send — Scribe never
/// transmits anything silently).
///
/// Prefers `NSSharingService(.composeEmail)`, which can carry the optional
/// transcript as a real attachment; falls back to a `mailto:` URL when no
/// compose service is available, truncating the body to stay within mail-client
/// URL limits.
@MainActor
enum Sharer {
    /// `mailto:` bodies get truncated by some clients (Mail.app at ~a few KB of
    /// URL); keep the body well under that and point to the attachment instead.
    static let mailtoBodyLimit = 1800

    struct Draft: Equatable {
        var recipients: [String]
        var subject: String
        var body: String
        var attachment: URL?
    }

    /// Assemble a draft. `notesBody` is the rendered summary + action items;
    /// `transcriptURL` is attached only when the caller opts in.
    static func makeDraft(
        title: String,
        date: Date,
        attendeeEmails: [String],
        notesBody: String,
        transcriptURL: URL? = nil
    ) -> Draft {
        let dateString = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        return Draft(
            recipients: dedupedEmails(attendeeEmails),
            subject: "Notes: \(title) (\(dateString))",
            body: notesBody,
            attachment: transcriptURL
        )
    }

    /// Open the draft in the user's mail client. No-op effect beyond presenting
    /// the composer; sending is the user's action.
    static func share(_ draft: Draft) {
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = draft.recipients
            service.subject = draft.subject
            var items: [Any] = [draft.body]
            if let attachment = draft.attachment {
                items.append(attachment)
            }
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return
            }
        }
        openMailto(draft)
    }

    // MARK: - mailto fallback

    private static func openMailto(_ draft: Draft) {
        var body = draft.body
        if body.count > mailtoBodyLimit {
            let cutoff = body.index(body.startIndex, offsetBy: mailtoBodyLimit)
            body = String(body[..<cutoff]) + "\n\n…(truncated — see attachment for full notes)"
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.recipients.joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: body),
        ]
        // mailto wants %20 for spaces, not '+'.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%20")

        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func dedupedEmails(_ emails: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for email in emails {
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered
    }
}
