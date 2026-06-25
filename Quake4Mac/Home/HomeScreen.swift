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

    /// The home app matching a destination (for the app switcher's icon/label); falls back to the catalog.
    func appFor(_ dest: AppDest) -> HomeApp? { allApps.first { $0.dest == dest } ?? HomeStore.catalog().first { $0.dest == dest } }

    // MARK: editing (used by the Mac-side Home Layout editor)
    func addPage() { pages.append([]) }
    func removePage(_ i: Int) { guard pages.count > 1, pages.indices.contains(i) else { return }; pages.remove(at: i); WallpaperStore.shared.removePageIndex(i) }
    func addApp(_ app: HomeApp, toPage i: Int) {
        guard pages.indices.contains(i) else { return }
        pages[i].append(HomeApp(title: app.title, symbol: app.symbol, tint: app.tint, dest: app.dest))
    }
    func insertApp(_ app: HomeApp, page i: Int, at k: Int) {
        guard pages.indices.contains(i) else { return }
        let idx = min(max(0, k), pages[i].count)
        pages[i].insert(HomeApp(title: app.title, symbol: app.symbol, tint: app.tint, dest: app.dest), at: idx)
    }
    func removeApp(page i: Int, at j: Int) { guard pages.indices.contains(i), pages[i].indices.contains(j) else { return }; pages[i].remove(at: j) }
    func moveApp(page i: Int, from j: Int, to k: Int) {
        guard pages.indices.contains(i), pages[i].indices.contains(j), k >= 0, k < pages[i].count else { return }
        let a = pages[i].remove(at: j); pages[i].insert(a, at: k)
    }

    /// Commit a whole new layout (the editor's saved draft) → device + disk.
    func replace(_ newPages: [[HomeApp]]) { pages = newPages }

    /// Every app you can drop onto a home page (built-ins, panels, and your macro pages).
    static func catalog() -> [HomeApp] {
        var out: [HomeApp] = [
            HomeApp(title: "Clock",     symbol: "clock.fill",     tint: .orange, dest: .panel("clock")),
            HomeApp(title: "Music",     symbol: "music.note",     tint: .pink,   dest: .panel("music")),
            HomeApp(title: "Monitor",   symbol: "cpu",            tint: .green,  dest: .panel("monitor")),
            HomeApp(title: "Settings",  symbol: "gearshape.fill", tint: .gray,   dest: .builtin("settings")),
            HomeApp(title: "Wallpaper", symbol: "photo.fill",     tint: .blue,   dest: .builtin("wallpaper")),
            HomeApp(title: "Browser",   symbol: "globe",          tint: .purple, dest: .builtin("browser")),
            HomeApp(title: "Weather",   symbol: "cloud.sun.fill", tint: .cyan,   dest: .panel("weather")),
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
            HomeApp(title: "Weather",  symbol: "cloud.sun.fill",   tint: .cyan,   dest: .panel("weather")),
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

// Draft/Save session for the Home Layout editor. Edits go to a draft shown in the live hero
// preview; the Quake home only changes when you Save (commit → HomeStore + WallpaperStore).
final class HomeEditSession: ObservableObject {
    static let shared = HomeEditSession()
    @Published var draft: [[HomeApp]] = []
    @Published var wallpaperDraft: [Int: String] = [:]
    @Published var editPage = 0
    @Published var dirty = false
    private init() {}

    func begin() {
        draft = HomeStore.shared.pages
        wallpaperDraft = WallpaperStore.shared.perPage
        editPage = min(editPage, max(0, draft.count - 1))
        dirty = false
    }
    func save() { HomeStore.shared.replace(draft); WallpaperStore.shared.replacePerPage(wallpaperDraft); dirty = false }
    func revert() { begin() }

    func app(page i: Int, slot j: Int) -> HomeApp? {
        guard draft.indices.contains(i), draft[i].indices.contains(j) else { return nil }
        return draft[i][j]
    }
    func insert(destKey key: String, page i: Int, at k: Int) {
        guard draft.indices.contains(i), let a = HomeStore.catalog().first(where: { $0.dest.storageKey == key }) else { return }
        draft[i].insert(HomeApp(title: a.title, symbol: a.symbol, tint: a.tint, dest: a.dest), at: min(max(0, k), draft[i].count)); dirty = true
    }
    func move(page i: Int, from j: Int, to k: Int) {
        guard draft.indices.contains(i), draft[i].indices.contains(j), k >= 0, k < draft[i].count else { return }
        let a = draft[i].remove(at: j); draft[i].insert(a, at: k); dirty = true
    }
    func remove(page i: Int, at j: Int) { guard draft.indices.contains(i), draft[i].indices.contains(j) else { return }; draft[i].remove(at: j); dirty = true }
    func addPage() { draft.append([]); wallpaperDraft[draft.count - 1] = nil; editPage = draft.count - 1; dirty = true }
    func removePage(_ i: Int) { guard draft.count > 1, draft.indices.contains(i) else { return }; draft.remove(at: i); wallpaperDraft = Dictionary(uniqueKeysWithValues: wallpaperDraft.compactMap { (k, v) in k == i ? nil : (k > i ? (k - 1, v) : (k, v)) }); editPage = min(editPage, draft.count - 1); dirty = true }
    func wallpaper(page i: Int) -> String { wallpaperDraft[i] ?? "default" }
    func setWallpaper(page i: Int, _ id: String?) { wallpaperDraft[i] = (id == "default" ? nil : id); dirty = true }
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
    @ObservedObject var pad: PadModel

    private let M = HomeLayoutMetrics.self
    private var page: Int { pad.homePage }

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

                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !pad.editMode)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    VStack(spacing: 0) {
                        ForEach(0..<M.rows, id: \.self) { r in
                            HStack(spacing: 0) {
                                ForEach(0..<M.cols, id: \.self) { c in
                                    let idx = r * M.cols + c
                                    Group {
                                        if idx < apps.count { iconCell(apps[idx], size: size, index: idx, t: t) } else { Color.clear }
                                    }
                                    .frame(width: cellW, height: cellH)
                                }
                            }
                        }
                    }
                    .frame(width: gridW, height: gridH)
                    .animation(.spring(response: 0.28, dampingFraction: 0.8), value: apps.map { $0.id })
                }
                .frame(width: gridW, height: gridH)
                .position(x: w / 2, y: h * M.topFrac + gridH / 2)

                dots.position(x: w / 2, y: h * (1 - M.bottomFrac / 2))

                // Lifted icon that follows the finger while dragging in edit mode.
                if pad.editMode, let ds = pad.draggingSlot, let dp = pad.dragPoint, ds < apps.count {
                    iconGlyph(apps[ds], size: size * 1.15)
                        .position(x: dp.x * w, y: dp.y * h)
                        .shadow(color: .black.opacity(0.5), radius: 12)
                }
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

    private func iconGlyph(_ app: HomeApp, size: CGFloat) -> some View {
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
    }

    private func iconCell(_ app: HomeApp, size: CGFloat, index: Int, t: Double) -> some View {
        let dragging = pad.editMode && pad.draggingSlot == index
        // Continuous clock-driven wobble — keeps jiggling through reflow (per-icon phase).
        let angle: Double = (pad.editMode && !dragging) ? sin(t * 9 + Double(index) * 0.9) * 2.0 : 0
        return iconGlyph(app, size: size)
            .opacity(dragging ? 0.25 : 1)          // the lifted icon shows as the floating copy
            .rotationEffect(.degrees(angle))
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
    @ObservedObject private var s = HomeEditSession.shared
    private let lib = [GridItem(.adaptive(minimum: 86, maximum: 120), spacing: 12, alignment: .top)]

    private var wallpaperOptions: [(String, String)] {
        [("default", "Default (global)")] + WallpaperStore.options.map { ($0.id, $0.title) }
    }
    private var page: Int { min(s.editPage, max(0, s.draft.count - 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                SettingsHeader(title: "Layout",
                               subtitle: "Drag an app from the library onto the live home screen above. Arrows switch pages; drag an icon to the trash to remove it. Changes hit the Quake only when you Save.")
                Spacer(minLength: 16)
                saveBar
            }
            controlsRow
            NeonCard("Apps — drag onto the home screen above") {
                LazyVGrid(columns: lib, spacing: 12) {
                    ForEach(HomeStore.catalog()) { app in
                        libTile(app).draggable("lib:\(app.dest.storageKey)")
                    }
                }
                .padding(.vertical, 8)
            }
            trashZone
            Spacer()
        }
        .onAppear { s.begin() }
    }

    private var saveBar: some View {
        HStack(spacing: 10) {
            if s.dirty {
                Text("Unsaved").font(.system(size: 10, weight: .semibold)).foregroundColor(NeonTheme.magenta)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(NeonTheme.magenta.opacity(0.14)))
            }
            barButton("Revert", NeonTheme.textSecondary, enabled: s.dirty) { s.revert() }
            barButton("Save to Quake", NeonTheme.cyan, enabled: s.dirty) { s.save() }
        }
    }
    private func barButton(_ title: String, _ tint: Color, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(enabled ? tint : NeonTheme.textTertiary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(enabled ? 0.14 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(enabled ? 0.4 : 0.12), lineWidth: 1))
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            arrow("chevron.left", enabled: page > 0) { s.editPage = max(0, page - 1) }
            arrow("chevron.right", enabled: page < s.draft.count - 1) { s.editPage = min(s.draft.count - 1, page + 1) }
            Text("Page \(page + 1) of \(s.draft.count)").font(.system(size: 12)).foregroundColor(NeonTheme.textSecondary)
            HStack(spacing: 6) {
                ForEach(0..<s.draft.count, id: \.self) { i in
                    Circle().fill(i == page ? NeonTheme.cyan : Color.white.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            Spacer()
            Picker("", selection: wallpaperBinding(page)) {
                ForEach(wallpaperOptions, id: \.0) { Text($0.1).tag($0.0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 190)
            Button { s.addPage() } label: {
                Label("Add page", systemImage: "plus").font(.system(size: 12, weight: .medium)).foregroundColor(NeonTheme.cyan)
            }.buttonStyle(.plain)
            if s.draft.count > 1 {
                Button { s.removePage(page) } label: {
                    Label("Remove page", systemImage: "trash").font(.system(size: 12)).foregroundColor(NeonTheme.magenta)
                }.buttonStyle(.plain)
            }
        }
    }

    private func arrow(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .foregroundColor(enabled ? NeonTheme.cyan : NeonTheme.textTertiary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(NeonTheme.panel)).overlay(Circle().strokeBorder(NeonTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private var trashZone: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash"); Text("Drag an app here to remove it").font(.system(size: 12))
        }
        .foregroundColor(NeonTheme.textTertiary)
        .frame(maxWidth: .infinity).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(NeonTheme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5])))
        .dropDestination(for: String.self) { items, _ in
            guard let str = items.first, str.hasPrefix("idx:"), let j = Int(str.dropFirst(4)) else { return false }
            s.remove(page: page, at: j); return true
        }
    }

    private func libTile(_ app: HomeApp) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(app.tint.opacity(0.92))
                .frame(width: 54, height: 54)
                .overlay(Image(systemName: app.symbol).font(.system(size: 24, weight: .medium)).foregroundColor(.white))
            Text(app.title).font(.system(size: 10, weight: .medium)).foregroundColor(NeonTheme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: 92)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func wallpaperBinding(_ p: Int) -> Binding<String> {
        Binding(get: { s.wallpaper(page: p) }, set: { s.setWallpaper(page: p, $0) })
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
