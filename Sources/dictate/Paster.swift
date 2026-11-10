import AppKit
import Carbon.HIToolbox
import Foundation

/// Inserts text at the cursor by writing it to the pasteboard, sending Cmd-V,
/// then restoring whatever was on the pasteboard before.
enum Paster {
    /// Stamped on the keys we post (`eventSourceUserData`), so the hotkey tap
    /// can tell our Cmd-V from the user's keys.
    static let eventMarker: Int64 = 0x6469_6374  // "dict"

    /// The clipboard from before a paste, waiting to be put back. A second
    /// paste inside the wait keeps this one: snapshotting then would save the
    /// first transcript as "the user's clipboard" and lose theirs.
    private static var pendingRestore: (saved: Snapshot, work: DispatchWorkItem)?

    static func paste(_ text: String, restoreClipboard: Bool = true, restoreAfter: TimeInterval = 0.25, thenReturn: Bool = false) {
        let pb = NSPasteboard.general
        let earlier = takePendingRestore()
        let saved = restoreClipboard ? (earlier ?? snapshot(pb)) : []
        ClipboardHistory.clearForOwnWrite(pb)
        pb.setString(text, forType: .string)
        let ours = pb.changeCount

        sendKey(kVK_ANSI_V, flags: .maskCommand)
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

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
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
        guard !snap.isEmpty else { return }
        let items: [NSPasteboardItem] = snap.map { d in
            let item = NSPasteboardItem()
            for (type, data) in d { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}
