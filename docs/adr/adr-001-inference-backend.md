# ADR-001: Inference Backend — FluidAudio (audio) + MLX (LLM)

## Status
Accepted

## Context
The brief asked for MLX as the backend for all AI workloads. However:
- `mlx-whisper` and pyannote diarization are Python libraries — requiring a bundled Python sidecar
- pyannote weights are gated behind a Hugging Face agreement (violates "fully open source" constraint)
- MLX is excellent for LLM inference in Swift but is not the right tool for ASR/diarization

## Decision
- **ASR + VAD + diarization + speaker embeddings:** FluidAudio (Apache-2.0, pure Swift, CoreML/ANE)
  - Models: NVIDIA Parakeet TDT (auto-download from Hugging Face, permissive licenses)
  - Runs on Apple Neural Engine — lower power draw for an always-on menu bar app
- **Summarization + action extraction + speaker-name inference:** MLX via `mlx-swift` + `mlx-swift-lm`
  - Default model: `Qwen/Qwen3-4B-Instruct` 4-bit (Apache-2.0)
  - Alternative: `meta-llama/Llama-3.2-3B-Instruct` 4-bit

## Consequences
- MLX constraint is satisfied where MLX is genuinely right (LLM workloads)
- No Python sidecar required; app is pure Swift
- Fallback path (Python sidecar with mlx-whisper + non-gated diarizer) is documented as out of scope for v1
