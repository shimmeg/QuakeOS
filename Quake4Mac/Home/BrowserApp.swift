// BrowserApp.swift — Quake4Mac
//
// On-panel web browser (real WKWebView, not Safari). Persistent multi-tab session that survives
// leaving/reopening the app, a left tab sidebar (scrollable) for multiple open sites, a top toolbar
// (Back / Home / address bar / Reload), and a bookmark "new tab" page whose tiles are editable from
// the Mac settings (Prebuilt Panels → Browser). Device HID touches are bridged: tap follows links /
// focuses fields, vertical drag scrolls. The Mac keyboard/mouse work on the panel display too.

import SwiftUI
import WebKit
import AppKit

// MARK: - Bookmarks (editable on the Mac, shown on the browser home page)

struct BookmarkItem: Codable, Identifiable, Equatable { var id = UUID(); var name: String; var url: String }

final class BrowserBookmarks: ObservableObject {
    static let shared = BrowserBookmarks()
    @Published var items: [BookmarkItem] { didSet { save() } }
    private static let key = "browser.bookmarks"

    private init() {
        if let d = UserDefaults.standard.data(forKey: BrowserBookmarks.key),
           let v = try? JSONDecoder().decode([BookmarkItem].self, from: d), !v.isEmpty {
            items = v
        } else {
            items = BrowserBookmarks.defaults
        }
    }
    private func save() { if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: BrowserBookmarks.key) } }

    /// JSON array the home page renders.
    var json: String {
        let arr = items.map { ["name": $0.name, "url": $0.url] }
        return (try? JSONSerialization.data(withJSONObject: arr)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    static let defaults: [BookmarkItem] = [
        .init(name: "Google", url: "https://www.google.com"),
        .init(name: "YouTube", url: "https://www.youtube.com"),
        .init(name: "Wikipedia", url: "https://www.wikipedia.org"),
        .init(name: "Reddit", url: "https://www.reddit.com"),
        .init(name: "GitHub", url: "https://github.com"),
        .init(name: "Maps", url: "https://www.google.com/maps"),
        .init(name: "News", url: "https://news.google.com"),
        .init(name: "Weather", url: "https://weather.com"),
        .init(name: "Hacker News", url: "https://news.ycombinator.com"),
        .init(name: "Amazon", url: "https://www.amazon.com"),
        .init(name: "Spotify", url: "https://open.spotify.com"),
        .init(name: "Twitch", url: "https://www.twitch.tv"),
    ]
}

// MARK: - Tabs + session (persist across app navigation)

final class BrowserTab: Identifiable {
    let id = UUID()
    let web: WKWebView
    var title: String = "New Tab"
    var urlText: String = ""
    init(web: WKWebView) { self.web = web }
}

final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = BrowserSession()

    @Published private(set) var tabs: [BrowserTab] = []
    @Published var activeID: UUID?
    @Published var address: String = ""        // address bar text for the active tab

    private let pool = WKProcessPool()
    private static let saveKey = "browser.tabs"

    var active: BrowserTab? { tabs.first { $0.id == activeID } }
    var homeURL: URL? { Bundle.main.url(forResource: "browser-home", withExtension: "html", subdirectory: "Web") }

    private override init() {
        super.init()
        let saved = UserDefaults.standard.stringArray(forKey: BrowserSession.saveKey) ?? []
        if saved.isEmpty { _ = newTab() }
        else { for s in saved { _ = newTab(urlString: s == "home" ? nil : s) }; activeID = tabs.first?.id }
    }

    private func makeConfig() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = pool
        let bridge = """
        window.__quakeTap = function(nx, ny){
          var x = nx*window.innerWidth, y = ny*window.innerHeight;
          var el = document.elementFromPoint(x, y); if(!el) return false;
          var a = el.closest && el.closest('a[href]');
          if(a && a.href){ window.location.href = a.href; return false; }
          ['mousedown','mouseup','click'].forEach(function(t){ try{ el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,clientX:x,clientY:y,view:window})); }catch(e){} });
          var f = (el.closest && el.closest('input,textarea,select,[contenteditable]'))
                  || (el.matches && el.matches('input,textarea,select') ? el : null)
                  || (el.querySelector && el.querySelector('input,textarea,[contenteditable]'));
          if(f && f.getAttribute && f.getAttribute('contenteditable')==='false') f=null;
          if(f && f.focus){ try{ f.focus(); return true; }catch(e){} }
          return false;
        };
        window.__quakeScroll = function(dx, dy){ window.scrollBy(dx, dy); };
        """
        cfg.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return cfg
    }

    private func attach(_ web: WKWebView) {
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        web.navigationDelegate = self
        web.uiDelegate = self
    }

    @discardableResult
    func newTab(urlString: String? = nil) -> BrowserTab {
        let web = WKWebView(frame: .zero, configuration: makeConfig())
        attach(web)
        let tab = BrowserTab(web: web)
        tabs.append(tab); activeID = tab.id
        if let s = urlString, let u = URL(string: s) { web.load(URLRequest(url: u)) } else { loadHome(tab) }
        persist()
        return tab
    }

    func loadHome(_ tab: BrowserTab? = nil) {
        let t = tab ?? active
        guard let t, let u = homeURL else { return }
        t.web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
        t.urlText = ""; if t.id == activeID { address = "" }
    }

    func select(_ id: UUID) { activeID = id; address = active?.urlText ?? ""; persist() }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].web.navigationDelegate = nil
        tabs.remove(at: i)
        if tabs.isEmpty { _ = newTab() }
        if activeID == id { activeID = tabs[min(i, tabs.count - 1)].id; address = active?.urlText ?? "" }
        persist()
    }

    func back() { active?.web.goBack() }
    func reload() { active?.web.reload() }
    func go(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        var s = t
        if t.contains(".") && !t.contains(" ") { if !t.lowercased().hasPrefix("http") { s = "https://" + t } }
        else { s = "https://www.google.com/search?q=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t) }
        if let u = URL(string: s) { active?.web.load(URLRequest(url: u)) }
    }
    func makeKey() { NSApp.activate(ignoringOtherApps: true); active?.web.window?.makeKeyAndOrderFront(nil) }

    private func persist() {
        UserDefaults.standard.set(tabs.map { $0.urlText.isEmpty ? "home" : $0.urlText }, forKey: BrowserSession.saveKey)
    }

    // MARK: delegates
    private func tab(for web: WKWebView) -> BrowserTab? { tabs.first { $0.web === web } }
    private func refresh(_ web: WKWebView) {
        guard let t = tab(for: web) else { return }
        if let u = web.url { t.urlText = u.isFileURL ? "" : u.absoluteString }
        t.title = web.title?.isEmpty == false ? web.title! : (web.url?.host ?? "New Tab")
        if t.id == activeID { address = t.urlText }
        objectWillChange.send(); persist()
    }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { refresh(w) }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        refresh(w)
        if w.url?.isFileURL == true {   // home page → inject the user's bookmarks
            w.evaluateJavaScript("window.__setBookmarks && window.__setBookmarks(\(BrowserBookmarks.shared.json));", completionHandler: nil)
        }
    }
    // Popups / target=_blank → open as a new tab.
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let web = WKWebView(frame: .zero, configuration: cfg)
        attach(web)
        let tab = BrowserTab(web: web); tabs.append(tab); activeID = tab.id; persist()
        return web
    }
}

