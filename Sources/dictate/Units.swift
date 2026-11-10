import Foundation

/// Units a technical writer abbreviates, after a number: "5 megabytes" ->
/// "5 MB", "200 milliseconds" -> "200 ms", "100 megabits per second" ->
/// "100 Mbps", "3 gigahertz" -> "3 GHz". Seconds, minutes, hours, bytes and
/// bits stay words ("wait 5 minutes"), and so does a unit with no number
/// before it ("a few megabytes"). What the model abbreviates itself gets a
/// space: "4MB" -> "4 MB".
enum Units {
    /// Spoken prefix + unit, singular; "s" may follow.
    static let spoken: [(String, String)] = [
        ("kilobyte", "KB"), ("megabyte", "MB"), ("gigabyte", "GB"), ("terabyte", "TB"), ("petabyte", "PB"),
        ("kibibyte", "KiB"), ("mebibyte", "MiB"), ("gibibyte", "GiB"), ("tebibyte", "TiB"),
        ("millisecond", "ms"), ("microsecond", "µs"), ("nanosecond", "ns"),
        ("hertz", "Hz"), ("kilohertz", "kHz"), ("megahertz", "MHz"), ("gigahertz", "GHz"),
    ]
    /// Rates, which only abbreviate with "per second".
    static let rates: [(String, String)] = [
        ("kilobit", "kbps"), ("megabit", "Mbps"), ("gigabit", "Gbps"),
        ("kilobyte", "KB/s"), ("megabyte", "MB/s"), ("gigabyte", "GB/s"),
    ]

    private static let number = #"(\d+(?:[.,]\d+)*)"#

    static func apply(_ text: String) -> String {
        var out = text
        for (word, unit) in rates {
            out = out.replacingOccurrences(of: #"(?i)\b"# + number + #"[ -]"# + word + #"s? per second\b"#,
                                           with: "$1 " + unit, options: .regularExpression)
        }
        for (word, unit) in spoken {
            out = out.replacingOccurrences(of: #"(?i)\b"# + number + #"[ -]"# + word + #"s?\b"#,
                                           with: "$1 " + unit, options: .regularExpression)
        }
        let units = (spoken + rates).map(\.1).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return out.replacingOccurrences(of: #"\b"# + number + "(" + units + #")(?![\w/])"#,
                                        with: "$1 $2", options: .regularExpression)
    }
}
