// GeneralSettingsView.swift — Quake4Mac settings app
//
// Device & app basics: appearance (glow / font / live-preview style — moved here off the old
// top toolbar), language, and an About block. Values persist via @AppStorage; wiring the glow
// level and font into the live look across the app comes in a later phase.

import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @AppStorage("settings.glow")        private var glow = NeonTheme.Glow.high.rawValue
    @AppStorage("settings.font")        private var font = "SF"
    @AppStorage("settings.previewMode") private var previewMode = "Hero"
    @AppStorage("settings.language")    private var language = "System"

    // Startup / menu-bar behaviour (read + applied by AppDelegate; toggled here).
    @AppStorage("settings.openAtLogin")     private var openAtLogin = false
    @AppStorage("settings.menuBarOnly")     private var menuBarOnly = false   // hide Dock icon
    @AppStorage("settings.openAtLaunch")    private var openAtLaunch = true
    @AppStorage("settings.runInBackground") private var runInBackground = true
    @AppStorage("settings.allowExecutableMacros") private var allowExecutableMacros = false
    @AppStorage("settings.developerMode") private var developerMode = false
    @AppStorage("settings.enablePrivateThermals") private var enablePrivateThermals = false

    // Which screen the Quake panel opens to at launch (read by PadModel.applyStartup).
    @AppStorage("startup.target") private var startupTarget = "home"
    private var launchOptions: [(String, String)] {   // (value, label)
        [("home", "Home screen"), ("last", "Last opened")]
        + HomeStore.shared.allApps.map { ($0.dest.storageKey, $0.title) }
    }

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 470), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeader(title: "General", subtitle: SettingsSection.general.subtitle)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                NeonCard("Appearance") {
                    NeonPickerRow(label: "Glow intensity", selection: $glow,
                                  options: NeonTheme.Glow.allCases.map { ($0.rawValue, $0.label) })
                        .onChange(of: glow) { _ in GlowSetting.shared.refresh() }
                    NeonDivider()
                    NeonPickerRow(label: "Font", selection: $font,
                                  options: [("SF", "SF"), ("Geo", "Geo")])
                    NeonDivider()
                    NeonPickerRow(label: "Live preview", selection: $previewMode,
                                  options: [("Bar", "Bar"), ("Hero", "Hero"), ("Dock", "Dock")])
                }

                NeonCard("Startup & Menu Bar") {
                    toggleRow("Open at login", $openAtLogin)
                        .onChange(of: openAtLogin) { applyOpenAtLogin($0) }
                    NeonDivider()
                    toggleRow("Menu-bar only (hide Dock icon)", $menuBarOnly)
                        .onChange(of: menuBarOnly) { NSApp.setActivationPolicy($0 ? .accessory : .regular) }
                    NeonDivider()
                    toggleRow("Open Settings at launch", $openAtLaunch)
                    NeonDivider()
                    toggleRow("Keep running in the background", $runInBackground)
                }

                NeonCard("Advanced Macros") {
                    toggleRow("Allow Shell and AppleScript tiles", $allowExecutableMacros)
                    Text("Treat shared page configs as executable content. Leave this off unless you trust every shell or AppleScript tile on your pages.")
                        .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }

                NeonCard("Developer Mode") {
                    toggleRow("Show device debug actions", $developerMode)
                    Text("Reveals manual RGB probe, tour, browse, and CPU sweep actions after relaunch. These write to the HID/VIA lighting interface.")
                        .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                    NeonDivider()
                    toggleRow("Enable private thermal sensors", $enablePrivateThermals)
                    Text("Reads temperature sensors through private IOHIDEventSystem symbols. Leave this off unless you accept the compatibility and distribution risk.")
                        .font(.system(size: 11)).foregroundColor(NeonTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }

                NeonCard("Device launch") {
                    HStack {
                        Text("Open Quake panel to")
                            .font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
                        Spacer(minLength: 16)
                        Picker("", selection: $startupTarget) {
                            ForEach(launchOptions, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden().pickerStyle(.menu).tint(NeonTheme.cyan)
                        .frame(maxWidth: 200)
                    }
                    .padding(.vertical, 9)
                }

                NeonCard("Language") {
                    NeonPickerRow(label: "Language", selection: $language,
                                  options: [("System", "System"), ("English", "English")])
                }

                NeonCard("About") {
                    NeonInfoRow(label: "App", value: "Quake4Mac")
                    NeonDivider()
                    NeonInfoRow(label: "Version", value: Self.version)
                    NeonDivider()
                    NeonInfoRow(label: "Device", value: "DK-QUAKE / ARIS-68")
                }
            }
        }
    }

    private func toggleRow(_ label: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundColor(NeonTheme.textPrimary)
            Spacer(minLength: 16)
            Toggle("", isOn: isOn).toggleStyle(.switch).tint(NeonTheme.cyan).labelsHidden()
        }
        .padding(.vertical, 9)
    }

    private func applyOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[Quake] open-at-login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    private static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
