// QuakeStripPreview.swift — Quake4Mac settings app
//
// The hero "LIVE" preview. To be a TRUE 1:1 of the device it renders the SAME screen.html via a
// WebView (QuakePreviewWeb) fed the SAME model builder (ScreenModel) — not a SwiftUI lookalike.
// While editing a page it shows the editor DRAFT (TileEditSession) and each cell is a drop target;
// the committed device state is untouched until Save.

import SwiftUI
import WebKit

struct QuakeStripPreview: View {
    var pageName: String = "Studio"
    /// Set when a macro page is selected → the strip is an editable drop target for the draft.
    var editingPageIndex: Int? = nil

    @ObservedObject private var rgbSession = RGBEditSession.shared
    @ObservedObject private var live = RGBLiveState.shared      // what's ACTUALLY on the knob now
    @ObservedObject private var store = PadStore.shared
    @ObservedObject private var session = TileEditSession.shared
    @ObservedObject private var homeSession = HomeEditSession.shared

    // Device panel logical size + the on-screen strip size (kept exactly 4:1). Height + whether the
    // knob shows follow the "Live preview" setting (Bar = compact strip only, Hero = full, Dock = mid).
    @AppStorage("settings.previewMode") private var previewMode = "Hero"
    private let panelW: CGFloat = 1920, panelH: CGFloat = 480
    private var stripH: CGFloat { previewMode == "Bar" ? 116 : (previewMode == "Dock" ? 150 : 200) }
    private var showKnob: Bool { previewMode != "Bar" }
    private var stripW: CGFloat { stripH * (panelW / panelH) }
    private var scale: CGFloat { stripW / panelW }

    private var isEditing: Bool { editingPageIndex != nil }
    private var previewPages: [PadPage] { isEditing ? session.draft : store.pages }
    private var previewIndex: Int { previewPages.firstIndex { $0.name == pageName } ?? 0 }
    /// True only for real macro pages (Apps/System/Web). Prebuilt panels (Music/Stats) aren't tile grids.
    private var isPage: Bool { previewPages.contains { $0.name == pageName } }
    /// The kind of the previewed page (nil if it's a prebuilt panel, not a page).
    private var previewPageKind: PadPageKind? { previewPages.first { $0.name == pageName }?.kind }
    private var isGridPage: Bool { if case .grid = previewPageKind { return true }; return false }

