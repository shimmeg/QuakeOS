// ScreenWebView.swift — Quake4Mac
//
// Renders the on-screen key grid the SAME way DK-Suite does: an HTML/CSS page in a
// WebView (screen.html), with their actual animated video wallpaper and glass-key CSS.
// Our Swift side stays the brain — it feeds the page a model (pages of keys, with each
// icon resolved to DecoKee's own PNG, the real macOS app icon, or a tinted SF Symbol)
// and tells it which key is pressed. No SwiftUI approximation of their look.

import SwiftUI
import AppKit
import WebKit

struct ScreenWebView: NSViewRepresentable {
    @ObservedObject var pad: PadModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        // NOTE: do NOT use the private setValue(false, forKey:"drawsBackground") hack —
        // on current macOS it disables the webview's painting entirely (whole screen
        // goes black). Our pages have opaque backgrounds, so opaque is correct.
        context.coordinator.web = web
        context.coordinator.pad = pad

        if let url = Bundle.main.url(forResource: "screen", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.sync(pad: pad)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        weak var pad: PadModel?
        private var loaded = false
        private var modelEnc: String?      // percent-encoded (UTF-8-safe) pages JSON, built once
        private var lastPage = -1
        private var lastPressedIdx: Int? = nil
        private var enhanced = false
        private var lastVersion = -1

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let enc = modelEnc {
                webView.evaluateJavaScript("window.QUAKE.setModel(decodeURIComponent('\(enc)'))", completionHandler: nil)
            }
            webView.evaluateJavaScript("window.QUAKE.setPage(\(max(0, lastPage)))", completionHandler: nil)
            enhanceWebIcons()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[Quake] ScreenWebView: didFail — \(error.localizedDescription)")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[Quake] ScreenWebView: didFailProvisional — \(error.localizedDescription)")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NSLog("[Quake] ScreenWebView: WebContent process terminated; reloading")
            loaded = false
            enhanced = false
            webView.reload()
        }

        /// For openURL tiles, fetch the site's brand favicon and swap it in (full colour + glow-tinted rim).
        private func enhanceWebIcons() {
            guard !enhanced, let pad = pad else { return }
            enhanced = true
            for (p, page) in pad.pages.enumerated() {
                for (i, tile) in page.tiles.enumerated() {
                    guard tile.image == nil, let urlStr = tile.openURLValue,
                          let host = URL(string: urlStr)?.host else { continue }
                    guard let fav = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128") else { continue }
                    URLSession.shared.dataTask(with: fav) { [weak self] data, _, _ in
                        guard let self, let data, let img = NSImage(data: data), let r = ScreenModel.rasterize(img) else { return }
                        let glow = r.glow ?? "#ffffff"
                        DispatchQueue.main.async {
                            self.web?.evaluateJavaScript("window.QUAKE.setKeyIcon(\(p),\(i),'data:image/png;base64,\(r.b64)','\(glow)')", completionHandler: nil)
                        }
                    }.resume()
                }
            }
        }

        func sync(pad: PadModel) {
            guard let web = web else { return }

            if modelEnc == nil { modelEnc = ScreenModel.buildModelEnc(pages: pad.pages) }
            if loaded, lastPage < 0, let enc = modelEnc {
                web.evaluateJavaScript("window.QUAKE.setModel(decodeURIComponent('\(enc)'))", completionHandler: nil)
            }

            // A Save committed new pages → rebuild the model and re-push to the device.
            if PadStore.shared.version != lastVersion {
                lastVersion = PadStore.shared.version
                modelEnc = ScreenModel.buildModelEnc(pages: pad.pages)
                enhanced = false
                if loaded, let enc = modelEnc {
                    web.evaluateJavaScript("window.QUAKE.setModel(decodeURIComponent('\(enc)'))", completionHandler: nil)
                    web.evaluateJavaScript("window.QUAKE.setPage(\(max(0, pad.pageIndex)))", completionHandler: nil)
                    enhanceWebIcons()
                }
            }

            // Page change.
            if pad.pageIndex != lastPage {
                lastPage = pad.pageIndex
                if loaded { web.evaluateJavaScript("window.QUAKE.setPage(\(pad.pageIndex))", completionHandler: nil) }
            }

            // Press / release.
            let idx: Int? = {
                guard let id = pad.pressedTileID else { return nil }
                return pad.current.tiles.firstIndex { $0.id == id }
            }()
            if idx != lastPressedIdx {
                lastPressedIdx = idx
                if loaded {
                    if let i = idx { web.evaluateJavaScript("window.QUAKE.press(\(i))", completionHandler: nil) }
                    else { web.evaluateJavaScript("window.QUAKE.release()", completionHandler: nil) }
                }
            }
        }

    }
}

