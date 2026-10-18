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

    /// `pcm` with every quiet run longer than `maxPause` seconds cut down to
    /// `maxPause`, half kept at each end. `maxPause` 0 returns it unchanged.
    static func squeeze(_ pcm: [Float], maxPause: Double, rate: Int) -> [Float] {
        let frame = max(1, Int(frameSeconds * Double(rate)))
        let frames = pcm.count / frame
        let maxFrames = Int(maxPause / frameSeconds)
        guard maxPause > 0, frames > maxFrames else { return pcm }

        var levels = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var e: Float = 0
            for v in pcm[(f * frame)..<((f + 1) * frame)] { e += v * v }
            levels[f] = (e / Float(frame)).squareRoot()
        }
        let room = levels.sorted()[Int(Double(frames - 1) * floorPercentile)]
        let threshold = max(minimumRMS, room * overFloor)

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
                out.append(contentsOf: pcm[copied..<((f + keepHead) * frame)])
                copied = (end - keepTail) * frame
            }
            f = end
        }
        out.append(contentsOf: pcm[copied...])
        return out
    }
}
