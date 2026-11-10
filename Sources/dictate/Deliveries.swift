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
