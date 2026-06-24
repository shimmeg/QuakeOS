// ContentView.swift — Quake4Mac (Phase 2 macro pad)
//
// Renders the current page of tiles across the Quake's ultra-wide panel. Layout is a
// fixed 5×2 grid that exactly matches the touch hit-testing in PadModel.
//
// Tile styling is a 1:1 port of DK-Suite's own on-screen tile CSS (decompiled from
// app.c9424d02.css, scopes data-v-662b433c / data-v-ff2d6586) — NOT our own invention:
//   • container : background #2f2f2f, 1px solid hsla(0,0%,100%,.07), rounded, clipped
//   • content   : a single flat colored glyph centered, label beneath
//   • pressed   : transform: scale(.8); box-shadow: 0 0 25px hsla(0,0%,100%,.4)
// Their icon assets (icon/*.png) are flat single-colour glyphs — there is no PNG
// "generator"; the polish is the dark panel + flat glyph + device backlight + this CSS.

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var wallpaper = WallpaperStore.shared

    var body: some View {
        let pad = state.pad

        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if pad.onHome {
                    ZStack {
                        WallpaperView(id: wallpaper.id(forPage: pad.homePage)).ignoresSafeArea()
                        HomeScreenView(pad: pad).ignoresSafeArea()
                    }
                    .transition(.opacity)
                } else {
                    appContent(pad)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))   // iOS-ish open/close zoom
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: pad.onHome)

            // Health dot — only shown when the knob or touchscreen has dropped (orange),
            // so a healthy panel stays clean.
            if !(state.input.knobConnected && state.input.touchConnected) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // App switcher overlay (knob: turn to scrub recents, press/tap to open).
            if pad.switcherOpen {
                AppSwitcherView(recents: pad.recents, index: pad.switcherIndex)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: pad.switcherOpen)
    }

    @ViewBuilder private func appContent(_ pad: PadModel) -> some View {
        if case .builtin("wallpaper")? = pad.currentDest {
            WallpaperAppView().ignoresSafeArea()
        } else if case .builtin("browser")? = pad.currentDest {
            BrowserAppView().ignoresSafeArea()
        } else if case .builtin("settings")? = pad.currentDest {
            SettingsAppView(input: state.input).ignoresSafeArea()
        } else if case .builtin(let b)? = pad.currentDest {
            HomeBuiltinView(title: b.capitalized).ignoresSafeArea()
        } else {
            switch pad.extra {
            case .monitor:
                MonitorDeviceView().ignoresSafeArea()              // persistent, pre-warmed webview
            case .music:
                MusicScreenView().ignoresSafeArea()        // proven path; new persistent MusicDeviceView stays dormant until on-device test
            case .clock:
                ClockDeviceView().ignoresSafeArea()
            case .weather:
                WeatherScreenView().ignoresSafeArea()
            case .none:
                switch pad.currentKind {
                case .grid:                            ScreenWebView(pad: pad).ignoresSafeArea()
                case .app(let id) where id == "clock": ClockDeviceView().ignoresSafeArea()
                case .web(let url):                    WebDashboardView(urlString: url).ignoresSafeArea()
                case .app:                             ScreenWebView(pad: pad).ignoresSafeArea()
                }
            }
        }
    }
}

// MARK: - Radial page switcher

private struct PageSwitcher: View {
    let titles: [String]
    let index: Int

    private let cyan = Color(red: 0.18, green: 0.85, blue: 1.0)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cy = h * 0.5
            let cX = w + 80                 // circle centre off-screen right → only a gentle slice shows
            let arcR: CGFloat = 300          // big radius = gentle curve (≈half the previous curvature)
            let itemR = arcR + 26
            let dStep = 7.0                  // degrees between items (tighter → more fit)
            let maxOff = 5                   // show up to 11 labels at once (was 2 → 5 items)
            ZStack {
                Color.black.opacity(0.72).ignoresSafeArea()

                // Gentle glowing arc near the knob.
                Circle()
                    .trim(from: 0.34, to: 0.66)
                    .stroke(cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: arcR * 2, height: arcR * 2)
                    .shadow(color: cyan.opacity(0.9), radius: 9)
                    .shadow(color: cyan.opacity(0.5), radius: 20)
                    .position(x: cX, y: cy)

                // Each label rotated to its own radial angle (centre horizontal, others tilt).
                ForEach(titles.indices, id: \.self) { i in
                    let off = offset(i)
                    if abs(off) <= maxOff {
                        let sel = (off == 0)
                        let angle = (180.0 - Double(off) * dStep) * .pi / 180.0
                        let px = cX + itemR * CGFloat(cos(angle))
                        let py = cy + itemR * CGFloat(sin(angle))
                        Text(titles[i])
                            .font(.system(size: sel ? 28 : 17, weight: sel ? .bold : .medium, design: .rounded))
                            .foregroundColor(sel ? cyan : cyan.opacity(0.5))
                            .brightness(sel ? 0.15 : 0)
                            .shadow(color: cyan.opacity(sel ? 0.8 : 0.3), radius: sel ? 10 : 4)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: 240, alignment: .trailing)
                            .rotationEffect(.degrees(-Double(off) * dStep), anchor: .trailing)
                            .position(x: px - 120, y: py)   // text right edge meets the arc point
                            .opacity(1.0 - abs(Double(off)) * 0.12)
                    }
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: index)
        }
    }

    private func offset(_ i: Int) -> Int {
        let n = titles.count
        var d = i - index
        if d > n / 2 { d -= n }
        if d < -n / 2 { d += n }
        return d
    }
}

// MARK: - Wallpaper

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.11), .black],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.11, green: 0.13, blue: 0.22).opacity(0.65), .clear],
                           center: .center, startRadius: 8, endRadius: 1000)
        }
    }
}

// MARK: - Tile asset resolution (used by the WebView screen)

enum DecoAssets {
    /// DecoKee glyph PNG bundled under Icons/.
    static func icon(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons") else { return nil }
        return NSImage(contentsOf: url)
    }
    /// The real macOS icon for an installed app.
    static func appIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
