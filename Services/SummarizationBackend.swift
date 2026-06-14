// SPDX-License-Identifier: MIT

import Foundation

/// Which LLM powers summarization. Apple's on-device Foundation Models is the
/// default (OS-native, no download); the MLX/Gemma path is kept behind a feature
/// flag as a fallback for pre-macOS-26 / non-Apple-Intelligence machines and for
/// users who prefer it.
enum SummarizationBackend: String, CaseIterable, Identifiable, Sendable {
    case appleFoundationModels
    case mlxGemma

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleFoundationModels: return "Apple (on-device)"
        case .mlxGemma: return "Gemma 4 E4B via MLX (download)"
        }
    }

    /// Default for new installs: Apple Foundation Models.
    static let `default`: SummarizationBackend = .appleFoundationModels

    static let defaultsKey = "summarization.backend"

    /// The user's configured choice, or the default when unset.
    static var configured: SummarizationBackend {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init) ?? .default
    }

    static func store(_ backend: SummarizationBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: defaultsKey)
    }
}

/// Builds the `LLMClient` for the configured backend, transparently falling back
/// to MLX/Gemma when Apple Foundation Models isn't available on this OS/hardware.
enum SummarizerClientFactory {
    static func makeClient(backend: SummarizationBackend = .configured) -> LLMClient {
        switch backend {
        case .appleFoundationModels:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), FoundationModelsLLMClient.isAvailable {
                return FoundationModelsLLMClient()
            }
            #endif
            Log.make("SummarizerClientFactory")
                .info("Apple Foundation Models unavailable; using MLX/Gemma fallback")
            return MLXLLMClient()
        case .mlxGemma:
            return MLXLLMClient()
        }
    }

    /// Whether Apple's on-device model can be used right now (drives the
    /// settings hint and the silent fallback).
    static var appleFoundationModelsAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationModelsLLMClient.isAvailable }
        #endif
        return false
    }
}
