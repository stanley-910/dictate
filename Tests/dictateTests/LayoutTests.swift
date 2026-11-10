import Testing
@testable import dictate

/// Each pair is (as the model writes it, as typed); the inputs are what
/// `say` + `dictate transcribe` gave for the spoken commands.
struct LayoutTests {
    @Test(arguments: [
        ("Here are the steps bullet sort the array, bullet scan from the left, bullet return the count.",
         "Here are the steps:\n- Sort the array\n- Scan from the left\n- Return the count"),
        ("Here are the steps. Bullet sort the array. Bullet scan from the left. Bullet return the count.",
         "Here are the steps.\n- Sort the array\n- Scan from the left\n- Return the count"),
        ("Bullet first thing, next bullet second thing.", "- First thing\n- Second thing"),
        ("To do list. New bullet sort the array. New bullet scan from the left.",
         "To do list.\n- Sort the array\n- Scan from the left"),
        ("Steps: bullet point sort, next bullet point scan. New paragraph. That is all.",
         "Steps:\n- Sort\n- Scan\n\nThat is all."),
        ("Number 1 Sort the array Number 2 Scan it.", "1. Sort the array\n2. Scan it"),
        ("Number one, sort the array. Number two, scan it. Number three, return.",
         "1. Sort the array\n2. Scan it\n3. Return"),
        ("First line, new line, second line, new paragraph, third line.",
         "First line\nSecond line\n\nThird line."),
        ("First line. New line. Second line.", "First line.\nSecond line."),
        ("Dear Sam Newline Thanks for the notes Newline Stan.", "Dear Sam\nThanks for the notes\nStan."),
        ("Dear Sam Newline, thanks for the notes. Newline Stan.", "Dear Sam\nThanks for the notes.\nStan."),
        ("Steps, bullet sort the array, next bullet scan from the left, new paragraph, that is all.",
         "Steps:\n- Sort the array\n- Scan from the left\n\nThat is all."),
        ("bullet x < y, bullet done", "- x < y\n- Done"),
        // The shapes the model gives for "speaking, speaking, new line, new
        // line, paste, new line, new line, and here's another example ...".
        ("Speaking, speaking, new line, new line, paste, new line, new line, and here's another example new line, new line, paste.",
         "Speaking, speaking\n\nPaste\n\nAnd here's another example\n\nPaste."),
        ("Speaking, speaking. New line, new line. Paste. New line, new line. And here's another example. New line, new line. Paste.",
         "Speaking, speaking.\n\nPaste.\n\nAnd here's another example.\n\nPaste."),
        ("Here is my code new line paste new line and the error new line paste.",
         "Here is my code\nPaste\nAnd the error\nPaste."),
        ("Done. New line.", "Done.\n"),
        ("Done, new paragraph", "Done\n\n"),
    ])
    func converts(_ said: String, _ typed: String) {
        #expect(Layout.apply(said) == typed)
    }

    @Test func lowercase() {
        #expect(Layout.apply("bullet one, bullet two", capitalize: false) == "- one\n- two")
    }

    @Test(arguments: [
        "Bullet points are useful. A bullet hit the wall. The next bullet in the list is fine.",
        "Next bullet point is about cost.",
        "The bullet is fast, and bullet proof glass stops it.",
        "The number one reason is speed, number two is cost.",
        "Number 1 priority. Number 3 later.",
        "Use a new line for each item. Start a new paragraph here.",
        "The new line character ends it, print new line.",
        "Strip the trailing newline.",
        "Split on newline and strip newline characters, a newline is fine.",
        "It ends with new line",
        "Start a new line of work, add a new line to the file.",
        "We need a blank new line here.",
        "Add a new line.",
        "A new, line of code.",
    ])
    func leavesProse(_ said: String) {
        #expect(Layout.apply(said) == said)
    }
}
