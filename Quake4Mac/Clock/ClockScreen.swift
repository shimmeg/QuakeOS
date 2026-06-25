// ClockScreen.swift — Quake4Mac
//
// Bundled "Clock" panel. Web/clock.html renders either a single big clock (flip / digital /
// analog) that you swipe to step through configured zones, or a grid of analog world-clocks.
// Config lives in ClockStore (persisted) and is pushed via window.CLOCK.set(...). On the device,
// horizontal finger swipes are read through ScreenTouchRouter and forwarded as window.CLOCK.flip().
// Also hosts WebDashboardView used for `.web` page kinds.

import SwiftUI
import WebKit

// MARK: - Model + store

struct WorldClock: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var tz: String        // TimeZone identifier, or "local"
}

final class ClockStore: ObservableObject {
    static let shared = ClockStore()

    @Published var layout: String  { didSet { save() } }   // "single" | "grid"
    @Published var style: String   { didSet { save() } }   // single-layout style: flip | digital | analog
    @Published var clocks: [WorldClock] { didSet { save() } }
    @Published var hour24: Bool    { didSet { save() } }
    @Published var seconds: Bool   { didSet { save() } }
    @Published var showDate: Bool  { didSet { save() } }

    static let cities: [(name: String, tz: String)] = [
        ("Local", "local"),
        ("Cupertino", "America/Los_Angeles"), ("New York", "America/New_York"),
        ("Chicago", "America/Chicago"), ("Denver", "America/Denver"),
        ("Toronto", "America/Toronto"), ("São Paulo", "America/Sao_Paulo"),
        ("London", "Europe/London"), ("Paris", "Europe/Paris"),
        ("Berlin", "Europe/Berlin"), ("Moscow", "Europe/Moscow"),
        ("Dubai", "Asia/Dubai"), ("Mumbai", "Asia/Kolkata"),
        ("Singapore", "Asia/Singapore"), ("Hong Kong", "Asia/Hong_Kong"),
        ("Shanghai", "Asia/Shanghai"), ("Tokyo", "Asia/Tokyo"),
        ("Sydney", "Australia/Sydney"), ("Auckland", "Pacific/Auckland"),
        ("Honolulu", "Pacific/Honolulu"), ("Cape Town", "Africa/Johannesburg"),
    ]
    static let layouts: [(name: String, id: String)] = [("Single (swipe)", "single"), ("World grid", "grid")]
    static let styles:  [(name: String, id: String)] = [("Flip", "flip"), ("Digital", "digital"), ("Analog", "analog")]

    private struct Config: Codable {
        var layout: String?; var style: String?
        var clocks: [WorldClock]; var hour24: Bool; var seconds: Bool; var showDate: Bool
    }
    private static let key = "clock.config"

