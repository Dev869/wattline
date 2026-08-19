// Wattline: a menu bar app you open like any other app.
//
// It owns the menu bar item, starts the Python daemon that does the real work
// (Bluetooth, ANT emulation, recording, Strava), and shuts it down on quit.
// The daemon publishes a plain-text status file; this reads it twice a second
// and rebuilds the menu from it.

import AppKit
import Foundation
import UniformTypeIdentifiers

let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("wattline")
let statusFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/wattline-status.txt")
let logFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/wattline.log")
let ridesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/Wattline Rides")
let api = "http://127.0.0.1:51235"

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var daemon: Process?
    var timer: Timer?
    // Lazy on purpose: building an NSPanel while the delegate is still being
    // constructed, before NSApplication has finished starting, leaves it in a
    // state where ordering it front does nothing.
    lazy var overlay = Overlay()
    var overlayVisible = UserDefaults.standard.bool(forKey: "overlayVisible")
    var settings: SettingsWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        // The login agent and a manual open can both fire; two menu bar icons
        // is worse than none, so the second copy bows out.
        let mine = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: mine)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let icon = NSImage(systemSymbolName: "bicycle", accessibilityDescription: "Wattline")
            icon?.isTemplate = true
            button.image = icon?.withSymbolConfiguration(
                .init(pointSize: 15, weight: .regular, scale: .medium))
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        item.menu = NSMenu()

        startDaemonIfNeeded()
        if overlayVisible { overlay.show() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.refresh() }
        refresh()
    }

    /// The daemon may already be up from the login agent; only start our own if not.
    func startDaemonIfNeeded() {
        if portInUse(51234) { return }
        let task = Process()
        task.executableURL = root.appendingPathComponent("venv/bin/python")
        task.arguments = [root.appendingPathComponent("ant_stick.py").path]
        task.currentDirectoryURL = root
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            task.standardOutput = handle
            task.standardError = handle
        }
        try? task.run()
        daemon = task
    }

    func portInUse(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func call(_ path: String) {
        guard let url = URL(string: api + path) else { return }
        URLSession.shared.dataTask(with: url) { _, _, _ in
            DispatchQueue.main.async { self.refresh() }
        }.resume()
    }

    func refresh() {
        let text = (try? String(contentsOf: statusFile, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // First line is the menu bar title; a "---" separates it from the body.
        if !lines.isEmpty { lines.removeFirst() }

        let live = status()
        overlay.update(live)
        let power = live["power"] as? Int ?? 0
        let recording = live["recording"] as? Bool ?? false
        item.button?.title = power > 0 ? " \(power)W" : ""
        item.button?.contentTintColor = recording ? .systemRed : nil

        let menu = NSMenu()
        for line in lines where !line.isEmpty {
            if line == "---" { menu.addItem(.separator()); continue }
            let entry = NSMenuItem(title: strip(line), action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        if recording {
            menu.addItem(action("Stop ride and upload to Strava", #selector(stopRide)))
        } else {
            menu.addItem(action("Start ride", #selector(startRide)))
        }

        let powerMenu = NSMenu()
        for watts in [100, 120, 140, 160, 180, 200, 220, 250, 280, 300] {
            let entry = NSMenuItem(title: "\(watts) W", action: #selector(setPower(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = watts
            powerMenu.addItem(entry)
        }
        powerMenu.addItem(.separator())
        powerMenu.addItem(action("Release", #selector(releasePower)))
        let powerItem = NSMenuItem(title: "Hold a power target", action: nil, keyEquivalent: "")
        menu.addItem(powerItem)
        menu.setSubmenu(powerMenu, for: powerItem)

        menu.addItem(.separator())
        let strava = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wattline/strava.json")
        if !FileManager.default.fileExists(atPath: strava.path) {
            menu.addItem(action("Connect Strava…", #selector(connectStrava)))
        }
        // Workout controls only appear when there is a workout to control.
        if let plan = live["workout"] as? [String: Any] {
            let running = (plan["state"] as? String) == "running"
            menu.addItem(action(running ? "Pause workout" : "Resume workout",
                                running ? #selector(pauseWorkout) : #selector(resumeWorkout)))
            menu.addItem(action("Skip this block", #selector(skipBlock)))
            menu.addItem(action("Stop workout", #selector(stopWorkout)))
        } else {
            menu.addItem(action("Load workout…", #selector(loadWorkout)))
        }
        menu.addItem(.separator())

        menu.addItem(action(overlayVisible ? "Hide overlay" : "Show overlay", #selector(toggleOverlay)))
        menu.addItem(submenu("Overlay size", [75, 100, 125, 150, 200], Int(overlay.scale * 100),
                              #selector(setOverlayScale(_:))))
        menu.addItem(submenu("Overlay opacity", [40, 60, 80, 100], Int(overlay.opacity * 100),
                              #selector(setOverlayOpacity(_:))))
        let graphItem = action("Show workout graph", #selector(toggleGraph))
        graphItem.state = overlay.showGraph ? .on : .off
        menu.addItem(graphItem)
        menu.addItem(action("Set FTP…", #selector(setFTP)))
        menu.addItem(action("Settings…", #selector(openSettings)))
        menu.addItem(action("Check my sensors…", #selector(checkSensors)))
        menu.addItem(action("Past rides", #selector(openRides)))
        menu.addItem(action("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit)))
        item.menu = menu
    }

    func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    /// A "pick one" submenu of percentages, e.g. overlay size or opacity.
    func submenu(_ title: String, _ percents: [Int], _ current: Int, _ selector: Selector) -> NSMenuItem {
        let sub = NSMenu()
        for pct in percents {
            let entry = NSMenuItem(title: "\(pct)%", action: selector, keyEquivalent: "")
            entry.target = self
            entry.tag = pct
            entry.state = pct == current ? .on : .off
            sub.addItem(entry)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// Status lines carry SwiftBar-style "| color=red" attributes; drop them.
    func strip(_ line: String) -> String {
        String(line.split(separator: "|").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The daemon's numbers, for the overlay and the menu bar title.
    func status() -> [String: Any] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/wattline-status.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    @objc func toggleOverlay() {
        overlayVisible.toggle()
        UserDefaults.standard.set(overlayVisible, forKey: "overlayVisible")
        overlayVisible ? overlay.show() : overlay.hide()
        refresh()
    }

    @objc func openSettings() {
        if settings == nil {
            settings = SettingsWindow(overlay: overlay) { [weak self] in self?.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleGraph() {
        overlay.setGraph(!overlay.showGraph)
        refresh()
    }

    /// A file picker needs the app foregrounded for a moment. This is the one
    /// place that is acceptable - the overlay itself must never activate.
    @objc func loadWorkout() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Zwift workout"
        panel.allowedContentTypes = [UTType(filenameExtension: "zwo")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoded = url.path.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? ""
        call("/workout/load?path=\(encoded)")
    }

    @objc func pauseWorkout() { call("/workout/pause") }
    @objc func resumeWorkout() { call("/workout/resume") }
    @objc func skipBlock() { call("/workout/skip") }
    @objc func stopWorkout() { call("/workout/stop") }

    /// Workout files hold power as a fraction of FTP, so the daemon cannot
    /// turn a plan into watts without this number.
    @objc func setFTP() {
        let alert = NSAlert()
        alert.messageText = "Functional Threshold Power"
        alert.informativeText = "Workout files store power as a percentage of FTP."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.stringValue = "250"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let watts = Int(field.stringValue), watts > 50, watts < 600 else { return }
        call("/ftp/\(watts)")
    }

    @objc func setOverlayScale(_ sender: NSMenuItem) {
        overlay.setScale(CGFloat(sender.tag) / 100)
        refresh()
    }

    @objc func setOverlayOpacity(_ sender: NSMenuItem) {
        overlay.setOpacity(Double(sender.tag) / 100)
        refresh()
    }

    @objc func startRide() { call("/ride/start") }
    @objc func stopRide() { call("/ride/stop") }
    @objc func releasePower() { call("/power/off") }
    @objc func setPower(_ sender: NSMenuItem) { call("/power/\(sender.tag)") }
    @objc func openRides() { NSWorkspace.shared.open(ridesDir) }
    @objc func openLog() { NSWorkspace.shared.open(logFile) }

    /// Anything interactive gets a Terminal window, since it asks questions.
    func runInTerminal(_ command: String) {
        let script = "tell application \"Terminal\" to do script \"\(command)\"\n"
            + "tell application \"Terminal\" to activate"
        if let apple = NSAppleScript(source: script) { apple.executeAndReturnError(nil) }
    }

    @objc func connectStrava() {
        runInTerminal("cd '\(root.path)' && venv/bin/python strava.py setup")
    }

    @objc func checkSensors() {
        runInTerminal("cd '\(root.path)' && venv/bin/python bike_ble.py")
    }

    @objc func quit() {
        daemon?.terminate()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ note: Notification) {
        overlay.savePosition()
        daemon?.terminate()
    }
}

