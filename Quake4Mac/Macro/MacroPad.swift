// MacroPad.swift — Quake4Mac (Phase 2)
//
// The actual shortcut pad: pages of glowing tiles laid out on the Quake's ultra-wide
// panel. Touch a tile to fire its action; turn the knob to flip pages; press the knob
// to jump home. Everything is data-driven (see PadModel.defaultPages) so it's easy to
// extend into a user-editable config later.

import SwiftUI
import AppKit
import Combine

// MARK: - Model

enum PadAction {
    case launchApp(bundleID: String)   // open an app by bundle identifier
    case openURL(String)               // open a URL in the default browser
    case shell(String)                 // run a shell command (/bin/zsh -lc)
    case appleScript(String)           // run an AppleScript snippet
    case luminance(delta: Int)         // nudge the Quake panel backlight
    case openPage(String)              // jump to another Quake page (by name)
    case none
}

// A page can be a tile grid (the default), a live web dashboard, or a bundled "app" screen
// (Clock, etc.). Keeps the "page = app" abstraction clean as we add open-quake / DK-Suite presets.
enum PadPageKind: Equatable {
    case grid                  // 8×2 tile grid (current behaviour)
    case web(url: String)      // full-screen web dashboard
    case app(id: String)       // a bundled renderer, keyed by id ("clock", …)
}

// What a home-screen app icon opens (the OS layer). Springboard home → tap an icon → open one
// of these fullscreen; knob press returns home.
enum AppDest: Equatable {
    case macroPage(String)     // one of the tile-grid pages, by name
    case panel(String)         // a built-in panel: "clock" | "music" | "monitor"
    case builtin(String)       // an on-device app: "settings" | "wallpaper" | "browser" (stubs for now)
}

struct Tile: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String          // SF Symbol fallback
    let tint: Color
    let action: PadAction
    var image: String? = nil    // DecoKee PNG glyph name (in bundle Icons/), used verbatim when set
    var editable: Bool = false  // false = built-in preset (Safari, Music, …) → action not editable

    /// Bundle id when this tile launches an app — lets the tile show the real macOS app icon.
    var appBundleID: String? {
        if case let .launchApp(bid) = action { return bid }
        return nil
    }

    /// The URL when this tile opens a web page — lets the tile show the site's brand favicon.
    var openURLValue: String? {
        if case let .openURL(u) = action { return u }
        return nil
    }
}

struct PadPage: Identifiable {
    let id = UUID()
    var name: String
    var tiles: [Tile]
    var kind: PadPageKind = .grid
}

final class PadModel: ObservableObject {
    static let cols = 8          // 8×2 on the 1920×480 panel → square cells (like DecoKee)
    static let rows = 2
    static let perPage = cols * rows

    @Published var pageIndex = 0
    @Published var pressedTileID: UUID? = nil
    @Published var lastFired: String = ""

    private unowned let input: QuakeInputReader
    private var storeSub: AnyCancellable?

    /// Pages come from the shared, persisted store so the device, the settings preview, and the
    /// Tile Editor all stay in sync; edits there re-render the pad live.
    var pages: [PadPage] { PadStore.shared.pages }

    init(input: QuakeInputReader) {
        self.input = input
        storeSub = PadStore.shared.$pages.sink { [weak self] _ in
            self?.normalizePageIndex()
            self?.objectWillChange.send()
        }
        applyStartup()
    }

    private var safePageIndex: Int {
        min(max(0, pageIndex), max(0, screenCount - 1))
    }

    private func normalizePageIndex() {
        let clamped = safePageIndex
        if pageIndex != clamped { pageIndex = clamped }
    }

    var current: PadPage {
        let source = pages.isEmpty ? PadModel.defaultPages() : pages
        return source[min(max(0, safePageIndex), source.count - 1)]
    }

    // Screens = the tile pages, then trailing "extra" widget screens (built-in panels).
    enum Extra: Equatable { case monitor, music, clock, weather }
    let extras: [Extra] = [.monitor, .music, .clock, .weather]

    var screenCount: Int { pages.count + extras.count }
    var isTilePage: Bool { safePageIndex < pages.count }
    var extra: Extra? {
        guard !isTilePage else { return nil }
        let i = safePageIndex - pages.count
        return extras.indices.contains(i) ? extras[i] : nil
    }

