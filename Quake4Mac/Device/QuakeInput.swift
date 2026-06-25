// QuakeInput.swift — Quake4Mac
//
// Reads the real DecoKee Quake over USB-HID via IOKit/IOHIDManager and turns its
// raw reports into clean events. Decoded from a live hid_scan capture:
//
//   KNOB / BUTTON  — device VID 0x4158 (Huckies) / PID 0x514B, report id 0, 32 bytes:
//       A3 03 03 [kind] [dir] [code] 00...
//       kind 01 = rotate (dir 01 = CW, dir 02 = CCW); kind 02 = button (dir 01 = press)
//
//   TOUCH          — device VID 0x0712 (hotlotus) / PID 0x0010, report id 0xA3, ~30 bytes:
//       A3 1C 03 1A 01 [contact] [Xlo Xhi] [Ylo Yhi] 00...
//       X = bytes[6..7], Y = bytes[8..9], 16-bit LITTLE-endian.
//       Panel is native PORTRAIT (~480 x 1920) rotated into the ultra-wide landscape.
//
// We match STRICTLY by VID/PID so the firehose from other HID gear (Razer mouse,
// Apple sensors, etc.) is ignored.

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

// MARK: - Device identity (ground truth from the scan)

enum QuakeIDs {
    static let knobVID  = 0x4158
    static let knobPID  = 0x514B
    static let touchVID = 0x0712
    static let touchPID = 0x0010
}

enum QuakeDeviceKind { case knob, touch }

// MARK: - Events

enum QuakeEvent {
    case knobClockwise
    case knobCounterClockwise
    case knobPress
    case touchBegan(CGPoint)   // normalized 0...1, origin top-left of the display
    case touchMoved(CGPoint)
    case touchEnded
}

// MARK: - Touch calibration
//
// Maps raw panel coordinates to a normalized display point. Defaults come straight
// from the scan; tweak with a quick corner-tap pass.

struct TouchCalibration {
    // Observed raw range. Taps read X 52–410, Y 251–1720; we open it to the full
    // native panel and let a calibration pass tighten it.
    var xMin: Double = 0,    xMax: Double = 480
    var yMin: Double = 0,    yMax: Double = 1920

    // Panel is portrait, display is landscape -> swap axes so the long panel axis
    // (Y, 0..1920) drives display width and the short axis (X) drives display height.
    var swapAxes = true
    var flipU = false        // horizontal flip of the display-width axis
    var flipV = true         // vertical flip — panel reports Y inverted vs. our view

