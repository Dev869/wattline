// A small always-on-top read-out that sits over anything, including a video
// playing fullscreen.
//
// The shape of this is dictated by three AppKit facts:
//   - NSPanel with .nonactivatingPanel never steals focus, so clicking it does
//     not pause whatever you are watching.
//   - .statusBar window level floats above ordinary windows.
//   - .canJoinAllSpaces + .fullScreenAuxiliary is what gets it over a
//     fullscreen app rather than being hidden behind that app's Space.
// Deliberately never calls NSApp.activate: that would defeat the whole thing.
//
// It is click-through by default so a click meant for the play button beneath
// it reaches the player. Option is the one modifier that makes it live: hold
// it to drag the panel, or drag its bottom-right corner to resize.
//
// This file owns window behaviour only. The numbers live in Readout.swift and
// the workout profile in PlanGraph.swift.

import AppKit

final class Overlay: NSPanel {
    private let blur = NSVisualEffectView()
    // A plain layer-backed view actually clips its subviews. Setting
    // cornerRadius + masksToBounds on the visual effect view does not: it
    // manages its own layer tree, so the graph bars ran square through the
    // rounded corners.
    private let clip = NSView()
    private let readout = Readout(frame: .zero)
    private let graph = PlanGraph(frame: .zero)

    private let baseWidth: CGFloat = 240
    private let collapsedHeight: CGFloat = 62
    private let workoutRowHeight: CGFloat = 26

    private(set) var scale: CGFloat = 1.0
    var opacity: Double = 1.0
    private(set) var showGraph = true

    // Option held: the panel becomes grabbable. Polled rather than watched
    // with a global .flagsChanged monitor, which would need Accessibility
    // permission this app otherwise never asks for.
    // ponytail: 100ms poll; switch to a monitor if we ever take Accessibility.
    private var grabTimer: Timer?
    private var resizing = false
    private var resizeStart: (mouse: NSPoint, size: NSSize)?

    // Dim rather than vanish when you stop: riding pauses for a red light as
    // much as for a good scene, and a readout that disappears is a readout you
    // go looking for.
    private var lastActive = Date()
    private var isIdle = false
    private let idleAfter: TimeInterval = 10
    private let idleDim = 0.35

    private var hasWorkout = false
    // The countdown is scheduled, not polled. Status arrives every 2s, so a
    // poll-driven countdown can only ever catch one of 3, 2, 1 - which is
    // exactly what it did.
    private var scheduledTransition: Double = -1
    private var beepTimers: [Timer] = []

    // Preferences the settings window writes.
    var beepEnabled = UserDefaults.standard.object(forKey: "overlayBeep") as? Bool ?? true
    var idleDimEnabled = UserDefaults.standard.object(forKey: "overlayIdleDim") as? Bool ?? true

    /// Every beep is recorded: whether it fired, at which countdown tick, and
    /// whether the sound system accepted it. Audio output cannot be captured
    /// here, but the part that regresses - firing at the wrong moment, firing
    /// twice, not firing at all - is exactly what this makes testable.
    private static let beepLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/wattline-beeps.log")

    /// Book the 3, 2 and 1 beeps against the clock as soon as a transition is
    /// close enough to see, rather than waiting for a status poll to happen to
    /// land on each second.
    private func scheduleCountdown(toNext: Double, transitionAt: Double) {
        guard toNext <= 6 else { return }
        // Same transition we already booked? Leave the timers alone.
        guard abs(transitionAt - scheduledTransition) > 1.0 else { return }
        cancelCountdown()
        scheduledTransition = transitionAt
        for tick in [3, 2, 1] {
            let delay = toNext - Double(tick)
            guard delay >= -0.25 else { continue }
            let timer = Timer.scheduledTimer(withTimeInterval: max(0, delay), repeats: false) {
                [weak self] _ in
                guard let self else { return }
                var played = false
                if self.beepEnabled {
                    played = NSSound(named: tick == 1 ? "Ping" : "Tink")?.play() ?? false
                }
                self.recordBeep(tick: tick, played: played)
            }
            beepTimers.append(timer)
        }
    }