    /// The kind of the current screen (grid for the trailing extras).
    var currentKind: PadPageKind { isTilePage ? current.kind : .grid }
    /// Only a grid page hit-tests tiles; web/app pages route raw touches to their screen view.
    var isGridPage: Bool { isTilePage && current.kind == .grid }
    /// True only when the open app is a macro tile-grid (so taps activate tiles). Panels and
    /// built-in apps route their touches to ScreenTouchRouter instead.
    var inMacroGrid: Bool { if case .macroPage = currentDest { return isGridPage }; return false }

    // MARK: OS navigation (springboard home + open apps)
    //
    // The device boots to a home screen of app icons. Tapping an icon opens that app fullscreen
    // (setting pageIndex so the existing renderers keep working); a knob press returns home. Which
    // screen we open at launch is a General setting (home / a specific app / last opened).

    @Published var onHome = true
    @Published var homePage = 0
    @Published var currentDest: AppDest? = nil
    @Published var recents: [AppDest] = []        // app history, most-recent LAST (rightmost in the switcher)
    private var homeStart: CGPoint?
    private var homeLast: CGPoint?
    private var switStart: CGPoint?
    private var switLast: CGPoint?
    private var switcherTimer: Timer?
    // Home edit ("jiggle") mode: hold an icon to enter, drag to rearrange, knob/tap-empty to exit.
    @Published var editMode = false
    @Published var draggingSlot: Int? = nil
    @Published var dragPoint: CGPoint? = nil
    private var longPressTimer: Timer?
    private var edgeTimer: Timer?
    private var edgeDir = 0

    func setHomePage(_ p: Int) { let n = max(1, HomeStore.shared.pages.count); homePage = min(max(0, p), n - 1) }
    func goHome() { onHome = true; editMode = false; draggingSlot = nil; dragPoint = nil; saveLastNav() }

    func openApp(_ dest: AppDest) {
        switch dest {
        case .macroPage(let name): if let i = pages.firstIndex(where: { $0.name == name }) { pageIndex = i }
        case .panel(let id):
            let ex: Extra = id == "monitor" ? .monitor : id == "music" ? .music : id == "weather" ? .weather : .clock
            if let k = extras.firstIndex(of: ex) { pageIndex = pages.count + k }
        case .builtin: break
        }
        currentDest = dest
        onHome = false
        switcherOpen = false
        editMode = false; draggingSlot = nil; dragPoint = nil
        switcherTimer?.invalidate()
        recents.removeAll { $0 == dest }            // move to most-recent (end)
        recents.append(dest)
        if recents.count > 8 { recents.removeFirst(recents.count - 8) }
        saveLastNav()
    }

