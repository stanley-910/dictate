import Testing
@testable import dictate

struct SeamTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let left: String, right: String, probe: String
        let mended: (String, String)
        var testDescription: String { "\(left) | \(right)" }
    }

    static let cases: [Case] = [
        // The probe runs on with a comma: the stop becomes it.
        Case(left: "People do not look at the room size at all.", right: "So, my plan is to show it.",
             probe: "do not look at the room size at all, so my plan is to",
             mended: ("People do not look at the room size at all,", "so, my plan is to show it.")),
        // No punctuation in the probe: the stop just goes.
        Case(left: "and nobody notices until.", right: "Somebody shows up.",
             probe: "nobody notices until somebody shows up with",
             mended: ("and nobody notices until", "somebody shows up.")),
        // A word the pieces dropped at the cut comes back.
        Case(left: "Thirty minutes is too long for a quick check in.", right: "15 minutes would be enough.",
             probe: "too long for a quick check in, and 15 minutes would probably",
             mended: ("Thirty minutes is too long for a quick check in and", "15 minutes would be enough.")),
        // "I" keeps its capital.
        Case(left: "We could try that.", right: "I think it works.",
             probe: "we could try that, I think it works",
             mended: ("We could try that,", "I think it works.")),
        Case(left: "We could try that.", right: "I'm sure it works.",
             probe: "we could try that I'm sure it works",
             mended: ("We could try that", "I'm sure it works.")),
        // So does a name the probe capitalizes mid-sentence.
        Case(left: "The growth is strongest in.", right: "Germany and Japan.",
             probe: "the growth is strongest in Germany and Japan where",
             mended: ("The growth is strongest in", "Germany and Japan.")),
        // And an acronym.
        Case(left: "Then we call the.", right: "API twice.",
             probe: "then we call the api twice",
             mended: ("Then we call the", "API twice.")),
    ]

    /// The probe ends a sentence there, or cannot be lined up: left alone.
    static let kept: [(String, String, String)] = [
        ("I know this looks worse.", "However, the trend is up.", "I know this looks worse. However, the trend is up"),
        ("It has very little memory.", "The support team says", "very little memory? The support team says"),
        ("It has very little memory.", "The support team says", "something else entirely was heard here"),
        // Only the word at the cut matches, nothing next to it.
        ("It has very little memory.", "The support team says", "all of the memory the cat said"),
        // Two places fit equally well.
        ("Go.", "Go.", "go go go go"),
        // Not a full stop: a question stays a question.
        ("Is that right?", "So we go.", "is that right so we go"),
        ("And then he said...", "So we went.", "and then he said so we went"),
        // The cut word itself is not where the probe has it.
        ("It was good.", "Then we left.", "it was great then we left"),
    ]

    @Test(arguments: cases)
    func mends(_ c: Case) {
        let out = Seam.mend(c.left, c.right, probe: c.probe)
        #expect(out.0 == c.mended.0)
        #expect(out.1 == c.mended.1)
    }

    @Test(arguments: kept.indices)
    func keeps(_ i: Int) {
        let (left, right, probe) = Self.kept[i]
        let out = Seam.mend(left, right, probe: probe)
        #expect(out.0 == left)
        #expect(out.1 == right)
    }
}
