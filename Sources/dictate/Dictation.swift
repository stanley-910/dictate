import Foundation

/// The mic-to-text path shared by the daemon and `dictate listen`: the selected
/// microphone, speaker muting, the minimum length, chunked transcription, and
/// dictionary + replacements + casing. Fixes here land in both.
final class Dictation {
    let recorder = Recorder()
    let transcriber: Transcriber
    private let mute = OutputMute()

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
    /// default) and starts loading the model so the stop is fast.
    func start() throws {
        try recorder.start(device: AudioDevices.resolve(configured: config.microphone))
        transcriber.preload()
    }

    /// Separate from `start` so the daemon's start sound is not muted.
    func muteSpeakersIfConfigured() {
        if config.muteSpeakersWhileRecording { mute.engage() }
    }

    /// Releases the mic and the speaker mute; returns the audio and how long it ran.
    func stop() -> (pcm: [Float], seconds: TimeInterval) {
        let seconds = recorder.duration
        let pcm = recorder.stop()
        mute.release()
        return (pcm, seconds)
    }

    /// Recordings under `minimumSeconds` are dropped untranscribed.
    func isTooShort(_ seconds: TimeInterval) -> Bool {
        seconds < config.minimumSeconds
    }

    /// Transcribes in pieces cut at quiet points, then post-processes.
    /// Completion runs on the transcriber's queue.
    func text(from pcm: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        transcriber.transcribe(pcm) { [transcriber] result in
            completion(result.map { transcriber.config.postProcess($0) })
        }
    }

    /// Before exit: ggml's Metal teardown asserts if a model outlives exit().
    func shutdown() {
        _ = stop()
        transcriber.unloadSync()
    }
}
