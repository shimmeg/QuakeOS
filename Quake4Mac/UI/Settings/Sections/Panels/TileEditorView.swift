// TileEditorView.swift — Quake4Mac settings app
//
// Per-page editor. The page's live layout is the hero strip at the top (the drop target); this
// view below is the TILE LIBRARY: category chips (All / Apps / System / Web / Discord / …) over a
// grid of draggable tiles. Drag a tile up onto a strip cell to place it — the page updates live
// and persists via PadStore.
//
// Selecting a tile (from the strip or the library) opens TileInspectorRail, which SettingsRootView
// docks as a full-height column to the RIGHT of the live preview.

import SwiftUI
import AppKit

struct TileEditorView: View {
    let pageName: String
    @State private var category = "All"
    @ObservedObject private var session = TileEditSession.shared

    private let grid = [GridItem(.adaptive(minimum: 96, maximum: 128), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                SettingsHeader(title: pageName,
                               subtitle: "Drag a tile from the library onto the strip above. Changes hit the Quake only when you Save.")
                Spacer(minLength: 16)
                saveBar
            }
            libraryColumn
        }
        .onChange(of: pageName) { _ in session.select(nil); session.inspect(nil) }
    }

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Category filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All")
                    ForEach(TileCatalog.categories, id: \.self) { chip($0) }
                }
                .padding(.horizontal, 2).padding(.bottom, 2)
            }

            // Library grid (draggable)
            NeonCard(category == "All" ? "All tiles" : category) {
                LazyVGrid(columns: grid, spacing: 12) {
                    ForEach(TileCatalog.tiles(category: category)) { spec in
                        if spec.actKind == "none" {
                            libraryCell(spec)            // greyed + not draggable until it has an action
                        } else {
                            libraryCell(spec).draggable(spec.dragString)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var saveBar: some View {
        HStack(spacing: 10) {
            if session.dirty {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(NeonTheme.magenta)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(NeonTheme.magenta.opacity(0.14)))
            }
            barButton("Revert", NeonTheme.textSecondary, enabled: session.dirty) { session.revert() }
            barButton("Save to Quake", NeonTheme.cyan, enabled: session.dirty) { session.save() }
        }
    }

    private func barButton(_ title: String, _ tint: Color, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(enabled ? tint : NeonTheme.textTertiary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(enabled ? 0.14 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(enabled ? 0.4 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    private func chip(_ name: String) -> some View {
        let on = category == name
        return Button { category = name } label: {
            Text(name)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundColor(on ? .white : NeonTheme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? NeonTheme.cyan.opacity(0.16) : Color.white.opacity(0.04)))
                .overlay(Capsule().strokeBorder(on ? NeonTheme.cyan.opacity(0.4) : NeonTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func libraryCell(_ spec: TileSpec) -> some View {
        let wired = spec.actKind != "none"
        let selected = session.selectedSpec?.id == spec.id
        return VStack(spacing: 6) {
            TileGlyphView(symbol: spec.symbol, image: spec.image, tint: Color(hexRGB: spec.tintHex),
                          appBundleID: spec.appBundleID, url: spec.openURLValue, size: 60)
            Text(spec.title)
                .font(.system(size: 10, weight: .medium)).foregroundColor(NeonTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: 92)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? NeonTheme.cyan : NeonTheme.stroke, lineWidth: selected ? 2 : 1))
        .opacity(wired ? 1 : 0.4)                                  // grey out tiles with no action yet
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { session.inspect(spec) }
        .help(wired ? "Click for details · drag onto the strip above" : "No action assigned yet")
    }
}

// MARK: - Inspector rail (docked right of the preview by SettingsRootView)

struct TileInspectorRail: View {
    let pageName: String
    @ObservedObject private var session = TileEditSession.shared

    // Edit buffers for an editable strip tile.
    @State private var eTitle = ""
    @State private var eKind = "none"
    @State private var eValue = ""
    @State private var eDelta = 26

    private var stripSelected: Bool {
        session.selectedSlot != nil && session.index(ofPage: pageName) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if session.selectedSpec != nil {
                    libraryInfoCard
                } else if stripSelected {
                    stripInspectorCard
                } else {
                    placeholder
                }
            }
            .padding(18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: session.selectedSlot) { _ in loadInspector() }
        .onAppear { loadInspector() }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.system(size: 26, weight: .light)).foregroundColor(NeonTheme.textTertiary)
            Text("Click a tile to view its settings")
                .font(.system(size: 12)).foregroundColor(NeonTheme.textTertiary)
                .multilineTextAlignment(.center)
            Text("Select a tile on the strip or in the library to see what it does and edit it.")
                .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary.opacity(0.7))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Library tile — read-only "what does this do"

    private func displayAppName(_ bid: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bid.split(separator: ".").last.map { String($0).capitalized } ?? bid
    }

    /// (headline, detail) describing an action in plain language.
    private func actionSummary(kind: String, str: String?, int: Int?) -> (String, String?) {
        switch kind {
        case "app":
            let name = displayAppName(str ?? "")
            return ("Opens the \(name) app", str)
        case "url":
            let host = URL(string: str ?? "")?.host ?? (str ?? "—")
            return ("Opens \(host)", str)
        case "shell":   return ("Runs an advanced shell macro", str)
        case "ascript": return ("Runs an advanced AppleScript macro", str)
        case "lum":     return ("Adjusts brightness by \((int ?? 0) >= 0 ? "+" : "")\(int ?? 0)", nil)
        case "sys":     return ("Runs a built-in system action", str)
        case "page":    return ("Switches to the \(str ?? "—") page", nil)
        default:        return ("No action assigned yet", nil)
        }
    }

    @ViewBuilder private var libraryInfoCard: some View {
        if let spec = session.selectedSpec {
            let info = actionSummary(kind: spec.actKind, str: spec.actStr, int: spec.actInt)
            NeonCard("Tile Info") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        TileGlyphView(symbol: spec.symbol, image: spec.image, tint: Color(hexRGB: spec.tintHex),
                                      appBundleID: spec.appBundleID, url: spec.openURLValue, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.title).font(.system(size: 15, weight: .semibold)).foregroundColor(NeonTheme.textPrimary)
                            Text(spec.category).font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.0).font(.system(size: 13, weight: .medium)).foregroundColor(NeonTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = info.1 {
                            Text(detail).font(.system(size: 11).monospacedDigit()).foregroundColor(NeonTheme.textTertiary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(spec.actKind == "none" ? "This tile has no action yet, so it can't be placed."
                                                 : "Drag this tile onto the strip above to place it.")
                        .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack { Spacer(); pill("Done", NeonTheme.cyan) { session.inspect(nil) } }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Placed strip tile — editable, or locked preset

    private var selectedEditable: Bool {
        guard let p = session.index(ofPage: pageName), let sel = session.selectedSlot,
              let t = session.tile(page: p, slot: sel) else { return false }
        return t.editable
    }

    private var currentAction: PadAction {
        switch eKind {
        case "app":     return .launchApp(bundleID: eValue)
        case "url":     return .openURL(eValue)
        case "shell":   return .shell(eValue)
        case "ascript": return .appleScript(eValue)
        case "lum":     return .luminance(delta: eDelta)
        case "sys":     return SystemAction(rawValue: eValue).map(PadAction.system) ?? .none
        case "page":    return .openPage(eValue)
        default:        return .none
        }
    }

    private func loadInspector() {
        guard let p = session.index(ofPage: pageName), let sel = session.selectedSlot,
              let t = session.tile(page: p, slot: sel) else { return }
        eTitle = t.title; eValue = ""; eDelta = 26
        switch t.action {
        case .launchApp(let b):   eKind = "app";     eValue = b
        case .openURL(let u):     eKind = "url";     eValue = u
        case .shell(let c):       eKind = "shell";   eValue = c
        case .appleScript(let s): eKind = "ascript"; eValue = s
        case .luminance(let d):   eKind = "lum";     eDelta = d
        case .system(let a):      eKind = "sys";     eValue = a.rawValue
        case .openPage(let n):    eKind = "page";    eValue = n
        case .none:               eKind = "none"
        }
    }

    private func applyInspector() {
        guard let p = session.index(ofPage: pageName), let sel = session.selectedSlot else { return }
        session.setTitleAction(page: p, slot: sel, title: eTitle, action: currentAction)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let bid = Bundle(url: url)?.bundleIdentifier {
            eKind = "app"; eValue = bid
            if eTitle.isEmpty { eTitle = url.deletingPathExtension().lastPathComponent }
            applyInspector()
        }
    }

    @ViewBuilder private var stripInspectorCard: some View {
        NeonCard("Edit Tile") {
            VStack(alignment: .leading, spacing: 12) {
                if selectedEditable {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Title").font(.system(size: 12)).foregroundColor(NeonTheme.textSecondary)
                        field($eTitle, placeholder: "Tile name")
                        Text("Action").font(.system(size: 12)).foregroundColor(NeonTheme.textSecondary)
                        Picker("", selection: $eKind) {
                            Text("None").tag("none"); Text("Open App").tag("app"); Text("Open URL").tag("url")
                            Text("Shell").tag("shell"); Text("AppleScript").tag("ascript"); Text("Brightness").tag("lum")
                            Text("Go to Page").tag("page")
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        .onChange(of: eKind) { _ in applyInspector() }
                        actionValueRow
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(eTitle).font(.system(size: 14, weight: .semibold)).foregroundColor(NeonTheme.textPrimary)
                        Text("Built-in preset tile — its action is locked. You can remove it, but not reassign what it does.")
                            .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Spacer()
                    pill("Remove", NeonTheme.magenta) {
                        if let p = session.index(ofPage: pageName), let sel = session.selectedSlot { session.remove(page: p, slot: sel) }
                    }
                    pill("Done", NeonTheme.cyan) { session.select(nil) }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var actionValueRow: some View {
        switch eKind {
        case "app":
            VStack(alignment: .leading, spacing: 8) {
                Text("Bundle ID").font(.system(size: 12)).foregroundColor(NeonTheme.textSecondary)
                field($eValue, placeholder: "com.apple.Safari").onChange(of: eValue) { _ in applyInspector() }
                HStack { Spacer(); pill("Choose App…", NeonTheme.purple) { chooseApp() } }
            }
        case "url":
            labeledField("URL", placeholder: "https://example.com")
        case "shell":
            VStack(alignment: .leading, spacing: 6) {
                labeledField("Command", placeholder: "open ~/Downloads")
                executableWarning
            }
        case "ascript":
            VStack(alignment: .leading, spacing: 6) {
                labeledField("Script", placeholder: "tell application ...")
                executableWarning
            }
        case "lum":
            HStack {
                Text("Delta").font(.system(size: 12)).foregroundColor(NeonTheme.textSecondary).frame(width: 70, alignment: .leading)
                Stepper("\(eDelta)", value: $eDelta, in: -255...255, step: 13).labelsHidden()
                Text("\(eDelta)").font(.system(size: 12).monospacedDigit()).foregroundColor(NeonTheme.textSecondary)
                    .onChange(of: eDelta) { _ in applyInspector() }
            }
        case "page":
            VStack(alignment: .leading, spacing: 6) {
                Text("Page").font(.system(size: 12)).foregroundColor(NeonTheme.textSecondary)
                Picker("", selection: $eValue) {
                    ForEach(PadStore.shared.pages.map { $0.name }, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                .onChange(of: eValue) { _ in applyInspector() }
            }
        default:
            Text("This tile does nothing until you pick an action.")
                .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
        }
    }

    private func labeledField(_ label: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundColor(NeonTheme.textSecondary)
            field($eValue, placeholder: placeholder).onChange(of: eValue) { _ in applyInspector() }
        }
    }

    private var executableWarning: some View {
        Text(MacroActionExecutor.executableWarning(for: eKind) ?? "")
            .font(.system(size: 11)).foregroundColor(Color(red: 1, green: 0.65, blue: 0.25))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(NeonTheme.stroke, lineWidth: 1))
            .onChange(of: text.wrappedValue) { _ in applyInspector() }
    }

    private func pill(_ title: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(tint)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
