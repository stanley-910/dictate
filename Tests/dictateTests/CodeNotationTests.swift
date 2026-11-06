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

struct IndexingAndComparisonTests {
    @Test(arguments: [
        ("Take the string s. Move i forward until s of i equals s of j.",
         "Take the string `s`. Move i forward until `s[i] == s[j]`."),
        ("Take the string S move I forward until S of I equals S of J.",
         "Take the string `S` move I forward until `S[i] == S[J]`."),
        ("Take string s, then check if s at i + 1 is less than or equal to x.",
         "Take string `s`, then check if `s[i + 1] <= x`."),
        ("Read the array b of i plus one and the array c at k.", "Read the array `b[i + 1]` and the array `c[k]`."),
        ("pointers i and j. While i is less than j, move i.", "pointers `i` and `j`. While `i < j`, move `i`."),
        ("If i is not equal to j and n is greater than or equal to 2, return.", "If i != j and n >= 2, return."),
        ("x is less than 5 and y equals 2", "x < 5 and y == 2"),
        ("n is at least 2", "n >= 2"),
        ("x does not equal y", "x != y"),
        ("x is set to 4", "x = 4"),
        ("I is at most 3", "i <= 3"),
    ])
    func converts(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said) == typed)
    }

    @Test(arguments: [
        "The counter is at least 3 and at most 10.",
        "at least 3 people came",
        "it is 5 at least",
        "this is less than ideal",
        "one is equal to the other",
        "i - unlike him - we agree",
        "the length of s is 3",
        "swap s of i and s of j",  // s never declared
    ])
    func leavesProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }

    @Test(arguments: [
        ("4 minus 52", "`4 - 52`"),
        ("it is O of n log n time", "it is `O(n log n)` time"),
        ("the string s and s of i", "the string `s` and `s[i]`"),
        ("5 plus years", "5 plus years"),
    ])
    func codeSpans(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said, spans: true) == typed)
    }
}

struct IdentifierTests {
    @Test(arguments: [
        ("Set camel case max depth to 0, then call snake case get username.",
         "Set `maxDepth` to 0, then call `get_username`."),
        ("Call node.next and Pascal case tree node, then screaming snake case max size.",
         "Call node.next and `TreeNode`, then `MAX_SIZE`."),
        ("Use kebab case user profile in the URL.", "Use `user-profile` in the URL."),
        ("constant case retry limit is 3", "`RETRY_LIMIT` is 3"),
        ("camel case is valid.", "`isValid`."),
        ("Store camel case max depth. Later, max depth grows.", "Store `maxDepth`. Later, `maxDepth` grows."),
    ])
    func converts(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said) == typed)
    }

    @Test(arguments: [
        "I like the camel case style.",
        "Use camel case for names.",
        "We use snake, case by case.",
        "camel case",
        "write it in snake case",
    ])
    func leavesProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }

    @Test func toString() {
        #expect(CodeNotation.apply("call camel case to string on it") == "call `toString` on it")
    }
}
