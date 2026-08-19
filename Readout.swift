// The numbers themselves. Split out of Overlay.swift, which now only has to
// care about being a window: where it sits, what it ignores, how big it is.
//
// The second row is deliberately context-aware. Speed and distance are real
// when you are riding Los Santos, and meaningless in ERG mode - the trainer
// varies resistance to hold watts no matter what gear you are in - so a
// workout swaps them for the numbers you can actually act on.

import AppKit

final class Readout: NSView {
    private let big = NSTextField(labelWithString: "--")
    private let unit = NSTextField(labelWithString: "W")
    private let corner = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let coming = NSTextField(labelWithString: "")
    private let countdown = NSTextField(labelWithString: "")
    private let dot = NSView()

    private var scalable: [(NSLayoutConstraint, CGFloat)] = []
    private var powerHistory: [Double] = []

    /// Which optional fields the settings window says to show. Power is not in
    /// here: a readout with no power is not a readout.
    static let optionalFields = ["cadence", "hr", "speed", "distance", "elapsed", "grade"]
    private var fields = Readout.savedFields()

    static func savedFields() -> Set<String> {
        guard let saved = UserDefaults.standard.array(forKey: "overlayFields") as? [String]
        else { return Set(optionalFields) }
        return Set(saved)
    }

    func reloadFields() { fields = Readout.savedFields() }

    /// Seconds of smoothing. Raw per-stroke power is too jumpy to read; 3s is
    /// what Zwift and every power meter default to.
    private let smoothingSeconds = 3.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        big.font = .systemFont(ofSize: 30, weight: .medium)
        big.textColor = .white
        unit.font = .systemFont(ofSize: 12, weight: .semibold)
        unit.textColor = NSColor.white.withAlphaComponent(0.85)
        corner.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        corner.textColor = .white
        corner.alignment = .right
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = NSColor.white.withAlphaComponent(0.92)
        coming.font = .systemFont(ofSize: 11, weight: .semibold)
        coming.textColor = .white
        countdown.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        countdown.textColor = .white
        countdown.alignment = .right

        // Every label sits over the graph, so each gets a drop shadow. Without
        // it a white number over a pale zone bar disappears.
        let shade = NSShadow()
        shade.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shade.shadowBlurRadius = 3
        shade.shadowOffset = NSSize(width: 0, height: -1)
        for label in [big, unit, corner, detail, coming, countdown] {
            label.shadow = shade
        }

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.isHidden = true