// MARK: - Shared screen-model builder
//
// Builds the exact screen.html model (icons rasterized to data URLs + per-icon neon glow). Used by
// BOTH the on-device renderer (ScreenWebView) and the settings 1:1 preview, so they are byte-for-
// byte identical — the preview is literally the same renderer fed the same model.

enum ScreenModel {
    private final class IconInfoBox {
        let url: String
        let glow: String?
        let app: Bool

        init(url: String, glow: String?, app: Bool) {
            self.url = url
            self.glow = glow
            self.app = app
        }
    }

    private static let iconInfoCache = NSCache<NSString, IconInfoBox>()

    static func buildModelEnc(pages: [PadPage]) -> String? {
        var out: [[String: Any]] = []
        for page in pages {
            var keys: [[String: Any]] = []
            for tile in page.tiles {
                var k: [String: Any] = ["title": tile.title]
                if let info = iconInfo(for: tile) {
                    k["icon"] = info.url
                    if let g = info.glow { k["glow"] = g }
                    if info.app { k["app"] = true }
                }
                keys.append(k)
            }
            out.append(["name": page.name, "keys": keys])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: []) else { return nil }
        // Percent-encode so UTF-8 (e.g. the "–" en-dash) survives the JS bridge intact.
        let json = String(decoding: data, as: UTF8.self)
        return json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }

    static func iconInfo(for tile: Tile) -> (url: String, glow: String?, app: Bool)? {
        let key: String
        let image: NSImage
        let fallbackGlow: String?
        let app: Bool

        if let name = tile.image, let img = DecoAssets.icon(name) {                  // their PNG → neon glow in its own colour
            key = "image:\(name)"
            image = img
            fallbackGlow = nil
            app = false
        } else if let bid = tile.appBundleID, let img = DecoAssets.appIcon(bid) {    // real app icon → full colour
            key = "app:\(bid)"
            image = img
            fallbackGlow = nil
            app = true
        } else {
            key = "symbol:\(tile.symbol):\(tile.tint.hexRGB)"
            if let cached = iconInfoCache.object(forKey: key as NSString) {
                return (cached.url, cached.glow, cached.app)
            }
            guard let img = symbol(tile.symbol, color: NSColor(tile.tint)) else { return nil } // tinted SF Symbol → neon glow
            image = img
            fallbackGlow = hex(NSColor(tile.tint))
            app = false
        }

        if let cached = iconInfoCache.object(forKey: key as NSString) {
            return (cached.url, cached.glow, cached.app)
        }
        guard let r = rasterize(image) else { return nil }
        let box = IconInfoBox(url: "data:image/png;base64,\(r.b64)", glow: r.glow ?? fallbackGlow, app: app)
        iconInfoCache.setObject(box, forKey: key as NSString)
        return (box.url, box.glow, box.app)
    }

    static func symbol(_ name: String, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let out = NSImage(size: base.size)
        out.lockFocus()
        color.set()
        let r = NSRect(origin: .zero, size: base.size)
        base.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
        r.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    /// Rasterize to PNG base64 AND compute a vivid "neon" glow colour from the icon's own pixels.
    static func rasterize(_ image: NSImage, side: Int = 96) -> (b64: String, glow: String?)? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }

        var rs = 0.0, gs = 0.0, bs = 0.0, n = 0.0
        for y in stride(from: 0, to: side, by: 4) {
            for x in stride(from: 0, to: side, by: 4) {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.35 else { continue }
                rs += Double(c.redComponent); gs += Double(c.greenComponent); bs += Double(c.blueComponent); n += 1
            }
        }
        var glow: String? = nil
        if n > 0 {
            var r = rs / n, g = gs / n, b = bs / n
            let mx = max(r, max(g, b))
            if mx > 0.01 { r /= mx; g /= mx; b /= mx }
            glow = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
        return (png.base64EncodedString(), glow)
    }

    static func hex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.deviceRGB) ?? c
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