    // MARK: App switcher (knob-driven recents carousel)
    private func openOrMoveSwitcher(_ d: Int) {
        guard !recents.isEmpty else { return }
        if !switcherOpen { switcherOpen = true; switcherIndex = recents.count - 1 }
        else { switcherIndex = min(max(0, switcherIndex + d), recents.count - 1) }
        resetSwitcherTimer()
    }
    private func commitSwitcher() {
        switcherTimer?.invalidate()
        guard recents.indices.contains(switcherIndex) else { switcherOpen = false; return }
        let d = recents[switcherIndex]
        switcherOpen = false
        openApp(d)
    }
    private func endSwitcherTouch() {
        defer { switStart = nil; switLast = nil }
        guard let s = switStart, let e = switLast else { return }
        let dx = e.x - s.x
        if abs(dx) > 0.12 {                          // swipe scrubs the carousel
            switcherIndex = min(max(0, switcherIndex + (dx < 0 ? 1 : -1)), recents.count - 1)
            resetSwitcherTimer()
        } else { commitSwitcher() }                  // tap opens the highlighted app
    }
    private func resetSwitcherTimer() {
        switcherTimer?.invalidate()
        switcherTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in self?.switcherOpen = false }
    }

    private func homeTouchEnded() {
        defer { homeStart = nil; homeLast = nil }
        guard let s = homeStart, let e = homeLast else { return }
        let dx = e.x - s.x
        if abs(dx) > 0.12 { setHomePage(homePage + (dx < 0 ? 1 : -1)); return }   // swipe → change page
        // Map the tap into the icon-grid region (same insets the home view lays out with).
        let M = HomeLayoutMetrics.self
        let gx = (s.x - M.sideFrac) / (1 - 2 * M.sideFrac)
        let gy = (s.y - M.topFrac) / (1 - M.topFrac - M.bottomFrac)
        guard gx >= 0, gx <= 1, gy >= 0, gy <= 1 else { return }
        let col = min(max(Int(gx * CGFloat(M.cols)), 0), M.cols - 1)
        let row = min(max(Int(gy * CGFloat(M.rows)), 0), M.rows - 1)
        if let app = HomeStore.shared.app(page: homePage, slot: row * M.cols + col) { openApp(app.dest) }
    }

    // MARK: Home edit ("jiggle") mode
    func exitEditMode() { editMode = false; draggingSlot = nil; dragPoint = nil; longPressTimer?.invalidate(); edgeTimer?.invalidate(); edgeDir = 0 }

    /// Carry the dragged icon to the adjacent page (creating one past the last page).
    private func performEdgeMove(_ dir: Int) {
        guard editMode, let from = draggingSlot else { return }
        let cur = homePage
        var target = cur + dir
        if target < 0 { edgeDir = 0; return }
        if target >= HomeStore.shared.pages.count {
            guard dir > 0 else { edgeDir = 0; return }
            HomeStore.shared.addPage(); target = HomeStore.shared.pages.count - 1
        }
        guard let app = HomeStore.shared.app(page: cur, slot: from) else { edgeDir = 0; return }
        HomeStore.shared.removeApp(page: cur, at: from)
        HomeStore.shared.addApp(app, toPage: target)
        homePage = target
        draggingSlot = max(0, HomeStore.shared.pages[target].count - 1)
        edgeDir = 0
    }

    /// Slot index under a normalized point, using the same grid insets the home view lays out with.
    private func homeSlot(at p: CGPoint) -> Int {
        let M = HomeLayoutMetrics.self
        let gx = (p.x - M.sideFrac) / (1 - 2 * M.sideFrac)
        let gy = (p.y - M.topFrac) / (1 - M.topFrac - M.bottomFrac)
        let col = min(max(Int(gx * CGFloat(M.cols)), 0), M.cols - 1)
        let row = min(max(Int(gy * CGFloat(M.rows)), 0), M.rows - 1)
        return row * M.cols + col
    }

    private func homeBegan(_ p: CGPoint) {
        homeStart = p; homeLast = p
        if editMode {
            let s = homeSlot(at: p)
            if HomeStore.shared.app(page: homePage, slot: s) != nil { draggingSlot = s; dragPoint = p }
        } else {
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in self?.beginEditDrag() }
        }
    }

    private func beginEditDrag() {
        guard onHome, let s = homeStart else { return }
        editMode = true
        let slot = homeSlot(at: s)
        if HomeStore.shared.app(page: homePage, slot: slot) != nil { draggingSlot = slot; dragPoint = s }
    }

    private func homeMoved(_ p: CGPoint) {
        homeLast = p
        if editMode {
            guard let cur = draggingSlot, HomeStore.shared.pages.indices.contains(homePage) else { return }
            dragPoint = p
            let n = HomeStore.shared.pages[homePage].count
            let target = min(homeSlot(at: p), max(0, n - 1))
            if target != cur { HomeStore.shared.moveApp(page: homePage, from: cur, to: target); draggingSlot = target }
            // Hold at the left/right edge → carry the icon to the adjacent page.
            if p.x < 0.05 || p.x > 0.95 {
                let dir = p.x < 0.05 ? -1 : 1
                if edgeDir != dir {
                    edgeDir = dir; edgeTimer?.invalidate()
                    edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.performEdgeMove(dir) }
                }
            } else { edgeDir = 0; edgeTimer?.invalidate() }
        } else if let s = homeStart, max(abs(p.x - s.x), abs(p.y - s.y)) > 0.03 {
            longPressTimer?.invalidate()       // moved → it's a swipe, not a hold
        }
    }

    private func homeEnded() {
        longPressTimer?.invalidate()
        edgeTimer?.invalidate(); edgeDir = 0
        if editMode {
            if draggingSlot != nil { draggingSlot = nil; dragPoint = nil }            // drop
            else if let s = homeStart, HomeStore.shared.app(page: homePage, slot: homeSlot(at: s)) == nil { exitEditMode() }  // tap empty → exit
            homeStart = nil; homeLast = nil
        } else {
            homeTouchEnded()
        }
    }

    /// Resolve the launch screen from the General "open at launch" setting.
    func applyStartup() {
        let target = UserDefaults.standard.string(forKey: "startup.target") ?? "home"
        switch target {
        case "home": onHome = true; homePage = 0
        case "last":
            if let key = UserDefaults.standard.string(forKey: "nav.last"), key != "home",
               let d = AppDest(storageKey: key) { openApp(d) } else { onHome = true }
        default:
            if let d = AppDest(storageKey: target) { openApp(d) } else { onHome = true }
        }
    }
    private func saveLastNav() {
        UserDefaults.standard.set(onHome ? "home" : (currentDest?.storageKey ?? "home"), forKey: "nav.last")
    }

    /// Names of every screen, in order, for the radial switcher.
    /// (Monitor screen is "Stats" so it doesn't collide with the "System" macro page.)
    var screenTitles: [String] { pages.map { $0.name } + ["Stats", "Music", "Clock", "Weather"] }

    /// Title of the current screen (matches `screenTitles`) — the key the reactive RGB "page theme"
    /// source uses to look up the colour the user picked for this page.
    var currentScreenTitle: String {
        if onHome { return "Home" }
        let t = screenTitles
        return t[min(max(0, safePageIndex), t.count - 1)]
    }

    // Retained for the (currently unused) radial-switcher overlay; the knob now drives Home/app nav.
    @Published var switcherOpen = false
    @Published var switcherIndex = 0

    // MARK: Input handling (called from QuakeInputReader.onEvent, on the main run loop)
    //
    // Knob press = Home (like an iPhone home button). On Home: rotate or swipe changes home page,
    // tap opens an app. In an app: grid pages hit-test tiles; other panels route touches to their
    // screen view (scroll / clock-swipe).

    func handle(_ e: QuakeEvent) {
        switch e {
        case .knobClockwise:        openOrMoveSwitcher(+1)   // open / scrub the recents app switcher
        case .knobCounterClockwise: openOrMoveSwitcher(-1)
        case .knobPress:
            if editMode { exitEditMode() }                  // exit jiggle mode (like iPhone home)
            else if switcherOpen { commitSwitcher() }       // open the highlighted app
            else if onHome { setHomePage(0) }
            else { goHome() }                               // home button
        case .touchBegan(let p):
            if switcherOpen { switStart = p; switLast = p }
            else if onHome { homeBegan(p) }
            else if inMacroGrid { activate(at: p) }
            else { ScreenTouchRouter.shared.onBegan?(p) }
        case .touchEnded:
            pressedTileID = nil
            if switcherOpen { endSwitcherTouch() }
            else if onHome { homeEnded() }
            else if !inMacroGrid { ScreenTouchRouter.shared.onEnded?() }
        case .touchMoved(let p):
            if switcherOpen { switLast = p }
            else if onHome { homeMoved(p) }
            else if !inMacroGrid { ScreenTouchRouter.shared.onMoved?(p) }
        }
    }

    private func activate(at p: CGPoint) {
        let col = min(max(Int(p.x * CGFloat(Self.cols)), 0), Self.cols - 1)
        let row = min(max(Int(p.y * CGFloat(Self.rows)), 0), Self.rows - 1)
        let idx = row * Self.cols + col
        guard idx < current.tiles.count else { return }
        let tile = current.tiles[idx]
        log("tile \(current.name)[\(idx)] \(tile.title) → \(tile.action.logDescription)")
        pressedTileID = tile.id
        lastFired = tile.title
        run(tile.action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            if self?.pressedTileID == tile.id { self?.pressedTileID = nil }
        }
    }

    // MARK: Action execution

    private func run(_ a: PadAction) {
        MacroActionExecutor.execute(
            a,
            input: input,
            openPage: { [weak self] name in
                guard let self else { return }
                if let i = pages.firstIndex(where: { $0.name == name }) { pageIndex = i }
            },
            log: { [weak self] message in self?.log(message) }
        )
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(("[Quake] " + s + "\n").data(using: .utf8)!)
    }

    // MARK: Default content (3 starter pages)

    static func defaultPages() -> [PadPage] {
        let apps = PadPage(name: "Apps", tiles: [
            Tile(title: "Safari",   symbol: "safari.fill",     tint: .blue,    action: .launchApp(bundleID: "com.apple.Safari")),
            Tile(title: "Mail",     symbol: "envelope.fill",   tint: .cyan,    action: .launchApp(bundleID: "com.apple.mail")),
            Tile(title: "Messages", symbol: "message.fill",    tint: .green,   action: .launchApp(bundleID: "com.apple.MobileSMS")),
            Tile(title: "Notes",    symbol: "note.text",       tint: .yellow,  action: .launchApp(bundleID: "com.apple.Notes")),
            Tile(title: "Music",    symbol: "music.note",      tint: .pink,    action: .launchApp(bundleID: "com.apple.Music")),
            Tile(title: "Calendar", symbol: "calendar",        tint: .red,     action: .launchApp(bundleID: "com.apple.iCal")),
            Tile(title: "Finder",   symbol: "folder.fill",     tint: .blue,    action: .launchApp(bundleID: "com.apple.finder")),
            Tile(title: "Terminal", symbol: "terminal.fill",   tint: .gray,    action: .launchApp(bundleID: "com.apple.Terminal")),
            Tile(title: "Photos",   symbol: "photo.fill",      tint: .orange,  action: .launchApp(bundleID: "com.apple.Photos")),
            Tile(title: "Settings", symbol: "gearshape.fill",  tint: .gray,    action: .launchApp(bundleID: "com.apple.systempreferences")),
            Tile(title: "Maps",     symbol: "map.fill",        tint: .green,   action: .launchApp(bundleID: "com.apple.Maps")),
            Tile(title: "FaceTime", symbol: "video.fill",      tint: .green,   action: .launchApp(bundleID: "com.apple.FaceTime")),
            Tile(title: "Reminders",symbol: "checklist",       tint: .orange,  action: .launchApp(bundleID: "com.apple.reminders")),
            Tile(title: "Calculator",symbol: "plusminus",      tint: .gray,    action: .launchApp(bundleID: "com.apple.calculator")),
            Tile(title: "App Store",symbol: "bag.fill",        tint: .blue,    action: .launchApp(bundleID: "com.apple.AppStore")),
            Tile(title: "Preview",  symbol: "doc.richtext",    tint: .blue,    action: .launchApp(bundleID: "com.apple.Preview")),
        ])

        // Force Quit = ⌘⌥Esc ; Spotlight = ⌘Space ; volume via AppleScript.
        let forceQuit = "tell application \"System Events\" to key code 53 using {command down, option down}"
        let spotlight = "tell application \"System Events\" to keystroke space using command down"
        let volUp = "set volume output volume ((output volume of (get volume settings)) + 12)"
        let volDown = "set volume output volume ((output volume of (get volume settings)) - 12)"
        let muteToggle = "set volume output muted (not (output muted of (get volume settings)))"
        let micToggle = """
        set inputVol to input volume of (get volume settings)
        if inputVol > 0 then
            set volume input volume 0
        else
            set volume input volume 50
        end if
        """

        // System page — uses DecoKee's OWN icon PNGs (image:) mapped to real macOS actions.
        let system = PadPage(name: "System", tiles: [
            Tile(title: "Screen +",   symbol: "sun.max.fill",   tint: .orange, action: .luminance(delta: 26),  image: "brightest"),
            Tile(title: "Screen –",   symbol: "sun.min.fill",   tint: .orange, action: .luminance(delta: -26), image: "darkest"),
            Tile(title: "Settings",   symbol: "gearshape.fill", tint: .gray,   action: .launchApp(bundleID: "com.apple.systempreferences"), image: "control_panel"),
            Tile(title: "Activity",   symbol: "cpu",            tint: .green,  action: .shell("open -a 'Activity Monitor'"), image: "cpu_info"),
            Tile(title: "Music",      symbol: "music.note",     tint: .pink,   action: .launchApp(bundleID: "com.apple.Music"), image: "media"),
            Tile(title: "Spotlight",  symbol: "magnifyingglass",tint: .blue,   action: .appleScript(spotlight), image: "global_search"),
            Tile(title: "Screenshot", symbol: "camera.viewfinder", tint: .teal, action: .shell("screencapture -i -c"), image: "clip_board"),
            Tile(title: "Downloads",  symbol: "folder.fill",    tint: .blue,   action: .shell("open ~/Downloads"), image: "folder"),
            Tile(title: "Force Quit", symbol: "xmark.octagon.fill", tint: .red, action: .appleScript(forceQuit), image: "force_quit"),
            Tile(title: "Sleep",      symbol: "moon.fill",      tint: .gray,   action: .shell("pmset displaysleepnow"), image: "lock_screen"),
            Tile(title: "Vol +",      symbol: "speaker.wave.3.fill", tint: .indigo, action: .appleScript(volUp)),
            Tile(title: "Vol –",      symbol: "speaker.wave.1.fill", tint: .indigo, action: .appleScript(volDown)),
            Tile(title: "Mute",       symbol: "speaker.slash.fill",  tint: .purple, action: .appleScript(muteToggle), image: "buzzer_off"),
            Tile(title: "Mission",    symbol: "rectangle.3.group.fill", tint: .teal, action: .shell("open -a 'Mission Control'")),
            Tile(title: "Buzzer",     symbol: "bell.fill",      tint: .yellow, action: .none, image: "buzzer"),
            Tile(title: "Mic",        symbol: "mic.fill",       tint: .purple, action: .appleScript(micToggle), image: "device_mic"),
        ])

        let web = PadPage(name: "Web", tiles: [
            Tile(title: "Google",  symbol: "magnifyingglass",  tint: .blue,   action: .openURL("https://www.google.com")),
            Tile(title: "YouTube", symbol: "play.rectangle.fill", tint: .red, action: .openURL("https://www.youtube.com")),
            Tile(title: "GitHub",  symbol: "chevron.left.forwardslash.chevron.right", tint: .gray, action: .openURL("https://github.com")),
            Tile(title: "Gmail",   symbol: "envelope.fill",    tint: .red,    action: .openURL("https://mail.google.com")),
            Tile(title: "ChatGPT", symbol: "bubble.left.fill", tint: .green,  action: .openURL("https://chat.openai.com"), image: "chatgpt"),
            Tile(title: "Maps",    symbol: "map.fill",         tint: .green,  action: .openURL("https://maps.google.com")),
            Tile(title: "Reddit",  symbol: "bubble.left.and.bubble.right.fill", tint: .orange, action: .openURL("https://www.reddit.com")),
            Tile(title: "X",       symbol: "xmark",            tint: .gray,   action: .openURL("https://x.com")),
            Tile(title: "Wikipedia",symbol: "book.fill",       tint: .gray,   action: .openURL("https://wikipedia.org")),
            Tile(title: "Amazon",  symbol: "cart.fill",        tint: .yellow, action: .openURL("https://www.amazon.com")),
            Tile(title: "Netflix", symbol: "play.tv.fill",     tint: .red,    action: .openURL("https://www.netflix.com")),
            Tile(title: "Spotify", symbol: "music.note",       tint: .green,  action: .openURL("https://open.spotify.com")),
            Tile(title: "Twitch",  symbol: "gamecontroller.fill", tint: .purple, action: .openURL("https://www.twitch.tv")),
            Tile(title: "LinkedIn",symbol: "person.2.fill",    tint: .blue,   action: .openURL("https://www.linkedin.com")),
            Tile(title: "Stack",   symbol: "square.stack.3d.up.fill", tint: .orange, action: .openURL("https://stackoverflow.com")),
            Tile(title: "Discord", symbol: "bubble.left.fill", tint: .indigo, action: .openURL("https://discord.com")),
        ])

        return [apps, system, web]
    }
}

