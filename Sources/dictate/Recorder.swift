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
    private var device: AudioInputDevice?
    private var reopens = 0
    // Touched only on `callbackQueue`.
    private var heardSound = false
    private var silentFrames = 0
    static let targetRate: Double = 16_000
    private static let bufferCount = 3
    private static let bufferFrames: UInt32 = 1_600  // 100 ms
    /// Digital silence this long after real sound means the input died: a
    /// Bluetooth headset the Mac did not own when recording started can drop
    /// its mic stream when our start sound finishes, feeding zeros from then on.
    private static let deadSeconds = 0.5
    private static let maxReopens = 3
    /// Linear RMS of each chunk and its length in frames, called on the audio thread.
    var onLevel: ((_ rms: Float, _ frames: Int) -> Void)?

    var isRecording: Bool { queue != nil }

    var duration: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    func start(device: AudioInputDevice? = nil) throws {
        teardown()
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        self.device = device
        reopens = 0
        try open()
        startedAt = Date()
    }

    private func open() throws {
        callbackQueue.sync { heardSound = false; silentFrames = 0 }
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
    }

    /// Reopens the device after its input died, keeping what was recorded.
    /// On main, like `start` and `stop`.
    private func reopen() {
        guard queue != nil, reopens < Recorder.maxReopens else { return }
        reopens += 1
        log("input went silent; reopening \(device?.name ?? "default input")")
        teardown()
        do { try open() } catch { log("\(error)") }
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

    /// What has been recorded from sample `index` on, while recording goes on.
    func recorded(from index: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard index < samples.count else { return [] }
        return Array(samples[index...])
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
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = sqrt(sum / Float(count))
        onLevel?(rms, count)
        // Far below any live mic's noise floor; a dropped stream reads as zeros.
        if rms > 1e-6 {
            heardSound = true
            silentFrames = 0
        } else if heardSound {
            silentFrames += count
            if Double(silentFrames) >= Recorder.deadSeconds * Recorder.targetRate {
                silentFrames = 0
                DispatchQueue.main.async { [weak self] in self?.reopen() }
            }
        }
    }
}
