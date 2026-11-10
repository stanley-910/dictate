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
    /// Each carries the index into the hotkeys array. `released` is clean
    /// when nothing else was pressed meanwhile (always, for a key with a key
    /// code); `chorded` is a lone modifier's first other key or click.
    enum Event: Equatable { case pressed(Int), released(Int, clean: Bool), chorded(Int), escape }

    private let hotkeys: [Hotkey]
    private let handler: (Event) -> Void
    /// Asked on every Escape press; when true the key is consumed and reported
    /// as `.escape` instead of reaching the frontmost app.
    var capturesEscape: () -> Bool = { false }
    /// Extra modifier flags to ignore when matching a hotkey, asked per event.
    /// Lets a delivery modifier be held while the stop key is pressed.
    var toleratedModifiers: () -> CGEventFlags = { [] }
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The tap's own thread, so keys pass through while main is busy (opening
    /// a Bluetooth mic can hold it for 150 ms).
    private var runLoop: CFRunLoop?
    /// Modifier flags on the last key event the tap saw, i.e. what apps see
    /// after Karabiner and friends have remapped.
    private(set) var lastFlags: CGEventFlags = []
    /// Goes up with every key or click of the user's that reaches an app, so
    /// a caller can tell whether anything was typed since it last looked.
    private(set) var inputCount = 0
    private var lone: [LoneModifier]
    private var keyDown: [Bool]

    init(hotkeys: [Hotkey], handler: @escaping (Event) -> Void) {
        self.hotkeys = hotkeys
        self.handler = handler
        lone = Array(repeating: LoneModifier(), count: hotkeys.count)
        keyDown = Array(repeating: false, count: hotkeys.count)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop {
            if let runLoopSource { CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        tap = nil
        runLoopSource = nil
        runLoop = nil
    }

    func start() throws {
        var mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        // Clicks end a lone modifier's tap (Command-click) and move the cursor.
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown] { mask |= 1 << type.rawValue }
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
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "dictate.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = loop
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Our own Cmd-V, pasting an earlier transcript while recording: not
        // the user's modifiers, not a key they pressed.
        if event.getIntegerValueField(.eventSourceUserData) == Paster.eventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            chord()
            inputCount += 1
            return Unmanaged.passUnretained(event)
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        lastFlags = event.flags
        if type == .keyDown { chord() }

        if code == CGKeyCode(kVK_Escape), type == .keyDown || type == .keyUp {
            guard capturesEscape() else {
                inputCount += 1
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                handler(.escape)
            }
            return nil  // swallow both down and up so the app underneath never sees it
        }

        for (i, hotkey) in hotkeys.enumerated() {
            if let lone = hotkey.loneModifierKeyCode {
                guard type == .flagsChanged, code == lone else { continue }
                switch self.lone[i].modifier(isDown: isModifierDown(code: lone, flags: event.flags)) {
                case .pressed: handler(.pressed(i))
                case .released(let clean): handler(.released(i, clean: clean))
                case .chorded, nil: break
                }
                return Unmanaged.passUnretained(event)
            }

            guard let key = hotkey.keyCode, code == key,
                  hotkey.modifiersMatch(event.flags.subtracting(toleratedModifiers())) || (type == .keyUp && keyDown[i])
            else { continue }
            switch type {
            case .keyDown:
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                keyDown[i] = true
                handler(.pressed(i))
                return nil
            case .keyUp:
                keyDown[i] = false
                handler(.released(i, clean: true))
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }
        if type == .keyDown { inputCount += 1 }
        return Unmanaged.passUnretained(event)
    }

    /// Another key or a click: a lone modifier held now is part of a shortcut.
    private func chord() {
        for i in lone.indices where lone[i].otherInput() != nil { handler(.chorded(i)) }
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
