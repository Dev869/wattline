// Test instruments for the overlay. Four jobs, one binary, because they are
// only ever used together by test_overlay.sh.
//
//   probe <pid>            what the window server actually renders, as JSON
//   click <x> <y> [opt]    a real HID click, optionally with option held
//   catch <x> <y> <w> <h>  a window that reports clicks that reach it
//   ink <file.png>         fraction of bright pixels, to prove content scaled
//
// Two things this exists to work around:
//   - System Events' `click at` does not post a real HID click, so it cannot
//     tell "passed through" from "nothing happened".
//   - NSWindow.frame is not observable from outside the app, and asserting
//     against our own UserDefaults would pass even if nothing moved.

import AppKit
import CoreGraphics

let args = CommandLine.arguments

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

// MARK: probe

func probe(_ pid: Int) {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [[String: Any]] = []
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? Int) == pid,
              let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        out.append([
            "id": w[kCGWindowNumber as String] as? Int ?? 0,
            "width": b["Width"] as? Double ?? 0,
            "height": b["Height"] as? Double ?? 0,
            "x": b["X"] as? Double ?? 0,
            "y": b["Y"] as? Double ?? 0,
            "alpha": w[kCGWindowAlpha as String] as? Double ?? -1,
            "layer": w[kCGWindowLayer as String] as? Int ?? -1,
            "onscreen": w[kCGWindowIsOnscreen as String] as? Bool ?? false,
        ])
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

// MARK: click

func click(_ p: CGPoint, option: Bool) {
    // The overlay polls NSEvent.modifierFlags, which reads global state rather
    // than the flags carried on our click, so option has to be asserted for
    // real and held longer than the overlay's poll interval.
    if option {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x3A, keyDown: true)
        down?.flags = .maskAlternate
        down?.post(tap: .cghidEventTap)
        usleep(400_000)
    }
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: p, mouseButton: .left)
        if option { e?.flags = .maskAlternate }
        e?.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    if option {
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x3A, keyDown: false)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: catch

final class Catcher: NSView {
    override func mouseDown(with e: NSEvent) {
        print("HIT \(Int(e.locationInWindow.x)),\(Int(e.locationInWindow.y))")
        fflush(stdout)
    }
}

func catchClicks(x: Double, y: Double, w: Double, h: Double) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let screenH = NSScreen.main!.frame.height
    let win = NSWindow(contentRect: NSRect(x: x, y: screenH - y - h, width: w, height: h),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = .floating       // above ordinary windows, below the overlay's .statusBar
    win.backgroundColor = .systemGreen
    win.alphaValue = 0.85
    win.contentView = Catcher()
    win.orderFrontRegardless()
    print("READY")
    fflush(stdout)
    Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in app.terminate(nil) }
    app.run()
    exit(0)
}

// MARK: ink

/// Fraction of pixels that differ from the panel's own flat background. A
/// panel that grows while its readout does not keeps roughly constant content
/// area, so this ratio collapses; real scaling holds it steady.
///
/// Measured against the median rather than an absolute brightness threshold on
/// purpose: the blur is translucent, so a light desktop behind it made a
/// fixed "count near-white pixels" test call 99% of the panel ink and stop
/// discriminating anything.
/// `crop` is x,y,w,h in desktop coordinates; the image is scaled to match, so
/// a full-display grab can be measured against a window rect from `probe`.
/// Needed because -R region capture is broken on some multi-display setups.
func ink(_ path: String, crop: (Double, Double, Double, Double)? = nil,
         desktop: (Double, Double)? = nil) {
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { die("cannot read \(path)") }

    var x0 = 0, y0 = 0, x1 = bitmap.pixelsWide, y1 = bitmap.pixelsHigh
    if let crop, let desktop, desktop.0 > 0, desktop.1 > 0 {
        let sx = Double(bitmap.pixelsWide) / desktop.0
        let sy = Double(bitmap.pixelsHigh) / desktop.1
        x0 = max(0, Int(crop.0 * sx)); y0 = max(0, Int(crop.1 * sy))
        x1 = min(bitmap.pixelsWide, Int((crop.0 + crop.2) * sx))
        y1 = min(bitmap.pixelsHigh, Int((crop.1 + crop.3) * sy))
        if x1 <= x0 || y1 <= y0 { print("0.0000"); return }
    }

    var values: [Double] = []
    values.reserveCapacity((x1 - x0) * (y1 - y0))
    for y in y0..<y1 {
        for x in x0..<x1 {
            guard let c = bitmap.colorAt(x: x, y: y) else { continue }
            values.append(Double(c.brightnessComponent))
        }
    }
    guard !values.isEmpty else { print("0.0000"); return }
    let median = values.sorted()[values.count / 2]
    let content = values.filter { abs($0 - median) > 0.15 }.count
    print(String(format: "%.4f", Double(content) / Double(values.count)))
}

// MARK: dispatch

guard args.count > 1 else { die("usage: overlay_test probe|click|catch|ink ...") }
switch args[1] {
case "probe":
    guard args.count > 2, let pid = Int(args[2]) else { die("usage: probe <pid>") }
    probe(pid)
case "click":
    guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else {
        die("usage: click <x> <y> [opt]")
    }
    click(CGPoint(x: x, y: y), option: args.count > 4 && args[4] == "opt")
case "catch":
    guard args.count > 5, let x = Double(args[2]), let y = Double(args[3]),
          let w = Double(args[4]), let h = Double(args[5]) else {
        die("usage: catch <x> <y> <w> <h>")
    }
    catchClicks(x: x, y: y, w: w, h: h)
case "ink":
    guard args.count > 2 else { die("usage: ink <file.png> [x y w h deskW deskH]") }
    if args.count >= 9, let x = Double(args[3]), let y = Double(args[4]),
       let w = Double(args[5]), let h = Double(args[6]),
       let dw = Double(args[7]), let dh = Double(args[8]) {
        ink(args[2], crop: (x, y, w, h), desktop: (dw, dh))
    } else {
        ink(args[2])
    }
case "screens":
    // Union of the displays in CGWindowList's coordinate space. On a scaled
    // external display that space is not AppKit points - a 360pt window can
    // report as 324 - so anything comparing window rects to screen bounds has
    // to ask for both in the same units.
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: max(1, Int(count)))
    CGGetActiveDisplayList(count, &ids, &count)
    var union = CGRect.null
    for id in ids.prefix(Int(count)) { union = union.union(CGDisplayBounds(id)) }
    // .null has infinite origin, and Int(infinity) traps rather than erroring.
    if union.isNull || union.isInfinite { union = CGDisplayBounds(CGMainDisplayID()) }
    print("\(Int(union.minX)) \(Int(union.minY)) \(Int(union.width)) \(Int(union.height))")
default:
    die("unknown command \(args[1])")
}
