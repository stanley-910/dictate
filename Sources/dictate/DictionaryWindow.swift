import AppKit

/// Menu bar > Dictionary: the config's `dictionary`, one term per line.
/// Save writes the file; the daemon's watcher picks it up like any edit.
final class DictionaryWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?

    /// Reloads the terms from the file each time unless an edit is unsaved.
    func show() {
        if window == nil { build() }
        guard let window, let textView else { return }
        if !window.isDocumentEdited {
            textView.string = Config.load().dictionary.joined(separator: "\n")
            textView.undoManager?.removeAllActions()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Dictionary"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 260, height: 220)
        window.delegate = self

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: text, queue: .main
        ) { [weak window] _ in window?.isDocumentEdited = true }

        let hint = NSTextField(labelWithString: "One term per line")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let content = NSView()
        for v in [scroll, hint, save, cancel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            save.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            save.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            hint.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
        ])
        window.contentView = content
        window.center()
        self.window = window
        self.textView = text
    }

    /// Trimmed, blank lines dropped, first spelling of a duplicate kept.
    @objc private func save() {
        guard let window, let textView else { return }
        var seen = Set<String>()
        let terms = textView.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        do {
            try Config.saveDictionary(terms)
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
            return
        }
        log("dictionary saved: \(terms.count) terms")
        window.isDocumentEdited = false
        window.close()
    }

    @objc private func cancel() {
        window?.isDocumentEdited = false
        window?.close()
    }
}