    func normalize(panelX: Double, panelY: Double) -> CGPoint {
        let nx = clamp((panelX - xMin) / (xMax - xMin))   // 0..1 across short axis
        let ny = clamp((panelY - yMin) / (yMax - yMin))   // 0..1 across long axis
        var u = swapAxes ? ny : nx                        // display width  (x)
        var v = swapAxes ? nx : ny                        // display height (y)
        if flipU { u = 1 - u }
        if flipV { v = 1 - v }
        return CGPoint(x: u, y: v)
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

// MARK: - Reader

final class QuakeInputReader: ObservableObject {

    // UI-facing state (updated on the main run loop, where HID callbacks fire).
    @Published var lastEvent: String = "—"
    @Published var knobValue: Int = 0
    @Published var touchPoint: CGPoint? = nil      // normalized 0..1, nil when lifted
    @Published var lastRawTouch: (x: Int, y: Int)? = nil
    @Published var knobConnected = false
    @Published var touchConnected = false
    @Published var luminance: Int = 255      // device panel backlight, 0–255 (0xA3 cmd 5)

    var calibration = TouchCalibration()

    /// Optional sink for whoever wants the raw event stream (Phase 2+).
    var onEvent: ((QuakeEvent) -> Void)?

    private var manager: IOHIDManager?
    private struct OpenDevice {
        let kind: QuakeDeviceKind
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let tag: DeviceTag
    }
    private var openDevices: [OpenDevice] = []
    // The QMK raw-HID / VIA interface (usagePage 0xFF60, usage 0x61). Confirmed from DK-Suite's
    // own logs: it targets exactly VID 0x4158/PID 0x514B, usagePage 65376, usage 97, interface 2.
    // ALL lighting must go to THIS interface specifically — the knob also exposes a System-Control
    // interface (usagePage 1/usage 0x80) under the same VID/PID that silently ignores VIA writes.
    private var viaDevice: IOHIDDevice?
    private var wakeAttempted = false
    private var liftWork: DispatchWorkItem?
    private var sessionResetWork: DispatchWorkItem?
    private var contactSessionActive = false
    private let reportBufferSize = 64
    private var viaProbing = false
    private var probeQueue: [[UInt8]] = []
    private var rgbBrowseMode = false
    private var rgbBrowseIndex = 1

    // Per-device context handed to the C callback.
    final class DeviceTag {
        let kind: QuakeDeviceKind
        unowned let reader: QuakeInputReader
        init(_ kind: QuakeDeviceKind, _ reader: QuakeInputReader) {
            self.kind = kind; self.reader = reader
        }
    }

    func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        let matching: [[String: Any]] = [
            [kIOHIDVendorIDKey as String: QuakeIDs.knobVID,
             kIOHIDProductIDKey as String: QuakeIDs.knobPID],
            [kIOHIDVendorIDKey as String: QuakeIDs.touchVID,
             kIOHIDProductIDKey as String: QuakeIDs.touchPID],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matching as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, quakeDeviceAdded, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, quakeDeviceRemoved, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            let msg = "HID open failed (0x\(String(r, radix: 16))) — grant Input Monitoring to this app, then relaunch"
            lastEvent = msg
            log(msg)
        } else {
            log("HID manager open OK. Watching for knob 4158:514B + touch 0712:0010.")
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(("[Quake] " + s + "\n").data(using: .utf8)!)
    }

    // Called from the device-matching callback once we know the device + kind.
    fileprivate func attach(device: IOHIDDevice, kind: QuakeDeviceKind) {
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? -1
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
        let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1

        // Skip the plain keyboard interface (usagePage 0x01 / usage 0x06): the knob's
        // events come through System Control + vendor interfaces, and opening a keyboard
        // trips the strictest permission gate for no benefit.
        if usagePage == 0x01 && usage == 0x06 {
            log("skipping keyboard interface \(String(format: "%04X:%04X", vid, pid))")
            return
        }

        openAttempt(device: device, kind: kind, vid: vid, pid: pid,
                    usagePage: usagePage, usage: usage, tries: 0)
    }

    private func openAttempt(device: IOHIDDevice, kind: QuakeDeviceKind,
                             vid: Int, pid: Int, usagePage: Int, usage: Int, tries: Int) {
        let id = String(format: "%04X:%04X up=0x%02X u=0x%02X", vid, pid, usagePage, usage)
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            log("open DENIED \(id) (0x\(String(UInt32(bitPattern: r), radix: 16))) try \(tries)")
            if tries < 5 {   // TCC sometimes denies the first opens, then allows
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                    self?.openAttempt(device: device, kind: kind, vid: vid, pid: pid,
                                      usagePage: usagePage, usage: usage, tries: tries + 1)
                }
            }
            return
        }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        buf.initialize(repeating: 0, count: reportBufferSize)

        let tag = DeviceTag(kind, self)
        let tagPtr = Unmanaged.passUnretained(tag).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(device, buf, reportBufferSize, quakeReport, tagPtr)

        switch kind {
        case .knob:  knobConnected = true
        case .touch: touchConnected = true
        }
        openDevices.append(OpenDevice(kind: kind, device: device, buffer: buf, tag: tag))
        // Lock onto the VIA raw-HID interface for lighting. This is the ONE interface that
        // accepts QMK lighting commands; everything else under this VID/PID ignores them.
        if usagePage == 0xFF60 && usage == 0x61 {
            viaDevice = device
            log("VIA raw-HID interface READY \(id) — lighting will target this interface")
        }
        log("attached \(kind) \(id) (\(openDevices.count) interface(s) open)")

        // Light the panel AND start the keep-alive heartbeat. The Quake firmware blanks
        // the HDMI display if it doesn't receive a periodic ping (DK-Suite sends it every
        // 15s; without it the panel times out after ~15-30s and goes black). THIS, not our
        // rendering, was the "random black-out".
        if !wakeAttempted {
            wakeAttempted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.wakePanel()        // backlight on (A3 03 01 05 FF 06)
                self?.startKeepAlive()   // begin the ping that keeps it showing HDMI
            }
        }
    }

    fileprivate func markRemoved(device: IOHIDDevice, kind: QuakeDeviceKind) {
        detach(device: device)
        knobConnected = openDevices.contains { $0.kind == .knob }
        touchConnected = openDevices.contains { $0.kind == .touch }
        if !touchConnected { touchPoint = nil }
        if openDevices.isEmpty {
            wakeAttempted = false
            stopKeepAlive()
        }
    }

    private func detach(device: IOHIDDevice) {
        var removed: [OpenDevice] = []
        openDevices.removeAll { entry in
            let match = sameDevice(entry.device, device)
            if match { removed.append(entry) }
            return match
        }

        for entry in removed {
            if let via = viaDevice, sameDevice(via, entry.device) { viaDevice = nil }
            IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, 0, nil, nil)
            IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
            entry.buffer.deinitialize(count: reportBufferSize)
            entry.buffer.deallocate()
        }
        log("detached \(removed.count) HID interface(s); \(openDevices.count) still open")
    }

    private func sameDevice(_ lhs: IOHIDDevice, _ rhs: IOHIDDevice) -> Bool {
        CFEqual(lhs, rhs)
    }

    // MARK: Report handling (runs on main run loop)

    fileprivate func handle(kind: QuakeDeviceKind, bytes: [UInt8]) {
        // During a capability probe, only surface MEANINGFUL replies: the version, and any
        // get_value (0x08) field whose payload is non-zero and not the 0xCAFE "unknown" sentinel.
        // Everything else (zero fields, unknown channels) is suppressed so a hidden per-LED field
        // would stand out instead of hiding in hundreds of zero lines.
        if viaProbing, kind == .knob, let c = bytes.first {
            if c == 0x01 {
                log("VIA-resp protocol version: " + hex(bytes, 3))
            } else if c == 0x08, bytes.count >= 4 {
                let ch = bytes[1], field = bytes[2]
                let payload = Array(bytes.dropFirst(3).prefix(8))
                let isCafe = bytes.count >= 5 && bytes[3] == 0xCA && bytes[4] == 0xFE
                if !isCafe, payload.contains(where: { $0 != 0 }) {
                    log(String(format: "VIA-resp ch=%d field=%d → %@", ch, field,
                               payload.map { String(format: "%02X", $0) }.joined(separator: " ")))
                }
            }
        }
        switch kind {
        case .knob:  handleKnob(bytes)
        case .touch: handleTouch(bytes)
        }
    }

    private func handleKnob(_ b: [UInt8]) {
        // Expect A3 03 03 [kind] [dir] ...
        guard b.count >= 5, b[0] == 0xA3, b[1] == 0x03, b[2] == 0x03 else { return }
        let kind = b[3], dir = b[4]
        // RGB browse mode: knob steps effects (turn = next/prev, press = exit). Swallows the
        // events so the page-switcher doesn't also react.
        if rgbBrowseMode {
            switch (kind, dir) {
            case (0x01, 0x01): rgbBrowseIndex = min(44, rgbBrowseIndex + 1); showRgbBrowse()
            case (0x01, 0x02): rgbBrowseIndex = max(0,  rgbBrowseIndex - 1); showRgbBrowse()
            case (0x02, 0x01): rgbBrowseMode = false
                               log("=== RGB browse OFF — stopped on effect \(rgbBrowseIndex): \(Self.effectName(rgbBrowseIndex)) ===")
            default: break
            }
            return
        }
        switch (kind, dir) {
        case (0x01, 0x01): emit(.knobClockwise);        knobValue += 1; lastEvent = "knob ⟳ CW"
        case (0x01, 0x02): emit(.knobCounterClockwise); knobValue -= 1; lastEvent = "knob ⟲ CCW"
        case (0x02, 0x01): emit(.knobPress);                            lastEvent = "knob ⏺ press"
        default:                                                        lastEvent = "knob ? \(hex(b, 6))"
        }
    }

    private func handleTouch(_ b: [UInt8]) {
        // A3 1C 03 1A 01 [contact] [Xlo Xhi] [Ylo Yhi]
        guard b.count >= 10, b[0] == 0xA3 else { return }
        let contact = b[5]
        let x = Int(b[6]) | (Int(b[7]) << 8)   // little-endian
        let y = Int(b[8]) | (Int(b[9]) << 8)
        lastRawTouch = (x, y)

        if contact == 0x00 {
            liftWork?.cancel()
            sessionResetWork?.cancel()
            contactSessionActive = false
            touchPoint = nil
            emit(.touchEnded)
            lastEvent = "touch ↑"
            log("TOUCH end")
            return
        }

        let p = calibration.normalize(panelX: Double(x), panelY: Double(y))
        sessionResetWork?.cancel()
        let began = !contactSessionActive
        contactSessionActive = true
        touchPoint = p
        emit(began ? .touchBegan(p) : .touchMoved(p))
        lastEvent = String(format: "touch (%d,%d) → (%.2f,%.2f)", x, y, p.x, p.y)
        if began { log(String(format: "TOUCH begin raw(%d,%d) → norm(%.2f,%.2f)", x, y, p.x, p.y)) }

        // The panel doesn't reliably send a touch-up report, so treat a short gap with
        // no further reports as a lift. This makes each discrete tap re-register.
        liftWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.touchPoint != nil else { return }
            self.touchPoint = nil
            self.emit(.touchEnded)
            self.lastEvent = "touch ↑ (gap)"
            let reset = DispatchWorkItem { [weak self] in
                guard let self, self.touchPoint == nil else { return }
                self.contactSessionActive = false
            }
            self.sessionResetWork = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: reset)
        }
        liftWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    // MARK: Outgoing — panel backlight / wake
    //
    // DecoKee sets the LCD backlight with a 0xA1 JSON frame {type:brightness, level:0..6}.
    // The panel stays dark until it receives this — which is exactly why a freshly
    // plugged-in Quake shows nothing. We don't yet know which of the device's HID
    // interfaces accepts it, so we write to every one we managed to open (harmless
    // shotgun) and let the knob sweep the level live to find what lights it.

    func wakePanel() { setLuminance(255) }

    // MARK: Keep-alive heartbeat
    //
    // The Quake firmware blanks the HDMI panel unless it keeps receiving a periodic ping.
    // From DK-Suite background.js (QuakeMainController.startKeepAliveProcess):
    //   sendShortCMD(sn, l(163, [239], 2))   every deviceKeepAliveGap = 15_000 ms
    // l(163,[239],2) builds the 0xA3 frame  A3 02 02 EF F1  (opcode 0x02, data 0xEF).
    // We ping every 10 s for margin (firmware timeout is ~15-30 s).

    private var keepAliveTimer: Timer?

    func startKeepAlive() {
        sendPing()
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        log("keep-alive started — ping A3 02 02 EF F1 every 10s")
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        log("keep-alive stopped — no HID interfaces open")
    }

    func sendPing() {
        let frame = a3Frame(opcode: 0x02, data: [0xEF])   // → A3 02 02 EF F1
        for entry in openDevices { writeOutput(frame, to: entry.device) }
    }

    /// Set the panel backlight via the device's native 0xA3 command.
    /// Reverse-engineered from DK-Suite: `sendShortCMD(sn, l(163,[5,value],1))`.
    /// On the wire (report id 0): A3 03 01 05 <value> <(1+5+value)%255>, value 1–255.
    func setLuminance(_ value: Int) {
        let v = min(255, max(1, value))
        luminance = v
        let frame = a3Frame(opcode: 0x01, data: [0x05, UInt8(v)])
        var ok = 0
        for entry in openDevices where writeOutput(frame, to: entry.device) { ok += 1 }
        log(String(format: "luminance %d → [%@] to %d/%d iface(s)", v,
                   frame.map { String(format: "%02X", $0) }.joined(separator: " "),
                   ok, openDevices.count))
    }

    // MARK: Knob RGB ring (QMK VIA, RGB-Matrix custom channel 3)
    //
    // VERIFIED against DK-Suite v0.4.40's own runtime logs talking to THIS unit (QUAKE,
    // 0x4158/0x514B, protocol v12). It sets the ring via the VIA custom-menu channel 3:
    //   effect      → [0x07, 0x03, 0x02, idx]   (field 2; firmware clamps idx to 0…44)
    //   brightness  → [0x07, 0x03, 0x01, val]   (field 1)
    //   speed       → [0x07, 0x03, 0x03, val]   (field 3)
    //   color       → [0x07, 0x03, 0x04, hue, sat] (field 4)
    //   save        → [0x09]
    // Wire format = 32-byte OUTPUT report, report id 0: [command, …payload] — byte-identical
    // to DK-Suite's reportHead. The rainbow the user wants is effect index 13 (Cycle
    // Left/Right) — DK-Suite's log shows effect "before: [13]" while the rainbow was live.
    // The framing was never the problem; the fix is sending to the RIGHT interface (viaDevice)
    // and confirming the write — see sendVIA logging.
    private let viaRGBChannel: UInt8 = 3

    // Each also mirrors into RGBLiveState so the settings knob preview matches whatever is actually
    // driving the ring (static OR the reactive engine's page/album/CPU/flash overrides).
    func rgbSetEffect(_ i: Int)          { let v = max(0, min(44, i));  sendVIA(0x07, [viaRGBChannel, 0x02, UInt8(v)]); RGBLiveState.shared.setEffect(v) }
    func rgbSetBrightness(_ v: Int)      { let x = max(0, min(255, v)); sendVIA(0x07, [viaRGBChannel, 0x01, UInt8(x)]); RGBLiveState.shared.setBrightness(x) }
    func rgbSetSpeed(_ v: Int)           { let x = max(0, min(255, v)); sendVIA(0x07, [viaRGBChannel, 0x03, UInt8(x)]); RGBLiveState.shared.setSpeed(x) }
    func rgbSetColor(hue: Int, sat: Int) { let h = max(0, min(255, hue)), s = max(0, min(255, sat)); sendVIA(0x07, [viaRGBChannel, 0x04, UInt8(h), UInt8(s)]); RGBLiveState.shared.setColor(h: h, s: s) }
    func rgbSave()                       { sendVIA(0x09, []) }

    private func sendVIA(_ command: UInt8, _ data: [UInt8]) {
        var frame = [UInt8](repeating: 0, count: 32)
        frame[0] = command
        for (i, b) in data.enumerated() where (1 + i) < 32 { frame[1 + i] = b }
        let hexData = data.map { String(format: "%02X", $0) }.joined(separator: " ")

        // Send ONLY to the VIA raw-HID interface (0xFF60/0x61) — the one DK-Suite uses.
        guard let dev = viaDevice else {
            if !viaProbing {
                log("VIA cmd=0x\(String(format: "%02X", command)) [\(hexData)] DROPPED — no 0xFF60 interface open " +
                    "(grant Input Monitoring + replug; lighting can't work until 'VIA raw-HID interface READY' appears)")
            }
            return
        }
        let rc = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, frame, frame.count)
        if !viaProbing {
            log(String(format: "VIA cmd=0x%02X [%@] → SetReport rc=0x%08X (%@)",
                       command, hexData, UInt32(bitPattern: rc),
                       rc == kIOReturnSuccess ? "OK" : "FAIL"))
        }
    }

    /// Capability scan — ask the firmware (VIA get_value 0x08) what parameters it exposes across
    /// channels/fields, plus the VIA protocol version (0x01). Replies print as "VIA-resp" lines.
    /// If only channel 3 / fields 1–4 answer, per-LED addressing is confirmed unavailable; if
    /// other channels/fields respond, there may be a direct-LED path worth chasing.
    func rgbProbe() {
        log("=== RGB capability probe START (exhaustive: ch 0–7, field 0–31) ===")
        viaProbing = true
        var q: [[UInt8]] = [[0x01]]                       // VIA protocol version
        for ch in 0...7 { for f in 0...31 { q.append([0x08, UInt8(ch), UInt8(f)]) } }
        probeQueue = q
        fireNextProbe()
    }
    private func fireNextProbe() {
        guard viaProbing else { return }
        if probeQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.viaProbing = false
                self?.log("=== RGB capability probe END ===")
            }
            return
        }
        let cmd = probeQueue.removeFirst()
        sendVIA(cmd[0], Array(cmd.dropFirst()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in self?.fireNextProbe() }
    }

    /// Standard QMK RGB-matrix effect names, in the default compiled order (matches what we've
    /// seen on this unit: 1=Solid, 13=Cycle Left/Right). 31 & 33–44 only react to keypresses.
    static func effectName(_ i: Int) -> String {
        let names = ["All Off", "Solid Color", "Alphas Mods", "Gradient Up/Down", "Gradient Left/Right",
            "Breathing", "Band Sat", "Band Val", "Pinwheel Sat", "Pinwheel Val", "Spiral Sat", "Spiral Val",
            "Cycle All", "Cycle Left/Right", "Cycle Up/Down", "Rainbow Moving Chevron", "Cycle Out/In",
            "Cycle Out/In Dual", "Cycle Pinwheel", "Cycle Spiral", "Dual Beacon", "Rainbow Beacon",
            "Rainbow Pinwheels", "Raindrops", "Jellybean Raindrops", "Hue Breathing", "Hue Pendulum",
            "Hue Wave", "Pixel Rain", "Pixel Flow", "Pixel Fractal", "Typing Heatmap", "Digital Rain",
            "Solid Reactive Simple", "Solid Reactive", "Solid Reactive Wide", "Solid Reactive Multi Wide",
            "Solid Reactive Cross", "Solid Reactive Multi Cross", "Solid Reactive Nexus",
            "Solid Reactive Multi Nexus", "Splash", "Multi Splash", "Solid Splash", "Solid Multi Splash"]
        return (i >= 0 && i < names.count) ? names[i] : "Effect \(i)"
    }

    /// Knob-driven effect browser: turn the knob to step effects one at a time (press to exit),
    /// dwelling on each as long as you like. Logs "effect N: <name>".
    func rgbBrowseStart() {
        rgbBrowseMode = true
        rgbBrowseIndex = 1
        rgbSetBrightness(220); rgbSetSpeed(140); rgbSetColor(hue: 0, sat: 255)
        log("=== RGB browse ON — turn the knob to step effects, press the knob to exit ===")
        showRgbBrowse()
    }
    private func showRgbBrowse() {
        rgbSetEffect(rgbBrowseIndex)
        log("effect \(rgbBrowseIndex): \(Self.effectName(rgbBrowseIndex))")
    }

    /// Effect tour — auto-step through every effect (~1.8s each), logging index + name.
    func rgbEffectTour() {
        log("=== RGB effect tour: stepping 0…44 (~1.8s each). ===")
        rgbSetBrightness(220); rgbSetSpeed(140); rgbSetColor(hue: 0, sat: 255)
        for i in 0...44 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.8) { [weak self] in
                self?.log("effect \(i): \(Self.effectName(i))")
                self?.rgbSetEffect(i)
            }
        }
    }

    /// One-shot visual test: off → solid red → green → blue → rainbow cycle → settle.
    /// Watch the ring; if it changes, global VIA control works on this unit.
    func rgbSelfTest() {
        log("RGB self-test starting")
        rgbSetEffect(0)                                                 // off first, so the change is obvious
        rgbSetBrightness(200)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.rgbSetEffect(1); self?.rgbSetColor(hue: 0, sat: 255) }  // solid red
        let q = DispatchQueue.main
        q.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.rgbSetColor(hue: 85, sat: 255) }   // green
        q.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.rgbSetColor(hue: 170, sat: 255) }  // blue
        q.asyncAfter(deadline: .now() + 4.5) { [weak self] in self?.rgbSetEffect(13); self?.rgbSetSpeed(150) }  // rainbow cycle
        q.asyncAfter(deadline: .now() + 7.5) { [weak self] in self?.rgbSetEffect(1); self?.rgbSetColor(hue: 128, sat: 255) }  // settle cyan
    }

    /// Build the device's 0xA3 short-command frame:
    /// [0xA3, data.count+1, opcode, ...data, (opcode + Σdata) % 255].
    private func a3Frame(opcode: UInt8, data: [UInt8]) -> [UInt8] {
        var f: [UInt8] = [0xA3, UInt8((data.count + 1) & 0xFF), opcode]
        f += data
        var sum = Int(opcode)
        for b in data { sum += Int(b) }
        f.append(UInt8(sum % 255))
        return f
    }

    @discardableResult
    private func writeOutput(_ bytes: [UInt8], to device: IOHIDDevice) -> Bool {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            // report id 0, output report — matches DK-Suite's node-hid write([0, ...frame]).
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, base, bytes.count) == kIOReturnSuccess
        }
    }

    private func emit(_ e: QuakeEvent) { onEvent?(e) }

    private func hex(_ b: [UInt8], _ n: Int) -> String {
        b.prefix(n).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - C callbacks (no captures, so they can bridge to @convention(c))

private let quakeDeviceAdded: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    let reader = Unmanaged<QuakeInputReader>.fromOpaque(context).takeUnretainedValue()
    let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
    let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? -1
    if vid == QuakeIDs.knobVID && pid == QuakeIDs.knobPID {
        reader.attach(device: device, kind: .knob)
    } else if vid == QuakeIDs.touchVID && pid == QuakeIDs.touchPID {
        reader.attach(device: device, kind: .touch)
    }
}

private let quakeDeviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    let reader = Unmanaged<QuakeInputReader>.fromOpaque(context).takeUnretainedValue()
    let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
    if vid == QuakeIDs.knobVID { reader.markRemoved(device: device, kind: .knob) }
    else if vid == QuakeIDs.touchVID { reader.markRemoved(device: device, kind: .touch) }
}

private let quakeReport: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
    guard let context else { return }
    let tag = Unmanaged<QuakeInputReader.DeviceTag>.fromOpaque(context).takeUnretainedValue()
    let n = Int(reportLength)
    let bytes = (0..<n).map { report[$0] }
    tag.reader.handle(kind: tag.kind, bytes: bytes)
}
