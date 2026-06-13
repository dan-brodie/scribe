// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// Extracts a short slice of a recording for preview playback in the Review
/// popover.
enum AudioSnippet {
    /// Write a `[start, start+duration)` slice of `sourceURL` to a temp `.caf`
    /// and return its URL, or nil on failure.
    static func extract(from sourceURL: URL, start: TimeInterval, duration: TimeInterval = 5) -> URL? {
        guard let file = try? AVAudioFile(forReading: sourceURL) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, start) * sampleRate)
        guard startFrame < file.length else { return nil }

        let frameCount = AVAudioFrameCount(min(duration * sampleRate, Double(file.length - startFrame)))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: frameCount)
        } catch {
            return nil
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-snippet-\(UUID().uuidString).caf")
        guard let out = try? AVAudioFile(
            forWriting: outURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else { return nil }
        try? out.write(from: buffer)
        return outURL
    }
}