private extension PadAction {
    var logDescription: String {
        switch self {
        case .launchApp(let bid): return "launchApp(\(bid))"
        case .openURL:            return "openURL"
        case .shell:              return "shell"
        case .appleScript:        return "appleScript"
        case .luminance(let d):   return "luminance(\(d))"
        case .openPage(let name): return "openPage(\(name))"
        case .none:               return "none"
        }
    }
}

// MARK: - Persisted, editable page store
//
// Single source of truth for the macro pages. The live pad (PadModel), the settings live-preview,
// and the Tile Editor all read this; edits persist to JSON in Application Support and publish live.

final class PadStore: ObservableObject {
    static let shared = PadStore()
    /// The COMMITTED pages — what the device shows and what's on disk. The Tile Editor works on a
    /// separate draft (TileEditSession) and only calls `replace` on Save, so the Quake never changes
    /// until you explicitly save.
    @Published var pages: [PadPage]
    /// Bumped on every commit so the device renderer knows to re-push.
    @Published var version = 0

    private init() {
        let loaded = PadStore.load() ?? PadModel.defaultPages()
        let normalized = PadStore.normalizedPages(loaded)
        pages = normalized
        if normalized.count != loaded.count || loaded.isEmpty { save() }
    }

    /// Commit a whole new set of pages (the editor's saved draft) → device + disk.
    func replace(_ newPages: [PadPage]) {
        pages = PadStore.normalizedPages(newPages)
        version += 1
        save()
    }

