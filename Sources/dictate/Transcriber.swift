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
            let chunks = chunker.split(pcm)
            var at = 0
            for (i, chunk) in chunks.enumerated() {
                pieces.take(chunk, at: at, cut: i < chunks.count - 1, with: self)
                at += chunk.count
            }
            pieces.probe({ Array(pcm[min($0, pcm.count)..<min($1, pcm.count)]) }, done: true, with: self)
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

    /// Audio as the model gets it, pauses already shortened. On `queue` only.
    fileprivate func decode(_ audio: [Float], halvings: Int = 2) throws -> String {
        try load()
        guard let session else { throw DictateError.notLoaded }
        var options = RunOptions()
        options.language = config.language
        return try run(audio, session: session, options: options, halvings: halvings)
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
    private var parts: [Part] = []
    private(set) var fed = 0
    private var skipped = 0
    private var lastError: Error?
    private var probes = 0
    private var probeTime: TimeInterval = 0

    private struct Part {
        /// Empty when it had no speech, `gap` when it failed.
        var text: String
        /// Where it ends in the recording.
        let end: Int
        /// Its room level, which the probe of the cut at its end uses too.
        let threshold: Float
        /// Whether another piece follows, and so a seam to probe.
        let cut: Bool
        var probed = false
        /// What a decode across the cut heard.
        var probe: String?

        var spoken: Bool { !text.isEmpty && text != Pieces.gap }
    }

    init(chunker: Chunker) { self.chunker = chunker }

    var count: Int { parts.count }

    /// Decodes `chunk`, which starts `at` samples into the recording.
    mutating func take(_ chunk: [Float], at start: Int, cut: Bool, with transcriber: Transcriber) {
        let threshold = chunker.threshold(chunk[...])
        var part = Part(text: "", end: start + chunk.count, threshold: threshold, cut: cut)
        defer { parts.append(part) }
        if Silence.speechSeconds(chunk, rate: chunker.rate) < Silence.minSpeechSeconds {
            log("piece \(count + 1) of \(seconds(chunk.count)) s has no speech; skipped")
            return
        }
        do {
            let audio = Silence.squeeze(chunk, maxPause: chunker.maxPause, rate: chunker.rate, threshold: threshold)
            part.text = try transcriber.decode(audio)
            fed += audio.count
        } catch {
            log("piece \(count + 1) of \(seconds(chunk.count)) s failed: \(error)")
            skipped += 1
            lastError = error
            part.text = Self.gap
        }
    }

    /// Decodes a short stretch across each cut whose audio is in, so the
    /// seam's punctuation comes from a decode that heard both sides (`Seam`).
    /// `audio(from, to)` is the recording in that range, as far as it goes;
    /// `done` when the recording is over.
    mutating func probe(_ audio: (Int, Int) -> [Float], done: Bool, with transcriber: Transcriber) {
        let limit = Int(Chunker.probeLimit * Double(chunker.rate))
        for i in parts.indices where parts[i].cut && !parts[i].probed {
            let part = parts[i]
            guard part.spoken else { parts[i].probed = true; continue }
            let before = audio(max(0, part.end - limit), part.end)
            let after = audio(part.end, part.end + limit)
            guard let ahead = chunker.probeReach(after, threshold: part.threshold, complete: done),
                  let back = chunker.probeReach(before.reversed(), threshold: part.threshold, complete: true)
            else { continue }
            parts[i].probed = true
            let clip = Array(before.suffix(back) + after.prefix(ahead))
            guard Silence.speechSeconds(clip, rate: chunker.rate) >= Silence.minSpeechSeconds else { continue }
            let t0 = Date()
            do {
                let squeezed = Silence.squeeze(clip, maxPause: chunker.maxPause, rate: chunker.rate, threshold: part.threshold)
                parts[i].probe = try transcriber.decode(squeezed, halvings: 0)
            } catch {
                log("seam probe after piece \(i + 1) failed: \(error)")
            }
            probes += 1
            probeTime += Date().timeIntervalSince(t0)
        }
    }

    /// The text; a failure only when no piece decoded (a missing model, say).
    var result: Result<String, Error> {
        if let lastError, skipped == count { return .failure(lastError) }
        return .success(text)
    }

    var text: String { stitched.text }

    /// The pieces joined, each seam mended by its probe; also how many were.
    private var stitched: (text: String, joined: Int) {
        var texts = parts.map(\.text)
        var joined = 0
        for i in parts.indices.dropLast() where parts[i].spoken && parts[i + 1].spoken {
            guard let probe = parts[i].probe else { continue }
            let (left, right) = Seam.mend(texts[i], texts[i + 1], probe: probe)
            if left != texts[i] || right != texts[i + 1] { joined += 1 }
            (texts[i], texts[i + 1]) = (left, right)
        }
        return (texts.filter { !$0.isEmpty }.joined(separator: " "), joined)
    }

    var summary: String {
        "\(count) chunk\(count == 1 ? "" : "s")" + (skipped > 0 ? ", \(skipped) failed" : "")
            + (probes > 0 ? ", \(probes) seam\(probes == 1 ? "" : "s") probed in \(Int(probeTime * 1000)) ms, \(stitched.joined) joined" : "")
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
        let asked = Date()
        transcriber.queue.async {
            let t0 = Date()
            let waited = Int(t0.timeIntervalSince(asked) * 1000)
            if waited >= 50 { log("the last piece waited \(waited) ms for the model's queue") }
            let early = self.pieces.count
            let tail = self.decoded < pcm.count ? Array(pcm[self.decoded...]) : []
            let chunks = self.chunker.split(tail).filter { !$0.isEmpty }
            for (i, chunk) in chunks.enumerated() {
                self.pieces.take(chunk, at: self.decoded, cut: i < chunks.count - 1, with: self.transcriber)
                self.decoded += chunk.count
            }
            self.pieces.probe({ Array(pcm[min($0, pcm.count)..<min($1, pcm.count)]) }, done: true, with: self.transcriber)
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
            pieces.take(Array(pending[start..<cut]), at: decoded, cut: true, with: transcriber)
            decoded += cut - start
            start = cut
        }
        // Seams are probed while recording goes on, so stopping rarely waits on one.
        pieces.probe({ [recorded] from, to in Array(recorded(from).prefix(to - from)) }, done: false, with: transcriber)
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
