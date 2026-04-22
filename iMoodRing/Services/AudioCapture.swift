import AVFoundation

final class AudioCapture {
    var onChunk: (([Float]) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let targetRate: Double = 16_000
    private let chunkSeconds: Double = 5.0
    private var buffer: [Float] = []
    private var chunkSize: Int { Int(targetRate * chunkSeconds) }

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError?("Audio session error: \(error.localizedDescription)")
            return
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ) else {
            onError?("Could not create 16 kHz audio format")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            onError?("Could not create audio converter")
            return
        }

        let tapSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1) // 100 ms taps

        input.installTap(onBus: 0, bufferSize: tapSize, format: inputFormat) { [weak self] inBuf, _ in
            guard let self else { return }

            let outFrames = AVAudioFrameCount(
                Double(inBuf.frameLength) * self.targetRate / inputFormat.sampleRate
            )
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

            var consumed = false
            var convError: NSError?
            converter.convert(to: outBuf, error: &convError) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData
                consumed = true
                return inBuf
            }
            guard convError == nil, let ch = outBuf.floatChannelData?[0] else { return }

            let samples = Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
            self.buffer.append(contentsOf: samples)

            while self.buffer.count >= self.chunkSize {
                let chunk = Array(self.buffer.prefix(self.chunkSize))
                self.buffer.removeFirst(self.chunkSize)
                self.onChunk?(chunk)
            }
        }

        do {
            try engine.start()
        } catch {
            onError?("Engine start error: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
