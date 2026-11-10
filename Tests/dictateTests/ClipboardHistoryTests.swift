import Testing
@testable import dictate

/// The spoken "paste" command, from the shapes `say` + `dictate transcribe`
/// gave, through post-processing, then filled from a history.
struct PasteTests {
    @Test(arguments: [
        ("Speaking, speaking, new line, new line, paste, new line, new line, and here's another example new line, new line, paste.",
         "Speaking, speaking\n\n[paste]\n\nAnd here's another example\n\n[paste]"),
        ("Speaking, speaking. New line, new line. Paste. New line, new line. And here's another example. New line, new line. Paste.",
         "Speaking, speaking.\n\n[paste]\n\nAnd here's another example.\n\n[paste]"),
        ("Here is my code new line paste new line and the error new line paste.",
         "Here is my code\n[paste]\nAnd the error\n[paste]"),
        ("Here is the error. Paste. And that is what I see.", "Here is the error. [paste] And that is what I see."),
        ("Here is the error, paste, and that is what I see.", "Here is the error [paste] and that is what I see."),
        ("paste.", "[paste]"),
    ])
    func marks(_ said: String, _ typed: String) {
        #expect(Config().postProcess(said) == typed)
    }

    @Test(arguments: [
        "You can copy and paste it, paste the link below, I'll paste that in.",
        "Compare this paste with this paste.",
        "Here is the error paste and that is what I see.",
        "Add tomato paste.",
    ])
    func leavesProse(_ said: String) {
        #expect(Config().postProcess(said) == said)
    }

    @Test func untouchedByOtherRules() {
        var c = Config()
        c.casing = .lower
        c.dictionary = ["Pastebin"]
        c.replacements = [.init(from: "paste", to: "PASTE")]
        #expect(c.postProcess("Copy this, paste.") == "copy this [paste]")
    }

    @Test(arguments: [
        (ClipboardHistory.Order.recent, "a\n\nnewest\n\nb\n\nolder"),
        (ClipboardHistory.Order.oldest, "a\n\nolder\n\nb\n\nnewest"),
    ])
    func fills(_ order: ClipboardHistory.Order, _ typed: String) {
        let history = ["newest", "older", "oldest"]
        #expect(ClipboardHistory.fill("a\n\n[paste]\n\nb\n\n[paste]", history: history, order: order) == typed)
    }

    @Test func extraCommandsInsertNothing() {
        #expect(ClipboardHistory.fill("x [paste] y [paste] z", history: ["one"], order: .recent) == "x one y z")
        #expect(ClipboardHistory.fill("x [paste] y [paste] z", history: ["one"], order: .oldest) == "x one y z")
        #expect(ClipboardHistory.fill("[paste]", history: [], order: .recent) == "")
        #expect(ClipboardHistory.fill("x [paste]", history: [], order: .recent) == "x")
        #expect(ClipboardHistory.fill("no command", history: ["one"], order: .recent) == "no command")
    }

    @Test func insertsVerbatim() {
        #expect(ClipboardHistory.fill("see [paste] here", history: ["let x = 1;\n"], order: .recent) == "see let x = 1;\n here")
    }
}
