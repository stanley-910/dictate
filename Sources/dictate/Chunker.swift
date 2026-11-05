import Foundation

/// Splits long audio into pieces the model can decode in one pass, cutting
/// where the signal is quietest so a word is not sliced in half.
enum Chunker {
    /// Frame length used to measure loudness (20 ms at 16 kHz).
    static let frameSeconds = 0.02
    /// Cuts land no earlier than this fraction of `maxSeconds` into a piece.
    static let earliestCut = 0.6

    static func split(_ pcm: [Float], maxSeconds: Double, rate: Int) -> [[Float]] {
        var pieces: [[Float]] = []
        var start = 0
        while let cut = firstCut(pcm[start...], maxSeconds: maxSeconds, rate: rate) {
            pieces.append(Array(pcm[start..<cut]))
            start = cut
        }
        pieces.append(Array(pcm[start...]))
        return pieces
    }

    /// Where the first piece of `pcm` ends (an index into its base array), or
    /// nil while it still fits in one piece. Depends only on the first
    /// `maxSeconds`, so audio still arriving can be cut as it comes.
    static func firstCut(_ pcm: ArraySlice<Float>, maxSeconds: Double, rate: Int) -> Int? {
        let maxLen = Int(maxSeconds * Double(rate))
        guard maxSeconds > 0, pcm.count > maxLen else { return nil }
        let frame = max(1, Int(frameSeconds * Double(rate)))
        let minLen = Int(Double(maxLen) * earliestCut)
        return quietestPoint(pcm, from: pcm.startIndex + minLen, to: pcm.startIndex + maxLen, frame: frame)
    }

    /// Where to halve a piece the model could not decode: the quietest point in
    /// its middle third, so neither half is much shorter than the other.
    static func middleCut(_ pcm: [Float], rate: Int) -> Int {
        let frame = max(1, Int(frameSeconds * Double(rate)))
        return quietestPoint(pcm[...], from: pcm.count / 3, to: pcm.count * 2 / 3, frame: frame)
    }

    /// Index of the middle of the lowest-energy frame in `from..<to`. Ties go
    /// to the later frame so pieces stay as long as they can.
    private static func quietestPoint(_ pcm: ArraySlice<Float>, from: Int, to: Int, frame: Int) -> Int {
        var best = to
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = from
        while i + frame <= to {
            var e: Float = 0
            for v in pcm[i..<(i + frame)] { e += v * v }
            if e <= bestEnergy { bestEnergy = e; best = i + frame / 2 }
            i += frame
        }
        return best
    }
}
