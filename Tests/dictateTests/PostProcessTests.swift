import Foundation
import Testing
@testable import dictate

struct PostProcessTests {
    /// The emoticon rules from the author's config, which the other rules
    /// must not disturb.
    static let emoticons: Config = {
        let url = Bundle.module.url(forResource: "emoticons", withExtension: "json")!
        return try! JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }()

    @Test(arguments: [
        ("angry winky face", ">;)"),
        ("smiley face", ":)"),
        ("winky face", ";)"),
        ("tongue face", ":P"),
        ("oh face", ":O"),
    ])
    func emoticons(_ said: String, _ typed: String) {
        #expect(Self.emoticons.postProcess(said) == typed)
    }

    @Test(arguments: [
        ("x squared plus 1", "x^2 + 1"),
        ("i mod n is the slot", "i % n is the slot"),
        ("n factorial grows fast", "n! grows fast"),
        ("the string s", "The string `s`"),
        ("a plus is fine", "A plus is fine"),
        ("so it works", "So it works"),
    ])
    func sentenceCasingSkipsLeadingCode(_ said: String, _ typed: String) {
        var c = Config()
        c.casing = .sentence
        #expect(c.postProcess(said) == typed)
    }

    @Test func endPeriod() {
        var c = Config()
        c.endPeriod = false
        #expect(c.postProcess("Done.") == "Done")
        #expect(c.postProcess("Well...") == "Well...")
    }
}
