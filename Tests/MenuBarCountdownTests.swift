// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

/// Covers the pure menu-bar countdown formatting (7c). The live ticker and
/// SwiftUI label rendering are exercised by running the app, not unit tests.
final class MenuBarCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func meeting(
        title: String = "Standup",
        startsIn minutes: Double,
        lasts duration: Double = 30
    ) -> UpcomingMeeting {
        let start = now.addingTimeInterval(minutes * 60)
        return UpcomingMeeting(
            externalID: "e1",
            title: title,
            start: start,
            end: start.addingTimeInterval(duration * 60),
            attendees: [],
            optedOut: false
        )
    }

    func testNilWhenNoMeeting() {
        XCTAssertNil(AppCoordinator.menuBarCountdownText(for: nil, now: now))
    }

    func testRoundsUpToWholeMinutes() {
        // 11.2 minutes away → "12 min" (we round up so we never under-report).
        XCTAssertEqual(
            AppCoordinator.menuBarCountdownText(for: meeting(startsIn: 11.2), now: now),
            "Standup · 12 min"
        )
    }

    func testSingularMinute() {
        XCTAssertEqual(
            AppCoordinator.menuBarCountdownText(for: meeting(startsIn: 0.5), now: now),
            "Standup · 1 min"
        )
    }

    func testInProgressMeetingShowsNow() {
        // Started two minutes ago but still running.
        XCTAssertEqual(
            AppCoordinator.menuBarCountdownText(for: meeting(startsIn: -2), now: now),
            "Standup · now"
        )
    }

    func testEndedMeetingIsHidden() {
        XCTAssertNil(
            AppCoordinator.menuBarCountdownText(for: meeting(startsIn: -40, lasts: 30), now: now)
        )
    }

    func testBeyondLookAheadIsHidden() {
        // 90 minutes out, default 60-minute window → hidden.
        XCTAssertNil(AppCoordinator.menuBarCountdownText(for: meeting(startsIn: 90), now: now))
    }

    func testLongTitleTruncated() {
        let result = AppCoordinator.menuBarCountdownText(
            for: meeting(title: "Quarterly Planning and Roadmap Review", startsIn: 5),
            now: now
        )
        XCTAssertEqual(result, "Quarterly Planning an… · 5 min")
    }
}
