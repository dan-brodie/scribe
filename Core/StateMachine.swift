// SPDX-License-Identifier: MIT

import Foundation

/// The processing stages a meeting passes through, in order.
///
/// ```
/// scheduled → recorded → transcribed → diarized → summarized → exported
/// ```
///
/// `scheduled` is the head: a calendar-detected meeting exists before any
/// audio is captured. Recording (Phase 2) transitions it to `recorded`.
///
/// `CaseIterable` declaration order *is* the pipeline order; `next` and
/// transition validation rely on it.
enum MeetingState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case recorded
    case transcribed
    case diarized
    case summarized
    case exported

    /// The single stage that legally follows this one, or `nil` if terminal.
    var next: MeetingState? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else {
            return nil
        }
        return all[index + 1]
    }

    /// Only a forward step of exactly one stage is a legal transition.
    func canTransition(to target: MeetingState) -> Bool {
        next == target
    }
}

/// Validates and persists meeting state transitions.
///
/// An `actor` so it is safe to drive from multiple concurrent processing
/// tasks. Invalid transitions are rejected with a thrown error and a logged
/// message — never a crash.
actor StateMachine {
    enum TransitionError: Error, CustomStringConvertible, Equatable {
        case invalidTransition(from: MeetingState, to: MeetingState)
        case meetingNotFound(id: Int64)

        var description: String {
            switch self {
            case let .invalidTransition(from, to):
                return "invalid transition \(from.rawValue) → \(to.rawValue)"
            case let .meetingNotFound(id):
                return "meeting \(id) not found"
            }
        }
    }

    private let database: Database
    private let logger = Log.make("StateMachine")

    init(database: Database) {
        self.database = database
    }

    /// Move a meeting to `target`, rejecting any non-sequential transition.
    @discardableResult
    func transition(meeting id: Int64, to target: MeetingState) async throws -> MeetingState {
        guard let current = try await database.meetingState(id: id) else {
            logger.error("rejected transition to \(target.rawValue, privacy: .public): meeting \(id) not found")
            throw TransitionError.meetingNotFound(id: id)
        }
        guard current.canTransition(to: target) else {
            logger.error(
                "rejected invalid transition \(current.rawValue, privacy: .public) → \(target.rawValue, privacy: .public) for meeting \(id)"
            )
            throw TransitionError.invalidTransition(from: current, to: target)
        }
        try await database.updateMeetingState(id: id, to: target)
        logger.info("meeting \(id) \(current.rawValue, privacy: .public) → \(target.rawValue, privacy: .public)")
        return target
    }

    /// Advance a meeting to its next stage. Returns `nil` if already terminal.
    @discardableResult
    func advance(meeting id: Int64) async throws -> MeetingState? {
        guard let current = try await database.meetingState(id: id) else {
            throw TransitionError.meetingNotFound(id: id)
        }
        guard let next = current.next else {
            return nil
        }
        return try await transition(meeting: id, to: next)
    }
}
