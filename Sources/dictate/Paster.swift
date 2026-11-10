import AppKit
import Carbon.HIToolbox
import Foundation

/// Inserts text at the cursor by writing it to the pasteboard, sending Cmd-V,
/// then restoring whatever was on the pasteboard before.
/// Every item on a pasteboard, each as its types and their data.
typealias PasteSnapshot = [[NSPasteboard.PasteboardType: Data]]

enum Paster {
    /// Stamped on the keys we post (`eventSourceUserData`), so the hotkey tap
    /// can tell our Cmd-V from the user's keys.
    static let eventMarker: Int64 = 0x6469_6374  // "dict"

    /// The clipboard from before a paste, waiting to be put back. A second
    /// paste inside the wait keeps this one: snapshotting then would save the
    /// first transcript as "the user's clipboard" and lose theirs.
    private static var pendingRestore: (saved: Snapshot, work: DispatchWorkItem)?

    /// Wait after pasting text, or an image, before the next part goes on
    /// the pasteboard: the app reads it some time after the key.
    static let textStepSeconds = 0.3
    static let richStepSeconds = 0.6

    static func paste(_ text: String, restoreClipboard: Bool = true, restoreAfter: TimeInterval = 0.25, thenReturn: Bool = false) {
        paste([.text(text)], restoreClipboard: restoreClipboard, restoreAfter: restoreAfter, thenReturn: thenReturn)
    }

    /// Pastes each part in turn. `richKey` is the modifier for images and
    /// files: Control in a terminal, where Claude Code and the like read an
    /// image on Ctrl-V and Cmd-V pastes text only.
    static func paste(_ parts: [ClipboardHistory.Part], restoreClipboard: Bool = true, restoreAfter: TimeInterval = 0.25,
                      thenReturn: Bool = false, richKey: CGEventFlags = .maskCommand) {
        guard !parts.isEmpty else { return }
        waiting.append {
            let pb = NSPasteboard.general
            let earlier = takePendingRestore()
            let saved = restoreClipboard ? (earlier ?? snapshot(pb)) : []
            step(parts[...], pb: pb, richKey: richKey) {
                let ours = pb.changeCount
                if thenReturn {
                    // Let the paste land before submitting.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { sendKey(kVK_Return, flags: []) }
                }
                guard restoreClipboard else { return }
                // Give the target app (and any clipboard history manager) time to
                // read the pasteboard before restoring. Something copied meanwhile
                // (by the user, or `copy`) is left alone.
                let work = DispatchWorkItem {
                    pendingRestore = nil
                    if pb.changeCount == ours { restore(pb, saved) }
                }
                pendingRestore = (saved, work)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(restoreAfter, 0.1), execute: work)
            }
        }
        if !pasting { next() }
    }

    /// Pastes waiting their turn: one with an image in it takes a moment,
    /// and the next must not write the pasteboard under it. On main.
    private static var waiting: [() -> Void] = []
    private static var pasting = false

    private static func next() {
        pasting = !waiting.isEmpty
        if pasting { waiting.removeFirst()() }
    }

    /// Writes and pastes the first of `parts`, then the rest after a wait.
    private static func step(_ parts: ArraySlice<ClipboardHistory.Part>, pb: NSPasteboard, richKey: CGEventFlags,
                             then done: @escaping () -> Void) {
        guard let part = parts.first else { return }
        write(part, to: pb, richKey: richKey)
        let rest = parts.dropFirst()
        if rest.isEmpty {
            done()
            return next()
        }
        let wait: TimeInterval
        if case .rich = part { wait = richStepSeconds } else { wait = textStepSeconds }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { step(rest, pb: pb, richKey: richKey, then: done) }
    }

    /// Leave the text on the clipboard without pasting.
    static func copy(_ text: String) {
        _ = takePendingRestore()
        let pb = NSPasteboard.general
        ClipboardHistory.clearForOwnWrite(pb)
        pb.setString(text, forType: .string)
    }

    /// Cancels a restore still waiting and returns what it would have put back.
    private static func takePendingRestore() -> Snapshot? {
        guard let pending = pendingRestore else { return nil }
        pending.work.cancel()
        pendingRestore = nil
        return pending.saved
    }

    private static func write(_ part: ClipboardHistory.Part, to pb: NSPasteboard, richKey: CGEventFlags) {
        ClipboardHistory.clearForOwnWrite(pb)
        switch part {
        case .text(let text):
            pb.setString(text, forType: .string)
            sendKey(kVK_ANSI_V, flags: .maskCommand)
        case .rich(let snap):
            put(snap, on: pb)
            sendKey(kVK_ANSI_V, flags: richKey)
        }
    }

    private static func sendKey(_ code: Int, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(code)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        else { return }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    typealias Snapshot = PasteSnapshot

    static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { d[type] = data }
            }
            return d
        }
    }

    private static func restore(_ pb: NSPasteboard, _ snap: Snapshot) {
        ClipboardHistory.clearForOwnWrite(pb)
        put(snap, on: pb)
    }

    private static func put(_ snap: Snapshot, on pb: NSPasteboard) {
        guard !snap.isEmpty else { return }
        let items: [NSPasteboardItem] = snap.map { d in
            let item = NSPasteboardItem()
            for (type, data) in d { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}
