import AVFoundation
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
    /// Inputs this recording has used, by UID, so a fallback never goes back.
    private var tried: Set<String> = []
    // Touched only on `callbackQueue`.
    private var watch = DeadInput()
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
        self.device = device
        reopens = 0
        tried = Set([device?.uid ?? AudioDevices.defaultInputDevice()?.uid].compactMap { $0 })
        try open()
        startedAt = Date()
    }

    private func open() throws {
        callbackQueue.sync { watch = DeadInput() }
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

    /// After the input died: reopens it, or once that has failed
    /// `DeadInput.maxReopens` times (or it is gone), switches to the system
    /// default input, then the built-in mic, keeping what was recorded. On
    /// main, like `start` and `stop`.
    private func reopen() {
        guard queue != nil else { return }
        // Muted on purpose (a headset's mute gesture): not dead, and no other mic should take over.
        if AVAudioApplication.shared.isInputMuted { return }
        var present = device.map { d in AudioDevices.inputDevices().contains { $0.uid == d.uid } } ?? true
        while true {
            let name = device?.name ?? "default input"
            switch DeadInput.next(present: present, reopens: reopens, tried: tried,
                                  systemDefault: AudioDevices.defaultInputDevice(), builtIn: AudioDevices.builtInInput()) {
            case .same:
                reopens += 1
                log("input went silent; reopening \(name)")
            case .switchTo(let next):
                log("\(name) \(present ? "stayed silent" : "is gone"); switching to \(next.name) for this recording")
                device = next
                tried.insert(next.uid)
                reopens = 0
            case .giveUp:
                log("input went silent; no other input to switch to")
                return
            }
            teardown()
            do {
                try open()
                return
            } catch {
                log("\(error)")
                present = false
            }
        }
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
        if watch.feed(rms: rms, frames: count) {
            DispatchQueue.main.async { [weak self] in self?.reopen() }
        }
    }
}

/// Tells a dead input from a quiet room: a live mic always has some noise,
/// a dropped stream reads as exact zeros.
struct DeadInput: Equatable {
    /// Far below any live mic's noise floor.
    static let silentRMS: Float = 1e-6
    /// Digital silence this long after real sound means the input died: a
    /// Bluetooth headset the Mac did not own when recording started can drop
    /// its mic stream when our start sound finishes, feeding zeros from then on.
    static let deadSeconds = 0.5
    /// Zeros from the very start for this long: the input never came up. Longer
    /// than a slow AirPods switch to its mic, which reads zeros for a second or two.
    static let neverSeconds = 3.0
    static let maxReopens = 3

    private var heardSound = false
    private var silentFrames = 0

    /// Feeds one buffer; true when the input reads as dead (then it counts afresh).
    mutating func feed(rms: Float, frames: Int, rate: Double = Recorder.targetRate) -> Bool {
        if rms > Self.silentRMS {
            heardSound = true
            silentFrames = 0
            return false
        }
        silentFrames += frames
        guard Double(silentFrames) >= (heardSound ? Self.deadSeconds : Self.neverSeconds) * rate else { return false }
        silentFrames = 0
        return true
    }

    enum Next: Equatable { case same, switchTo(AudioInputDevice), giveUp }

    /// What to open after the input died: the same device again, up to
    /// `maxReopens` times while it is still connected; then the system
    /// default input, then the built-in mic, skipping any `tried` already.
    static func next(present: Bool, reopens: Int, tried: Set<String>,
                     systemDefault: AudioInputDevice?, builtIn: AudioInputDevice?) -> Next {
        if present && reopens < maxReopens { return .same }
        for d in [systemDefault, builtIn].compactMap({ $0 }) where !tried.contains(d.uid) { return .switchTo(d) }
        return .giveUp
    }
}
