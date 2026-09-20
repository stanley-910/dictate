import AppKit
import Carbon.HIToolbox
import Foundation

/// A parsed hotkey: a set of modifiers plus either a key code or a lone modifier.
struct Hotkey {
    var modifiers: CGEventFlags = []
    var keyCode: CGKeyCode?
    /// Set when the hotkey is a single modifier key (e.g. "fn", "right_command").
    var loneModifierKeyCode: CGKeyCode?

    static func parse(_ spec: String) -> Hotkey? {
        var hk = Hotkey()
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            switch part {
            case "control", "ctrl": hk.modifiers.insert(.maskControl)
            case "option", "alt": hk.modifiers.insert(.maskAlternate)
            case "command", "cmd": hk.modifiers.insert(.maskCommand)
            case "shift": hk.modifiers.insert(.maskShift)
            default:
                if let code = Hotkey.keyCodes[part] {
                    hk.keyCode = code
                } else if let code = Hotkey.modifierKeyCodes[part] {
                    hk.loneModifierKeyCode = code
                } else {
                    return nil
                }
            }
        }
        if hk.keyCode == nil && hk.loneModifierKeyCode == nil { return nil }
        return hk
    }

    static let keyCodes: [String: CGKeyCode] = [
        "space": CGKeyCode(kVK_Space), "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "return": CGKeyCode(kVK_Return), "tab": CGKeyCode(kVK_Tab), "grave": CGKeyCode(kVK_ANSI_Grave),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3), "f4": CGKeyCode(kVK_F4),
        "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6), "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8),
        "f9": CGKeyCode(kVK_F9), "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
        "f13": CGKeyCode(kVK_F13), "f14": CGKeyCode(kVK_F14), "f15": CGKeyCode(kVK_F15), "f16": CGKeyCode(kVK_F16),
        "f17": CGKeyCode(kVK_F17), "f18": CGKeyCode(kVK_F18), "f19": CGKeyCode(kVK_F19),
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "slash": 44, "period": 47, "comma": 43, "semicolon": 41, "quote": 39,
    ]

    static let modifierKeyCodes: [String: CGKeyCode] = [
        "fn": CGKeyCode(kVK_Function),
        "right_command": CGKeyCode(kVK_RightCommand), "left_command": CGKeyCode(kVK_Command),
        "right_option": CGKeyCode(kVK_RightOption), "left_option": CGKeyCode(kVK_Option),
        "right_control": CGKeyCode(kVK_RightControl), "left_control": CGKeyCode(kVK_Control),
        "right_shift": CGKeyCode(kVK_RightShift), "left_shift": CGKeyCode(kVK_Shift),
    ]

    private static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    /// True when the event's modifier set equals ours (ignoring caps lock, fn, numpad bits).
    func modifiersMatch(_ flags: CGEventFlags) -> Bool {
        flags.intersection(Hotkey.relevant) == modifiers
    }
}

/// Installs a CGEventTap and reports hotkey presses and releases.
/// Requires Accessibility (an active tap can swallow the event so the
/// hotkey does not also reach the frontmost app).
final class HotkeyListener {
    enum Event { case pressed, released, escape }

    private let hotkey: Hotkey
    private let handler: (Event) -> Void
    /// Asked on every Escape press; when true the key is consumed and reported
    /// as `.escape` instead of reaching the frontmost app.
    var capturesEscape: () -> Bool = { false }
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var loneModifierDown = false
    private var keyDown = false

    init(hotkey: Hotkey, handler: @escaping (Event) -> Void) {
        self.hotkey = hotkey
        self.handler = handler
    }

    func start() throws {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<HotkeyListener>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon)
        else {
            throw DictateError.audio("could not create event tap; grant Accessibility to dictate")
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if code == CGKeyCode(kVK_Escape), type == .keyDown || type == .keyUp {
            guard capturesEscape() else { return Unmanaged.passUnretained(event) }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                handler(.escape)
            }
            return nil  // swallow both down and up so the app underneath never sees it
        }

        if let lone = hotkey.loneModifierKeyCode {
            guard type == .flagsChanged, code == lone else { return Unmanaged.passUnretained(event) }
            let down = isModifierDown(code: lone, flags: event.flags)
            if down != loneModifierDown {
                loneModifierDown = down
                handler(down ? .pressed : .released)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let key = hotkey.keyCode else { return Unmanaged.passUnretained(event) }
        guard code == key, hotkey.modifiersMatch(event.flags) || (type == .keyUp && keyDown) else {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            keyDown = true
            handler(.pressed)
            return nil
        case .keyUp:
            keyDown = false
            handler(.released)
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func isModifierDown(code: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch Int(code) {
        case kVK_Function: return flags.contains(.maskSecondaryFn)
        case kVK_Command, kVK_RightCommand: return flags.contains(.maskCommand)
        case kVK_Option, kVK_RightOption: return flags.contains(.maskAlternate)
        case kVK_Control, kVK_RightControl: return flags.contains(.maskControl)
        case kVK_Shift, kVK_RightShift: return flags.contains(.maskShift)
        default: return false
        }
    }
}
