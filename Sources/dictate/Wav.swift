import AVFoundation
import Foundation

enum Wav {
    /// Reads any audio file AVFoundation understands and returns mono float32 at 16 kHz.
    static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: file.processingFormat, to: outFormat)
        else { throw DictateError.audio("unsupported format \(file.processingFormat)") }

        let inCapacity = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCapacity)
        else { throw DictateError.audio("alloc") }
        try file.read(into: inBuf)

        let ratio = 16_000 / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)
        else { throw DictateError.audio("alloc") }

        var fed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { throw error }
        guard let ch = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}

extension Wav {
    /// Writes mono float32 at 16 kHz as 16-bit PCM WAV, half the size of float.
    static func write16k(_ pcm: [Float], to url: URL) throws {
        let rate = UInt32(Recorder.targetRate)
        let dataBytes = UInt32(pcm.count * 2)
        var d = Data(capacity: 44 + Int(dataBytes))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        let samples = pcm.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)).littleEndian }
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url, options: .atomic)
    }
}
