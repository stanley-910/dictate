import Foundation
import Testing
@testable import dictate

struct PostProcessTests {
    /// The emoticon rules from the author's config, which the other rules
    /// must not disturb.
    static func emoticonConfig() throws -> Config {
        let url = try #require(Bundle.module.url(forResource: "emoticons", withExtension: "json"))
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    @Test(arguments: [
        ("angry winky face", ">;)"),
        ("smiley face", ":)"),
        ("winky face", ";)"),
        ("tongue face", ":P"),
        ("oh face", ":O"),
    ])
    func emoticons(_ said: String, _ typed: String) throws {
        #expect(try Self.emoticonConfig().postProcess(said) == typed)
    }

    @Test(arguments: [
        ("x squared plus 1", "x^2 + 1"),
        ("i mod n is the slot", "i % n is the slot"),
        ("n factorial grows fast", "n! grows fast"),
        ("the string s", "The string `s`"),
        ("a plus is fine", "A plus is fine"),
        ("a + b is the sum", "a + b is the sum"),
        ("x+y here", "x+y here"),
        ("x == y holds", "x == y holds"),
        ("x-ray it", "X-ray it"),
        ("i - unlike him - agree", "I - unlike him - agree"),
        ("i - 1 is the last", "i - 1 is the last"),
        ("x is less than y squared", "x < y^2"),
        ("so it works", "So it works"),
    ])
    func sentenceCasingSkipsLeadingCode(_ said: String, _ typed: String) {
        var c = Config()
        c.casing = .sentence
        #expect(c.postProcess(said) == typed)
    }

    @Test func layoutAfterLowerCasing() {
        var c = Config()
        c.casing = .lower
        #expect(c.postProcess("Steps, bullet sort, bullet scan.") == "steps:\n- sort\n- scan")
        c.layout = false
        #expect(c.postProcess("Steps, bullet sort, bullet scan.") == "steps, bullet sort, bullet scan.")
    }

    @Test func endPeriod() {
        var c = Config()
        c.endPeriod = false
        #expect(c.postProcess("Done.") == "Done")
        #expect(c.postProcess("Well...") == "Well...")
    }
}

struct ConfigTests {
    @Test func soundPackKeepsDefaultsForMissingNames() throws {
        let json = #"{"soundPack": {"start": "Tink", "stop": null}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.soundPack.start == "Tink")
        #expect(c.soundPack.stop == nil)
        #expect(c.soundPack.warn == "Funk")
        #expect(c.maximumWarnSeconds == 30)
        #expect(c.keepRecordings == 5)
    }
}