    /// Replace the tile in a slot (nil = clear to an empty slot). Pads the row if needed.
    func setTile(page: Int, slot: Int, _ tile: Tile?) {
        guard pages.indices.contains(page), slot >= 0, slot < PadModel.perPage else { return }
        var tiles = pages[page].tiles
        while tiles.count <= slot { tiles.append(PadStore.emptyTile) }
        tiles[slot] = tile ?? PadStore.emptyTile
        pages[page].tiles = tiles
        save()
    }

    func renamePage(_ page: Int, to name: String) {
        guard pages.indices.contains(page) else { return }
        pages[page].name = name
        save()
    }

    static let emptyTile = Tile(title: "", symbol: "square.dashed", tint: .gray, action: .none)

    // MARK: Persistence (JSON in Application Support/Quake4Mac/pages.json)
    private static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
                   ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Quake4Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pages.json")
    }
    func save() {
        if let data = try? JSONEncoder().encode(pages.map(PageDTO.init)) {
            try? data.write(to: PadStore.fileURL)
        }
    }
    private static func load() -> [PadPage]? {
        guard let data = try? Data(contentsOf: fileURL),
              let dto = try? JSONDecoder().decode([PageDTO].self, from: data) else { return nil }
        return dto.map { $0.toPage() }
    }

    private static func normalizedPages(_ input: [PadPage]) -> [PadPage] {
        var out = input
        // Clock moved to a built-in panel — strip any old Clock page seeded into pages.json.
        out.removeAll { if case .app("clock") = $0.kind { return true }; return false }
        return out.isEmpty ? PadModel.defaultPages() : out
    }
}

