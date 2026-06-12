// SPDX-License-Identifier: MIT

import XCTest
@testable import Scribe

final class StateMachineTests: XCTestCase {
    // MARK: - Pure transition logic

    func testNextFollowsPipelineOrder() {
        XCTAssertEqual(MeetingState.recorded.next, .transcribed)
        XCTAssertEqual(MeetingState.transcribed.next, .diarized)
        XCTAssertEqual(MeetingState.diarized.next, .summarized)
        XCTAssertEqual(MeetingState.summarized.next, .exported)
        XCTAssertNil(MeetingState.exported.next)
    }

    func testCanTransitionOnlyAllowsSingleForwardStep() {
        XCTAssertTrue(MeetingState.recorded.canTransition(to: .transcribed))
        // Skipping a stage is invalid.
        XCTAssertFalse(MeetingState.recorded.canTransition(to: .diarized))
        // Going backward is invalid.
        XCTAssertFalse(MeetingState.diarized.canTransition(to: .transcribed))
        // Staying put is invalid.
        XCTAssertFalse(MeetingState.recorded.canTransition(to: .recorded))
    }

    // MARK: - Actor + DB

    private func makeFixture() async throws -> (Database, StateMachine, Int64) {
        let db = try Database.inMemory()
        let sm = StateMachine(database: db)
        let id = try await db.insert(
            Meeting(
                id: nil,
                eventID: "evt-\(UUID().uuidString)",
                title: "Test",
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 1800),
                state: .recorded,
                exportPath: nil,
                error: nil
            )
        )
        return (db, sm, id)
    }

    func testValidTransitionPersists() async throws {
        let (db, sm, id) = try await makeFixture()

        let result = try await sm.transition(meeting: id, to: .transcribed)
        XCTAssertEqual(result, .transcribed)

        let persisted = try await db.meetingState(id: id)
        XCTAssertEqual(persisted, .transcribed)
    }

    func testAdvanceWalksThroughEveryStage() async throws {
        let (db, sm, id) = try await makeFixture()

        let expected: [MeetingState] = [.transcribed, .diarized, .summarized, .exported]
        for state in expected {
            let reached = try await sm.advance(meeting: id)
            XCTAssertEqual(reached, state)
        }

        // Terminal: advancing again is a no-op (nil), state unchanged.
        let terminal = try await sm.advance(meeting: id)
        XCTAssertNil(terminal)
        let final = try await db.meetingState(id: id)
        XCTAssertEqual(final, .exported)
    }

    func testInvalidTransitionIsRejectedNotCrashing() async throws {
        let (db, sm, id) = try await makeFixture()

        await XCTAssertThrowsErrorAsync(
            try await sm.transition(meeting: id, to: .summarized)
        ) { error in
            guard case StateMachine.TransitionError.invalidTransition(.recorded, .summarized) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // State must be untouched after a rejected transition.
        let unchanged = try await db.meetingState(id: id)
        XCTAssertEqual(unchanged, .recorded)
    }

    func testTransitionOnMissingMeetingThrows() async throws {
        let db = try Database.inMemory()
        let sm = StateMachine(database: db)

        await XCTAssertThrowsErrorAsync(
            try await sm.transition(meeting: 999, to: .transcribed)
        ) { error in
            guard case StateMachine.TransitionError.meetingNotFound(999) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

/// Async-friendly variant of `XCTAssertThrowsError`.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected error but none thrown. \(message())", file: file, line: line)
    } catch {
        handler(error)
    }
}
