import Foundation
import TranscribeCpp

/// Owns the model. Loads lazily on first use and drops it after an idle period
/// so the process sits at a few MB when you are not dictating.
final class Transcriber {
    var config: Config
    private var model: Model?
    private var session: Session?
    private var idleTimer: Timer?
    private let queue = DispatchQueue(label: "dictate.transcriber")

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
                try self.load()
                guard let session = self.session else { throw DictateError.notLoaded }
                var options = RunOptions()
                options.language = self.config.language
                let t0 = Date()
                let transcript = try session.run(pcm, options: options)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                log("transcribed \(String(format: "%.1f", Double(pcm.count) / 16000)) s of audio in \(ms) ms")
                self.scheduleUnload()
                completion(.success(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func scheduleUnload() {
        guard config.unloadAfterSeconds > 0 else { return }
        DispatchQueue.main.async {
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: self.config.unloadAfterSeconds, repeats: false) { _ in
                self.queue.async { self.unload() }
            }
        }
    }
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
