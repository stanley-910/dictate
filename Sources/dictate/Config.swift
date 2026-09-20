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
    /// Path to the GGUF. "~" is expanded.
    var model: String = "~/.local/share/dictate/models/cohere-transcribe-03-2026-Q8_0.gguf"
    /// BCP-47 language hint passed to the model; nil = auto.
    var language: String? = "en"
    /// Seconds of inactivity before the model is dropped from memory. 0 = never.
    var unloadAfterSeconds: Double = 300
    /// Input device UID or name. The menu bar pick overrides this; nil = system default.
    var microphone: String? = nil
    /// Play a sound on start/stop/cancel/arm.
    var sounds: Bool = true
    /// Sound names from /System/Library/Sounds (without extension) or file paths.
    var soundPack: SoundPack = SoundPack()
    /// Action per modifier held while the transcript is delivered:
    /// "paste", "copy" (clipboard only) or "send" (paste, then Return).
    var modifiers: [String: Delivery] = ["shift": .copy, "option": .send]
    /// Put the previous clipboard back after pasting.
    var restoreClipboard: Bool = true
    /// "model" keeps the model's casing, "lower" lowercases everything
    /// (dictionary terms keep theirs), "sentence" only uppercases the first letter.
    var casing: Casing = .model
    /// Mute the speakers while recording so playback stays out of the mic; restored afterwards.
    var muteSpeakersWhileRecording: Bool = false
    /// Show the floating waveform pill while recording.
    var indicator: Bool = true
    /// Add a trailing space after pasted text.
    var trailingSpace: Bool = false
    /// Cancel recordings shorter than this (seconds) instead of transcribing.
    var minimumSeconds: Double = 0.3
    /// Longest recording before auto-stop (seconds).
    var maximumSeconds: Double = 120
    /// Recordings at least this long need Escape twice to cancel. 0 = always once.
    var cancelConfirmAfterSeconds: Double = 10
    /// Correct spellings of names and jargon. Matched fuzzily against the
    /// transcript after recognition; "neo vim" -> "Neovim" needs no rule.
    var dictionary: [String] = []
    /// Minimum similarity (0...1) for a dictionary match. Lower = more aggressive.
    var dictionaryThreshold: Double = 0.8
    /// Ordered, case-insensitive whole-word replacements applied after the dictionary.
    var replacements: [Replacement] = []

    struct SoundPack: Codable {
        var start: String? = "Tink"
        var stop: String? = "Pop"
        var cancel: String? = "Bottle"
        var arm: String? = "Morse"
    }

    enum Delivery: String, Codable { case paste, copy, send }
    enum Casing: String, Codable { case model, lower, sentence }

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
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        language = c.contains(.language) ? try c.decode(String?.self, forKey: .language) : d.language
        unloadAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .unloadAfterSeconds) ?? d.unloadAfterSeconds
        microphone = try c.decodeIfPresent(String.self, forKey: .microphone)
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        soundPack = try c.decodeIfPresent(SoundPack.self, forKey: .soundPack) ?? d.soundPack
        modifiers = try c.decodeIfPresent([String: Delivery].self, forKey: .modifiers) ?? d.modifiers
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        casing = try c.decodeIfPresent(Casing.self, forKey: .casing) ?? d.casing
        muteSpeakersWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .muteSpeakersWhileRecording) ?? d.muteSpeakersWhileRecording
        indicator = try c.decodeIfPresent(Bool.self, forKey: .indicator) ?? d.indicator
        trailingSpace = try c.decodeIfPresent(Bool.self, forKey: .trailingSpace) ?? d.trailingSpace
        minimumSeconds = try c.decodeIfPresent(Double.self, forKey: .minimumSeconds) ?? d.minimumSeconds
        maximumSeconds = try c.decodeIfPresent(Double.self, forKey: .maximumSeconds) ?? d.maximumSeconds
        cancelConfirmAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .cancelConfirmAfterSeconds) ?? d.cancelConfirmAfterSeconds
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? d.dictionary
        dictionaryThreshold = try c.decodeIfPresent(Double.self, forKey: .dictionaryThreshold) ?? d.dictionaryThreshold
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? d.replacements
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

    /// Dictionary then replacements, in that order.
    func postProcess(_ raw: String) -> String {
        let text = casing == .lower ? raw.lowercased() : raw
        let fixed = Dictionary.apply(text, terms: Dictionary.terms(dictionary), threshold: dictionaryThreshold)
        var out = Replacements.apply(fixed, rules: replacements)
        if casing == .sentence, let first = out.first, first.isLowercase {
            out = first.uppercased() + out.dropFirst()
        }
        return out
    }

    /// Modification time of the resolved config file, for live reload.
    static var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    var modelURL: URL {
        URL(fileURLWithPath: (model as NSString).expandingTildeInPath)
    }
}

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(ts) \(message)\n".data(using: .utf8)!)
}