// MARK: - Codable DTOs (Color → hex, PadAction flattened)

private struct ActionDTO: Codable {
    var kind: String; var s: String?; var i: Int?
    init(_ a: PadAction) {
        switch a {
        case .launchApp(let b):   kind = "app";     s = b
        case .openURL(let u):     kind = "url";     s = u
        case .shell(let c):       kind = "shell";   s = c
        case .appleScript(let x): kind = "ascript"; s = x
        case .luminance(let d):   kind = "lum";     i = d
        case .openPage(let n):    kind = "page";    s = n
        case .none:               kind = "none"
        }
    }
    var action: PadAction {
        switch kind {
        case "app":     return .launchApp(bundleID: s ?? "")
        case "url":     return .openURL(s ?? "")
        case "shell":   return .shell(s ?? "")
        case "ascript": return .appleScript(s ?? "")
        case "lum":     return .luminance(delta: i ?? 0)
        case "page":    return .openPage(s ?? "")
        default:        return .none
        }
    }
}
private struct TileDTO: Codable {
    var title: String; var symbol: String; var tintHex: String; var image: String?; var action: ActionDTO
    var editable: Bool?     // optional → old pages.json (without it) still decodes (defaults to preset)
    init(_ t: Tile) { title = t.title; symbol = t.symbol; tintHex = t.tint.hexRGB; image = t.image; action = ActionDTO(t.action); editable = t.editable }
    func toTile() -> Tile { Tile(title: title, symbol: symbol, tint: Color(hexRGB: tintHex), action: action.action, image: image, editable: editable ?? false) }
}
private struct PageDTO: Codable {
    var name: String; var tiles: [TileDTO]
    var kind: String?; var kindArg: String?   // optional → old pages.json decodes as .grid
    init(_ p: PadPage) {
        name = p.name; tiles = p.tiles.map(TileDTO.init)
        switch p.kind {
        case .grid:            kind = "grid"
        case .web(let url):    kind = "web";  kindArg = url
        case .app(let id):     kind = "app";  kindArg = id
        }
    }
    func toPage() -> PadPage {
        let k: PadPageKind
        switch kind {
        case "web": k = .web(url: kindArg ?? "")
        case "app": k = .app(id: kindArg ?? "")
        default:    k = .grid
        }
        return PadPage(name: name, tiles: tiles.map { $0.toTile() }, kind: k)
    }
}