    private init() {
        if let data = UserDefaults.standard.data(forKey: ClockStore.key),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            layout = c.layout ?? "single"; style = c.style ?? "flip"
            clocks = c.clocks; hour24 = c.hour24; seconds = c.seconds; showDate = c.showDate
        } else {
            layout = "single"; style = "flip"
            clocks = [WorldClock(label: "Local", tz: "local")]
            hour24 = false; seconds = true; showDate = true
        }
    }

    private func save() {
        let c = Config(layout: layout, style: style, clocks: clocks, hour24: hour24, seconds: seconds, showDate: showDate)
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: ClockStore.key) }
    }

    func addClock() { clocks.append(WorldClock(label: "New York", tz: "America/New_York")) }
    func add(name: String, tz: String) { clocks.append(WorldClock(label: name, tz: tz)) }
    func remove(at index: Int) { guard clocks.indices.contains(index) else { return }; clocks.remove(at: index) }
    func remove(id: UUID) { clocks.removeAll { $0.id == id } }

    /// Display name for a time-zone id (falls back to the id's last path component).
    static func cityName(_ tz: String) -> String {
        cities.first(where: { $0.tz == tz })?.name
            ?? tz.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? tz
    }

    /// Set a clock's zone, auto-renaming its label to the new city unless the user typed a custom one.
    func setTZ(at i: Int, to newTZ: String) {
        guard clocks.indices.contains(i) else { return }
        if clocks[i].label == ClockStore.cityName(clocks[i].tz) { clocks[i].label = ClockStore.cityName(newTZ) }
        clocks[i].tz = newTZ
    }

    var webConfig: String {
        let arr = clocks.map { ["label": $0.label, "tz": $0.tz] }
        let dict: [String: Any] = ["layout": layout, "style": style, "clocks": arr,
                                   "hour24": hour24, "seconds": seconds, "showDate": showDate]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Renderer

struct ClockScreenView: View {
    var interactive = true       // false in the settings preview (no device touch-router)
    var zoom: CGFloat = 1
    @ObservedObject private var store = ClockStore.shared

    var body: some View {
        ClockWebView(zoom: zoom, config: store.webConfig, interactive: interactive).ignoresSafeArea()
    }
}

struct ClockWebView: NSViewRepresentable {
    var zoom: CGFloat = 1
    var config: String
    var interactive = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "clock", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // Device finger swipes (USB-HID) → flip through zones. Skip in the settings preview.
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
        context.coordinator.apply(zoom: zoom, config: config)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        ScreenTouchRouter.shared.release(owner: coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var loaded = false
        private var pending: (CGFloat, String)?
        private var startX: CGFloat?
        private var lastX: CGFloat?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let p = pending { apply(zoom: p.0, config: p.1) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loaded = false
            webView.reload()
        }

        func apply(zoom: CGFloat, config: String) {
            pending = (zoom, config)
            guard loaded, let web = web else { pending = (zoom, config); return }
            web.evaluateJavaScript("window.CLOCK && window.CLOCK.set(\(config));", completionHandler: nil)
            if abs(zoom - 1) > 0.001 {
                web.evaluateJavaScript("document.documentElement.style.zoom='\(zoom)';", completionHandler: nil)
            }
        }

        // Horizontal swipe → step zones. p is normalized device coords (0…1).
        func touchBegan(_ p: CGPoint) { startX = p.x; lastX = p.x }
        func touchMoved(_ p: CGPoint) { lastX = p.x }
        func touchEnded() {
            defer { startX = nil; lastX = nil }
            guard let s = startX, let e = lastX, let web = web else { return }
            let dx = e - s
            guard abs(dx) > 0.12 else { return }          // ignore taps / tiny drags
            let dir = dx < 0 ? 1 : -1                       // swipe left → next zone
            web.evaluateJavaScript("window.CLOCK && window.CLOCK.flip(\(dir));", completionHandler: nil)
        }
    }
}

// MARK: - Web dashboard (for `.web` page kinds — Weather/Home Assistant/etc.)

struct WebDashboardView: View {
    let urlString: String
    var body: some View { WebDashboardWeb(urlString: urlString).ignoresSafeArea() }
}

struct WebDashboardWeb: NSViewRepresentable {
    let urlString: String
    func makeCoordinator() -> Coordinator { Coordinator(urlString: urlString) }
    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        context.coordinator.load()
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.update(urlString: urlString) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var urlString: String

        init(urlString: String) {
            self.urlString = urlString
        }

        func update(urlString: String) {
            guard self.urlString != urlString else { return }
            self.urlString = urlString
            load()
        }

        func load() {
            guard let web else { return }
            guard let u = MacroActionExecutor.webURL(from: urlString) else {
                web.loadHTMLString("", baseURL: nil)
                return
            }
            web.load(URLRequest(url: u))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            load()
        }

        // Dashboard URL, not a general browser: allow only http/https. Cancel file:// and all other
        // schemes so a stored dashboard URL can't load local files or custom schemes.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - Clock settings (Settings panel for the Clock prebuilt panel)

struct ClockPageView: View {
    let pageName: String
    @ObservedObject private var store = ClockStore.shared
    @State private var query = ""
    @State private var results: [GeoResult] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: pageName,
                           subtitle: "One big clock you swipe through, or a grid of world clocks. Changes apply live.")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            NeonCard("Layout") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Layout", selection: $store.layout) {
                        ForEach(ClockStore.layouts, id: \.id) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.segmented)
                    if store.layout == "single" {
                        HStack {
                            Text("Style").font(.system(size: 13)).foregroundColor(NeonTheme.textSecondary)
                            Picker("", selection: $store.style) {
                                ForEach(ClockStore.styles, id: \.id) { Text($0.name).tag($0.id) }
                            }.labelsHidden().frame(width: 260)
                            Spacer()
                        }
                        Text("Swipe the panel to flip between your clocks; dots show how many.")
                            .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                    } else {
                        Text("All your clocks show at once as analog faces with each city's offset.")
                            .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                    }
                }
                .font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                .padding(.vertical, 8)
            }

            NeonCard("Display") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("24-hour time", isOn: $store.hour24)
                    Toggle("Show seconds", isOn: $store.seconds)
                    Toggle("Show date", isOn: $store.showDate)
                }
                .toggleStyle(.switch).tint(NeonTheme.cyan)
                .font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                .padding(.vertical, 8)
            }

            NeonCard("Clocks") {
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
                        Button {
                            store.add(name: r.name, tz: r.timezone ?? "UTC"); results = []; query = ""
                        } label: {
                            HStack { Image(systemName: "plus.circle").foregroundColor(NeonTheme.cyan); Text(r.label).font(.system(size: 12)).foregroundColor(NeonTheme.textPrimary); Spacer() }
                        }.buttonStyle(.plain).disabled(store.clocks.count >= 5)
                    }
                    NeonDivider()
                    ForEach($store.clocks) { $clock in clockRow($clock) }
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
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            let r = await GeoSearch.search(q)
            if Task.isCancelled { return }
            await MainActor.run { results = r; searching = false }
        }
    }

    @ViewBuilder private func clockRow(_ clock: Binding<WorldClock>) -> some View {
        HStack(spacing: 10) {
            TextField("Label", text: clock.label)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 160)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
            Text(clock.wrappedValue.tz == "local" ? "Local" : clock.wrappedValue.tz)
                .font(.system(size: 12)).foregroundColor(NeonTheme.textTertiary).lineLimit(1)
            Spacer()
            Button { store.remove(id: clock.wrappedValue.id) } label: {
                Image(systemName: "trash").font(.system(size: 13)).foregroundColor(NeonTheme.magenta)
            }
            .buttonStyle(.plain).disabled(store.clocks.count <= 1)
        }
    }
}