// MARK: - Touch/keyboard input controller (geometry shared with the layout)

final class BrowserUI: ObservableObject {
    static let shared = BrowserUI()
    let sidebarFrac: CGFloat = 0.13
    let toolbarFrac: CGFloat = 0.16     // of the main (right) area's height = full panel height
    let rowH: CGFloat = 0.17            // sidebar row height (normalized)
    @Published var sidebarScroll: CGFloat = 0   // <= 0
    @Published var focusTick = 0
    private var start: CGPoint?, last: CGPoint?

    private var session: BrowserSession { .shared }

    func began(_ p: CGPoint) { start = p; last = p }
    func moved(_ p: CGPoint) {
        defer { last = p }
        guard let s = start, let l = last else { return }
        if s.x < sidebarFrac {                                   // scroll the tab sidebar
            let n = CGFloat(session.tabs.count + 1)
            let maxScroll = min(0, 1 - rowH * n)
            sidebarScroll = min(0, max(maxScroll, sidebarScroll + (p.y - l.y)))
        } else if s.y >= toolbarFrac, let web = session.active?.web {   // scroll the page
            let px = (l.y - p.y) / (1 - toolbarFrac) * web.bounds.height
            if abs(px) > 0.5 { web.evaluateJavaScript("window.__quakeScroll && window.__quakeScroll(0, \(px));", completionHandler: nil) }
        }
    }
    func ended() {
        defer { start = nil; last = nil }
        guard let s = start, let e = last else { return }
        guard max(abs(e.x - s.x), abs(e.y - s.y)) < 0.02 else { return }    // a drag, not a tap
        if s.x < sidebarFrac {
            let idx = Int((s.y - sidebarScroll) / rowH)                      // 0 = new tab, then tabs
            if idx <= 0 { _ = session.newTab(); return }
            let ti = idx - 1
            guard ti < session.tabs.count else { return }
            let tab = session.tabs[ti]
            if s.x > sidebarFrac * 0.72 { session.close(tab.id) } else { session.select(tab.id) }
            return
        }
        let lx = (s.x - sidebarFrac) / (1 - sidebarFrac)
        if s.y < toolbarFrac {
            if lx < 0.08 { session.back() }
            else if lx < 0.16 { session.loadHome() }
            else if lx > 0.92 { session.reload() }
            else { focusAddress() }
        } else if let web = session.active?.web {
            let ny = (s.y - toolbarFrac) / (1 - toolbarFrac)
            web.evaluateJavaScript("window.__quakeTap ? window.__quakeTap(\(lx), \(ny)) : false") { [weak self] r, _ in
                if (r as? Bool) == true { self?.session.makeKey() }
            }
        }
    }
    func focusAddress() { session.makeKey(); focusTick += 1 }
}