// MARK: - Color <-> "#RRGGBB" (via deviceRGB)

// MARK: - Tile-editor draft session
//
// The editor edits a DRAFT copy of the pages (shown 1:1 in the live preview). The Quake and disk
// only change when the user hits Save (commit → PadStore.replace). Revert drops the draft back to
// the committed state.

final class TileEditSession: ObservableObject {
    static let shared = TileEditSession()
    @Published var draft: [PadPage]
    @Published var dirty = false
    @Published var selectedSlot: Int? = nil      // strip slot being edited in the inspector
    @Published var selectedSpec: TileSpec? = nil // library tile being inspected (read-only)

    private init() { draft = PadStore.shared.pages }

    func index(ofPage name: String) -> Int? { draft.firstIndex { $0.name == name } }

    /// Select a placed strip slot (clears any library inspection).
    func select(_ slot: Int?) { selectedSlot = slot; if slot != nil { selectedSpec = nil } }

    /// Inspect a library tile read-only (clears any strip selection).
    func inspect(_ spec: TileSpec?) { selectedSpec = spec; if spec != nil { selectedSlot = nil } }

    /// True when the inspector rail should be visible.
    var hasSelection: Bool { selectedSlot != nil || selectedSpec != nil }

    /// The non-empty tile at a slot, or nil.
    func tile(page: Int, slot: Int) -> Tile? {
        guard draft.indices.contains(page), draft[page].tiles.indices.contains(slot) else { return nil }
        let t = draft[page].tiles[slot]
        return t.title.isEmpty ? nil : t
    }

