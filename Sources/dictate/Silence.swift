import Foundation

/// Shortens long pauses before audio reaches the model, which spends as long
/// on silence as on speech. Pauses are shortened, never removed: the model
/// places sentence breaks from them, and the kept edges hold the soft starts
/// and ends of words that measure as quiet.
enum Silence {
    /// Frame length used to measure loudness (20 ms at 16 kHz).
    static let frameSeconds = 0.02
    /// The room's level is the quietest tenth of the piece's frames.
    static let floorPercentile = 0.1
    /// A frame is speech above this many times the room. Lower than `dictate
    /// listen`'s 2.5: here a miss drops words, so it errs toward keeping sound.
    static let overFloor: Float = 2
    /// Floor for the threshold when the room reads as digital silence.
    static let minimumRMS: Float = 0.002
    /// Crossfade where a pause is shortened. Equal-power: both ends are
    /// room noise, unrelated, so the level holds through the join.
    static let fadeSeconds = 0.015

    /// `pcm` with every quiet run longer than `maxPause` seconds cut down to
    /// `maxPause`, half kept at each end. `maxPause` 0 returns it unchanged.
    /// Quiet is below `threshold`, by default set from the whole clip's room.
    static func squeeze(_ pcm: [Float], maxPause: Double, rate: Int, threshold: Float? = nil) -> [Float] {
        let frame = max(1, Int(frameSeconds * Double(rate)))
        let frames = pcm.count / frame
        guard let maxFrames = pauseFrames(maxPause), frames > maxFrames else { return pcm }

        let levels = Silence.levels(pcm[...], frame: frame)
        let threshold = threshold ?? Silence.threshold(levels[...])

        let fade = Int(fadeSeconds * Double(rate))
        let keepHead = maxFrames / 2
        let keepTail = maxFrames - keepHead
        var out: [Float] = []
        out.reserveCapacity(pcm.count)
        var copied = 0  // samples of pcm already handled
        var f = 0
        while f < frames {
            guard levels[f] <= threshold else { f += 1; continue }
            var end = f
            while end < frames && levels[end] <= threshold { end += 1 }
            if end - f > maxFrames {
                // Blend across the join rather than butt the two ends: a step
                // in the room noise is a click, and the model hears a break.
                // Centred on the cut, so the length is what a hard cut gives.
                let out1 = (f + keepHead) * frame, in2 = (end - keepTail) * frame
                let half = min(fade / 2, out1 - copied, pcm.count - in2)
                out.append(contentsOf: pcm[copied..<(out1 - half)])
                for k in 0..<(2 * half) {
                    let w = (Float(k) + 0.5) / Float(2 * half) * .pi / 2
                    out.append(pcm[out1 - half + k] * cos(w) + pcm[in2 - half + k] * sin(w))
                }
                copied = in2 + half
            }
            f = end
        }
        out.append(contentsOf: pcm[copied...])
        return out
    }

    /// The longest quiet run `squeeze` keeps, in frames; nil when it keeps all.
    static func pauseFrames(_ maxPause: Double) -> Int? {
        maxPause > 0 ? Int(maxPause / frameSeconds) : nil
    }

    /// RMS of each whole frame of `pcm`, at most `limit` of them.
    static func levels(_ pcm: ArraySlice<Float>, frame: Int, limit: Int = .max) -> [Float] {
        let count = min(limit, pcm.count / frame)
        return (0..<count).map { f in
            let at = pcm.startIndex + f * frame
            return level(pcm[at..<(at + frame)])
        }
    }

    static func level(_ frame: ArraySlice<Float>) -> Float {
        var e: Float = 0
        for v in frame { e += v * v }
        return (e / Float(max(1, frame.count))).squareRoot()
    }

    /// Frames at or below this are quiet: twice the room, the quietest tenth.
    static func threshold(_ levels: ArraySlice<Float>) -> Float {
        guard !levels.isEmpty else { return minimumRMS }
        let room = levels.sorted()[Int(Double(levels.count - 1) * floorPercentile)]
        return max(minimumRMS, room * overFloor)
    }

    /// How many frames `squeeze` keeps of audio heard so far, one frame at a
    /// time. A quiet run still open counts as `squeeze` would count it if
    /// the audio ended there, so the count never depends on what comes next.
    struct Kept {
        let threshold: Float
        let maxRun: Int?
        private var settled = 0
        private var run = 0