    /// The RGB state the knob ring should reflect: the live draft while editing RGB, else committed.
    private var rgbState: (effect: Int, hue: Double, sat: Double, brightness: Double, speed: Double) {
        if rgbSession.active { return (rgbSession.effect, rgbSession.hue, rgbSession.sat, rgbSession.brightness, rgbSession.speed) }
        // Not editing RGB → mirror the actual device ring (includes reactive-lighting overrides).
        return (live.effect, live.hue, live.sat, live.brightness, live.speed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7).neonGlow(.green, radius: 5)
                Text("LIVE · DK-QUAKE STRIP 1920×480")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.4)
                    .foregroundColor(NeonTheme.textSecondary)
                Spacer()
                Text(isEditing ? "\(pageName) · editing" : "\(pageName) · 60fps")
                    .font(.system(size: 10)).foregroundColor(isEditing ? NeonTheme.cyan : NeonTheme.textTertiary)
            }
            HStack(spacing: 18) {
                strip
                if showKnob { knob.frame(width: 188) }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .glowCard(cornerRadius: 18)
    }

    // MARK: Strip — the real device renderer, 1:1. Macro pages → screen.html (editable); built-in
    // panels → their actual monitor/music renderers (non-interactive in preview).
    @ViewBuilder private var strip: some View {
        if isGridPage {
            ZStack(alignment: .topLeading) {
                QuakePreviewWeb(pages: previewPages, pageIndex: previewIndex, zoom: scale)
                    .frame(width: stripW, height: stripH)
                if isEditing { dropOverlay }
            }
            .frame(width: stripW, height: stripH)
            .modifier(StripChrome())
        } else if case .web(let url)? = previewPageKind {
            WebDashboardView(urlString: url)
                .frame(width: stripW, height: stripH)
                .modifier(StripChrome())
        } else if pageName == "System Monitor" {
            SystemMonitorView(interactive: false)
                .frame(width: stripW, height: stripH)
                .modifier(StripChrome())
        } else if pageName == "Music" {
            MusicScreenView(interactive: false, zoom: scale)
                .frame(width: stripW, height: stripH)
                .modifier(StripChrome())
        } else if pageName == "Clock" {
            ClockScreenView(interactive: false, zoom: scale)
                .frame(width: stripW, height: stripH)
                .modifier(StripChrome())
        } else if pageName == "Weather" {
            WeatherScreenView(interactive: false, zoom: scale)
                .frame(width: stripW, height: stripH)
                .modifier(StripChrome())
        } else if pageName == "Layout" {
            homeEditStrip
        } else {
            panelPlaceholder
        }
    }

    private struct StripChrome: ViewModifier {
        func body(content: Content) -> some View {
            content
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
        }
    }

    // The home springboard rendered in the hero strip as a live, editable drop target (draft).
    private var homeEditStrip: some View {
        let M = HomeLayoutMetrics.self
        let page = min(homeSession.editPage, max(0, homeSession.draft.count - 1))
        let apps = homeSession.draft.indices.contains(page) ? homeSession.draft[page] : []
        let gridW = stripW * (1 - 2 * M.sideFrac), gridH = stripH * (1 - M.topFrac - M.bottomFrac)
        let cellW = gridW / CGFloat(M.cols), cellH = gridH / CGFloat(M.rows)
        let size = min(cellW, cellH) * 0.5
        return ZStack(alignment: .topLeading) {
            WallpaperView(id: homeSession.wallpaperDraft[page] ?? WallpaperStore.shared.defaultID)
            Color.black.opacity(0.25)
            VStack(spacing: 0) {
                ForEach(0..<M.rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<M.cols, id: \.self) { c in homeCell(r * M.cols + c, page: page, apps: apps, cellW: cellW, cellH: cellH, size: size) }
                    }
                }
            }
            .frame(width: gridW, height: gridH)
            .position(x: stripW / 2, y: stripH * M.topFrac + gridH / 2)
        }
        .frame(width: stripW, height: stripH)
        .modifier(StripChrome())
    }

    @ViewBuilder private func homeCell(_ k: Int, page: Int, apps: [HomeApp], cellW: CGFloat, cellH: CGFloat, size: CGFloat) -> some View {
        let app = apps.indices.contains(k) ? apps[k] : nil
        ZStack {
            if let app { homeIcon(app, size: size).draggable("idx:\(k)") }
        }
        .frame(width: cellW, height: cellH)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first else { return false }
            let count = homeSession.draft.indices.contains(page) ? homeSession.draft[page].count : 0
            if s.hasPrefix("lib:") { homeSession.insert(destKey: String(s.dropFirst(4)), page: page, at: min(k, count)); return true }
            if s.hasPrefix("idx:"), let j = Int(s.dropFirst(4)) { homeSession.move(page: page, from: j, to: min(k, max(0, count - 1))); return true }
            return false
        }
    }

    private func homeIcon(_ app: HomeApp, size: CGFloat) -> some View {
        VStack(spacing: size * 0.14) {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(app.tint.opacity(0.92))
                .frame(width: size, height: size)
                .overlay(Image(systemName: app.symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundColor(.white))
            Text(app.title).font(.system(size: size * 0.2, weight: .medium)).foregroundColor(.white.opacity(0.9)).lineLimit(1)
        }
    }

    private var panelPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed").font(.system(size: 30)).foregroundColor(NeonTheme.textTertiary)
            Text("\(pageName)").font(.system(size: 13, weight: .medium)).foregroundColor(NeonTheme.textSecondary)
        }
        .frame(width: stripW, height: stripH)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.4)))
        .modifier(StripChrome())
    }

    // 8×2 transparent drop grid in panel (1920×480) coordinates, matching screen.html's padding/gap,
    // so cells line up exactly with the rendered tiles after scaling.
    private var dropOverlay: some View {
        let pad: CGFloat = 14 * scale, gap: CGFloat = 8 * scale     // on-screen px (page is zoomed)
        let cellW = (stripW - pad * 2 - gap * 7) / 8
        let cellH = (stripH - pad * 2 - gap * 1) / 2
        return VStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<8, id: \.self) { c in
                        dropCell(index: r * 8 + c).frame(width: cellW, height: cellH)
                    }
                }
            }
        }
        .padding(pad)
        .frame(width: stripW, height: stripH)
    }

    // Each cell is a drop target AND (if it holds a tile) draggable — so you can drag tiles in from
    // the library OR drag an existing tile to another cell to move/swap them.
    @ViewBuilder private func dropCell(index: Int) -> some View {
        let selected = session.selectedSlot == index
        let base = RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? NeonTheme.cyan : Color.clear, lineWidth: 3))   // highlight the tile border
            .contentShape(Rectangle())
            .onTapGesture { session.select(tileAt(index) != nil ? index : nil) }
            .dropDestination(for: String.self) { items, _ in handleDrop(items, to: index) }
        if let t = tileAt(index) {
            base.draggable(dragSpec(for: t, from: index).dragString) { dragTilePreview(t) }
        } else {
            base
        }
    }

    /// Drag image: the whole tile (panel + glow + glyph + label) at tile size, like the library drag.
    private func dragTilePreview(_ t: Tile) -> some View {
        VStack(spacing: 4) {
            TileGlyphView(symbol: t.symbol, image: t.image, tint: t.tint,
                          appBundleID: t.appBundleID, url: t.openURLValue, size: 56)
            Text(t.title).font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.85)).lineLimit(1)
        }
        .frame(width: 96, height: 86)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [t.tint.opacity(0.18), Color.black.opacity(0.35)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(t.tint.opacity(0.32), lineWidth: 1))
    }

    /// The non-empty draft tile at a slot, or nil.
    private func tileAt(_ index: Int) -> Tile? {
        guard let p = session.index(ofPage: pageName), session.draft.indices.contains(p),
              session.draft[p].tiles.indices.contains(index) else { return nil }
        let t = session.draft[p].tiles[index]
        return t.title.isEmpty ? nil : t
    }

    private func dragSpec(for tile: Tile, from index: Int) -> TileSpec {
        var s = TileSpec(from: tile, category: "page")
        s.fromSlot = index
        return s
    }

    private func handleDrop(_ items: [String], to index: Int) -> Bool {
        guard let s = items.first, let spec = TileSpec.decode(s),
              let page = session.index(ofPage: pageName) else { return false }
        if let from = spec.fromSlot, from != index {
            // Move/swap within the page: dropped tile → here; whatever was here → its old slot.
            let dest = tileAt(index) ?? PadStore.emptyTile
            session.setTile(page: page, slot: index, spec.makeTile())
            session.setTile(page: page, slot: from, dest)
        } else if spec.fromSlot == nil {
            session.setTile(page: page, slot: index, spec.makeTile())   // placed from the library
        }
        return true
    }

    // MARK: Knob — the animated RGB ring (live draft while editing RGB, else committed device state).
    private var knob: some View {
        ZStack {
            KnobRingView(effect: rgbState.effect, hue: rgbState.hue, sat: rgbState.sat,
                         brightness: rgbState.brightness, speed: rgbState.speed, diameter: 150)
            Circle().fill(RadialGradient(colors: [Color(white: 0.08), Color.black],
                                         center: .center, startRadius: 2, endRadius: 80))
                .frame(width: 132, height: 132)
            VStack(spacing: 4) {
                Text("PAGE").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundColor(NeonTheme.textTertiary)
                Text(pageName).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
            }
        }
    }
}

