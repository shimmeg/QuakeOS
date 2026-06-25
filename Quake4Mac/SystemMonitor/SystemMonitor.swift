// SystemMonitor.swift — Quake4Mac (Phase 3 ambient panel)
//
// A neon system-stats dashboard for the Quake panel, styled after DK-Suite's monitor
// view: dark glass panels, glowing multi-colour ring gauges, gradient bars. Live data
// (CPU load, RAM, process count) is read natively via mach/sysctl — no helpers needed.
//
// NOTE: CPU/GPU *temperature* and GPU load aren't here yet: DK-Suite gets those via
// `sudo powermetrics` and a privileged helper. We can add that later the same way.

import SwiftUI
import Foundation
import Darwin
import WebKit
import IOKit.ps
import IOBluetooth
import CoreWLAN

// MARK: - Live stats

struct DiskInfo { let name: String; let used: Double; let total: Double }
struct StorageCat { let name: String; let bytes: Double }

final class SystemStats: ObservableObject {
    @Published var cpuLoad: Double = 0          // 0…1
    @Published var cpuTemp: Double? = nil       // °C (nil if no sensor)
    @Published var gpuLoad: Double = 0          // 0…1
    @Published var gpuTemp: Double? = nil       // °C
    @Published var memTotal: Double = 1         // bytes
    @Published var memUsed: Double = 0
    @Published var memFree: Double = 0
    @Published var processCount: Int = 0
    @Published var procRunning = 0
    @Published var procSleeping = 0
    @Published var procBlocked = 0
    @Published var uptime: Double = 0           // seconds since boot
    @Published var netUp: Double = 0            // bytes/sec
    @Published var netDown: Double = 0
    @Published var wifiLinkMbps: Double = 0     // negotiated Wi-Fi link rate (Mbps)
    @Published var wifiSSID: String = ""        // network name (may be empty without Location access)
    @Published var hasBattery = false
    @Published var battLevel: Double = 0        // 0…1
    @Published var battCharging = false
    @Published var disks: [DiskInfo] = []
    @Published var bt: [String] = []
    @Published var storageTotal: Double = 1
    @Published var storageCats: [StorageCat] = []
    @Published var topRAM: [StorageCat] = []     // processes using the most memory (name + bytes)
    private var tick = 0
    private var procBusy = false
    private var storageBusy = false
    private var bluetoothBusy = false
    // Variable-latency readers (Wi-Fi/SSID, network, battery, volumes) run here so they never
    // hitch the 1s main-thread tick. Serial → prevNet/lastNetRate stay single-owner; metricsBusy
    // (main-only) prevents pile-up if one sample runs long.
    private let metricsQueue = DispatchQueue(label: "com.quake4mac.sysmetrics", qos: .utility)
    private var metricsBusy = false
    private var lastNetRate: (up: Double, down: Double) = (0, 0)   // bg-owned fallback for readNetwork hiccups

