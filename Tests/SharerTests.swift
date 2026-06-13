// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

@MainActor
final class SharerTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testDraftSubjectAndRecipients() {
        let draft = Sharer.makeDraft(
            title: "Weekly Sync",
            date: date("2026-06-13T15:00:00Z"),
            attendeeEmails: ["a@x.com", "b@x.com"],
            notesBody: "summary"
        )
        XCTAssertTrue(draft.subject.hasPrefix("Notes: Weekly Sync ("))
        XCTAssertEqual(draft.recipients, ["a@x.com", "b@x.com"])
        XCTAssertNil(draft.attachment)
    }

    func testDraftDeduplicatesAndTrimsRecipients() {
        let draft = Sharer.makeDraft(
            title: "Sync",
            date: Date(),
            attendeeEmails: [" a@x.com ", "A@X.com", "", "b@x.com"],
            notesBody: "body"
        )
        XCTAssertEqual(draft.recipients, ["a@x.com", "b@x.com"])
    }

    func testTranscriptAttachedOnlyWhenProvided() {
        let url = URL(fileURLWithPath: "/tmp/transcript.txt")
        let draft = Sharer.makeDraft(
            title: "Sync",
            date: Date(),
            attendeeEmails: ["a@x.com"],
            notesBody: "body",
            transcriptURL: url
        )
        XCTAssertEqual(draft.attachment, url)
    }
}
