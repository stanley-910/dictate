import Foundation

/// The mic-to-text path shared by the daemon and `dictate listen`: the selected
/// microphone, speaker muting, the minimum length, chunked transcription, and
/// dictionary + replacements + casing. Fixes here land in both.
final class Dictation {
    let recorder = Recorder()
    let transcriber: Transcriber
    private let mute = OutputMute()
    /// The recording in progress (or just stopped), decoded as it comes in.
    private var live: LiveTranscript?
    /// Its files; nil when `keepRecordings` is 0.
    private var take: Recovery.Take?
    /// The input the latest recording used, for the log.
    private(set) var inputName = "default input"

    /// Read at each use; a new model path drops the loaded one.
    var config: Config {
        didSet {
            transcriber.config = config
            if config.modelURL != oldValue.modelURL { transcriber.unload() }
        }
    }

    init(config: Config) {
        self.config = config
        self.transcriber = Transcriber(config: config)
    }

    /// Opens the menu bar pick (or config `microphone`, else the system
    /// default), starts loading the model, and decodes full pieces as they
    /// arrive so the stop is fast.
    /// With `keepRecordings` above 0, the audio and text so far are saved
    /// after each piece, so a crash or a forced quit keeps nearly all of it.
    func start() throws {
        live = nil
        let device = AudioDevices.resolve(configured: config.microphone, preferBuiltIn: config.preferBuiltInMic)
        inputName = device?.name ?? "default input"
        try recorder.start(device: device)
        transcriber.preload()
        let take = config.keepRecordings > 0 ? Recovery.Take.new() : nil
        // `dictate listen` too, not only the app's launch: the old last.wav is moved, never overwritten.
        if take != nil { Recovery.migrate() }
        if let take {
            Recovery.prune(keep: config.keepRecordings - 1)
            take.begin()
        }
        self.take = take
        live = transcriber.begin(recorded: { [recorder] in recorder.recorded(from: $0) }) { [recorder, transcriber] text in
            guard let take else { return }
            take.saveAudio(recorder.recorded(from: 0))
            take.saveText(transcriber.config.postProcess(text))
        }
    }

    /// Separate from `start` so the daemon's start sound is not muted.
    func muteSpeakersIfConfigured() {
        if config.muteSpeakersWhileRecording { mute.engage() }
    }

    /// Releases the mic and the speaker mute; returns the audio and how long it
    /// ran. The audio is saved first (`Recovery`), cancelled recordings too, so
    /// whatever happens next it can be transcribed again. `wait` holds until
    /// it is on disk, for quitting. A `discard`ed recording is not kept.
    func stop(wait: Bool = false, discard: Bool = false) -> (pcm: [Float], seconds: TimeInterval) {
        let seconds = recorder.duration
        let wasRecording = recorder.isRecording
        live?.stop()
        let pcm = recorder.stop()
        mute.release()
        if wasRecording, let take {
            if seconds >= config.minimumSeconds, !discard { take.saveAudio(pcm, done: true, wait: wait) } else { take.delete(wait: wait) }
        }
        return (pcm, seconds)
    }

    /// Recordings under `minimumSeconds` are dropped untranscribed.
    func isTooShort(_ seconds: TimeInterval) -> Bool {
        seconds < config.minimumSeconds
    }

    /// Transcribes in pieces cut at quiet points, then post-processes. With
    /// `recording`, `pcm` is the recording just stopped and it picks up from
    /// the pieces decoded while it ran; other audio (a saved file) is decoded
    /// whole, and a cancelled recording's pieces are dropped. Completion runs
    /// on the transcriber's queue.
    func text(from pcm: [Float], recording: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        if !recording { live = nil }
        let take = live != nil ? self.take : nil
        let done: (Result<String, Error>) -> Void = { [transcriber] result in
            let result = result.map { transcriber.config.postProcess($0) }
            if let take, case .success(let text) = result, !text.isEmpty { take.saveText(text) }
            completion(result)
        }
        if let live {
            self.live = nil
            live.finish(pcm) { result in
                if case .failure = result, let take {
                    log("recording kept at \(take.audioURL.path); dictate transcribe it to retry")
                }
                done(result)
            }
        } else {
            transcriber.transcribe(pcm, completion: done)
        }
    }

    /// Loudness of a recording, for the log when no speech was found in it:
    /// whether it was silence, a dead input or speech too quiet for the gate.
    static func levels(_ pcm: [Float]) -> String {
        let block = Int(Recorder.targetRate / 10)
        var levels: [Float] = []
        var i = 0
        while i + block <= pcm.count {
            var e: Float = 0
            for v in pcm[i..<(i + block)] { e += v * v }
            levels.append((e / Float(block)).squareRoot())
            i += block
        }
        guard !levels.isEmpty else { return "no audio" }
        let dead = levels.filter { $0 <= EndOfSpeech.deadRMS }.count
        let sorted = levels.sorted()
        func at(_ q: Double) -> String { String(format: "%.4f", sorted[Int(Double(sorted.count - 1) * q)]) }
        return "100 ms levels: loudest \(at(1)), 90th pct \(at(0.9)), median \(at(0.5)), 10th pct \(at(0.1)); "
            + "\(dead * 100 / levels.count)% dead"
    }

    /// Before exit: ggml's Metal teardown asserts if a model outlives exit().
    /// A recording still running is saved before the app goes.
    func shutdown() {
        _ = stop(wait: true)
        live = nil
        transcriber.unloadSync()
    }
}
