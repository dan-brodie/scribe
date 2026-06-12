# Core Audio Process Taps — Local API Reference

**API introduced:** macOS 14.4
**Framework:** CoreAudio (built-in)
**Reference:** https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
**Sample code:** https://github.com/insidegui/AudioCap

## Info.plist Requirement

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Scribe needs to record meeting audio from other apps to transcribe your meetings.</string>
```

This is an audio-only TCC permission — it does NOT trigger the "Screen & System Audio Recording" category that ScreenCaptureKit uses on macOS 13.

## Setup Pattern

```swift
import CoreAudio
import AVFoundation

func createSystemAudioTap() throws -> (tapID: AudioObjectID, aggregateDeviceID: AudioObjectID) {
    // 1. Create the tap description
    let tapDescription = CATapDescription(stereoMixdown: true)
    tapDescription.uuid = UUID()
    tapDescription.name = "ScribeSystemTap"
    tapDescription.muteBehavior = .unmuted       // CATapUnmuted
    tapDescription.exclusive = false             // share with other apps
    tapDescription.privateTap = false

    // 2. Create the process tap
    var tapID: AudioObjectID = kAudioObjectUnknown
    var tapDescription_ptr = tapDescription
    let status = AudioHardwareCreateProcessTap(&tapDescription_ptr, &tapID)
    guard status == noErr else { throw AudioError.tapCreationFailed(status) }

    // 3. Build aggregate device dict including the tap
    let aggregateDict: [String: Any] = [
        kAudioAggregateDeviceNameKey: "ScribeAggregate",
        kAudioAggregateDeviceUIDKey: "com.scribe.aggregate.\(UUID().uuidString)",
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: 1,
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString
        ]]
    ]

    // 4. Create the aggregate device
    var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
    guard aggStatus == noErr else { throw AudioError.aggregateDeviceCreationFailed(aggStatus) }

    return (tapID, aggregateDeviceID)
}
```

## Reading the Format & Attaching to AVAudioEngine

```swift
// 5. Read the tap's native format
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var asbd = AudioStreamBasicDescription()
AudioObjectGetPropertyData(
    tapID,
    &AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    ),
    0, nil, &formatSize, &asbd
)
let tapFormat = AVAudioFormat(streamDescription: &asbd)!

// 6. Install a tap on AVAudioEngine input node pointing at the aggregate device
let engine = AVAudioEngine()
// Set engine's input to the aggregate device, then:
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, time in
    // buffer contains mixed-down system audio at tapFormat sample rate
    // downsample to 16kHz Float32 for FluidAudio:
    let samples = try? AudioConverter.resampleBuffer(buffer)
}
```

## Teardown

```swift
AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
AudioHardwareDestroyProcessTap(tapID)
```

## Dual-Channel Recording Pattern

```swift
// Mic channel: standard AVAudioEngine mic input → write to mic.caf
// System channel: process tap aggregate → write to system.caf
// Both at 16kHz mono Float32
// Flush every ≤5 s (FR-11 crash-safety requirement)
```

## ScreenCaptureKit Fallback (macOS 13, behind flag)

```swift
#if SCREENCAPTURE_FALLBACK
import ScreenCaptureKit
// Use SCStream with audio-only configuration
// Permission appears under "Screen & System Audio Recording" in TCC
#endif
```

## Key Risks

- **Default output device mismatch:** if the meeting app outputs to a non-default device, the tap captures nothing. Detect by checking if system channel has non-zero RMS energy after 30s; warn user if silent.
- **Device changes mid-recording:** listen for `kAudioHardwarePropertyDevices` / `kAudioHardwarePropertyDefaultOutputDevice` notifications and recreate the tap.
- **macOS version gating:** `CATapDescription` requires macOS 14.4+; gate with `#available(macOS 14.4, *)`.
