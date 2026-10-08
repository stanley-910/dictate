import AVFoundation
import Foundation

/// Decides when a hands-free recording is over, from the loudness of each
/// block: speech then `silenceMs` of quiet ends it; no speech within
/// `nothingMs` means nothing was said; `limitMs` stops it regardless.
/// Same rules as Stenographer's mic.ts.
struct EndOfSpeech {
    enum Outcome: Equatable { case speech, nothing }

    /// RMS below which nothing counts as speech, however quiet the room. AirPods
    /// in call mode sit quieter than a laptop mic; 0.01 is a whisper's floor.
    static let speechRMS: Float = 0.01
    /// Speech is this many times the room's noise floor. Measured 2026-10-08 on
    /// the MacBook mic: room 0.009–0.014 (a fixed 0.01 never heard the quiet
    /// after speech), soft speech 0.023–0.084.
    static let overFloor: Float = 2.5
    /// The mic's first blocks read near zero while it warms up; the floor skips them.
    static let warmupBlocks = 2
    /// Blocks averaged for the noise floor (300 ms at 100 ms blocks), so one
    /// quiet block does not drag the floor down.
    static let floorBlocks = 3
    /// Below this a block is the mic still waking (a slow AirPods switch reads
    /// zeros for longer than the warm-up), never a room: it never sets the floor.
    static let deadRMS: Float = 0.0005
    /// The floor is the quietest 300 ms of the last 5 s, so a wrong early
    /// estimate recovers.
    static let floorWindowBlocks = 50
    /// Sound above the threshold, in all, before it counts as speech: a click or
    /// a breath is one block.
    static let speechMinMs = 300

    var silenceMs = 2000
    var nothingMs = 8000
    var limitMs = 60000

    private var levels: [Float] = []
    private var blockMs = 100
    /// Quietest 300 ms average of the last 5 s, warm-up and dead blocks left out:
    /// the room with nobody talking.
    private(set) var floor: Float?

    /// The level a block must pass to count as speech.
    var threshold: Float { max(Self.speechRMS, (floor ?? 0) * Self.overFloor) }

    /// Whether enough sound above the threshold has come, judged against the
    /// floor as it stands now (speech before the floor was known counts once it is).
    var heard: Bool {
        guard floor != nil else { return false }
        let t = threshold
        return levels.reduce(0) { $1 > t ? $0 + blockMs : $0 } >= Self.speechMinMs
    }

    /// Feeds one block; returns an outcome once the recording should end.
    mutating func feed(rms: Float, ms: Int) -> Outcome? {
        blockMs = ms
        levels.append(rms)
        let n = levels.count
        let from = max(Self.warmupBlocks, n - Self.floorWindowBlocks)
        var lowest: Float?
        if n - from >= Self.floorBlocks {
            for start in from...(n - Self.floorBlocks) {
                let window = levels[start..<(start + Self.floorBlocks)]
                if window.contains(where: { $0 < Self.deadRMS }) { continue }
                let avg = window.reduce(0, +) / Float(Self.floorBlocks)
                lowest = min(lowest ?? avg, avg)
            }
        }
        floor = lowest
        let elapsedMs = n * ms
        if heard {
            let t = threshold
            let lastLoud = levels.lastIndex { $0 > t } ?? 0
            if (n - 1 - lastLoud) * ms >= silenceMs { return .speech }
        } else if elapsedMs >= nothingMs {
            return .nothing
        }
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
    /// `--levels`: each block's RMS and the speech threshold on stderr, for tuning.
    private static var traceLevels = false
    private static var ended = false
    /// Set first by SIGINT/SIGTERM; a transcript that finishes later is dropped.
    private static var cancelled = false
    private static var tearingDown = false
    /// Read by the exit paths off the main queue; cancellation's code wins.
    private static var exitCode: Int32 = 0
    private static let exitLock = NSLock()
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
            if flag == "--levels" {
                traceLevels = true
                i += 1
                continue
            }
            guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
                fail("usage: dictate listen [--silence-ms 2000] [--nothing-ms 8000] [--limit-ms 60000] [--levels]")
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
            cancelled = true
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
        let outcome = detector.feed(rms: rms, ms: ms)
        if traceLevels {
            FileHandle.standardError.write(String(format: "level %.4f threshold %.4f\n", rms, detector.threshold).data(using: .utf8)!)
        }
        if let outcome { end(outcome) }
    }

    private static func end(_ outcome: EndOfSpeech.Outcome) {
        guard !ended, let d = dictation else { return }
        ended = true
        let (pcm, seconds) = d.stop()
        guard outcome == .speech, !d.isTooShort(seconds) else { teardown(code: 0); return }
        d.text(from: pcm) { result in
            DispatchQueue.main.async {
                guard !cancelled else { return }
                switch result {
                case .success(let text):
                    // Unbuffered: the fallback _exit would drop a buffered print.
                    if !text.isEmpty { FileHandle.standardOutput.write((text + "\n").data(using: .utf8)!) }
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
    /// Runs once, on the main queue; a signal arriving later only replaces the
    /// exit code.
    private static func teardown(code: Int32) {
        exitLock.lock()
        if cancelled || !tearingDown { exitCode = code }
        exitLock.unlock()
        guard !tearingDown else { return }
        tearingDown = true
        guard let d = dictation else { exit(code) }
        _ = d.stop()
        DispatchQueue.global().async {
            d.transcriber.unloadSync()
            exit(currentExitCode())
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _exit(currentExitCode()) }
    }

    private static func currentExitCode() -> Int32 {
        exitLock.lock(); defer { exitLock.unlock() }
        return exitCode
    }
}
