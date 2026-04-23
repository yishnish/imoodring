# iMoodRing

Real-time emotional tone detection using on-device LLM inference with Metal GPU acceleration.

## Setup

Requires Xcode 16+ and XcodeGen.

```sh
brew install xcodegen
./setup.sh
open iMoodRing.xcodeproj
```

`setup.sh` generates the Xcode project. On first open, Xcode automatically resolves the `llama.swift` SPM package, which downloads the llama.cpp XCFramework.

## Architecture

- **Inference**: [llama.cpp](https://github.com/ggml-org/llama.cpp) via [mattt/llama.swift](https://github.com/mattt/llama.swift), with Metal GPU acceleration (`n_gpu_layers=9999`)
- **Model**: Gemma 4 E2B GGUF UD-IQ2_M (~2.3 GB, downloaded on first launch from HuggingFace)
- **Speech**: `SFSpeechRecognizer` on-device, 16 kHz mono PCM chunks
- **Pipeline**: mic → 10s chunks → on-device ASR → Gemma prompt → JSON mood+intensity → ring animation

## Why llama.cpp instead of MediaPipeTasksGenAI

`MediaPipeTasksGenAI` supports CPU-only inference on iOS. The `libLiteRtMetalAccelerator.dylib` prebuilts from Google are mispackaged as macOS x86_64 binaries and cannot load on iOS arm64 ([LiteRT issue #6745](https://github.com/google-ai-edge/LiteRT/issues/6745)). Gemma 4 E2B (2.3+ GB) requires GPU to avoid OOM on device, so CPU-only was a dead end.

llama.cpp's Metal backend works on iOS today. The GGUF quantized model fits comfortably on devices with 6 GB+ RAM. Fall back to `ModelVariant.gemma3_1b` (~900 MB) if you hit memory pressure on older hardware.
