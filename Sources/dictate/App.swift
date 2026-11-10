import AppKit
import Carbon.HIToolbox
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
    private let cheatMenu = NSMenu(title: "Cheat Sheet")
    private let recentMenu = NSMenu(title: "Recent Recordings")
    private let dictionaryWindow = DictionaryWindow()
    /// Written on main; the tap's thread reads it too.
    private var recording = false
    /// Stopped recordings still decoding. A new recording can start meanwhile;
    /// their text is delivered in the order they stopped.
    private var deliveries = DeliveryQueue<Job, Result<String, Error>>()
    private var state: State { recording ? .recording : deliveries.isEmpty ? .idle : .transcribing }

    private enum Job {
        /// A recording just stopped, with the modifiers held and the app
        /// frontmost as it stopped.
        case dictation(stopFlags: CGEventFlags, target: NSRunningApplication?)
        /// A saved recording decoded again from the menu; its text is copied.
        case saved(Recovery.Take)
    }
    private var maxTimer: Timer?
    private var warnTimer: Timer?
    /// Inside `maximumWarnSeconds` of the safety stop.
    private var nearMaximum = false
    private var reloadTimer: Timer?
    private var configModified: Date?
    /// Index of the hotkey that started the current recording.
    private var activeHotkey = 0
    /// The bound hotkeys, as the listener has them.
    private var hotkeys: [Hotkey] = []
    /// When each hotkey last went down, by index.
    private var pressedAt: [Int: Date] = [:]
    /// The recording was started by a press (not a lone key's release), so
    /// holding that press past `holdToTalkAfterSeconds` makes it push-to-talk.
    private var pressStarted = false
    /// The last delivery found no speech: the pill shows it before hiding.
    private var heardNothing = false
    /// `config.deliveryModifierFlags`, kept apart for the tap's thread.
    private var deliveryFlags: CGEventFlags = []

    init(config: Config) {
        self.config = config
        self.dictation = Dictation(config: config.withMenuPicks)
        self.deliveryFlags = config.deliveryModifierFlags
        super.init()
        if config.indicator {
            dictation.recorder.onLevel = { [indicator] level, _ in indicator.push(level: level) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        Recovery.migrate()
        if let take = Recovery.interrupted() {
            log("recording \(take.id) was interrupted (\(Int(take.seconds)) s kept); it is in Recent Recordings")
        }
        requestPermissions()
        startListening()
        ClipboardHistory.shared.start()
        configModified = Config.modified
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reloadIfChanged()
        }
        secureTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkSecureInput()
        }
    }

    /// Secure input (a password field, Terminal's Secure Keyboard Entry) is
    /// on: keys never reach the event tap, so the hotkey is dead until it is
    /// off. The idle dot dims so that is not a mystery.
    private var secureInput = false
    private var secureTimer: Timer?

    private func checkSecureInput() {
        let on = IsSecureEventInputEnabled()
        guard on != secureInput else { return }
        secureInput = on
        if on {
            let holder = (CGSessionCopyCurrentDictionary() as? [String: Any]).flatMap(Self.secureInputHolder)
                .flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            log("secure input on\(holder.map { " (\($0))" } ?? ""); the hotkey is blocked until it is off")
        } else {
            log("secure input off")
        }
        statusItem?.button?.toolTip = on ? "Secure input on" : nil
        if state == .idle, listener != nil { setIdleIcon() }
    }

    /// The process holding secure input, from the session dictionary
    /// (an undocumented key; nil when absent).
    static func secureInputHolder(_ session: [String: Any]) -> pid_t? {
        (session["kCGSSessionSecureInputPID"] as? NSNumber).map { pid_t($0.int32Value) }
    }

    private func setIdleIcon() {
        setIcon("○", color: secureInput ? .tertiaryLabelColor : .labelColor)
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
        deliveryFlags = config.deliveryModifierFlags
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
        self.hotkeys = hotkeys
        let l = HotkeyListener(hotkeys: hotkeys) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        l.capturesEscape = { [weak self] in
            // Read on the tap's thread; `recording` is only written on main, and a
            // stale read here costs at most one Escape passing through.
            self?.recording == true
        }
        l.toleratedModifiers = { [weak self] in
            guard let self, self.recording else { return [] }
            return self.deliveryFlags
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
        setIdleIcon()
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
            if recording { escapePressed() }
        case .pressed(let i):
            pressedAt[i] = Date()
            act(.press, key: i)
        case .released(let i, let clean):
            act(.release(clean: clean), key: i)
        case .chorded(let i):
            act(.chord, key: i)
        }
    }

    /// Earlier recordings still decoding do not hold up the next one: a
    /// press starts it whatever is in flight.
    private func act(_ event: Trigger.Event, key i: Int) {
        guard i < hotkeys.count else { return }
        let key = Trigger.Key(mode: i == 0 ? config.mode : .hold, lone: hotkeys[i].loneModifierKeyCode != nil,
                              holdAfterSeconds: config.holdToTalkAfterSeconds)
        let held = pressedAt[i].map { Date().timeIntervalSince($0) } ?? 0
        let now = Trigger.State(recording: recording, ownsRecording: activeHotkey == i, heldSeconds: held,
                                pressStarted: pressStarted)
        switch Trigger.action(event, key: key, state: now) {
        case .start:
            activeHotkey = i
            pressStarted = event == .press
            startRecording()
        case .stop:
            stopAndTranscribe()
        case .discard:
            discard()
        case .none:
            break
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
        recording = true
        setIcon("●", color: .systemRed)
        if config.indicator {
            indicator.position = config.indicatorPosition
            indicator.margin = config.indicatorMargin
            indicator.show(.recording)
        }
        playSound(config.soundPack.start)
        dictation.muteSpeakersIfConfigured()
        stopTimers()
        maxTimer = Timer.scheduledTimer(withTimeInterval: config.maximumSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            log("reached maximumSeconds (\(Int(self.config.maximumSeconds)) s); stopping")
            self.stopAndTranscribe()
        }
        let warnAt = config.maximumSeconds - config.maximumWarnSeconds
        if config.maximumWarnSeconds > 0, warnAt > 0 {
            warnTimer = Timer.scheduledTimer(withTimeInterval: warnAt, repeats: false) { [weak self] _ in
                guard let self, self.recording else { return }
                log("\(Int(self.config.maximumWarnSeconds)) s to maximumSeconds")
                self.nearMaximum = true
                self.playSound(self.config.soundPack.warn)
                if !self.cancelArmed {
                    self.setIcon("●", color: .systemPurple)
                    self.indicator.mode = .ending
                }
            }
        }
    }

    private func stopTimers() {
        maxTimer?.invalidate()
        warnTimer?.invalidate()
        nearMaximum = false
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
        playSound(config.soundPack.arm)
        cancelArmTimer?.invalidate()
        cancelArmTimer = Timer.scheduledTimer(withTimeInterval: confirmWindow, repeats: false) { [weak self] _ in
            guard let self, self.recording else { return }
            self.cancelArmed = false
            self.setIcon("●", color: self.nearMaximum ? .systemPurple : .systemRed)
            self.indicator.mode = self.nearMaximum ? .ending : .recording
        }
    }

    private func disarmCancel() {
        cancelArmed = false
        cancelArmTimer?.invalidate()
    }

    private func cancel() {
        disarmCancel()
        stopTimers()
        _ = dictation.stop()
        recording = false
        showState()
        playSound(config.soundPack.cancel)
        log("cancelled")
    }

    /// A hold key that turned out to be part of a shortcut (Right-Command+C):
    /// gone without a sound or a saved recording.
    private func discard() {
        disarmCancel()
        stopTimers()
        _ = dictation.stop(discard: true)
        recording = false
        showState()
        log("discarded: the hotkey was part of a shortcut")
    }

    private func stopAndTranscribe() {
        guard recording else { return }
        disarmCancel()
        stopTimers()
        let (pcm, seconds) = dictation.stop()
        recording = false
        let stopFlags = listener?.lastFlags ?? []
        if dictation.isTooShort(seconds) {
            showState()
            return
        }
        let target = NSWorkspace.shared.frontmostApplication
        let ticket = deliveries.add(.dictation(stopFlags: stopFlags, target: target))
        showState()
        playSound(config.soundPack.stop)
        let input = dictation.inputName
        dictation.text(from: pcm, recording: true) { [weak self] result in
            // Off main, and only when needed: a long recording takes a moment.
            if case .success(let text) = result, text.isEmpty {
                log("no speech in \(String(format: "%.1f", seconds)) s from \(input); \(Dictation.levels(pcm))")
            }
            DispatchQueue.main.async { self?.finished(ticket, result) }
        }
    }

    /// The icon and pill for the state after a stop, cancel or delivery. A
    /// recording keeps its own colours, set where they change.
    private func showState() {
        switch state {
        case .recording:
            break
        case .transcribing:
            setIcon("◐", color: .systemOrange)
            indicator.mode = .transcribing
        case .idle:
            setIdleIcon()
            guard heardNothing else { return indicator.hide() }
            heardNothing = false
            indicator.mode = .nothing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.state == .idle else { return }
                self.indicator.hide()
            }
        }
    }

    private func finished(_ ticket: Int, _ result: Result<String, Error>) {
        for (job, result) in deliveries.finish(ticket, result) { deliver(job, result) }
        showState()
    }

    private func deliver(_ job: Job, _ result: Result<String, Error>) {
        heardNothing = false
        switch (job, result) {
        case (.dictation(let stopFlags, let target), .success(var text)):
            if text.isEmpty {
                // Silence, or speech too quiet for the gate: say so rather
                // than leave the user waiting for text that is not coming.
                playSound(config.soundPack.nothing)
                heardNothing = !recording
                return
            }
            // While the next recording runs, the modifiers held are its own
            // (a hold key, a delivery pick for it): only the stop's count.
            let held = recording ? stopFlags
                : CGEventSource.flagsState(.combinedSessionState).union(listener?.lastFlags ?? []).union(stopFlags)
            let chosen = config.delivery(for: held)
            let front = NSWorkspace.shared.frontmostApplication
            let delivery = PasteTarget.delivery(chosen, stoppedIn: target?.processIdentifier, frontNow: front?.processIdentifier)
            if delivery != chosen {
                // Focus is not moved back: the user went somewhere on purpose.
                text = ClipboardHistory.shared.fill(text, order: config.pasteOrder)
                if text.isEmpty { return }
                if config.trailingSpace { text += " " }
                Paster.copy(text)
                playSound(config.soundPack.copied)
                log("copied: recorded for \(target?.localizedName ?? "?"), \(front?.localizedName ?? "?") is frontmost now")
                return
            }
            if delivery != .copy, config.cursorContext {
                text = CursorText.fit(text, after: CursorText.beforeCursor(), terms: config.dictionary,
                                      isWord: CursorText.isKnownWord)
            }
            // After the fit, so a pasted copy keeps its own casing.
            text = ClipboardHistory.shared.fill(text, order: config.pasteOrder)
            if text.isEmpty { return }
            if config.trailingSpace { text += " " }
            switch delivery {
            case .paste:
                Paster.paste(text, restoreClipboard: config.restoreClipboard, restoreAfter: config.restoreClipboardAfterSeconds)
            case .copy:
                Paster.copy(text)
                log("copied")
            case .send:
                Paster.paste(text, restoreClipboard: config.restoreClipboard, restoreAfter: config.restoreClipboardAfterSeconds, thenReturn: true)
                log("sent")
            }
        case (.saved(let take), .success(let text)):
            if text.isEmpty {
                playSound(config.soundPack.nothing)
                log("no speech in recording \(take.id)")
                return
            }
            take.saveText(text)
            Paster.copy(text)
            playSound(config.soundPack.stop)
            log("copied recording \(take.id)")
        case (_, .failure(let error)):
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
        let muteItem = NSMenuItem(title: "Mute Sounds", action: #selector(toggleMute(_:)), keyEquivalent: "")
        muteItem.target = self
        muteItem.state = Config.soundsMuted ? .on : .off
        menu.addItem(muteItem)
        menu.addItem(NSMenuItem.separator())
        let cheatItem = NSMenuItem(title: "Cheat Sheet", action: nil, keyEquivalent: "")
        cheatMenu.delegate = self
        cheatItem.submenu = cheatMenu
        menu.addItem(cheatItem)
        let dictItem = NSMenuItem(title: "Dictionary…", action: #selector(showDictionary), keyEquivalent: "d")
        dictItem.target = self
        menu.addItem(dictItem)
        menu.addItem(NSMenuItem.separator())
        let lastText = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "")
        lastText.target = self
        menu.addItem(lastText)
        let lastAudio = NSMenuItem(title: "Transcribe Last Recording", action: #selector(transcribeLastRecording), keyEquivalent: "")
        lastAudio.target = self
        menu.addItem(lastAudio)
        let recentItem = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
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

    /// Never shown (the app has no Dock icon or menu bar of its own), but key
    /// equivalents route through it: without Edit, Cmd-V does nothing in the
    /// Dictionary window.
    private func setupMainMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Dictate", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func copyLastTranscript() {
        guard let text = Recovery.lastText else { return beep() }
        Paster.copy(text)
    }

    /// Decodes the newest saved recording again and copies the text: for a
    /// recording that failed, was cancelled by mistake, or pasted into the
    /// wrong place.
    @objc private func transcribeLastRecording() {
        guard let take = Recovery.recent().first else {
            log("no saved recording")
            return beep()
        }
        retranscribe(take)
    }

    /// One row per saved recording: copies its text, or with Option held,
    /// decodes it again (also what a row with no text does).
    private func updateRecentMenu() {
        recentMenu.removeAllItems()
        let takes = Recovery.recent()
        if takes.isEmpty {
            recentMenu.addItem(NSMenuItem(title: "None", action: nil, keyEquivalent: ""))
            return
        }
        let time = DateFormatter()
        time.dateFormat = "MMM d, HH:mm"
        for take in takes {
            let when = take.date.map(time.string(from:)) ?? take.id
            let length = Int(take.seconds.rounded())
            let text = take.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let preview = text.isEmpty ? "no text" : (text.count > 40 ? text.prefix(40) + "…" : text)
            let copy = NSMenuItem(title: "\(when) · \(length / 60):\(String(format: "%02d", length % 60)) · \(preview)",
                                  action: #selector(recentPicked(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = take.id
            recentMenu.addItem(copy)
            let again = NSMenuItem(title: "Transcribe \(when) Again", action: #selector(recentRetranscribe(_:)), keyEquivalent: "")
            again.target = self
            again.representedObject = take.id
            again.isAlternate = true
            again.keyEquivalentModifierMask = .option
            recentMenu.addItem(again)
        }
        recentMenu.addItem(NSMenuItem.separator())
        let folder = NSMenuItem(title: "Show in Finder", action: #selector(showRecordings), keyEquivalent: "")
        folder.target = self
        recentMenu.addItem(folder)
    }

    @objc private func recentPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let take = Recovery.Take(id: id)
        if let text = take.text, !text.isEmpty { Paster.copy(text) } else { retranscribe(take) }
    }

    @objc private func recentRetranscribe(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        retranscribe(Recovery.Take(id: id))
    }

    @objc private func showRecordings() {
        NSWorkspace.shared.open(Recovery.recordings)
    }

    private func retranscribe(_ take: Recovery.Take) {
        guard !recording else { return beep() }
        let pcm: [Float]
        do { pcm = try Wav.readMono16k(take.audioURL) } catch {
            log("could not read recording \(take.id): \(error)")
            return beep()
        }
        let ticket = deliveries.add(.saved(take))
        showState()
        dictation.text(from: pcm) { [weak self] result in
            DispatchQueue.main.async { self?.finished(ticket, result) }
        }
    }

    @objc private func showDictionary() {
        dictionaryWindow.show()
    }

    private func setIcon(_ glyph: String, color: NSColor = .labelColor) {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = NSAttributedString(
            string: glyph,
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 14)])
    }

    private func beep() { NSSound.beep() }

    private func playSound(_ name: String?) {
        if config.sounds && !Config.soundsMuted { Sounds.play(name) }
    }

    // MARK: menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu {
        case micMenu: updateMicrophoneMenu()
        case styleMenu: updateStyleMenu()
        case cheatMenu: updateCheatMenu()
        case recentMenu: updateRecentMenu()
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

    /// Plain replacements as written, then each `cheatSheet` phrase run
    /// through the replacements, so the list always shows what dictating it
    /// gives now. Picking a row copies the result.
    private func updateCheatMenu() {
        cheatMenu.removeAllItems()
        var rows = config.replacements.filter { $0.regex != true }.map { ($0.from, $0.to) }
        let phrases = config.cheatSheet.map { ($0, Replacements.apply($0, rules: config.replacements)) }
        let width = (rows + phrases).map { $0.0.count }.max() ?? 0
        if !rows.isEmpty, !phrases.isEmpty { rows.append(("", "")) }
        for (said, result) in rows + phrases {
            if said.isEmpty {
                cheatMenu.addItem(NSMenuItem.separator())
                continue
            }
            let item = NSMenuItem(title: "", action: #selector(copyCheat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = result
            item.attributedTitle = NSAttributedString(
                string: said.padding(toLength: width + 2, withPad: " ", startingAt: 0) + result,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
            cheatMenu.addItem(item)
        }
        if cheatMenu.items.isEmpty {
            let empty = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            cheatMenu.addItem(empty)
        }
    }

    @objc private func copyCheat(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? String else { return }
        Paster.copy(result)
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Config.pickedStyle = Config.Style(rawValue: raw)
        dictation.config = config.withMenuPicks
        log("style: \(raw)")
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        Config.soundsMuted.toggle()
        sender.state = Config.soundsMuted ? .on : .off
        log(Config.soundsMuted ? "sounds muted" : "sounds unmuted")
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