// MARK: - Animated knob ring (approximates the QMK effect families dynamically, driven by speed)

struct KnobRingView: View {
    let effect: Int
    let hue: Double          // 0–255
    let sat: Double          // 0–255
    let brightness: Double   // 0–255
    let speed: Double        // 0–255
    var diameter: CGFloat = 150
    var lineWidth: CGFloat = 10

    private var baseColor: Color { Color(hue: hue / 255, saturation: max(0.12, sat / 255), brightness: 1) }
    private var dim: Double { max(0.12, brightness / 255) }
    private var isOff: Bool { effect == 0 || brightness <= 0 }

    private static let rainbow: Set<Int>   = [12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 26, 27]
    private static let gradient: Set<Int>  = [3, 4, 6, 7, 8, 9, 10, 11]
    private static let breathing: Set<Int> = [5, 25]
    private static let sparkle: Set<Int>   = [23, 24, 28, 29, 30, 32]
    private static let spectrum: [Color]   = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red]

    var body: some View {
        TimelineView(.animation) { ctx in
            ring(ctx.date.timeIntervalSinceReferenceDate)
                .frame(width: diameter, height: diameter)
        }
    }

    @ViewBuilder private func ring(_ t: TimeInterval) -> some View {
        if isOff {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
        } else if Self.rainbow.contains(effect) {
            let deg = (t * (20 + speed / 255 * 340)).truncatingRemainder(dividingBy: 360)
            Circle().stroke(AngularGradient(colors: Self.spectrum, center: .center), lineWidth: lineWidth)
                .rotationEffect(.degrees(deg)).opacity(dim)
                .neonGlow(NeonTheme.magenta, radius: 16, opacity: 0.55)
        } else if Self.gradient.contains(effect) {
            let deg = (t * (8 + speed / 255 * 70)).truncatingRemainder(dividingBy: 360)
            Circle().stroke(AngularGradient(colors: [baseColor, baseColor.opacity(0.25), baseColor], center: .center), lineWidth: lineWidth)
                .rotationEffect(.degrees(deg)).opacity(dim)
                .neonGlow(baseColor, radius: 14, opacity: 0.55)
        } else if Self.breathing.contains(effect) {
            let period = 2.0 + (1 - speed / 255) * 3
            let pulse = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 2 * .pi / period))
            Circle().stroke(baseColor, lineWidth: lineWidth).opacity(dim * pulse)
                .neonGlow(baseColor, radius: 16, opacity: 0.5 * pulse)
        } else if Self.sparkle.contains(effect) {
            let flick = 0.65 + 0.35 * sin(t * 7)
            Circle().stroke(baseColor, lineWidth: lineWidth).opacity(dim * flick)
                .neonGlow(baseColor, radius: 12, opacity: 0.45)
        } else {
            Circle().stroke(baseColor, lineWidth: lineWidth).opacity(dim)
                .neonGlow(baseColor, radius: 14, opacity: 0.55)
        }
    }
}

