// NetSpeed — live network speed for the macOS menu bar.
//
// Reads per-interface 64-bit counters via sysctl(NET_RT_IFLIST2) — the same
// source `netstat` uses — and displays a wrapping-subtraction delta (correct
// even at 4 GB counter boundaries) normalized by real elapsed time, so
// sleep/wake never produces a bogus spike.

import AppKit
import Darwin
import ServiceManagement

// MARK: - Settings (persisted)

enum Prefs {
    static let paused = "paused"
    static let downloadOnly = "downloadOnly"
    static let bits = "bitsMode"
    static let loginItem = "loginItem"
}

// MARK: - Counters (sysctl NET_RT_IFLIST2, if_data64)

/// index -> (rxBytes, txBytes) for every interface
func routeCounters() -> [Int32: (UInt64, UInt64)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var size: size_t = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
    var buf = [UInt8](repeating: 0, count: size)
    var dataSize = size
    guard sysctl(&mib, u_int(mib.count), &buf, &dataSize, nil, 0) == 0, dataSize > 0 else { return [:] }

    var out: [Int32: (UInt64, UInt64)] = [:]
    buf.withUnsafeBytes { raw in
        var offset = 0
        while offset < dataSize {
            let p = raw.baseAddress!.advanced(by: offset)
            let msglen = Int(p.load(as: UInt16.self))
            if msglen <= 0 { break }
            let type = p.load(fromByteOffset: 3, as: UInt8.self)
            if type == 0x12 /* RTM_IFINFO2 */, msglen >= MemoryLayout<if_msghdr2>.size {
                let ifm = p.assumingMemoryBound(to: if_msghdr2.self).pointee
                out[Int32(ifm.ifm_index)] = (ifm.ifm_data.ifi_ibytes, ifm.ifm_data.ifi_obytes)
            }
            offset += msglen
        }
    }
    return out
}

/// index -> interface name (from getifaddrs, AF_LINK sockaddr_dl)
func indexToName() -> [Int32: String] {
    var map: [Int32: String] = [:]
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return map }
    defer { freeifaddrs(first) }
    var ptr = first
    while true {
        let ifp = ptr.pointee
        if let sa = ifp.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let nameC = ifp.ifa_name {
            let sdl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self).pointee
            map[Int32(sdl.sdl_index)] = String(cString: nameC)
        }
        guard let next = ifp.ifa_next else { break }
        ptr = next
    }
    return map
}

// MARK: - Formatting

