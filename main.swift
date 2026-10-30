// NetSpeed — live network speed for the macOS menu bar.
//
// Measures the primary (internet-facing) interface only, so traffic forwarded between
// interfaces (Internet Sharing, bridges) or tunnelled inside a VPN isn't counted twice.
// Reads its exact 64-bit byte counters via sysctl(IFMIB_IFDATA) — the same source
// `netstat -ib` uses — and divides the delta by elapsed monotonic time (which includes
// sleep), so sleep/wake and clock changes never produce a bogus spike.

import AppKit
import Darwin
import ServiceManagement
import SystemConfiguration

// MARK: - Settings (persisted)

enum Prefs {
    static let paused = "paused"
    static let downloadOnly = "downloadOnly"
    static let bits = "bitsMode"
}

// MARK: - Counters (sysctl IFMIB_IFDATA, if_data64)

/// (rxBytes, txBytes) for one interface, or nil if it doesn't exist (anymore).
/// Not NET_RT_IFLIST2 / getifaddrs: macOS hands normal apps those counters cut to
/// 32 bits and rounded to 1 KB, which wraps every 4 GB (~30s at 1 Gbps).
func interfaceCounters(index: UInt32) -> (rx: UInt64, tx: UInt64)? {
    guard index > 0 else { return nil }
    var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
    var d = ifmibdata()
    var size = MemoryLayout<ifmibdata>.size
    guard sysctl(&mib, u_int(mib.count), &d, &size, nil, 0) == 0 else { return nil }
    return (d.ifmd_data.ifi_ibytes, d.ifmd_data.ifi_obytes)
}

/// BSD name of the interface carrying the default route ("en0"), nil when offline.
func primaryInterface(_ store: SCDynamicStore?) -> String? {
    for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
        if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
           let name = dict["PrimaryInterface"] as? String { return name }
    }
    return nil
}

/// Seconds on a clock that never jumps and keeps running during sleep.
func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
}

// MARK: - Formatting

