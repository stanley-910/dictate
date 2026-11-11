import Foundation

/// Words the model hears right but spells as the everyday word that sounds
/// the same: "a dual right problem" -> "a dual write problem", "clear the
/// cash" -> "clear the cache". "right" changes only where the words around
/// it say it is "write" ("read and right", "right to the file", "let me
/// right a test"), so "you're right" and "the right file" stay. "cash" is
/// the other way round: it becomes "cache" unless the words around it say
/// money ("pay in cash", "cash out", "petty cash").
enum Homophones {
    static func apply(_ text: String) -> String {
        cash(write(text))
    }

    private static let spelling = [
        "right": "write", "rights": "writes", "righting": "writing",
        "cash": "cache", "cashes": "caches", "cashed": "cached", "cashing": "caching",
    ]

    /// Respells capture group 1 of each match, keeping a leading capital.
    private static func respell(_ text: String, _ pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?i)" + pattern) else { return text }
        var out = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: out) else { continue }
            let word = String(out[range])
            guard var fixed = spelling[word.lowercased()] else { continue }
            if word.first?.isUppercase == true { fixed = fixed.prefix(1).uppercased() + fixed.dropFirst() }
            out.replaceSubrange(range, with: fixed)
        }
        return out
    }

    // MARK: right -> write

    private static let determiner = "(?:the|a|an|this|that|its|our|my|your|their|each|every|some|same)"
    /// Things written to.
    private static let sinks = "files?|disk|logs?|database|db|tables?|buffers?|stdout|stderr|standard out|standard error"
        + "|sockets?|pipes?|cache|memory|channels?|streams?|clipboard|pasteboard|config|store|storage|queues?"
        + "|console|output|terminal|buckets?|json|csv|replicas?|primary|index|ledger"
    /// Words that come before "write" the noun.
    private static let kinds = "dual|double|concurrent|atomic|batched|disk|file|db|database|cache|blind|dirty|lost"
        + "|partial|torn|buffered|sync|async|synchronous|random|sequential|failed|duplicate|idempotent"
        + "|conflicting|racing"
    /// Words that take a verb after them.
    private static let leads = "to|can|could|should|will|would|must|might|let['’]s|let me|let us|please|gonna|cannot"
        + "|(?:I|we|you|it|they|he|she)['’]ll|(?:do|did|does|ca|wo|would|could|should)n['’]t"
        + "|(?:can|could|should|will|would|did|do|does) (?:you|I|we|they|it|he|she)"
    /// What "to right" really rights.
    private static let righted = "(?! (?:(?:the|a|an|this|that|every|all) )?(?:wrongs?|ship|balance|injustice|itself|course)\\b)"

    private static let writes: [String] = [
        // "read and right", "reads/rights", "read-right".
        #"\b(?:read|reads|reading)(?:-|/|,? (?:and|or|slash) )(rights?|righting)\b"#,
        // "right to the file"; not "the right to the file", "access rights to the database".
        #"(?<!\b(?:the|a|no|any|all|your|my|their|our|his|her|have|has|access|admin|user) )\b(rights?|righting) (?:in|on)?to (?:"#
            + determiner + #" )?(?:\w+ )?(?:"# + sinks + #")\b"#,
        // "a dual right", "failed rights"; not "the file right now", "double right click".
        #"\b(?:"# + kinds + #")[ -](rights?)\b(?! (?:side|hand|click|now|away|arrow|here|there|after|before|next|above|below)\b)"#,
        // "right lock", "right skew", "right ahead log".
        #"\b(rights?)[ -](?=(?:locks?|skew|conflicts?|throughput|latency|heavy|amplification|quorum|barrier)\b"#
            + #"|ahead log|through cach|behind cach)"#,
        // "let me right a test", "to right it down"; not "left to right the", "to right a wrong".
        #"(?<!\bleft )\b(?:"# + leads + #") (right)\b"# + righted
            + #"(?= (?:a|an|the|some|me|us|it|this|that|these|those|up|down|out|another|new|my|your|our|its|code|tests?|to|into|more)\b(?!['’]))"#,
        // "fix it and right a test"; not "left and right the", "and right up to".
        #"(?<!\bleft )\b(?:and|then|also) (right)\b"# + righted
            + #"(?= (?:a|an|me|us|some|another|the(?! (?:first|second|way)\b))\b(?!['’]))"#,
        // "Right a test for it." as an instruction; "Right, a test" has its comma.
        #"(?:^|[.!?:]\s+|\n)(right)\b"# + righted + #"(?= (?:a|an|me|some|the(?! (?:first|second|way)\b))\b(?!['’]))"#,
        // "righting" is almost never meant.
        #"\b(righting)\b"# + righted,
    ]

    private static func write(_ text: String) -> String {
        var out = writes.reduce(text, respell)
        out = out.replacingOccurrences(of: #"(?i)\b(re)-?righting\b"#, with: "$1writing", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\b(re)-?right(s?)\b"#, with: "$1write$2", options: .regularExpression)
        return out
    }

    // MARK: cash -> cache

    /// After "cash", these make it the cache whatever else the sentence says.
    private static let cacheAfter = try! NSRegularExpression(pattern: "(?i)^[ -](?:hits?|miss|misses|keys?|lines?|entry"
        + "|entries|layer|size|invalidation|eviction|lookups?|directory|dir|folder|control|headers?|busting|buster|policy"
        + "|ttl|expiry|expiration|warming|warmup|poisoning|coherence|locality|backend|server|cluster|node|reads?"
        + "|writes?|breakpoints?|prefix|files?|is stale|was stale)\\b")
    /// After "cash", these make it money.
    private static let moneyAfter = try! NSRegularExpression(pattern: "(?i)^[ -](?:out|flow|back|only|app|register"
        + "|machine|payments?|prize|advance|deposit|cow|crop|grab|money|on hand|in hand|or card|or credit|reserves"
        + "|balance|position|is king|rich|poor|strapped)\\b")
    /// Before "cash", these make it money.
    private static let moneyBefore = try! NSRegularExpression(pattern: "(?i)\\b(?:hard|cold|petty|spare|raise|raised"
        + "|raising|carry|carrying|withdraw|withdrew|accept|accepts|strapped for|short on|out of|much|enough"
        + "|(?:pay|pays|paid|paying)(?: in| with)?) $")
    /// Anywhere in the sentence, these make a bare "cash" money.
    private static let moneyNear = try! NSRegularExpression(pattern: "(?i)\\$\\d|\\b(?:dollars?|bucks|money|bank|atm"
        + "|wallet|salary|venmo|refund|price|pay|pays|paid|paying|payment|buy|bought|sell|sold|rent|tip|coins?"
        + "|cheque|credit card|debit)\\b")
    private static let cashWord = try! NSRegularExpression(pattern: "(?i)\\bcash\\b")

    private static func has(_ regex: NSRegularExpression, _ text: Substring) -> Bool {
        let s = String(text)
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func cash(_ text: String) -> String {
        // "cashed out", "cashing a check" are money; "cached in memory" is not.
        var out = respell(text, #"\b(cashed|cashing|cashes)\b(?! (?:out|in on|in my|in your|in their|(?:it|them) in"#
            + #"|(?:a|the|my|your|that) (?:check|cheque)|checks|cheques)\b)(?! in\b(?! \w))"#)
        let ends: Set<Character> = [".", "!", "?", "\n"]
        let matches = cashWord.matches(in: out, range: NSRange(out.startIndex..., in: out))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let before = out[..<range.lowerBound], after = out[range.upperBound...]
            let start = before.lastIndex(where: ends.contains).map(out.index(after:)) ?? out.startIndex
            let end = after.firstIndex(where: ends.contains) ?? out.endIndex
            let word = out[range]
            let opens = out[start..<range.lowerBound].allSatisfy { $0.isWhitespace }
            // "Johnny Cash", "Cash App": a capital mid-sentence is a name.
            if word.first?.isUppercase == true, !opens { continue }
            if !has(cacheAfter, after) {
                if has(moneyAfter, after) || has(moneyBefore, before) || has(moneyNear, out[start..<end]) { continue }
            }
            out.replaceSubrange(range, with: word.first?.isUppercase == true ? "Cache" : "cache")
        }
        return out
    }
}
