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
        ("If i is not equal to j and n is greater than or equal to 2, return.", "If i != j && n >= 2, return."),
        ("x is less than 5 and y equals 2", "x < 5 && y == 2"),
        ("n is at least 2", "n >= 2"),
        ("x does not equal y", "x != y"),
        ("x is set to 4", "x = 4"),
        ("I is at most 3", "i <= 3"),
        ("string s. s of i plus s of j", "string `s`. `s[i] + s[j]`"),
        ("variable x. x equals 1.5", "variable `x`. `x == 1.5`"),
        ("variable n. O of n plus 1", "variable `n`. O(n + 1)"),
        ("variable n. negative n plus 1", "variable `n`. `-n + 1`"),
        ("variable n. 2 to the n", "variable `n`. `2^n`"),
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
        "Plan B is at least 2 hours away.",
        "pi is 3.14",
        "say ``x equals 2`` here",
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
        ("Max depth matters. Set camel case max depth to 0.", "Max depth matters. Set `maxDepth` to 0."),
        ("Call (camel case max depth).", "Call (`maxDepth`)."),
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
        "I prefer snake case names.",
        "say `camel case max depth` is valid",
    ])
    func leavesProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }

    @Test func toString() {
        #expect(CodeNotation.apply("call camel case to string on it") == "call `toString` on it")
    }
}

struct SymbolTests {
    @Test(arguments: [
        ("The function takes x arrow y", "The function takes x -> y"),
        ("The lambda is x fat arrow x plus 1.", "The lambda is x => x + 1."),
        ("from A arrow B", "from A -> B"),
        ("Call std double colon vector.", "Call std::vector."),
        ("The type is A double colon B double colon C.", "The type is A::B::C."),
        ("Wait for it. . . . done.", "Wait for it... done."),
        ("Wait for it dot dot dot done", "Wait for it... done"),
        ("Open paren a plus b close paren times c.", "(a + b) * c."),
        ("Open parent a plus b close parent times c.", "(a + b) * c."),
        ("The cost open paren in dollars close paren is high.", "The cost (in dollars) is high."),
        ("the array b. b open bracket i plus 1 close bracket", "the array `b`. `b[i + 1]`"),
        ("Use open brace and close brace.", "Use open brace and close brace."),
        ("A map open brace key colon value close brace", "A map {key colon value}"),
    ])
    func converts(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said) == typed)
    }

    @Test(arguments: [
        "Follow the arrow to the exit. An arrow function is short.",
        "The type is int arrow int arrow bool.",
        "We map each key arrow value.",
        "Use a double colon to separate them.",
        "Write double colon syntax here.",
        "A missing open paren and a close paren.",
        "Open the paren file, then close it.",
        "The fat arrow is short.",
        "dot dot",
    ])
    func leavesProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }
}

struct CodeTalkTests {
    @Test(arguments: [
        ("Camel case max depth equals 2.", "`maxDepth == 2`."),
        ("Call camel case get max of x and y.", "Call `getMax(x, y)`."),
        ("The function f of x equals x squared plus 1.", "The function `f(x) == x^2 + 1`."),
        ("Define the function f then f of x plus 1 is 3.", "Define the function `f` then `f(x + 1)` is 3."),
        ("the function f and the array s. f of s at i", "the function `f` and the array `s`. `f(s[i])`"),
        ("i plus equals 2 and j minus equals 1", "i += 2 and j -= 1"),
        ("Set count plus equals 1.", "Set count += 1."),
        ("For i from 0 to n, i++.", "For i from 0 to n, i++."),
        ("I plus plus moves forward.", "i++ moves forward."),
        ("then count plus plus", "then count++"),
        ("If i is less than j and j is less than n then swap.", "If i < j && j < n then swap."),
        ("If i equals 0 or j equals n then stop.", "If i == 0 || j == n then stop."),
        ("the array v. Return not v of i and i is less than n.", "the array `v`. Return `!v[i] && i < n`."),
        ("x equals 1 and we stop", "x == 1 and we stop"),
        ("x dot length is the size", "x.length is the size"),
        ("X dot length minus 1", "X.length - 1"),
        ("x.length minus 1", "x.length - 1"),
        ("string s. s.length minus 1", "string `s`. `s.length - 1`"),
    ])
    func converts(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said) == typed)
    }

    @Test(arguments: [
        "C plus plus is fast.",
        "Call foo of x and y.",  // foo never declared or spoken as an identifier
        "swap f of x",  // f never declared a function
        "If not x and y then return.",  // "not" counts only beside a comparison
        "it is not x but y",
        "polka dot dress",
        "the x dot product",
        "e.g. plus 2",
        "Set camel case max depth to 0.".replacingOccurrences(of: "camel case max depth", with: "`maxDepth`"),
        "`maxDepth` of the tree",
        "A plus plus grade",
        "five plus plus",
    ])
    func leavesProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }

    @Test func spans() {
        #expect(CodeNotation.apply("Call node.next.", spans: true) == "Call `node.next`.")
    }
}

struct MathTests {
    @Test(arguments: [
        ("Theta of n log n and omega of n.", "Θ(n log n) and Ω(n)."),
        ("Big theta of n squared", "Θ(n^2)"),
        ("Log base 2 of n.", "log_2 n."),
        ("log base 2 of n plus 1", "log_2 n + 1"),
        ("O of log base 2 of n", "O(log_2 n)"),
        ("There are n choose 2 pairs.", "There are C(n, 2) pairs."),
        ("n choose k", "C(n, k)"),
        ("Sum from i equals 1 to n of i.", "Σ_{i=1}^n i."),
        ("The sum from i equals 1 to n of x sub i", "The Σ_{i=1}^n x_i"),
        ("product from k equals 0 to n minus 1 of k plus 1", "Π_{k=0}^{n - 1} k + 1"),
        ("x sub i plus x sub j", "x_i + x_j"),
        ("x sub I", "x_i"),
        ("x is approximately 3.14", "x ≈ 3.14"),
        ("n is approximately equal to 1000", "n ≈ 1000"),
        ("It is 2.5 times 10 to the minus 3.", "It is 2.5e-3."),
        ("It takes 1.6 times 10 to the minus 19", "It takes 1.6e-19"),
        ("3 times 10 to the 8", "3e8"),
        ("The answer is 10 to the 9 plus 7.", "The answer is 10^9 + 7."),
        ("x to the minus 1", "x^-1"),
        ("2n times 10 to the 3", "2n * 10^3"),  // not scientific: 2n is not a number
    ])
    func converts(_ said: String, _ typed: String) {
        #expect(CodeNotation.apply(said) == typed)
    }

    @Test(arguments: [
        "The omega of the system",
        "Theta is the angle.",
        "theta of one thing",
        "the log base is 2",
        "I choose 2 of them.",
        "You choose k.",
        "I sub in for him.",
        "the sub i ordered",
        "Plan B is approximately 2 hours.",
        "It is approximately 5 minutes.",
        "the sum from the first row",
        "sum from 1 to n",
    ])
    func leavesProse(_ said: String) {
        #expect(CodeNotation.apply(said) == said)
    }
}
