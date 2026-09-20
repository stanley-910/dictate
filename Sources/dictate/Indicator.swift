import AppKit

/// Floating pill: a status dot and a scrolling waveform of the live input
/// level. Draggable, on every Space, never takes focus.
final class Indicator {
    enum Mode { case recording, armed, transcribing }

    private let panel: NSPanel
    private let wave = WaveView()
    private var timer: Timer?
    private var placing = false
    private static let size = NSSize(width: 220, height: 44)
    private static let originKey = "indicatorOrigin"

    /// Anchor used when the pill has not been dragged.
    var position: Config.IndicatorPosition = .bottom {
        didSet { if position != oldValue { Indicator.savedOrigin = nil } }
    }
    var margin: CGFloat = 14

    init() {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Indicator.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.alphaValue = 0

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: Indicator.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Indicator.size.height / 2
        blur.layer?.masksToBounds = true
        wave.frame = blur.bounds
        wave.autoresizingMask = [.width, .height]
        blur.addSubview(wave)
        p.contentView = blur
        panel = p
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            guard let self, !self.placing, self.panel.alphaValue > 0 else { return }
            Indicator.savedOrigin = self.panel.frame.origin
        }
    }

    /// Origin left by the last drag, if any.
    private static var savedOrigin: NSPoint? {
        get {
            guard let a = UserDefaults.standard.array(forKey: originKey) as? [Double], a.count == 2 else { return nil }
            return NSPoint(x: a[0], y: a[1])
        }
        set {
            if let p = newValue { UserDefaults.standard.set([p.x, p.y], forKey: originKey) }
            else { UserDefaults.standard.removeObject(forKey: originKey) }
        }
    }

    var mode: Mode = .recording {
        didSet { wave.mode = mode; wave.needsDisplay = true }
    }

    func show(_ mode: Mode) {
        self.mode = mode
        wave.reset()
        place()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [wave] _ in wave.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Feed a linear RMS level (0...1) from the audio thread or main.
    func push(level: Float) {
        wave.target = level
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    /// The dragged spot if it is still on some screen, else the configured
    /// anchor on the screen under the pointer.
    private func place() {
        placing = true
        defer { placing = false }
        if let saved = Indicator.savedOrigin,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -Indicator.size.width / 2, dy: 0).contains(saved) }) {
            panel.setFrameOrigin(saved)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let f = screen.visibleFrame
        let w = Indicator.size.width, h = Indicator.size.height, m = margin
        let x: CGFloat, y: CGFloat
        switch position {
        case .bottom:      x = f.midX - w / 2;  y = f.minY + m
        case .top:         x = f.midX - w / 2;  y = f.maxY - h - m
        case .topLeft:     x = f.minX + m;      y = f.maxY - h - m
        case .topRight:    x = f.maxX - w - m;  y = f.maxY - h - m
        case .bottomLeft:  x = f.minX + m;      y = f.minY + m
        case .bottomRight: x = f.maxX - w - m;  y = f.minY + m
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Draws the dot and the bars. Levels enter on the right and scroll left.
final class WaveView: NSView {
    var mode: Indicator.Mode = .recording
    /// Latest level from the recorder; `tick` smooths it into `current`.
    var target: Float = 0
    private var current: Float = 0
    private var history: [Float]
    private var phase: CGFloat = 0
    private let bars = 40

    override init(frame: NSRect) {
        history = Array(repeating: 0, count: bars)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        history = Array(repeating: 0, count: bars)
        current = 0
        target = 0
        phase = 0
    }

    func tick() {
        switch mode {
        case .recording, .armed:
            // Fast attack, slow release, then scroll.
            let t = WaveView.normalize(target)
            current = t > current ? t : max(t, current * 0.82)
            history.removeFirst()
            history.append(current)
        case .transcribing:
            phase += 0.045
            if phase > 1.6 { phase = -0.6 }
        }
        needsDisplay = true
    }

    /// Map RMS to 0...1 on a dB scale so quiet speech still moves.
    private static func normalize(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 40))
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let dotColor: NSColor
        let barColor: NSColor
        switch mode {
        case .recording: dotColor = .systemRed; barColor = .labelColor
        case .armed: dotColor = .systemYellow; barColor = .systemYellow
        case .transcribing: dotColor = .systemOrange; barColor = .labelColor
        }

        let dotR: CGFloat = 4.5
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: h / 2 - dotR, width: dotR * 2, height: dotR * 2)).fill()

        let left: CGFloat = 34, right = bounds.width - 16
        let gap: CGFloat = 1.5
        let w = (right - left - gap * CGFloat(bars - 1)) / CGFloat(bars)
        let maxH = h - 18
        for (i, level) in history.enumerated() {
            let x = left + CGFloat(i) * (w + gap)
            let bh = max(2, CGFloat(level) * maxH)
            var alpha: CGFloat = 1
            if mode == .transcribing {
                // Dim the frozen waveform and sweep a highlight across it.
                let d = abs(CGFloat(i) / CGFloat(bars) - phase)
                alpha = 0.3 + 0.7 * max(0, 1 - d * 6)
            }
            barColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: h / 2 - bh / 2, width: w, height: bh),
                         xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}
