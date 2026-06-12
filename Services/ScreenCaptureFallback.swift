// SPDX-License-Identifier: MIT

// ScreenCaptureKit fallback for system-audio capture on hosts where the Core
// Audio process tap is unavailable. Compiled only when SCREENCAPTURE_FALLBACK
// is defined; the default build uses `SystemAudioTap` instead (ADR-002), which
// avoids the "Screen & System Audio Recording" TCC prompt.

#if SCREENCAPTURE_FALLBACK
import AVFoundation
import Foundation
import ScreenCaptureKit

@available(macOS 13.0, *)
final class ScreenCaptureSystemAudio: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let onSamples: @Sendable ([Float]) -> Void
    private let logger = Log.make("ScreenCaptureFallback")

    init(onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.onSamples = onSamples
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.tapCreationFailed(-1)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        self.stream = stream
        logger.info("ScreenCaptureKit audio capture started")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = Self.floatSamples(from: sampleBuffer), !samples.isEmpty else { return }
        onSamples(samples)
    }

    /// Extract mono Float32 samples from a PCM `CMSampleBuffer`.
    private static func floatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let data = audioBufferList.mBuffers.mData else { return nil }
        let count = Int(audioBufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let pointer = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}
#endif
