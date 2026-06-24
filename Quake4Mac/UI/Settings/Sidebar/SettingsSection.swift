// SettingsSection.swift — Quake4Mac settings app
//
// Every page in the redesigned Settings, grouped under sidebar headers. Built from the user's
// written spec (not the older mockup sidebar): Device / Panels / Lighting / Studio / Advanced.

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case pages, prebuilt, layout
    case rgbRing, reactive
    case panelCreator, tileEditor
    case webDashboards, aiVoice, apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:       return "General"
        case .pages:         return "Pages"
        case .prebuilt:      return "Prebuilt Panels"
        case .layout:        return "Layout"
        case .rgbRing:       return "RGB Ring"
        case .reactive:      return "Reactive Lighting"
        case .panelCreator:  return "Panel Creator"
        case .tileEditor:    return "Tile Editor"
        case .webDashboards: return "Web Dashboards"
        case .aiVoice:       return "AI & Voice"
        case .apps:          return "Apps"
        }
    }

    /// One-line description shown under the section title.
    var subtitle: String {
        switch self {
        case .general:       return "App language, version, appearance, and device basics."
        case .pages:         return "Your created panels — edit tiles, drag macros in, tweak each tile."
        case .prebuilt:      return "Built-in panels (Music, System Monitor, …) and their settings."
        case .layout:        return "Reorder, enable/disable, and auto-rotate the knob's pages."
        case .rgbRing:       return "The knob's built-in RGB effects, color, brightness, and speed."
        case .reactive:      return "Knob-flash, music, CPU heat, and page-theme lighting — ranked."
        case .panelCreator:  return "Create new panels, optionally starting from an existing one."
        case .tileEditor:    return "Build reusable tile templates to drag into any panel."
        case .webDashboards: return "Add full web dashboards (Home Assistant, Grafana, any URL)."
        case .aiVoice:       return "Voice + AI panels: meeting transcription, chat, push-to-talk."
        case .apps:          return "Drop in a self-contained web app folder as a panel."
        }
    }

    var icon: String {   // SF Symbols (all verified to exist)
        switch self {
        case .general:       return "gearshape"
        case .pages:         return "square.grid.2x2"
        case .prebuilt:      return "rectangle.on.rectangle"
        case .layout:        return "rectangle.3.group"
        case .rgbRing:       return "circle.circle"
        case .reactive:      return "sparkles"
        case .panelCreator:  return "plus.rectangle.on.rectangle"
        case .tileEditor:    return "square.grid.3x3.square"
        case .webDashboards: return "globe"
        case .aiVoice:       return "waveform"
        case .apps:          return "shippingbox"
        }
    }

    var badge: String? {
        switch self {
        case .panelCreator, .tileEditor:        return "Beta"
        case .webDashboards, .aiVoice, .apps:   return "Soon"
        default:                                return nil
        }
    }
}

// Built-in panels listed under the expandable "Prebuilt Panels" row.
enum PrebuiltPanel: String, CaseIterable, Identifiable {
    case monitor, music, clock, browser, weather
    var id: String { rawValue }
    var title: String {
        switch self {
        case .monitor: return "System Monitor"; case .music: return "Music"
        case .clock: return "Clock"; case .browser: return "Browser"; case .weather: return "Weather"
        }
    }
    var icon: String {
        switch self {
        case .monitor: return "cpu"; case .music: return "music.note"
        case .clock: return "clock"; case .browser: return "globe"; case .weather: return "cloud.sun"
        }
    }
}

// What the main content area is currently showing.
enum SettingsRoute: Hashable {
    case section(SettingsSection)   // a fixed leaf row (general, layout, rgbRing, …)
    case page(String)               // one macro page, by name (child of "Pages")
    case prebuilt(PrebuiltPanel)    // one built-in panel (child of "Prebuilt Panels")
}

extension SettingsSection {
    /// The two sidebar rows that expand to list children instead of opening their own page.
    var isExpandable: Bool { self == .pages || self == .prebuilt }
}

enum SettingsData {
    /// Names of the user's macro pages — the children shown under the "Pages" row (live from the store).
    static var pageNames: [String] { PadStore.shared.pages.map { $0.name } }
}

struct SettingsGroup: Identifiable {
    let id = UUID()
    let header: String
    let items: [SettingsSection]
}

let settingsGroups: [SettingsGroup] = [
    SettingsGroup(header: "Device",   items: [.general]),
    SettingsGroup(header: "Panels",   items: [.pages, .prebuilt, .layout]),
    SettingsGroup(header: "Lighting", items: [.rgbRing, .reactive]),
    SettingsGroup(header: "Studio",   items: [.panelCreator, .tileEditor]),
    SettingsGroup(header: "Advanced", items: [.webDashboards, .aiVoice, .apps]),
]
