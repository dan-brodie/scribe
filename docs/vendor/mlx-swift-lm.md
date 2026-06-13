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

## Actual Integration (validated June 2026 — `Services/MLXLLMClient.swift`)

The simplified pattern below predates the current `main` API. As shipped,
mlx-swift-lm does **not** bundle a Hugging Face downloader/tokenizer — the
consumer must add two extra packages and load via the `MLXHuggingFace` macro:

```swift
// Extra SPM deps the app links (in addition to MLXLLM/MLXLMCommon/MLXHuggingFace):
//   huggingface/swift-transformers  ≥1.3.0  → product "Tokenizers"  (Apache-2.0)
//   huggingface/swift-huggingface   ≥0.9.0  → product "HuggingFace" (Apache-2.0)

import HuggingFace   // HubClient — required for the macro expansion
import Tokenizers     // AutoTokenizer — required for the macro expansion
import MLXHuggingFace

let container = try await #huggingFaceLoadModelContainer(
    configuration: ModelConfiguration(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
) { progress in /* progress.fractionCompleted */ }

let session = ChatSession(container, generateParameters: params) // params.maxTokens, .temperature
let text = try await session.respond(to: prompt)
```

Build/test require `xcodebuild -skipMacroValidation` (macro fingerprint gate);
the Makefile passes this.

## Core Usage Pattern (legacy reference)

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