    private func cancelCountdown() {
        beepTimers.forEach { $0.invalidate() }
        beepTimers.removeAll()
        scheduledTransition = -1
    }

    private func recordBeep(tick: Int, played: Bool) {
        let line = "\(Date().timeIntervalSince1970) tick=\(tick) played=\(played)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.beepLog) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.beepLog)
        }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 62),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow

        // Forced dark: .hudWindow follows the system appearance, so over a
        // light desktop the panel came out near-white with white text on it.
        appearance = NSAppearance(named: .darkAqua)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        blur.autoresizingMask = [.width, .height]
        // Mask the material itself as well, so the blur does not square off
        // behind the clipped content.
        blur.maskImage = Self.roundedMask(radius: 16)
        contentView = blur

        clip.wantsLayer = true
        clip.layer?.cornerRadius = 16
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(clip)

        // Order matters: the graph goes in first so it sits behind the
        // numbers. It is a backdrop the readout is legible against, not a
        // panel of its own, so it fills the whole panel rather than taking a
        // row of its own.
        for v in [graph, readout] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(v)
        }
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            clip.topAnchor.constraint(equalTo: blur.topAnchor),
            clip.bottomAnchor.constraint(equalTo: blur.bottomAnchor),

            graph.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            graph.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            graph.topAnchor.constraint(equalTo: clip.topAnchor),
            graph.bottomAnchor.constraint(equalTo: clip.bottomAnchor),

            readout.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            readout.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            readout.topAnchor.constraint(equalTo: clip.topAnchor),
            readout.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])

        restorePosition()
        let d = UserDefaults.standard
        scale = d.object(forKey: "overlayScale") as? CGFloat ?? 1.0
        opacity = d.object(forKey: "overlayOpacity") as? Double ?? 1.0
        showGraph = d.object(forKey: "overlayGraph") as? Bool ?? true
        applyScale()
    }

    override var canBecomeKey: Bool { false }

    /// A resizable rounded-rect mask for the material. capInsets keep the
    /// corners crisp at any panel size instead of stretching them.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: geometry

    /// Collapsed unless a workout is loaded; the workout is the only thing
    /// with enough to say to earn the extra height.
    private var naturalSize: NSSize {
        // The graph is a backdrop behind the numbers rather than a row of its
        // own, so a workout only costs the height of its extra line.
        NSSize(width: baseWidth, height: hasWorkout ? collapsedHeight + workoutRowHeight : collapsedHeight)
    }

    private func applyScale() {
        let want = naturalSize
        var rect = NSRect(origin: frame.origin,
                          size: NSSize(width: want.width * scale, height: want.height * scale))
        // It grows right and up from its saved corner and normally lives near
        // an edge, so without this the bigger sizes push the readout offscreen.
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        }
        setFrame(rect, display: true)

        readout.apply(scale: scale)
        let radius = 16 * scale
        blur.layer?.cornerRadius = radius
        blur.maskImage = Self.roundedMask(radius: radius)
        clip.layer?.cornerRadius = radius
        graph.isHidden = !(hasWorkout && showGraph)
    }

    func setScale(_ s: CGFloat) {
        scale = min(2.5, max(0.6, s))
        UserDefaults.standard.set(scale, forKey: "overlayScale")
        applyScale()
    }

    /// Re-read everything the settings window may have changed.
    func reloadPreferences() {
        let d = UserDefaults.standard
        beepEnabled = d.object(forKey: "overlayBeep") as? Bool ?? true
        idleDimEnabled = d.object(forKey: "overlayIdleDim") as? Bool ?? true
        showGraph = d.object(forKey: "overlayGraph") as? Bool ?? true
        readout.reloadFields()
        applyScale()
        applyAlpha()
    }

    func setGraph(_ on: Bool) {
        showGraph = on
        UserDefaults.standard.set(on, forKey: "overlayGraph")
        applyScale()
    }

    func setOpacity(_ o: Double) {
        opacity = o
        UserDefaults.standard.set(o, forKey: "overlayOpacity")
        applyAlpha()
    }

    /// Idle dim multiplies the chosen opacity rather than replacing it, so the
    /// two settings compose instead of one clobbering the other.
    private func applyAlpha() {
        alphaValue = CGFloat(opacity * (isIdle && idleDimEnabled ? idleDim : 1))
    }

    func restorePosition() {
        let saved = UserDefaults.standard.string(forKey: "overlayOrigin")
        if let saved, let screen = NSScreen.main {
            let point = NSPointFromString(saved)
            if screen.frame.contains(point) { setFrameOrigin(point); return }
        }
        if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.minY + 24))
        }
    }

    func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: "overlayOrigin")
    }

    // MARK: content

    /// Feed it the daemon's JSON. `interval` is how often this is called, so
    /// the readout knows how many samples make up its smoothing window.
    func update(_ s: [String: Any], interval: Double = 2.0) {
        let power = s["power"] as? Int ?? 0
        let cadence = s["cadence"] as? Int ?? 0
        let workout = s["workout"] as? [String: Any]

        let nowHasWorkout = workout != nil
        if nowHasWorkout != hasWorkout {
            hasWorkout = nowHasWorkout
            applyScale()
        }

        if power > 0 || cadence > 0 { lastActive = Date() }
        // A running workout is never idle: the trainer is about to do
        // something to you whether or not you are pedalling this second.
        let idleNow = idleDimEnabled && !nowHasWorkout
            && Date().timeIntervalSince(lastActive) > idleAfter
        if idleNow != isIdle {
            isIdle = idleNow
            applyAlpha()
        }

        let toNext = readout.update(s, interval: interval)
        graph.update(workout: workout, power: power)
        alert(secondsToNext: toNext)
        if let toNext, let elapsed = workout?["elapsed"] as? Double {
            scheduleCountdown(toNext: toNext, transitionAt: elapsed + toNext)
        } else {
            cancelCountdown()
        }
    }

    /// The step warning. No flashing: the category convention is a countdown
    /// plus a held colour, and a flashing saturated red would trip the WCAG
    /// red-flash threshold. The edge fills and stays filled.
    private func alert(secondsToNext: Double?) {
        guard let seconds = secondsToNext, hasWorkout else {
            blur.layer?.borderWidth = 0.5 * scale
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            return
        }
        if seconds <= 3.5 {
            blur.layer?.borderWidth = 3 * scale
            blur.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.95).cgColor
        } else {
            blur.layer?.borderWidth = seconds <= 15 ? 1.5 * scale : 0.5 * scale
            blur.layer?.borderColor = seconds <= 15
                ? NSColor.systemOrange.withAlphaComponent(0.45).cgColor
                : NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }

    // MARK: option-to-grab

    func show() {
        applyAlpha()
        orderFrontRegardless()
        startGrabWatch()
    }

    func hide() {
        stopGrabWatch()
        savePosition()
        orderOut(nil)
    }

    private func startGrabWatch() {
        grabTimer?.invalidate()
        grabTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollModifier()
        }
    }

    private func stopGrabWatch() {
        grabTimer?.invalidate()
        grabTimer = nil
        ignoresMouseEvents = true
        resizing = false
    }

    private func pollModifier() {
        let grab = NSEvent.modifierFlags.contains(.option)
        if ignoresMouseEvents == grab {
            ignoresMouseEvents = !grab
            if !grab {
                resizing = false
                resizeStart = nil
                savePosition()   // releasing option ends a drag
            }
        }
        guard grab, resizing, let start = resizeStart else { return }
        // Corner drag: width follows the mouse, the panel keeps its aspect so
        // every metric stays in proportion.
        let mouse = NSEvent.mouseLocation
        let grown = start.size.width + (mouse.x - start.mouse.x)
        setScale(grown / naturalSize.width)
    }

    /// Bottom-right corner starts a resize; anywhere else falls through to the
    /// window's own drag handling.
    override func mouseDown(with event: NSEvent) {
        let p = event.locationInWindow
        let grip = 22 * scale
        if p.x > frame.width - grip, p.y < grip {
            resizing = true
            resizeStart = (NSEvent.mouseLocation, frame.size)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        resizing = false
        resizeStart = nil
        savePosition()
        super.mouseUp(with: event)
    }
}
