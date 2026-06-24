// WeatherScreen.swift — Quake4Mac
//
// Bundled "Weather" panel. Web/weather.html renders rich live weather (Open-Meteo). Supports
// multiple locations you swipe through on the panel, a "Current Location" resolved by IP, and a
// city search in the settings. Config lives in WeatherStore and is pushed via window.WEATHER.set().

import SwiftUI
import WebKit

struct WeatherLoc: Codable, Identifiable, Equatable { var id = UUID(); var name: String; var lat: Double; var lon: Double }

final class WeatherStore: ObservableObject {
    static let shared = WeatherStore()
    @Published var locations: [WeatherLoc] { didSet { saveLocs() } }
    @Published var unit: String { didSet { UserDefaults.standard.set(unit, forKey: "weather.unit") } }
    @Published var useCurrent: Bool { didSet { UserDefaults.standard.set(useCurrent, forKey: "weather.useCurrent") } }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "weather.locs"), let v = try? JSONDecoder().decode([WeatherLoc].self, from: d) { locations = v } else { locations = [] }
        unit = UserDefaults.standard.string(forKey: "weather.unit") ?? "fahrenheit"
        useCurrent = (UserDefaults.standard.object(forKey: "weather.useCurrent") as? Bool) ?? true
    }
    private func saveLocs() { if let d = try? JSONEncoder().encode(locations) { UserDefaults.standard.set(d, forKey: "weather.locs") } }

    func add(_ r: GeoResult) {
        guard !locations.contains(where: { abs($0.lat - r.lat) < 0.01 && abs($0.lon - r.lon) < 0.01 }) else { return }
        locations.append(WeatherLoc(name: r.name, lat: r.lat, lon: r.lon))
    }
    func remove(at i: Int) { guard locations.indices.contains(i) else { return }; locations.remove(at: i) }

    var webConfig: String {
        let arr = locations.map { ["name": $0.name, "lat": $0.lat, "lon": $0.lon] as [String: Any] }
        let dict: [String: Any] = ["locations": arr, "unit": unit, "useCurrent": useCurrent]
        return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct WeatherScreenView: View {
    var interactive = true
    var zoom: CGFloat = 1
    @ObservedObject private var store = WeatherStore.shared
    @ObservedObject private var loc = LocationService.shared
    var body: some View {
        Group {
            if interactive { WeatherDeviceView(config: configJSON) }       // persistent webview on the panel
            else { WeatherWebView(zoom: zoom, config: configJSON) }        // fresh webview for the settings preview
        }
        .ignoresSafeArea()
        .onAppear { if interactive { loc.request() } }
    }
    private var configJSON: String {
        var dict: [String: Any] = [
            "locations": store.locations.map { ["name": $0.name, "lat": $0.lat, "lon": $0.lon] as [String: Any] },
            "unit": store.unit, "useCurrent": store.useCurrent,
        ]
        if let la = loc.lat, let lo = loc.lon { dict["current"] = ["lat": la, "lon": lo, "name": loc.cityName ?? "Current Location"] }
        return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// Fresh, throwaway webview used only for the settings-strip preview (zoomed-down, non-interactive).
struct WeatherWebView: NSViewRepresentable {
    var zoom: CGFloat = 1
    var config: String
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "weather", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.apply(zoom: zoom, config: config) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var loaded = false
        private var pending: (CGFloat, String)?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded = true; if let p = pending { apply(zoom: p.0, config: p.1) } }
        func apply(zoom: CGFloat, config: String) {
            guard loaded, let web = web else { pending = (zoom, config); return }
            web.evaluateJavaScript("window.WEATHER && window.WEATHER.set(\(config));", completionHandler: nil)
            if abs(zoom - 1) > 0.001 { web.evaluateJavaScript("document.documentElement.style.zoom='\(zoom)';", completionHandler: nil) }
        }
    }
}

// Persistent webview that backs the on-device Weather app. Created once and reparented on each open,
// so reopening the app never reloads the page (no "[City] Loading" splash) and config is pushed only
// when it actually changes. Also routes touch: drags over the hourly strip scroll it; bigger horizontal
// drags elsewhere flip to the next/previous city.
final class WeatherWeb: NSObject, WKNavigationDelegate {
    static let shared = WeatherWeb()
    let web: WKWebView
    private var loaded = false
    private var pendingConfig: String?
    private var lastConfig = ""
    private var hourlyRect: (CGFloat, CGFloat, CGFloat, CGFloat)?   // normalized x,y,w,h
    private var startX: CGFloat?, lastX: CGFloat?
    private var scrollMode = false

    override init() {
        // Real panel size up front so first-paint layout (and the hourly rect) is correct even off-screen.
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 480), configuration: WKWebViewConfiguration())
        super.init()
        web.navigationDelegate = self
        if let url = Bundle.main.url(forResource: "weather", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// Build + load + render at app launch so the very first open shows finished content (no splash).
    func warm() {
        LocationService.shared.request()
        apply(config: WeatherWeb.currentConfig())
    }

    static func currentConfig() -> String {
        let s = WeatherStore.shared
        var dict: [String: Any] = [
            "locations": s.locations.map { ["name": $0.name, "lat": $0.lat, "lon": $0.lon] as [String: Any] },
            "unit": s.unit, "useCurrent": s.useCurrent,
        ]
        let l = LocationService.shared
        if let la = l.lat, let lo = l.lon { dict["current"] = ["lat": la, "lon": lo, "name": l.cityName ?? "Current Location"] }
        return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded = true; pushIfChanged(force: true); scheduleRectRefresh() }

    func apply(config: String) { pendingConfig = config; if loaded { pushIfChanged(force: false) } }

    private func pushIfChanged(force: Bool) {
        guard let cfg = pendingConfig else { return }
        if !force && cfg == lastConfig { return }   // unchanged → don't re-render, avoids the splash on reopen
        lastConfig = cfg
        web.evaluateJavaScript("window.WEATHER && window.WEATHER.set(\(cfg));", completionHandler: nil)
        scheduleRectRefresh()
    }

    func began(_ p: CGPoint) {
        startX = p.x; lastX = p.x; scrollMode = false
        if let r = hourlyRect, p.x >= r.0, p.x <= r.0 + r.2, p.y >= r.1, p.y <= r.1 + r.3 { scrollMode = true }
    }
    func moved(_ p: CGPoint) {
        if scrollMode, let l = lastX {
            let px = Double(p.x - l) * 1920.0
            web.evaluateJavaScript("window.WEATHER && window.WEATHER.scrollHourly(\(px));", completionHandler: nil)
        }
        lastX = p.x
    }
    func ended() {
        defer { startX = nil; lastX = nil }
        if scrollMode { scrollMode = false; return }
        guard let s = startX, let e = lastX, abs(e - s) > 0.12 else { return }
        web.evaluateJavaScript("window.WEATHER && window.WEATHER.flip(\(e < s ? 1 : -1));", completionHandler: nil)
        scheduleRectRefresh()
    }

    func nudgeMap() { web.evaluateJavaScript("if(typeof _map!=='undefined' && _map){ _map.invalidateSize(); }", completionHandler: nil) }

    private func scheduleRectRefresh() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.refreshRect() } }
    private func refreshRect() {
        web.evaluateJavaScript("JSON.stringify(window.__hourlyRect||null)") { [weak self] r, _ in
            guard let s = r as? String, let d = s.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Double],
                  let x = o["x"], let y = o["y"], let w = o["w"], let h = o["h"] else { self?.hourlyRect = nil; return }
            self?.hourlyRect = (CGFloat(x), CGFloat(y), CGFloat(w), CGFloat(h))
        }
    }
}