    /// Edit a placed tile's title + action, keeping its glyph/tint.
    func setTitleAction(page: Int, slot: Int, title: String, action: PadAction) {
        guard let t0 = tile(page: page, slot: slot) else { return }
        setTile(page: page, slot: slot, Tile(title: title, symbol: t0.symbol, tint: t0.tint, action: action, image: t0.image, editable: t0.editable))
    }

    func remove(page: Int, slot: Int) {
        setTile(page: page, slot: slot, nil)
        if selectedSlot == slot { selectedSlot = nil }
    }

    func setTile(page: Int, slot: Int, _ tile: Tile?) {
        guard draft.indices.contains(page), slot >= 0, slot < PadModel.perPage else { return }
        var tiles = draft[page].tiles
        while tiles.count <= slot { tiles.append(PadStore.emptyTile) }
        tiles[slot] = tile ?? PadStore.emptyTile
        draft[page].tiles = tiles
        dirty = true
    }

    /// Commit the draft → device + disk.
    func save() { PadStore.shared.replace(draft); dirty = false }

    /// Throw away unsaved edits, returning to what the device currently shows.
    func revert() { draft = PadStore.shared.pages; dirty = false }
}

// MARK: - Color <-> "#RRGGBB" (via deviceRGB)

extension Color {
    var hexRGB: String {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.gray
        let r = Int((ns.redComponent   * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
    init(hexRGB: String) {
        let hex = hexRGB.hasPrefix("#") ? String(hexRGB.dropFirst()) : hexRGB
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self = Color(red:   Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8)  & 0xff) / 255,
                     blue:  Double(v & 0xff) / 255)
    }
}