// MARK: - Views

struct BrowserAppView: View {
    @ObservedObject private var session = BrowserSession.shared
    @ObservedObject private var ui = BrowserUI.shared
    @FocusState private var addrFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            HStack(spacing: 0) {
                sidebar(w: w * ui.sidebarFrac, h: h)
                VStack(spacing: 0) {
                    toolbar(w: w * (1 - ui.sidebarFrac)).frame(height: h * ui.toolbarFrac)
                    BrowserHostView()
                }
            }
            .frame(width: w, height: h)
            .onAppear {
                ScreenTouchRouter.shared.install(owner: ui,
                    began: { ui.began($0) }, moved: { ui.moved($0) }, ended: { ui.ended() })
            }
            .onDisappear { ScreenTouchRouter.shared.release(owner: ui) }
        }
    }

    private func sidebar(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Color(white: 0.05)
            VStack(spacing: 0) {
                row(icon: "plus", title: "New Tab", active: false, h: h * ui.rowH, accent: true)
                ForEach(session.tabs) { t in
                    row(icon: "globe", title: t.title, active: t.id == session.activeID, h: h * ui.rowH, accent: false)
                }
            }
            .offset(y: ui.sidebarScroll * h)
        }
        .frame(width: w, height: h).clipped()
    }

    private func row(icon: String, title: String, active: Bool, h: CGFloat, accent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: h * 0.34, weight: .medium))
                .foregroundColor(accent ? .cyan : .white.opacity(0.85))
            Text(title).font(.system(size: h * 0.3, weight: .medium)).foregroundColor(.white.opacity(0.9)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, h * 0.3)
        .frame(height: h)
        .background(active ? Color.white.opacity(0.12) : Color.clear)
    }

    private func toolbar(w: CGFloat) -> some View {
        HStack(spacing: w * 0.015) {
            Button(action: session.back) { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Button(action: { session.loadHome() }) { Image(systemName: "house.fill") }.buttonStyle(.plain)
            TextField("Search or enter address", text: $session.address)
                .textFieldStyle(.plain).font(.system(size: 22)).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                .focused($addrFocused)
                .onSubmit { session.go(session.address); addrFocused = false }
                .onChange(of: ui.focusTick) { _ in addrFocused = true }
            Button(action: session.reload) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
        }
        .font(.system(size: 30, weight: .semibold)).foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, w * 0.02)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }
}

// Hosts the active tab's (persistent) WKWebView, swapping it in when the active tab changes.
struct BrowserHostView: NSViewRepresentable {
    @ObservedObject var session = BrowserSession.shared
    func makeNSView(context: Context) -> NSView { let v = NSView(); v.wantsLayer = true; return v }
    func updateNSView(_ v: NSView, context: Context) {
        let web = session.active?.web
        if web?.superview !== v {
            v.subviews.forEach { $0.removeFromSuperview() }
            if let web { web.frame = v.bounds; web.autoresizingMask = [.width, .height]; v.addSubview(web) }
        }
    }
}

// MARK: - Mac settings panel (Prebuilt Panels → Browser)

struct BrowserPanelView: View {
    let pageName: String
    @ObservedObject private var bm = BrowserBookmarks.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeader(title: pageName,
                           subtitle: "The embedded web browser on the Quake. Edit the bookmark tiles shown on its home page.")
            NeonCard("Home page bookmarks") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(bm.items.indices, id: \.self) { i in bookmarkRow(i) }
                    Button { bm.items.append(BookmarkItem(name: "New", url: "https://")) } label: {
                        Label("Add bookmark", systemImage: "plus.circle.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(NeonTheme.cyan)
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                }
                .padding(.vertical, 8)
            }
            Spacer()
        }
    }

    @ViewBuilder private func bookmarkRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            TextField("Name", text: $bm.items[i].name)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 150)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
            TextField("https://…", text: $bm.items[i].url)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
            Button { bm.items.remove(at: i) } label: {
                Image(systemName: "trash").font(.system(size: 13)).foregroundColor(NeonTheme.magenta)
            }
            .buttonStyle(.plain).disabled(bm.items.count <= 1)
        }
    }
}
