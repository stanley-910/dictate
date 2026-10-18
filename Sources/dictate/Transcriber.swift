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
            do {
                let t0 = Date()
                // The model decodes a whole clip in one pass and falls apart past
                // roughly half a minute (skips ahead, then loops the last sentence),
                // and the library does no long-form chunking for it. Cut at quiet
                // points and stitch the pieces.
                let chunks = Chunker.split(pcm, maxSeconds: self.config.chunkSeconds, rate: Int(Recorder.targetRate))
                var parts: [String] = []
                var fed = 0
                for chunk in chunks {
                    let piece = try self.decode(chunk)
                    if !piece.text.isEmpty { parts.append(piece.text) }
                    fed += piece.samples
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                log("transcribed \(seconds(pcm.count)) s of audio (\(seconds(fed)) s after pauses) in \(ms) ms (\(chunks.count) chunk\(chunks.count == 1 ? "" : "s"))")
                self.scheduleUnload()
                completion(.success(parts.joined(separator: " ")))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Starts transcribing a recording while it is still being made.
    /// `recorded(from:)` returns the audio from a sample index on, so far.
    func begin(recorded: @escaping (Int) -> [Float]) -> LiveTranscript {
        LiveTranscript(transcriber: self, maxSeconds: config.chunkSeconds, recorded: recorded)
    }

    /// One piece, long pauses shortened; also how many samples the model got.
    /// On `queue` only.
    fileprivate func decode(_ chunk: [Float]) throws -> (text: String, samples: Int) {
        try load()
        guard let session else { throw DictateError.notLoaded }
        var options = RunOptions()
        options.language = config.language
        let audio = Silence.squeeze(chunk, maxPause: config.maxPauseSeconds, rate: Int(Recorder.targetRate))
        let text = try session.run(audio, options: options).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, audio.count)
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

/// A recording transcribed while it is still being made. Once more than
/// `chunkSeconds` has arrived past the last cut, the next piece is cut and
/// decoded, the same cuts `Chunker.split` makes on the whole clip, so the text
/// matches. Stopping leaves only the last piece to decode, so the wait after
/// stop no longer grows with the length of the recording.
final class LiveTranscript {
    /// How often it checks for a full piece; a piece decodes in about 1 s.
    static let pollSeconds = 1.0

    private let transcriber: Transcriber
    private let maxSeconds: Double
    private let recorded: (Int) -> [Float]
    private let timer: DispatchSourceTimer
    // Touched only on the transcriber's queue.
    private var decoded = 0
    private var parts: [String] = []
    private var pieces = 0
    private var fed = 0
    private var failure: Error?

    fileprivate init(transcriber: Transcriber, maxSeconds: Double, recorded: @escaping (Int) -> [Float]) {
        self.transcriber = transcriber
        self.maxSeconds = maxSeconds
        self.recorded = recorded
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
            do {
                if let failure = self.failure { throw failure }
                let t0 = Date()
                let early = self.pieces
                let tail = self.decoded < pcm.count ? Array(pcm[self.decoded...]) : []
                for chunk in Chunker.split(tail, maxSeconds: self.maxSeconds, rate: Int(Recorder.targetRate)) where !chunk.isEmpty {
                    try self.take(chunk)
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                log("transcribed \(seconds(pcm.count)) s of audio (\(seconds(self.fed)) s after pauses) in \(ms) ms after stop (\(self.pieces) chunk\(self.pieces == 1 ? "" : "s"), \(early) while recording)")
                self.transcriber.scheduleUnload()
                completion(.success(self.parts.joined(separator: " ")))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func advance() {
        guard failure == nil else { return }
        let pending = recorded(decoded)
        var start = 0
        while let cut = Chunker.firstCut(pending[start...], maxSeconds: maxSeconds, rate: Int(Recorder.targetRate)) {
            do {
                try take(Array(pending[start..<cut]))
            } catch {
                failure = error
                return
            }
            decoded += cut - start
            start = cut
        }
    }

    private func take(_ chunk: [Float]) throws {
        let piece = try transcriber.decode(chunk)
        if !piece.text.isEmpty { parts.append(piece.text) }
        fed += piece.samples
        pieces += 1
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
