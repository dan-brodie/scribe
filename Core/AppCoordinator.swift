// SPDX-License-Identifier: MIT

import AppKit
import AVFoundation
import Foundation
import Observation
import UserNotifications

/// Thin orchestration layer the UI binds to. Owns the database and state
/// machine and exposes the current menu-bar status. Real work lives in
/// `Services/`.
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

    /// Detected upcoming meetings, soonest first.
    private(set) var upcomingMeetings: [UpcomingMeeting] = []
    /// Calendars available to watch (populated once access is granted).
    private(set) var availableCalendars: [CalendarInfo] = []
    private(set) var calendarAuthorized = false
    /// Set when a recording was blocked because microphone access is off; drives
    /// the "Enable Microphone Access…" affordance in the menu.
    private(set) var microphoneAccessDenied = false
    /// Set when system-audio (process tap) capture is unavailable, so recordings
    /// of online meetings would miss the far side; drives the "Enable Audio
    /// Recording Access…" affordance. Best-effort — never blocks recording.
    private(set) var systemAudioAccessDenied = false
    /// Whether macOS notification permission is granted. When false, meeting
    /// prompts and "Notes ready" banners are silently dropped, so the menu offers
    /// an "Enable Notifications…" action.
    private(set) var notificationsAuthorized = true

    // MARK: Permission overview (Settings)

    /// Permission statuses for the Settings overview, refreshed via
    /// `refreshPermissions()`. System audio has no status API, so it's probed.
    private(set) var microphonePermission: PermissionStatus = .unknown
    private(set) var systemAudioPermission: PermissionStatus = .unknown
    private(set) var calendarPermission: PermissionStatus = .unknown

    // MARK: Model pre-download (onboarding)

    /// First-run model-download progress (0...1) — bound ONLY in the onboarding
    /// window, never the menu bar dropdown (which crashes on rapid updates).
    private(set) var modelDownloadProgress: Double?
    /// Whether a pre-download is in flight, all needed models are present, and the
    /// last error if any — for the onboarding "Download models" step.
    private(set) var isDownloadingModels = false
    private(set) var modelsReady = false
    private(set) var modelDownloadError: String?

    /// The next meeting that has not been opted out, for the menu bar row.
    var nextMeeting: UpcomingMeeting? {
        upcomingMeetings.first { !$0.optedOut }
    }

    /// Current time, ticked once a minute by `startCountdownTicker()` so the
    /// menu-bar countdown (7c) and relative-time labels stay live.
    private(set) var now: Date = Date()

    /// Only surface the menu-bar countdown when the next meeting starts within
    /// this window; beyond it the menu bar shows just the icon.
    nonisolated private static let menuBarLookAhead: TimeInterval = 60 * 60

    /// Short menu-bar text for the next upcoming meeting, e.g. "Standup · 12 min"
    /// or "Standup · now". `nil` when there's no meeting within the look-ahead
    /// window or while a recording is in progress (the icon covers that case).
    var menuBarCountdown: String? {
        guard !isRecording else { return nil }
        return Self.menuBarCountdownText(for: nextMeeting, now: now)
    }

    /// Pure formatting for the menu-bar countdown, factored out for testing.
    /// Returns `nil` when there's no meeting, it has ended, or it starts beyond
    /// the look-ahead window.
    nonisolated static func menuBarCountdownText(
        for meeting: UpcomingMeeting?,
        now: Date,
        lookAhead: TimeInterval = AppCoordinator.menuBarLookAhead
    ) -> String? {
        guard let meeting, meeting.end > now else { return nil }
        let interval = meeting.start.timeIntervalSince(now)
        guard interval <= lookAhead else { return nil }
        let minutes = max(0, Int((interval / 60).rounded(.up)))
        let when: String
        switch minutes {
        case 0: when = "now"
        case 1: when = "1 min"
        default: when = "\(minutes) min"
        }
        return "\(menuBarTitle(meeting.title)) · \(when)"
    }

    /// Truncate a meeting title so the menu bar doesn't grow unbounded.
    nonisolated private static func menuBarTitle(_ title: String, max: Int = 22) -> String {
        title.count <= max ? title : String(title.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Whether a capture session is currently active.
    private(set) var isRecording = false
    /// What to do when a watched meeting starts: nothing, ask, or auto-record.
    var recordMode: RecordMode {
        didSet {
            UserDefaults.standard.set(recordMode.rawValue, forKey: Self.recordModeKey)
            rescheduleAutoStart()
        }
    }

    /// Short message describing current processing ("Transcribing…"), else nil.
    /// Also surfaces a coarse "Downloading model…" during first-run downloads —
    /// deliberately without a live percentage (see `noteModelDownloading`).
    private(set) var processingMessage: String?

    /// Whether voice enrollment is on ("Remember voices", off by default).
    var rememberVoices = false {
        didSet { Task { await voiceStore.setEnabled(rememberVoices) } }
    }
    /// The most recently diarized meeting, offered for review in the menu.
    private(set) var lastDiarizedMeetingID: Int64?
    /// The most recently exported meeting, surfaced in the menu for reveal/share.
    private(set) var lastExportedMeetingID: Int64?
    /// The folder the last export was written to (the Reveal/Share target).
    private(set) var lastExportURL: URL?

    /// Where notes are written; user-configurable in Settings.
    let outputFolderStore = OutputFolderStore()

    /// Whether to attach the full transcript to shared emails. Off by default
    /// (ADR-006 / open question 3).
    var includeTranscriptInEmail: Bool {
        didSet { UserDefaults.standard.set(includeTranscriptInEmail, forKey: Self.includeTranscriptKey) }
    }

    /// Whether to delete the raw audio (`mic.caf`/`system.caf`) once a meeting's
    /// notes have been exported. Off by default; opting in bounds how long raw
    /// recordings of people's voices sit on disk.
    var deleteAudioAfterExport: Bool {
        didSet { UserDefaults.standard.set(deleteAudioAfterExport, forKey: Self.deleteAudioKey) }
    }

    /// Whether the first-launch onboarding wizard still needs to run.
    private(set) var needsOnboarding: Bool
    /// Whether the user has acknowledged the recording-consent notice. Recording
    /// is blocked until this is true (Phase 6 acceptance criterion).
    private(set) var hasAcknowledgedConsent: Bool

    private static let includeTranscriptKey = "includeTranscriptInEmail"
    private static let deleteAudioKey = "deleteAudioAfterExport"
    private static let onboardedKey = "didCompleteOnboarding"
    private static let consentKey = "hasAcknowledgedRecordingConsent"
    private static let recordModeKey = "recordMode"

    let database: Database
    let stateMachine: StateMachine
    let calendarService: CalendarService
    let captureService: CaptureService
    let asrEngine = ASREngine()
    let diarizer = Diarizer()
    let speakerNamer = SpeakerNamer()
    let voiceStore: VoiceEnrollmentStore

    /// Summarization backend. Apple's on-device model by default; the MLX/Gemma
    /// path stays available behind this flag.
    var summarizationBackend: SummarizationBackend = .configured {
        didSet { SummarizationBackend.store(summarizationBackend) }
    }
    /// Whether Apple's on-device model is usable right now (for the settings hint).
    var appleFoundationModelsAvailable: Bool { SummarizerClientFactory.appleFoundationModelsAvailable }

    /// Label used for the local user's (mic) speaker.
    static let localUserLabel = "you"

    private let timing = CaptureTiming.default
    private let logger = Log.make("AppCoordinator")
    private var calendarPollTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var calendarChangeObserver: NSObjectProtocol?
    private var autoStartTask: Task<Void, Never>?
    private var captureConfigured = false
    /// Becomes true once a system-audio tap is confirmed available, so we don't
    /// re-probe on every recording.
    private var systemAudioConfirmed = false
    /// Meetings already prompted ("Ask" mode), so a calendar re-poll doesn't
    /// re-prompt the same event.
    private var promptedEventIDs: Set<String> = []
    /// Presents the persistent floating "meeting starting" prompt.
    private let meetingPrompt = MeetingPromptPresenter()

    /// Per-meeting diarization scratch kept for the Review popover: speaker
    /// embeddings (for enrollment) and a representative snippet location.
    /// Bounded to the most recent meetings so a long-running session doesn't
    /// accumulate embeddings indefinitely.
    private var meetingEmbeddings: [Int64: [String: [Float]]] = [:]
    private var meetingSnippets: [Int64: [String: (channel: TranscriptChannel, start: TimeInterval)]] = [:]
    private var reviewScratchOrder: [Int64] = []
    private let reviewScratchLimit = 8
    private var snippetPlayer: AVAudioPlayer?
    /// The temp file backing the currently-playing snippet, removed on replace.
    private var lastSnippetURL: URL?

    init() {
        let defaults = UserDefaults.standard
        includeTranscriptInEmail = defaults.bool(forKey: Self.includeTranscriptKey)
        deleteAudioAfterExport = defaults.bool(forKey: Self.deleteAudioKey)
        needsOnboarding = !defaults.bool(forKey: Self.onboardedKey)
        hasAcknowledgedConsent = defaults.bool(forKey: Self.consentKey)
        recordMode = defaults.string(forKey: Self.recordModeKey)
            .flatMap(RecordMode.init(rawValue:)) ?? .ask

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
        voiceStore = VoiceEnrollmentStore(database: db, enabled: false)
        calendarAuthorized = calendarService.isAuthorized
    }

    private static func recordingsRoot() -> URL {
        let base = (try? Database.defaultURL().deletingLastPathComponent())
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("recordings", isDirectory: true)
    }

    /// Per-meeting working directory. Event IDs are inviter-controlled, so the
    /// path component is always sanitized via `RecordingPaths` — every consumer
    /// of the recordings root must go through this helper.
    private static func recordingDir(for eventID: String) -> URL {
        RecordingPaths.directory(root: recordingsRoot(), eventID: eventID)
    }

    /// One-shot launch setup invoked from the UI: permissions, capture handlers,
    /// calendar monitoring, and resuming any meetings a previous run left
    /// mid-pipeline.
    func start() async {
        NotificationActionHandler.shared.register()
        await requestNotificationPermission()
        await configureCaptureHandlers()
        await startCalendarMonitoringIfAuthorized()
        startCountdownTicker()
        await resumeIncompleteMeetings()
    }

    /// Pick up meetings stranded in a non-terminal state by a crash, quit, or
    /// earlier processing failure, and run their remaining stages sequentially
    /// (one processing job at a time).
    private func resumeIncompleteMeetings() async {
        let stuck = (try? await database.incompleteMeetings()) ?? []
        guard !stuck.isEmpty else { return }
        logger.info("resuming \(stuck.count, privacy: .public) incomplete meeting(s)")
        for meeting in stuck {
            guard let meetingID = meeting.id, !isRecording else { continue }
            await resumeMeeting(meeting, meetingID: meetingID)
        }
    }

    /// Run the pipeline from the stage matching the meeting's persisted state.
    /// Each stage chains into the next on success, so one call completes the
    /// meeting or records an error.
    private func resumeMeeting(_ meeting: Meeting, meetingID: Int64) async {
        status = .processing
        defer {
            processingMessage = nil
            updateStatusForUpcoming()
        }
        switch meeting.state {
        case .recorded:
            await processMeeting(meetingID: meetingID, eventID: meeting.eventID)
        case .transcribed:
            guard let transcript = loadTranscript(eventID: meeting.eventID) else {
                logger.error("resume: segments.json missing for \(meeting.eventID, privacy: .public)")
                try? await database.setError(
                    meetingID: meetingID,
                    message: "Resume failed: transcription output is missing or unreadable."
                )
                return
            }
            await diarizeAndName(meetingID: meetingID, eventID: meeting.eventID, transcript: transcript)
        case .diarized:
            await summarizeMeeting(meetingID: meetingID, eventID: meeting.eventID)
        case .summarized:
            await exportMeeting(meetingID: meetingID, eventID: meeting.eventID)
        case .scheduled, .exported:
            break
        }
    }

    /// Reload a meeting's transcript from its persisted `segments.json`.
    private func loadTranscript(eventID: String) -> Transcript? {
        let url = Self.recordingDir(for: eventID).appendingPathComponent("segments.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Tick `now` at each minute boundary so the menu-bar countdown (7c) updates
    /// without busy-waiting. Aligns to the next whole minute, then every 60 s.
    private func startCountdownTicker() {
        guard countdownTask == nil else { return }
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                let secondsToNextMinute = 60 - (Calendar.current.component(.second, from: Date()))
                try? await Task.sleep(for: .seconds(secondsToNextMinute))
                guard !Task.isCancelled else { break }
                self?.now = Date()
            }
        }
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

    /// Ask for notification permission once, on first launch, and record the
    /// resulting status so the menu can offer a fix if it's off.
    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                notificationsAuthorized = granted
                logger.info("notification authorization granted=\(granted, privacy: .public)")
            } catch {
                notificationsAuthorized = false
                logger.error("notification authorization failed: \(error, privacy: .public)")
            }
        case .authorized, .provisional, .ephemeral:
            notificationsAuthorized = true
        default:
            notificationsAuthorized = false
        }
    }

    /// Menu action: get notifications turned on. Prompts when undetermined
    /// (activating first so the system alert surfaces for this agent app), and
    /// otherwise sends the user to System Settings since macOS won't re-prompt.
    func enableNotifications() async {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            notificationsAuthorized = granted
            if !granted { openNotificationSettings() }
        case .authorized, .provisional, .ephemeral:
            notificationsAuthorized = true
        default:
            openNotificationSettings()
        }
    }

    /// Open System Settings → Notifications.
    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
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

    /// Reflect the soonest non-opted-out meeting in the menu bar icon, unless an
    /// active recording currently owns the status.
    private func updateStatusForUpcoming() {
        guard !isRecording, status != .error else { return }
        status = nextMeeting == nil ? .idle : .upcoming
    }

    // MARK: - Recording

    /// Schedule the meeting-start action (record or prompt) for the next meeting
    /// at `start − lead`.
    private func rescheduleAutoStart() {
        autoStartTask?.cancel()
        guard recordMode != .off, !isRecording, let meeting = nextMeeting else {
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
            await self?.handleMeetingStart(meeting)
        }
    }

    /// Fired at a watched meeting's start: record automatically, or post a
    /// "Take Notes / Ignore" prompt, per the user's `recordMode`.
    private func handleMeetingStart(_ meeting: UpcomingMeeting) async {
        guard recordMode != .off, !isRecording, !meeting.optedOut else { return }
        switch recordMode {
        case .auto:
            await startRecording(for: meeting)
        case .ask:
            // Prompt once per occurrence; a 5-minute re-poll must not re-ask,
            // but the next instance of a recurring series must prompt again.
            guard !promptedEventIDs.contains(meeting.occurrenceID) else { return }
            promptedEventIDs.insert(meeting.occurrenceID)
            promptToRecord(meeting)
        case .off:
            break
        }
    }

    /// Begin recording a scheduled meeting (shared by auto mode and "Take Notes").
    /// Keyed on the occurrence, not the series, so recurring meetings never
    /// collide with a prior instance's pipeline state or files.
    private func startRecording(for meeting: UpcomingMeeting) async {
        let occurrenceID = meeting.occurrenceID
        var meetingID = try? await database.meetingID(forEventID: occurrenceID)
        if meetingID == nil {
            // The occurrence hasn't been persisted yet (e.g. recording started
            // before the first calendar poll) — create its row now so the
            // capture can be processed into notes.
            meetingID = try? await database.upsertScheduledMeeting(
                externalID: occurrenceID,
                title: meeting.title,
                start: meeting.start,
                end: meeting.end,
                attendees: meeting.attendees
            )
        }
        let target = RecordingTarget(
            eventID: occurrenceID,
            scheduledEnd: meeting.end,
            meetingID: meetingID
        )
        await startCapture(target)
    }

    /// Show the persistent floating prompt for a starting meeting. It stays
    /// on-screen (top-center, above other apps) until the user chooses.
    private func promptToRecord(_ meeting: UpcomingMeeting) {
        meetingPrompt.present(
            meeting: meeting,
            onJoin: { [weak self] in
                Task { @MainActor in await self?.joinAndTranscribe(meeting) }
            },
            onIgnore: { [weak self] in
                Task { @MainActor in await self?.ignoreMeeting(meeting.externalID) }
            }
        )
    }

    /// "Join and transcribe": open the meeting's join link and start recording.
    func joinAndTranscribe(_ meeting: UpcomingMeeting) async {
        if let link = meeting.conferenceURL, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        guard !isRecording else { return }
        await startRecording(for: meeting)
    }

    /// "Ignore": opt this meeting out so it isn't re-prompted; the next event
    /// becomes the soonest and is scheduled in turn.
    func ignoreMeeting(_ eventID: String) async {
        await calendarService.setOptOut(eventID, true)
        await refreshCalendar()
    }

    /// Manual "Record now" — works without a calendar event.
    func recordNow() async {
        guard !isRecording else { return }
        let now = Date()
        let eventID = "manual-\(Int(now.timeIntervalSince1970))"
        let meetingID: Int64
        do {
            meetingID = try await database.insert(
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
        } catch {
            // Without a meeting row the capture can't be processed into notes, so
            // surface the failure instead of recording into a void.
            logger.error("failed to create manual meeting: \(error, privacy: .public)")
            status = .error
            return
        }
        await startCapture(RecordingTarget(eventID: eventID, scheduledEnd: nil, meetingID: meetingID))
    }

    private func startCapture(_ target: RecordingTarget) async {
        guard hasAcknowledgedConsent else {
            logger.info("recording blocked for \(target.eventID, privacy: .public): consent not acknowledged")
            notifyConsentRequired()
            return
        }
        // macOS only shows the microphone prompt via requestAccess, and only
        // once ever. Starting AVAudioEngine without authorization silently
        // records zeroed buffers, so always confirm access before capturing.
        guard await ensureMicrophoneAccess() else {
            logger.info("recording blocked for \(target.eventID, privacy: .public): microphone access not granted")
            microphoneAccessDenied = true
            notifyMicrophoneRequired()
            status = .error
            return
        }
        microphoneAccessDenied = false
        // System audio (the far side of an online meeting) is best-effort —
        // in-person meetings are mic-only — so this never blocks. Probe once so
        // macOS prompts the first time and we can offer a fix path if it's off.
        await ensureSystemAudioAccess()
        do {
            try await captureService.startRecording(for: target)
            isRecording = true
            status = .recording
            logger.info("capture started for \(target.eventID, privacy: .public)")
        } catch CaptureError.alreadyRecording {
            // A session is already live (e.g. racing auto-start and manual
            // start) — re-sync our flags to it rather than flagging an error.
            logger.error("duplicate capture start for \(target.eventID, privacy: .public); keeping existing session")
            isRecording = true
            status = .recording
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
                await processMeeting(meetingID: meetingID, eventID: target.eventID)
            } catch {
                logger.error("state transition to recorded failed: \(error, privacy: .public)")
            }
        } else {
            logger.error("recording for \(target.eventID, privacy: .public) had no meeting row — not processed")
        }
        updateStatusForUpcoming()
        rescheduleAutoStart()
    }

    /// Reflect a first-run model download in the menu as a single static message.
    ///
    /// We deliberately do NOT publish a live percentage: the FluidAudio/MLX
    /// download handlers fire many times per second, and the value is non-
    /// monotonic (per-file), so any value bound to the `MenuBarExtra` menu
    /// re-renders it fast enough to drive SwiftUI's menu diffing into runaway
    /// recursion and crash (EXC_BAD_ACCESS in AttributeGraph →
    /// menuHostDidChangeMenuItems). A guarded one-time string change is safe.
    private func noteModelDownloading() {
        let message = "Downloading model…"
        if processingMessage != message { processingMessage = message }
    }

    // MARK: - Processing pipeline

    /// Run transcription for a freshly-recorded meeting and advance
    /// `recorded → transcribed`. Later phases extend this with diarization etc.
    func processMeeting(meetingID: Int64, eventID: String) async {
        guard !isRecording else { return }
        status = .processing
        processingMessage = "Transcribing…"
        defer {
            processingMessage = nil
            updateStatusForUpcoming()
        }

        do {
            let output = try await asrEngine.transcribeMeeting(
                eventID: eventID,
                recordingsRoot: Self.recordingsRoot(),
                modelProgress: { [weak self] fraction in
                    guard fraction < 1 else { return }
                    Task { @MainActor in self?.noteModelDownloading() }
                }
            )
            try await stateMachine.transition(meeting: meetingID, to: .transcribed)
            logger.info("transcription complete for \(eventID, privacy: .public): RTFx \(output.transcript.rtfx, privacy: .public)")
            if output.transcript.warnings.contains(.possiblyUnsupportedLanguage) {
                warnUnsupportedLanguage(eventID: eventID)
            }
            await diarizeAndName(meetingID: meetingID, eventID: eventID, transcript: output.transcript)
        } catch {
            logger.error("transcription failed for \(eventID, privacy: .public): \(error, privacy: .public)")
            try? await database.setError(meetingID: meetingID, message: String(describing: error))
            noteStageFailed(eventID: eventID, stage: "transcribing")
        }
    }

    // MARK: - Diarization & speaker naming

    /// Diarize the system channel, attribute transcript segments to speakers,
    /// name them (ADR-005), persist, write `transcript.txt`, and advance
    /// `transcribed → diarized`.
    private func diarizeAndName(meetingID: Int64, eventID: String, transcript: Transcript) async {
        processingMessage = "Identifying speakers…"
        let dir = Self.recordingDir(for: eventID)
        let systemURL = dir.appendingPathComponent("system.caf")

        do {
            let diarized = (try? await diarizer.diarize(systemURL: systemURL)) ?? []
            let attributed = SpeakerAttribution.attribute(
                transcript: transcript.segments,
                diarized: diarized,
                localUserLabel: Self.localUserLabel
            )
            let lines = SpeakerAttribution.lines(from: attributed)

            let attendees = try await database.attendees(forMeeting: meetingID)
            let named = attendees.compactMap { attendee -> NamedAttendee? in
                guard let email = attendee.email else { return nil }
                return NamedAttendee(name: attendee.name, email: email)
            }
            let localUserEmail = attendees.first { $0.role == "self" }?.email
            let speakerLabels = orderedSpeakerLabels(diarized)

            // Voice enrollment scores (only when enabled).
            let embeddings = diarizer.embeddings(from: diarized)
            var enrollment: [String: (email: String, score: Float)] = [:]
            if rememberVoices {
                for (label, embedding) in embeddings {
                    if let match = await voiceStore.bestMatch(for: embedding, threshold: 0.7) {
                        enrollment[label] = match
                    }
                }
            }

            let assignments = await speakerNamer.assign(
                speakerLabels: speakerLabels,
                localUserLabel: Self.localUserLabel,
                localUserEmail: localUserEmail,
                lines: lines,
                attendees: named,
                enrollment: enrollment
            )

            try await persistSpeakers(meetingID: meetingID, assignments: assignments)
            cacheReviewScratch(meetingID: meetingID, embeddings: embeddings, diarized: diarized, transcript: transcript)

            let nameForEmail = Dictionary(named.map { ($0.email, $0.name) }, uniquingKeysWith: { first, _ in first })
            let resolver = displayNameResolver(assignments: assignments, nameForEmail: nameForEmail)
            try ArtifactWriter(meetingDir: dir).writeLines(lines)
            try ArtifactWriter(meetingDir: dir).writeTranscript(lines: lines, displayName: resolver)

            try await stateMachine.transition(meeting: meetingID, to: .diarized)
            lastDiarizedMeetingID = meetingID
            logger.info("diarized \(eventID, privacy: .public): \(assignments.count, privacy: .public) speakers")
            await summarizeMeeting(meetingID: meetingID, eventID: eventID)
        } catch {
            logger.error("diarization failed for \(eventID, privacy: .public): \(error, privacy: .public)")
            try? await database.setError(meetingID: meetingID, message: String(describing: error))
            noteStageFailed(eventID: eventID, stage: "identifying speakers")
        }
    }

    // MARK: - Summarization

    /// Summarize the diarized transcript (ADR-001), write `actions.json` and
    /// `notes.md`, persist action rows, and advance `diarized → summarized`.
    ///
    /// A completed recording always produces an exported note: if there's no
    /// speech to summarize, or summarization fails (e.g. the model can't be
    /// loaded), we still write a minimal note and export the transcript rather
    /// than silently dropping the recording. This matters for manual "Record
    /// Now" captures with no calendar event, which would otherwise vanish.
    private func summarizeMeeting(meetingID: Int64, eventID: String) async {
        processingMessage = "Summarizing…"
        let dir = Self.recordingDir(for: eventID)
        let writer = ArtifactWriter(meetingDir: dir)

        let meeting = try? await database.meeting(id: meetingID)
        let title = meeting?.title ?? "Meeting"
        let dateString = meeting.map {
            DateFormatter.localizedString(from: $0.start, dateStyle: .medium, timeStyle: .short)
        } ?? ""

        guard let transcript = writer.loadTranscriptText(), !transcript.isEmpty else {
            logger.error("no transcript text to summarize for \(eventID, privacy: .public)")
            await finalizeWithoutSummary(
                meetingID: meetingID,
                eventID: eventID,
                writer: writer,
                title: title,
                dateString: dateString,
                note: "_No speech was detected in this recording._",
                failureReason: nil
            )
            return
        }

        do {
            let attendees = try await database.attendees(forMeeting: meetingID).map(\.name)

            // Build the summarizer with the currently-selected backend so a flag
            // change takes effect on the next meeting without a relaunch. Apple's
            // on-device model needs no download (prepareModel is then a no-op).
            let summarizer = Summarizer(client: SummarizerClientFactory.makeClient(backend: summarizationBackend))
            try await summarizer.prepareModel(progress: { [weak self] fraction in
                guard fraction < 1 else { return }
                Task { @MainActor in self?.noteModelDownloading() }
            })

            let result = try await summarizer.summarize(
                transcript: transcript,
                attendees: attendees,
                title: title,
                date: dateString
            )

            try writer.writeActions(result.summary.actionItems)
            try writer.writeNotes(NotesRenderer.render(result.summary, dateString: dateString))
            try await persistActions(meetingID: meetingID, actions: result.summary.actionItems)

            if result.degraded {
                try? await database.setError(
                    meetingID: meetingID,
                    message: "Summary degraded: model JSON could not be parsed; summary-only result written."
                )
            }

            try await stateMachine.transition(meeting: meetingID, to: .summarized)
            logger.info("summarized \(eventID, privacy: .public): \(result.summary.actionItems.count, privacy: .public) actions, degraded=\(result.degraded, privacy: .public)")
            await exportMeeting(meetingID: meetingID, eventID: eventID)
        } catch {
            logger.error("summarization failed for \(eventID, privacy: .public): \(error, privacy: .public)")
            // Don't lose the recording: export the transcript with a note that the
            // summary couldn't be generated.
            await finalizeWithoutSummary(
                meetingID: meetingID,
                eventID: eventID,
                writer: writer,
                title: title,
                dateString: dateString,
                note: "_A summary couldn't be generated for this meeting. The full transcript is included below._",
                failureReason: String(describing: error)
            )
        }
    }

    /// Write a minimal note (no LLM summary), advance `diarized → summarized`,
    /// and export — so a completed recording always lands a note in the output
    /// folder even when summarization can't run.
    private func finalizeWithoutSummary(
        meetingID: Int64,
        eventID: String,
        writer: ArtifactWriter,
        title: String,
        dateString: String,
        note: String,
        failureReason: String?
    ) async {
        do {
            var markdown = "# \(title)\n\n"
            if !dateString.isEmpty { markdown += "\(dateString)\n\n" }
            markdown += "\(note)\n"
            try writer.writeNotes(markdown)
            try writer.writeActions([])

            if let failureReason {
                try? await database.setError(meetingID: meetingID, message: "Summary unavailable: \(failureReason)")
            }

            // Only the diarized → summarized step is legal here; if a prior run
            // already advanced the meeting, skip straight to export.
            if (try? await database.meetingState(id: meetingID)) == .diarized {
                try await stateMachine.transition(meeting: meetingID, to: .summarized)
            }
            await exportMeeting(meetingID: meetingID, eventID: eventID)
        } catch {
            logger.error("failed to finalize note for \(eventID, privacy: .public): \(error, privacy: .public)")
            try? await database.setError(meetingID: meetingID, message: String(describing: error))
            noteStageFailed(eventID: eventID, stage: "writing notes")
        }
    }

    // MARK: - Export & sharing

    /// Copy the rendered artifacts into the user's output folder and advance
    /// `summarized → exported`. Posts a notification whose banner/Reveal action
    /// opens the notes folder in Finder.
    private func exportMeeting(meetingID: Int64, eventID: String) async {
        processingMessage = "Exporting…"
        do {
            guard let meeting = try await database.meeting(id: meetingID) else { return }
            let dir = try performExport(meeting: meeting, eventID: eventID)
            try await database.setExportPath(meetingID: meetingID, path: dir.path)
            try await stateMachine.transition(meeting: meetingID, to: .exported)
            lastExportedMeetingID = meetingID
            lastExportURL = dir
            if deleteAudioAfterExport {
                removeRawAudio(eventID: eventID)
            }
            notifyExported(title: meeting.title, dir: dir)
            logger.info("exported \(eventID, privacy: .public) → \(dir.lastPathComponent, privacy: .private)")
        } catch {
            logger.error("export failed for \(eventID, privacy: .public): \(error, privacy: .public)")
            try? await database.setError(meetingID: meetingID, message: String(describing: error))
            noteStageFailed(eventID: eventID, stage: "exporting")
        }
    }

    /// Write the four artifacts to the output folder, reusing the meeting's
    /// existing export directory on a re-export (e.g. after a reassignment).
    @discardableResult
    private func performExport(meeting: Meeting, eventID: String) throws -> URL {
        let workingDir = Self.recordingDir(for: eventID)
        let root = outputFolderStore.folder()
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = meeting.exportPath.map { URL(fileURLWithPath: $0) }
        return try FileExporter(outputRoot: root).export(
            title: meeting.title,
            date: meeting.start,
            workingDir: workingDir,
            existingExportDir: existing
        )
    }

    /// Delete a meeting's raw audio once its notes are safely exported
    /// (retention opt-in). Transcripts and notes are kept; the Review popover's
    /// voice snippets become unavailable for this meeting.
    private func removeRawAudio(eventID: String) {
        let dir = Self.recordingDir(for: eventID)
        for name in ["mic.caf", "system.caf"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        logger.info("raw audio removed after export for \(eventID, privacy: .public)")
    }

    private func notifyExported(title: String, dir: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Notes ready"
        content.body = "\(title) — saved to your notes folder."
        content.categoryIdentifier = NotificationActionHandler.exportCategoryID
        content.userInfo = [NotificationActionHandler.pathKey: dir.path]
        let request = UNNotificationRequest(identifier: "export-\(dir.lastPathComponent)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Surface a pipeline-stage failure: error icon + a notification, so a
    /// failed meeting never disappears silently. The state was not advanced,
    /// so the launch-time resume scan retries it.
    private func noteStageFailed(eventID: String, stage: String) {
        status = .error
        let content = UNMutableNotificationContent()
        content.title = "Notes failed"
        content.body = "Scribe couldn't finish \(stage) for this meeting. "
            + "The recording is kept and will be retried the next time Scribe starts."
        let request = UNNotificationRequest(identifier: "failed-\(eventID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyConsentRequired() {
        let content = UNMutableNotificationContent()
        content.title = "Recording paused"
        content.body = "Open Scribe and acknowledge the recording notice to enable recording."
        let request = UNNotificationRequest(identifier: "consent-required", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Reveal an exported meeting's notes folder in Finder.
    func revealExport(meetingID: Int64) async {
        guard let meeting = try? await database.meeting(id: meetingID), let path = meeting.exportPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Open a pre-addressed email draft of an exported meeting's notes.
    func shareNotes(meetingID: Int64) async {
        guard let meeting = try? await database.meeting(id: meetingID), let path = meeting.exportPath else { return }
        let dir = URL(fileURLWithPath: path)
        let body = (try? String(contentsOf: dir.appendingPathComponent(ArtifactWriter.notesName), encoding: .utf8)) ?? ""
        let attendees = (try? await database.attendees(forMeeting: meetingID)) ?? []
        let emails = attendees.compactMap { $0.role == "self" ? nil : $0.email }
        let draft = Sharer.makeDraft(
            title: meeting.title,
            date: meeting.start,
            attendeeEmails: emails,
            notesBody: body,
            transcriptURL: includeTranscriptInEmail ? dir.appendingPathComponent("transcript.txt") : nil
        )
        Sharer.share(draft)
    }

    // MARK: - Output folder settings

    var outputFolderDisplayPath: String {
        (outputFolderStore.folder().path as NSString).abbreviatingWithTildeInPath
    }

    /// Present a directory picker and persist the chosen output folder.
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = outputFolderStore.folder()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolderStore.setFolder(url)
    }

    func revealOutputFolder() {
        let url = outputFolderStore.folder()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Permission overview

    /// Refresh all permission statuses for the Settings overview. Mic/Calendar
    /// read their TCC status directly; system audio has no status API so it's
    /// probed (which also triggers its prompt the first time).
    func refreshPermissions() async {
        microphonePermission = Self.mapAVStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        if microphonePermission == .granted, microphoneAccessDenied {
            // The mic-denied error is resolved — stop showing the error icon.
            microphoneAccessDenied = false
            if status == .error, !isRecording {
                status = nextMeeting == nil ? .idle : .upcoming
            }
        }
        if calendarService.isAuthorized {
            calendarPermission = .granted
        } else {
            calendarPermission = calendarService.isDenied ? .denied : .unknown
        }
        calendarAuthorized = calendarPermission == .granted
        systemAudioPermission = await requestSystemAudioAccess() ? .granted : .denied
    }

    private static func mapAVStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Settings "Grant" for microphone: prompt if undetermined, else open Settings.
    func grantMicrophonePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: openMicrophoneSettings()
        default: break
        }
        await refreshPermissions()
    }

    /// Settings "Grant" for system audio: probe (prompts first time), else Settings.
    func grantSystemAudioPermission() async {
        let granted = await requestSystemAudioAccess()
        if !granted, systemAudioPermission == .denied { openSystemAudioSettings() }
        await refreshPermissions()
    }

    /// Settings "Grant" for calendar: prompt if undetermined, else open Settings.
    func grantCalendarPermission() async {
        if calendarService.isDenied {
            openCalendarSettings()
        } else {
            await grantCalendarAccess()
        }
        await refreshPermissions()
    }

    /// Open System Settings → Privacy & Security → Calendars.
    func openCalendarSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Model pre-download

    /// Download every on-device model Scribe needs up front (ASR; plus the MLX
    /// summary model when that backend is selected). Drives the onboarding
    /// progress UI. Idempotent and safe to re-run.
    func downloadModels() async {
        guard !isDownloadingModels else { return }
        isDownloadingModels = true
        modelDownloadError = nil
        modelDownloadProgress = 0
        defer {
            isDownloadingModels = false
            modelDownloadProgress = nil
        }
        do {
            try await asrEngine.prepareModels(progress: { [weak self] fraction in
                Task { @MainActor in self?.modelDownloadProgress = fraction }
            })
            if summarizationBackend == .mlxGemma {
                let summarizer = Summarizer(client: SummarizerClientFactory.makeClient(backend: .mlxGemma))
                try await summarizer.prepareModel(progress: { [weak self] fraction in
                    Task { @MainActor in self?.modelDownloadProgress = fraction }
                })
            }
            modelsReady = true
            logger.info("model pre-download complete")
        } catch {
            logger.error("model pre-download failed: \(error, privacy: .public)")
            modelDownloadError = String(describing: error)
        }
    }

    // MARK: - Onboarding & permissions

    /// Request microphone access; returns whether it was granted.
    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Confirm microphone access before recording, prompting the first time.
    /// Returns `false` when access is denied/restricted — the caller surfaces a
    /// "turn it on in Settings" path, since macOS won't prompt again.
    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Open System Settings → Privacy & Security → Microphone.
    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Confirm system-audio capture before recording. Never blocks: a failed
    /// probe just means we record mic-only and surface a fix path. Probing also
    /// triggers the macOS "Audio Recording" prompt the first time.
    private func ensureSystemAudioAccess() async {
        guard !systemAudioConfirmed else { return }
        let granted = await requestSystemAudioAccess()
        systemAudioConfirmed = granted
        systemAudioAccessDenied = !granted
        if !granted {
            logger.info("system audio capture unavailable — recording mic-only")
        }
    }

    /// Open System Settings → Privacy & Security → Audio Recording (the
    /// process-tap permission that captures other participants' audio).
    func openSystemAudioSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func notifyMicrophoneRequired() {
        let content = UNMutableNotificationContent()
        content.title = "Microphone access needed"
        content.body = "Scribe couldn't record — enable microphone access in System Settings › Privacy & Security › Microphone."
        let request = UNNotificationRequest(identifier: "microphone-required", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Trigger the system-audio TCC prompt by briefly creating and tearing down
    /// a process tap. Returns whether a tap could be established.
    func requestSystemAudioAccess() async -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        return await Task.detached {
            do {
                let tap = try SystemAudioTapFactory.create(name: "ScribePermissionProbe")
                SystemAudioTapFactory.destroy(tap)
                return true
            } catch {
                return false
            }
        }.value
    }

    /// Record that the user acknowledged the recording-consent notice.
    func acknowledgeConsent() {
        hasAcknowledgedConsent = true
        UserDefaults.standard.set(true, forKey: Self.consentKey)
    }

    /// Mark first-launch onboarding complete.
    func completeOnboarding() {
        needsOnboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
    }

    private func persistActions(meetingID: Int64, actions: [ExtractedAction]) async throws {
        let rows = actions.map {
            ActionItem(id: nil, meetingID: meetingID, owner: $0.owner, task: $0.task, due: nil, done: $0.done)
        }
        try await database.replaceActions(meetingID: meetingID, actions: rows)
    }

    private func orderedSpeakerLabels(_ diarized: [DiarizedSegment]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for segment in diarized.sorted(by: { $0.start < $1.start }) where seen.insert(segment.speakerLabel).inserted {
            labels.append(segment.speakerLabel)
        }
        return labels
    }

    private func persistSpeakers(meetingID: Int64, assignments: [SpeakerAssignment]) async throws {
        let rows = assignments.map {
            Speaker(
                id: nil,
                meetingID: meetingID,
                label: $0.speakerLabel,
                assignedAttendee: $0.attendeeEmail,
                confidence: $0.confidence.score,
                provenance: $0.provenance.rawValue
            )
        }
        try await database.replaceSpeakers(meetingID: meetingID, speakers: rows)
    }

    private func cacheReviewScratch(
        meetingID: Int64,
        embeddings: [String: [Float]],
        diarized: [DiarizedSegment],
        transcript: Transcript
    ) {
        meetingEmbeddings[meetingID] = embeddings
        reviewScratchOrder.removeAll { $0 == meetingID }
        reviewScratchOrder.append(meetingID)
        while reviewScratchOrder.count > reviewScratchLimit {
            let evicted = reviewScratchOrder.removeFirst()
            meetingEmbeddings.removeValue(forKey: evicted)
            meetingSnippets.removeValue(forKey: evicted)
        }
        var snippets: [String: (channel: TranscriptChannel, start: TimeInterval)] = [:]
        snippets[Self.localUserLabel] = (.mic, transcript.segments.first { $0.channel == .mic }?.start ?? 0)
        for segment in diarized.sorted(by: { $0.start < $1.start }) where snippets[segment.speakerLabel] == nil {
            snippets[segment.speakerLabel] = (.system, segment.start)
        }
        meetingSnippets[meetingID] = snippets
    }

    private func displayNameResolver(
        assignments: [SpeakerAssignment],
        nameForEmail: [String: String]
    ) -> (String) -> String {
        let emailForLabel = Dictionary(assignments.map { ($0.speakerLabel, $0.attendeeEmail) }, uniquingKeysWith: { first, _ in first })
        return { label in
            if let email = emailForLabel[label] ?? nil, let name = nameForEmail[email] {
                return name
            }
            return label == Self.localUserLabel ? "You" : label
        }
    }

    private func warnUnsupportedLanguage(eventID: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcript may be unreliable"
        content.body = "Scribe's transcriber had low confidence — the meeting language may not be supported."
        let request = UNNotificationRequest(identifier: "lang-\(eventID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func warnZeroSystemAudio(target: RecordingTarget) {
        logger.error("zero system audio energy for \(target.eventID, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = "No system audio detected"
        content.body = "Scribe isn't hearing other participants. Check that your meeting app uses the default output device."
        let request = UNNotificationRequest(identifier: "zero-energy-\(target.eventID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Speaker review

    /// Build the data the Review popover binds to for a meeting.
    func reviewData(meetingID: Int64) async -> ReviewData? {
        guard let meeting = try? await database.meeting(id: meetingID),
              let speakers = try? await database.speakers(forMeeting: meetingID),
              let attendees = try? await database.attendees(forMeeting: meetingID)
        else { return nil }

        let snippets = meetingSnippets[meetingID] ?? [:]
        let items = speakers.compactMap { speaker -> SpeakerReviewItem? in
            guard let id = speaker.id else { return nil }
            return SpeakerReviewItem(
                id: id,
                label: speaker.label,
                assignedEmail: speaker.assignedAttendee,
                confidence: SpeakerConfidence(score: speaker.confidence ?? 0),
                provenance: SpeakerProvenance(rawValue: speaker.provenance ?? "") ?? .unassigned,
                hasSnippet: snippets[speaker.label] != nil
            )
        }
        let named = attendees.compactMap { attendee -> NamedAttendee? in
            guard let email = attendee.email else { return nil }
            return NamedAttendee(name: attendee.name, email: email)
        }
        return ReviewData(meetingID: meetingID, meetingTitle: meeting.title, speakers: items, attendees: named)
    }

    /// Reassign a speaker to an attendee (or clear it), re-render `transcript.txt`,
    /// and update voice enrollment if enabled.
    func reassignSpeaker(meetingID: Int64, speakerID: Int64, toEmail: String?) async {
        do {
            try await database.updateSpeakerAssignment(
                speakerID: speakerID,
                attendeeEmail: toEmail,
                confidence: SpeakerConfidence.high.score,
                provenance: SpeakerProvenance.manual.rawValue
            )

            let speakers = try await database.speakers(forMeeting: meetingID)
            let attendees = try await database.attendees(forMeeting: meetingID)
            let nameForEmail = Dictionary(
                attendees.compactMap { a in a.email.map { ($0, a.name) } },
                uniquingKeysWith: { first, _ in first }
            )
            let emailForLabel = Dictionary(
                speakers.map { ($0.label, $0.assignedAttendee) },
                uniquingKeysWith: { first, _ in first }
            )
            let resolver: (String) -> String = { label in
                if let email = emailForLabel[label] ?? nil, let name = nameForEmail[email] { return name }
                return label == Self.localUserLabel ? "You" : label
            }

            if let meeting = try await database.meeting(id: meetingID) {
                let dir = Self.recordingDir(for: meeting.eventID)
                try ArtifactWriter(meetingDir: dir).rewriteAfterReassignment(displayName: resolver)
                // If the meeting was already exported, refresh the user-facing
                // copy so the corrected names appear there too.
                if meeting.state == .exported {
                    _ = try? performExport(meeting: meeting, eventID: meeting.eventID)
                }
            }

            // Enrollment: learn this voice once the user confirms a name.
            if rememberVoices, let email = toEmail,
               let label = speakers.first(where: { $0.id == speakerID })?.label,
               let embedding = meetingEmbeddings[meetingID]?[label],
               let name = nameForEmail[email] {
                await voiceStore.enroll(email: email, name: name, embedding: embedding)
            }
            logger.info("reassigned speaker \(speakerID, privacy: .public) → \(toEmail ?? "unassigned", privacy: .private)")
        } catch {
            logger.error("reassign failed: \(error, privacy: .public)")
        }
    }

    /// Play the ~5 s preview snippet for a speaker.
    func playSnippet(meetingID: Int64, speakerID: Int64) async {
        guard let speakers = try? await database.speakers(forMeeting: meetingID),
              let speaker = speakers.first(where: { $0.id == speakerID }),
              let snippet = meetingSnippets[meetingID]?[speaker.label],
              let meeting = try? await database.meeting(id: meetingID)
        else { return }

        let dir = Self.recordingDir(for: meeting.eventID)
        let file = dir.appendingPathComponent(snippet.channel == .mic ? "mic.caf" : "system.caf")
        guard let snippetURL = AudioSnippet.extract(from: file, start: snippet.start) else { return }
        // Snippets are throwaway temp files — clean up the previous one.
        if let previous = lastSnippetURL {
            try? FileManager.default.removeItem(at: previous)
        }
        lastSnippetURL = snippetURL
        snippetPlayer = try? AVAudioPlayer(contentsOf: snippetURL)
        snippetPlayer?.play()
    }

    func deleteVoiceProfiles() async {
        await voiceStore.deleteAll()
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
}