        for v in [big, unit, corner, detail, coming, countdown, dot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        scalable = [
            (big.leadingAnchor.constraint(equalTo: leadingAnchor), 16),
            (big.topAnchor.constraint(equalTo: topAnchor), 6),
            (unit.leadingAnchor.constraint(equalTo: big.trailingAnchor), 3),

            (corner.trailingAnchor.constraint(equalTo: trailingAnchor), -16),

            (detail.leadingAnchor.constraint(equalTo: leadingAnchor), 16),
            (detail.topAnchor.constraint(equalTo: big.bottomAnchor), 0),
            (detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor), -16),

            (coming.leadingAnchor.constraint(equalTo: leadingAnchor), 16),
            (coming.topAnchor.constraint(equalTo: detail.bottomAnchor), 5),
            (countdown.trailingAnchor.constraint(equalTo: trailingAnchor), -16),

            (dot.leadingAnchor.constraint(equalTo: leadingAnchor), 6),
            (dot.centerYAnchor.constraint(equalTo: big.centerYAnchor), 0),
            (dot.widthAnchor.constraint(equalToConstant: 6), 6),
            (dot.heightAnchor.constraint(equalToConstant: 6), 6),
        ]
        NSLayoutConstraint.activate(scalable.map(\.0) + [
            unit.firstBaselineAnchor.constraint(equalTo: big.firstBaselineAnchor),
            corner.firstBaselineAnchor.constraint(equalTo: big.firstBaselineAnchor),
            countdown.firstBaselineAnchor.constraint(equalTo: coming.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(scale: CGFloat) {
        big.font = .systemFont(ofSize: 30 * scale, weight: .medium)
        unit.font = .systemFont(ofSize: 12 * scale, weight: .semibold)
        corner.font = .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .regular)
        detail.font = .monospacedDigitSystemFont(ofSize: 11 * scale, weight: .regular)
        coming.font = .systemFont(ofSize: 11 * scale, weight: .semibold)
        countdown.font = .monospacedDigitSystemFont(ofSize: 15 * scale, weight: .bold)
        dot.layer?.cornerRadius = 3 * scale
        for (c, base) in scalable { c.constant = base * scale }
    }

    /// Rolling average of the last few seconds, so the big number is readable
    /// rather than twitching with every pedal stroke.
    private func smoothed(_ power: Int, every interval: Double) -> Int {
        powerHistory.append(Double(power))
        let keep = max(1, Int(smoothingSeconds / max(0.5, interval)))
        if powerHistory.count > keep { powerHistory.removeFirst(powerHistory.count - keep) }
        return Int(powerHistory.reduce(0, +) / Double(powerHistory.count))
    }

    /// Returns how many seconds until the next workout step, or nil.
    @discardableResult
    func update(_ s: [String: Any], interval: Double) -> Double? {
        let raw = s["power"] as? Int ?? 0
        let power = smoothed(raw, every: interval)
        let cadence = s["cadence"] as? Int ?? 0
        let hr = s["hr"] as? Int ?? 0
        let recording = s["recording"] as? Bool ?? false
        let workout = s["workout"] as? [String: Any]

        big.stringValue = power > 0 ? "\(power)" : "--"

        // In a workout the target belongs next to the number you are chasing.
        if let step = workout?["step"] as? [String: Any], let target = step["target"] as? Int {
            unit.stringValue = "W → \(target)"
        } else {
            unit.stringValue = "W"
        }

        var right: [String] = []
        if cadence > 0, fields.contains("cadence") { right.append("\(cadence) rpm") }
        if hr > 0, fields.contains("hr") { right.append("\(hr) bpm") }
        corner.stringValue = right.joined(separator: "   ")

        detail.stringValue = detailLine(s, workout: workout, recording: recording)
        dot.isHidden = !recording

        guard let workout, let toNext = workout["to_next"] as? Double else {
            coming.stringValue = ""
            countdown.stringValue = ""
            return nil
        }
        if let next = workout["next"] as? [String: Any] {
            let mins = (next["d"] as? Int ?? 0)
            coming.stringValue = "NEXT  \(duration(mins)) @ \(next["target"] as? Int ?? 0) W"
        } else {
            coming.stringValue = "LAST BLOCK"
        }
        // Only start counting out loud once it is close enough to matter.
        countdown.stringValue = toNext <= 15 ? "\(Int(toNext.rounded()))" : ""
        return toNext
    }

    private func detailLine(_ s: [String: Any], workout: [String: Any]?, recording: Bool) -> String {
        var parts: [String] = []
        if let workout, let step = workout["step"] as? [String: Any] {
            // ERG: speed and distance are noise, interval time is what you want.
            if let remaining = step["remaining"] as? Int { parts.append("\(duration(remaining)) left") }
            if let name = step["name"] as? String, !name.isEmpty { parts.append(name) }
            if let elapsed = workout["elapsed"] as? Double, let total = workout["total"] as? Double {
                parts.append("\(Int(elapsed / 60))/\(Int(total / 60)) min")
            }
        } else {
            if let speed = s["speed"] as? Double, speed > 0, fields.contains("speed") {
                parts.append(String(format: "%.1f km/h", speed))
            }
            if let grade = s["grade"] as? Double, fields.contains("grade") {
                parts.append(String(format: "%+.1f%%", grade))
            }
            if recording {
                if let distance = s["distance"] as? Int, distance > 0, fields.contains("distance") {
                    parts.append(String(format: "%.1f km", Double(distance) / 1000))
                }
                if let elapsed = s["elapsed"] as? Int, fields.contains("elapsed") {
                    parts.append("\(elapsed / 60) min")
                }
            }
            if parts.isEmpty {
                if let target = s["target_power"] as? Double { parts.append("target \(Int(target)) W") }
                // Only claim there is no sensor when nothing at all is coming
                // in. Saying "no sensor" beside a live 180 W is just wrong.
                else if s["power"] as? Int ?? 0 == 0 && s["cadence"] as? Int ?? 0 == 0
                            && s["hr"] as? Int ?? 0 == 0 {
                    parts.append(recording ? "waiting for data" : "no sensor")
                }
            }
        }
        return parts.prefix(3).joined(separator: "  ·  ")
    }

    private func duration(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds)s"
    }
}
