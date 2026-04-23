import SwiftUI
import CoreHaptics
import AVFoundation

@Observable
final class AppViewModel {
    enum State {
        case idle
        case loading(progress: Double, label: String, detail: String)
        case listening
        case error(String)
    }

    var appState: State = .idle
    var showDebug = false
    var ringMode: RingMode = .proportional

    private(set) var history   = MoodHistory()
    private(set) var animator  = RingAnimator()
    var chunkCount  = 0
    var lastMood:    Mood?
    var lastIntensity: Double = 0.5
    var lastTranscript = ""
    var isProcessing = false

    private let loader     = ModelLoader()
    private let classifier = GemmaMoodClassifier()
    private let audio      = AudioCapture()
    private var hapticEngine: CHHapticEngine?

    func begin() {
        guard case .idle = appState else { return }
        prepareHaptics()
        Task { await loadModel() }
    }

    // MARK: - Model loading

    private func loadModel() async {
        let variant = ModelVariant.e2b
        appState = .loading(progress: 0, label: "Preparing model…", detail: "")

        // Observe ModelLoader.state and relay progress
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await self.loader.load(variant)
            }
            group.addTask { [self] in
                while true {
                    switch self.loader.state {
                    case .idle:
                        break
                    case .downloading(let progress, let detail):
                        self.appState = .loading(progress: progress, label: "Downloading \(variant.name)", detail: detail)
                    case .ready(let path):
                        do {
                            // Request permissions before starting audio — on device these are required.
                            let micOK  = await AVAudioApplication.requestRecordPermission()
                            let asrOK  = await self.classifier.requestSpeechAuth()
                            guard micOK, asrOK else {
                                self.appState = .error("Microphone and speech recognition permissions are required.")
                                return
                            }
                            try await self.classifier.load(modelPath: path)
                            self.appState = .listening
                            self.startAudio()
                        } catch {
                            self.appState = .error("Model load error: \(error.localizedDescription)")
                        }
                        return
                    case .failed(let msg):
                        self.appState = .error(msg)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    // MARK: - Audio pipeline

    private func startAudio() {
        audio.onChunk = { [weak self] pcm in
            guard let self else { return }
            Task {
                await self.processChunk(pcm)
            }
        }
        audio.onError = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.appState = .error(msg)
            }
        }
        audio.start()
    }

    private func processChunk(_ pcm: [Float]) async {
        await MainActor.run { isProcessing = true }
        defer { Task { @MainActor in self.isProcessing = false } }

        do {
            guard let result = try await classifier.classify(audio: pcm) else { return }
            await MainActor.run {
                history.add(mood: result.mood, intensity: result.intensity)
                animator.setMood(result.mood, intensity: result.intensity)
                lastMood       = result.mood
                lastIntensity  = result.intensity
                lastTranscript = result.transcript
                chunkCount    += 1
            }
            pulse(mood: result.mood, intensity: result.intensity)
        } catch {
            // Transient chunk errors are non-fatal — log and continue
            print("Chunk error: \(error)")
        }
    }

    // MARK: - Haptics

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        hapticEngine = try? CHHapticEngine()
        try? hapticEngine?.start()
    }

    private func pulse(mood: Mood, intensity: Double) {
        guard let engine = hapticEngine else { return }
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(1 - intensity))
        let intParam  = CHHapticEventParameter(parameterID: .hapticIntensity,  value: Float(intensity))
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [sharpness, intParam], relativeTime: 0)
        if let pattern = try? CHHapticPattern(events: [event], parameters: []) {
            try? engine.makePlayer(with: pattern).start(atTime: 0)
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var vm = AppViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Ring — always rendered, hidden until listening
            RingView(history: vm.history, animator: vm.animator, mode: vm.ringMode)
                .ignoresSafeArea()
                .opacity(vm.isListening ? 1 : 0)

            // Overlay — shown until listening
            if !vm.isListening {
                overlay
            }

            // Debug panel + mode toggle — shown while listening
            if vm.isListening {
                listeningHUD
            }
        }
        .statusBarHidden()
    }

    // MARK: - Overlay

    @ViewBuilder
    private var overlay: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()

            switch vm.appState {
            case .idle:
                idlePrompt

            case .loading(let progress, let label, let detail):
                VStack(spacing: 48) {
                    LoadingView(progress: progress, label: label, detail: detail)
                }

            case .error(let msg):
                VStack(spacing: 16) {
                    Text(msg)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.red.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

            case .listening:
                EmptyView()
            }
        }
        .onTapGesture {
            if case .idle = vm.appState { vm.begin() }
        }
    }

    private var idlePrompt: some View {
        VStack(spacing: 12) {
            Text("MoodRing")
                .font(.system(size: 35, weight: .ultraLight))
                .tracking(7)
                .textCase(.uppercase)
                .foregroundStyle(.white)

            Text("Real-time emotional tone")
                .font(.system(size: 13, weight: .regular))
                .tracking(2.4)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.4))

            Text("Downloads ~2.3 GB on first launch")
                .font(.system(size: 10))
                .tracking(1.3)
                .foregroundStyle(.white.opacity(0.2))
                .padding(.top, 4)

            Text("tap to begin")
                .font(.system(size: 11))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.2))
                .padding(.top, 32)
        }
    }

    // MARK: - Listening HUD

    private var listeningHUD: some View {
        VStack {
            Spacer()

            if vm.showDebug {
                DebugOverlayView(
                    chunkCount:  vm.chunkCount,
                    mood:        vm.lastMood,
                    intensity:   vm.lastIntensity,
                    transcript:  vm.lastTranscript,
                    isProcessing: vm.isProcessing
                )
                .padding(.bottom, 8)
            }

            Button(vm.ringMode == .proportional ? "Proportional" : "Chronological") {
                vm.ringMode = vm.ringMode == .proportional ? .chronological : .proportional
            }
            .font(.system(size: 10, weight: .regular))
            .tracking(2.2)
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.35))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(.white.opacity(0.06))
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .clipShape(Capsule())
            .onLongPressGesture { vm.showDebug.toggle() }
        }
        .padding(.bottom, 36)
    }

    private var isListening: Bool {
        if case .listening = vm.appState { return true }
        return false
    }
}

// Extension so AppViewModel can expose isListening cleanly
extension AppViewModel {
    var isListening: Bool {
        if case .listening = appState { return true }
        return false
    }
}
