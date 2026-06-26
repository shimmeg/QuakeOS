// CalendarScreen.swift -- Quake4Mac
//
// Built-in Calendar panel. Events come from macOS calendars through EventKit so the
// Quake screen can render today's schedule without depending on Fantastical's private UI.

import SwiftUI
import WebKit
import Combine

// MARK: - Persistent panel webview

final class CalendarWeb: PanelWeb, WKScriptMessageHandler {
    static let shared = CalendarWeb()

    private let store = CalendarPanelStore.shared
    private var bag = Set<AnyCancellable>()
    private var lastJSON = ""
    private var visible = false
    private var startPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var dragged = false

    init() {
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        super.init(html: "calendar", configuration: config)
        web.configuration.userContentController.add(self, name: "calendar")
        store.$snapshot
            .sink { [weak self] _ in self?.push() }
            .store(in: &bag)
    }

    override func onReady() {
        lastJSON = ""
        push(force: true)
    }

    override func onShow() {
        visible = true
        store.start()
        push(force: true)
    }

    override func onHide() {
        visible = false
        store.stop()
    }

    func warm() {
        push(force: true)
    }

    private func push(force: Bool = false) {
        guard loaded, visible || force else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: store.snapshot.jsonObject, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        if !force && json == lastJSON { return }
        lastJSON = json
        guard let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        eval("window.CAL && window.CAL.set(decodeURIComponent('\(encoded)'));")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "calendar", let action = message.body as? String else { return }
        switch action {
        case "openFantastical":
            _ = FantasticalLauncher.open()
        case "openCalendarPrivacy":
            store.openPrivacySettings()
        case "requestAccess":
            store.requestAccess()
        default:
            break
        }
    }

    override func touchBegan(_ p: CGPoint) {
        startPoint = p
        lastPoint = p
        dragged = false
    }

    override func touchMoved(_ p: CGPoint) {
        let dx = abs((p.x - startPoint.x) * web.bounds.width)
        let dy = abs((p.y - startPoint.y) * web.bounds.height)
        if dx > 20 || dy > 20 { dragged = true }
        if dragged {
            let scrollY = Double(lastPoint.y - p.y) * Double(web.bounds.height)
            eval("window.CAL && window.CAL.scroll(\(scrollY));")
        }
        lastPoint = p
    }

    override func touchEnded() {
        guard loaded, !dragged else { return }
        let x = startPoint.x * web.bounds.width
        let y = startPoint.y * web.bounds.height
        let js = """
        (function(){var e=document.elementFromPoint(\(x),\(y));if(!e)return;
        while(e&&!e.onclick&&e!==document.body)e=e.parentElement;if(e&&e.click)e.click();})();
        """
        eval(js)
    }
}

struct CalendarDeviceView: View {
    var body: some View { PanelWebHost(panel: CalendarWeb.shared).ignoresSafeArea() }
}

// MARK: - Settings (Prebuilt Panels -> Calendar)

struct CalendarPanelView: View {
    @ObservedObject private var store = CalendarPanelStore.shared
    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeader(title: CalendarAppLabels.settingsTitle, subtitle: "Today's schedule on the Quake, sourced from macOS calendars.")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                NeonCard("Calendar Access") {
                    NeonInfoRow(label: "Source", value: "macOS calendars")
                    NeonDivider()
                    NeonInfoRow(label: "Status", value: statusText)
                    NeonDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Permission").font(.system(size: 11, weight: .semibold)).foregroundColor(NeonTheme.textTertiary)
                        Text(permissionDetail)
                            .font(.system(size: 11))
                            .foregroundColor(NeonTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)

                    HStack(spacing: 10) {
                        Button(action: performPrimaryAction) {
                            Text(CalendarStoreLogic.requestButtonTitle(for: store.snapshot.status))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(NeonTheme.cyan)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NeonTheme.cyan.opacity(0.12)))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(NeonTheme.cyan.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.snapshot.status == .requesting)
                    }
                    .padding(.bottom, 8)
                }

                NeonCard("External App") {
                    NeonInfoRow(label: "App", value: store.snapshot.canOpenFantastical ? "Installed" : "Not found")
                    NeonDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The Quake panel renders events itself, but the on-screen button opens \(CalendarAppLabels.externalAppTitle) for full calendar editing.")
                            .font(.system(size: 11))
                            .foregroundColor(NeonTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { _ = FantasticalLauncher.open() } label: {
                            Text(CalendarAppLabels.externalOpenTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(store.snapshot.canOpenFantastical ? NeonTheme.cyan : NeonTheme.textTertiary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NeonTheme.cyan.opacity(store.snapshot.canOpenFantastical ? 0.12 : 0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(NeonTheme.cyan.opacity(store.snapshot.canOpenFantastical ? 0.35 : 0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.snapshot.canOpenFantastical)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .onAppear { store.refresh() }
    }

    private var statusText: String {
        switch store.snapshot.status {
        case .notDetermined: return "Not requested"
        case .requesting: return "Requesting"
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .error: return "Error"
        }
    }

    private var permissionDetail: String {
        switch store.snapshot.status {
        case .notDetermined, .requesting:
            return "Request Calendar permission from this Mac-side settings view so the system prompt stays on the normal app path."
        case .denied, .restricted:
            return "Calendar access is currently off. Open macOS Privacy Settings to re-enable it for Quake4Mac."
        case .authorized:
            return "Quake4Mac reads today's events through EventKit and refreshes while the panel is visible."
        case .error:
            return "Quake4Mac could not read Calendar status. Refresh the snapshot or check Privacy Settings."
        }
    }

    private func performPrimaryAction() {
        switch CalendarStoreLogic.settingsAction(for: store.snapshot.status) {
        case .requestAccess:
            store.requestAccess()
        case .openPrivacySettings:
            store.openPrivacySettings()
        case .refreshEvents:
            store.refresh()
        }
    }
}
