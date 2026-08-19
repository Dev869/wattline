// The settings and about window.
//
// Everything here writes straight to UserDefaults and then tells the overlay
// to re-read, so there is no second copy of the state to drift out of sync.
// Built in code rather than a xib because the app is compiled with a plain
// swiftc invocation from the Makefile - no Xcode project, no nib loading.

import AppKit

final class SettingsWindow: NSWindowController {
    private let overlay: Overlay
    private let onChange: () -> Void
    private var fieldBoxes: [NSButton] = []

    init(overlay: Overlay, onChange: @escaping () -> Void) {
        self.overlay = overlay
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "\(Branding.name) Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(header("Overlay"))
        stack.addArrangedSubview(slider(
            "Size", value: Double(overlay.scale), min: 0.6, max: 2.5,
            format: { String(format: "%.0f%%", $0 * 100) },
            apply: { [weak self] v in self?.overlay.setScale(CGFloat(v)) }))
        stack.addArrangedSubview(slider(
            "Opacity", value: overlay.opacity, min: 0.2, max: 1.0,
            format: { String(format: "%.0f%%", $0 * 100) },
            apply: { [weak self] v in self?.overlay.setOpacity(v) }))

        stack.addArrangedSubview(toggle("Show workout graph", key: "overlayGraph", default: true))
        stack.addArrangedSubview(toggle("Beep before each interval", key: "overlayBeep", default: true))
        stack.addArrangedSubview(toggle("Dim when you stop pedalling", key: "overlayIdleDim", default: true))

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(header("Show these numbers"))
        let shown = Readout.savedFields()
        for field in Readout.optionalFields {
            let box = NSButton(checkboxWithTitle: label(for: field), target: self,
                               action: #selector(fieldToggled))
            box.identifier = NSUserInterfaceItemIdentifier(field)
            box.state = shown.contains(field) ? .on : .off
            fieldBoxes.append(box)
            stack.addArrangedSubview(box)
        }
        stack.addArrangedSubview(note("Power is always shown. Speed and distance hide "
                                      + "themselves during a workout, where they mean nothing."))

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(header("Controls"))
        stack.addArrangedSubview(note("Hold ⌥ to grab the overlay: drag it to move, "
                                      + "or drag its bottom-right corner to resize.\n"
                                      + "Without ⌥ held, clicks pass straight through to "
                                      + "whatever is underneath."))

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(note("\(Branding.name) \(Branding.version) — \(Branding.blurb)"))

        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: pieces

    private func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        return l
    }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 330
        return l
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return v
    }

    private func toggle(_ title: String, key: String, default def: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(prefToggled))
        box.identifier = NSUserInterfaceItemIdentifier(key)
        box.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? def) ? .on : .off
        return box
    }

    /// A labelled slider that shows its own value; live-applies as you drag so
    /// you can see the overlay change while you aim.
    private func slider(_ title: String, value: Double, min: Double, max: Double,
                        format: @escaping (Double) -> String,
                        apply: @escaping (Double) -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let name = NSTextField(labelWithString: title)
        name.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let readout = NSTextField(labelWithString: format(value))
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let control = Slider(minValue: min, maxValue: max) { v in
            readout.stringValue = format(v)
            apply(v)
        }
        control.doubleValue = value
        control.widthAnchor.constraint(equalToConstant: 200).isActive = true

        row.addArrangedSubview(name)
        row.addArrangedSubview(control)
        row.addArrangedSubview(readout)
        return row
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

    private func label(for field: String) -> String {
        switch field {
        case "cadence": return "Cadence"
        case "hr": return "Heart rate"
        case "speed": return "Speed"
        case "distance": return "Distance"
        case "elapsed": return "Elapsed time"
        case "grade": return "Gradient"
        default: return field
        }
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
