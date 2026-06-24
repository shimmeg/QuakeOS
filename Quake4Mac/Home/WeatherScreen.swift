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
    var body: some View { WeatherWebView(zoom: zoom, config: store.webConfig, interactive: interactive).ignoresSafeArea() }
}

struct WeatherWebView: NSViewRepresentable {
    var zoom: CGFloat = 1
    var config: String
    var interactive = true
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "weather", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        if interactive {
            let coord = context.coordinator
            ScreenTouchRouter.shared.install(owner: coord,
                began: { [weak coord] p in coord?.began(p) },
                moved: { [weak coord] p in coord?.moved(p) },
                ended: { [weak coord] in coord?.ended() })
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.apply(zoom: zoom, config: config) }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) { ScreenTouchRouter.shared.release(owner: coordinator) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var loaded = false
        private var pending: (CGFloat, String)?
        private var startX: CGFloat?, lastX: CGFloat?

        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded = true; if let p = pending { apply(zoom: p.0, config: p.1) } }
        func apply(zoom: CGFloat, config: String) {
            guard loaded, let web = web else { pending = (zoom, config); return }
            web.evaluateJavaScript("window.WEATHER && window.WEATHER.set(\(config));", completionHandler: nil)
            if abs(zoom - 1) > 0.001 { web.evaluateJavaScript("document.documentElement.style.zoom='\(zoom)';", completionHandler: nil) }
        }
        func began(_ p: CGPoint) { startX = p.x; lastX = p.x }
        func moved(_ p: CGPoint) { lastX = p.x }
        func ended() {
            defer { startX = nil; lastX = nil }
            guard let s = startX, let e = lastX, abs(e - s) > 0.12, let web = web else { return }
            web.evaluateJavaScript("window.WEATHER && window.WEATHER.flip(\(e < s ? 1 : -1));", completionHandler: nil)
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
