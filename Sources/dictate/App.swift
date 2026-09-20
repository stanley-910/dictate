import AppKit
import Foundation

/// The daemon: hotkey -> record -> transcribe -> paste, with a menu bar dot.
final class DictateApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording, transcribing }

    private let config: Config
    private let recorder = Recorder()
    private let transcriber: Transcriber
    private let indicator = Indicator()
    private var listener: HotkeyListener?
    private var statusItem: NSStatusItem?
    private var state: State = .idle
    private var maxTimer: Timer?
    private var pressedAt: Date?

    init(config: Config) {
        self.config = config
        self.transcriber = Transcriber(config: config)
        super.init()
        if config.indicator {
            recorder.onLevel = { [indicator] level in indicator.push(level: level) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let hotkey = Hotkey.parse(config.hotkey) else {
            log("bad hotkey: \(config.hotkey)")
            NSApp.terminate(nil)
            return
        }
        setupStatusItem()
        requestPermissions()

        startListening(hotkey)
    }

    /// Installs the event tap, retrying until Accessibility is granted so the
    /// first-run flow is: launch, approve the prompt, start dictating.
    private func startListening(_ hotkey: Hotkey) {
        let l = HotkeyListener(hotkey: hotkey) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        l.capturesEscape = { [weak self] in
            // Read on the tap's thread; `state` is only written on main, and a
            // stale read here costs at most one Escape passing through.
            self?.state == .recording
        }
        do {
            try l.start()
        } catch {
            if !warnedAboutAccessibility {
                log("waiting for Accessibility: System Settings > Privacy & Security > Accessibility > Dictate")
                warnedAboutAccessibility = true
            }
            setIcon("○", color: .tertiaryLabelColor)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startListening(hotkey) }
            return
        }
        listener = l
        setIcon("○")
        log("ready: \(config.hotkey) (\(config.mode.rawValue)), model \(config.modelURL.lastPathComponent)")
    }
    private var warnedAboutAccessibility = false

    func applicationWillTerminate(_ notification: Notification) {
        transcriber.unloadSync()  // ggml's Metal teardown asserts if a model outlives exit()
    }

    // MARK: hotkey state machine

    private func handle(_ event: HotkeyListener.Event) {
        switch (event, config.mode, state) {
        case (.escape, _, .recording):
            escapePressed()
        case (.pressed, .toggle, .idle):
            startRecording()
        case (.pressed, .toggle, .recording):
            stopAndTranscribe()
        case (.pressed, .hold, .idle):
            pressedAt = Date()
            startRecording()
        case (.released, .hold, .recording):
            stopAndTranscribe()
        default:
            break
        }
    }

    private func startRecording() {
        do {
            try recorder.start(device: AudioDevices.resolve(configured: config.microphone))
        } catch {
            log("\(error)")
            beep()
            return
        }
        state = .recording
        transcriber.preload()
        setIcon("●", color: .systemRed)
        if config.indicator { indicator.show(.recording) }
        if config.sounds { NSSound(named: "Tink")?.play() }
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
            && recorder.duration >= config.cancelConfirmAfterSeconds
        if !needsConfirm || cancelArmed {
            cancel()
            return
        }
        cancelArmed = true
        setIcon("●", color: .systemYellow)
        indicator.mode = .armed
        if config.sounds { NSSound(named: "Morse")?.play() }
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
        _ = recorder.stop()
        state = .idle
        setIcon("○")
        indicator.hide()
        if config.sounds { NSSound(named: "Bottle")?.play() }
        log("cancelled")
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        disarmCancel()
        maxTimer?.invalidate()
        let seconds = recorder.duration
        let pcm = recorder.stop()
        if seconds < config.minimumSeconds {
            state = .idle
            setIcon("○")
            indicator.hide()
            return
        }
        state = .transcribing
        setIcon("◐", color: .systemOrange)
        indicator.mode = .transcribing
        if config.sounds { NSSound(named: "Pop")?.play() }
        transcriber.transcribe(pcm) { [weak self] result in
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        state = .idle
        setIcon("○")
        indicator.hide()
        switch result {
        case .success(let raw):
            var text = config.postProcess(raw)
            if text.isEmpty { return }
            if config.trailingSpace { text += " " }
            Paster.paste(text)
        case .failure(let error):
            log("transcribe failed: \(error)")
            beep()
        }
    }

    // MARK: UI

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "Dictate", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu(title: "Microphone")
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)
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

    // MARK: microphone menu

    /// Rebuilt each time the submenu opens so newly plugged devices show up.
    func menuNeedsUpdate(_ menu: NSMenu) {
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