struct WeatherDeviceView: NSViewRepresentable {
    var config: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        attach(to: v)
        ScreenTouchRouter.shared.install(owner: WeatherWeb.shared,
            began: { p in WeatherWeb.shared.began(p) },
            moved: { p in WeatherWeb.shared.moved(p) },
            ended: { WeatherWeb.shared.ended() })
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        attach(to: v)
        WeatherWeb.shared.apply(config: config)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { ScreenTouchRouter.shared.release(owner: WeatherWeb.shared) }

    private func attach(to v: NSView) {
        let web = WeatherWeb.shared.web
        if web.superview !== v {
            web.removeFromSuperview()
            web.frame = v.bounds
            web.autoresizingMask = [.width, .height]
            v.addSubview(web)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { WeatherWeb.shared.nudgeMap() }
        }
    }
}

// MARK: - Settings (Prebuilt Panels → Weather)

struct WeatherPanelView: View {
    let pageName: String
    @ObservedObject private var store = WeatherStore.shared
    @State private var query = ""
    @State private var results: [GeoResult] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: pageName,
                           subtitle: "Live weather on the Quake (Open-Meteo). Add any city by search and swipe between them on the panel.")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            NeonCard("Options") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Units").font(.system(size: 13)).foregroundColor(NeonTheme.textSecondary).frame(width: 130, alignment: .leading)
                        Picker("", selection: $store.unit) { Text("°F").tag("fahrenheit"); Text("°C").tag("celsius") }.pickerStyle(.segmented).frame(width: 160)
                    }
                    Toggle("Show current location (auto)", isOn: $store.useCurrent)
                        .toggleStyle(.switch).tint(NeonTheme.cyan).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                }
                .padding(.vertical, 8)
            }
            NeonCard("Locations") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Search any city or town…", text: $query)
                            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
                            .onChange(of: query) { _ in scheduleSearch() }
                        if searching { ProgressView().scaleEffect(0.6).frame(width: 16, height: 16) }
                    }
                    if searching { Text("Searching…").font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary) }
                    ForEach(results) { r in
                        Button { store.add(r); results = []; query = "" } label: {
                            HStack { Image(systemName: "plus.circle").foregroundColor(NeonTheme.cyan); Text(r.label).font(.system(size: 12)).foregroundColor(NeonTheme.textPrimary); Spacer() }
                        }.buttonStyle(.plain)
                    }
                    if !store.locations.isEmpty { NeonDivider() }
                    ForEach(store.locations.indices, id: \.self) { i in
                        HStack {
                            Image(systemName: "mappin.circle.fill").foregroundColor(NeonTheme.cyan)
                            Text(store.locations[i].name).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                            Spacer()
                            Button { store.remove(at: i) } label: { Image(systemName: "trash").foregroundColor(NeonTheme.magenta) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            }
            Spacer()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { results = []; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)        // debounce keystrokes
            if Task.isCancelled { return }
            let r = await GeoSearch.search(q)
            if Task.isCancelled { return }
            await MainActor.run { results = r; searching = false }
        }
    }
}