// MARK: - The screen.html renderer, reused for the preview (identical to the device path).

struct QuakePreviewWeb: NSViewRepresentable {
    var pages: [PadPage]
    var pageIndex: Int
    var zoom: CGFloat = 1     // CSS zoom so the 1920-logical page renders into the small strip

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)   // SwiftUI sizes it to the strip
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "screen", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.update(pages: pages, page: pageIndex, zoom: zoom)
    }

    final class Coord: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var loaded = false
        private var pending: (String, Int, CGFloat)?
        private var lastEnc: String?
        private var lastPage = -1
        private var lastZoom: CGFloat = -1
        private var lastPages: [PadPage] = []
        private static var favCache: [String: (b64: String, glow: String)] = [:]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let (enc, pg, z) = pending { push(enc, pg, z); pending = nil }
        }

        func update(pages: [PadPage], page: Int, zoom: CGFloat) {
            lastPages = pages
            let enc = ScreenModel.buildModelEnc(pages: pages) ?? ""
            guard loaded else { pending = (enc, page, zoom); return }
            if enc != lastEnc || page != lastPage || zoom != lastZoom { push(enc, page, zoom) }
        }

        private func push(_ enc: String, _ page: Int, _ zoom: CGFloat) {
            lastEnc = enc; lastPage = page; lastZoom = zoom
            // Zoom the whole page so the device's 1920-logical layout fits the small strip exactly.
            let js = "document.documentElement.style.zoom='\(zoom)';"
                   + "window.QUAKE.setModel(decodeURIComponent('\(enc)'));"
                   + "window.QUAKE.setPage(\(page))"
            web?.evaluateJavaScript(js, completionHandler: nil)
            enhanceFavicons()
        }

        /// Web-link tiles (no DecoKee PNG): swap in the site's real favicon, exactly like the device.
        private func enhanceFavicons() {
            guard lastPages.indices.contains(lastPage) else { return }
            for (i, tile) in lastPages[lastPage].tiles.enumerated() {
                guard tile.image == nil, let urlStr = tile.openURLValue,
                      let host = URL(string: urlStr)?.host else { continue }
                if let c = Coord.favCache[host] { setKeyIcon(lastPage, i, c.b64, c.glow); continue }
                guard let fav = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128") else { continue }
                URLSession.shared.dataTask(with: fav) { [weak self] data, _, _ in
                    guard let self, let data, let img = NSImage(data: data),
                          let r = ScreenModel.rasterize(img) else { return }
                    let glow = r.glow ?? "#ffffff"
                    Coord.favCache[host] = (r.b64, glow)
                    DispatchQueue.main.async { self.setKeyIcon(self.lastPage, i, r.b64, glow) }
                }.resume()
            }
        }

        private func setKeyIcon(_ page: Int, _ idx: Int, _ b64: String, _ glow: String) {
            web?.evaluateJavaScript(
                "window.QUAKE.setKeyIcon(\(page),\(idx),'data:image/png;base64,\(b64)','\(glow)')",
                completionHandler: nil)
        }
    }
}
