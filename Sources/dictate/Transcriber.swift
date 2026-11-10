import Foundation
import TranscribeCpp

/// Owns the model. Loads lazily on first use and drops it after an idle period
/// so the process sits at a few MB when you are not dictating.
final class Transcriber {
    var config: Config
    private var model: Model?
    private var session: Session?
    private var idleTimer: Timer?
    fileprivate let queue = DispatchQueue(label: "dictate.transcriber")

    init(config: Config) {
        self.config = config
        Transcribe.setLogHandler { level, message in
            if level == .error || level == .warn { log("ggml: \(message)") }
        }
    }

    var isLoaded: Bool { model != nil }

    /// Load synchronously on the caller's queue. Safe to call repeatedly.
    func load() throws {
        if model != nil { return }
        let path = config.modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw DictateError.modelMissing(path)
        }
        let t0 = Date()
        let m = try Model(path: path, options: ModelOptions(backend: .auto))
        let s = try m.session()
        model = m
        session = s
        log("model loaded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms on \(m.backend) (\((try? m.device.name) ?? "?"))")
    }

    /// Kick off a load in the background so the first stop is fast.
    func preload() {
        queue.async {
            do { try self.load() } catch { log("preload failed: \(error)") }
        }
    }

    func unload() {
        session = nil
        model = nil
        log("model unloaded")
    }

    func unloadSync() {
        queue.sync { if self.model != nil { self.unload() } }
    }

    /// pcm: mono float32 at 16 kHz.
    func transcribe(_ pcm: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let t0 = Date()
            // The model decodes a whole clip in one pass and falls apart past
            // roughly half a minute (skips ahead, then loops the last sentence),
            // and the library does no long-form chunking for it. Cut at quiet
            // points and stitch the pieces.
            let chunker = Chunker(config: self.config)
            var pieces = Pieces(chunker: chunker)
            for chunk in chunker.split(pcm) { pieces.take(chunk, with: self) }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log("transcribed \(seconds(pcm.count)) s of audio (\(seconds(pieces.fed)) s after pauses) in \(ms) ms (\(pieces.summary))")
            self.scheduleUnload()
            completion(pieces.result)
        }
    }

    /// Starts transcribing a recording while it is still being made.
    /// `recorded(from:)` returns the audio from a sample index on, so far.
    /// `progress` gets the text so far after each piece, on the transcriber's queue.
    func begin(recorded: @escaping (Int) -> [Float], progress: @escaping (String) -> Void = { _ in }) -> LiveTranscript {
        LiveTranscript(transcriber: self, chunker: Chunker(config: config), recorded: recorded, progress: progress)
    }

    /// One piece, long pauses shortened; also how many samples the model got.
    /// On `queue` only.
    fileprivate func decode(_ chunk: [Float], chunker: Chunker) throws -> (text: String, samples: Int) {
        try load()
        guard let session else { throw DictateError.notLoaded }
        var options = RunOptions()
        options.language = config.language
        let audio = chunker.squeeze(chunk)
        return (try run(audio, session: session, options: options, halvings: 2), audio.count)
    }

    /// Now and then the model gets stuck repeating a phrase until it hits its
    /// token cap ("the people who are talking about the people who are ...").
    /// Shorter audio usually decodes cleanly, so such a piece is decoded again
    /// as two halves cut at a quiet point, up to `halvings` deep; past that,
    /// its text is kept up to where the repeating starts.
    private func run(_ audio: [Float], session: Session, options: RunOptions, halvings: Int) throws -> String {
        do {
            return try session.run(audio, options: options).text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard let partial = Loop.partial(error) else { throw error }
            let rate = Int(Recorder.targetRate)
            guard halvings > 0, audio.count >= 2 * rate else {
                log("piece of \(seconds(audio.count)) s looped; keeping its text up to the loop")
                return Loop.cut(partial).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            log("piece of \(seconds(audio.count)) s looped; decoding it in two halves")
            let mid = Chunker.middleCut(audio, rate: rate)
            let halves = try [Array(audio[..<mid]), Array(audio[mid...])].map {
                try run($0, session: session, options: options, halvings: halvings - 1)
            }
            return halves.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    fileprivate func scheduleUnload() {
        guard config.unloadAfterSeconds > 0 else { return }
        DispatchQueue.main.async {
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: self.config.unloadAfterSeconds, repeats: false) { _ in
                self.queue.async { self.unload() }
            }
        }
    }
}

/// The decoded pieces of one recording. A piece that fails is logged and
/// marked "[…]" in the text instead of failing the whole recording, so one
/// bad stretch never costs everything around it. On the transcriber's queue.
private struct Pieces {
    static let gap = "[…]"
    let chunker: Chunker
    private var parts: [String] = []
    private(set) var count = 0
    private(set) var fed = 0
    private var skipped = 0
    private var lastError: Error?

    init(chunker: Chunker) { self.chunker = chunker }

    mutating func take(_ chunk: [Float], with transcriber: Transcriber) {
        count += 1
        if Silence.speechSeconds(chunk, rate: Int(Recorder.targetRate)) < Silence.minSpeechSeconds {
            log("piece \(count) of \(seconds(chunk.count)) s has no speech; skipped")
            return
        }
        do {
            let piece = try transcriber.decode(chunk, chunker: chunker)
            if !piece.text.isEmpty { parts.append(piece.text) }
            fed += piece.samples
        } catch {
            log("piece \(count) of \(seconds(chunk.count)) s failed: \(error)")
            skipped += 1
            lastError = error
            parts.append(Self.gap)
        }
    }

    /// The text; a failure only when no piece decoded (a missing model, say).
    var result: Result<String, Error> {
        if let lastError, skipped == count { return .failure(lastError) }
        return .success(text)
    }

    var text: String { parts.joined(separator: " ") }

    var summary: String {
        "\(count) chunk\(count == 1 ? "" : "s")" + (skipped > 0 ? ", \(skipped) failed" : "")
    }
}

/// Text the model produced before it started repeating itself.
enum Loop {
    /// The longest phrase checked for repeats, in words.
    static let maxPhrase = 20
    /// A loop runs on for hundreds of tokens; real speech repeats a short
    /// phrase a few times at most ("no no no"). So the copies must span at
    /// least this many words, and there must be three or more of them.
    static let minSpan = 24

    /// The text decoded before a run stopped short: at its token cap
    /// (`outputTruncated`), or because transcribe.cpp saw the output start
    /// repeating and stopped early, the repeats already dropped
    /// (`outputRepetition`). Nil for any other error.
    static func partial(_ error: Error) -> String? {
        guard let error = error as? TranscribeError, error.isTruncated else { return nil }
        return error.partial?.text ?? ""
    }

    /// `text` up to the end of the first copy of the first phrase repeated
    /// back to back across `minSpan` words; unchanged when there is none.
    static func cut(_ text: String) -> String {
        let words = text.split(separator: " ")
        let keys = words.map { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        for start in keys.indices {
            for length in 1...maxPhrase {
                let copies = max(3, (minSpan + length - 1) / length)
                guard start + copies * length <= keys.count else { break }
                let phrase = keys[start..<(start + length)]
                let repeats = (1..<copies).allSatisfy {
                    keys[(start + $0 * length)..<(start + ($0 + 1) * length)].elementsEqual(phrase)
                }
                if repeats { return words[..<(start + length)].joined(separator: " ") }
            }
        }
        return text
    }
}

/// A recording transcribed while it is still being made. Once more than
/// `chunkSeconds` (after pauses are shortened) has arrived past the last cut,
/// the next piece is cut and decoded, the same cuts `Chunker.split` makes on
/// the whole clip, so the text matches. Stopping leaves only the last piece to decode, so the wait after
/// stop no longer grows with the length of the recording.
final class LiveTranscript {
    /// How often it checks for a full piece; a piece decodes in about 1 s.
    static let pollSeconds = 1.0

    private let transcriber: Transcriber
    private let chunker: Chunker
    private let recorded: (Int) -> [Float]
    private let progress: (String) -> Void
    private let timer: DispatchSourceTimer
    // Touched only on the transcriber's queue.
    private var decoded = 0
    private var pieces: Pieces

    /// `chunker` is fixed at the start: a config reload mid-recording must
    /// not move cuts already made.
    fileprivate init(transcriber: Transcriber, chunker: Chunker, recorded: @escaping (Int) -> [Float],
                     progress: @escaping (String) -> Void) {
        self.transcriber = transcriber
        self.chunker = chunker
        self.pieces = Pieces(chunker: chunker)
        self.recorded = recorded
        self.progress = progress
        // On the model's queue: polls wait behind a decode instead of piling up.
        timer = DispatchSource.makeTimerSource(queue: transcriber.queue)
        timer.schedule(deadline: .now() + Self.pollSeconds, repeating: Self.pollSeconds, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.advance() }
        timer.resume()
    }

    deinit { timer.cancel() }

    /// Stops cutting pieces; a decode in flight still finishes.
    func stop() { timer.cancel() }

    /// Decodes what is left of `pcm` (the whole recording) and hands back the
    /// full text. Completion runs on the transcriber's queue.
    func finish(_ pcm: [Float], completion: @escaping (Result<String, Error>) -> Void) {
        stop()
        transcriber.queue.async {
            let t0 = Date()
            let early = self.pieces.count
            let tail = self.decoded < pcm.count ? Array(pcm[self.decoded...]) : []
            for chunk in self.chunker.split(tail) where !chunk.isEmpty {
                self.pieces.take(chunk, with: self.transcriber)
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log("transcribed \(seconds(pcm.count)) s of audio (\(seconds(self.pieces.fed)) s after pauses) in \(ms) ms after stop (\(self.pieces.summary), \(early) while recording)")
            self.transcriber.scheduleUnload()
            completion(self.pieces.result)
        }
    }

    private func advance() {
        let pending = recorded(decoded)
        var start = 0
        while let cut = chunker.firstCut(pending[start...]) {
            pieces.take(Array(pending[start..<cut]), with: transcriber)
            decoded += cut - start
            start = cut
        }
        if start > 0 { progress(pieces.text) }
    }
}

/// Samples at 16 kHz as seconds, for the log.
private func seconds(_ samples: Int) -> String {
    String(format: "%.1f", Double(samples) / Recorder.targetRate)
}

enum DictateError: Error, CustomStringConvertible {
    case modelMissing(String)
    case notLoaded
    case audio(String)

    var description: String {
        switch self {
        case .modelMissing(let p): return "model not found at \(p); run scripts/fetch-model.sh"
        case .notLoaded: return "model not loaded"
        case .audio(let m): return "audio: \(m)"
        }
    }
}
