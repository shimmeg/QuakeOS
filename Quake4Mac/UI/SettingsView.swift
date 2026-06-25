// SettingsView.swift — Quake4Mac
//
// The app's Settings window (⌘,): connect Spotify (music screen queue/playlist + album art),
// pick the music style, and control the knob's RGB ring.

import SwiftUI
import AppKit
import Combine
import ScreenCaptureKit
import CoreMedia
import CoreAudio

struct SettingsView: View {
    @ObservedObject private var auth = SpotifyAuth.shared
    @ObservedObject private var rgb = RGBController.shared
    @ObservedObject private var react = RGBReactiveEngine.shared
    @AppStorage("music.style") private var musicStyle = "clean"   // "clean" | "vinyl"
    @State private var clientField = SpotifyAuth.shared.clientID
    @State private var pickColor = RGBController.shared.previewColor

    /// A labeled slider row with a caption and a 0–100% readout — used for the visualizer tuning.
    private func tuneSlider(_ title: String, caption: String,
                            value: Binding<Double>, range: ClosedRange<Double>,
                            readout: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(readout).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
            Text(caption).font(.caption2).foregroundColor(.secondary)
        }
    }

    /// Format a 0…1 fraction as a clamped whole-number percent.
    private func pct(_ f: Double) -> String { "\(Int((min(1, max(0, f))) * 100))%" }

    var body: some View {
        Form {
            Section("Knob RGB ring") {
                Picker("Effect", selection: $rgb.effect) {
                    ForEach(RGBController.effects, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }

                ColorPicker("Color", selection: $pickColor, supportsOpacity: false)
                    .onChange(of: pickColor) { newValue in rgb.setColor(newValue) }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Brightness").font(.caption).foregroundColor(.secondary)
                    Slider(value: $rgb.brightness, in: 1...255)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed").font(.caption).foregroundColor(.secondary)
                    Slider(value: $rgb.speed, in: 0...255)
                }

                HStack {
                    Button("Save to device") { rgb.saveToDevice() }
                    Spacer()
                    Button("Turn ring off") { rgb.effect = 0 }
                }

                Text("Changes apply live. “Save to device” stores the look on the knob so it persists "
                     + "even when the app is closed. Color applies to color-based effects; rainbow / "
                     + "sparkle effects pick their own colors.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Reactive lighting") {
                Toggle("Enable reactive lighting", isOn: $react.enabled)

                Toggle("Flash when the knob turns", isOn: $react.flashOnTurn)
                    .disabled(!react.enabled)
                HStack {
                    ColorPicker("Clockwise", selection: $react.cwColor, supportsOpacity: false)
                    ColorPicker("Counter-CW", selection: $react.ccwColor, supportsOpacity: false)
                }
                .disabled(!react.enabled || !react.flashOnTurn)

                Toggle("Flash when the knob is pressed", isOn: $react.flashOnClick)
                    .disabled(!react.enabled)
                ColorPicker("Press color", selection: $react.clickColor, supportsOpacity: false)
                    .disabled(!react.enabled || !react.flashOnClick)

                Divider()

                Text("Base lighting — rank the sources with the arrows; the highest one that's currently "
                     + "active wins the ring. Toggle each on or off. (Knob flashes and the CPU heat alert "
                     + "always sit on top of these.)")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                ForEach(Array(react.sourceOrder.enumerated()), id: \.element) { idx, id in
                    HStack(spacing: 10) {
                        VStack(spacing: 1) {
                            Button { react.moveSource(id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(!react.enabled || idx == 0)
                            Button { react.moveSource(id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(!react.enabled || idx == react.sourceOrder.count - 1)
                        }
                        .buttonStyle(.borderless).font(.caption2)
                        Text("\(idx + 1).").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        Toggle(RGBReactiveEngine.sourceName(id), isOn: react.sourceBinding(id))
                            .disabled(!react.enabled)
                    }
                }

                Text("Album color tints to the now-playing Spotify cover (only while something's playing). "
                     + "Beat visualizer pulses to any audio — it needs Screen Recording permission "
                     + "(System Settings ▸ Privacy ▸ Screen Recording), then quit & reopen. Page theme uses "
                     + "the per-page colors below.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                if react.enabled && react.pageTheme {
                    ForEach(react.pageThemeTitles, id: \.self) { title in
                        ColorPicker("\(title) color", selection: Binding(
                            get: { react.pageThemeColor(title) },
                            set: { react.setPageThemeColor($0, for: title) }
                        ), supportsOpacity: false)
                    }
                }

                if react.enabled && react.musicVisualizer {
                    Divider()
                    HStack {
                        Text("Visualizer tuning").font(.caption.bold()).foregroundColor(.secondary)
                        Spacer()
                        Button("Reset") {
                            react.vizSensitivity = 1.28; react.vizFloor = 30; react.vizTail = 0.82
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }

                    // Sensitivity — invert so dragging right fires on MORE beats (lower avg multiplier).
                    tuneSlider("Sensitivity", caption: "How easily a beat triggers a flash",
                               value: Binding(get: { (1.60 - react.vizSensitivity) / 0.50 },
                                              set: { react.vizSensitivity = 1.60 - $0 * 0.50 }),
                               range: 0...1, readout: pct((1.60 - react.vizSensitivity) / 0.50))

                    tuneSlider("Idle glow", caption: "Resting brightness between beats",
                               value: $react.vizFloor, range: 0...120, readout: pct(react.vizFloor / 120))

                    tuneSlider("Flash length", caption: "How long each beat lingers",
                               value: $react.vizTail, range: 0.70...0.92,
                               readout: pct((react.vizTail - 0.70) / 0.22))
                }

                Divider()

                Toggle("CPU heat alert", isOn: $react.cpuTint)
                    .disabled(!react.enabled)
                if react.enabled && react.cpuTint {
                    tuneSlider("Alert above", caption: "Blink a heat warning when the CPU passes this",
                               value: $react.cpuThreshold, range: 50...95,
                               readout: "\(Int(react.cpuThreshold)) °C")
                    Stepper("Blinks per set: \(react.cpuBlinkCount)", value: $react.cpuBlinkCount, in: 1...8)
                        .font(.caption)
                    tuneSlider("Between blinks", caption: "Spacing of the blinks within a set",
                               value: $react.cpuBlinkGap, range: 0.3...2.0,
                               readout: String(format: "%.1f s", react.cpuBlinkGap))
                    tuneSlider("Between sets", caption: "Rest before the alert repeats",
                               value: $react.cpuSetGap, range: 10...300,
                               readout: react.cpuSetGap >= 60
                                   ? String(format: "%.1f min", react.cpuSetGap / 60)
                                   : "\(Int(react.cpuSetGap)) s")
                }
                Text("When the CPU climbs past the threshold the ring fires a set of quick heat-color "
                     + "blinks (cool blue → hot red), hands back to your music or preset, then repeats the "
                     + "set after a rest — until it cools down. It sits on top of everything, including the "
                     + "visualizer. Try “Simulate CPU Heat Sweep” in the menu-bar icon to preview it.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Music style") {
                Picker("On-screen player", selection: $musicStyle) {
                    Text("Clean (album art + controls)").tag("clean")
                    Text("DecoKee vinyl").tag("vinyl")
                }
                .pickerStyle(.radioGroup)
            }

            Section("Spotify") {
                Text("For queue / playlists / album art. Create a free app at developer.spotify.com, "
                     + "add the redirect URI below, then paste the Client ID here.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                TextField("Client ID", text: $clientField)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Redirect URI:").font(.caption).foregroundColor(.secondary)
                    Text(SpotifyAuth.redirectURI).font(.caption.monospaced()).textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button(auth.isConnected ? "Reconnect" : "Connect Spotify") {
                        auth.saveClientID(clientField)
                        auth.connect()
                    }
                    if auth.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                        Button("Disconnect") { auth.disconnect() }
                    }
                }

                if !auth.lastError.isEmpty {
                    Text(auth.lastError).font(.caption).foregroundColor(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}

// MARK: - RGB ring controller
//
// Holds the knob ring settings, persists them, and applies them live via QuakeInput's VIA
// commands. Bridges the Settings window (which has no AppState) to the input reader, which sets
// `input` at launch. Only self-animating effects are offered (keypress-reactive 31, 33–44 do
// nothing on this hardware, so they're omitted).
final class RGBController: ObservableObject {
    static let shared = RGBController()

    /// Device interface; assigned by AppDelegate after `input.start()`.
    weak var input: QuakeInputReader?

    /// Curated working effects as (index, name) — 0–30 plus 32 (Digital Rain).
    static let effects: [(Int, String)] =
        (Array(0...30) + [32]).map { ($0, QuakeInputReader.effectName($0)) }

    @Published var effect: Int        { didSet { d.set(effect, forKey: K.effect); input?.rgbSetEffect(effect) } }
    @Published var hue: Double        { didSet { d.set(hue, forKey: K.hue); input?.rgbSetColor(hue: Int(hue), sat: Int(sat)) } }
    @Published var sat: Double        { didSet { d.set(sat, forKey: K.sat); input?.rgbSetColor(hue: Int(hue), sat: Int(sat)) } }
    @Published var brightness: Double { didSet { d.set(brightness, forKey: K.bri); input?.rgbSetBrightness(Int(brightness)) } }
    @Published var speed: Double      { didSet { d.set(speed, forKey: K.speed); input?.rgbSetSpeed(Int(speed)) } }

    private let d = UserDefaults.standard
    private enum K { static let effect = "rgb.effect", hue = "rgb.hue", sat = "rgb.sat", bri = "rgb.brightness", speed = "rgb.speed" }

    private init() {
        effect     = d.object(forKey: K.effect) as? Int    ?? 1     // Solid Color
        hue        = d.object(forKey: K.hue)    as? Double ?? 128
        sat        = d.object(forKey: K.sat)    as? Double ?? 255
        brightness = d.object(forKey: K.bri)    as? Double ?? 200
        speed      = d.object(forKey: K.speed)  as? Double ?? 140
    }

    /// Push the full saved profile to the device (call once the device is connected).
    func applyAll() {
        input?.rgbSetBrightness(Int(brightness))
        input?.rgbSetSpeed(Int(speed))
        input?.rgbSetColor(hue: Int(hue), sat: Int(sat))
        input?.rgbSetEffect(effect)
    }

    func saveToDevice() { input?.rgbSave() }

    /// Set hue/sat from a SwiftUI Color (QMK uses 0–255 hue & sat).
    func setColor(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        hue = Double(ns.hueComponent) * 255
        sat = Double(ns.saturationComponent) * 255
    }

    /// Swatch color for the picker (full brightness; QMK value is fixed).
    var previewColor: Color { Color(hue: hue / 255.0, saturation: sat / 255.0, brightness: 1.0) }
}

// MARK: - Live ring mirror (what's actually on the knob right now)
//
// Mirrors the LAST RGB command sent to the device — whether from the static RGBController OR the
// reactive engine (page-theme / album / CPU / flash). The settings knob preview reads this so it
// matches the physical knob even when Reactive Lighting is overriding the static look.

final class RGBLiveState: ObservableObject {
    static let shared = RGBLiveState()
    @Published var effect = 1
    @Published var hue = 128.0
    @Published var sat = 255.0
    @Published var brightness = 200.0
    @Published var speed = 140.0

    func setEffect(_ i: Int)      { onMain { if self.effect != i { self.effect = i } } }
    func setBrightness(_ v: Int)  { onMain { let d = Double(v); if self.brightness != d { self.brightness = d } } }
    func setSpeed(_ v: Int)       { onMain { let d = Double(v); if self.speed != d { self.speed = d } } }
    func setColor(h: Int, s: Int) { onMain { if self.hue != Double(h) { self.hue = Double(h) }; if self.sat != Double(s) { self.sat = Double(s) } } }

    private func onMain(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }
}

// MARK: - RGB ring draft session
//
// The RGB Ring editor edits a DRAFT shown live in the knob-ring preview (animated). Nothing reaches
// the physical knob until Save — mirroring the tile editor's draft/commit. While `active`, the
// preview ring reflects the draft; otherwise it reflects the committed (device) state.

final class RGBEditSession: ObservableObject {
    static let shared = RGBEditSession()
    @Published var effect: Int = 1
    @Published var hue: Double = 128
    @Published var sat: Double = 255
    @Published var brightness: Double = 200
    @Published var speed: Double = 140
    @Published var dirty = false
    @Published var active = false          // true while the RGB Ring editor is on screen

    private let c = RGBController.shared
    private init() { syncFromCommitted() }

    /// Pull the draft from the committed device state (call when the editor opens).
    func begin() { syncFromCommitted(); active = true }
    func end()   { active = false }

    private func syncFromCommitted() {
        effect = c.effect; hue = c.hue; sat = c.sat; brightness = c.brightness; speed = c.speed
        dirty = false
    }

    func setEffect(_ i: Int)        { effect = i; dirty = true }
    func setBrightness(_ v: Double) { brightness = v; dirty = true }
    func setSpeed(_ v: Double)      { speed = v; dirty = true }
    func setColor(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        hue = Double(ns.hueComponent) * 255; sat = Double(ns.saturationComponent) * 255; dirty = true
    }

    /// Commit the draft → device + persisted (RGBController applies on set).
    func save() {
        c.effect = effect; c.brightness = brightness; c.speed = speed; c.hue = hue; c.sat = sat
        c.saveToDevice()
        dirty = false
    }
    func revert() { syncFromCommitted() }

    var previewColor: Color { Color(hue: hue / 255.0, saturation: sat / 255.0, brightness: 1.0) }
}

// MARK: - Reactive lighting engine
//
// Drives the ring in response to events and app state.
//   • Transient flashes — knob turn/click briefly override the ring, then it returns to the base.
//   • Continuous sources — the "base" the ring rests on. Highest-priority active source wins;
//     music tint is the first (album-art colour while playing), with temp/theme to follow. When
//     no source is active (or reactive mode is off), the base is the user's chosen static look.
final class RGBReactiveEngine: ObservableObject {
    static let shared = RGBReactiveEngine()

    /// Device interface; assigned by AppDelegate after `input.start()`.
    weak var input: QuakeInputReader?
    /// Macro pad model; assigned by AppDelegate. Source of the current page's accent colour.
    weak var pad: PadModel?

    @Published var enabled: Bool      { didSet { d.set(enabled, forKey: "rgb.react.enabled"); syncSources() } }
    @Published var flashOnTurn: Bool  { didSet { d.set(flashOnTurn, forKey: "rgb.react.turn") } }
    @Published var flashOnClick: Bool { didSet { d.set(flashOnClick, forKey: "rgb.react.click") } }
    @Published var cwColor: Color     { didSet { saveColor(cwColor, "rgb.react.cw") } }
    @Published var ccwColor: Color    { didSet { saveColor(ccwColor, "rgb.react.ccw") } }
    @Published var clickColor: Color  { didSet { saveColor(clickColor, "rgb.react.clickColor") } }
    @Published var musicTint: Bool       { didSet { d.set(musicTint, forKey: "rgb.react.music"); syncSources() } }
    @Published var musicVisualizer: Bool { didSet { d.set(musicVisualizer, forKey: "rgb.react.viz"); syncSources() } }
    @Published var cpuTint: Bool         { didSet { d.set(cpuTint, forKey: "rgb.react.cpu"); syncSources() } }
    @Published var pageTheme: Bool       { didSet { d.set(pageTheme, forKey: "rgb.react.page"); syncSources() } }
    @Published var pageColors: [String: [Double]] { didSet { d.set(pageColors, forKey: "rgb.react.pagecolors") } }   // screen title → [h,s,b]
    @Published var sourceOrder: [String] { didSet { d.set(sourceOrder, forKey: "rgb.react.order") } }   // base priority, top = highest
    @Published var cpuThreshold: Double  { didSet { d.set(cpuThreshold, forKey: "rgb.react.cputhresh"); evaluateCPUAlert() } }
    @Published var cpuBlinkCount: Int    { didSet { d.set(cpuBlinkCount, forKey: "rgb.react.cpublinks") } }
    @Published var cpuBlinkGap: Double   { didSet { d.set(cpuBlinkGap, forKey: "rgb.react.cpublinkgap") } }   // sec between blinks in a set
    @Published var cpuSetGap: Double     { didSet { d.set(cpuSetGap, forKey: "rgb.react.cpusetgap") } }       // sec between sets

    // Beat-visualizer tuning — live-bound to sliders; pushed to the running capture on change.
    @Published var vizSensitivity: Double { didSet { d.set(vizSensitivity, forKey: "rgb.viz.sens");  pushVizTuning() } }
    @Published var vizFloor: Double       { didSet { d.set(vizFloor,       forKey: "rgb.viz.floor"); pushVizTuning() } }
    @Published var vizTail: Double        { didSet { d.set(vizTail,        forKey: "rgb.viz.tail");  pushVizTuning() } }

    private let d = UserDefaults.standard
    private var revert: DispatchWorkItem?
    private var viz: AnyObject?
    private var vizTap: AnyObject?      // Core Audio process tap (macOS 14.4+, DRM-safe)

    // Music source state
    private var musicSub: AnyCancellable?
    private var lastArt = ""
    private var lastPlaying = false
    private var musicHueSat: (Int, Int)?
    private var artCache: [String: (Int, Int)] = [:]

    // CPU-temp source — a periodic "it's hot" alert that briefly preempts the music/preset base,
    // then hands back, re-pulsing while the die stays above the threshold (sooner the hotter it is).
    private var cpuTimer: Timer?            // sensor poll
    private var lastCPUTemp: Double?        // latest reading (real or simulated)
    private var cpuCycleActive = false      // currently above threshold and blinking
    private var cpuAlerting = false         // a blink is lit on the ring right now
    private var cpuNextAlert: DispatchWorkItem?   // scheduler for the next blink set
    private var cpuSimulating = false       // menu-bar demo: compressed cadence

    // Page-theme source state
    private var pageSub: AnyCancellable?
    private var lastPageAccent: Color?

    private init() {
        enabled      = d.object(forKey: "rgb.react.enabled") as? Bool ?? false
        flashOnTurn  = d.object(forKey: "rgb.react.turn")    as? Bool ?? true
        flashOnClick = d.object(forKey: "rgb.react.click")   as? Bool ?? true
        musicTint    = d.object(forKey: "rgb.react.music")   as? Bool ?? false
        musicVisualizer = d.object(forKey: "rgb.react.viz")  as? Bool ?? false
        cpuTint      = d.object(forKey: "rgb.react.cpu")     as? Bool ?? false
        pageTheme    = d.object(forKey: "rgb.react.page")    as? Bool ?? false
        pageColors   = (d.dictionary(forKey: "rgb.react.pagecolors") as? [String: [Double]]) ?? [:]
        // Base priority order; sanitize against the known sources so it always holds exactly them.
        let known = ["visualizer", "album", "page"]
        let saved = (d.array(forKey: "rgb.react.order") as? [String]) ?? known
        sourceOrder = saved.filter(known.contains) + known.filter { !saved.contains($0) }
        cpuThreshold = d.object(forKey: "rgb.react.cputhresh") as? Double ?? 70
        cpuBlinkCount = d.object(forKey: "rgb.react.cpublinks")   as? Int ?? 3
        cpuBlinkGap   = d.object(forKey: "rgb.react.cpublinkgap") as? Double ?? 1.0
        cpuSetGap     = d.object(forKey: "rgb.react.cpusetgap")   as? Double ?? 60
        vizSensitivity = d.object(forKey: "rgb.viz.sens")  as? Double ?? 1.28
        vizFloor       = d.object(forKey: "rgb.viz.floor") as? Double ?? 30
        vizTail        = d.object(forKey: "rgb.viz.tail")  as? Double ?? 0.82
        cwColor    = RGBReactiveEngine.loadColor("rgb.react.cw",         fallback: .green)
        ccwColor   = RGBReactiveEngine.loadColor("rgb.react.ccw",        fallback: .red)
        clickColor = RGBReactiveEngine.loadColor("rgb.react.clickColor", fallback: .blue)
    }

    /// Call once the device is connected (from AppDelegate): start any enabled sources and paint
    /// the initial base.
    func activate() { syncSources() }

    /// Called for every knob/touch event (from AppState's input handler).
    func handle(_ e: QuakeEvent) {
        guard enabled else { return }
        switch e {
        case .knobClockwise        where flashOnTurn:  flash(cwColor)
        case .knobCounterClockwise where flashOnTurn:  flash(ccwColor)
        case .knobPress            where flashOnClick: flash(clickColor)
        default: break
        }
    }

    /// Start/stop the continuous sources to match the current settings, then repaint the base.
    private func syncSources() {
        // Each base source runs whenever its own toggle is on; the priority list (winningSource)
        // decides which one actually paints, so they no longer exclude one another.
        if enabled && musicVisualizer { startViz() } else { stopViz() }
        if enabled && musicTint { startMusic() } else { stopMusic() }
        if enabled && cpuTint { startCPU() } else { stopCPU() }
        if enabled && pageTheme { startPageTheme() } else { stopPageTheme() }
        applyBase()
    }

    // MARK: Base-source priority (drag-ranked in Settings)
    enum Base: String { case visualizer, album, page }
    static func sourceName(_ id: String) -> String {
        switch id {
        case "visualizer": return "Beat visualizer"
        case "album":      return "Album color"
        case "page":       return "Page theme"
        default:           return id
        }
    }
    private func sourceEnabled(_ b: Base) -> Bool {
        switch b { case .visualizer: return musicVisualizer; case .album: return musicTint; case .page: return pageTheme }
    }
    /// Is this source currently able to paint something meaningful?
    private func sourceActive(_ b: Base) -> Bool {
        switch b {
        case .visualizer: return true                              // drives the ring live whenever enabled
        case .album:      return SpotifyClient.shared.isPlaying && musicHueSat != nil
        case .page:       return pad != nil
        }
    }
    /// Highest-ranked source that is both enabled and active — the one that owns the base right now.
    func winningSource() -> Base? {
        for raw in sourceOrder {
            if let b = Base(rawValue: raw), sourceEnabled(b), sourceActive(b) { return b }
        }
        return nil
    }
    /// Move a source up (-1) or down (+1) the priority list.
    func moveSource(_ id: String, by delta: Int) {
        guard let i = sourceOrder.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < sourceOrder.count else { return }
        sourceOrder.swapAt(i, j)
        applyBase()
    }
    /// Toggle binding for a source row, routed to the matching published flag.
    func sourceBinding(_ id: String) -> Binding<Bool> {
        switch id {
        case "visualizer": return Binding(get: { self.musicVisualizer }, set: { self.musicVisualizer = $0 })
        case "album":      return Binding(get: { self.musicTint },       set: { self.musicTint = $0 })
        case "page":       return Binding(get: { self.pageTheme },       set: { self.pageTheme = $0 })
        default:           return .constant(false)
        }
    }

    // MARK: Base — a CPU heat pulse (if active) owns the ring; else the top-ranked enabled+active
    // source (visualizer / album / page theme); else the user's static look.
    func applyBase() {
        if cpuAlerting { return }                                  // a heat pulse is showing — leave it
        guard enabled else { RGBController.shared.applyAll(); return }
        switch winningSource() {
        case .visualizer:
            return                                                 // the visualizer paints itself live
        case .album:
            if let (h, s) = musicHueSat {
                input?.rgbSetEffect(1)
                input?.rgbSetColor(hue: h, sat: s)
                input?.rgbSetBrightness(Int(RGBController.shared.brightness))
            }
        case .page:
            if let pad = pad {
                let (h, s) = RGBReactiveEngine.hsv(pageThemeColor(pad.currentScreenTitle))
                input?.rgbSetEffect(1)
                input?.rgbSetColor(hue: h, sat: s)
                input?.rgbSetBrightness(Int(RGBController.shared.brightness))
            }
        case nil:
            RGBController.shared.applyAll()                        // static preset
        }
    }

    private func flash(_ color: Color) {
        let (h, s) = RGBReactiveEngine.hsv(color)
        // Always re-assert Solid here. (We tried skipping this when RGBLiveState.effect==1, but that
        // mirror tracks the last-ATTEMPTED send and defaults to 1, so after a cold boot / reattach where
        // the effect write was dropped the ring can physically be on a saved non-solid effect while the
        // mirror reads 1 — the flash would then paint colour onto the wrong effect. The extra write is
        // cheap now that per-write logging is gone, so correctness wins.)
        input?.rgbSetEffect(1)                 // Solid Color
        input?.rgbSetColor(hue: h, sat: s)
        input?.rgbSetBrightness(255)
        revert?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.winningSource() != .visualizer { self.applyBase() }   // viz repaints itself live
        }
        revert = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: w)
    }

    // MARK: Beat visualizer source (system audio → live colour + brightness)
    private func startViz() {
        guard viz == nil else { return }
        guard #available(macOS 13.0, *) else { return }
        let v = AudioVisualizer()
        v.sensitivity = Float(vizSensitivity); v.floor = Float(vizFloor); v.tail = Float(vizTail)
        v.onUpdate = { [weak self] hue, bright in self?.applyViz(hue: hue, bright: bright) }
        input?.rgbSetEffect(1)                                  // Solid Color; we modulate it live
        if #available(macOS 14.4, *) {
            // DRM-safe: capture system audio via a Core Audio process tap (no screen capture), so
            // protected video (Netflix etc.) keeps playing while the visualizer runs.
            let tap = SystemAudioTap()
            tap.onSamples = { [weak v] p, n in v?.ingest(p, n) }
            tap.start()
            vizTap = tap
        } else {
            v.start()                                          // ScreenCaptureKit fallback (< macOS 14.4)
        }
        viz = v
    }

    /// Push the current tuning to a running capture so slider changes take effect instantly.
    private func pushVizTuning() {
        guard #available(macOS 13.0, *), let v = viz as? AudioVisualizer else { return }
        v.sensitivity = Float(vizSensitivity); v.floor = Float(vizFloor); v.tail = Float(vizTail)
    }
    private func stopViz() {
        if #available(macOS 14.4, *), let t = vizTap as? SystemAudioTap { t.stop() }
        vizTap = nil
        if #available(macOS 13.0, *), let v = viz as? AudioVisualizer { v.stop() }
        viz = nil
    }
    private func applyViz(hue: Int, bright: Int) {
        // Only paint when the visualizer is actually the winning source and no heat pulse is up.
        guard enabled, !cpuAlerting, winningSource() == .visualizer else { return }
        input?.rgbSetColor(hue: hue, sat: 255)
        input?.rgbSetBrightness(bright)
    }

    // MARK: Music tint source
    private func startMusic() {
        guard musicSub == nil else { return }
        SpotifyClient.shared.pinned = true
        SpotifyClient.shared.start()
        musicSub = SpotifyClient.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.musicChanged() }   // read values after they update
        }
        musicChanged()
    }
    private func stopMusic() {
        guard musicSub != nil || SpotifyClient.shared.pinned else { return }
        musicSub = nil
        SpotifyClient.shared.pinned = false
        musicHueSat = nil; lastArt = ""; lastPlaying = false
    }

    // MARK: Page-theme source — ring reflects the accent of the on-screen page.
    private func startPageTheme() {
        guard pageSub == nil, let pad = pad else { return }
        lastPageAccent = nil                                       // force a repaint on (re)start
        // The pad publishes on every interaction (touches, switcher); only repaint when the page's
        // accent actually changes, so we don't spam the ring over USB.
        pageSub = pad.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.pageChanged() }
        }
        pageChanged()
    }
    private func stopPageTheme() {
        pageSub = nil; lastPageAccent = nil
    }
    private func pageChanged() {
        guard pageTheme, let pad = pad else { return }
        let accent = pageThemeColor(pad.currentScreenTitle)
        guard accent != lastPageAccent else { return }
        lastPageAccent = accent
        applyBase()
    }

    /// Screen titles to offer colour pickers for (the tile pages, then Stats + Music).
    var pageThemeTitles: [String] { pad?.screenTitles ?? [] }

    /// The colour chosen for a screen, falling back to a sensible per-screen default.
    func pageThemeColor(_ title: String) -> Color {
        if let a = pageColors[title], a.count == 3 {
            return Color(hue: a[0], saturation: a[1], brightness: a[2])
        }
        return RGBReactiveEngine.defaultPageColor(title)
    }
    /// Persist a screen's chosen colour and repaint immediately if it's the page on screen now.
    func setPageThemeColor(_ c: Color, for title: String) {
        let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? .white
        pageColors[title] = [Double(ns.hueComponent), Double(ns.saturationComponent), Double(ns.brightnessComponent)]
        lastPageAccent = nil
        if pad?.currentScreenTitle == title { applyBase() }
    }
    static func defaultPageColor(_ title: String) -> Color {
        switch title {
        case "Stats":  return .cyan        // DecoKee's cyan monitor theme
        case "Music":  return .green       // Spotify green
        case "System": return .orange
        case "Web":    return .blue
        default:       return .purple
        }
    }

    // MARK: CPU-temp source — periodic heat-alert blinks
    //
    // While the die sits above the threshold, fire a set of quick heat-colour blinks, hand the ring
    // back to the music/preset base, then repeat the set after a rest — until it cools back under the
    // threshold. Blinks-per-set, in-set spacing, and rest-between-sets are all user-configurable.
    private func startCPU() {
        guard cpuTimer == nil else { return }
        // Thermals must be read on the main thread; poll every 2s (sensor values are cached/cheap).
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.readCPUTint() }
        t.tolerance = 0.4   // coalesce wakeups; a heat-alert poll doesn't need exact 2s spacing
        cpuTimer = t
        readCPUTint()
    }
    private func stopCPU() {
        cpuTimer?.invalidate(); cpuTimer = nil
        cpuCycleActive = false
        cpuNextAlert?.cancel(); cpuNextAlert = nil
        lastCPUTemp = nil
        if cpuAlerting { cpuAlerting = false; applyBase() }
    }
    private func readCPUTint() {
        guard !cpuSimulating else { return }                       // the demo drives lastCPUTemp itself
        lastCPUTemp = Thermals.shared.cpuTemp()
        evaluateCPUAlert()
    }

    /// Start or stop the heat-alert cycle based on the latest temperature crossing the threshold.
    private func evaluateCPUAlert() {
        guard cpuSimulating || (enabled && cpuTint), let t = lastCPUTemp else { endCPUCycle(); return }
        if t >= cpuThreshold {
            if !cpuCycleActive { cpuCycleActive = true; fireCPUBlinkSet() }   // crossed the line → start blinking
        } else {
            endCPUCycle()                                          // cooled → stop scheduling more pulses
        }
    }

    /// Fire one set of quick heat blinks, then queue the next set if the CPU is still hot.
    /// The music/preset base is suppressed for the WHOLE set (start of blink 1 → end of the last
    /// blink): the in-set gaps go dark, not back to music, so the alert reads as its own thing.
    /// Blinks-per-set, in-set spacing, and the rest between sets are all user-configurable.
    private func fireCPUBlinkSet() {
        guard let t = lastCPUTemp else { return }
        cpuNextAlert?.cancel()
        let hue = RGBReactiveEngine.tempToHue(t)
        let count = max(1, cpuBlinkCount)
        let gap = max(0.2, cpuBlinkGap)                            // seconds between blink onsets
        let on = min(0.2, gap * 0.5)                               // quick on-time per blink
        let bright = Int(RGBController.shared.brightness)

        let lead = 1.0, tail = 1.0                                 // dark padding so blinks never blend into music

        cpuAlerting = true                                         // hold off music/visualizer for the whole set
        input?.rgbSetEffect(1)
        input?.rgbSetBrightness(0)                                 // go dark immediately for the 1s lead-in
        for i in 0..<count {
            let at = lead + Double(i) * gap
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in   // blink ON
                guard let self, self.cpuCycleActive else { return }
                self.input?.rgbSetColor(hue: hue, sat: 255)
                self.input?.rgbSetBrightness(bright)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + at + on) { [weak self] in   // blink OFF → dark gap
                guard let self, self.cpuCycleActive else { return }
                self.input?.rgbSetBrightness(0)
            }
        }
        let lastOff = lead + Double(count - 1) * gap + on
        // 1s tail of darkness after the final blink, then release the ring back to music / preset.
        DispatchQueue.main.asyncAfter(deadline: .now() + lastOff + tail) { [weak self] in
            guard let self else { return }
            self.cpuAlerting = false
            self.applyBase()
        }
        // Queue the next set after the configured rest (compressed during the demo).
        let setSpan = lastOff + tail
        let rest = cpuSimulating ? min(cpuSetGap, 3.0) : cpuSetGap
        let next = DispatchWorkItem { [weak self] in
            guard let self, self.cpuCycleActive,
                  let t = self.lastCPUTemp, t >= self.cpuThreshold else { return }
            self.fireCPUBlinkSet()
        }
        cpuNextAlert = next
        DispatchQueue.main.asyncAfter(deadline: .now() + setSpan + rest, execute: next)
    }
    private func endCPUCycle() {
        cpuCycleActive = false
        cpuNextAlert?.cancel(); cpuNextAlert = nil
        // an in-progress pulse finishes on its own and restores the base
    }

    /// Map a CPU temperature to a ring hue: 170 (cool blue) at ≤35 °C → 0 (hot red) at ≥85 °C.
    static func tempToHue(_ temp: Double) -> Int {
        let frac = (max(35.0, min(85.0, temp)) - 35.0) / 50.0      // 0 cool … 1 hot
        return Int((1 - frac) * 170)
    }

    /// Demo/test (menu bar): fake the die warming past the threshold and back so you can watch the
    /// heat alert pulse the ring a couple of times (compressed cadence) and hand back to the
    /// music/preset base between pulses — without actually heating the CPU. Works even if the CPU
    /// source toggle is off, so it's a pure preview.
    func simulateCPUSweep() {
        cpuSimulating = true
        endCPUCycle()
        // Scripted temps over ~18s: cool → hot (blink sets fire & recur) → cool (they stop).
        let script: [(Double, Double)] = [(0, 50), (2, 85), (14, 50)]
        for (at, temp) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self else { return }
                self.lastCPUTemp = temp
                self.evaluateCPUAlert()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in
            guard let self else { return }
            self.cpuSimulating = false
            self.lastCPUTemp = nil
            self.syncSources()                                     // resume the real sensor poller
        }
    }
    private func musicChanged() {
        guard musicTint else { return }
        let art = SpotifyClient.shared.art ?? ""
        let playing = SpotifyClient.shared.isPlaying
        if art != lastArt {
            lastArt = art
            if art.isEmpty { musicHueSat = nil; applyBase() }
            else if let c = artCache[art] { musicHueSat = c; applyBase() }
            else { fetchArtColor(art) }
        }
        if playing != lastPlaying { lastPlaying = playing; applyBase() }
    }
    private func fetchArtColor(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {                                  // render + apply on main
                guard let self else { return }
                let hs = RGBReactiveEngine.vibrantHueSat(img)
                self.artCache[urlStr] = hs
                if self.lastArt == urlStr { self.musicHueSat = hs; self.applyBase() }
            }
        }.resume()
    }

    /// Dominant "pop" colour of an image → QMK hue/sat. Renders to a tiny bitmap and picks the
    /// most vivid pixel (max saturation × brightness).
    static func vibrantHueSat(_ image: NSImage) -> (Int, Int) {
        let w = 20, h = 20
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return (0, 255) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        var best = -1.0, bh = 0.0, bs = 0.0
        for y in 0..<h { for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let s = Double(c.saturationComponent), b = Double(c.brightnessComponent)
            let score = s * b
            if score > best { best = score; bh = Double(c.hueComponent); bs = s }
        } }
        return (Int(bh * 255), Int(max(0.5, bs) * 255))   // floor saturation so it's never washed out
    }

    // MARK: Color <-> storage (QMK hue/sat are 0…255)
    static func hsv(_ color: Color) -> (Int, Int) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return (Int(ns.hueComponent * 255), Int(ns.saturationComponent * 255))
    }
    private func saveColor(_ c: Color, _ key: String) {
        let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? .white
        d.set([Double(ns.hueComponent), Double(ns.saturationComponent), Double(ns.brightnessComponent)], forKey: key)
    }
    private static func loadColor(_ key: String, fallback: Color) -> Color {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Double], a.count == 3 else { return fallback }
        return Color(hue: a[0], saturation: a[1], brightness: a[2])
    }
}