    private var prev: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private var prevNet: (rx: UInt64, tx: UInt64, t: Date)?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        memTotal = Double(ProcessInfo.processInfo.physicalMemory)
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = 0.15   // let the kernel coalesce wakeups; imperceptible on a 1Hz status gauge
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        cpuLoad = readCPU()
        readMem()
        readProcessesAsync()        // states + top-RAM via `ps`, off the main thread
        uptime = readUptime()
        // Real thermals + GPU load (no sudo). IOHIDEventSystem clients must be used on a
        // run-loop thread — doing this on a bare background queue crashed the HID server —
        // so read on the MAIN thread (sample() already runs there). The calls are fast
        // (cached sensor values); throttle to every 2s to keep it cheap.
        if tick % 2 == 0 {
            cpuTemp = Thermals.shared.cpuTemp()
            gpuTemp = Thermals.shared.gpuTemp()
            if let gl = Thermals.shared.gpuUtilization() { gpuLoad = gl }
        }
        // Wi-Fi (SSID lookup can stall on Location/entitlement checks), network counters, battery,
        // and mounted-volume enumeration are the variable-latency readers — gather them on a serial
        // background queue and publish on main, so they never hitch the 1s UI tick. (Thermals stay
        // on main above: IOHIDEventSystem needs a run-loop thread.)
        if !metricsBusy {
            metricsBusy = true
            metricsQueue.async { [weak self] in
                guard let self else { return }
                let net = self.readNetwork()
                var link = 0.0, ssid = ""
                if let w = CWWiFiClient.shared().interface() {
                    link = w.transmitRate()        // negotiated PHY rate (e.g. 1200 for Wi-Fi 6)
                    ssid = w.ssid() ?? ""
                }
                let batt = self.readBattery()
                let dks = self.readDisks()
                DispatchQueue.main.async {
                    self.netUp = net.up; self.netDown = net.down
                    self.wifiLinkMbps = link; self.wifiSSID = ssid
                    if let b = batt { self.hasBattery = true; self.battLevel = b.level; self.battCharging = b.charging }
                    else { self.hasBattery = false }
                    self.disks = dks
                    self.metricsBusy = false
                }
            }
        }
        if tick % 60 == 0, !storageBusy {
            storageBusy = true
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.computeStorage() }
        }
        if tick % 30 == 0, !bluetoothBusy {
            bluetoothBusy = true
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.computeBluetooth() }
        }
        tick += 1
    }

    // MARK: storage breakdown by category (computed off the main thread, refreshed ~60s)
    //
    // Uses `du` (C, fast) instead of a Swift FileManager walk — the old walk enumerated every
    // file under /Applications (Xcode ≈ 300k files), taking minutes, so the tile stayed empty.
    private func computeStorage() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let boot = URL(fileURLWithPath: "/")
        var totalCap: Double = 0, availCap: Double = 0
        if let v = try? boot.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            totalCap = Double(v.volumeTotalCapacity ?? 0); availCap = Double(v.volumeAvailableCapacity ?? 0)
        }
        let used = max(0, totalCap - availCap)
        let total = totalCap > 0 ? totalCap : 1
        let defs: [(String, String)] = [
            ("Applications", "/Applications"),
            ("Documents", home + "/Documents"),
            ("Downloads", home + "/Downloads"),
            ("Desktop", home + "/Desktop"),
            ("Pictures", home + "/Pictures"),
            ("Music", home + "/Music"),
            ("Movies", home + "/Movies")
        ]
        // Show the disk total/used immediately so the tile is never blank while du runs.
        DispatchQueue.main.async { [weak self] in
            if self?.storageCats.isEmpty ?? false {
                self?.storageTotal = total
                self?.storageCats = [StorageCat(name: "Used", bytes: used)]
            }
        }
        // `du -sk -d 0 <paths…>` → "<kilobytes>\t<path>" per line.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", "-d", "0"] + defs.map { $0.1 }
        // Drain stderr to /dev/null so a flood of "Permission denied" can't fill the pipe's
        // ~64KB kernel buffer and deadlock the child on write(2). Read stdout to EOF BEFORE
        // waitUntilExit() so a large stdout can't deadlock either.
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        var sizes: [String: Double] = [:]
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\t")
                    guard parts.count >= 2, let kb = Double(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                    sizes[String(parts[1])] = kb * 1024
                }
            }
        }
        var cats: [(String, Double)] = []
        var sum: Double = 0
        for (name, path) in defs {
            let b = sizes[path] ?? 0
            if b > 0 { cats.append((name, b)); sum += b }
        }
        cats.append(("System & Other", max(0, used - sum)))
        cats.sort { $0.1 > $1.1 }
        let result = cats.map { StorageCat(name: $0.0, bytes: $0.1) }
        DispatchQueue.main.async { [weak self] in
            self?.storageTotal = total
            self?.storageCats = result
            self?.storageBusy = false
        }
    }

    // MARK: Bluetooth — connected devices via system_profiler (catches AirPods that
    // IOBluetooth's pairedDevices misses). Slow (~1-2s), so run off-thread, refreshed ~30s.
    private func computeBluetooth() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        // Drain stderr to /dev/null (an unconsumed stderr pipe can fill and deadlock the
        // child). Read stdout to EOF BEFORE waitUntilExit() so large output can't deadlock.
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else {
            DispatchQueue.main.async { [weak self] in self?.bluetoothBusy = false }
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var names: [String] = []
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = root["SPBluetoothDataType"] as? [[String: Any]] {
            for entry in arr {
                if let connected = entry["device_connected"] as? [[String: Any]] {
                    for dev in connected { names.append(contentsOf: dev.keys) }
                }
            }
        }
        // Same device can appear under multiple controller entries (e.g. AirPods) — dedupe.
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        DispatchQueue.main.async { [weak self] in
            self?.bt = unique
            self?.bluetoothBusy = false
        }
    }

    // MARK: process states + top-RAM (via `ps`, off the main thread)
    //
    // The sysctl KERN_PROC p_stat field reports almost everything as SRUN on modern macOS,
    // so "running" was 100% of processes — wrong. `ps -axo state=` uses the real scheduler
    // state (R runnable, S/I sleeping, others waiting/stopped), matching Activity Monitor.
    // The same call yields rss per process, which we aggregate by name for "most RAM".
    private func readProcessesAsync() {
        if procBusy { return }
        procBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = SystemStats.psSnapshot()
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Reset the guard on EVERY exit path — including psSnapshot() returning nil —
                // so one failed sample doesn't freeze the process panel forever. procBusy is
                // only ever read/written on the main thread, so this stays consistent.
                defer { self.procBusy = false }
                guard let r = r else { return }
                self.processCount = r.total
                self.procRunning = r.running
                self.procSleeping = r.sleeping
                self.procBlocked = r.blocked
                self.topRAM = r.top
            }
        }
    }

    private static func psSnapshot() -> (total: Int, running: Int, sleeping: Int, blocked: Int, top: [StorageCat])? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "state=,rss=,comm="]
        // Drain stderr to /dev/null (an unconsumed stderr pipe can fill and deadlock the
        // child). Read stdout to EOF BEFORE waitUntilExit() so large output can't deadlock.
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var run = 0, sleep = 0, block = 0, total = 0
        var byName: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            total += 1
            switch parts[0].first {
            case "R":           run += 1          // runnable / on-CPU
            case "S", "I":      sleep += 1        // interruptible sleep / idle
            default:            block += 1        // U/D uninterruptible, T stopped, Z zombie
            }
            let rssBytes = (Double(parts[1]) ?? 0) * 1024     // ps rss is KiB
            let name = URL(fileURLWithPath: String(parts[2])).lastPathComponent
            byName[name, default: 0] += rssBytes
        }
        let top = byName.sorted { $0.value > $1.value }.prefix(5).map { StorageCat(name: $0.key, bytes: $0.value) }
        return (total, run, sleep, block, Array(top))
    }

    // MARK: network throughput (bytes/sec, summed over non-loopback links)
    private func readNetwork() -> (up: Double, down: Double) {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return lastNetRate }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let cur = p {
            let ifa = cur.pointee
            if ifa.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let d = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") {           // physical Wi-Fi / Ethernet only (skip lo/utun/bridge/awdl)
                    let nd = d.assumingMemoryBound(to: if_data.self).pointee
                    rx += UInt64(nd.ifi_ibytes); tx += UInt64(nd.ifi_obytes)
                }
            }
            p = ifa.ifa_next
        }
        let now = Date()
        defer { prevNet = (rx, tx, now) }
        guard let pr = prevNet else { return (0, 0) }
        let dt = now.timeIntervalSince(pr.t)
        guard dt > 0 else { return lastNetRate }
        let rate = (up: max(0, Double(tx &- pr.tx) / dt), down: max(0, Double(rx &- pr.rx) / dt))
        lastNetRate = rate
        return rate
    }

    // MARK: battery (nil on desktops without one)
    private func readBattery() -> (level: Double, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let mx = desc[kIOPSMaxCapacityKey] as? Int, mx > 0 else { continue }
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            return (Double(cur) / Double(mx), charging)
        }
        return nil
    }

    // MARK: mounted volumes
    private func readDisks() -> [DiskInfo] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        guard let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                               options: [.skipHiddenVolumes]) else { return [] }
        var out: [DiskInfo] = []
        for url in vols {
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.volumeIsBrowsable == true, v.volumeIsLocal == true,
                  let total = v.volumeTotalCapacity, total > 0,
                  let avail = v.volumeAvailableCapacity else { continue }
            out.append(DiskInfo(name: v.volumeName ?? url.lastPathComponent,
                                used: Double(total - avail), total: Double(total)))
        }
        return out
    }

    // MARK: connected Bluetooth devices (needs NSBluetoothAlwaysUsageDescription, now set).
    private func readBluetooth() -> [String] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.filter { $0.isConnected() }.compactMap { $0.name }
    }

    private func readUptime() -> Double {
        var bt = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bt, &size, nil, 0) == 0, bt.tv_sec != 0 else { return uptime }
        return max(0, Date().timeIntervalSince1970 - Double(bt.tv_sec))
    }

    private func readCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        // mach_host_self() returns a send right we own — release it after the last use,
        // otherwise we leak a Mach port on every sample.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return cpuLoad }
        let u = info.cpu_ticks.0, s = info.cpu_ticks.1, i = info.cpu_ticks.2, n = info.cpu_ticks.3
        defer { prev = (u, s, i, n) }
        guard let p = prev else { return 0 }
        let du = Double(u &- p.user), ds = Double(s &- p.sys), di = Double(i &- p.idle), dn = Double(n &- p.nice)
        let busy = du + ds + dn, total = busy + di
        return total > 0 ? busy / total : 0
    }

    private func readMem() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        // mach_host_self() returns a send right we own — release it after the last use,
        // otherwise we leak a Mach port on every sample.
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        memUsed = used
        memFree = max(0, memTotal - used)
    }

}

