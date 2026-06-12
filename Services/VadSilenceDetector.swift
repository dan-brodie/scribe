// SPDX-License-Identifier: MIT

import FluidAudio
import Foundation

/// Production silence detector backed by FluidAudio's neural VAD.
///
/// The model is loaded (and auto-downloaded) lazily on first use. If loading or
/// inference ever fails, it transparently falls back to energy detection so a
/// recording is never lost to a model problem.
actor VadSilenceDetector: SilenceDetector {
    private let config: VadConfig
    private let fallback = EnergySilenceDetector()
    private var manager: VadManager?
    private var disabled = false
    private let logger = Log.make("VadSilenceDetector")

    init(threshold: Float = 0.85) {
        self.config = VadConfig(defaultThreshold: threshold)
    }

    func containsSpeech(_ samples: [Float]) async -> Bool {
        guard !disabled else { return await fallback.containsSpeech(samples) }
        do {
            let manager = try await loadIfNeeded()
            let results = try await manager.process(samples)
            return results.contains { $0.isVoiceActive }
        } catch {
            logger.error("VAD unavailable, falling back to energy detection: \(error, privacy: .public)")
            disabled = true
            return await fallback.containsSpeech(samples)
        }
    }

    private func loadIfNeeded() async throws -> VadManager {
        if let manager { return manager }
        let created = try await VadManager(config: config)
        manager = created
        logger.info("VAD model loaded")
        return created
    }
}
