import AVFoundation
import CoreAudio
import Foundation

/// Captures the default input device and accumulates mono float32 at 16 kHz,
/// which is what the Cohere model expects.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var startedAt: Date?
    static let targetRate: Double = 16_000
    /// Linear RMS of each converted chunk, called on the audio thread.
    var onLevel: ((Float) -> Void)?

    var isRecording: Bool { engine.isRunning }

    var duration: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    func start(device: AudioInputDevice? = nil) throws {
        let input = engine.inputNode
        if let device, let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { log("could not select \(device.name) (\(status)); using default") }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw DictateError.audio("no input device")
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Recorder.targetRate, channels: 1, interleaved: false),
            let conv = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw DictateError.audio("cannot build converter from \(inFormat)") }
        converter = conv
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.consume(buffer, converter: conv, outFormat: outFormat)
        }
        engine.prepare()
        try engine.start()
        startedAt = Date()
    }

    /// Stops capture and returns everything recorded so far.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startedAt = nil
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    private func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outFormat: AVAudioFormat) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { log("convert: \(error)"); return }
        guard let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        if let onLevel {
            var sum: Float = 0
            for v in chunk { sum += v * v }
            onLevel(sqrt(sum / Float(chunk.count)))
        }
    }
}
