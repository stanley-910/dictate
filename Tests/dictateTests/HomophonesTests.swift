import Foundation
import Testing
@testable import dictate

/// Each pair is (as the model writes it, as typed).
struct HomophonesTests {
    @Test(arguments: [
        ("So then, a race is a dual right problem?", "So then, a race is a dual write problem?"),
        ("It needs read and right access.", "It needs read and write access."),
        ("The reads and rights are batched.", "The reads and writes are batched."),
        ("A read-right lock.", "A read-write lock."),
        ("Then it rights to the log file.", "Then it writes to the log file."),
        ("We right to disk on every change.", "We write to disk on every change."),
        ("Let me right a test for that.", "Let me write a test for that."),
        ("Can you right the function first?", "Can you write the function first?"),
        ("I'll right it down.", "I'll write it down."),
        ("Don't right to the same file twice.", "Don't write to the same file twice."),
        ("Right a script that does it.", "Write a script that does it."),
        ("Done. Right me a summary.", "Done. Write me a summary."),
        ("The failed rights are retried.", "The failed writes are retried."),
        ("It holds the right lock too long.", "It holds the write lock too long."),
        ("Use a right ahead log.", "Use a write ahead log."),
        ("I am righting the tests now.", "I am writing the tests now."),
        ("Re-right the loop.", "Rewrite the loop."),
        ("Clear it and right a test.", "Clear it and write a test."),
        ("It keeps rerighting the file.", "It keeps rewriting the file."),
    ])
    func writes(_ said: String, _ typed: String) {
        #expect(Homophones.apply(said) == typed)
    }

    @Test(arguments: [
        "You're right, the test fails.",
        "That is the right file.",
        "Right, a test would help.",
        "Do it right now.",
        "Open the file right now.",
        "Go from left to right the whole way.",
        "Right the first time.",
        "They have the right to the file.",
        "Check the access rights to the database.",
        "We need to right a wrong.",
        "Turn right at the light.",
        "Double right click on it.",
        "Right that's what I meant.",
        "You were right to ask.",
        "Check left and right the whole way.",
        "It goes up and right to the end.",
    ])
    func leavesRight(_ said: String) {
        #expect(Homophones.apply(said) == said)
    }

    @Test(arguments: [
        ("Clear the cash and try again.", "Clear the cache and try again."),
        ("It is a cash miss.", "It is a cache miss."),
        ("The prompt cash is cold.", "The prompt cache is cold."),
        ("Cash the result.", "Cache the result."),
        ("The value is cashed in memory.", "The value is cached in memory."),
        ("Cashing helps here.", "Caching helps here."),
        ("It cashes every response.", "It caches every response."),
        ("Is it in cash already?", "Is it in cache already?"),
        ("We pay for cash misses.", "We pay for cache misses."),
    ])
    func caches(_ said: String, _ typed: String) {
        #expect(Homophones.apply(said) == typed)
    }

    @Test(arguments: [
        "I paid in cash.",
        "She wants to cash out.",
        "It costs 5 dollars in cash.",
        "The petty cash is gone.",
        "He cashed out early.",
        "They are cashing in.",
        "I cashed a check.",
        "A song by Johnny Cash.",
        "Cash flow is fine.",
        "We are out of cash.",
    ])
    func leavesCash(_ said: String) {
        #expect(Homophones.apply(said) == said)
    }

    static let pairs = [
        Config.HomophonePair(heard: "sink", meant: "sync", near: ["data", "calendar", "job"], unless: nil),
        Config.HomophonePair(heard: "cue", meant: "queue", near: nil, unless: ["actor", "stage"]),
        Config.HomophonePair(heard: "colonel", meant: "kernel", near: ["linux", "panic"], unless: ["army"]),
        Config.HomophonePair(heard: "bite code", meant: "bytecode", near: nil, unless: nil),
    ]

    @Test(arguments: [
        ("The job should sink the data.", "The job should sync the data."),
        ("Wash it in the sink.", "Wash it in the sink."),
        ("The sink is full. Run the job.", "The sink is full. Run the job."),
        ("Sink my calendar.", "Sync my calendar."),
        ("Put it on the cue.", "Put it on the queue."),
        ("The actor missed the cue.", "The actor missed the cue."),
        ("A Linux colonel panic.", "A Linux kernel panic."),
        ("The army colonel uses Linux.", "The army colonel uses Linux."),
        ("It emits bite code.", "It emits bytecode."),
        ("The data is in sync, not the sinkhole.", "The data is in sync, not the sinkhole."),
    ])
    func usesConfigPairs(_ said: String, _ typed: String) {
        #expect(Homophones.apply(said, pairs: Self.pairs) == typed)
    }

    @Test func configPairsDecode() throws {
        let json = #"{"homophonePairs":[{"heard":"sink","meant":"sync","near":["data"]}]}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.postProcess("Sink the data.") == "Sync the data.")
        #expect(c.postProcess("The kitchen sink.") == "The kitchen sink.")
    }

    @Test func flagTurnsItOff() {
        var c = Config()
        #expect(c.postProcess("Clear the cash.") == "Clear the cache.")
        c.homophones = false
        #expect(c.postProcess("Clear the cash.") == "Clear the cash.")
    }
}
