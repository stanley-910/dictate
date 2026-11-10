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

struct LoneModifierTests {
    enum Step { case down, up, other }

    static func run(_ steps: [Step]) -> [LoneModifier.Event] {
        var m = LoneModifier()
        return steps.compactMap { step in
            switch step {
            case .down: m.modifier(isDown: true)
            case .up: m.modifier(isDown: false)
            case .other: m.otherInput()
            }
        }
    }

    @Test func aTapIsClean() {
        #expect(Self.run([.down, .up]) == [.pressed, .released(clean: true)])
    }

    @Test func rightCommandCIsAChord() {
        #expect(Self.run([.down, .other, .other, .up]) == [.pressed, .chorded, .released(clean: false)])
    }

    @Test func keysWhileUpDoNotCount() {
        #expect(Self.run([.other, .down, .up, .other, .down, .up]) == [.pressed, .released(clean: true), .pressed, .released(clean: true)])
    }

    @Test func repeatedFlagsAreOnePress() {
        #expect(Self.run([.down, .down, .up, .up]) == [.pressed, .released(clean: true)])
    }
}

struct TriggerTests {
    typealias T = Trigger
    static let toggle = T.Key(mode: .toggle)
    static let hold = T.Key(mode: .hold)
    static let loneToggle = T.Key(mode: .toggle, lone: true)
    static let loneHold = T.Key(mode: .hold, lone: true)
    static let idle = T.State()
    static func rec(owns: Bool = true, held: Double = 0) -> T.State {
        T.State(recording: true, ownsRecording: owns, heldSeconds: held)
    }
    static func up(held: Double) -> T.State { T.State(heldSeconds: held) }
    static let tapOrHold = T.Key(mode: .toggle, holdAfterSeconds: 0.4)
    static func pressed(held: Double, started: Bool = true) -> T.State {
        T.State(recording: true, ownsRecording: true, heldSeconds: held, pressStarted: started)
    }

    @Test(arguments: [
        // A key with a key code: press starts, the same key's next press stops.
        (T.Event.press, toggle, idle, T.Action.start),
        (.press, toggle, rec(), .stop),
        (.press, toggle, rec(owns: false), .none),
        (.release(clean: true), toggle, rec(), .none),
        (.press, hold, idle, .start),
        (.press, hold, rec(owns: false), .none),
        (.release(clean: true), hold, rec(), .stop),
        (.release(clean: true), hold, rec(owns: false), .none),
        // Lone toggle: acts on a clean, quick release only.
        (.press, loneToggle, idle, .none),
        (.release(clean: true), loneToggle, up(held: 0.1), .start),
        (.release(clean: false), loneToggle, up(held: 0.1), .none),
        (.release(clean: true), loneToggle, up(held: 0.8), .none),
        (.release(clean: true), loneToggle, rec(held: 0.1), .stop),
        (.release(clean: false), loneToggle, rec(held: 0.1), .none),
        (.chord, loneToggle, rec(held: 0.1), .none),
        // Lone hold: starts at once; a shortcut right after the press discards it.
        (.press, loneHold, idle, .start),
        (.chord, loneHold, rec(held: 0.2), .discard),
        (.chord, loneHold, rec(held: 3), .none),
        (.chord, loneHold, rec(owns: false, held: 0.2), .none),
        (.release(clean: false), loneHold, rec(held: 3), .stop),
        // Tap or hold on the toggle key: a tap leaves it recording, a hold
        // past the threshold stops on release.
        (.press, tapOrHold, idle, .start),
        (.release(clean: true), tapOrHold, pressed(held: 0.15), .none),
        (.release(clean: true), tapOrHold, pressed(held: 0.4), .stop),
        (.release(clean: true), tapOrHold, pressed(held: 5), .stop),
        // The release after a press that stopped (or a lone tap that started) is idle.
        (.release(clean: true), tapOrHold, pressed(held: 5, started: false), .none),
        (.release(clean: true), tapOrHold, up(held: 5), .none),
        (.press, tapOrHold, pressed(held: 0, started: true), .stop),
        // 0 turns it off.
        (.release(clean: true), toggle, pressed(held: 5), .none),
    ])
    func decides(_ event: T.Event, _ key: T.Key, _ state: T.State, _ expected: T.Action) {
        #expect(T.action(event, key: key, state: state) == expected)
    }
}
