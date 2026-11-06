import Foundation
import Testing
@testable import dictate

/// Against a throwaway XDG_STATE_HOME. Serialized: the directory is process-wide.
@Suite(.serialized) struct RecoveryTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", home.path, 1)
    }

    static func take(_ n: Int) -> Recovery.Take {
        Recovery.Take(id: String(format: "2026-11-06T10-00-%02d.000", n))
    }

    @Test func savesAndLinksTheNewest() throws {
        let a = Self.take(1), b = Self.take(2)
        a.saveAudio([Float](repeating: 0.1, count: 16_000), done: true)
        a.saveText("first")
        b.saveAudio([Float](repeating: 0.1, count: 32_000), done: true)
        b.saveText("second")
        Recovery.flush()
        #expect(Recovery.recent().map(\.id) == [b.id, a.id])
        #expect(Recovery.lastText == "second")
        #expect(try Wav.readMono16k(Recovery.audioURL).count == 32_000)
        #expect(abs(b.seconds - 2) < 0.01)
        let mode = try FileManager.default.attributesOfItem(atPath: b.audioURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func prunesTheOldest() {
        for n in 1...4 { Self.take(n).saveAudio([0.1], done: true) }
        Recovery.flush()
        Recovery.prune(keep: 2)
        Recovery.flush()
        #expect(Recovery.recent().map(\.id) == [Self.take(4).id, Self.take(3).id])
    }

    @Test func aLatePartialSaveDoesNotReplaceTheFullOne() throws {
        let t = Self.take(5)
        t.saveAudio([Float](repeating: 0.1, count: 1000), done: true)
        t.saveAudio([Float](repeating: 0.1, count: 10))
        Recovery.flush()
        #expect(try Wav.readMono16k(t.audioURL).count == 1000)
    }

    @Test func findsAnInterruptedRecording() {
        let t = Self.take(6)
        t.begin()
        t.saveAudio([Float](repeating: 0.1, count: 100))
        Recovery.flush()
        #expect(Recovery.interrupted()?.id == t.id)
        #expect(Recovery.interrupted() == nil)
    }

    @Test func aStoppedRecordingIsNotInterrupted() {
        let t = Self.take(7)
        t.begin()
        t.saveAudio([Float](repeating: 0.1, count: 100), done: true)
        Recovery.flush()
        #expect(Recovery.interrupted() == nil)
    }

    @Test func movesAnOldLastRecordingIn() throws {
        try FileManager.default.createDirectory(at: Recovery.directory, withIntermediateDirectories: true)
        try Wav.write16k([Float](repeating: 0.1, count: 500), to: Recovery.audioURL)
        try "old".write(to: Recovery.textURL, atomically: true, encoding: .utf8)
        Recovery.migrate()
        let moved = try #require(Recovery.recent().first)
        #expect(moved.text == "old")
        #expect(try Wav.readMono16k(moved.audioURL).count == 500)
        Recovery.migrate()  // nothing left to move
        #expect(Recovery.recent().count == 1)
    }
}