// MARK: - Dashboard (DecoKee systemInfoTheme, rendered in a WebView)

struct SystemMonitorView: View {
    @StateObject private var stats = SystemStats()
    var interactive = true     // false in the settings preview: don't grab the device touch-router

    var body: some View {
        MonitorWebView(stats: stats, interactive: interactive)
            .ignoresSafeArea()
            .onAppear { stats.start() }
            .onDisappear { stats.stop() }
    }
}

/// Renders monitor.html (DecoKee's cyan systemInfoTheme stat tiles) and feeds it live
/// stats via window.MON.set(...) — same pattern as the macro ScreenWebView.
struct MonitorWebView: NSViewRepresentable {
    @ObservedObject var stats: SystemStats
    var interactive = true     // false = settings preview (no device touch-router install)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "monitor", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // Device touches arrive as USB-HID, not as WebKit scroll gestures — forward
        // finger-drags here so the Storage / Bluetooth lists scroll on the panel. Skip in the
        // settings preview so it doesn't steal the router from the real on-device panel.
        if interactive {
            let coord = context.coordinator
            ScreenTouchRouter.shared.install(owner: coord,
                began: { [weak coord] p in coord?.touchBegan(p) },
                moved: { [weak coord] p in coord?.touchMoved(p) },
                ended: { [weak coord] in coord?.touchEnded() })
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.push(stats)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        ScreenTouchRouter.shared.release(owner: coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var loaded = false
        private var lastTouch: CGPoint?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            pushLast()
        }

        // Touch → scroll: drag delta (in device px) scrolls whatever list is under the finger.
        func touchBegan(_ p: CGPoint) { lastTouch = p }
        func touchEnded() { lastTouch = nil }
        func touchMoved(_ p: CGPoint) {
            defer { lastTouch = p }
            guard let prev = lastTouch, let web = web else { return }
            let dy = Double(prev.y - p.y) * Double(web.bounds.height)   // finger-up → reveal below
            guard abs(dy) > 0.3 else { return }
            web.evaluateJavaScript("window.MON.scrollAt(\(Double(p.x)),\(Double(p.y)),\(dy))", completionHandler: nil)
        }

        private var last: [String: Any] = [:]
        func push(_ s: SystemStats) {
            last = [
                "cpu": ["load": s.cpuLoad, "temp": s.cpuTemp.map { $0 as Any } ?? NSNull()],
                "gpu": ["load": s.gpuLoad, "temp": s.gpuTemp.map { $0 as Any } ?? NSNull()],
                "mem": ["total": s.memTotal, "used": s.memUsed, "free": s.memFree,
                        "top": s.topRAM.map { ["name": $0.name, "bytes": $0.bytes] }],
                "proc": ["running": s.procRunning, "blocked": s.procBlocked,
                         "sleeping": s.procSleeping, "total": s.processCount],
                "net": ["up": s.netUp, "down": s.netDown, "iface": "Wi-Fi",
                        "link": s.wifiLinkMbps, "ssid": s.wifiSSID],
                "battery": s.hasBattery ? ["level": s.battLevel, "charging": s.battCharging] : NSNull(),
                "storage": ["total": s.storageTotal,
                            "cats": s.storageCats.map { ["name": $0.name, "bytes": $0.bytes] }],
                "bt": s.bt
            ]
            pushLast()
        }
        private func pushLast() {
            guard loaded, let web = web,
                  let data = try? JSONSerialization.data(withJSONObject: last),
                  let json = String(data: data, encoding: .utf8) else { return }
            let enc = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            web.evaluateJavaScript("window.MON.set(decodeURIComponent('\(enc)'))", completionHandler: nil)
        }
    }
}
