import AppKit
import Carbon.HIToolbox
import Foundation

/// Inserts text at the cursor by writing it to the pasteboard, sending Cmd-V,
/// then restoring whatever was on the pasteboard before.
enum Paster {
    static func paste(_ text: String, restoreClipboard: Bool = true) {
        let pb = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(pb) : []
        pb.clearContents()
        pb.setString(text, forType: .string)

        sendCommandV()

        guard restoreClipboard else { return }
        // Give the target app time to read the pasteboard before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            restore(pb, saved)
        }
    }

    /// Leave the text on the clipboard without pasting.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
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
        pb.clearContents()
        guard !snap.isEmpty else { return }
        let items: [NSPasteboardItem] = snap.map { d in
            let item = NSPasteboardItem()
            for (type, data) in d { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}
