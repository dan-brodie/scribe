// SPDX-License-Identifier: MIT

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// MLX-backed ``LLMClient`` (ADR-001). Loads a local 4-bit instruct model via
/// the Hugging Face downloader macros and answers each prompt with a fresh,
/// stateless ``ChatSession`` so map/reduce/repair calls never share KV cache.
///
/// The model is downloaded once on first use and all subsequent inference is
/// offline. Generation length is throttled under Low Power Mode (spec).
actor MLXLLMClient: PreparableLLMClient {
    /// Default model: Qwen3-4B Instruct, 4-bit, Apache-2.0 (CLAUDE.md). MLX
    /// requires MLX-format weights, hence the `mlx-community` mirror.
    static let defaultModelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    enum ClientError: Error, CustomStringConvertible {
        case notLoaded

        var description: String {
            switch self {
            case .notLoaded: return "LLM model is not loaded"
            }
        }
    }

    private let modelID: String
    private let temperature: Float
    /// Generation caps for normal and Low Power Mode.
    private let maxTokens: Int
    private let lowPowerMaxTokens: Int

    private var container: ModelContainer?
    private let logger = Log.make("MLXLLMClient")

    init(
        modelID: String = MLXLLMClient.defaultModelID,
        temperature: Float = 0.1,
        maxTokens: Int = 1024,
        lowPowerMaxTokens: Int = 512
    ) {
        self.modelID = modelID
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.lowPowerMaxTokens = lowPowerMaxTokens
    }

    /// Load (downloading on first run) the model weights. Safe to call repeatedly.
    func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if container != nil { return }
        let configuration = ModelConfiguration(id: modelID)
        container = try await #huggingFaceLoadModelContainer(configuration: configuration) { p in
            progress(p.fractionCompleted)
        }
        logger.info("LLM model ready: \(self.modelID, privacy: .public)")
    }

    func complete(prompt: String) async throws -> String {
        try await prepare()
        guard let container else { throw ClientError.notLoaded }

        var parameters = GenerateParameters()
        parameters.temperature = temperature
        parameters.maxTokens = ProcessInfo.processInfo.isLowPowerModeEnabled ? lowPowerMaxTokens : maxTokens

        let session = ChatSession(container, generateParameters: parameters)
        return try await session.respond(to: prompt)
    }
}
