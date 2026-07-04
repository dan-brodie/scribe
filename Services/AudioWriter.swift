// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// Errors raised by the capture pipeline.
enum CaptureError: Error, CustomStringConvertible {
    case unsupportedFormat
    case writerNotOpen
    case alreadyRecording
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case engineStartFailed(String)

    var description: String {
        switch self {
        case .unsupportedFormat: return "could not create 16 kHz mono Float32 format"
        case .writerNotOpen: return "audio writer is not open"
        case .alreadyRecording: return "a recording is already in progress"
        case let .tapCreationFailed(status): return "process tap creation failed (\(status))"
        case let .aggregateDeviceCreationFailed(status): return "aggregate device creation failed (\(status))"
        case let .engineStartFailed(message): return "audio engine failed to start: \(message)"
        }
    }
}

/// Writes one channel of 16 kHz mono Float32 audio to a `.caf` file.
///
/// Buffers are written to disk on arrival (~256 ms chunks), so a crash loses
/// well under the 5 s budget — no separate flush timer is needed because
/// `AVAudioFile` persists each `write` incrementally.
actor AudioWriter {
    /// The canonical capture format for the whole app.
    static func captureFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    let url: URL
    private var file: AVAudioFile?
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(url: URL) {
        self.url = url
    }

    func open() throws {
        guard let format = Self.captureFormat() else { throw CaptureError.unsupportedFormat }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw CaptureError.writerNotOpen }
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    /// Convenience for already-resampled mono sample arrays (and tests).
    func writeSamples(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let format = Self.captureFormat(),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData
        else { throw CaptureError.unsupportedFormat }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel[0].update(from: base, count: samples.count)
            }
        }
        try write(buffer)
    }

    /// Finalize the file. `AVAudioFile` flushes its header on deinit.
    func close() {
        file = nil
    }

    var durationSeconds: Double {
        Double(framesWritten) / 16_000.0
    }
}
