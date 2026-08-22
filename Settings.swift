// The settings window.
//
// Everything here writes straight to UserDefaults or the daemon's config and
// then tells the overlay to re-read, so there is no second copy of the state
// to drift out of sync. Built in code rather than a xib because the app is
// compiled with a plain swiftc invocation from the Makefile - no Xcode
// project, no nib loading.
//
// Two columns of grouped boxes rather than one long scroll: the settings fall
// into small clusters that fit side by side, and a roughly square window is
// easier to take in at a glance than a 500pt ribbon.

import AppKit

final class SettingsWindow: NSWindowController {
    private let overlay: Overlay
    private let onChange: () -> Void
    private weak var app: AppDelegate?

    private var fieldBoxes: [NSButton] = []
    private let ftpField = NSTextField(string: "")
    private let sensorLine = NSTextField(wrappingLabelWithString: "")
    private let sensorList = NSStackView()
    private let stravaLine = NSTextField(labelWithString: "")
    private let stravaButton = NSButton(title: "", target: nil, action: nil)
    private var poll: Timer?

    /// Which sensor supplies each number, as the daemon last reported it. A
    /// metric missing from this is taken from whatever offers it.
    private var sources: [String: String] = [:]
    /// Picks made here that the daemon has not written back yet. Without this
    /// the icon springs back to its old state for the second between clicking
    /// it and the daemon rewriting its status file.
    private var pending: [String: String] = [:]

    private static let columnWidth: CGFloat = 300

    /// The numbers a sensor can supply, in the order they are shown, with the
    /// symbol and the word for each.
    private static let metrics = [
        (key: "power", symbol: "bolt.fill", word: "power"),
        (key: "cadence", symbol: "arrow.triangle.2.circlepath", word: "cadence"),
        (key: "speed", symbol: "speedometer", word: "speed"),
        (key: "hr", symbol: "heart.fill", word: "heart rate"),
    ]

