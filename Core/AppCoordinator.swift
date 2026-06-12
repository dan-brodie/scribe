// SPDX-License-Identifier: MIT

import Foundation
import Observation
import UserNotifications

/// Thin orchestration layer the UI binds to. Owns the database and state
/// machine and exposes the current menu-bar status. Real work lives in
/// `Services/` (added in later phases); for Phase 0 this drives a demo loop.
@MainActor
@Observable
final class AppCoordinator {
    /// The five visual states of the menu bar icon.
    enum Status: String {
        case idle
        case upcoming
        case recording
        case processing
        case error

        /// SF Symbol name for the menu bar icon.
        var symbolName: String {
            switch self {
            case .idle: return "circle"
            case .upcoming: return "calendar"
            case .recording: return "record.circle"
            case .processing: return "gearshape.2"
            case .error: return "exclamationmark.triangle"
            }
        }

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .upcoming: return "Meeting upcoming"
            case .recording: return "Recording"
            case .processing: return "Processing"
            case .error: return "Error"
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var demoRunning = false

    /// Detected upcoming meetings, soonest first.
    private(set) var upcomingMeetings: [UpcomingMeeting] = []
    /// Calendars available to watch (populated once access is granted).
    private(set) var availableCalendars: [CalendarInfo] = []
    private(set) var calendarAuthorized = false

    /// The next meeting that has not been opted out, for the menu bar row.
    var nextMeeting: UpcomingMeeting? {
        upcomingMeetings.first { !$0.optedOut }
    }

    /// Whether a capture session is currently active.
    private(set) var isRecording = false
    /// Whether meetings should auto-record at their start time.
    var autoRecordEnabled = true

    let database: Database
    let stateMachine: StateMachine
    let calendarService: CalendarService
    let captureService: CaptureService

    private let timing = CaptureTiming.default
    private let logger = Log.make("AppCoordinator")
    private var demoTask: Task<Void, Never>?
    private var calendarPollTask: Task<Void, Never>?
    private var calendarChangeObserver: NSObjectProtocol?
    private var autoStartTask: Task<Void, Never>?
    private var captureConfigured = false

    init() {
        let db: Database
        do {
            db = try Database.makeDefault()
        } catch {
            // A broken on-disk store must not prevent launch: fall back to an
            // ephemeral DB and surface the error in the menu bar icon.
            Log.make("AppCoordinator").error("default DB init failed: \(error, privacy: .public); using in-memory")
            guard let memory = try? Database.inMemory() else {
                fatalError("could not initialize any database: \(error)")
            }
            db = memory
            status = .error
        }
        database = db
        stateMachine = StateMachine(database: db)
        calendarService = CalendarService(database: db)
        captureService = CaptureService(
            recordingsRoot: Self.recordingsRoot(),
            silenceDetector: VadSilenceDetector(),
            timing: timing
        )
        calendarAuthorized = calendarService.isAuthorized
    }

    private static func recordingsRoot() -> URL {
        let base = (try? Database.defaultURL().deletingLastPathComponent())
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("recordings", isDirectory: true)
    }

    /// One-shot launch setup invoked from the UI: permissions, capture handlers,
    /// and calendar monitoring.
    func start() async {
        await requestNotificationPermission()
        await configureCaptureHandlers()
        await startCalendarMonitoringIfAuthorized()
    }

    private func configureCaptureHandlers() async {
        guard !captureConfigured else { return }
        captureConfigured = true
        await captureService.setHandlers(
            onStop: { [weak self] reason, target in
                Task { @MainActor in await self?.handleRecordingStopped(reason: reason, target: target) }
            },
            onZeroEnergyWarning: { [weak self] target in
                Task { @MainActor in self?.warnZeroSystemAudio(target: target) }
            }
        )
    }

