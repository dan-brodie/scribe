// SPDX-License-Identifier: MIT

import AVFoundation
import CoreAudio
import Foundation

/// A live Core Audio process tap plus the aggregate device that exposes it to
/// `AVAudioEngine`. Capturing system audio this way uses only the audio-only
/// TCC permission (`NSAudioCaptureUsageDescription`) on macOS 14.4+, avoiding
/// the screen-recording prompt that ScreenCaptureKit triggers.
@available(macOS 14.4, *)
struct SystemAudioTap {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    let aggregateUID: String
    let format: AVAudioFormat
}

@available(macOS 14.4, *)
enum SystemAudioTapFactory {
    private static let logger = Log.make("SystemAudioTap")

    /// Create a global stereo-mixdown tap of all system audio and wrap it in a
    /// private aggregate device.
    static func create(name: String = "ScribeSystemTap") throws -> SystemAudioTap {
        let uuid = UUID()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = name
        description.uuid = uuid
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.isExclusive = false

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }

        let aggregateUID = "com.scribe.aggregate.\(uuid.uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(name)Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: 1,
                    kAudioSubTapUIDKey: uuid.uuidString,
                ],
            ],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.aggregateDeviceCreationFailed(aggregateStatus)
        }

        let format = try readTapFormat(tapID: tapID)
        logger.info("system tap created: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
        return SystemAudioTap(tapID: tapID, aggregateDeviceID: aggregateID, aggregateUID: aggregateUID, format: format)
    }

    static func readTapFormat(tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.tapCreationFailed(status)
        }
        return format
    }

    static func destroy(_ tap: SystemAudioTap) {
        AudioHardwareDestroyAggregateDevice(tap.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(tap.tapID)
    }
}
