// Quake4MacApp.swift — Quake4Mac (Xcode app entry, Phase 1)
//
// SwiftUI App lifecycle + an AppKit delegate that pins a borderless fullscreen
// window to the Quake's HDMI display. The Settings scene is empty on purpose —
// we don't want a default app window; the delegate makes our own on the right screen.

import SwiftUI
import AppKit
import Combine
import IOKit.pwr_mgt

// MARK: - App-wide state

final class AppState: ObservableObject {
    let input = QuakeInputReader()
    lazy var pad = PadModel(input: input)
    @Published var displayInfo: String = "—"

    private var c1: AnyCancellable?
    private var c2: AnyCancellable?
    init() {
        // Re-publish the reader's + pad's @Published changes so views observing AppState update.
        c1 = input.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        c2 = pad.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Route knob + touch events into the macro pad and the reactive RGB engine.
        input.onEvent = { [weak self] event in
            self?.pad.handle(event)
            RGBReactiveEngine.shared.handle(event)
        }
    }
}

// MARK: - Display pinning

enum QuakeDisplay {
    /// The Quake screen, identified by STABLE identity — its name ("DK-QUAKE") or its distinctive
    /// ~1920×480 panel size. Returns nil when the panel isn't currently connected. NB: we do NOT
    /// fall back to "widest external" at runtime — that, plus excluding NSScreen.main, caused the
    /// window to oscillate onto (and hijack) other monitors. Overridable via QUAKE_SCREEN.
    static func screen() -> NSScreen? {
        let screens = NSScreen.screens
        if let raw = ProcessInfo.processInfo.environment["QUAKE_SCREEN"],
           let i = Int(raw), i >= 0, i < screens.count {
            return screens[i]
        }
        if let s = screens.first(where: { $0.localizedName.uppercased().contains("QUAKE") }) { return s }
        if let s = screens.first(where: { isPanelSize($0.frame.size) }) { return s }
        return nil
    }

    /// Launch-time choice: the real Quake if present, else a safe fallback so we still have a window.
    static func pickOrFallback() -> NSScreen {
        screen() ?? NSScreen.main ?? NSScreen.screens.first!
    }

    /// The panel is ~1920×480 (either orientation), distinct from every normal monitor.
    private static func isPanelSize(_ sz: CGSize) -> Bool {
        let long = max(sz.width, sz.height), short = min(sz.width, sz.height)
        return abs(long - 1920) <= 8 && abs(short - 480) <= 8
    }

    static func describe(_ s: NSScreen) -> String {
        let f = s.frame
        return String(format: "%@  %.0f×%.0f  @(%.0f,%.0f)%@",
                      s.localizedName, f.width, f.height, f.origin.x, f.origin.y,
                      (s == NSScreen.main) ? "  [main]" : "")
    }
}

