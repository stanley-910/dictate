import AppKit
import Foundation

/// User configuration, read from ~/.config/dictate/config.json.
/// Every field has a default so an empty file is valid.
struct Config: Codable {
    enum Mode: String, Codable { case toggle, hold }

    /// "control+space", "option+space", "fn", "right_command", etc.
    var hotkey: String = "control+space"
    var mode: Mode = .toggle
    /// Optional second hotkey that always records while held (push-to-talk).
    var holdHotkey: String? = nil
    /// The toggle hotkey held at least this long (seconds) stops on release,
    /// push-to-talk; a shorter tap toggles. 0 = always toggle.
    var holdToTalkAfterSeconds: Double = 0.4
    /// Path to the GGUF. "~" is expanded.
    var model: String = "~/.local/share/dictate/models/cohere-transcribe-03-2026-Q8_0.gguf"
    /// BCP-47 language hint passed to the model; nil = auto.
    var language: String? = "en"
    /// Seconds of inactivity before the model is dropped from memory. 0 = never.
    var unloadAfterSeconds: Double = 300
    /// Input device UID or name. The menu bar pick overrides this; nil = system default.
    var microphone: String? = nil
    /// With no microphone picked, record from the built-in mic rather than a
    /// Bluetooth headset that is also playing the sound, so the headset's
    /// playback does not drop to call quality while recording.
    var preferBuiltInMic: Bool = false
    /// Play a sound on start/stop/cancel/arm.
    var sounds: Bool = true
    /// Sound names from /System/Library/Sounds (without extension) or file paths.
    var soundPack: SoundPack = SoundPack()
    /// Action per modifier held while the transcript is delivered:
    /// "paste", "copy" (clipboard only) or "send" (paste, then Return).
    var modifiers: [String: Delivery] = ["shift": .copy, "option": .send]
    /// Put the previous clipboard back after pasting.
    var restoreClipboard: Bool = true
    /// How long the transcript stays on the clipboard before the previous
    /// contents come back. Raise it so a clipboard history manager records it.
    var restoreClipboardAfterSeconds: Double = 0.25
    /// "model" keeps the model's casing, "lower" lowercases everything
    /// (dictionary terms keep theirs), "sentence" only uppercases the first letter.
    var casing: Casing = .model
    /// false drops the period that ends the transcript; periods inside it stay.
    var endPeriod: Bool = true
    /// Mute the speakers while recording so playback stays out of the mic; restored afterwards.
    var muteSpeakersWhileRecording: Bool = false
    /// Show the floating waveform pill while recording.
    var indicator: Bool = true
    /// Where the indicator sits: bottom, top, top-left, top-right, bottom-left,
    /// bottom-right. Dragging it overrides this until the value changes.
    var indicatorPosition: IndicatorPosition = .bottom
    /// Gap between the indicator and the screen edge, in points.
    var indicatorMargin: Double = 14
    /// Add a trailing space after pasted text.
    var trailingSpace: Bool = false
    /// Read the text before the cursor (Accessibility) to put a space before
    /// the transcript when it would run into a word, and lowercase its first
    /// word mid-sentence. Apps that do not expose it get the text unchanged.
    var cursorContext: Bool = true
    /// Cancel recordings shorter than this (seconds) instead of transcribing.
    var minimumSeconds: Double = 0.3
    /// Longest recording before it stops and transcribes on its own (seconds).
    /// A safety stop for a recording left running; pieces decode as they
    /// arrive, so length costs little.
    var maximumSeconds: Double = 600
    /// Seconds before `maximumSeconds` that a sound plays and the indicator
    /// turns purple, so the stop is not a surprise. 0 = no warning.
    var maximumWarnSeconds: Double = 30
    /// Recordings kept in ~/.local/state/dictate/recordings, with their text,
    /// to transcribe or copy again from the menu. 0 = keep none.
    var keepRecordings: Int = 5
    /// Recordings are transcribed in pieces no longer than this (seconds, after
    /// `maxPauseSeconds` shortens pauses), cut at the quietest moment in the
    /// last part of each piece. The model drifts and repeats itself on longer
    /// single passes. 0 = never split.
    var chunkSeconds: Double = 30
    /// Quiet stretches longer than this (seconds) are shortened to it before
    /// decoding; the model spends as long on silence as on speech. 0 = keep all.
    var maxPauseSeconds: Double = 0.6
    /// Recordings at least this long need Escape twice to cancel. 0 = always once.
    var cancelConfirmAfterSeconds: Double = 10
    /// Correct spellings of names and jargon. Matched fuzzily against the
    /// transcript after recognition; "neo vim" -> "Neovim" needs no rule.
    var dictionary: [String] = []
    /// Minimum similarity (0...1) for a dictionary match. Lower = more aggressive.
    var dictionaryThreshold: Double = 0.8
    /// Ordered, case-insensitive whole-word replacements applied after the dictionary.
    var replacements: [Replacement] = []
    /// Write spoken code talk as typed: "O of n log n" -> "O(n log n)", and a
    /// letter named after a type word ("the string s") in backticks.
    var codeNotation: Bool = true
    /// Put every expression `codeNotation` writes in backticks ("`4 - 52`",
    /// "`O(n)`"), not only those with a declared variable, for Markdown.
    var codeSpans: Bool = false
    /// Spoken layout: "bullet ... bullet ..." -> "- " items, "number 1 ...
    /// number 2 ..." -> "1. " items, "new line", "new paragraph".
    var layout: Bool = true
    /// "5 megabytes" -> "5 MB", "200 milliseconds" -> "200 ms", "3
    /// gigahertz" -> "3 GHz" after a number; minutes and seconds stay words.
    var units: Bool = true
    /// Which copy each spoken "paste" inserts: "recent" (the newest first,
    /// then the one before) or "oldest" (the oldest of the last N copies
    /// first, for N commands).
    var pasteOrder: ClipboardHistory.Order = .recent
    /// Spoken phrases listed in menu bar > Cheat Sheet with what the
    /// replacements turn them into, e.g. "wink smile face" -> ";)".
    var cheatSheet: [String] = []