    init(overlay: Overlay, app: AppDelegate?, onChange: @escaping () -> Void) {
        self.overlay = overlay
        self.app = app
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "\(Branding.name) Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let columns = NSStackView(views: [column(left()), column(right())])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 20

        let root = NSStackView(views: [columns, footer()])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        window.contentView = root
        root.layoutSubtreeIfNeeded()
        window.setContentSize(root.fittingSize)
        window.center()

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: the two columns

    private func left() -> [NSView] {
        [
            box("Overlay", [
                checkbox("Show the overlay", on: app?.overlayVisible ?? false,
                         action: #selector(overlayVisibilityToggled)),
                slider("Size", value: Double(overlay.scale), min: 0.6, max: 2.5,
                       format: { String(format: "%.0f%%", $0 * 100) },
                       apply: { [weak self] v in self?.overlay.setScale(CGFloat(v)) }),
                slider("Opacity", value: overlay.opacity, min: 0.2, max: 1.0,
                       format: { String(format: "%.0f%%", $0 * 100) },
                       apply: { [weak self] v in self?.overlay.setOpacity(v) }),
                toggle("Show the workout graph", key: "overlayGraph", default: true),
                toggle("Dim when you stop pedalling", key: "overlayIdleDim", default: true),
                note("Hold ⌥ to grab the overlay: drag to move, or drag its "
                     + "bottom-right corner to resize. Without ⌥ held, clicks pass "
                     + "straight through to whatever is underneath."),
            ]),
            box("Show these numbers", [
                fieldGrid(),
                note("Power is always shown. Speed and distance hide themselves "
                     + "during a workout, where they mean nothing."),
            ]),
        ]
    }

    private func right() -> [NSView] {
        ftpField.alignment = .right
        ftpField.placeholderString = "250"
        ftpField.target = self
        ftpField.action = #selector(ftpEdited)
        ftpField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let ftpRow = NSStackView(views: [
            NSTextField(labelWithString: "FTP"), ftpField,
            NSTextField(labelWithString: "watts"),
        ])
        ftpRow.orientation = .horizontal
        ftpRow.spacing = 8

        sensorList.orientation = .vertical
        sensorList.alignment = .leading
        sensorList.spacing = 6
        sensorLine.font = .systemFont(ofSize: 11)
        sensorLine.textColor = .secondaryLabelColor
        sensorLine.preferredMaxLayoutWidth = Self.columnWidth - 28
        stravaLine.font = .systemFont(ofSize: 11)
        stravaLine.textColor = .secondaryLabelColor
        stravaButton.target = self
        stravaButton.bezelStyle = .rounded

        return [
            box("Rider", [
                ftpRow,
                note("Workout files store power as a percentage of FTP, so the "
                     + "same file is a different ride for every rider."),
            ]),
            box("Workouts", [
                toggle("Beep before each interval", key: "overlayBeep", default: true),
                note("Three beeps, one per second, and the overlay edge holds amber "
                     + "for the last three seconds. The colour stays even with the "
                     + "beep off, because then it is the only warning left."),
            ]),
            box("Sensors", [
                sensorList,
                sensorLine,
            ]),
            box("Rides", [
                stravaLine,
                row([stravaButton, button("Past rides", #selector(openRides))]),
            ]),
        ]
    }

    private func footer() -> NSView {
        let about = NSTextField(labelWithString:
            "\(Branding.name) \(Branding.version) — \(Branding.blurb)")
        about.font = .systemFont(ofSize: 11)
        about.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [about, spacer, button("Open log", #selector(openLog))])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 10
        bar.widthAnchor.constraint(equalToConstant: Self.columnWidth * 2 + 20).isActive = true
        return bar
    }

    // MARK: live values

    /// Sensor and Strava state come from the daemon, so they can change while
    /// the window is open. Poll only while it is actually on screen.
    private func refresh() {
        let live = liveStatus()
        let nearby = live["nearby"] as? [[String: Any]] ?? []
        let connected = live["sensors"] as? [String] ?? []

        var picked = live["sources"] as? [String: String] ?? [:]
        for (metric, want) in pending {
            if (picked[metric] ?? "any") == want {
                pending[metric] = nil          // the daemon agrees; stop overriding
            } else {
                picked[metric] = want == "any" ? nil : want
            }
        }
        sources = picked

        sensorList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for device in nearby { sensorList.addArrangedSubview(sensorRow(device)) }
        sensorList.isHidden = nearby.isEmpty

        if nearby.isEmpty {
            sensorLine.stringValue = "Nothing advertising yet. Sensors sleep when the bike "
                + "is still — turn the trainer on and spin the cranks."
        } else if connected.isEmpty {
            sensorLine.stringValue = "Nothing to pair: \(Branding.name) connects to every "
                + "cycling sensor it hears."
        } else if live["erg"] as? Bool ?? false {
            sensorLine.stringValue = "Reading live, and it takes power targets — a workout "
                + "will set the resistance for you. Click an icon to choose which sensor a "
                + "number comes from."
        } else {
            sensorLine.stringValue = "Reading live. This one does not take power targets, "
                + "so a workout's numbers are yours to chase. Click an icon to choose which "
                + "sensor a number comes from."
        }

        if stravaConfigured() {
            stravaLine.stringValue = "Strava connected — rides upload when you stop."
            stravaButton.title = "Reconnect Strava…"
        } else {
            stravaLine.stringValue = "Strava not connected — rides are saved locally only."
            stravaButton.title = "Connect Strava…"
        }
        stravaButton.action = #selector(connectStrava)

        // Someone may have used the menu's Set FTP… since this opened.
        if ftpField.currentEditor() == nil {
            ftpField.stringValue = String(currentFTP())
        }

        resizeToFit()
    }

    /// One device the scan can hear, connected or not: what it is, what we are
    /// taking from it, and a row of icons to change that.
    private func sensorRow(_ device: [String: Any]) -> NSView {
        let gives = (device["gives"] as? [String] ?? []).joined(separator: ", ")
        let address = device["address"] as? String ?? ""
        let can = device["can"] as? [String] ?? []
        let taking = Self.metrics.filter { can.contains($0.key) && supplies(address, $0.key) }

        let symbol: String, tint: NSColor, detail: String
        switch device["state"] as? String {
        case "connected":
            symbol = "checkmark.circle.fill"
            tint = .systemGreen
            detail = taking.isEmpty
                ? (gives.isEmpty ? "connected" : "connected — nothing taken from it")
                : "taking " + taking.map(\.word).joined(separator: ", ")
        case "ignored":
            symbol = "minus.circle"
            tint = .tertiaryLabelColor
            detail = "nothing here we can read"
        default:
            symbol = "antenna.radiowaves.left.and.right"
            tint = .secondaryLabelColor
            detail = gives.isEmpty ? "connecting…" : "\(gives) — connecting…"
        }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let name = NSTextField(labelWithString: device["name"] as? String ?? "unnamed")
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.columnWidth - 28).isActive = true

        guard !can.isEmpty, device["state"] as? String != "ignored" else { return row }

        let picks = NSStackView(views: Self.metrics.filter { can.contains($0.key) }
            .map { metricButton($0, address: address) })
        picks.orientation = .horizontal
        picks.spacing = 10
        picks.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)

        let stack = NSStackView(views: [row, picks])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    /// Is this device the one that number comes from? A number nobody has
    /// claimed is read from whatever offers it, so every sensor that has it
    /// shows as supplying it - which is the truth.
    private func supplies(_ address: String, _ metric: String) -> Bool {
        sources[metric] == nil || sources[metric] == address
    }

    /// One number this sensor could supply: lit when it does, grey when
    /// something else was picked for it.
    private func metricButton(_ metric: (key: String, symbol: String, word: String),
                              address: String) -> NSButton {
        let on = supplies(address, metric.key)
        let image = NSImage(systemSymbolName: metric.symbol, accessibilityDescription: metric.word)
        let button = NSButton(image: image ?? NSImage(), target: self,
                              action: #selector(sourceToggled))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
        button.identifier = NSUserInterfaceItemIdentifier("\(metric.key)|\(address)")
        button.toolTip = on
            ? "Taking \(metric.word) from this sensor — click to take it from any sensor"
            : "Take \(metric.word) from this sensor instead"
        return button
    }

    /// The sensor list grows and shrinks as things come and go, so the window
    /// has to follow it. Grow downwards - a settings window that walks up the
    /// screen every time a sensor wakes up is worse than one that is too tall.
    private func resizeToFit() {
        guard let window, let root = window.contentView else { return }
        let size = root.fittingSize
        guard abs(size.height - root.frame.height) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.refresh()
        }
    }

    private func liveStatus() -> [String: Any] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/wattline-status.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    // MARK: pieces

    /// A titled group: a small heading over a rounded card, the way System
    /// Settings groups things. Hand-rolled rather than NSBox, which refuses to
    /// take its height from the stack view inside it and collapses to a line.
    private func box(_ title: String, _ contents: [NSView]) -> NSView {
        let inner = NSStackView(views: contents)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false

        let card = Card()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            card.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let group = NSStackView(views: [heading, card])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        return group
    }

    /// One column of groups. The trailing filler matters: the two columns are
    /// never the same height, and without something willing to absorb the
    /// difference the stack stretches the last group instead, leaving a card
    /// with a lake of empty space in it.
    private func column(_ boxes: [NSView]) -> NSStackView {
        let filler = NSView()
        filler.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        let stack = NSStackView(views: boxes + [filler])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 14
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    /// The six optional numbers, two to a line: six stacked checkboxes made the
    /// column twice as tall as anything next to it.
    private func fieldGrid() -> NSView {
        let shown = Readout.savedFields()
        var rows: [NSView] = []
        var pair: [NSView] = []
        for field in Readout.optionalFields {
            let checkbox = NSButton(checkboxWithTitle: label(for: field), target: self,
                                    action: #selector(fieldToggled))
            checkbox.identifier = NSUserInterfaceItemIdentifier(field)
            checkbox.state = shown.contains(field) ? .on : .off
            checkbox.widthAnchor.constraint(equalToConstant: 130).isActive = true
            fieldBoxes.append(checkbox)
            pair.append(checkbox)
            if pair.count == 2 { rows.append(row(pair)); pair = [] }
        }
        if !pair.isEmpty { rows.append(row(pair)) }

        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        return grid
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.columnWidth - 28
        return label
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: selector)
        control.bezelStyle = .rounded
        return control
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.state = on ? .on : .off
        return box
    }

    private func toggle(_ title: String, key: String, default def: Bool) -> NSButton {
        let box = checkbox(title, on: UserDefaults.standard.object(forKey: key) as? Bool ?? def,
                           action: #selector(prefToggled))
        box.identifier = NSUserInterfaceItemIdentifier(key)
        return box
    }

    /// A labelled slider that shows its own value; live-applies as you drag so
    /// you can see the overlay change while you aim.
    private func slider(_ title: String, value: Double, min: Double, max: Double,
                        format: @escaping (Double) -> String,
                        apply: @escaping (Double) -> Void) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let readout = NSTextField(labelWithString: format(value))
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let control = Slider(minValue: min, maxValue: max) { v in
            readout.stringValue = format(v)
            apply(v)
        }
        control.doubleValue = value
        control.widthAnchor.constraint(equalToConstant: 160).isActive = true

        return row([name, control, readout])
    }

    // MARK: actions

    @objc private func prefToggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
        overlay.reloadPreferences()
        onChange()
    }

    @objc private func fieldToggled(_ sender: NSButton) {
        let on = fieldBoxes.filter { $0.state == .on }
            .compactMap { $0.identifier?.rawValue }
        UserDefaults.standard.set(on, forKey: "overlayFields")
        overlay.reloadPreferences()
        onChange()
    }

    /// Clicking the sensor a number already comes from hands it back to
    /// whatever offers it; clicking any other pins the number to that one.
    @objc private func sourceToggled(_ sender: NSButton) {
        let bits = (sender.identifier?.rawValue ?? "").split(separator: "|", maxSplits: 1)
        guard bits.count == 2 else { return }
        let metric = String(bits[0]), address = String(bits[1])
        let want = sources[metric] == address ? "any" : address
        pending[metric] = want
        sources[metric] = want == "any" ? nil : want
        let escaped = want.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? want
        app?.call("/source/\(metric)/\(escaped)")
        refresh()
    }

    @objc private func overlayVisibilityToggled(_ sender: NSButton) {
        app?.setOverlay(visible: sender.state == .on)
    }

    @objc private func ftpEdited() {
        guard let watts = Int(ftpField.stringValue), watts >= 50, watts <= 600 else {
            ftpField.stringValue = String(currentFTP())
            return
        }
        app?.call("/ftp/\(watts)")
    }

    @objc private func connectStrava() { app?.connectStrava() }
    @objc private func openRides() { app?.openRides() }
    @objc private func openLog() { app?.openLog() }

    private func label(for field: String) -> String {
        switch field {
        case "cadence": return "Cadence"
        case "hr": return "Heart rate"
        case "speed": return "Speed"
        case "distance": return "Distance"
        case "elapsed": return "Elapsed time"
        default: return field
        }
    }
}

/// The daemon owns FTP - it lives in the same config file the workout parser
/// reads - so both the menu and the settings window ask this rather than
/// keeping a second copy in UserDefaults.
func currentFTP() -> Int {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/wattline/config.json")
    guard let data = try? Data(contentsOf: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ftp = json["ftp"] as? NSNumber
    else { return 200 }
    return ftp.intValue
}

func stravaConfigured() -> Bool {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/wattline/strava.json")
    return FileManager.default.fileExists(atPath: path.path)
}

/// The rounded well behind each group. A layer-backed view rather than a
/// colour baked in once, so it follows the system between light and dark.
private final class Card: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
    }
}

/// NSSlider needs a target; this keeps the closure alive with the control
/// rather than scattering retained handlers around the window controller.
private final class Slider: NSSlider {
    private let onSlide: (Double) -> Void

    init(minValue: Double, maxValue: Double, onSlide: @escaping (Double) -> Void) {
        self.onSlide = onSlide
        super.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        self.isContinuous = true
        target = self
        action = #selector(slid)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func slid() { onSlide(doubleValue) }
}
