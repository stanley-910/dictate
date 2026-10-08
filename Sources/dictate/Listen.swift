import AVFoundation
import Foundation

/// Decides when a hands-free recording is over, from the loudness of each
/// block: speech then `silenceMs` of quiet ends it; no speech within
/// `nothingMs` means nothing was said; `limitMs` stops it regardless.
/// Same rules as Stenographer's mic.ts.
struct EndOfSpeech {
    enum Outcome: Equatable { case speech, nothing }

    /// RMS above which a block counts as speech. AirPods in call mode sit
    /// quieter than a laptop mic; 0.01 is a whisper's floor.
    static let speechRMS: Float = 0.01

    var silenceMs = 2000
    var nothingMs = 8000
    var limitMs = 60000

    private(set) var heard = false
    private var quietMs = 0
    private var elapsedMs = 0

    /// Feeds one block; returns an outcome once the recording should end.
    mutating func feed(rms: Float, ms: Int) -> Outcome? {
        elapsedMs += ms
        if rms > Self.speechRMS {
            heard = true
            quietMs = 0
        } else {
            quietMs += ms
        }
        if heard && quietMs >= silenceMs { return .speech }
        if !heard && elapsedMs >= nothingMs { return .nothing }
        if elapsedMs >= limitMs { return heard ? .speech : .nothing }
        return nil
    }
}

/// `dictate listen`: record from the selected mic until speech ends, print the
/// transcript on stdout. stderr carries `ready` and, on failure, one error line.
enum Listen {
    private static var dictation: Dictation?
    private static var detector = EndOfSpeech()
    private static var readySent = false
    private static var ended = false
    private static var signalSources: [DispatchSourceSignal] = []

    static func run(_ args: [String]) -> Never {
        logEnabled = false
        parse(args)
        let config = Config.load()

        guard FileManager.default.fileExists(atPath: config.modelURL.path) else {
            fail("\(DictateError.modelMissing(config.modelURL.path))")
        }
        guard micAllowed() else {
            fail("microphone access denied: System Settings > Privacy & Security > Microphone")
        }
        guard AudioDevices.resolve(configured: config.microphone) != nil else {
            fail("no input device")
        }

        let d = Dictation(config: config)
        dictation = d
        trap(SIGINT, code: 130)
        trap(SIGTERM, code: 143)

        d.recorder.onLevel = { rms, frames in
            let ms = frames * 1000 / Int(Recorder.targetRate)
            DispatchQueue.main.async { block(rms: rms, ms: ms) }
        }
        do {
            try d.start()
        } catch {
            d.shutdown()
            fail("\(error)")
        }
        d.muteSpeakersIfConfigured()
        // Backstop in case the device never delivers a buffer.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(detector.limitMs + 1000)) {
            end(detector.heard ? .speech : .nothing)
        }
        dispatchMain()
    }

    private static func parse(_ args: [String]) {
        var i = 0
        while i < args.count {
            let flag = args[i]
            guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
                fail("usage: dictate listen [--silence-ms 2000] [--nothing-ms 8000] [--limit-ms 60000]")
            }
            switch flag {
            case "--silence-ms": detector.silenceMs = n
            case "--nothing-ms": detector.nothingMs = n
            case "--limit-ms": detector.limitMs = n
            default: fail("unknown option \(flag)")
            }
            i += 2
        }
    }

    /// Without access the queue records silence instead of failing, so ask
    /// first. TCC answers for the responsible app (the terminal, or Obsidian).
    private static func micAllowed() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                ok = granted
                sem.signal()
            }
            sem.wait()
            return ok
        default: return false
        }
    }

    private static func trap(_ sig: Int32, code: Int32) {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            ended = true
            teardown(code: code)
        }
        source.resume()
        signalSources.append(source)
    }

    private static func block(rms: Float, ms: Int) {
        guard !ended else { return }
        if !readySent {
            readySent = true
            FileHandle.standardError.write("ready\n".data(using: .utf8)!)
        }
        if let outcome = detector.feed(rms: rms, ms: ms) { end(outcome) }
    }

    private static func end(_ outcome: EndOfSpeech.Outcome) {
        guard !ended, let d = dictation else { return }
        ended = true
        let (pcm, seconds) = d.stop()
        guard outcome == .speech, !d.isTooShort(seconds) else { teardown(code: 0); return }
        d.text(from: pcm) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    if !text.isEmpty { print(text) }
                    teardown(code: 0)
                case .failure(let error):
                    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
                    teardown(code: 1)
                }
            }
        }
    }

    /// Releases the mic and speakers at once (the caller SIGKILLs after 3 s),
    /// then unloads the model off the main queue so signal handlers stay
    /// runnable; the unload waits behind any load or inference in flight, so
    /// after 2 s it _exits, skipping the C++ teardown that asserts on a live model.
    private static func teardown(code: Int32) {
        guard let d = dictation else { exit(code) }
        _ = d.stop()
        DispatchQueue.global().async {
            d.transcriber.unloadSync()
            exit(code)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _exit(code) }
    }
}
