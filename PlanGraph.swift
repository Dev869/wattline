// The workout profile, as a strip that scrolls under a fixed "now" line.
//
// A whole 60-minute session squeezed into 300 points makes a 30-second
// interval about two pixels wide, so this shows a window instead: the last
// minute behind you and the next two ahead. Bars are the plan, the line is
// what you actually did.
//
// Zone colours are decided by the daemon (plan.py owns the boundaries) so the
// two halves can never disagree about where threshold starts.

import AppKit

final class PlanGraph: NSView {
    private var steps: [[String: Any]] = []
    private var elapsed: Double = 0
    private var ftpTop: Double = 300      // watts at full height
    private var trace: [(Double, Double)] = []   // (elapsed, watts)

    private let behind: Double = 60
    private let ahead: Double = 120

    // Grey through blue, green, yellow, orange, red, dark red. No app
    // publishes official hex codes, so this is the agreed cool-to-warm ramp
    // rather than a claim to match anyone exactly.
    private static let zoneColors: [NSColor] = [
        NSColor(calibratedRed: 0.55, green: 0.57, blue: 0.60, alpha: 1),
        NSColor(calibratedRed: 0.28, green: 0.55, blue: 0.85, alpha: 1),
        NSColor(calibratedRed: 0.30, green: 0.70, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.90, green: 0.76, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.55, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.85, green: 0.28, blue: 0.25, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.16, blue: 0.20, alpha: 1),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(workout: [String: Any]?, power: Int) {
        guard let workout, let steps = workout["steps"] as? [[String: Any]] else {
            self.steps = []
            trace.removeAll()
            needsDisplay = true
            return
        }
        self.steps = steps
        elapsed = workout["elapsed"] as? Double ?? 0
        let peak = steps.compactMap { max($0["p0"] as? Double ?? 0, $0["p1"] as? Double ?? 0) }.max() ?? 300
        ftpTop = max(150, peak * 1.15)

        trace.append((elapsed, Double(power)))
        trace.removeAll { $0.0 < elapsed - behind }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        guard !steps.isEmpty, bounds.width > 8 else { return }
        let span = behind + ahead
        let pxPerSecond = bounds.width / span
        // The window is fixed to the panel; time slides underneath it.
        let originTime = elapsed - behind

        func x(_ t: Double) -> CGFloat { CGFloat(t - originTime) * pxPerSecond }
        func y(_ watts: Double) -> CGFloat {
            bounds.height * CGFloat(min(1, watts / ftpTop)) * 0.55
        }

        for step in steps {
            let start = step["t"] as? Double ?? 0
            let dur = step["d"] as? Double ?? 0
            guard start + dur > originTime, start < originTime + span else { continue }
            let p0 = step["p0"] as? Double ?? 0
            let p1 = step["p1"] as? Double ?? p0
            let zone = min(7, max(1, step["zone"] as? Int ?? 1))
            let colour = Self.zoneColors[zone - 1]

            // Done is solid, still to come is muted, so "where am I" reads
            // without needing to find the cursor first.
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: x(start), y: 0))
            bar.line(to: NSPoint(x: x(start), y: y(p0)))
            bar.line(to: NSPoint(x: x(start + dur), y: y(p1)))
            bar.line(to: NSPoint(x: x(start + dur), y: 0))
            bar.close()
            colour.withAlphaComponent(start + dur <= elapsed ? 0.42 : 0.20).setFill()
            bar.fill()
        }

        if trace.count > 1 {
            let line = NSBezierPath()
            line.lineWidth = max(1, bounds.height / 34)
            line.move(to: NSPoint(x: x(trace[0].0), y: y(trace[0].1)))
            for point in trace.dropFirst() {
                line.line(to: NSPoint(x: x(point.0), y: y(point.1)))
            }
            NSColor.white.withAlphaComponent(0.35).setStroke()
            line.stroke()
        }

        let now = NSBezierPath()
        now.lineWidth = max(1, bounds.height / 40)
        now.move(to: NSPoint(x: x(elapsed), y: 0))
        now.line(to: NSPoint(x: x(elapsed), y: bounds.height))
        NSColor.white.withAlphaComponent(0.30).setStroke()
        now.stroke()
    }
}
