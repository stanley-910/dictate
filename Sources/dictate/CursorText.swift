import AppKit
import ApplicationServices

/// Fits a transcript to the text already before the cursor: a space when it
/// would otherwise run into the previous word, and a lowercase first word in
/// the middle of a sentence ("I want to" + "Check this" -> " check this").
enum CursorText {
    /// Closing marks that end a word: a space goes after them.
    private static let closers: Set<Character> = [")", "]", "}", "\u{201D}", "\u{2019}"]
    /// Marks a sentence can end with.
    private static let terminators: Set<Character> = [".", "?", "!", "\u{2026}"]
    /// Text starting with one of these attaches to what is before it.
    private static let attaching: Set<Character> = [".", ",", ";", ":", "?", "!", ")", "]", "}", "'", "\u{2019}", "\u{201D}", "\u{2026}"]

    /// `text` as it should be pasted after `before` (the text up to the
    /// cursor; "" at the start of a field). nil means the app did not say,
    /// and `text` is returned as it is. `terms` are dictionary spellings,
    /// whose casing is kept. `isWord` says whether the first word lowercased
    /// is still a word: "paris" is not, so "Paris" keeps its capital.
    static func fit(_ text: String, after before: String?, terms: [String] = [],
                    isWord: (String) -> Bool = { _ in true }) -> String {
        guard let before, let first = text.first else { return text }
        var out = text
        if midSentence(before), first.isUppercase, !keepsCase(text, terms: terms),
           isWord(String(text.prefix { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }).lowercased()) {
            out = first.lowercased() + out.dropFirst()
        }
        if needsSpace(before), !first.isWhitespace, !attaching.contains(first) {
            out = " " + out
        }
        return out
    }

    /// The character before the cursor ends a word or a sentence, with no
    /// space after it: "word", "2", "word,", "end.", "(aside)", "said \"so\"".
    static func needsSpace(_ before: String) -> Bool {
        guard let last = before.last else { return false }
        if last.isLetter || last.isNumber || closers.contains(last) || terminators.contains(last) { return true }
        if ",;:".contains(last) { return true }
        // A straight quote closes after a word ("so\"|") and opens after a
        // space ("said \"|").
        if last == "\"" || last == "'" {
            let prior = before.dropLast().last
            return prior.map { !$0.isWhitespace && $0 != "(" } ?? false
        }
        return false
    }

    /// The cursor is inside a sentence: the last mark before it, past spaces
    /// and closing quotes, is a word, a number, a comma or the like. Not a
    /// sentence end, a newline or the start, and not any other symbol: a
    /// shell or chat prompt ("$ ", "> ", "Subject: ") starts a sentence.
    static func midSentence(_ before: String) -> Bool {
        for c in before.reversed() {
            if c == " " || c == "\t" || c == "\u{00A0}" { continue }
            if c.isNewline { return false }
            if closers.contains(c) || c == "\"" || c == "'" { continue }
            return c.isLetter || c.isNumber || ",;(-\u{2013}\u{2014}".contains(c)
        }
        return false
    }

    /// The first word keeps its capital: "I" and its contractions, an
    /// acronym or mixed case ("API", "JavaScript"), a dictionary term, or code.
    private static func keepsCase(_ text: String, terms: [String]) -> Bool {
        let word = text.prefix { !$0.isWhitespace }
        let core = word.trimmingCharacters(in: .punctuationCharacters)
        if core == "I" || core.hasPrefix("I'") || core.hasPrefix("I\u{2019}") { return true }
        if core.dropFirst().contains(where: \.isUppercase) { return true }
        if terms.contains(where: { $0.split(separator: " ").first.map(String.init) == core }) { return true }
        return CodeNotation.startsWithCode(text)
    }

    /// Up to `limit` characters before the cursor in the focused text field,
    /// via Accessibility; "" at the start of the field. nil when the app does
    /// not expose it (many terminals and Electron apps), and for our own
    /// windows, whose Accessibility calls would wait on this same thread.
    /// Whether the spelling checker knows `word`, for `fit`'s `isWord`.
    static func isKnownWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    static func beforeCursor(limit: Int = 200) -> String? {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return nil }
        let system = AXUIElementCreateSystemWide()
        // A hung app must not hold up the paste.
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        var selection: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID(),
              AXValueGetValue(selection as! AXValue, .cfRange, &range), range.location >= 0
        else { return nil }
        if range.location == 0 { return "" }
        // Ranges count UTF-16 units.
        let start = max(0, range.location - limit)
        var wanted = CFRange(location: start, length: range.location - start)
        if let param = AXValueCreate(.cfRange, &wanted) {
            var string: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, param, &string) == .success,
               let s = string as? String {
                return s
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let full = value as? String
        else { return nil }
        let units = Array(full.utf16)
        guard range.location <= units.count else { return nil }
        return String(decoding: units[start..<range.location], as: UTF16.self)
    }
}
