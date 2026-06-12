# FluidAudio — Local API Reference

**Repo:** https://github.com/FluidInference/FluidAudio
**License:** Apache-2.0
**Latest:** v0.13.6 (Apr 2026)

## SPM Dependency

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
// target dependency:
.product(name: "FluidAudio", package: "FluidAudio")
```

**Minimum:** macOS 14+ / iOS 17+, Swift 6.0+

## Audio Format

All modules require **16 kHz mono Float32**. Convert with:

```swift
let samples: [Float] = try AudioConverter.resampleAudioFile(path: "/path/to/file.wav")
let samples: [Float] = try AudioConverter.resampleBuffer(avAudioPCMBuffer)
```

---

## ASR (Automatic Speech Recognition)

### Batch — `AsrManager`

```swift
let models = try await AsrModels.downloadAndLoad(version: .v3)  // multilingual
let manager = AsrManager(models: models)

let result = try await manager.transcribe(audioSamples, source: .microphone)
// result.text     — full transcript string
// result.segments — [ASRSegment] with start/end timestamps
```

`source:` is `.microphone` or `.system` — affects internal processing hints.

Model versions: `.v3` (multilingual, 25 languages), `.v2` (English only, faster).

### Streaming — `StreamingEouAsrManager`

```swift
let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
try await manager.loadModels(modelDir: modelsURL)

for chunk in audioChunks {
    _ = try await manager.process(audioBuffer: chunk)
}
let transcript = try await manager.finish()
await manager.reset()  // reuse for next utterance
```

Chunk sizes: `.ms160` (~8% WER, lowest latency), `.ms320` (~5% WER, balanced), `.ms1600` (highest throughput).

---

## Speaker Diarization

### Batch — `OfflineDiarizerManager` (recommended for post-meeting)

```swift
let manager = OfflineDiarizerManager()
try await manager.prepareModels(directory: bundleDir)

let result = try await manager.process(audio: audioSamples)
// result.timeline.speakers — [Speaker] with segments
```

For large files (streaming load):
```swift
let result = try await manager.process(audioSource: streamingSource, audioLoadingSeconds: 60.0)
```

Speaker management on the timeline:
```swift
timeline.upsertSpeaker(named: "Alice", atIndex: 0)
timeline.upsertSpeaker(_: speaker, atIndex: 1, transferCurrentSegment: true)
timeline.removeSpeaker(atIndex: 0, clearCurrentSegment: true)
```

### Streaming — `SortformerDiarizer` (≤4 speakers, 80ms frames)

```swift
let diarizer = SortformerDiarizer(config: .default)   // or .fastV2_1, .balancedV2_1
try await diarizer.initialize(mainModelPath: modelURL)

diarizer.addAudio(samples, sourceSampleRate: 16000)
if let update = diarizer.process() {
    let speakers = diarizer.timeline.speakers
}
diarizer.finalizeSession()
```

### Streaming — `LSEENDDiarizer` (up to 10 speakers, 100ms frames)

```swift
let diarizer = try await LSEENDDiarizer(variant: .dihard3)
diarizer.addAudio(samples, sourceSampleRate: 8000)
if let update = diarizer.process() { /* timeline update */ }
diarizer.finalizeSession()
```

### `DiarizerManager` (Pyannote 3.1-style, modular)

```swift
let diarizer = DiarizerManager()
let result = try diarizer.performCompleteDiarization(audioSamples, sampleRate: 16000)
```

---

## Voice Activity Detection

### `VadManager`

```swift
let config = VadConfig(
    defaultThreshold: 0.85,   // 0.7–0.9 clean audio, 0.3–0.6 noisy
    debugMode: false,
    computeUnits: .cpuAndNeuralEngine
)
let manager = VadManager(config: config)

let results = try await manager.process(audioSamples)         // [Float]
// or:       try await manager.process(audioFileURL)          // URL
// or:       try await manager.process(audioBuffer)           // AVAudioPCMBuffer

for r in results {
    // r.isSpeech: Bool, r.confidence: Float
}
```

Constants: `VadManager.chunkSize = 4096` (256ms @ 16kHz), `VadManager.sampleRate = 16000`

---

## Model Registry

```swift
// Override download URL (default: Hugging Face)
ModelRegistry.baseURL = "https://your-mirror.example.com"
// Or set env vars: REGISTRY_URL / MODEL_REGISTRY_URL
```

Models auto-download on first use. Priority: code override → env vars → Hugging Face.

---

## Performance Notes

- Real-time factor: ~190× on M4 Pro (batch), effectively real-time for streaming
- Runs on Apple Neural Engine — low power draw, suitable for always-on app
- All managers are thread-safe and support concurrent usage