/// Fixed-width (3-char number + unit) so the menu bar item doesn't jitter.
/// Decimal (1000) units, matching Activity Monitor and how link speeds are quoted.
func formatRate(bytesPerSecond bps: Double, bits: Bool) -> String {
    let units = bits ? ["b ", "Kb", "Mb", "Gb", "Tb"] : ["B", "K", "M", "G", "T"]
    var v = max(0, bps) * (bits ? 8 : 1)
    var u = 0
    while v >= 999.5, u < units.count - 1 { v /= 1000; u += 1 }
    let num = (u > 0 && v < 9.95) ? String(format: "%.1f", v) : String(format: "%.0f", v)
    return String(repeating: " ", count: max(0, 3 - num.count)) + num + units[u]
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var hiddenBecause: Set<String> = [] // screens asleep, locked, or user switched away
    var store: SCDynamicStore?
    var primaryIndex: UInt32 = 0
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    // last-seen counters, tagged with the interface they came from
    var last: (index: UInt32, rx: UInt64, tx: UInt64)?
    var lastTime = monotonicSeconds()
    var lastDown: Double?
    var lastUp: Double?
    var shownText = ""
    var shownIdle = false

    // menu items needing state sync
    var pauseItem: NSMenuItem!
    var dlOnlyItem: NSMenuItem!
    var bitsItem: NSMenuItem!
    var loginItem: NSMenuItem?

    var paused: Bool {
        get { UserDefaults.standard.bool(forKey: Prefs.paused) }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.paused) }
    }
    var downloadOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Prefs.downloadOnly) }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.downloadOnly) }
    }
    var bitsMode: Bool {
        get { UserDefaults.standard.bool(forKey: Prefs.bits) }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.bits) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()

        // Nobody can see the menu bar while displays are off, the screen is locked,
        // or another user is switched in: stop sampling entirely.
        let ws = NSWorkspace.shared.notificationCenter
        hideWhile(ws, NSWorkspace.screensDidSleepNotification, until: NSWorkspace.screensDidWakeNotification)
        hideWhile(ws, NSWorkspace.sessionDidResignActiveNotification, until: NSWorkspace.sessionDidBecomeActiveNotification)
        hideWhile(DistributedNotificationCenter.default(), .init("com.apple.screenIsLocked"), until: .init("com.apple.screenIsUnlocked"))

        // Re-resolve the primary interface whenever the network changes (Wi-Fi <-> Ethernet, VPN up/down).
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "NetSpeed" as CFString, { _, _, info in
            Unmanaged<AppDelegate>.fromOpaque(info!).takeUnretainedValue().refreshPrimary()
        }, &ctx)
        if let store {
            SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray, nil)
            CFRunLoopAddSource(CFRunLoopGetMain(), SCDynamicStoreCreateRunLoopSource(nil, store, 0), .commonModes)
        }
        refreshPrimary()
        refreshRunning()
    }

    func hideWhile(_ center: NotificationCenter, _ on: Notification.Name, until off: Notification.Name) {
        center.addObserver(forName: on, object: nil, queue: .main) { [weak self] _ in
            self?.hiddenBecause.insert(on.rawValue); self?.refreshRunning()
        }
        center.addObserver(forName: off, object: nil, queue: .main) { [weak self] _ in
            self?.hiddenBecause.remove(on.rawValue); self?.refreshRunning()
        }
    }

    func refreshPrimary() {
        let name = primaryInterface(store)
        primaryIndex = name.map { if_nametoindex($0) } ?? 0
        statusItem.button?.toolTip = name.map { "Measuring \($0)" } ?? "Offline"
    }

    /// Starts the 1s sampler when visible and not paused; otherwise stops it so the
    /// app makes zero wakeups. (No App Nap opt-out needed: macOS doesn't nap an app whose
    /// status item is visible — measured: 150/150 ticks on time without one.)
    func refreshRunning() {
        let run = !paused && hiddenBecause.isEmpty
        // Fresh baselines on every start, so time spent stopped never shows up as a spike.
        last = nil; lastDown = nil; lastUp = nil
        lastTime = monotonicSeconds()

        if run, timer == nil {
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.update() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common) // .common: keep ticking while the menu is open
            timer = t
            update() // first tick only records the baseline
        } else if !run {
            timer?.invalidate(); timer = nil
        }
        render()
    }

    // MARK: menu

    func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            return i
        }

        pauseItem = item("Pause", #selector(togglePause(_:)), key: "p")
        dlOnlyItem = item("Download only", #selector(toggleDownloadOnly(_:)))
        bitsItem = item("Show bits (Mbps)", #selector(toggleBits(_:)))

        menu.addItem(pauseItem)
        menu.addItem(dlOnlyItem)
        menu.addItem(bitsItem)
        if #available(macOS 13.0, *) {
            loginItem = item("Launch at Login", #selector(toggleLogin(_:)))
            menu.addItem(loginItem!)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NetSpeed", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // Synced on open, so a change made in System Settings > Login Items shows up too.
    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.title = paused ? "Resume" : "Pause"
        dlOnlyItem.state = downloadOnly ? .on : .off
        bitsItem.state = bitsMode ? .on : .off
        loginItem?.state = loginEnabled() ? .on : .off
    }

    // MARK: actions

    @objc func togglePause(_ sender: NSMenuItem) {
        paused.toggle(); refreshRunning()
    }
    @objc func toggleDownloadOnly(_ sender: NSMenuItem) {
        downloadOnly.toggle(); render()
    }
    @objc func toggleBits(_ sender: NSMenuItem) {
        bitsMode.toggle(); render()
    }
    @objc func toggleLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("NetSpeed login item error: \(error)")
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Launch at Login"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        // User has to approve it in System Settings > General > Login Items.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func loginEnabled() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    // MARK: sampling

    func update() {
        let now = monotonicSeconds()
        let elapsed = now - lastTime
        lastTime = now

        let prev = last
        last = interfaceCounters(index: primaryIndex).map { (index: primaryIndex, rx: $0.rx, tx: $0.tx) }
        // Need the same interface as last tick, counters not gone backwards (interface reset),
        // and a sane interval (not first tick, sleep/wake or a stall); otherwise show nothing yet.
        guard let n = last, let o = prev, n.index == o.index, n.rx >= o.rx, n.tx >= o.tx,
              elapsed > 0.3, elapsed < 3.0 else {
            lastDown = nil; lastUp = nil
            render()
            return
        }
        lastDown = Double(n.rx - o.rx) / elapsed
        lastUp = Double(n.tx - o.tx) / elapsed
        render()
    }

    // MARK: rendering

    func render() {
        let text: String
        var idle = true
        if paused {
            text = "⏸"
        } else if let down = lastDown, let up = lastUp {
            let d = formatRate(bytesPerSecond: down, bits: bitsMode)
            let u = formatRate(bytesPerSecond: up, bits: bitsMode)
            text = downloadOnly ? "↓\(d)" : "↓\(d) ↑\(u)"
            idle = down < 50 && up < 50
        } else {
            text = downloadOnly ? "↓ …" : "↓ … ↑ …"
        }

        // Most ticks show the same text (e.g. idle); skip the menu bar redraw then.
        guard text != shownText || idle != shownIdle, let button = statusItem.button else { return }
        shownText = text
        shownIdle = idle
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: idle ? NSColor.secondaryLabelColor : NSColor.labelColor])
        button.setAccessibilityLabel(paused ? "Network speed paused" : "Network speed \(text)")
    }
}

// `NetSpeed --selftest` checks the formatter and counter read, then exits (run by build.sh).
if CommandLine.arguments.contains("--selftest") {
    let cases: [(Double, Bool, String)] = [
        (0, false, "  0B"), (999, false, "999B"), (999.6, false, "1.0K"), (9_960, false, " 10K"),
        (123_400_000, false, "123M"), (1_250_000, true, " 10Mb"), (100, true, "800b "), (-5, false, "  0B"),
    ]
    for (v, bits, want) in cases {
        let got = formatRate(bytesPerSecond: v, bits: bits)
        precondition(got == want, "formatRate(\(v), bits: \(bits)) = '\(got)', want '\(want)'")
    }
    precondition(interfaceCounters(index: if_nametoindex("lo0")) != nil, "can't read lo0 counters")
    precondition(interfaceCounters(index: 0) == nil, "index 0 must read as missing")
    // Must work inside the App Sandbox; nil only when offline.
    print("primary interface:", primaryInterface(nil) ?? "none (offline)")
    print("selftest ok")
    exit(0)
}

// Already running (e.g. launched twice)? Don't add a second menu bar item.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id)
       .contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar-only, no Dock icon
app.run()
