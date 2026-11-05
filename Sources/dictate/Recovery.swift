import Foundation

/// Keeps the last recording and the last transcript on disk, so nothing said
/// is lost when a transcription fails, a paste lands in the wrong window, a
/// long recording is cancelled by mistake, or the app quits mid-recording.
/// `dictate transcribe <last.wav>` decodes the audio again.
enum Recovery {
    /// $XDG_STATE_HOME/dictate, else ~/.local/state/dictate: next to the log.
    static var directory: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return base.appendingPathComponent("dictate")
    }

    static var audioURL: URL { directory.appendingPathComponent("last.wav") }
    static var textURL: URL { directory.appendingPathComponent("last.txt") }

    private static let queue = DispatchQueue(label: "dictate.recovery")

    /// Writes the recording off the caller's thread; `wait` blocks until it
    /// is on disk (for quitting). Empty audio leaves the last file in place.
    static func saveAudio(_ pcm: [Float], wait: Bool = false) {
        guard !pcm.isEmpty else { return }
        let write = {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Wav.write16k(pcm, to: audioURL)
            } catch {
                log("could not save recording: \(error)")
            }
        }
        if wait { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    static func saveText(_ text: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? text.write(to: textURL, atomically: true, encoding: .utf8)
        }
    }

    static var lastText: String? { try? String(contentsOf: textURL, encoding: .utf8) }
}
