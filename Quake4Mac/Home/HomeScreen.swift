// HomeScreen.swift — Quake4Mac
//
// The OS layer's springboard home screen, shown on the panel at boot. A grid of app icons across
// the 1920×480 panel; tap an icon to open that app, swipe (or rotate the knob) to change home
// page, knob press to return home. Layout lives in HomeStore (a default for now; the Mac settings
// "Layout" section will edit it later).

import SwiftUI

// AppDest <-> string for persisting the launch target / last-open screen.
extension AppDest {
    var storageKey: String {
        switch self {
        case .macroPage(let n): return "macroPage:\(n)"
        case .panel(let p):     return "panel:\(p)"
        case .builtin(let b):   return "builtin:\(b)"
        }
    }
    init?(storageKey s: String) {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "macroPage": self = .macroPage(parts[1])
        case "panel":     self = .panel(parts[1])
        case "builtin":   self = .builtin(parts[1])
        default:          return nil
        }
    }
    /// User-facing name for pickers.
    var displayName: String {
        switch self {
        case .macroPage(let n): return n
        case .panel(let p):     return p == "monitor" ? "System Monitor" : p.capitalized
        case .builtin(let b):   return b.capitalized
        }
    }
}

struct HomeApp: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String      // SF Symbol
    var tint: Color
    var dest: AppDest
}

private struct HomeAppDTO: Codable {
    var title: String; var symbol: String; var tintHex: String; var dest: String
    init(_ a: HomeApp) { title = a.title; symbol = a.symbol; tintHex = a.tint.hexRGB; dest = a.dest.storageKey }
    func toApp() -> HomeApp { HomeApp(title: title, symbol: symbol, tint: Color(hexRGB: tintHex),
                                      dest: AppDest(storageKey: dest) ?? .builtin("settings")) }
}

final class HomeStore: ObservableObject {
    static let shared = HomeStore()
    @Published var pages: [[HomeApp]] { didSet { save() } }
    private static let key = "home.layout"

    private init() {
        if let d = UserDefaults.standard.data(forKey: HomeStore.key),
           let dto = try? JSONDecoder().decode([[HomeAppDTO]].self, from: d), !dto.isEmpty {
            pages = dto.map { $0.map { $0.toApp() } }
        } else {
            pages = HomeStore.defaultPages()
        }
    }
    private func save() {
        let dto = pages.map { $0.map { HomeAppDTO($0) } }
        if let d = try? JSONEncoder().encode(dto) { UserDefaults.standard.set(d, forKey: HomeStore.key) }
    }

    func app(page: Int, slot: Int) -> HomeApp? {
        guard pages.indices.contains(page), pages[page].indices.contains(slot) else { return nil }
        return pages[page][slot]
    }

    /// Every app available, for the launch-target picker.
    var allApps: [HomeApp] { pages.flatMap { $0 } }

    /// The home app matching a destination (for the app switcher's icon/label).
    func appFor(_ dest: AppDest) -> HomeApp? { allApps.first { $0.dest == dest } }

    // MARK: editing (used by the Mac-side Home Layout editor)
    func addPage() { pages.append([]) }
    func removePage(_ i: Int) { guard pages.count > 1, pages.indices.contains(i) else { return }; pages.remove(at: i) }
    func addApp(_ app: HomeApp, toPage i: Int) {
        guard pages.indices.contains(i) else { return }
        pages[i].append(HomeApp(title: app.title, symbol: app.symbol, tint: app.tint, dest: app.dest))
    }
    func removeApp(page i: Int, at j: Int) { guard pages.indices.contains(i), pages[i].indices.contains(j) else { return }; pages[i].remove(at: j) }
    func moveApp(page i: Int, from j: Int, to k: Int) {
        guard pages.indices.contains(i), pages[i].indices.contains(j), k >= 0, k < pages[i].count else { return }
        let a = pages[i].remove(at: j); pages[i].insert(a, at: k)
    }

    /// Every app you can drop onto a home page (built-ins, panels, and your macro pages).
    static func catalog() -> [HomeApp] {
        var out: [HomeApp] = [
            HomeApp(title: "Clock",     symbol: "clock.fill",     tint: .orange, dest: .panel("clock")),
            HomeApp(title: "Music",     symbol: "music.note",     tint: .pink,   dest: .panel("music")),
            HomeApp(title: "Monitor",   symbol: "cpu",            tint: .green,  dest: .panel("monitor")),
            HomeApp(title: "Settings",  symbol: "gearshape.fill", tint: .gray,   dest: .builtin("settings")),
            HomeApp(title: "Wallpaper", symbol: "photo.fill",     tint: .blue,   dest: .builtin("wallpaper")),
            HomeApp(title: "Browser",   symbol: "globe",          tint: .purple, dest: .builtin("browser")),
        ]
        for p in PadStore.shared.pages { out.append(HomeApp(title: p.name, symbol: "square.grid.2x2.fill", tint: .teal, dest: .macroPage(p.name))) }
        return out
    }

