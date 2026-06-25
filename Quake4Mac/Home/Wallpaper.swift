// Wallpaper.swift — Quake4Mac
//
// The Quake panel's wallpaper (NOT the Mac's). Wallpapers are bundled under Wallpapers/.
// WallpaperStore holds a global default + optional per-home-page overrides (persisted). WallpaperView
// renders the chosen media behind the home screen; WallpaperAppView is the on-device picker.

import SwiftUI
import AppKit
import AVFoundation

enum WallpaperMedia: Equatable {
    case none
    case video(file: String)
    case image(file: String, ext: String)
}

struct WallpaperOption: Identifiable, Equatable {
    let id: String
    let title: String
    let media: WallpaperMedia
}

final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()

    @Published var defaultID: String { didSet { UserDefaults.standard.set(defaultID, forKey: "wallpaper.default") } }
    @Published var perPage: [Int: String] { didSet { savePerPage() } }

    static let options: [WallpaperOption] = [
        WallpaperOption(id: "none",         title: "None",          media: .none),
        WallpaperOption(id: "NeonHorizon",  title: "Neon Horizon",  media: .image(file: "NeonHorizon", ext: "png")),
        WallpaperOption(id: "SignalGrid",   title: "Signal Grid",   media: .image(file: "SignalGrid", ext: "png")),
        WallpaperOption(id: "PomeranianSpitz", title: "My Spitz",    media: .image(file: "MyPomeranianSpitz", ext: "png")),
        WallpaperOption(id: "Aurora",       title: "Aurora",        media: .video(file: "Aurora")),
        WallpaperOption(id: "Matrix",       title: "Matrix",        media: .video(file: "Matrix")),
        WallpaperOption(id: "car",          title: "Car",           media: .video(file: "car")),
        WallpaperOption(id: "cityofnight",  title: "City of Night", media: .video(file: "cityofnight")),
        WallpaperOption(id: "mountain",     title: "Mountain",      media: .video(file: "mountain")),
    ]

    private init() {
        defaultID = UserDefaults.standard.string(forKey: "wallpaper.default") ?? "Aurora"
        if let data = UserDefaults.standard.data(forKey: "wallpaper.perPage"),
           let m = try? JSONDecoder().decode([Int: String].self, from: data) { perPage = m } else { perPage = [:] }
    }
    private func savePerPage() {
        if let data = try? JSONEncoder().encode(perPage) { UserDefaults.standard.set(data, forKey: "wallpaper.perPage") }
    }

    func id(forPage p: Int) -> String { perPage[p] ?? defaultID }
    func replacePerPage(_ m: [Int: String]) { perPage = m }   // commit the layout editor's per-page wallpaper draft
    func option(_ id: String) -> WallpaperOption { WallpaperStore.options.first { $0.id == id } ?? WallpaperStore.options[0] }
    func setDefault(_ id: String) { defaultID = id }
    func setPage(_ p: Int, _ id: String?) { if let id { perPage[p] = id } else { perPage.removeValue(forKey: p) } }
    func removePageIndex(_ i: Int) { perPage = Dictionary(uniqueKeysWithValues: perPage.compactMap { (k, v) in k == i ? nil : (k > i ? (k - 1, v) : (k, v)) }) }   // drop key i, shift keys > i down by one
}

// MARK: - Looping video renderer

struct WallpaperView: View {
    let id: String
    var body: some View {
        let opt = WallpaperStore.shared.option(id)
        switch opt.media {
        case .none:
            Color.black.ignoresSafeArea()
        case .video(let file):
            if let url = Bundle.main.url(forResource: file, withExtension: "mp4", subdirectory: "Wallpapers") {
                LoopingVideoView(url: url).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        case .image(let file, let ext):
            if let url = Bundle.main.url(forResource: file, withExtension: ext, subdirectory: "Wallpapers") {
                StaticImageWallpaperView(url: url).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }
}

struct StaticImageWallpaperView: View {
    private let image: NSImage?

    init(url: URL) {
        image = NSImage(contentsOf: url)
    }

    var body: some View {
        GeometryReader { geo in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Color.black
            }
        }
    }
}

struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> LoopingPlayerView { LoopingPlayerView(url: url) }
    func updateNSView(_ nsView: LoopingPlayerView, context: Context) { nsView.update(url: url) }
    static func dismantleNSView(_ nsView: LoopingPlayerView, coordinator: ()) { nsView.stop() }
}

final class LoopingPlayerView: NSView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var currentURL: URL?

