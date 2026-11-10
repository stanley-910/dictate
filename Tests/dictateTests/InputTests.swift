import CoreAudio
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

struct PasteTargetTests {
    @Test(arguments: [
        (Config.Delivery.paste, Int32(10), Int32(10), Config.Delivery.paste),
        (.paste, 10, 11, .copy),
        (.send, 10, 11, .copy),
        (.send, 10, 10, .send),
        (.copy, 10, 11, .copy),
    ] as [(Config.Delivery, pid_t, pid_t, Config.Delivery)])
    func copiesWhenFocusMoved(_ chosen: Config.Delivery, _ stopped: pid_t, _ now: pid_t, _ expected: Config.Delivery) {
        #expect(PasteTarget.delivery(chosen, stoppedIn: stopped, frontNow: now) == expected)
    }

    @Test func unknownAppPastesAsBefore() {
        #expect(PasteTarget.delivery(.paste, stoppedIn: nil, frontNow: 3) == .paste)
        #expect(PasteTarget.delivery(.paste, stoppedIn: 3, frontNow: nil) == .paste)
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
    static func pressed(held: Double, started: Bool = true, speech: Bool = true) -> T.State {
        T.State(recording: true, ownsRecording: true, heldSeconds: held, pressStarted: started, heardSpeech: speech)
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
        // A slow press with nothing said is a tap, not push-to-talk; a long silent hold still stops.
        (.release(clean: true), tapOrHold, pressed(held: 0.8, speech: false), .none),
        (.release(clean: true), tapOrHold, pressed(held: 2.5, speech: false), .stop),
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

struct CursorTextTests {
    @Test(arguments: [
        // Nothing known: as transcribed.
        (nil, "Hello there.", "Hello there."),
        // Start of a field or a line: as transcribed.
        ("", "Hello there.", "Hello there."),
        ("Dear Sam,\n", "Thanks for this.", "Thanks for this."),
        // After a word: a space, and mid-sentence the first word lowercased.
        ("I want to", "Check this.", " check this."),
        ("I want to ", "Check this.", "check this."),
        ("It costs 5", "Dollars.", " dollars."),
        ("well,", "Maybe not.", " maybe not."),
        ("(an aside)", "Then more.", " then more."),
        ("he said \"so\"", "And left.", " and left."),
        // After a sentence: a space, casing kept.
        ("Done.", "Next one.", " Next one."),
        ("Really?  ", "Yes.", "Yes."),
        ("He said \"stop.\" ", "Then went.", "Then went."),
        // An opening quote or paren: no space.
        ("he said \"", "Hello.", "hello."),
        ("see (", "Below.", "below."),
        // Punctuation that attaches: no space.
        ("one", ", two", ", two"),
        ("end", ".", "."),
        // Words that keep their capital mid-sentence.
        ("so", "I think so.", " I think so."),
        ("so", "I'm in.", " I'm in."),
        ("call the", "API now.", " API now."),
        ("written in", "JavaScript.", " JavaScript."),
        ("open", "Neovim please.", " Neovim please."),
        ("so", "X == 5 holds.", " X == 5 holds."),
        ("and", "`s` is empty.", " `s` is empty."),
        // After a prompt or a label: a sentence starts, casing kept.
        ("~/src $ ", "Fix the bug.", "Fix the bug."),
        ("> ", "Fix the bug.", "Fix the bug."),
        ("\u{276F} ", "Fix the bug.", "Fix the bug."),
        ("Subject: ", "Fix the bug.", "Fix the bug."),
        // Already lowercase: only the space.
        ("and", "then this.", " then this."),
    ] as [(String?, String, String)])
    func fits(_ before: String?, _ text: String, _ expected: String) {
        #expect(CursorText.fit(text, after: before, terms: ["Neovim"]) == expected)
    }

    @Test func properNounsTheSpellingCheckerRejectsKeepTheirCapital() {
        let words: Set<String> = ["then", "check"]
        #expect(CursorText.fit("Paris was nice.", after: "we saw", isWord: words.contains) == " Paris was nice.")
        #expect(CursorText.fit("Then left.", after: "we saw it", isWord: words.contains) == " then left.")
    }
}

struct NoSpeechTests {
    @Test func levelsTellADeadInputFromQuietSpeech() {
        #expect(Dictation.levels([Float](repeating: 0, count: 16_000)).hasSuffix("100% dead"))
        let quiet = AudioTests.tone(1, amplitude: 0.01)
        #expect(Dictation.levels(quiet).hasSuffix("0% dead"))
        #expect(Dictation.levels([]) == "no audio")
    }

    @Test func soundsDefaultWhenTheConfigNamesOthers() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"soundPack": {"start": "Tink"}}"#.utf8))
        #expect(c.soundPack.nothing == "Submarine")
        #expect(c.soundPack.copied == "Glass")
    }
}

struct DeadInputTests {
    static let rate = 16_000.0
    /// Feeds `seconds` of 100 ms buffers at `rms`; returns how many read as dead.
    static func feed(_ w: inout DeadInput, _ seconds: Double, rms: Float) -> Int {
        (0..<Int(seconds * 10)).filter { _ in w.feed(rms: rms, frames: 1_600, rate: rate) }.count
    }

