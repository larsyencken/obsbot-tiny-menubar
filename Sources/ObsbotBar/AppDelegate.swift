import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let camera = Camera()
    // All USB work happens here, one operation at a time.
    private let queue = DispatchQueue(label: "obsbot.usb")

    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "Checking camera…", action: nil, keyEquivalent: "")
    private let wakeItem = NSMenuItem(title: "Wake", action: #selector(wake), keyEquivalent: "")
    private let sleepItem = NSMenuItem(title: "Sleep", action: #selector(sleepCamera), keyEquivalent: "")
    private let trackItem = NSMenuItem(title: "Normal Tracking", action: #selector(toggleTracking), keyEquivalent: "")

    private var lastStatus: CameraStatus?
    private var lastError: String?
    private var pending = 0  // operations queued or running

    // Tracking is on by default: it's turned on at launch, whenever the camera
    // connects, and whenever it wakes up (whoever woke it). If the attempt fails,
    // each poll retries until it succeeds. Between those events the app leaves the
    // mode alone, so changing it here or in OBSBOT Center sticks.
    private var trackingDue = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        for item in [wakeItem, sleepItem, trackItem] { item.target = self }
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(wakeItem)
        menu.addItem(sleepItem)
        menu.addItem(.separator())
        menu.addItem(trackItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // The camera may have been power-cycled while the Mac slept.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.trackingDue = true
            self?.poll()
        }

        render()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func menuWillOpen(_ menu: NSMenu) { poll() }

    private func poll() {
        // Don't pile up polls behind a slow operation.
        guard pending == 0 else { return }
        run { [self] cam, before in
            let s = try cam.status()
            let woke = s.awake && (before == nil || before?.awake == false)
            if woke { DispatchQueue.main.sync { trackingDue = true } }
            guard s.awake, DispatchQueue.main.sync(execute: { trackingDue }) else { return }
            // Always send the command, even if the status already reads "normal":
            // just after a wake it can still show the pre-sleep mode.
            try cam.enableTracking()
            DispatchQueue.main.sync { trackingDue = false }
        }
    }

    @objc private func wake() {
        run { [self] cam, _ in
            try cam.wakeAndTrack()
            DispatchQueue.main.sync { trackingDue = false }
        }
    }

    @objc private func sleepCamera() { run { cam, _ in try cam.sleepAndWait() } }

    @objc private func toggleTracking() {
        let on = lastStatus?.aiMode != .normal
        trackingDue = false
        run { cam, _ in
            if on { try cam.enableTracking() } else { try cam.disableTracking() }
        }
    }

    /// Run `work` on the USB queue with the last known status (nil if the camera
    /// wasn't connected), then read status and update the menu.
    private func run(_ work: @escaping (Camera, CameraStatus?) throws -> Void) {
        pending += 1
        render()
        let before = lastStatus
        queue.async { [self] in
            var err: String?
            do { try work(camera, before) } catch { err = "\(error)" }
            let status = try? camera.status()
            if status == nil { err = "Camera not connected" }
            DispatchQueue.main.async { [self] in
                pending -= 1
                lastStatus = status
                lastError = err
                render()
            }
        }
    }

    private func render() {
        let s = lastStatus
        let busy = pending > 0 && s == nil
        let tracking = s?.awake == true && s?.aiMode == .normal

        if let s {
            stateItem.title = s.awake ? "Awake · tracking \(s.aiMode.label.lowercased())" : "Asleep"
            if let e = lastError { stateItem.title += " — \(e)" }
        } else {
            stateItem.title = busy ? "Checking camera…" : (lastError ?? "Camera not connected")
        }

        let idle = pending == 0
        wakeItem.isEnabled = idle && s?.awake == false
        sleepItem.isEnabled = idle && s?.awake == true
        trackItem.isEnabled = idle && s?.awake == true
        trackItem.state = tracking ? .on : .off

        let symbol: String
        if s == nil { symbol = "video.slash" }
        else if s?.awake == false { symbol = "moon.zzz" }
        else if tracking { symbol = "person.crop.circle.badge.checkmark" }
        else { symbol = "video" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: stateItem.title)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "OBSBOT: \(stateItem.title)"
    }
}
