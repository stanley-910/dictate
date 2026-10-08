import AudioToolbox
import CoreAudio
import Foundation

/// Captures an input device and accumulates mono float32 at 16 kHz, which is
/// what the Cohere model expects.
///
/// Uses an input AudioQueue rather than AVAudioEngine: the queue converts
/// whatever the hardware delivers to 16 kHz mono itself. AVAudioEngine keeps
/// a stale 48 kHz client format when pointed at a Bluetooth headset whose mic
/// runs in HFP at 16 or 24 kHz (AirPods), and its tap then throws an
/// uncatchable "format mismatch" exception.
final class Recorder {
    private var queue: AudioQueueRef?
    private let callbackQueue = DispatchQueue(label: "dictate.recorder")
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var startedAt: Date?
    static let targetRate: Double = 16_000
    private static let bufferCount = 3
    private static let bufferFrames: UInt32 = 1_600  // 100 ms
    /// Linear RMS of each chunk and its length in frames, called on the audio thread.
    var onLevel: ((_ rms: Float, _ frames: Int) -> Void)?

    var isRecording: Bool { queue != nil }

    var duration: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    func start(device: AudioInputDevice? = nil) throws {
        teardown()
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        var format = AudioStreamBasicDescription(
            mSampleRate: Recorder.targetRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var newQueue: AudioQueueRef?
        var status = AudioQueueNewInputWithDispatchQueue(&newQueue, &format, 0, callbackQueue) {
            [weak self] queue, buffer, _, _, _ in
            self?.consume(buffer)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        guard status == noErr, let q = newQueue else { throw DictateError.audio("cannot open input (\(status))") }

        if let device {
            var uid = device.uid as CFString
            status = AudioQueueSetProperty(
                q, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size))
            if status != noErr { log("could not select \(device.name) (\(status)); using default") }
        }
        for _ in 0..<Recorder.bufferCount {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, Recorder.bufferFrames * format.mBytesPerFrame, &buffer) == noErr,
               let buffer {
                AudioQueueEnqueueBuffer(q, buffer, 0, nil)
            }
        }
        status = AudioQueueStart(q, nil)
        guard status == noErr else {
            AudioQueueDispose(q, true)
            throw DictateError.audio("cannot start \(device?.name ?? "default input") (\(status))")
        }
        queue = q
        startedAt = Date()
    }

    /// Stops capture and returns everything recorded so far.
    func stop() -> [Float] {
        teardown()
        startedAt = nil
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    private func teardown() {
        guard let q = queue else { return }
        queue = nil
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true)
    }

    private func consume(_ buffer: AudioQueueBufferRef) {
        let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(
            start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        if let onLevel {
            var sum: Float = 0
            for v in chunk { sum += v * v }
            onLevel(sqrt(sum / Float(count)), count)
        }
    }
}
