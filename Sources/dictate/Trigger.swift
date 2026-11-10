import Foundation

/// A lone-modifier hotkey ("fn", "right_command") seen through the event tap:
/// it counts as pressed alone only if no other key or click came while it was
/// down. Right-Command+C is a shortcut, not a hotkey press.
struct LoneModifier: Equatable {
    enum Event: Equatable { case pressed, released(clean: Bool), chorded }

    private(set) var down = false
    private var chorded = false

    /// The modifier's own flagsChanged.
    mutating func modifier(isDown: Bool) -> Event? {
        guard isDown != down else { return nil }
        down = isDown
        if isDown {
            chorded = false
            return .pressed
        }
        return .released(clean: !chorded)
    }

    /// Any other key down or mouse click; reported once per press.
    mutating func otherInput() -> Event? {
        guard down, !chorded else { return nil }
        chorded = true
        return .chorded
    }
}

/// What a hotkey press, release or chord does to the recording. Kept apart
/// from the app so the rules are table-tested.
enum Trigger {
    enum Event: Equatable { case press, release(clean: Bool), chord }
    enum Action: Equatable { case none, start, stop, discard }

    struct Key: Equatable {
        var mode: Config.Mode
        /// A single modifier key such as "fn" or "right_command".
        var lone = false
        /// A toggle key held at least this long before its release stops
        /// the recording its press started (push-to-talk); 0 = toggle only.
        var holdAfterSeconds: Double = 0
    }

    struct State: Equatable {
        var recording = false
        /// The recording in progress was started by this key.
        var ownsRecording = false
        /// Seconds since this key went down (for a release or a chord).
        var heldSeconds: Double = 0
        /// This key's latest press started the recording (not a release, and
        /// not an earlier press: the release after a stopping press is idle).
        var pressStarted = false
    }

    /// A lone-modifier toggle key acts on a release this soon after its
    /// press with nothing else pressed: a tap. Held longer and let go it was
    /// a shortcut abandoned, not a hotkey.
    static let tapSeconds = 0.5
    /// A hold key pressed with another key this soon after going down was a
    /// shortcut: the recording it started is discarded without a sound. Later
    /// the key is being held to talk and a stray key is ignored.
    static let chordSeconds = 1.0

    static func action(_ event: Event, key: Key, state s: State) -> Action {
        switch (event, key.mode) {
        case (.press, .toggle) where key.lone:
            // Wait for the release: only then is it known to be alone.
            return .none
        case (.press, _):
            if !s.recording { return .start }
            return key.mode == .toggle && s.ownsRecording ? .stop : .none
        case (.release(let clean), .toggle) where key.lone:
            guard clean, s.heldSeconds < tapSeconds else { return .none }
            if !s.recording { return .start }
            return s.ownsRecording ? .stop : .none
        case (.release, .toggle):
            // Tapped: recording goes on until the next press. Held: let go to stop.
            let held = key.holdAfterSeconds > 0 && s.heldSeconds >= key.holdAfterSeconds
            return held && s.recording && s.ownsRecording && s.pressStarted ? .stop : .none
        case (.release, .hold):
            return s.recording && s.ownsRecording ? .stop : .none
        case (.chord, .hold):
            return s.recording && s.ownsRecording && s.heldSeconds < chordSeconds ? .discard : .none
        case (.chord, .toggle):
            return .none
        }
    }
}
