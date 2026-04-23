# iMoodRing

Real-time emotional tone detection using on-device LLM inference.

## Setup

Requires Xcode 16+, CocoaPods, and XcodeGen.

```sh
brew install xcodegen
sudo gem install cocoapods
./setup.sh
open iMoodRing.xcworkspace
```

`setup.sh` downloads the LiteRT Metal accelerator dylib and generates the Xcode project.

## Current status: blocked on LiteRT-LM Swift + Metal

GPU acceleration for LLM inference on iOS is not currently available through any supported channel.

**What we know:**

- `libLiteRtMetalAccelerator.dylib` from Google's prebuilts is mispackaged as a macOS x86_64 binary instead of iOS arm64 ([LiteRT issue #6745](https://github.com/google-ai-edge/LiteRT/issues/6745)), so it cannot register at runtime.
- `MediaPipeTasksGenAI` (the pod we use) officially supports CPU-only on iOS — there is no GPU variant.
- **Gemma 4 E2B (2.6 GB) cannot run** without GPU acceleration; it OOMs on CPU.

**Current workaround:** the app uses Gemma 3 1B (~584 MB) for CPU-only inference. It works within iOS memory limits but is slower and less capable.

**Unblocked by:** LiteRT-LM Swift APIs shipping with Metal support. As of April 2026 these are marked "In Dev." Track progress at [google-ai-edge/LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM). When they ship, migrate from `MediaPipeTasksGenAI` to LiteRT-LM, remove the manually-embedded dylib, and switch back to Gemma 4 E2B.
