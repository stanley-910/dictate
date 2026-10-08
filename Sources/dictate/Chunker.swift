import Foundation

/// Splits long audio into pieces the model can decode in one pass, cutting
/// where the signal is quietest so a word is not sliced in half.
enum Chunker {
    /// Frame length used to measure loudness (20 ms at 16 kHz).
    static let frameSeconds = 0.02
    /// Cuts land no earlier than this fraction of `maxSeconds` into a piece.
    static let earliestCut = 0.6

    static func split(_ pcm: [Float], maxSeconds: Double, rate: Int) -> [[Float]] {
        let maxLen = Int(maxSeconds * Double(rate))
        guard maxSeconds > 0, pcm.count > maxLen else { return [pcm] }
        let frame = max(1, Int(frameSeconds * Double(rate)))
        let minLen = Int(Double(maxLen) * earliestCut)
        var pieces: [[Float]] = []
        var start = 0
        while pcm.count - start > maxLen {
            let cut = quietestPoint(pcm, from: start + minLen, to: start + maxLen, frame: frame)
            pieces.append(Array(pcm[start..<cut]))
            start = cut
        }
        pieces.append(Array(pcm[start...]))
        return pieces
    }

    /// Index of the middle of the lowest-energy frame in `from..<to`. Ties go
    /// to the later frame so pieces stay as long as they can.
    private static func quietestPoint(_ pcm: [Float], from: Int, to: Int, frame: Int) -> Int {
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