    init(url: URL) { super.init(frame: .zero); wantsLayer = true; layer = CALayer(); load(url) }
    required init?(coder: NSCoder) { fatalError() }

    private func load(_ url: URL) {
        currentURL = url
        let item = AVPlayerItem(url: url)
        let q = AVQueuePlayer()
        q.isMuted = true
        looper = AVPlayerLooper(player: q, templateItem: item)
        let pl = AVPlayerLayer(player: q)
        pl.videoGravity = .resizeAspectFill
        pl.frame = bounds
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.addSublayer(pl)
        player = q; playerLayer = pl
        q.play()
    }
    func update(url: URL) { if url != currentURL { load(url) } }
    func stop() { player?.pause(); player = nil; looper = nil }

    override func layout() { super.layout(); playerLayer?.frame = bounds }
}

// MARK: - On-device Wallpaper app (picker)

struct WallpaperAppView: View {
    @ObservedObject private var store = WallpaperStore.shared
    @State private var touchStart: CGPoint?
    @State private var touchLast: CGPoint?

    private let chipBandTop: CGFloat = 0.74   // bottom strip where option chips live (normalized y)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                WallpaperView(id: store.defaultID)
                Color.black.opacity(0.25).ignoresSafeArea()

                VStack {
                    Text("Wallpaper")
                        .font(.system(size: geo.size.height * 0.06, weight: .semibold))
                        .foregroundColor(.white).shadow(radius: 6)
                        .padding(.top, geo.size.height * 0.06)
                    Spacer()
                    chips(geo: geo)
                        .padding(.bottom, geo.size.height * 0.06)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { installRouter() }
            .onDisappear { ScreenTouchRouter.shared.release(owner: self.routerOwner) }
        }
    }

    private func chips(geo: GeometryProxy) -> some View {
        let n = WallpaperStore.options.count
        let cellW = geo.size.width / CGFloat(n)
        return HStack(spacing: 0) {
            ForEach(WallpaperStore.options) { opt in
                let on = opt.id == store.defaultID
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(on ? 0.18 : 0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(on ? Color.cyan : Color.white.opacity(0.2), lineWidth: on ? 3 : 1))
                        .frame(height: geo.size.height * 0.16)
                        .overlay(Image(systemName: iconName(for: opt.media))
                            .font(.system(size: geo.size.height * 0.05)).foregroundColor(.white.opacity(0.85)))
                    Text(opt.title).font(.system(size: geo.size.height * 0.035, weight: .medium))
                        .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                }
                .frame(width: cellW)
            }
        }
        .padding(.horizontal, geo.size.width * 0.02)
    }

    private func iconName(for media: WallpaperMedia) -> String {
        switch media {
        case .none: return "circle.slash"
        case .video: return "play.rectangle.fill"
        case .image: return "photo.fill"
        }
    }

    // Device HID touches arrive via the router; treat a tap in the chip band as a selection.
    private var routerOwner: AnyObject { store }
    private func installRouter() {
        ScreenTouchRouter.shared.install(owner: routerOwner,
            began: { p in touchStart = p; touchLast = p },
            moved: { p in touchLast = p },
            ended: {
                defer { touchStart = nil; touchLast = nil }
                guard let s = touchStart, let e = touchLast else { return }
                if abs(e.x - s.x) > 0.12 { return }                       // a swipe, not a tap
                guard s.y >= chipBandTop else { return }                  // only the chip strip selects
                let n = WallpaperStore.options.count
                let idx = min(max(Int(s.x * CGFloat(n)), 0), n - 1)
                store.setDefault(WallpaperStore.options[idx].id)
            })
    }
}
