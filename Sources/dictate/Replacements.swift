import Foundation

/// Applies the config replacement table. Plain entries match whole words,
/// case-insensitively, and preserve the replacement's casing as written.
enum Replacements {
    static func apply(_ text: String, rules: [Config.Replacement]) -> String {
        var out = text
        for rule in rules {
            let pattern = rule.regex == true
                ? rule.from
                : "\\b" + NSRegularExpression.escapedPattern(for: rule.from) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                log("replacements: bad pattern \(rule.from)")
                continue
            }
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(
                in: out, options: [], range: range,
                withTemplate: rule.regex == true ? rule.to : NSRegularExpression.escapedTemplate(for: rule.to))
        }
        return out
    }
}
