import Foundation

/// Splits long audio into pieces the model can decode in one pass, cutting
/// where the signal is quietest so a word is not sliced in half.
///
/// The limit is on what the model is fed, after `Silence.squeeze` shortens
/// the pauses: a piece with long pauses in it may span more than `maxSeconds`
/// of recording. Each cut is the user's pause, and every cut is a place the
/// model may end a sentence, so the fewer the better.
struct Chunker {
    /// Frame length used to measure loudness (20 ms at 16 kHz).
    static let frameSeconds = Silence.frameSeconds
    /// Cuts land no earlier than this fraction of `maxSeconds` into a piece.
    static let earliestCut = 0.6

    /// Longest a piece may be once squeezed; 0 = never split.
    let maxSeconds: Double
    /// `Silence.squeeze`'s pause cap; 0 = pauses kept whole.
    let maxPause: Double
    let rate: Int

    var frame: Int { max(1, Int(Self.frameSeconds * Double(rate))) }
    private var maxFrames: Int { Int(maxSeconds * Double(rate)) / frame }
    private var minFrames: Int { Int(Double(maxFrames) * Self.earliestCut) }

    /// Frames at the start of a piece that set its room level. Never more
    /// than the earliest cut, so the level is known before the cut is made
    /// and is the same whether the piece is cut live or from the whole clip.
    var roomFrames: Int { maxSeconds > 0 ? minFrames : .max }

    func split(_ pcm: [Float]) -> [[Float]] {
        var pieces: [[Float]] = []
        var start = 0
        while let cut = firstCut(pcm[start...]) {
            pieces.append(Array(pcm[start..<cut]))
            start = cut
        }
        pieces.append(Array(pcm[start...]))
        return pieces
    }

    /// The speech threshold `squeeze` uses for a piece.
    func threshold(_ piece: ArraySlice<Float>) -> Float {
        Silence.threshold(Silence.levels(piece, frame: frame, limit: roomFrames)[...])
    }

    /// The piece as the model gets it.
    func squeeze(_ piece: [Float]) -> [Float] {
        Silence.squeeze(piece, maxPause: maxPause, rate: rate, threshold: threshold(piece[...]))
    }

    /// Where the first piece of `pcm` ends (an index into its base array), or
    /// nil while it still fits in one piece. Depends only on audio up to the
    /// cut's latest place, so audio still arriving can be cut as it comes.
    func firstCut(_ pcm: ArraySlice<Float>) -> Int? {
        let maxFrames = self.maxFrames
        // Squeezing only shortens, so nothing under the limit raw needs a cut.
        guard maxSeconds > 0, pcm.count > maxFrames * frame else { return nil }
        let room = Silence.levels(pcm, frame: frame, limit: roomFrames)
        guard room.count == roomFrames else { return nil }
        var kept = Silence.Kept(threshold: Silence.threshold(room[...]), maxPause: maxPause)
        // Frames are measured from the piece's start, as `squeeze` measures them.
        var levels: [Float] = []
        var keptBefore: [Int] = []  // frames fed before frame f
        var f = 0
        while kept.frames <= maxFrames {
            let at = pcm.startIndex + f * frame
            guard at + frame <= pcm.endIndex else { return nil }  // not past the limit yet
            let level = f < room.count ? room[f] : Silence.level(pcm[at..<(at + frame)])
            keptBefore.append(kept.frames)
            levels.append(level)
            kept.add(level)
            f += 1
        }
        // A cut in frame f feeds keptBefore[f] frames and half of f.
        let candidates = levels.indices.filter { keptBefore[$0] >= minFrames && keptBefore[$0] < maxFrames }
        guard let best = Self.quietest(candidates, levels: levels) else { return nil }
        return pcm.startIndex + best * frame + frame / 2
    }

    /// A seam probe takes this much fed audio from each side of a cut, ending
    /// at the quietest point in the range.
    static let probeSide = 3.0...5.0
    /// And never reaches more than this much recording from the cut.
    static let probeLimit = 15.0

    /// How far a probe reaches from a cut into `side`, the audio leading away
    /// from it (reversed for the audio before the cut), in samples. Quiet is
    /// by `threshold`, the room of the piece before the cut. nil until
    /// enough has arrived to tell; `complete` when no more is coming. Never
    /// depends on audio past the point it returns.
    func probeReach(_ side: [Float], threshold: Float, complete: Bool) -> Int? {
        let limit = Int(Self.probeLimit * Double(rate))
        let side = side.prefix(limit)
        let complete = complete || side.count == limit
        let fps = 1 / Self.frameSeconds
        let least = Int(Self.probeSide.lowerBound * fps), most = Int(Self.probeSide.upperBound * fps)
        var kept = Silence.Kept(threshold: threshold, maxPause: maxPause)
        var levels: [Float] = []
        var keptBefore: [Int] = []
        while kept.frames <= most {
            let at = levels.count * frame
            guard at + frame <= side.count else {
                guard complete else { return nil }
                break
            }
            keptBefore.append(kept.frames)
            levels.append(Silence.level(side[at..<(at + frame)]))
            kept.add(levels[levels.count - 1])
        }
        let candidates = levels.indices.filter { keptBefore[$0] >= least && keptBefore[$0] < most }
        guard let best = Self.quietest(candidates, levels: levels) else { return side.count }
        return best * frame + frame / 2
    }

    /// Where to halve a piece the model could not decode: the quietest point in
    /// its middle third, so neither half is much shorter than the other.
    static func middleCut(_ pcm: [Float], rate: Int) -> Int {
        let frame = max(1, Int(frameSeconds * Double(rate)))
        var best = pcm.count * 2 / 3
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = pcm.count / 3
        while i + frame <= pcm.count * 2 / 3 {
            var e: Float = 0
            for v in pcm[i..<(i + frame)] { e += v * v }
            if e <= bestEnergy { bestEnergy = e; best = i + frame / 2 }
            i += frame
        }
        return best
    }

    /// The lowest-energy frame among `frames`. Ties go to the later frame so
    /// pieces stay as long as they can.
    static func quietest(_ frames: [Int], levels: [Float]) -> Int? {
        var best: Int?
        var bestLevel = Float.greatestFiniteMagnitude
        for f in frames where levels[f] <= bestLevel {
            best = f
            bestLevel = levels[f]
        }
        return best
    }
}

extension Chunker {
    init(config: Config) {
        self.init(maxSeconds: config.chunkSeconds, maxPause: config.maxPauseSeconds, rate: Int(Recorder.targetRate))
    }
}