    static func defaultPages() -> [[HomeApp]] {
        let osBasics: [HomeApp] = [
            HomeApp(title: "Clock",    symbol: "clock.fill",       tint: .orange, dest: .panel("clock")),
            HomeApp(title: "Settings", symbol: "gearshape.fill",   tint: .gray,   dest: .builtin("settings")),
            HomeApp(title: "Monitor",  symbol: "cpu",              tint: .green,  dest: .panel("monitor")),
            HomeApp(title: "Music",    symbol: "music.note",       tint: .pink,   dest: .panel("music")),
            HomeApp(title: "Wallpaper",symbol: "photo.fill",       tint: .blue,   dest: .builtin("wallpaper")),
            HomeApp(title: "Browser",  symbol: "globe",            tint: .purple, dest: .builtin("browser")),
        ]
        let yourPages: [HomeApp] = [
            HomeApp(title: "Apps",   symbol: "square.grid.2x2.fill", tint: .blue,  dest: .macroPage("Apps")),
            HomeApp(title: "System", symbol: "slider.horizontal.3",  tint: .gray,  dest: .macroPage("System")),
            HomeApp(title: "Web",    symbol: "network",              tint: .teal,  dest: .macroPage("Web")),
        ]
        return [osBasics, yourPages]
    }
}

// Shared layout fractions so the visual grid and PadModel's touch hit-testing agree exactly.
enum HomeLayoutMetrics {
    static let topFrac: CGFloat = 0.22      // status bar band (time / wifi / battery)
    static let bottomFrac: CGFloat = 0.13   // page-dots band
    static let sideFrac: CGFloat = 0.03
    static let cols = 8, rows = 2
}

struct HomeScreenView: View {
    @ObservedObject var store = HomeStore.shared
    let page: Int

    private let M = HomeLayoutMetrics.self

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let apps = store.pages.indices.contains(page) ? store.pages[page] : []
            let gridW = w * (1 - 2 * M.sideFrac)
            let gridH = h * (1 - M.topFrac - M.bottomFrac)
            let cellW = gridW / CGFloat(M.cols), cellH = gridH / CGFloat(M.rows)
            let size = min(cellW, cellH) * 0.56

