import Foundation

/// Keeps the last few recordings and their transcripts on disk, so nothing
/// said is lost when a transcription fails, a paste lands in the wrong window,
/// a long recording is cancelled by mistake, or the app dies mid-recording.
/// Each recording is `recordings/<time>.wav` with a `.txt` beside it;
/// `last.wav` and `last.txt` link to the newest. `dictate transcribe` on a
/// `.wav` decodes it again.
enum Recovery {
    /// $XDG_STATE_HOME/dictate, else ~/.local/state/dictate: next to the log.
    static var directory: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return base.appendingPathComponent("dictate")
    }

    static var recordings: URL { directory.appendingPathComponent("recordings") }
    static var audioURL: URL { directory.appendingPathComponent("last.wav") }
    static var textURL: URL { directory.appendingPathComponent("last.txt") }
    /// Names the recording in progress; still there at launch means the app
    /// died before that recording was stopped.
    static var markerURL: URL { recordings.appendingPathComponent("in-progress") }

    fileprivate static let queue = DispatchQueue(label: "dictate.recovery")
    /// Recordings saved in full; on `queue`. A save of the audio so far that
    /// lands after the full one (a piece decoding as recording stopped) is dropped.
    fileprivate static var finished: Set<String> = []

    /// Waits for the saves already asked for.
    static func flush() { queue.sync {} }

    static var lastText: String? { try? String(contentsOf: textURL, encoding: .utf8) }

    /// Saved recordings, newest first.
    static func recent() -> [Take] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
        return names.filter { $0.hasSuffix(".wav") }.sorted(by: >).map { Take(id: String($0.dropLast(4))) }
    }

    /// The recording the app was making when it last died, if any; clears
    /// the marker. At launch.
    static func interrupted() -> Take? {
        guard let id = try? String(contentsOf: markerURL, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: markerURL)
        let take = Take(id: id.trimmingCharacters(in: .whitespacesAndNewlines))
        return FileManager.default.fileExists(atPath: take.audioURL.path) ? take : nil
    }

    /// Moves a `last.wav` / `last.txt` from before recordings were kept into
    /// `recordings/`, named for the audio's modification time. At launch.
    static func migrate() {
        queue.sync {
            let fm = FileManager.default
            guard (try? fm.destinationOfSymbolicLink(atPath: audioURL.path)) == nil,
                  let attrs = try? fm.attributesOfItem(atPath: audioURL.path),
                  let date = attrs[.modificationDate] as? Date else { return }
            let take = Take(id: Take.formatter.string(from: date))
            do {
                try fm.createDirectory(at: recordings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.moveItem(at: audioURL, to: take.audioURL)
                if (try? fm.destinationOfSymbolicLink(atPath: textURL.path)) == nil, fm.fileExists(atPath: textURL.path) {
                    try fm.moveItem(at: textURL, to: take.textURL)
                }
                for url in [take.audioURL, take.textURL] where fm.fileExists(atPath: url.path) {
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                try fm.createSymbolicLink(atPath: audioURL.path, withDestinationPath: "recordings/" + take.audioURL.lastPathComponent)
                if fm.fileExists(atPath: take.textURL.path) {
                    try fm.createSymbolicLink(atPath: textURL.path, withDestinationPath: "recordings/" + take.textURL.lastPathComponent)
                }
                log("moved \(audioURL.lastPathComponent) to recordings/\(take.id).wav")
            } catch {
                log("could not move \(audioURL.lastPathComponent) into recordings: \(error)")
            }
        }
    }

    /// Deletes all but the newest `keep` recordings.
    static func prune(keep: Int) {
        for take in recent().dropFirst(max(0, keep)) { take.delete() }
    }

    /// One recording's files. Writes happen in order on one queue, off the
    /// caller's thread; `wait` blocks until they are on disk (for quitting).
    struct Take {
        let id: String

        static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS"
            return f
        }()

        /// A new recording named for the current time, to the millisecond.
        static func new() -> Take { Take(id: formatter.string(from: Date())) }

        var audioURL: URL { recordings.appendingPathComponent(id + ".wav") }
        var textURL: URL { recordings.appendingPathComponent(id + ".txt") }

        var date: Date? { Take.formatter.date(from: id) }

        /// Length from the file size: 16-bit mono at 16 kHz after a 44-byte header.
        var seconds: Double {
            let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
            return Double(max(0, size - 44)) / (2 * Recorder.targetRate)
        }

        var text: String? { try? String(contentsOf: textURL, encoding: .utf8) }

        /// Marks this as the recording in progress.
        func begin() {
            write { try Data(id.utf8).write(to: markerURL, options: .atomic) }
        }

        /// The recording so far or in full; the newest becomes `last.wav`.
        /// With `done`, it is no longer in progress.
        func saveAudio(_ pcm: [Float], done: Bool = false, wait: Bool = false) {
            write(wait: wait) {
                if !done, finished.contains(id) { return }
                if done { finished.insert(id) }
                if !pcm.isEmpty {
                    try Wav.write16k(pcm, to: audioURL)
                    try lock(audioURL)
                    try link(audioURL, as: Recovery.audioURL)
                }
                if done { try? FileManager.default.removeItem(at: markerURL) }
            }
        }

        func saveText(_ text: String) {
            write {
                try Data(text.utf8).write(to: textURL, options: [.atomic])
                try lock(textURL)
                try link(textURL, as: Recovery.textURL)
            }
        }

        /// Gone, with the marker if it is the one in progress.
        func delete(wait: Bool = false) {
            write(wait: wait) {
                for url in [audioURL, textURL] { try? FileManager.default.removeItem(at: url) }
                if (try? String(contentsOf: markerURL, encoding: .utf8)) == id {
                    try? FileManager.default.removeItem(at: markerURL)
                }
            }
        }

        private func write(wait: Bool = false, _ body: @escaping () throws -> Void) {
            let run = {
                do {
                    try FileManager.default.createDirectory(
                        at: recordings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try body()
                } catch {
                    log("could not save recording \(id): \(error)")
                }
            }
            if wait { queue.sync(execute: run) } else { queue.async(execute: run) }
        }

        /// Personal audio and text: owner only.
        private func lock(_ url: URL) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        /// `name` -> `target`, relative so the folder can move. A regular
        /// file there (from before recordings were kept) is never deleted.
        private func link(_ target: URL, as name: URL) throws {
            let fm = FileManager.default
            if fm.fileExists(atPath: name.path), (try? fm.destinationOfSymbolicLink(atPath: name.path)) == nil {
                log("not replacing \(name.lastPathComponent): not a link")
                return
            }
            try? fm.removeItem(at: name)
            try FileManager.default.createSymbolicLink(
                atPath: name.path, withDestinationPath: "recordings/" + target.lastPathComponent)
        }
    }
}
