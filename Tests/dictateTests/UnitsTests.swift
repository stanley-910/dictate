import Testing
@testable import dictate

/// Each pair is (as the model writes it, as typed).
struct UnitsTests {
    @Test(arguments: [
        ("It uses 5 megabytes and takes 200 milliseconds.", "It uses 5 MB and takes 200 ms."),
        ("The file is 2 kilobytes and the link is 100 megabits per second.", "The file is 2 KB and the link is 100 Mbps."),
        ("Latency is 200 milliseconds and 50 microseconds and 10 nanoseconds.", "Latency is 200 ms and 50 µs and 10 ns."),
        ("It is 4MB or 4 megabytes and 512KB.", "It is 4 MB or 4 MB and 512 KB."),
        ("The CPU runs at 3 GHz and has 16 GB.", "The CPU runs at 3 GHz and has 16 GB."),
        ("at 2.4 gigahertz", "at 2.4 GHz"),
        ("1 megabyte per second", "1 MB/s"),
        ("a 5-megabyte file", "a 5 MB file"),
        ("1,500 milliseconds", "1,500 ms"),
        ("5KB/s", "5 KB/s"),
    ])
    func converts(_ said: String, _ typed: String) {
        #expect(Units.apply(said) == typed)
    }

    @Test(arguments: [
        "Wait 5 minutes then 30 seconds.",
        "I waited 3 hours and 10 seconds.",
        "a few megabytes of memory",
        "It is 8 bytes and 64 bits.",
        "A 10 gigabit network.",
        "That is 3x faster.",
        "the MBA program",
        "version 5GBX",
    ])
    func leavesProse(_ said: String) {
        #expect(Units.apply(said) == said)
    }
}
