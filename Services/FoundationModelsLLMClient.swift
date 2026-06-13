// SPDX-License-Identifier: MIT

#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// On-device summarization via Apple's Foundation Models (Apple Intelligence) —
/// the OS-native, zero-download default (ADR-001 alternative). No `swift-huggingface`
/// or model fetch: the weights ship with the OS. The MLX/Qwen path
/// (`MLXLLMClient`) is retained behind a feature flag for older OS / unsupported
/// hardware.
///
/// `@available(macOS 26.0, *)` because the framework requires it; the factory
/// only instantiates this when `isAvailable`, otherwise it falls back to MLX.
@available(macOS 26.0, *)
actor FoundationModelsLLMClient: LLMClient {
    private let temperature: Double
    /// Generation caps for normal and Low Power Mode (spec throttle).
    private let maxTokens: Int
    private let lowPowerMaxTokens: Int
    private let logger = Log.make("FoundationModelsLLMClient")

    init(temperature: Double = 0.1, maxTokens: Int = 1024, lowPowerMaxTokens: Int = 512) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.lowPowerMaxTokens = lowPowerMaxTokens
    }

    /// Whether the on-device model is ready on this Mac (Apple-Intelligence-capable,
    /// enabled, and the assets downloaded by the OS).
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Answer one prompt with a fresh, stateless session so map/reduce/repair
    /// calls never share context.
    func complete(prompt: String) async throws -> String {
        let cap = ProcessInfo.processInfo.isLowPowerModeEnabled ? lowPowerMaxTokens : maxTokens
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: cap)
        let session = LanguageModelSession()
        return try await session.respond(to: prompt, options: options).content
    }
}
#endif