// MARK: - Beat visualizer (system audio capture)
//
// Captures system audio with ScreenCaptureKit (needs Screen Recording permission), measures
// loudness + a cheap bass/treble split each buffer, and emits a (hue, brightness) ~20×/sec:
// brightness follows loudness with a punch on beats; hue drifts from warm (bass) to cool (treble).
// Single-zone — the whole ring is one colour (no per-LED), like a single Govee bulb in music mode.
// Everything is guarded so a capture/permission failure just logs and no-ops; it never crashes.
@available(macOS 13.0, *)
final class AudioVisualizer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onUpdate: ((Int, Int) -> Void)?

    // Live-tunable from the UI. Set on main, read on the audio queue — a 32-bit Float read is
    // atomic on 64-bit, so the worst case is one buffer using a slightly stale value. No lock needed.
    var sensitivity: Float = 1.28     // beat trigger: avg multiplier — lower fires on more beats
    var floor: Float = 30             // resting brightness (0…120) — higher = brighter idle glow
    var tail: Float = 0.82            // pulse decay per buffer (0.70…0.92) — higher = longer flash

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.quake4mac.audioviz")

    private var level: Float = 0          // smoothed loudness (fast attack / slow decay)
    private var avg: Float = 0.0005       // moving average for beat detection
    private var lpState: Float = 0        // one-pole low-pass accumulator (bass proxy)
    private var hue: Float = 0.0
    private var pulse: Float = 0          // beat flash; decays each buffer
    private var lastBeat = Date.distantPast
    private var lastEmit = Date.distantPast

    func start() { Task { await begin() } }

    private func begin() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { NSLog("[Quake] viz: no display"); return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.width = 100; cfg.height = 100              // we only take the audio output; keep video tiny
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            NSLog("[Quake] viz: system-audio capture started")
        } catch {
            NSLog("[Quake] viz: start failed — \(error.localizedDescription) (grant Screen Recording, then restart)")
        }
    }

    func stop() {
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Quake] viz: stopped — \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        var energy: Float = 0, bass: Float = 0, treble: Float = 0
        var count = 0
        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                for buffer in abl {
                    guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    var lp = lpState
                    for i in 0..<n {
                        let x = p[i]
                        lp += 0.05 * (x - lp)              // one-pole low-pass ≈ bass
                        let hi = x - lp                    // remainder ≈ treble
                        energy += x * x; bass += lp * lp; treble += hi * hi; count += 1
                    }
                    lpState = lp
                }
            }
        } catch { return }
        guard count > 0 else { return }
        let rms = (energy / Float(count)).squareRoot()
        process(rms: rms,
                bass: (bass / Float(count)).squareRoot(),
                treble: (treble / Float(count)).squareRoot())
    }

    /// Feed raw interleaved float samples from ANY source (SCStream or the Core Audio tap) into the
    /// same beat/colour analysis. One process() call per chunk.
    func ingest(_ p: UnsafePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        var energy: Float = 0, bass: Float = 0, treble: Float = 0
        var lp = lpState
        for i in 0..<n {
            let x = p[i]
            lp += 0.05 * (x - lp)
            let hi = x - lp
            energy += x * x; bass += lp * lp; treble += hi * hi
        }
        lpState = lp
        let rms = (energy / Float(n)).squareRoot()
        process(rms: rms, bass: (bass / Float(n)).squareRoot(), treble: (treble / Float(n)).squareRoot())
    }

    private func process(rms: Float, bass: Float, treble: Float) {
        level = rms > level ? rms : level * 0.85 + rms * 0.15      // fast attack, slow decay
        avg = avg * 0.96 + rms * 0.04                              // slower avg → real beats stay above it in busy sections

        // Beat = energy spike above the moving average, with a refractory gap so each
        // pulse can decay before the next fires — keeps individual beats distinct.
        let now = Date()
        if rms > avg * sensitivity, rms > 0.006, now.timeIntervalSince(lastBeat) > 0.10 {
            pulse = 1.0; lastBeat = now
        }
        pulse *= tail                                              // decay → sharp flash with a short tail

        // Hue: slow, subtle drift so the colour is stable enough to read the brightness beats.
        let ratio = treble / (bass + treble + 1e-6)                // 0 (bass) … 1 (treble)
        hue += 0.03 * ((ratio * 0.6) - hue)

        // Brightness: a modest baseline that leaves lots of headroom, which the beat pulse
        // punches up into. (Device caps the brightness field at ~199, so 255 = hardware max;
        // the pop comes from keeping the non-beat floor low, not from raising the ceiling.)
        let norm = min(1, level * 5)
        let ambientGain = min(1, floor / 20)                     // fade the loudness glow out as idle→0
        let baseline = min(180, floor + norm * 110 * ambientGain) // floor 0 ⇒ dark between beats; beats still flash
        let bright = baseline + pulse * (255 - baseline)          // beats punch toward max

        guard now.timeIntervalSince(lastEmit) > 0.05 else { return }   // ~20 fps to the ring
        lastEmit = now
        let h = Int(max(0, min(1, hue)) * 255), b = Int(max(0, min(255, bright)))
        DispatchQueue.main.async { self.onUpdate?(h, b) }
    }
}

