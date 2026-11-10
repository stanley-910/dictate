import Foundation
import Testing
@testable import dictate
import TranscribeCpp

/// Signals made here rather than fixtures: the gate and the cuts depend only
/// on levels.
struct AudioTests {
    static let rate = 16_000

    /// A tone at `amplitude` for `seconds`.
    static func tone(_ seconds: Double, amplitude: Float, hz: Float = 220) -> [Float] {
        let step = 2 * Float.pi * hz / Float(rate)
        return (0..<Int(seconds * Double(rate))).map { (k: Int) -> Float in amplitude * sinf(step * Float(k)) }
    }

    static func noise(_ seconds: Double, amplitude: Float) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -amplitude...amplitude, using: &g) }
    }

    @Test func silenceHasNoSpeech() {
        #expect(Silence.speechSeconds([Float](repeating: 0, count: 3 * Self.rate), rate: Self.rate) == 0)
    }

    @Test func roomNoiseHasNoSpeech() {
        #expect(Silence.speechSeconds(Self.noise(3, amplitude: 0.004), rate: Self.rate) < Silence.minSpeechSeconds)
    }

    @Test func clicksAreNotSpeech() {
        var pcm = Self.noise(5, amplitude: 0.002)
        // Ten 20 ms clicks, each inside one 100 ms block.
        for k in 0..<10 {
            let at = k * Self.rate / 2 + 400
            for j in 0..<320 { pcm[at + j] = 0.5 }
        }
        #expect(Silence.speechSeconds(pcm, rate: Self.rate) < Silence.minSpeechSeconds)
    }

    @Test func speechCounts() {
        let pcm = Self.noise(1, amplitude: 0.002) + Self.tone(1, amplitude: 0.1) + Self.noise(1, amplitude: 0.002)
        let s = Silence.speechSeconds(pcm, rate: Self.rate)
        #expect(s > 0.8 && s < 1.2)
    }

    @Test func speechFromEndToEndCounts() {
        // Talking the whole clip: the quietest tenth is speech, not room.
        #expect(Silence.speechSeconds(Self.tone(3, amplitude: 0.1), rate: Self.rate) > 2)
    }

    @Test func chunkerCutsInTheGap() {
        // 20 s loud, a quiet gap at 22-23 s, then loud: a 30 s limit cuts there.
        let pcm = Self.tone(22, amplitude: 0.1) + [Float](repeating: 0, count: Self.rate) + Self.tone(20, amplitude: 0.1)
        let pieces = Chunker(maxSeconds: 30, maxPause: 0, rate: Self.rate).split(pcm)
        #expect(pieces.count == 2)
        #expect(pieces.map(\.count).reduce(0, +) == pcm.count)
        let cut = Double(pieces[0].count) / Double(Self.rate)
        #expect(cut > 22 && cut < 23)
    }

    @Test func shortAudioIsOnePiece() {
        #expect(Chunker(maxSeconds: 30, maxPause: 0.6, rate: Self.rate).split(Self.tone(5, amplitude: 0.1)).count == 1)
    }

    /// Talk in bursts of `talk` seconds with `pause` seconds of room noise
    /// between, for `seconds` in all; a seeded generator, so runs repeat.
    static func speech(_ seconds: Double, talk: ClosedRange<Double>, pause: ClosedRange<Double>, seed: UInt64 = 1) -> [Float] {
        var g = Seeded(seed)
        var pcm: [Float] = []
        while Double(pcm.count) < seconds * Double(rate) {
            let n = Int(Double.random(in: talk, using: &g) * Double(rate))
            let hz = Float.random(in: 150...300, using: &g)
            let step = 2 * Float.pi * hz / Float(rate)
            pcm += (0..<n).map { 0.1 * sinf(step * Float($0)) + Float.random(in: -0.002...0.002, using: &g) }
            pcm += (0..<Int(Double.random(in: pause, using: &g) * Double(rate))).map { _ in Float.random(in: -0.002...0.002, using: &g) }
        }
        return Array(pcm.prefix(Int(seconds * Double(rate))))
    }

    @Test func piecesAreCappedAfterPausesAreShortened() {
        // 2 s pauses squeeze to 0.6 s: 50 s of recording feeds the model about
        // 26 s, one piece. Kept whole, the pauses make it two.
        let pcm = Self.speech(50, talk: 1...1, pause: 2...2)
        #expect(Chunker(maxSeconds: 30, maxPause: 0.6, rate: Self.rate).split(pcm).count == 1)
        #expect(Chunker(maxSeconds: 30, maxPause: 0, rate: Self.rate).split(pcm).count == 2)
    }

    @Test(arguments: [0, 0.3, 0.6])
    func squeezedPiecesFit(maxPause: Double) {
        let chunker = Chunker(maxSeconds: 30, maxPause: maxPause, rate: Self.rate)
        let pcm = Self.speech(200, talk: 0.5...4, pause: 0.1...3)
        let pieces = chunker.split(pcm)
        #expect(pieces.count > 4)
        #expect(pieces.map(\.count).reduce(0, +) == pcm.count)
        for piece in pieces.dropLast() {
            let fed = Double(chunker.squeeze(piece).count) / Double(Self.rate)
            #expect(fed <= 30 && fed >= 30 * Chunker.earliestCut - 0.1)
        }
    }

    @Test(arguments: [0, 0.6])
    func liveCutsMatchSplit(maxPause: Double) {
        // `LiveTranscript` cuts audio as it arrives, a second at a time, and
        // splits what is left at stop; that must give the same pieces.
        let chunker = Chunker(maxSeconds: 30, maxPause: maxPause, rate: Self.rate)
        let pcm = Self.speech(200, talk: 0.5...4, pause: 0.1...3, seed: 7)
        var live: [Int] = []
        var start = 0
        for now in stride(from: Self.rate, through: pcm.count, by: Self.rate) {
            while let cut = chunker.firstCut(pcm[start..<now]) { live.append(cut); start = cut }
        }
        while let cut = chunker.firstCut(pcm[start...]) { live.append(cut); start = cut }
        var offline: [Int] = []
        var at = 0
        for piece in chunker.split(pcm).dropLast() { at += piece.count; offline.append(at) }
        #expect(live == offline)
        #expect(offline.count > 4)
    }

    @Test func squeezeShortensLongPauses() {
        let pcm = Self.tone(1, amplitude: 0.1) + [Float](repeating: 0, count: 5 * Self.rate) + Self.tone(1, amplitude: 0.1)
        let out = Silence.squeeze(pcm, maxPause: 1, rate: Self.rate)
        let seconds = Double(out.count) / Double(Self.rate)
        #expect(seconds > 2.9 && seconds < 3.1)
    }
}

/// SplitMix64, so generated audio is the same on every run.
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct LoopTests {
    @Test func cutsARunawayRepeat() {
        let start = "So here is what it said"
        let loop = Array(repeating: "about the people who are talking", count: 12).joined(separator: " ")
        #expect(Loop.cut(start + " " + loop) == start + " about the people who are talking")
    }

    @Test(arguments: ["No no no, not that one.", "very very very good", "ha ha ha ha ha ha"])
    func keepsShortRepeats(_ text: String) {
        #expect(Loop.cut(text) == text)
    }

    /// Both ways a decode stops short are retried in halves; other errors are not.
    @Test func stoppedShortRunsKeepTheirText() {
        #expect(Loop.partial(TranscribeError.outputTruncated(message: "", partial: nil)) == "")
        #expect(Loop.partial(TranscribeError.outputRepetition(message: "", partial: nil)) == "")
        #expect(Loop.partial(TranscribeError.aborted(message: "", partial: nil)) == nil)
        #expect(Loop.partial(TranscribeError.inputTooLong("")) == nil)
        #expect(Loop.partial(DictateError.notLoaded) == nil)
    }
}