    /// Ask for notification permission once, on first launch.
    func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            logger.info("notification authorization granted=\(granted, privacy: .public)")
        } catch {
            logger.error("notification authorization failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Calendar

    /// Begin monitoring if access is already granted (called at launch). If not
    /// authorized, the UI prompts the user to grant access first.
    func startCalendarMonitoringIfAuthorized() async {
        guard calendarService.isAuthorized else {
            calendarAuthorized = false
            return
        }
        await beginCalendarMonitoring()
    }

    /// Trigger the EventKit permission request (from an explicit UI action), and
    /// start monitoring on success.
    func grantCalendarAccess() async {
        let granted = await calendarService.requestAccess()
        calendarAuthorized = granted
        if granted {
            await beginCalendarMonitoring()
        }
    }

    private func beginCalendarMonitoring() async {
        calendarAuthorized = true
        availableCalendars = await calendarService.availableCalendars()
        await refreshCalendar()

        // Live refresh on external calendar changes.
        if calendarChangeObserver == nil {
            calendarChangeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { await self?.refreshCalendar() }
            }
        }

        // Poll every 5 minutes as a backstop.
        calendarPollTask?.cancel()
        calendarPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await self?.refreshCalendar()
            }
        }
    }

    func refreshCalendar() async {
        let meetings = await calendarService.upcomingMeetings()
        upcomingMeetings = meetings
        updateStatusForUpcoming()
        rescheduleAutoStart()
    }

    /// Reflect the soonest non-opted-out meeting in the menu bar icon, unless a
    /// demo run or active recording currently owns the status.
    private func updateStatusForUpcoming() {
        guard !demoRunning, !isRecording, status != .error else { return }
        status = nextMeeting == nil ? .idle : .upcoming
    }

    // MARK: - Recording

    /// Schedule auto-recording for the next meeting at `start − lead`.
    private func rescheduleAutoStart() {
        autoStartTask?.cancel()
        guard autoRecordEnabled, !isRecording, let meeting = nextMeeting else {
            autoStartTask = nil
            return
        }
        let fireAt = meeting.start.addingTimeInterval(-timing.clampedStartLead)
        autoStartTask = Task { [weak self] in
            let delay = fireAt.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.autoStart(meeting)
        }
    }

    private func autoStart(_ meeting: UpcomingMeeting) async {
        guard autoRecordEnabled, !isRecording, !meeting.optedOut else { return }
        let meetingID = try? await database.meetingID(forEventID: meeting.externalID)
        let target = RecordingTarget(
            eventID: meeting.externalID,
            scheduledEnd: meeting.end,
            meetingID: meetingID
        )
        await startCapture(target)
    }

    /// Manual "Record now" — works without a calendar event.
    func recordNow() async {
        guard !isRecording else { return }
        let now = Date()
        let eventID = "manual-\(Int(now.timeIntervalSince1970))"
        let meetingID = try? await database.insert(
            Meeting(
                id: nil,
                eventID: eventID,
                title: "Manual Recording",
                start: now,
                end: now,
                state: .scheduled,
                exportPath: nil,
                error: nil
            )
        )
        await startCapture(RecordingTarget(eventID: eventID, scheduledEnd: nil, meetingID: meetingID))
    }

    private func startCapture(_ target: RecordingTarget) async {
        do {
            try await captureService.startRecording(for: target)
            isRecording = true
            status = .recording
            logger.info("capture started for \(target.eventID, privacy: .public)")
        } catch {
            logger.error("failed to start capture: \(error, privacy: .public)")
            status = .error
        }
    }

    func stopRecording() async {
        await captureService.stopRecording(reason: .manual)
    }

    func discardRecording() async {
        await captureService.discardRecording()
        isRecording = false
        updateStatusForUpcoming()
    }

    /// Invoked from the capture service when a session ends.
    private func handleRecordingStopped(reason: StopReason, target: RecordingTarget) async {
        isRecording = false
        logger.info("recording finished (\(reason.rawValue, privacy: .public)) for \(target.eventID, privacy: .public)")

        // Advance scheduled → recorded so downstream phases can pick it up.
        if let meetingID = target.meetingID {
            do {
                try await stateMachine.transition(meeting: meetingID, to: .recorded)
            } catch {
                logger.error("state transition to recorded failed: \(error, privacy: .public)")
            }
        }
        updateStatusForUpcoming()
        rescheduleAutoStart()
    }

    private func warnZeroSystemAudio(target: RecordingTarget) {
        logger.error("zero system audio energy for \(target.eventID, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = "No system audio detected"
        content.body = "Scribe isn't hearing other participants. Check that your meeting app uses the default output device."
        let request = UNNotificationRequest(identifier: "zero-energy-\(target.eventID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func setOptOut(_ meeting: UpcomingMeeting, optedOut: Bool) async {
        await calendarService.setOptOut(meeting.externalID, optedOut)
        await refreshCalendar()
    }

    func setWatchedCalendars(_ ids: Set<String>?) async {
        await calendarService.setWatchedCalendars(ids)
        await refreshCalendar()
    }

    func watchedCalendarIDs() async -> Set<String>? {
        await calendarService.watchedCalendarIDs
    }

    // MARK: - Demo mode

    /// Insert a fake meeting and walk it through every state on a timer, so the
    /// pipeline and icon states can be exercised without real audio/calendar.
    func startDemo() {
        guard !demoRunning else { return }
        demoRunning = true
        demoTask = Task { [weak self] in
            await self?.runDemo()
            self?.demoRunning = false
            self?.updateStatusForUpcoming()
        }
    }

    func stopDemo() {
        demoTask?.cancel()
        demoTask = nil
        demoRunning = false
        updateStatusForUpcoming()
    }

    private func runDemo() async {
        do {
            status = .upcoming
            try await Task.sleep(for: .seconds(1))

            let now = Date()
            let meeting = Meeting(
                id: nil,
                eventID: "demo-\(Int(now.timeIntervalSince1970))",
                title: "Demo Meeting",
                start: now,
                end: now.addingTimeInterval(1800),
                state: .recorded,
                exportPath: nil,
                error: nil
            )
            let id = try await database.insert(meeting)
            logger.info("demo meeting inserted id=\(id, privacy: .public)")

            status = .recording
            try await Task.sleep(for: .seconds(1))
            status = .processing

            // Advance through transcribed → diarized → summarized → exported.
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                guard let next = try await stateMachine.advance(meeting: id) else { break }
                logger.info("demo meeting advanced to \(next.rawValue, privacy: .public)")
            }

            status = .idle
        } catch is CancellationError {
            status = .idle
        } catch {
            logger.error("demo run failed: \(error, privacy: .public)")
            status = .error
        }
    }
}