    @Test func zerosAfterSoundAreDeadAfterHalfASecond() {
        var w = DeadInput()
        #expect(Self.feed(&w, 2, rms: 0.01) == 0)
        #expect(Self.feed(&w, 0.4, rms: 0) == 0)
        #expect(Self.feed(&w, 0.1, rms: 0) == 1)
    }

    @Test func aQuietRoomIsNotDead() {
        var w = DeadInput()
        #expect(Self.feed(&w, 10, rms: 0.0005) == 0)
    }

    @Test func zerosFromTheStartWaitLongerThanAHeadsetSwitch() {
        var w = DeadInput()
        #expect(Self.feed(&w, 2, rms: 0) == 0)
        #expect(Self.feed(&w, 1, rms: 0) == 1)
        // Then counts afresh.
        #expect(Self.feed(&w, 2.9, rms: 0) == 0)
    }

    static let pods = AudioInputDevice(id: 1, uid: "pods", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
    static let mac = AudioInputDevice(id: 2, uid: "mac", name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
    static let usb = AudioInputDevice(id: 3, uid: "usb", name: "USB mic", transport: kAudioDeviceTransportTypeUSB)

    @Test(arguments: [
        // Still there: reopen it three times first.
        (true, 0, ["pods"], pods, mac, DeadInput.Next.same),
        (true, 2, ["pods"], pods, mac, .same),
        // Then the system default, then the built-in mic.
        (true, 3, ["usb"], pods, mac, .switchTo(pods)),
        (true, 3, ["usb", "pods"], pods, mac, .switchTo(mac)),
        (true, 3, ["pods"], pods, mac, .switchTo(mac)),
        // Gone: no point reopening it.
        (false, 0, ["usb"], mac, mac, .switchTo(mac)),
        // Nothing left that has not failed.
        (true, 3, ["mac"], mac, mac, .giveUp),
        (true, 3, ["pods", "mac"], pods, mac, .giveUp),
        (false, 0, ["pods"], pods, nil, .giveUp),
    ] as [(Bool, Int, [String], AudioInputDevice?, AudioInputDevice?, DeadInput.Next)])
    func fallsBack(_ present: Bool, _ reopens: Int, _ tried: [String], _ systemDefault: AudioInputDevice?,
                   _ builtIn: AudioInputDevice?, _ expected: DeadInput.Next) {
        #expect(DeadInput.next(present: present, reopens: reopens, tried: Set(tried),
                               systemDefault: systemDefault, builtIn: builtIn) == expected)
    }
}

struct MicChoiceTests {
    static let podsIn = AudioInputDevice(id: 7, uid: "AA-BB:input", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
    static let podsOut = AudioInputDevice(id: 8, uid: "AA-BB:output", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
    static let podsBoth = AudioInputDevice(id: 7, uid: "AA-BB", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
    static let otherPods = AudioInputDevice(id: 9, uid: "CC-DD:output", name: "Beats", transport: kAudioDeviceTransportTypeBluetooth)
    static let mac = DeadInputTests.mac
    static let speakers = AudioInputDevice(id: 3, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
    static let devices = [podsIn, mac]

    @Test(arguments: [
        // Off: the default input, as before.
        (nil, podsIn, podsOut, false, podsIn),
        // On, nothing picked, headset both ways: the built-in mic.
        (nil, podsIn, podsOut, true, mac),
        (nil, podsBoth, podsBoth, true, mac),
        // Output elsewhere, or a different headset: leave the input alone.
        (nil, podsIn, speakers, true, podsIn),
        (nil, podsIn, otherPods, true, podsIn),
        // An explicit pick wins, by UID or name.
        ("AA-BB:input", podsIn, podsOut, true, podsIn),
        ("AirPods", podsIn, podsOut, true, podsIn),
        // A pick no longer connected: as if nothing was picked.
        ("gone", podsIn, podsOut, true, mac),
    ] as [(String?, AudioInputDevice, AudioInputDevice, Bool, AudioInputDevice)])
    func chooses(_ picked: String?, _ input: AudioInputDevice, _ output: AudioInputDevice, _ prefer: Bool, _ expected: AudioInputDevice) {
        #expect(AudioDevices.choose(picked: picked, devices: Self.devices + [Self.podsBoth], defaultInput: input,
                                    output: output, preferBuiltIn: prefer) == expected)
    }

    @Test func noBuiltInMicKeepsTheHeadset() {
        #expect(AudioDevices.choose(picked: nil, devices: [Self.podsIn], defaultInput: Self.podsIn,
                                    output: Self.podsOut, preferBuiltIn: true) == Self.podsIn)
    }
}

struct SecureInputTests {
    @Test func namesTheHolder() {
        #expect(DictateApp.secureInputHolder(["kCGSSessionSecureInputPID": NSNumber(value: 412)]) == 412)
        #expect(DictateApp.secureInputHolder(["kCGSSessionOnConsoleKey": true]) == nil)
    }
}
