// PanelWeb.swift — Quake4Mac
//
// Persistent, pre-warmed webviews for the on-device panels (Clock / Music / Monitor / Weather).
//
// Why: previously each panel created a FRESH WKWebView every time you opened it, so every open
// showed a loading/splash flash and any in-page data had to be re-fetched. Apple's own Weather app
// never does this. Instead we build each panel's webview ONCE at app launch (PanelWarmer.warmAll),
// keep it alive forever, and just reparent it into whatever container is on screen. Opening a panel
// is then instant (the page is already rendered) and the page's own timers keep it fresh in the
// background, so switching back never needs a reload.
//
// PanelWeb is the shared base (load-once + reparent + JS eval + touch hooks). Each panel subclasses
// it for its config push + gestures. PanelWebHost is the thin SwiftUI bridge that reparents the
// shared webview and wires the device touch-router to it.

import SwiftUI
import WebKit
import AppKit
import Combine

// MARK: - Base

class PanelWeb: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private(set) var loaded = false
    private var htmlName: String

    /// Real panel size up front so first-paint layout is correct even while the webview is off-screen.
    init(html: String, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) {
        htmlName = html
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 480), configuration: configuration)
        super.init()
        web.navigationDelegate = self
        load(html: html)
    }

    func load(html: String) {
        htmlName = html
        loaded = false
        if let url = Bundle.main.url(forResource: html, withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded = true; onReady() }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[Quake] PanelWeb: WebContent process terminated for \(htmlName); reloading")
        load(html: htmlName)
    }

    func eval(_ js: String) { web.evaluateJavaScript(js, completionHandler: nil) }

    func reparent(into v: NSView) {
        if web.superview !== v {
            web.removeFromSuperview()
            web.frame = v.bounds
            web.autoresizingMask = [.width, .height]
            v.addSubview(web)
        }
    }

    // Overridable lifecycle / input hooks.
    func onReady() {}                       // page finished loading → push initial state
    func onShow() {}                        // panel became visible (also fired on config updates)
    func onHide() {}                        // panel dismissed
    func touchBegan(_ p: CGPoint) {}        // p = normalized device coords (0…1)
    func touchMoved(_ p: CGPoint) {}
    func touchEnded() {}
}

// MARK: - SwiftUI host

/// Reparents a shared PanelWeb into the on-screen container and routes device finger input to it.
struct PanelWebHost: NSViewRepresentable {
    let panel: PanelWeb
    var routeTouch = true

    func makeCoordinator() -> Coord { Coord(panel: panel) }
    final class Coord { let panel: PanelWeb; init(panel: PanelWeb) { self.panel = panel } }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        panel.reparent(into: v)
        if routeTouch {
            ScreenTouchRouter.shared.install(owner: panel,
                began: { [weak panel] p in panel?.touchBegan(p) },
                moved: { [weak panel] p in panel?.touchMoved(p) },
                ended: { [weak panel] in panel?.touchEnded() })
        }
        panel.onShow()
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { panel.reparent(into: v); panel.onShow() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coord) {
        coordinator.panel.onHide()
        ScreenTouchRouter.shared.release(owner: coordinator.panel)
    }
}

// MARK: - Clock

final class ClockWeb: PanelWeb {
    static let shared = ClockWeb()
    private var lastConfig = ""
    private var startX: CGFloat?, lastX: CGFloat?

    init() { super.init(html: "clock") }

    override func onReady() { lastConfig = ""; push() }
    override func onShow() { push() }

    private func push() {
        guard loaded else { return }
        let cfg = ClockStore.shared.webConfig
        if cfg == lastConfig { return }       // only re-render when the config actually changed
        lastConfig = cfg
        eval("window.CLOCK && window.CLOCK.set(\(cfg));")
    }

    override func touchBegan(_ p: CGPoint) { startX = p.x; lastX = p.x }
    override func touchMoved(_ p: CGPoint) { lastX = p.x }
    override func touchEnded() {
        defer { startX = nil; lastX = nil }
        guard let s = startX, let e = lastX, abs(e - s) > 0.12 else { return }
        eval("window.CLOCK && window.CLOCK.flip(\(e < s ? 1 : -1));")
    }
}

struct ClockDeviceView: View {
    @ObservedObject private var store = ClockStore.shared   // re-push when settings change
    var body: some View { PanelWebHost(panel: ClockWeb.shared).ignoresSafeArea() }
}

// MARK: - System monitor

final class MonitorWeb: PanelWeb {
    static let shared = MonitorWeb()
    let stats = SystemStats()
    private var bag = Set<AnyCancellable>()
    private var lastTouch: CGPoint?

