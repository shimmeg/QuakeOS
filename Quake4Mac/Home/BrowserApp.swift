// BrowserApp.swift — Quake4Mac
//
// An embedded web browser that runs ON the Quake panel (a real WKWebView, not Safari on the Mac).
// The panel is a normal display driven by the Mac, so the Mac keyboard/mouse work here: the address
// bar accepts typed URLs or search terms, and web text fields take keyboard input when focused.
// Device HID touches are also bridged — a tap follows links / clicks elements, a vertical drag
// scrolls. A thin top toolbar gives Back / Home / address bar / Reload. Starts on a bookmark page.

import SwiftUI
import WebKit

final class BrowserController: ObservableObject {
    @Published var address: String = ""
    @Published var focusTick = 0       // bumped to request the address bar take keyboard focus
    weak var web: WKWebView?

    /// Make the panel window the key window so the Mac keyboard types here.
    func makeKey() { web?.window?.makeKey() }
    /// Focus the address bar (touch can't focus native fields on its own).
    func focusAddress() { makeKey(); focusTick += 1 }

    var homeURL: URL? { Bundle.main.url(forResource: "browser-home", withExtension: "html", subdirectory: "Web") }

    func loadHome() { if let u = homeURL { web?.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()); address = "" } }
    func back() { web?.goBack() }
    func reload() { web?.reload() }

    /// Treat input as a URL if it looks like one, otherwise Google-search it.
    func go(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var urlStr = t
        let looksLikeURL = t.contains(".") && !t.contains(" ")
        if looksLikeURL {
            if !t.lowercased().hasPrefix("http") { urlStr = "https://" + t }
        } else {
            let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
            urlStr = "https://www.google.com/search?q=\(q)"
        }
        if let u = URL(string: urlStr) { web?.load(URLRequest(url: u)) }
    }

    func updateAddress() {
        guard let url = web?.url else { return }
        address = url.isFileURL ? "" : url.absoluteString
    }
}

struct BrowserAppView: View {
    @StateObject private var ctrl = BrowserController()
    @FocusState private var addrFocused: Bool
    static let toolbarFrac: CGFloat = 0.14

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                toolbar(w: geo.size.width)
                    .frame(height: geo.size.height * Self.toolbarFrac)
                BrowserWebView(ctrl: ctrl, toolbarFrac: Self.toolbarFrac)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func toolbar(w: CGFloat) -> some View {
        HStack(spacing: w * 0.015) {
            Button(action: ctrl.back) { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Button(action: ctrl.loadHome) { Image(systemName: "house.fill") }.buttonStyle(.plain)
            TextField("Search or enter address", text: $ctrl.address)
                .textFieldStyle(.plain).font(.system(size: 22))
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                .focused($addrFocused)
                .onSubmit { ctrl.go(ctrl.address); addrFocused = false }
                .onChange(of: ctrl.focusTick) { _ in addrFocused = true }
            Button(action: ctrl.reload) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
        }
        .font(.system(size: 30, weight: .semibold))
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, w * 0.025)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06))
    }
}

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var ctrl: BrowserController
    let toolbarFrac: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(ctrl: ctrl, toolbarFrac: toolbarFrac) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let bridge = """
        window.__quakeTap = function(nx, ny){
          var x = nx*window.innerWidth, y = ny*window.innerHeight;
          var el = document.elementFromPoint(x, y); if(!el) return;
          var a = el.closest && el.closest('a[href]');
          if(a && a.href){ window.location.href = a.href; return; }
          ['mousedown','mouseup','click'].forEach(function(t){
            try{ el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,clientX:x,clientY:y,view:window})); }catch(e){}
          });
          var f = el.closest && el.closest('input,textarea,select,[contenteditable]');
          if(f && f.getAttribute && f.getAttribute('contenteditable') === 'false') f = null;
          if(!f && el.matches && el.matches('input,textarea,select')) f = el;
          if(f && f.focus){ try{ f.focus(); }catch(e){} }
        };
        window.__quakeScroll = function(dx, dy){ window.scrollBy(dx, dy); };
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        web.navigationDelegate = context.coordinator
        ctrl.web = web
        ctrl.loadHome()

        let coord = context.coordinator
        ScreenTouchRouter.shared.install(owner: coord,
            began: { [weak coord] p in coord?.began(p) },
            moved: { [weak coord] p in coord?.moved(p) },
            ended: { [weak coord] in coord?.ended() })
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        ScreenTouchRouter.shared.release(owner: coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let ctrl: BrowserController
        let toolbarFrac: CGFloat
        private var start: CGPoint?
        private var last: CGPoint?
        init(ctrl: BrowserController, toolbarFrac: CGFloat) { self.ctrl = ctrl; self.toolbarFrac = toolbarFrac }

        func began(_ p: CGPoint) { start = p; last = p }
        func moved(_ p: CGPoint) {
            defer { last = p }
            guard let s = start, let l = last, let web = ctrl.web, s.y >= toolbarFrac else { return }
            let px = (l.y - p.y) / (1 - toolbarFrac) * web.bounds.height
            if abs(px) > 0.5 { web.evaluateJavaScript("window.__quakeScroll && window.__quakeScroll(0, \(px));", completionHandler: nil) }
        }
        func ended() {
            defer { start = nil; last = nil }
            guard let s = start, let e = last, let web = ctrl.web else { return }
            guard max(abs(e.x - s.x), abs(e.y - s.y)) < 0.02 else { return }   // drag, not tap
            if s.y < toolbarFrac {
                if s.x < 0.08 { ctrl.back() }
                else if s.x < 0.16 { ctrl.loadHome() }
                else if s.x > 0.92 { ctrl.reload() }
                else { ctrl.focusAddress() }                 // tap the address bar → focus + keyboard
            } else {
                ctrl.makeKey()                               // so typing into web fields reaches them
                let ny = (s.y - toolbarFrac) / (1 - toolbarFrac)
                web.evaluateJavaScript("window.__quakeTap && window.__quakeTap(\(s.x), \(ny));", completionHandler: nil)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { ctrl.updateAddress() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ctrl.updateAddress() }
    }
}
