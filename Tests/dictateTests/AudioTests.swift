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
        let pieces = Chunker.split(pcm, maxSeconds: 30, rate: Self.rate)
        #expect(pieces.count == 2)
        #expect(pieces.map(\.count).reduce(0, +) == pcm.count)
        let cut = Double(pieces[0].count) / Double(Self.rate)
        #expect(cut > 22 && cut < 23)
    }

    @Test func shortAudioIsOnePiece() {
        #expect(Chunker.split(Self.tone(5, amplitude: 0.1), maxSeconds: 30, rate: Self.rate).count == 1)
    }

    @Test func squeezeShortensLongPauses() {
        let pcm = Self.tone(1, amplitude: 0.1) + [Float](repeating: 0, count: 5 * Self.rate) + Self.tone(1, amplitude: 0.1)
        let out = Silence.squeeze(pcm, maxPause: 1, rate: Self.rate)
        let seconds = Double(out.count) / Double(Self.rate)
        #expect(seconds > 2.9 && seconds < 3.1)
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
