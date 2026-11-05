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
    func start() throws {
        live = nil
        try recorder.start(device: AudioDevices.resolve(configured: config.microphone))
        transcriber.preload()
        live = transcriber.begin { [recorder] in recorder.recorded(from: $0) }
    }

    /// Separate from `start` so the daemon's start sound is not muted.
    func muteSpeakersIfConfigured() {
        if config.muteSpeakersWhileRecording { mute.engage() }
    }

    /// Releases the mic and the speaker mute; returns the audio and how long it
    /// ran. The audio is saved first (`Recovery`), cancelled recordings too, so
    /// whatever happens next it can be transcribed again. `wait` holds until
    /// it is on disk, for quitting.
    func stop(wait: Bool = false) -> (pcm: [Float], seconds: TimeInterval) {
        let seconds = recorder.duration
        let wasRecording = recorder.isRecording
        live?.stop()
        let pcm = recorder.stop()
        mute.release()
        if wasRecording, seconds >= config.minimumSeconds { Recovery.saveAudio(pcm, wait: wait) }
        return (pcm, seconds)
    }

    /// Recordings under `minimumSeconds` are dropped untranscribed.
    func isTooShort(_ seconds: TimeInterval) -> Bool {
        seconds < config.minimumSeconds
    }

    /// Transcribes in pieces cut at quiet points, then post-processes. The
    /// recording just stopped picks up from the pieces decoded while it ran;
    /// other audio (a file) is decoded whole. Completion runs on the
    /// transcriber's queue.
    func text(from pcm: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        let isRecording = live != nil
        let done: (Result<String, Error>) -> Void = { [transcriber] result in
            let result = result.map { transcriber.config.postProcess($0) }
            if isRecording, case .success(let text) = result, !text.isEmpty { Recovery.saveText(text) }
            completion(result)
        }
        if let live {
            self.live = nil
            live.finish(pcm) { result in
                if case .failure = result {
                    log("recording kept at \(Recovery.audioURL.path); dictate transcribe it to retry")
                }
                done(result)
            }
        } else {
            transcriber.transcribe(pcm, completion: done)
        }
    }

    /// Before exit: ggml's Metal teardown asserts if a model outlives exit().
    /// A recording still running is saved before the app goes.
    func shutdown() {
        _ = stop(wait: true)
        live = nil
        transcriber.unloadSync()
    }
}