            ZStack(alignment: .topLeading) {
                Color.clear

                statusBar(w: w)
                    .frame(width: w * (1 - 2 * M.sideFrac), height: h * M.topFrac)
                    .position(x: w / 2, y: h * M.topFrac / 2)

                VStack(spacing: 0) {
                    ForEach(0..<M.rows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<M.cols, id: \.self) { c in
                                let idx = r * M.cols + c
                                Group {
                                    if idx < apps.count { iconCell(apps[idx], size: size) } else { Color.clear }
                                }
                                .frame(width: cellW, height: cellH)
                            }
                        }
                    }
                }
                .frame(width: gridW, height: gridH)
                .position(x: w / 2, y: h * M.topFrac + gridH / 2)

                dots.position(x: w / 2, y: h * (1 - M.bottomFrac / 2))
            }
            .frame(width: w, height: h)
        }
    }

    private func statusBar(w: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack {
                Text(timeString(ctx.date))
                    .font(.system(size: w * 0.016, weight: .semibold)).foregroundColor(.white)
                Spacer()
                HStack(spacing: w * 0.012) {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: w * 0.015, weight: .medium)).foregroundColor(.white.opacity(0.9))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = ClockStore.shared.hour24 ? "HH:mm" : "h:mm"
        return f.string(from: d)
    }

    private func iconCell(_ app: HomeApp, size: CGFloat) -> some View {
        VStack(spacing: size * 0.14) {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(app.tint.opacity(0.92))
                .frame(width: size, height: size)
                .overlay(Image(systemName: app.symbol)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundColor(.white))
                .shadow(color: app.tint.opacity(0.5), radius: size * 0.12)
            Text(app.title)
                .font(.system(size: size * 0.2, weight: .medium))
                .foregroundColor(.white.opacity(0.9)).lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var dots: some View {
        HStack(spacing: 10) {
            ForEach(0..<store.pages.count, id: \.self) { i in
                Circle().fill(i == page ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 9, height: 9)
            }
        }
    }
}

// iOS-style app switcher: recently-used apps as a horizontal carousel (most-recent on the right).
// Knob rotate scrubs the highlight, knob press / tap opens it.
struct AppSwitcherView: View {
    let recents: [AppDest]
    let index: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cardW = h * 0.46, cardH = h * 0.6
            let step = cardW * 1.22
            let center = (CGFloat(recents.count - 1) / 2 - CGFloat(index)) * step
            ZStack {
                Color.black.opacity(0.84).ignoresSafeArea()
                Text("Recent apps")
                    .font(.system(size: h * 0.06, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, h * 0.06)
                HStack(spacing: step - cardW) {
                    ForEach(recents.indices, id: \.self) { i in
                        card(recents[i], focused: i == index, w: cardW, h: cardH)
                    }
                }
                .frame(width: w)
                .offset(x: center)
            }
            .frame(width: w, height: h)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: index)
        }
    }

    private func card(_ dest: AppDest, focused: Bool, w: CGFloat, h: CGFloat) -> some View {
        let app = HomeStore.shared.appFor(dest)
        let title = app?.title ?? dest.displayName
        let symbol = app?.symbol ?? "app.fill"
        let tint = app?.tint ?? .gray
        return VStack(spacing: w * 0.1) {
            RoundedRectangle(cornerRadius: w * 0.22, style: .continuous)
                .fill(tint.opacity(0.92)).frame(width: w * 0.6, height: w * 0.6)
                .overlay(Image(systemName: symbol).font(.system(size: w * 0.28, weight: .medium)).foregroundColor(.white))
            Text(title).font(.system(size: w * 0.13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
        }
        .frame(width: w, height: h)
        .background(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous).fill(Color.white.opacity(focused ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous).strokeBorder(focused ? Color.cyan : Color.clear, lineWidth: 3))
        .scaleEffect(focused ? 1.0 : 0.84)
        .opacity(focused ? 1 : 0.6)
    }
}

// MARK: - Home Layout editor (Mac settings → Layout)

struct HomeLayoutView: View {
    @ObservedObject private var store = HomeStore.shared
    @ObservedObject private var wp = WallpaperStore.shared

    private var wallpaperOptions: [(String, String)] {
        [("default", "Default (global)")] + WallpaperStore.options.map { ($0.id, $0.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: "Layout",
                           subtitle: "Arrange your Quake home screen — pages, app icons, and per-page wallpaper.")
            ForEach(store.pages.indices, id: \.self) { p in pageCard(p) }
            Button { store.addPage() } label: {
                Label("Add home page", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(NeonTheme.cyan)
            }
            .buttonStyle(.plain).padding(.top, 2)
            Spacer()
        }
    }

    @ViewBuilder private func pageCard(_ p: Int) -> some View {
        NeonCard("Home Page \(p + 1)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Wallpaper").font(.system(size: 13)).foregroundColor(NeonTheme.textSecondary)
                    Spacer(minLength: 12)
                    Picker("", selection: wallpaperBinding(p)) {
                        ForEach(wallpaperOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 200)
                }
                NeonDivider()
                if store.pages[p].isEmpty {
                    Text("No apps on this page yet — add one below.")
                        .font(.system(size: 12)).foregroundColor(NeonTheme.textTertiary)
                }
                ForEach(store.pages[p].indices, id: \.self) { j in appRow(p, j) }
                HStack {
                    Menu {
                        ForEach(HomeStore.catalog()) { app in
                            Button(app.title) { store.addApp(app, toPage: p) }
                        }
                    } label: {
                        Label("Add app", systemImage: "plus.circle.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(NeonTheme.cyan)
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    if store.pages.count > 1 {
                        Button { store.removePage(p) } label: {
                            Label("Remove page", systemImage: "trash").font(.system(size: 12)).foregroundColor(NeonTheme.magenta)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private func appRow(_ p: Int, _ j: Int) -> some View {
        let app = store.pages[p][j]
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 13)).foregroundColor(NeonTheme.textTertiary)
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(app.tint.opacity(0.9))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: app.symbol).font(.system(size: 13, weight: .medium)).foregroundColor(.white))
            Text(app.title).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
            Spacer()
            Button { store.removeApp(page: p, at: j) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundColor(NeonTheme.magenta)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.03)))
        .contentShape(Rectangle())
        .draggable("\(p):\(j)")
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first else { return false }
            let parts = s.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] == p else { return false }   // reorder within the page
            store.moveApp(page: p, from: parts[1], to: j)
            return true
        }
    }

    private func wallpaperBinding(_ p: Int) -> Binding<String> {
        Binding(get: { wp.perPage[p] ?? "default" },
                set: { wp.setPage(p, $0 == "default" ? nil : $0) })
    }
}

// Placeholder for on-device apps not built yet (Settings / Wallpaper / Browser).
struct HomeBuiltinView: View {
    let title: String
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(systemName: "hammer.fill").font(.system(size: 40)).foregroundColor(.white.opacity(0.5))
                Text(title).font(.system(size: 34, weight: .semibold)).foregroundColor(.white)
                Text("Coming soon — press the knob to go home")
                    .font(.system(size: 18)).foregroundColor(.white.opacity(0.5))
            }
        }
    }
}