// MARK: - Borderless window that can still take focus

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App delegate (creates the window on the Quake display)

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var newSettingsWindow: NSWindow?     // redesigned Settings (in development, alongside the old)

    func applicationDidFinishLaunching(_ note: Notification) {
        let err = FileHandle.standardError
        func log(_ s: String) { err.write(("[Quake] " + s + "\n").data(using: .utf8)!) }

        let screens = NSScreen.screens
        log("launched. \(screens.count) screen(s):")
        for (i, s) in screens.enumerated() { log("  [\(i)] \(QuakeDisplay.describe(s))") }

        let screen = QuakeDisplay.pickOrFallback()
        state.displayInfo = QuakeDisplay.describe(screen)
        log("rendering on: \(state.displayInfo)  (override with QUAKE_SCREEN=<index>)")

        let win = KeyableWindow(contentRect: screen.frame,
                                styleMask: [.borderless],
                                backing: .buffered,
                                defer: false)
        // NB: at/near CGShieldingWindowLevel, current macOS renders only the window's
        // backgroundColor and skips compositing the content view entirely (whole panel
        // black). .screenSaver stays on top of normal windows but composites normally.
        win.level = .screenSaver
        win.isOpaque = true
        win.backgroundColor = .black
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.setFrame(screen.frame, display: true)
        win.contentView = NSHostingView(rootView: ContentView().environmentObject(state))
        win.makeKeyAndOrderFront(nil)
        window = win

        let prefs = UserDefaults.standard
        // Menu-bar-only hides the Dock icon (General → Startup & Menu Bar).
        NSApp.setActivationPolicy((prefs.object(forKey: "settings.menuBarOnly") as? Bool ?? false) ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
        state.input.start()

        // Pre-warm every on-device panel webview at launch so first open is instant (no loading splash)
        // and each panel keeps refreshing in the background while you're elsewhere. Deferred one run-loop
        // turn so the visible window paints before three 1920×480 WKWebViews (+ WebContent XPC) spin up.
        DispatchQueue.main.async { PanelWarmer.warmAll() }
        // Knob RGB ring: hand the controller + reactive engine the device, then restore the saved
        // look once the device has finished attaching (matching/open is async, ~1s after start()).
        RGBController.shared.input = state.input
        RGBReactiveEngine.shared.input = state.input
        RGBReactiveEngine.shared.pad = state.pad        // for the "page theme" reactive source
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { RGBReactiveEngine.shared.activate() }

        // Keep the panel awake: stop macOS idle-sleeping the Quake display out from under us.
        preventDisplaySleep()

        // The panel sometimes drops/returns (HDMI link, sleep). When the display set
        // changes, re-pick the Quake screen and re-pin the window onto it so it recovers.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleReattach() }

        setupMenuBar()

        // Open the Settings UI on launch (toggle in General) — the on-device window lives on the
        // Quake panel, so without this there's no visible app window on the user's monitors.
        if prefs.object(forKey: "settings.openAtLaunch") as? Bool ?? true {
            DispatchQueue.main.async { [weak self] in self?.openSettingsNew() }
        }
    }

    // "Keep running in the background" (default on) → stay alive in the menu bar after the last
    // window closes; off → quit when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "settings.runInBackground") as? Bool ?? true)
    }

    // A top-right menu-bar icon — reliable Settings access (the Dock icon doesn't activate
    // us because our only window lives on the Quake display).
    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                                     accessibilityDescription: "Quake4Mac")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Open Settings…", action: #selector(openSettingsMenuAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let newSettings = NSMenuItem(title: "Settings (new design)…", action: #selector(openSettingsNewAction), keyEquivalent: "")
        newSettings.target = self
        menu.addItem(newSettings)
        if UserDefaults.standard.bool(forKey: "settings.developerMode") {
            menu.addItem(.separator())
            let debugMenu = NSMenu()
            let rgbTest = NSMenuItem(title: "Test RGB Ring", action: #selector(testRGBMenuAction), keyEquivalent: "")
            rgbTest.target = self
            debugMenu.addItem(rgbTest)
            let rgbProbe = NSMenuItem(title: "Probe RGB Capability", action: #selector(probeRGBMenuAction), keyEquivalent: "")
            rgbProbe.target = self
            debugMenu.addItem(rgbProbe)
            let rgbTour = NSMenuItem(title: "Tour RGB Effects", action: #selector(tourRGBMenuAction), keyEquivalent: "")
            rgbTour.target = self
            debugMenu.addItem(rgbTour)
            let rgbBrowse = NSMenuItem(title: "Browse RGB Effects (knob)", action: #selector(browseRGBMenuAction), keyEquivalent: "")
            rgbBrowse.target = self
            debugMenu.addItem(rgbBrowse)
            let cpuSweep = NSMenuItem(title: "Simulate CPU Heat Sweep", action: #selector(cpuSweepMenuAction), keyEquivalent: "")
            cpuSweep.target = self
            debugMenu.addItem(cpuSweep)
            let debug = NSMenuItem(title: "Developer Device Actions", action: nil, keyEquivalent: "")
            debug.submenu = debugMenu
            menu.addItem(debug)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Quake4Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettingsMenuAction() { openSettings() }
    @objc private func openSettingsNewAction() { openSettingsNew() }
    @objc private func testRGBMenuAction() { guardDeveloperMode { state.input.rgbSelfTest() } }
    @objc private func probeRGBMenuAction() { guardDeveloperMode { state.input.rgbProbe() } }
    @objc private func tourRGBMenuAction() { guardDeveloperMode { state.input.rgbEffectTour() } }
    @objc private func browseRGBMenuAction() { guardDeveloperMode { state.input.rgbBrowseStart() } }
    @objc private func cpuSweepMenuAction() { guardDeveloperMode { RGBReactiveEngine.shared.simulateCPUSweep() } }

    private func guardDeveloperMode(_ action: () -> Void) {
        guard UserDefaults.standard.bool(forKey: "settings.developerMode") else {
            log("developer device action blocked: enable Developer Mode first")
            return
        }
        action()
    }

    private var sleepAssertion: IOPMAssertionID = 0
    private func preventDisplaySleep() {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Quake4Mac panel active" as CFString,
                                    &sleepAssertion)
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(("[Quake] " + s + "\n").data(using: .utf8)!)
    }

    // Coalesce bursts of didChangeScreenParameters (HDMI link blips fire several rapidly) so we
    // settle once instead of thrashing — the thrash was what flickered the window and hit audio.
    private var reattachWork: DispatchWorkItem?
    private func scheduleReattach() {
        reattachWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reattachToQuake() }
        reattachWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Re-pin the borderless window onto the Quake display — but only when it's actually present
    /// and not already correct. Never moves the window onto another monitor.
    private func reattachToQuake() {
        guard let win = window else { return }
        guard let screen = QuakeDisplay.screen() else {
            // Panel not connected right now: leave the window where it is rather than hijacking
            // another display. It'll re-pin when the Quake comes back.
            log("Quake display absent — leaving window in place")
            return
        }
        state.displayInfo = QuakeDisplay.describe(screen)
        // Already on the right screen at the right size → do nothing (prevents the re-pin loop).
        if win.screen == screen, win.frame == screen.frame { return }
        log("re-pinning to \(state.displayInfo)")
        win.setFrame(screen.frame, display: true)
        win.orderFront(nil)            // order front WITHOUT becoming key — avoids changing
                                       // NSScreen.main, which previously fed the oscillation.
        state.input.wakePanel()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // Our only on-screen window is the borderless panel on the Quake display, so a Dock
    // click had nothing to show. Make it activate the app and open Settings (where you
    // connect Spotify), and also expose it via the standard ⌘, menu item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        return true
    }

    // macOS 14 disabled the programmatic `showSettingsWindow:` selector (it just logs
    // "Please use SettingsLink…" and does nothing), and there's no AppKit call to open a SwiftUI
    // Settings scene. So we host SettingsView in our own window and show it directly — reliable
    // from the menu-bar item and the Dock.
    /// A real monitor to host settings windows on — never the Quake panel (tiny/offscreen for UI).
    static func settingsScreen() -> NSScreen {
        func isQuake(_ s: NSScreen) -> Bool {
            if s.localizedName.uppercased().contains("QUAKE") { return true }
            let long = max(s.frame.width, s.frame.height), short = min(s.frame.width, s.frame.height)
            return abs(long - 1920) <= 8 && abs(short - 480) <= 8
        }
        if let m = NSScreen.main, !isQuake(m) { return m }
        if let s = NSScreen.screens.first(where: { !isQuake($0) }) { return s }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Quake4Mac Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 480, height: 620))
            let vf = AppDelegate.settingsScreen().visibleFrame
            let f = w.frame
            w.setFrameOrigin(NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2))
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    /// The redesigned (dark-neon) Settings, in its own larger window. Lives alongside the classic
    /// window during the refactor so nothing regresses; will replace it once at parity.
    func openSettingsNew() {
        NSApp.activate(ignoringOtherApps: true)
        if newSettingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsRootView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Quake4Mac"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            // Open on a REAL monitor, never the Quake panel (it's tiny/offscreen for UI), and keep
            // the window fully on that screen.
            let target = AppDelegate.settingsScreen()
            let vf = target.visibleFrame
            // Roomy default so the left nav, content, and the right inspector rail all fit at launch.
            w.setContentSize(NSSize(width: min(1720, vf.width - 40), height: min(1000, vf.height - 40)))
            w.contentMinSize = NSSize(width: 1080, height: 640)   // keeps the fixed-width preview + collapsed layout intact
            let f = w.frame
            w.setFrameOrigin(NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2))
            newSettingsWindow = w
        }
        newSettingsWindow?.makeKeyAndOrderFront(nil)
        newSettingsWindow?.orderFrontRegardless()
    }
}

// MARK: - Entry point

@main
struct Quake4MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { SettingsView() }   // ⌘, opens this; the delegate owns the on-device window
    }
}