        init(threshold: Float, maxPause: Double) {
            self.threshold = threshold
            self.maxRun = Silence.pauseFrames(maxPause)
        }

        var frames: Int { settled + min(run, maxRun ?? run) }

        mutating func add(_ level: Float) {
            if level <= threshold { run += 1; return }
            settled = frames + 1
            run = 0
        }
    }

    /// Less speech than this and a piece is not decoded: on room noise or
    /// silence the model makes up "Thank you." and the like.
    static let minSpeechSeconds = 0.2
    /// The room estimate is capped here, the top of the rooms measured for
    /// `EndOfSpeech.overFloor`: in a clip that is talking from end to end the
    /// quietest tenth is speech, and the threshold would rise above it.
    static let loudestRoom: Float = 0.015
    /// Loudness is judged in 100 ms blocks, as `dictate listen` does.
    private static let blockSeconds = 0.1

    /// A room louder than this is judged again with its rumble filtered out.
    static let noisyRoom: Float = 0.008
    /// Below this is rumble (a fan, a desk, traffic), not the part of a
    /// voice the check needs.
    static let rumbleHz = 200.0
    /// `EndOfSpeech.speechRMS` for audio with the rumble taken out, which
    /// takes the low part of the voice with it.
    static let filteredSpeechRMS: Float = 0.004

    /// Seconds of speech in `pcm`, by `dictate listen`'s rule: blocks above
    /// both `EndOfSpeech.speechRMS` and `EndOfSpeech.overFloor` times the room
    /// (the quietest tenth of the blocks, at most `loudestRoom`). Only runs of two or more blocks
    /// count; a key click or a tap on the desk fills one. A loud steady
    /// rumble hides a voice from that rule, so when it finds nothing in a
    /// noisy room the same rule is tried on the audio above `rumbleHz`.
    static func speechSeconds(_ pcm: [Float], rate: Int) -> Double {
        let (seconds, room) = speech(pcm, rate: rate, floor: EndOfSpeech.speechRMS)
        guard seconds < minSpeechSeconds, room > noisyRoom else { return seconds }
        return max(seconds, speech(highPass(pcm, rate: rate), rate: rate, floor: filteredSpeechRMS).seconds)
    }

    /// `pcm` without what is below `rumbleHz`: two second-order high-pass
    /// filters in a row (24 dB per octave).
    static func highPass(_ pcm: [Float], rate: Int) -> [Float] {
        let w = 2 * Double.pi * rumbleHz / Double(rate)
        let alpha = sin(w) / (2 * 0.5.squareRoot())
        let a0 = 1 + alpha
        let b0 = Float((1 + cos(w)) / 2 / a0), b1 = Float(-(1 + cos(w)) / a0)
        let a1 = Float(-2 * cos(w) / a0), a2 = Float((1 - alpha) / a0)
        var out = pcm
        for _ in 0..<2 {
            var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
            for i in out.indices {
                let x = out[i]
                let y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                out[i] = y
            }
        }
        return out
    }

    /// Seconds of speech by the rule above with `floor` as the least a
    /// speech block can measure, and the room's level before its cap.
    private static func speech(_ pcm: [Float], rate: Int, floor: Float) -> (seconds: Double, room: Float) {
        let block = max(1, Int(blockSeconds * Double(rate)))
        var levels: [Float] = []
        var i = 0
        while i + block <= pcm.count {
            var e: Float = 0
            for v in pcm[i..<(i + block)] { e += v * v }
            levels.append((e / Float(block)).squareRoot())
            i += block
        }
        // A mic still waking reads zeros; that is not the room.
        let live = levels.filter { $0 > EndOfSpeech.deadRMS }.sorted()
        guard !live.isEmpty else { return (0, 0) }
        let heard = live[Int(Double(live.count - 1) * floorPercentile)]
        let threshold = max(floor, min(loudestRoom, heard) * EndOfSpeech.overFloor)
        var run = 0, total = 0
        for level in levels + [0] {
            if level > threshold { run += 1; continue }
            if run >= 2 { total += run }
            run = 0
        }
        return (Double(total) * blockSeconds, heard)
    }
}
