// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// Converts arbitrary-format capture buffers to the app's canonical
/// 16 kHz mono Float32, used for both file output and VAD.
///
/// Not thread-safe on its own; each capture engine owns one instance and only
/// calls it from that engine's tap callback thread.
final class AudioResampler {
    private let converter: AVAudioConverter
    let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat) {
        guard let output = AudioWriter.captureFormat(),
              let converter = AVAudioConverter(from: inputFormat, to: output)
        else { return nil }
        self.outputFormat = output
        self.converter = converter
    }

    /// Resample into a fresh 16 kHz mono buffer, or `nil` on failure.
    func resample(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Resample and flatten to a mono sample array.
    func resampleToSamples(_ input: AVAudioPCMBuffer) -> [Float]? {
        guard let buffer = resample(input), let channel = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