// MARK: - DRM-safe system-audio capture (Core Audio process tap, macOS 14.4+)
//
// ScreenCaptureKit counts as screen capture, so DRM players (Netflix, Apple TV, etc.) blank their
// video while the beat visualizer runs. A Core Audio *process tap* captures system audio WITHOUT
// any screen capture — so protected video keeps playing. We feed its samples into the same
// AudioVisualizer analysis. Used on 14.4+; older macOS falls back to the ScreenCaptureKit path.
@available(macOS 14.4, *)
final class SystemAudioTap {
    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private let q = DispatchQueue(label: "com.quake4mac.audiotap")

    func start() {
        // Global tap of all system audio (exclude nothing → whatever is playing).
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { NSLog("[Quake] tap: create failed"); return }
        tapID = tap

        // Read the tap's UID to attach it to a private aggregate device.
        var uid = "" as CFString
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        guard withUnsafeMutablePointer(to: &uid, { AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, $0) }) == noErr else {
            NSLog("[Quake] tap: UID read failed"); return
        }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Quake4Mac Beat Tap",
            kAudioAggregateDeviceUIDKey: "com.quake4mac.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uid,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var agg = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else {
            NSLog("[Quake] tap: aggregate failed"); return
        }
        aggID = agg

        var proc: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, q) { [weak self] _, inInput, _, _, _ in
            self?.handle(inInput)
        }
        guard st == noErr, let proc else { NSLog("[Quake] tap: ioproc failed (\(st))"); return }
        ioProc = proc
        AudioDeviceStart(aggID, proc)
        NSLog("[Quake] viz: Core Audio tap started (DRM-safe, no screen capture)")
    }

    private func handle(_ data: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        for buf in abl {
            guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            if n > 0 { onSamples?(p, n) }   // already on our serial queue, off the realtime thread
        }
    }

    func stop() {
        if let proc = ioProc { AudioDeviceStop(aggID, proc); AudioDeviceDestroyIOProcID(aggID, proc); ioProc = nil }
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }
}
