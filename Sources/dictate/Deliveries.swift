import Foundation

/// Transcripts waiting to be delivered, handed out in the order their
/// recordings stopped. A new recording can start while earlier ones are still
/// decoding; each result is held until every earlier one has been delivered,
/// so text never lands out of order.
struct DeliveryQueue<Job, Output> {
    private var nextTicket = 0
    private var nextOut = 0
    private var jobs: [Int: Job] = [:]
    private var done: [Int: Output] = [:]

    /// Recordings stopped and not yet delivered.
    var pending: Int { nextTicket - nextOut }
    var isEmpty: Bool { pending == 0 }

    /// Queues `job`; pass the ticket back to `finish` with its result.
    mutating func add(_ job: Job) -> Int {
        jobs[nextTicket] = job
        nextTicket += 1
        return nextTicket - 1
    }

    /// Records `ticket`'s result; returns every job now ready, oldest first
    /// (none while an earlier one is still decoding).
    mutating func finish(_ ticket: Int, _ output: Output) -> [(Job, Output)] {
        guard ticket >= nextOut, ticket < nextTicket, done[ticket] == nil else { return [] }
        done[ticket] = output
        var ready: [(Job, Output)] = []
        while let output = done.removeValue(forKey: nextOut), let job = jobs.removeValue(forKey: nextOut) {
            ready.append((job, output))
            nextOut += 1
        }
        return ready
    }
}

/// Where a transcript goes when it is ready.
enum PasteTarget {
    /// Terminal apps, by bundle identifier.
    static let terminals: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
    ]

    /// `chosen` (from the modifiers held), unless the app that was frontmost
    /// when the recording stopped is no longer frontmost: then a paste (or a
    /// send) would land in the wrong app, so it is copied instead. The pill is
    /// a non-activating panel and never becomes frontmost. When either app is
    /// unknown it is delivered as chosen.
    static func delivery(_ chosen: Config.Delivery, stoppedIn: pid_t?, frontNow: pid_t?) -> Config.Delivery {
        guard chosen != .copy, let stoppedIn, let frontNow, stoppedIn != frontNow else { return chosen }
        return .copy
    }
}
