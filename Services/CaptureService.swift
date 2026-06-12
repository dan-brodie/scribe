// SPDX-License-Identifier: MIT

import AVFoundation
import CoreAudio
import Foundation

/// What to record: a scheduled meeting (with an end time) or a manual session.
struct RecordingTarget: Sendable, Equatable {
    var eventID: String
    var scheduledEnd: Date?
    var meetingID: Int64?

    var isManual: Bool { scheduledEnd == nil }
}

/// Owns the dual-channel capture pipeline: microphone via `AVAudioEngine` and
/// system audio via a Core Audio process tap, each written to its own crash-safe
/// `.caf`. A stop-condition loop ends the session on grace period, sustained
/// silence, or manual stop. Degrades to mic-only if the system tap is
/// unavailable.
actor CaptureService {
    enum State: Sendable, Equatable {
        case idle
        case recording(eventID: String)
    }

    private(set) var state: State = .idle

    private let recordingsRoot: URL
    private let silenceDetector: SilenceDetector
    private let timing: CaptureTiming
    private let logger = Log.make("CaptureService")

    /// Called when a recording finishes (any reason). Set by the coordinator to
    /// drive the state machine.
    var onStop: (@Sendable (StopReason, RecordingTarget) -> Void)?
    /// Called once if the system channel stays silent past the warning delay.
    var onZeroEnergyWarning: (@Sendable (RecordingTarget) -> Void)?

    // Active-session state.
    private var target: RecordingTarget?
    private var startedAt: Date?
    private var monitor: StopConditionMonitor?
    private var micEngine: AVAudioEngine?
    private var systemEngine: AVAudioEngine?
    private var systemTapIDs: (tap: AudioObjectID, aggregate: AudioObjectID)?
    private var monitorTask: Task<Void, Never>?
    private var deviceListener: DeviceChangeListener?

    private var recentMic: [Float] = []
    private var recentSystem: [Float] = []
    private var sawSystemAudio = false
    private var zeroEnergyWarned = false

    /// ~2 s of recent audio kept per channel for the speech check.
    private let recentWindowSamples = 16_000 * 2

    init(
        recordingsRoot: URL,
        silenceDetector: SilenceDetector,
        timing: CaptureTiming = .default
    ) {
        self.recordingsRoot = recordingsRoot
        self.silenceDetector = silenceDetector
        self.timing = timing
    }

    func setHandlers(
        onStop: (@Sendable (StopReason, RecordingTarget) -> Void)? = nil,
        onZeroEnergyWarning: (@Sendable (RecordingTarget) -> Void)? = nil
    ) {
        self.onStop = onStop
        self.onZeroEnergyWarning = onZeroEnergyWarning
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Directory for a given event's recordings.
    func recordingDirectory(for eventID: String) -> URL {
        recordingsRoot.appendingPathComponent(eventID, isDirectory: true)
    }

    // MARK: - Lifecycle

    func startRecording(for target: RecordingTarget) async throws {
        guard case .idle = state else {
            logger.error("startRecording ignored: already recording")
            return
        }

        let dir = recordingDirectory(for: target.eventID)
        let micWriter = AudioWriter(url: dir.appendingPathComponent("mic.caf"))
        let systemWriter = AudioWriter(url: dir.appendingPathComponent("system.caf"))
        try await micWriter.open()
        try await systemWriter.open()
        self.micWriter = micWriter
        self.systemWriter = systemWriter

        let now = Date()
        self.target = target
        self.startedAt = now
        self.monitor = StopConditionMonitor(timing: timing, scheduledEnd: target.scheduledEnd, startedAt: now)
        self.recentMic = []
        self.recentSystem = []
        self.sawSystemAudio = false
        self.zeroEnergyWarned = false

        try startMicEngine()
        do {
            try startSystemEngine()
        } catch {
            // System audio is best-effort: a tap failure must not abort the
            // (often more important) mic recording.
            logger.error("system audio capture unavailable: \(error, privacy: .public); continuing mic-only")
        }

        startDeviceChangeMonitoring()
        state = .recording(eventID: target.eventID)
        monitorTask = Task { await self.runMonitorLoop() }
        logger.info("recording started for \(target.eventID, privacy: .public)")
    }

    /// Stop and finalize the recording.
    func stopRecording(reason: StopReason = .manual) async {
        guard case .recording = state else { return }
        await teardown()
        let finished = target
        state = .idle
        logger.info("recording stopped (\(reason.rawValue, privacy: .public)) for \(finished?.eventID ?? "?", privacy: .public)")
        clearSession()
        if let finished {
            onStop?(reason, finished)
        }
    }

    /// Stop and delete the recording's files (user pressed Discard).
    func discardRecording() async {
        guard case .recording = state else { return }
        let dir = target.map { recordingDirectory(for: $0.eventID) }
        await teardown()
        state = .idle
        clearSession()
        if let dir {
            try? FileManager.default.removeItem(at: dir)
            logger.info("recording discarded: \(dir.lastPathComponent, privacy: .public)")
        }
    }

    private var micWriter: AudioWriter?
    private var systemWriter: AudioWriter?

    private func teardown() async {
        monitorTask?.cancel()
        monitorTask = nil
        deviceListener?.cancel()
        deviceListener = nil

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        systemEngine?.inputNode.removeTap(onBus: 0)
        systemEngine?.stop()
        systemEngine = nil
        destroySystemTap()

        await micWriter?.close()
        await systemWriter?.close()
    }

    private func clearSession() {
        micWriter = nil
        systemWriter = nil
        target = nil
        startedAt = nil
        monitor = nil
        recentMic = []
        recentSystem = []
        sawSystemAudio = false
        zeroEnergyWarned = false
    }

    // MARK: - Engines

    private func startMicEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = AudioResampler(inputFormat: format) else { throw CaptureError.unsupportedFormat }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let samples = resampler.resampleToSamples(buffer) else { return }
            Task { await self.ingestMic(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        micEngine = engine
    }

    private func startSystemEngine() throws {
        guard #available(macOS 14.4, *) else { throw CaptureError.tapCreationFailed(-1) }

        let tap = try SystemAudioTapFactory.create()
        systemTapIDs = (tap.tapID, tap.aggregateDeviceID)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else {
            destroySystemTap()
            throw CaptureError.engineStartFailed("input node has no audio unit")
        }

        var deviceID = tap.aggregateDeviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            destroySystemTap()
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }

        let format = input.outputFormat(forBus: 0)
        guard let resampler = AudioResampler(inputFormat: format) else {
            destroySystemTap()
            throw CaptureError.unsupportedFormat
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let samples = resampler.resampleToSamples(buffer) else { return }
            Task { await self.ingestSystem(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            destroySystemTap()
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        systemEngine = engine
    }

    private func destroySystemTap() {
        guard let ids = systemTapIDs else { return }
        if #available(macOS 14.4, *) {
            AudioHardwareDestroyAggregateDevice(ids.aggregate)
            AudioHardwareDestroyProcessTap(ids.tap)
        }
        systemTapIDs = nil
    }

    // MARK: - Ingest

    private func ingestMic(_ samples: [Float]) async {
        guard case .recording = state else { return }
        append(samples, to: &recentMic)
        try? await micWriter?.writeSamples(samples)
    }

    private func ingestSystem(_ samples: [Float]) async {
        guard case .recording = state else { return }
        append(samples, to: &recentSystem)
        if AudioEnergy.rms(samples) > 1e-4 {
            sawSystemAudio = true
        }
        try? await systemWriter?.writeSamples(samples)
    }

    private func append(_ samples: [Float], to buffer: inout [Float]) {
        buffer.append(contentsOf: samples)
        if buffer.count > recentWindowSamples {
            buffer.removeFirst(buffer.count - recentWindowSamples)
        }
    }

    // MARK: - Stop-condition loop

    private func runMonitorLoop() async {
        while case .recording = state {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                break
            }
            await tick(now: Date())
        }
    }

    /// One evaluation step. `now` is injectable for completeness; production
    /// passes the wall clock.
    private func tick(now: Date) async {
        guard case .recording = state, var monitor, let target, let startedAt else { return }

        // Zero-energy (device-mismatch) detection on the system channel.
        if !sawSystemAudio,
           !zeroEnergyWarned,
           now.timeIntervalSince(startedAt) >= timing.zeroEnergyWarningDelay {
            zeroEnergyWarned = true
            logger.error("system channel silent after \(Int(self.timing.zeroEnergyWarningDelay))s — likely output device mismatch")
            onZeroEnergyWarning?(target)
        }

        let mic = recentMic
        let system = recentSystem
        recentMic.removeAll(keepingCapacity: true)
        recentSystem.removeAll(keepingCapacity: true)

        let micSpeech = mic.isEmpty ? false : await silenceDetector.containsSpeech(mic)
        let systemSpeech = system.isEmpty ? false : await silenceDetector.containsSpeech(system)
        let isSpeech = micSpeech || systemSpeech

        let decision = monitor.evaluate(now: now, isSpeech: isSpeech)
        self.monitor = monitor

        if case let .stop(reason) = decision {
            await stopRecording(reason: reason)
        }
    }

    // MARK: - Device changes (AirPods / default output switch)

    private func startDeviceChangeMonitoring() {
        deviceListener = DeviceChangeListener { [weak self] in
            Task { await self?.handleDeviceChange() }
        }
    }

    /// Recreate the system tap when the default output device changes mid-session
    /// (e.g. AirPods connect/disconnect) so we keep capturing the active device.
    private func handleDeviceChange() async {
        guard case .recording = state else { return }
        logger.info("output device changed — recreating system tap")
        systemEngine?.inputNode.removeTap(onBus: 0)
        systemEngine?.stop()
        systemEngine = nil
        destroySystemTap()
        do {
            try startSystemEngine()
        } catch {
            logger.error("failed to rebind system tap after device change: \(error, privacy: .public); mic-only")
        }
    }
}

/// Listens for default-output-device changes via Core Audio and invokes a
/// handler. Kept separate so `CaptureService` stays focused.
final class DeviceChangeListener {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init(_ handler: @escaping @Sendable () -> Void) {
        self.block = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        installed = status == noErr
    }

    func cancel() {
        guard installed else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        installed = false
    }
}
