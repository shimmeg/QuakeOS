// SettingsRootView.swift — Quake4Mac settings app
//
// The redesigned Settings shell: left sidebar + main area (hero live Quake-strip preview on top,
// the selected route's controls below). "Pages" and "Prebuilt Panels" expand in the sidebar; their
// children route here to the per-page Tile Editor and the per-panel settings.

import SwiftUI

struct SettingsRootView: View {
    @State private var selection: SettingsRoute = .section(.general)
    @State private var sidebarOpen = false      // used only in the narrow (collapsed) layout
    @ObservedObject private var glowSetting = GlowSetting.shared   // live glow-intensity refresh
    @ObservedObject private var editSession = TileEditSession.shared   // drives the inspector rail
    @AppStorage("settings.font") private var fontPref = "SF"       // SF (default) | Geo (rounded)
    @AppStorage("settings.previewMode") private var previewMode = "Hero"   // Hero/Bar = top, Dock = bottom

    @State private var rightOpen = false        // manual overlay open for the right rail when collapsed

    // Layout metrics for the collapse hierarchy. contentMin reflects the fixed-width hero preview
    // (≈800 strip + 188 knob + gaps), which does not shrink — so panels must drop, not squeeze.
    private let leftW: CGFloat = 234
    private let rightW: CGFloat = 320
    private let contentMin: CGFloat = 1040

    /// The page being edited, if the right inspector rail applies to this route.
    private var railPageName: String? {
        if case .page(let name) = selection { return name }
        return nil
    }

    private struct PanelLayout { var autoLeft: Bool; var autoRight: Bool }

    /// Which side panels fit inline. Collapse priority depends on selection:
    /// a selected tile keeps the right rail (drop left first); otherwise keep the left nav.
    private func panelLayout(width w: CGFloat, railWanted: Bool, tileSelected: Bool) -> PanelLayout {
        guard railWanted else { return PanelLayout(autoLeft: w >= leftW + contentMin, autoRight: false) }
        if w >= leftW + rightW + contentMin { return PanelLayout(autoLeft: true, autoRight: true) }
        if tileSelected {                                  // priority: collapse LEFT first
            return PanelLayout(autoLeft: false, autoRight: w >= rightW + contentMin)
        } else {                                           // priority: collapse RIGHT first
            return PanelLayout(autoLeft: w >= leftW + contentMin, autoRight: false)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let railWanted = railPageName != nil
            let tileSelected = editSession.hasSelection
            let layout = panelLayout(width: w, railWanted: railWanted, tileSelected: tileSelected)
            let autoLeft = layout.autoLeft
            let autoRight = layout.autoRight

            // Overlays for panels that don't fit inline — both reopen only via their toggle, so
            // either side can fully collapse regardless of whether a tile is selected.
            let leftOverlay  = !autoLeft && sidebarOpen
            let rightOverlay = railWanted && !autoRight && rightOpen

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if autoLeft {
                        SettingsSidebar(selection: $selection)
                        Rectangle().fill(NeonTheme.stroke).frame(width: 1)
                    }
                    mainColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if railWanted && autoRight {
                        Rectangle().fill(NeonTheme.stroke).frame(width: 1)
                        TileInspectorRail(pageName: railPageName!)
                            .frame(width: rightW)
                            .background(NeonTheme.panel.opacity(0.35))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                // Right rail as a floating overlay when there's no room inline but a tile is selected.
                if rightOverlay {
                    HStack(spacing: 0) {
                        Spacer()
                        Rectangle().fill(NeonTheme.stroke).frame(width: 1)
                        TileInspectorRail(pageName: railPageName!)
                            .frame(width: rightW)
                            .background(NeonTheme.panel)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.4), radius: 18, x: -6, y: 0)
                    .transition(.move(edge: .trailing))
                }

                // Left nav as a floating overlay when collapsed and toggled open.
                if leftOverlay {
                    HStack(spacing: 0) {
                        SettingsSidebar(selection: $selection)
                            .background(NeonTheme.panel)
                        Rectangle().fill(NeonTheme.stroke).frame(width: 1)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.4), radius: 18, x: 6, y: 0)
                    .transition(.move(edge: .leading))
                }

                // Hamburger to reopen the left nav when it's collapsed.
                if !autoLeft {
                    Button { withAnimation(.easeInOut(duration: 0.18)) { sidebarOpen.toggle() } } label: {
                        Image(systemName: sidebarOpen ? "sidebar.leading" : "line.3.horizontal")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(NeonTheme.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(NeonTheme.panel))
                            .overlay(Circle().strokeBorder(NeonTheme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, leftOverlay ? leftW + 10 : 12).padding(.top, 12)
                }

                // Toggle to reopen the right inspector rail when it's collapsed.
                if railWanted && !autoRight {
                    HStack {
                        Spacer()
                        Button { withAnimation(.easeInOut(duration: 0.18)) { rightOpen.toggle() } } label: {
                            Image(systemName: rightOverlay ? "sidebar.trailing" : "slider.horizontal.3")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(NeonTheme.textSecondary)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(NeonTheme.panel))
                                .overlay(Circle().strokeBorder(NeonTheme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, rightOverlay ? rightW + 10 : 12)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: autoLeft)
            .animation(.easeInOut(duration: 0.18), value: autoRight)
            .animation(.easeInOut(duration: 0.18), value: rightOverlay)
            .onChange(of: selection) { _ in withAnimation { sidebarOpen = false; rightOpen = false } }
        }
        .frame(minWidth: 1080, minHeight: 640)
        .background(NeonTheme.bg)
        .fontDesign(fontPref == "Geo" ? .rounded : .default)   // Font setting, live
        .preferredColorScheme(.dark)
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            if previewMode != "Dock" {
                QuakeStripPreview(pageName: previewPageName, editingPageIndex: editingPageIndex)
            }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 28)
            }
            if previewMode == "Dock" {       // docked at the bottom
                QuakeStripPreview(pageName: previewPageName, editingPageIndex: editingPageIndex)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NeonTheme.bg)
    }

    /// When a macro page is selected, the strip becomes an editable drop target for that page.
    private var editingPageIndex: Int? {
        if case .page(let name) = selection {
            return PadStore.shared.pages.firstIndex { $0.name == name }
        }
        return nil
    }

    /// The preview's page label.
    private var previewPageName: String {
        switch selection {
        case .page(let name):      return name
        case .prebuilt(let p):     return p.title
        case .section(let s):
            switch s {
            case .general, .rgbRing, .reactive: return "Studio"
            default:                            return s.title
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .page(let name):       TileEditorView(pageName: name)
        case .prebuilt(.music):     MusicPanelView()
        case .prebuilt(.monitor):   SystemMonitorPanelView()
        case .prebuilt(.clock):     ClockPageView(pageName: "Clock")
        case .prebuilt(.browser):   BrowserPanelView(pageName: "Browser")
        case .section(let s):
            switch s {
            case .general:  GeneralSettingsView()
            case .rgbRing:  RGBRingView()
            case .reactive: ReactiveLightingView()
            default:        PlaceholderSectionView(section: s)
            }
        }
    }
}
