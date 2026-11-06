import Testing
@testable import dictate

/// Cases checked by hand with `dictate fix` and `say` + `dictate transcribe`
/// while the rules were written; each pair is (as the model writes it, as typed).
struct CodeNotationTests {
    @Test(arguments: [
        ("O of n", "O(n)"),
        ("O of 1", "O(1)"),
        ("O of one time", "O(1) time"),
        ("it is O of one.", "it is O(1)."),
        ("O n log n", "O(n log n)"),
        ("O of n log n", "O(n log n)"),
        ("O log n", "O(log n)"),
        ("O 2n", "O(2n)"),
        ("O of n squared", "O(n^2)"),
        ("O of 2 to the n", "O(2^n)"),
        ("O of V plus E", "O(V + E)"),
        ("O of n times m", "O(n * m)"),
        ("O of n factorial", "O(n!)"),
        ("O of square root of n", "O(√n)"),
        ("O of n to the kth power", "O(n^k)"),
        ("big O of n", "O(n)"),
        ("oh of n", "O(n)"),
        ("O(n) lookups", "O(n) lookups"),
    ])
    func bigO(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said) == typed)
    }

    @Test(arguments: [
        "oh of one thing",
        "big O notation",
        "oh, of course",
        "Oh, so that is it.",
    ])
    func bigOLeavesProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }

    @Test(arguments: [
        ("4 minus 52", "4 - 52"),
        ("i mod n", "i % n"),
        ("I mod n", "i % n"),
        ("x plus y times 2", "x + y * 2"),
        ("negative 48", "-48"),
        ("x squared plus 1", "x^2 + 1"),
        ("n divided by 2", "n / 2"),
    ])
    func arithmetic(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said) == typed)
    }

    @Test(arguments: [
        "5 plus years",
        "C plus plus",
        "3 times a day",
        "write to the log 2 times",
    ])
    func arithmeticLeavesProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }

    @Test(arguments: [
        ("take this string s and reverse s", "take this string `s` and reverse `s`"),
        ("pointers i and j, then move i.", "pointers `i` and `j`, then move `i`."),
        ("the array a", "the array a"),
    ])
    func variables(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said) == typed)
    }

    @Test(arguments: [
        "plan B or plan C",
        "the x-axis, e.g. here",
        "string s's length",
    ])
    func variablesLeaveProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }
}
