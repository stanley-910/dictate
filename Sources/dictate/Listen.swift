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
    /// Speech is this many times the room's noise floor. A fixed threshold alone
    /// never heard the quiet after speech on the MacBook mic (room noise sat above
    /// 0.01, so every answer ran to the limit).
    static let overFloor: Float = 3
    /// Blocks averaged for the noise floor (300 ms at 100 ms blocks), so one
    /// quiet block does not drag the floor down.
    static let floorBlocks = 3

    var silenceMs = 2000
    var nothingMs = 8000
    var limitMs = 60000

    private(set) var heard = false
    private var quietMs = 0
    private var elapsedMs = 0
    private var recent: [Float] = []
    /// Lowest 300 ms average seen: the room with nobody talking.
    private(set) var floor: Float?
    /// Loudest block so far: speech before the floor was known still counts once it is.
    private var peak: Float = 0

    /// The level a block must pass to count as speech.
    var threshold: Float { max(Self.speechRMS, (floor ?? 0) * Self.overFloor) }

    /// Feeds one block; returns an outcome once the recording should end.
    mutating func feed(rms: Float, ms: Int) -> Outcome? {
        elapsedMs += ms
        recent.append(rms)
        if recent.count > Self.floorBlocks { recent.removeFirst() }
        if recent.count == Self.floorBlocks {
            let avg = recent.reduce(0, +) / Float(recent.count)
            floor = min(floor ?? avg, avg)
        }
        peak = max(peak, rms)
        if floor == nil {
            // The first 300 ms only measure the room; speech in them counts through `peak`.
        } else if rms > threshold {
            heard = true
            quietMs = 0
        } else {
            quietMs += ms
            // The floor only now fell below speech heard earlier: the quiet starts here.
            if !heard && peak > threshold {
                heard = true
                quietMs = ms
            }
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
