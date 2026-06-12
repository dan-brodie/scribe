# mlx-swift-lm / MLXLLM — Local API Reference

**Repos:**
- https://github.com/ml-explore/mlx-swift (MLX runtime)
- https://github.com/ml-explore/mlx-swift-lm (LLM/VLM implementations)

**Licenses:** MIT

## SPM Dependencies

```swift
// Package.swift dependencies:
.package(url: "https://github.com/ml-explore/mlx-swift", from: "0.10.0"),
.package(url: "https://github.com/ml-explore/mlx-swift-lm/", branch: "main"),

// Target dependencies:
.product(name: "MLX",         package: "mlx-swift"),
.product(name: "MLXNN",       package: "mlx-swift"),
.product(name: "MLXLLM",      package: "mlx-swift-lm"),
.product(name: "MLXLMCommon", package: "mlx-swift-lm"),
```

**Minimum:** macOS 14+, Swift 6.0+, Apple Silicon (Metal GPU backend required for performance)

## Default Models

| Model | HF Repo | License | Size (4-bit) |
|-------|---------|---------|--------------|
| Qwen3-4B-Instruct (default) | `Qwen/Qwen3-4B-Instruct` | Apache-2.0 | ~2.5 GB |
| Llama-3.2-3B-Instruct (alt) | `meta-llama/Llama-3.2-3B-Instruct` | Llama 3.2 (permissive) | ~2 GB |

## Core Usage Pattern

```swift
import MLXLLM
import MLXLMCommon

// 1. Load model (async, downloads on first run)
let modelConfig = ModelConfiguration(id: "Qwen/Qwen3-4B-Instruct")
let container = try await LLMModelFactory.shared.loadContainer(configuration: modelConfig)

// 2. Generate text
let prompt = "Summarize this transcript:\n\n\(transcript)"
let result = try await container.perform { model, tokenizer in
    let input = try await tokenizer.encode(prompt)
    return try await generate(
        input: MLXArray(input),
        parameters: GenerateParameters(temperature: 0.1, maxTokens: 1024),
        model: model
    ) { token in
        // streaming callback (optional)
        return .more
    }
}
let output = tokenizer.decode(result.tokens)
```

## Chunked Map-Reduce for Long Transcripts

```swift
// Map phase: summarize each chunk
let chunkSize = 1800  // tokens (leave headroom in 2048-ctx model)
let chunks = transcript.splitIntoChunks(maxTokens: chunkSize, tokenizer: tokenizer)
let partialSummaries = try await chunks.asyncMap { chunk in
    try await summarize(chunk, prompt: Prompts.load("summarize-meeting-map"))
}

// Reduce phase: combine partial summaries
let finalSummary = try await summarize(
    partialSummaries.joined(separator: "\n---\n"),
    prompt: Prompts.load("summarize-meeting-reduce")
)
```

## JSON Output + Validation

```swift
// Prompt instructs the model to output JSON; parse and validate:
let raw = try await generate(prompt: Prompts.load("extract-actions") + transcript)

if let data = raw.data(using: .utf8),
   let actions = try? JSONDecoder().decode([ActionItem].self, from: data) {
    return actions
} else {
    // Retry once with repair prompt
    let repaired = try await generate(prompt: Prompts.load("repair-json") + raw)
    return try JSONDecoder().decode([ActionItem].self, from: repaired.data(using: .utf8)!)
}
```

## Performance Notes

- Peak memory for Qwen3-4B 4-bit: ~3–4 GB; hard cap target <6 GB including ASR models
- Throttle `maxTokens` and batch size on low-power mode (`ProcessInfo.processInfo.isLowPowerModeEnabled`)
- Model download is one-time; all subsequent inference is offline
