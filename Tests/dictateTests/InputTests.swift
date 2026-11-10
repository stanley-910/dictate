import Foundation
import Testing
@testable import dictate

struct DeliveryQueueTests {
    /// Recordings named by letter, finishing in `order`; returns what was
    /// delivered after each finish.
    static func run(_ count: Int, finishing order: [Int]) -> [[String]] {
        var q = DeliveryQueue<String, String>()
        let names = (0..<count).map { String(UnicodeScalar(UInt8(97 + $0))) }
        let tickets = names.map { q.add($0) }
        return order.map { i in q.finish(tickets[i], names[i].uppercased()).map { $0.0 + $0.1 } }
    }

    @Test(arguments: [
        // In order: each goes out at once.
        (3, [0, 1, 2], [["aA"], ["bB"], ["cC"]]),
        // A later one done first waits for the earlier.
        (2, [1, 0], [[], ["aA", "bB"]]),
        (3, [2, 1, 0], [[], [], ["aA", "bB", "cC"]]),
        (3, [1, 0, 2], [[], ["aA", "bB"], ["cC"]]),
        // A duplicate finish is ignored.
        (2, [0, 0, 1], [["aA"], [], ["bB"]]),
    ])
    func deliversInStopOrder(_ count: Int, _ order: [Int], _ expected: [[String]]) {
        #expect(Self.run(count, finishing: order) == expected)
    }

    @Test func countsPending() {
        var q = DeliveryQueue<Int, Int>()
        #expect(q.isEmpty)
        let a = q.add(1), b = q.add(2)
        #expect(q.pending == 2)
        _ = q.finish(b, 0)
        #expect(q.pending == 2)
        _ = q.finish(a, 0)
        #expect(q.isEmpty)
        // Added after the queue drained: delivered on its own.
        let c = q.add(3)
        #expect(q.finish(c, 9).map(\.0) == [3])
    }
}