    struct SoundPack: Codable {
        var start: String? = "Tink"
        var stop: String? = "Pop"
        var cancel: String? = "Bottle"
        var arm: String? = "Morse"
        /// `maximumWarnSeconds` before the safety stop.
        var warn: String? = "Funk"
        /// The transcript was copied, not pasted: another app is frontmost now.
        var copied: String? = "Glass"
        /// The recording held no speech, so nothing was pasted.
        var nothing: String? = "Submarine"

        init() {}

        /// Missing names keep their defaults; null silences one.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = SoundPack()
            func name(_ key: CodingKeys, _ fallback: String?) throws -> String? {
                c.contains(key) ? try c.decode(String?.self, forKey: key) : fallback
            }
            start = try name(.start, d.start)
            stop = try name(.stop, d.stop)
            cancel = try name(.cancel, d.cancel)
            arm = try name(.arm, d.arm)
            warn = try name(.warn, d.warn)
            copied = try name(.copied, d.copied)
            nothing = try name(.nothing, d.nothing)
        }
    }

    enum Delivery: String, Codable { case paste, copy, send }
    enum Casing: String, Codable { case model, lower, sentence }

    /// Menu presets over `casing` and `endPeriod`.
    enum Style: String, CaseIterable {
        case formal, casual
        case veryCasual = "very-casual"

        var title: String {
            switch self {
            case .formal: "Formal"
            case .casual: "Casual"
            case .veryCasual: "Very Casual"
            }
        }
        var casing: Casing { self == .veryCasual ? .lower : .model }
        var endPeriod: Bool { self == .formal }
    }

    /// The preset matching `casing` and `endPeriod`, if any.
    var style: Style? {
        Style.allCases.first { $0.casing == casing && $0.endPeriod == endPeriod }
    }
    enum IndicatorPosition: String, Codable {
        case bottom, top
        case topLeft = "top-left", topRight = "top-right"
        case bottomLeft = "bottom-left", bottomRight = "bottom-right"
    }

    /// Flags for every modifier named in `modifiers`.
    var deliveryModifierFlags: CGEventFlags {
        var f: CGEventFlags = []
        if modifiers["shift"] != nil { f.insert(.maskShift) }
        if modifiers["option"] != nil { f.insert(.maskAlternate) }
        if modifiers["command"] != nil { f.insert(.maskCommand) }
        return f
    }

    /// Delivery chosen by the modifiers currently held; `paste` when none match.
    func delivery(for flags: CGEventFlags) -> Delivery {
        let held: [(String, CGEventFlags)] = [("shift", .maskShift), ("option", .maskAlternate), ("command", .maskCommand)]
        for (name, flag) in held where flags.contains(flag) {
            if let d = modifiers[name] { return d }
        }
        return .paste
    }

    struct Replacement: Codable {
        var from: String
        var to: String
        /// When true, `from` is a regular expression.
        var regex: Bool? = nil
    }

    init() {}

    /// Missing keys fall back to defaults so old configs survive new fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        holdHotkey = try c.decodeIfPresent(String.self, forKey: .holdHotkey)
        holdToTalkAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .holdToTalkAfterSeconds) ?? d.holdToTalkAfterSeconds
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        language = c.contains(.language) ? try c.decode(String?.self, forKey: .language) : d.language
        unloadAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .unloadAfterSeconds) ?? d.unloadAfterSeconds
        microphone = try c.decodeIfPresent(String.self, forKey: .microphone)
        preferBuiltInMic = try c.decodeIfPresent(Bool.self, forKey: .preferBuiltInMic) ?? d.preferBuiltInMic
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        soundPack = try c.decodeIfPresent(SoundPack.self, forKey: .soundPack) ?? d.soundPack
        modifiers = try c.decodeIfPresent([String: Delivery].self, forKey: .modifiers) ?? d.modifiers
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        restoreClipboardAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .restoreClipboardAfterSeconds) ?? d.restoreClipboardAfterSeconds
        casing = try c.decodeIfPresent(Casing.self, forKey: .casing) ?? d.casing
        endPeriod = try c.decodeIfPresent(Bool.self, forKey: .endPeriod) ?? d.endPeriod
        muteSpeakersWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .muteSpeakersWhileRecording) ?? d.muteSpeakersWhileRecording
        indicator = try c.decodeIfPresent(Bool.self, forKey: .indicator) ?? d.indicator
        indicatorPosition = try c.decodeIfPresent(IndicatorPosition.self, forKey: .indicatorPosition) ?? d.indicatorPosition
        indicatorMargin = try c.decodeIfPresent(Double.self, forKey: .indicatorMargin) ?? d.indicatorMargin
        trailingSpace = try c.decodeIfPresent(Bool.self, forKey: .trailingSpace) ?? d.trailingSpace
        cursorContext = try c.decodeIfPresent(Bool.self, forKey: .cursorContext) ?? d.cursorContext
        minimumSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumSeconds) ?? d.minimumSeconds
        maximumSeconds = try c.decodeIfPresent(Double.self, forKey: .maximumSeconds) ?? d.maximumSeconds
        maximumWarnSeconds = try c.decodeIfPresent(Double.self, forKey: .maximumWarnSeconds) ?? d.maximumWarnSeconds
        keepRecordings = try c.decodeIfPresent(Int.self, forKey: .keepRecordings) ?? d.keepRecordings
        chunkSeconds = try c.decodeIfPresent(Double.self, forKey: .chunkSeconds) ?? d.chunkSeconds
        maxPauseSeconds = try c.decodeIfPresent(Double.self, forKey: .maxPauseSeconds) ?? d.maxPauseSeconds
        cancelConfirmAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .cancelConfirmAfterSeconds) ?? d.cancelConfirmAfterSeconds
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? d.dictionary
        dictionaryThreshold = try c.decodeIfPresent(Double.self, forKey: .dictionaryThreshold) ?? d.dictionaryThreshold
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? d.replacements
        cheatSheet = try c.decodeIfPresent([String].self, forKey: .cheatSheet) ?? d.cheatSheet
        codeNotation = try c.decodeIfPresent(Bool.self, forKey: .codeNotation) ?? d.codeNotation
        codeSpans = try c.decodeIfPresent(Bool.self, forKey: .codeSpans) ?? d.codeSpans
        layout = try c.decodeIfPresent(Bool.self, forKey: .layout) ?? d.layout
        units = try c.decodeIfPresent(Bool.self, forKey: .units) ?? d.units
        pasteOrder = try c.decodeIfPresent(ClipboardHistory.Order.self, forKey: .pasteOrder) ?? d.pasteOrder
    }

    static var path: URL {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = xdg.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("dictate/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path) else { return Config() }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Config.self, from: data)
        } catch {
            log("config: \(path.path) failed to parse: \(error); using defaults")
            return Config()
        }
    }

    /// Writes `dictionary` into the config file, leaving every other key's
    /// value as it is (keys come out sorted). Goes through the symlink, so a
    /// dotfiles link stays a link. Refuses a file that does not parse rather
    /// than overwrite it.
    static func saveDictionary(_ terms: [String]) throws {
        let url = path.resolvingSymlinksInPath()
        var object: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: url) {
            guard case .object(let parsed) = try JSONDecoder().decode(JSONValue.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            object = parsed
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        object["dictionary"] = .array(terms.map { .string($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(JSONValue.object(object)) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// Dictionary, replacements, code notation, units, then layout, in that order.
    /// A spoken "paste" comes out as `ClipboardHistory.placeholder`.
    func postProcess(_ raw: String) -> String {
        let text = ClipboardHistory.mark(casing == .lower ? raw.lowercased() : raw)
        let fixed = Dictionary.apply(text, terms: Dictionary.terms(dictionary), threshold: dictionaryThreshold)
        var out = Replacements.apply(fixed, rules: replacements)
        if codeNotation { out = CodeNotation.apply(out, spans: codeSpans) }
        if units { out = Units.apply(out) }
        if layout { out = Layout.apply(out, capitalize: casing != .lower) }
        if casing == .sentence, let first = out.first, first.isLowercase, !CodeNotation.startsWithCode(out) {
            out = first.uppercased() + out.dropFirst()
        }
        if !endPeriod {
            out = out.trimmingCharacters(in: .whitespaces)
            // A single period only; "..." is a deliberate trail-off.
            if out.hasSuffix("."), !out.hasSuffix("..") { out.removeLast() }
        }
        // The daemon fills these from the clipboard history after this.
        return out.replacingOccurrences(of: ClipboardHistory.marker, with: ClipboardHistory.placeholder)
    }

    /// The built-in spoken shorthands by group, for menu bar > Cheat Sheet.
    static let shorthands: [(String, [String])] = [
        ("Layout", ["bullet a, bullet b", "number 1 a, number 2 b", "a, new line, b", "a, new paragraph, b", "paste"]),
        ("Big-O", ["O of n log n", "theta of n squared", "omega of n"]),
        ("Arithmetic", ["x squared plus 1", "i mod n", "negative 48", "2 to the n", "n divided by 2"]),
        ("Comparisons", ["i is less than or equal to j", "x does not equal y", "n is at least 2",
                         "i is less than j and j is less than n", "x is approximately 3.14"]),
        ("Names", ["the string s, s of i", "camel case max depth", "snake case user id", "pascal case tree node",
                   "the function f, f of x and y"]),
        ("Code", ["x dot length", "count plus equals 1", "i plus plus", "x arrow y", "x fat arrow y",
                  "std double colon vector", "open paren a plus b close paren times c", "wait dot dot dot"]),
        ("Math", ["log base 2 of n", "n choose k", "x sub i", "sum from i equals 1 to n of x sub i",
                  "2.5 times 10 to the minus 3"]),
        ("Units", ["5 megabytes", "200 milliseconds", "100 megabits per second", "3 gigahertz"]),
    ]

    /// Each shorthand with what this config makes of it now; those a turned
    /// off flag leaves as spoken are left out.
    func shorthandRows() -> [(String, [(String, String)])] {
        Config.shorthands.map { group, phrases in
            (group, phrases.map { ($0, postProcess($0)) }.filter { $0.0 != $0.1 })
        }.filter { !$0.1.isEmpty }
    }

    private static let styleKey = "style"

    /// Menu pick stored in app defaults; nil = follow the config file.
    static var pickedStyle: Style? {
        get { UserDefaults.standard.string(forKey: styleKey).flatMap(Style.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: styleKey) }
    }

    private static let muteKey = "muteSounds"

    /// Menu > Mute Sounds, stored in app defaults; on silences every sound.
    static var soundsMuted: Bool {
        get { UserDefaults.standard.bool(forKey: muteKey) }
        set { UserDefaults.standard.set(newValue, forKey: muteKey) }
    }

    /// This config with the menu pick applied over it; the daemon only.
    var withMenuPicks: Config {
        var c = self
        if let style = Config.pickedStyle {
            c.casing = style.casing
            c.endPeriod = style.endPeriod
        }
        return c
    }

    /// Modification time of the resolved config file, for live reload.
    static var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    var modelURL: URL {
        URL(fileURLWithPath: (model as NSString).expandingTildeInPath)
    }
}

/// Any JSON, for rewriting one key of the config file without dropping keys
/// this version does not know. Unlike JSONSerialization, numbers come back
/// as written (0.8, not 0.80000000000000004).
enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Off for `dictate listen`, whose stderr carries only `ready` and one error line.
var logEnabled = true

func log(_ message: String) {
    guard logEnabled else { return }
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(ts) \(message)\n".data(using: .utf8)!)
}
