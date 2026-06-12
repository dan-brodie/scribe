// SPDX-License-Identifier: MIT

import Foundation

/// Classifies a chunk of 16 kHz mono Float32 audio as speech or silence.
///
/// Abstracted so the production pipeline can use FluidAudio's neural VAD while
/// tests (and a lightweight fallback) use simple signal energy.
protocol SilenceDetector: Sendable {
    func containsSpeech(_ samples: [Float]) async -> Bool
}

/// Signal-energy helpers shared by silence detection and zero-energy
/// (device-mismatch) detection.
enum AudioEnergy {
    /// Root-mean-square amplitude of the samples (0 for empty input).
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// True when the channel carries essentially no signal — used to detect a
    /// system-audio device mismatch (the tap is capturing nothing).
    static func isEffectivelySilent(_ samples: [Float], threshold: Float = 1e-4) -> Bool {
        rms(samples) < threshold
    }
}

/// Energy-threshold silence detector. No models, no async work — the default
/// fallback and the test double.
struct EnergySilenceDetector: SilenceDetector {
    /// RMS below this is treated as silence (~ -40 dBFS at 0.01).
    var rmsThreshold: Float

    init(rmsThreshold: Float = 0.01) {
        self.rmsThreshold = rmsThreshold
    }

    func containsSpeech(_ samples: [Float]) async -> Bool {
        AudioEnergy.rms(samples) >= rmsThreshold
    }
}
