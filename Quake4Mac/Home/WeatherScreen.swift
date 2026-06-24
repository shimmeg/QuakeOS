// WeatherScreen.swift — Quake4Mac
//
// Bundled "Weather" panel. Web/weather.html renders live conditions + a 5-day forecast (Open-Meteo,
// no API key). Config (city + units) lives in WeatherStore and is pushed via window.WEATHER.set(...).
// Settings panel (Prebuilt Panels → Weather) edits the location and units.

import SwiftUI
import WebKit

final class WeatherStore: ObservableObject {
    static let shared = WeatherStore()
    @Published var city: String { didSet { save() } }
    @Published var unit: String { didSet { save() } }   // "celsius" | "fahrenheit"

    private static let cityKey = "weather.city", unitKey = "weather.unit"
    private init() {
        city = UserDefaults.standard.string(forKey: WeatherStore.cityKey) ?? "New York"
        unit = UserDefaults.standard.string(forKey: WeatherStore.unitKey) ?? "fahrenheit"
    }
    private func save() {
        UserDefaults.standard.set(city, forKey: WeatherStore.cityKey)
        UserDefaults.standard.set(unit, forKey: WeatherStore.unitKey)
    }
    var webConfig: String {
        let dict: [String: Any] = ["city": city, "unit": unit]
        return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct WeatherScreenView: View {
    var interactive = true
    var zoom: CGFloat = 1
    @ObservedObject private var store = WeatherStore.shared
    var body: some View { WeatherWebView(zoom: zoom, config: store.webConfig).ignoresSafeArea() }
}

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

// MARK: - Settings (Prebuilt Panels → Weather)

struct WeatherPanelView: View {
    let pageName: String
    @ObservedObject private var store = WeatherStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: pageName,
                           subtitle: "Live weather on the Quake (Open-Meteo). Set your location and units; updates apply live.")
            NeonCard("Location") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("City").font(.system(size: 13)).foregroundColor(NeonTheme.textSecondary).frame(width: 70, alignment: .leading)
                        TextField("City name", text: $store.city)
                            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
                    }
                    HStack {
                        Text("Units").font(.system(size: 13)).foregroundColor(NeonTheme.textSecondary).frame(width: 70, alignment: .leading)
                        Picker("", selection: $store.unit) {
                            Text("°F").tag("fahrenheit"); Text("°C").tag("celsius")
                        }.pickerStyle(.segmented).frame(width: 160)
                    }
                }
                .padding(.vertical, 8)
            }
            Spacer()
        }
    }
}