func formatRate(bitsPerSecond bps: Double, bits: Bool) -> String {
    let v = bps * (bits ? 8 : 1)
    let s = bits ? "b" : ""
    switch true {
    case v >= 1_073_741_824: return String(format: "%.1f G%@", v / 1_073_741_824, s)
    case v >= 1_048_576:     return String(format: "%.1f M%@", v / 1_048_576, s)
    case v >= 1024:          return String(format: "%.0f K%@", v / 1024, s)
    default:                 return String(format: "%.0f B%@", v, s)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var activity: NSObjectProtocol?

    // per-interface last-seen counters (wrapped delta math)
    var lastRx: [String: UInt64] = [:]
    var lastTx: [String: UInt64] = [:]
    var lastDate = Date()

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
        // Opt out of App Nap so the 1-second timer stays exact.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .init(rawValue: 0x400) /* NSActivityIdleDisable: no system sleep, no timer suspension */,
            reason: "Live menu bar network meter")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = " …"
        }
        buildMenu()

        // Warm baseline so the first tick already measures a 1s delta.
        lastRx = [:];
        lastTx = [:]
        for (idx, (rx, tx)) in routeCounters() where (indexToName()[idx] ?? "").hasPrefix("en") {
            let name = indexToName()[idx] ?? ""
            lastRx[name] = rx
            lastTx[name] = tx
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        timer?.tolerance = 0.05
        RunLoop.main.add(timer!, forMode: .common)
        update()
    }

    // MARK: menu

    func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            return i
        }

        pauseItem = item(paused ? "Resume" : "Pause", #selector(togglePause(_:)), key: "p")
        dlOnlyItem = item("Download only", #selector(toggleDownloadOnly(_:)))
        bitsItem = item("Show bits (Mbps)", #selector(toggleBits(_:)))
        loginItem = item("Launch at Login", #selector(toggleLogin(_:)))
        loginItem?.isHidden = true
        if #available(macOS 13.0, *) {
            loginItem?.isHidden = false
        }

        menu.addItem(pauseItem)
        menu.addItem(dlOnlyItem)
        menu.addItem(bitsItem)
        if let l = loginItem { menu.addItem(l) }
        menu.addItem(.separator())
        menu.addItem(item("Quit NetSpeed", #selector(NSApplication.terminate(_:)), key: "q"))

        syncMenuState()
        statusItem.menu = menu
    }

    func syncMenuState() {
        pauseItem.title = paused ? "Resume" : "Pause"
        pauseItem.state = paused ? .on : .off
        dlOnlyItem.state = downloadOnly ? .on : .off
        bitsItem.state = bitsMode ? .on : .off
        loginItem?.state = loginEnabled() ? .on : .off
    }

    // MARK: actions

    @objc func togglePause(_ sender: NSMenuItem) {
        paused.toggle(); syncMenuState(); update()
    }
    @objc func toggleDownloadOnly(_ sender: NSMenuItem) {
        downloadOnly.toggle(); syncMenuState(); update()
    }
    @objc func toggleBits(_ sender: NSMenuItem) {
        bitsMode.toggle(); syncMenuState(); update()
    }
    @objc func toggleLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if loginEnabled() {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: Prefs.loginItem)
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: Prefs.loginItem)
            }
        } catch {
            NSLog("NetSpeed login item error: \(error)")
        }
        syncMenuState()
    }

    func loginEnabled() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    // MARK: sampling

    func update() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastDate)
        lastDate = now

        if paused {
            render(idle: true)
            return
        }

        let names = indexToName()
        var rateRx = 0.0
        var rateTx = 0.0
        let cap: UInt64 = 300_000_000 // 300 MB/s — bitesize sanity bound per tick

        for (idx, (rx, tx)) in routeCounters() {
            let name = names[idx] ?? ""
            guard name.hasPrefix("en") else { continue } // physical interfaces only: no lo0/utun/awdl/bridge double-count

            var dRx: UInt64 = 0
            var dTx: UInt64 = 0
            if let oRx = lastRx[name] {
                dRx = rx &- oRx
                if dRx > cap { dRx = 0 }                        // counter reset — drop this tick
            }
            if let oTx = lastTx[name] {
                dTx = tx &- oTx
                if dTx > cap { dTx = 0 }
            }
            lastRx[name] = rx
            lastTx[name] = tx
            rateRx += Double(dRx)
            rateTx += Double(dTx)
        }

        // Sleep/wake & stall protection: if more than 3s passed, don't display
        // (baselines are already refreshed; next tick shows a fresh 1s value).
        guard elapsed > 0.3, elapsed < 3.0 else {
            render(idle: true)
            return
        }
        rateRx /= elapsed
        rateTx /= elapsed

        render(down: rateRx, up: rateTx, idle: rateRx < 50 && rateTx < 50)
    }

    // MARK: rendering

    func render(down: Double? = nil, up: Double? = nil, idle: Bool = false) {
        var text: String
        if down == nil && up == nil {
            text = paused ? "⏸" : " ↓… ↑…"
        } else {
            let d = formatRate(bitsPerSecond: down ?? 0, bits: bitsMode)
            let u = formatRate(bitsPerSecond: up ?? 0, bits: bitsMode)
            text = downloadOnly ? "↓\(d)" : "↓\(d)↑\(u)"
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let color: NSColor = idle ? NSColor.secondaryLabelColor : NSColor.labelColor
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar-only, no Dock icon
app.run()