    init() {
        super.init(html: "monitor")
        stats.start()    // keep stats live from launch so the panel is always current in the background
        stats.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.push() } }
            .store(in: &bag)
    }

    override func onReady() { push() }
    override func onShow() { push() }

    private func push() {
        guard loaded else { return }
        let s = stats
        let dict: [String: Any] = [
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
            "bt": s.bt,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8),
              let enc = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        eval("window.MON.set(decodeURIComponent('\(enc)'))")
    }

    override func touchBegan(_ p: CGPoint) { lastTouch = p }
    override func touchEnded() { lastTouch = nil }
    override func touchMoved(_ p: CGPoint) {
        defer { lastTouch = p }
        guard let prev = lastTouch else { return }
        let dy = Double(prev.y - p.y) * Double(web.bounds.height)
        guard abs(dy) > 0.3 else { return }
        eval("window.MON.scrollAt(\(Double(p.x)),\(Double(p.y)),\(dy))")
    }
}

struct MonitorDeviceView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.11), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            PanelWebHost(panel: MonitorWeb.shared).ignoresSafeArea()
        }
    }
}

// MARK: - Music

final class MusicWeb: PanelWeb, WKScriptMessageHandler {
    static let shared = MusicWeb()
    let model = MusicModel()
    private var bag = Set<AnyCancellable>()
    private var currentFile = ""
    private var last = ""
    private var startPt = CGPoint.zero, lastPt = CGPoint.zero, dragged = false

    init() {
        let f = (UserDefaults.standard.string(forKey: "music.style") == "vinyl") ? "music" : "musicclean"
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        super.init(html: f, configuration: cfg)
        currentFile = f
        web.configuration.userContentController.add(self, name: "transport")
        model.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.push() } }
            .store(in: &bag)
        // Poll in the background from launch so switching INTO the panel never shows a "no X found"
        // gap — the now-playing track, queue, lyrics and playlists are already current. (SpotifyClient
        // backs off on 429s; if lockouts return we can slow the inactive cadence.)
        model.start()
    }

    override func onReady() { last = ""; push(force: true) }

    override func onShow() {
        // Swap clean ↔ vinyl live if the style changed in Settings, then push the latest state.
        let f = (UserDefaults.standard.string(forKey: "music.style") == "vinyl") ? "music" : "musicclean"
        if f != currentFile { currentFile = f; last = ""; load(html: f) }
        push()
    }

    private func push(force: Bool = false) {
        guard loaded else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: model.snapshot()),
              let json = String(data: data, encoding: .utf8) else { return }
        if !force && json == last { return }
        last = json
        guard let enc = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        eval("window.MUSIC.update(decodeURIComponent('\(enc)'))")
    }

    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "transport", let action = m.body as? String else { return }
        if action == "focusapp" {
            NSApp.activate(ignoringOtherApps: true)
            web.window?.makeKeyAndOrderFront(nil)
            return
        }
        model.transport(action)
    }

    override func touchBegan(_ p: CGPoint) { startPt = p; lastPt = p; dragged = false }
    override func touchMoved(_ p: CGPoint) {
        guard loaded else { return }
        let dx = (p.x - lastPt.x) * web.bounds.width
        let dy = (p.y - lastPt.y) * web.bounds.height
        lastPt = p
        let totX = abs((p.x - startPt.x) * web.bounds.width)
        let totY = abs((p.y - startPt.y) * web.bounds.height)
        if totX > 28 || totY > 28 { dragged = true }
        guard dragged else { return }
        let x = startPt.x * web.bounds.width, y = startPt.y * web.bounds.height
        let horiz = totX > totY
        let delta = horiz ? -dx : -dy
        let js = """
        (function(){var e=document.elementFromPoint(\(x),\(y));var hz=\(horiz);
        while(e&&e!==document.body){var cs=getComputedStyle(e);
        if(hz&&(cs.overflowX==='auto'||cs.overflowX==='scroll')&&e.scrollWidth>e.clientWidth){e.scrollLeft+=\(delta);return;}
        if(!hz&&(cs.overflowY==='auto'||cs.overflowY==='scroll')&&e.scrollHeight>e.clientHeight){e.scrollTop+=\(delta);return;}
        e=e.parentElement;}})();
        """
        eval(js)
    }
    override func touchEnded() {
        guard loaded, !dragged else { return }
        let x = startPt.x * web.bounds.width, y = startPt.y * web.bounds.height
        let js = """
        (function(){var e=document.elementFromPoint(\(x),\(y));if(!e)return;
        var t=e.tagName;if(t==='INPUT'||t==='TEXTAREA'){e.focus();e.click();return;}
        while(e&&!e.onclick&&e!==document.body)e=e.parentElement;if(e&&e.click)e.click();})();
        """
        eval(js)
    }
}

struct MusicDeviceView: View {
    @AppStorage("music.style") private var style = "clean"   // re-render → onShow → live style swap
    var body: some View { PanelWebHost(panel: MusicWeb.shared).ignoresSafeArea() }
}

// MARK: - Launch warmer

enum PanelWarmer {
    /// Build + load every on-device panel webview at launch so first open is instant (no splash) and
    /// each panel keeps refreshing in the background. Call once from applicationDidFinishLaunching.
    static func warmAll() {
        _ = ClockWeb.shared
        _ = MonitorWeb.shared
        // MusicWeb intentionally NOT warmed yet — its persistent path is untested on-device, so we keep
        // the proven MusicScreenView active. Re-add `_ = MusicWeb.shared` once it's verified.
        WeatherWeb.shared.warm()
    }
}
