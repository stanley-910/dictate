import AppKit
import Foundation

/// The daemon: hotkey -> record -> transcribe -> paste, with a menu bar dot.
final class DictateApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording, transcribing }

    private var config: Config
    private let dictation: Dictation
    private let indicator = Indicator()
    private var listener: HotkeyListener?
    private var statusItem: NSStatusItem?
    private let micMenu = NSMenu(title: "Microphone")
    private let styleMenu = NSMenu(title: "Style")
    private var state: State = .idle
    private var maxTimer: Timer?
    private var reloadTimer: Timer?
    private var configModified: Date?
    /// Index of the hotkey that started the current recording.
    private var activeHotkey = 0
    /// Modifiers held when the recording was stopped.
    private var stopFlags: CGEventFlags = []
    private var pressedAt: Date?

    init(config: Config) {
        self.config = config
        self.dictation = Dictation(config: config.withMenuPicks)
        super.init()
        if config.indicator {
            dictation.recorder.onLevel = { [indicator] level, _ in indicator.push(level: level) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestPermissions()
        startListening()
        configModified = Config.modified
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reloadIfChanged()
        }
    }

    /// Hotkeys from config; index 0 follows `mode`, index 1 is always hold.
    private func parsedHotkeys() -> [Hotkey]? {
        guard let main = Hotkey.parse(config.hotkey) else {
            log("bad hotkey: \(config.hotkey)")
            return nil
        }
        var keys = [main]
        if let spec = config.holdHotkey {
            if let hold = Hotkey.parse(spec) { keys.append(hold) } else { log("bad holdHotkey: \(spec)") }
        }
        return keys
    }

    /// Re-reads the config when the file changes. Hotkeys rebind; everything
    /// else is read at the next use. A recording in progress is left alone.
    private func reloadIfChanged() {
        let now = Config.modified
        guard now != configModified, state == .idle else { return }
        configModified = now
        let old = config
        config = Config.load()
        dictation.config = config.withMenuPicks
        dictation.recorder.onLevel = config.indicator ? { [indicator] level, _ in indicator.push(level: level) } : nil
        if config.hotkey != old.hotkey || config.holdHotkey != old.holdHotkey || config.mode != old.mode {
            listener?.stop()
            listener = nil
            startListening()
        } else {
            log("config reloaded")
        }
    }

    /// Installs the event tap, retrying until Accessibility is granted so the
    /// first-run flow is: launch, approve the prompt, start dictating.
    private func startListening() {
        guard let hotkeys = parsedHotkeys() else { return }
        let l = HotkeyListener(hotkeys: hotkeys) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        l.capturesEscape = { [weak self] in
            // Read on the tap's thread; `state` is only written on main, and a
            // stale read here costs at most one Escape passing through.
            self?.state == .recording
        }
        l.toleratedModifiers = { [weak self] in
            guard let self, self.state == .recording else { return [] }
            return self.config.deliveryModifierFlags
        }
        do {
            try l.start()
        } catch {
            if !warnedAboutAccessibility {
                log("waiting for Accessibility: System Settings > Privacy & Security > Accessibility > Dictate")
                warnedAboutAccessibility = true
            }
            setIcon("○", color: .tertiaryLabelColor)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.listener == nil else { return }
                self.startListening()
            }
            return
        }
        listener = l
        setIcon("○")
        let hold = config.holdHotkey.map { ", hold \($0)" } ?? ""
        log("ready: \(config.hotkey) (\(config.mode.rawValue))\(hold), model \(config.modelURL.lastPathComponent)")
    }
    private var warnedAboutAccessibility = false

    func applicationWillTerminate(_ notification: Notification) {
        dictation.shutdown()
    }

    // MARK: hotkey state machine

    private func handle(_ event: HotkeyListener.Event) {
        switch event {
        case .escape:
            if state == .recording { escapePressed() }
        case .pressed(let i):
            let mode: Config.Mode = i == 0 ? config.mode : .hold
            switch (mode, state) {
            case (.toggle, .idle), (.hold, .idle):
                pressedAt = Date()
                activeHotkey = i
                startRecording()
            case (.toggle, .recording) where activeHotkey == i:
                stopAndTranscribe()
            default:
                break
            }
        case .released(let i):
            let mode: Config.Mode = i == 0 ? config.mode : .hold
            if mode == .hold, state == .recording, activeHotkey == i { stopAndTranscribe() }
        }
    }

    private func startRecording() {
        do {
            try dictation.start()
        } catch {
            log("\(error)")
            beep()
            return
        }
        state = .recording
        setIcon("●", color: .systemRed)
        if config.indicator {
            indicator.position = config.indicatorPosition
            indicator.margin = config.indicatorMargin
            indicator.show(.recording)
        }
        if config.sounds { Sounds.play(config.soundPack.start) }
        dictation.muteSpeakersIfConfigured()
        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: config.maximumSeconds, repeats: false) { [weak self] _ in
            self?.stopAndTranscribe()
        }
    }

    /// Short recordings cancel on one Escape; long ones arm on the first press
    /// and cancel on a second within `confirmWindow`.
    private var cancelArmed = false
    private var cancelArmTimer: Timer?
    private let confirmWindow: TimeInterval = 2

    private func escapePressed() {
        let needsConfirm = config.cancelConfirmAfterSeconds > 0
            && dictation.recorder.duration >= config.cancelConfirmAfterSeconds
        if !needsConfirm || cancelArmed {
            cancel()
            return
        }
        cancelArmed = true
        setIcon("●", color: .systemYellow)
        indicator.mode = .armed
        if config.sounds { Sounds.play(config.soundPack.arm) }
        cancelArmTimer?.invalidate()
        cancelArmTimer = Timer.scheduledTimer(withTimeInterval: confirmWindow, repeats: false) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            self.cancelArmed = false
            self.setIcon("●", color: .systemRed)
            self.indicator.mode = .recording
        }
    }

    private func disarmCancel() {
        cancelArmed = false
        cancelArmTimer?.invalidate()
    }

    private func cancel() {
        disarmCancel()
        maxTimer?.invalidate()
        _ = dictation.stop()
        state = .idle
        setIcon("○")
        indicator.hide()
        if config.sounds { Sounds.play(config.soundPack.cancel) }
        log("cancelled")
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        disarmCancel()
        maxTimer?.invalidate()
        let (pcm, seconds) = dictation.stop()
        stopFlags = listener?.lastFlags ?? []
        if dictation.isTooShort(seconds) {
            state = .idle
            setIcon("○")
            indicator.hide()
            return
        }
        state = .transcribing
        setIcon("◐", color: .systemOrange)
        indicator.mode = .transcribing
        if config.sounds { Sounds.play(config.soundPack.stop) }
        dictation.text(from: pcm) { [weak self] result in
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        state = .idle
        setIcon("○")
        indicator.hide()
        switch result {
        case .success(var text):
            if text.isEmpty { return }
            if config.trailingSpace { text += " " }
            let held = CGEventSource.flagsState(.combinedSessionState).union(listener?.lastFlags ?? []).union(stopFlags)
            switch config.delivery(for: held) {
            case .paste:
                Paster.paste(text, restoreClipboard: config.restoreClipboard, restoreAfter: config.restoreClipboardAfterSeconds)
            case .copy:
                Paster.copy(text)
                log("copied")
            case .send:
                Paster.paste(text, restoreClipboard: config.restoreClipboard, restoreAfter: config.restoreClipboardAfterSeconds, thenReturn: true)
                log("sent")
            }
        case .failure(let error):
            log("transcribe failed: \(error)")
            beep()
        }
    }

    // MARK: UI

    @objc private func copyConfigPath() {
        Paster.copy(Config.path.path)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "Dictate", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)
        menu.addItem(NSMenuItem.separator())
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleMenu.delegate = self
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        menu.addItem(NSMenuItem.separator())
        let copyPath = NSMenuItem(title: "Copy Config Path", action: #selector(copyConfigPath), keyEquivalent: "")
        copyPath.target = self
        menu.addItem(copyPath)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        setIcon("○")
    }

    private func setIcon(_ glyph: String, color: NSColor = .labelColor) {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = NSAttributedString(
            string: glyph,
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 14)])
    }

    private func beep() { NSSound.beep() }

    // MARK: menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu {
        case micMenu: updateMicrophoneMenu()
        case styleMenu: updateStyleMenu()
        default: break
        }
    }

    /// No checkmark when the config file sets a mix no preset matches.
    private func updateStyleMenu() {
        styleMenu.removeAllItems()
        let current = config.withMenuPicks.style
        for style in Config.Style.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == current ? .on : .off
            styleMenu.addItem(item)
        }
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Config.pickedStyle = Config.Style(rawValue: raw)
        dictation.config = config.withMenuPicks
        log("style: \(raw)")
    }

    /// Rebuilt each time the submenu opens so newly plugged devices show up.
    private func updateMicrophoneMenu() {
        let menu = micMenu
        menu.removeAllItems()
        let picked = AudioDevices.selectedUID ?? config.microphone
        let effective = AudioDevices.resolve(configured: config.microphone)
        let defaultItem = NSMenuItem(title: "System Default", action: #selector(pickMicrophone(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = picked == nil ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(NSMenuItem.separator())
        for device in AudioDevices.inputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(pickMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = (picked != nil && device == effective) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func pickMicrophone(_ sender: NSMenuItem) {
        AudioDevices.selectedUID = sender.representedObject as? String
        log("microphone: \(sender.title)")
    }

    private func requestPermissions() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            log("Accessibility not granted yet; approve dictate in System Settings > Privacy & Security > Accessibility")
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            if !ok { log("microphone access denied") }
        }
    }
}

import AVFoundation
