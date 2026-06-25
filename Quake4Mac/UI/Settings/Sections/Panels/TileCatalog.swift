// TileCatalog.swift — Quake4Mac settings app
//
// The draggable tile library shown in the Tile Editor. Each TileSpec is a ready-to-place tile
// (glyph + tint + action) tagged with a category, so the library groups as All / functional /
// per-app. TileSpec carries across a drag as a JSON string and rebuilds a Tile on drop.
//
// Seeded from: (1) the real default pages (with their real actions + icons), (2) a per-app Discord
// set, and (3) the FULL set of shipped DecoKee glyphs as ready-to-assign macro tiles (action set
// later via per-tile editing). Editor-UI chrome and pure status icons are intentionally excluded.

import SwiftUI

struct TileSpec: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var symbol: String
    var image: String?
    var tintHex: String
    var category: String
    var app: String?
    var actKind: String = "none"
    var actStr: String?
    var actInt: Int?
    var fromSlot: Int? = nil   // set when dragging an existing strip tile (move/swap within a page)
    var editable: Bool = false // custom tiles (user-created) are editable; catalog presets are not

    var appBundleID: String? { actKind == "app" ? actStr : nil }
    var openURLValue: String? { actKind == "url" ? actStr : nil }

    init(from t: Tile, category: String, app: String? = nil) {
        title = t.title; symbol = t.symbol; image = t.image
        tintHex = t.tint.hexRGB; self.category = category; self.app = app; editable = t.editable
        applyAction(t.action)
    }

    init(title: String, symbol: String, image: String? = nil, tint: Color,
         category: String, app: String? = nil, action: PadAction = .none) {
        self.title = title; self.symbol = symbol; self.image = image
        self.tintHex = tint.hexRGB; self.category = category; self.app = app
        applyAction(action)
    }

    private mutating func applyAction(_ a: PadAction) {
        switch a {
        case .launchApp(let b):   actKind = "app";     actStr = b
        case .openURL(let u):     actKind = "url";     actStr = u
        case .shell(let c):       actKind = "shell";   actStr = c
        case .appleScript(let x): actKind = "ascript"; actStr = x
        case .luminance(let d):   actKind = "lum";     actInt = d
        case .system(let a):      actKind = "sys";     actStr = a.rawValue
        case .openPage(let n):    actKind = "page";    actStr = n
        case .none:               actKind = "none"
        }
    }

    var action: PadAction {
        switch actKind {
        case "app":     return .launchApp(bundleID: actStr ?? "")
        case "url":     return .openURL(actStr ?? "")
        case "shell":   return .shell(actStr ?? "")
        case "ascript": return .appleScript(actStr ?? "")
        case "lum":     return .luminance(delta: actInt ?? 0)
        case "sys":     return SystemAction(rawValue: actStr ?? "").map(PadAction.system) ?? .none
        case "page":    return .openPage(actStr ?? "")
        default:        return .none
        }
    }

    func makeTile() -> Tile {
        Tile(title: title, symbol: symbol, tint: Color(hexRGB: tintHex), action: action, image: image, editable: editable)
    }

    var dragString: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func decode(_ s: String) -> TileSpec? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TileSpec.self, from: d)
    }
}

enum TileCatalog {
    static let all: [TileSpec] = build()

    private static func build() -> [TileSpec] {
        var out: [TileSpec] = []
        // (1) Real default-page tiles — keep their working actions.
        for page in PadModel.defaultPages() {
            for t in page.tiles where !t.title.isEmpty { out.append(TileSpec(from: t, category: page.name)) }
        }
        // (2) Per-app Discord set.
        out += discord
        // (3) Every other shipped glyph as a ready-to-assign macro tile (deduped by image).
        let used = Set(out.compactMap { $0.image })
        for g in glyphTable where !used.contains(g.0) {
            out.append(TileSpec(title: g.1, symbol: symbol(for: g.2), image: g.0,
                                tint: tint(for: g.2), category: g.2))
        }
        return out
    }

    private static let discord: [TileSpec] = [
        TileSpec(title: "Mute",         symbol: "mic.slash.fill",        image: "dc_mute_off",            tint: .indigo, category: "Discord", app: "Discord"),
        TileSpec(title: "Deafen",       symbol: "speaker.slash.fill",    image: "dc_deafen",              tint: .indigo, category: "Discord", app: "Discord"),
        TileSpec(title: "Camera",       symbol: "video.slash.fill",      image: "dc_camera_off",          tint: .indigo, category: "Discord", app: "Discord"),
        TileSpec(title: "Push to Talk", symbol: "dot.radiowaves.left.and.right", image: "dc_push_to_talk", tint: .indigo, category: "Discord", app: "Discord"),
        TileSpec(title: "Private PTT",  symbol: "lock.fill",             image: "dc_push_to_talk_private",tint: .indigo, category: "Discord", app: "Discord"),
        TileSpec(title: "Screen Share", symbol: "rectangle.on.rectangle",image: "dc_screen_share",        tint: .indigo, category: "Discord", app: "Discord"),
        TileSpec(title: "Stream Mode",  symbol: "antenna.radiowaves.left.and.right", image: "dc_stream_mode", tint: .indigo, category: "Discord", app: "Discord"),
        TileSpec(title: "Game Mode",    symbol: "gamecontroller.fill",   image: "discord_game_mode",      tint: .indigo, category: "Discord", app: "Discord"),
    ]

    // (name, title, category) for the shipped glyphs. Excludes icon-* editor chrome, status icons
    // (loading/delayed/gap/config_item_invalid/connectionType), assistant states, claw/* internals,
    // and placeholders (custom_icon/mdi/decokee/pixel_lobster).
    private static let glyphTable: [(String, String, String)] = [
        // Media / playback
        ("play_pause","Play / Pause","Media"), ("stop_play","Stop","Media"), ("skip_back","Previous","Media"),
        ("skip_forward","Next","Media"), ("fast_backward","Rewind","Media"), ("fast_forward","Fast Fwd","Media"),
        ("random_play","Shuffle","Media"), ("repeat_play","Repeat","Media"), ("playAudio","Play Audio","Media"),
        ("stopAudio","Stop Audio","Media"), ("stopShow","Stop Show","Media"), ("media","Media","Media"),
        ("volume","Volume","Media"), ("mute","Mute","Media"), ("mute_off","Unmute","Media"), ("pc_mic","PC Mic","Media"),
        // Premiere / video edit
        ("prem_cut","Cut","Premiere"), ("prem_cutjump","Cut & Jump","Premiere"), ("prem_fast_play","Fast Play","Premiere"),
        ("prem_play_stop","Play / Stop","Premiere"), ("prem_time_ctrl","Time Ctrl","Premiere"),
        ("prem_timeline_zoom","Timeline Zoom","Premiere"), ("prem_trim","Trim","Premiere"),
        ("prem_undo","Undo","Premiere"), ("prem_video_ctrl","Video Ctrl","Premiere"),
        // AI & chat
        ("aichat_compliance","Compliance","AI & Chat"), ("aichat_contentwriter","Content Writer","AI & Chat"),
        ("aichat_maths","Maths","AI & Chat"), ("aichat_search","AI Search","AI & Chat"), ("aichat_term","Terminology","AI & Chat"),
        ("aichat_translate","AI Translate","AI & Chat"), ("chatgpt","ChatGPT","AI & Chat"), ("deepseek","DeepSeek","AI & Chat"),
        ("qwen","Qwen","AI & Chat"), ("code_optimize","Optimize Code","AI & Chat"), ("explain","Explain","AI & Chat"),
        ("summarize","Summarize","AI & Chat"), ("translate","Translate","AI & Chat"), ("meeting_minutes","Meeting Minutes","AI & Chat"),
        ("live_translate","Live Translate","AI & Chat"), ("task_center","Task Center","AI & Chat"), ("assistant_chat_bot","AI Assistant","AI & Chat"),
        // System actions
        ("control_panel","Settings","System"), ("quick_settings","Quick Settings","System"), ("launchpad","Launchpad","System"),
        ("mission_control","Mission Control","System"), ("multi_window","Multi-Window","System"), ("new_desktop","New Desktop","System"),
        ("lock_screen","Lock","System"), ("force_quit","Force Quit","System"), ("screenshot","Screenshot","System"),
        ("terminal","Terminal","System"), ("projection","Projection","System"), ("switchProfile","Switch Profile","System"),
        ("clip_board","Clipboard","System"), ("folder","Folder","System"), ("device_mic","Mic","System"),
        ("device_mic_mute","Mic Mute","System"), ("device_luminance","Luminance","System"),
        // System info (icons for monitor / activity macros)
        ("cpu_info","CPU","System Info"), ("gpu_info","GPU","System Info"), ("mem_info","Memory","System Info"),
        ("disk_info","Disk","System Info"), ("network_info","Network","System Info"), ("power_info","Power","System Info"),
        ("bluetooth_info","Bluetooth","System Info"), ("process_info","Processes","System Info"),
        // Display / brightness
        ("brightness","Brightness","Display"), ("brightest","Brightest","Display"), ("darker","Darker","Display"),
        ("darkest","Darkest","Display"), ("lighter","Lighter","Display"), ("increase","Increase","Display"), ("reduction","Decrease","Display"),
        // Text formatting
        ("bold","Bold","Text"), ("italic","Italic","Text"), ("underline","Underline","Text"),
        ("font","Font","Text"), ("text","Text","Text"), ("emoji","Emoji","Text"),
        // Numbers
        ("num1","1","Numbers"), ("num2","2","Numbers"), ("num3","3","Numbers"), ("num4","4","Numbers"), ("num5","5","Numbers"),
        ("num6","6","Numbers"), ("num7","7","Numbers"), ("num8","8","Numbers"), ("num9","9","Numbers"), ("num10","10","Numbers"),
        // Web / integrations
        ("website","Website","Web"), ("global_search","Search","Web"), ("home_assistant","Home Assistant","Web"),
        // Macro / control
        ("hotkey","Hotkey","Macro"), ("hotkeySwitch","Hotkey Switch","Macro"), ("hotKeySwitch2","Hotkey Switch 2","Macro"),
        ("multiActions","Multi-Action","Macro"), ("pressTime","Press Time","Macro"), ("timer","Timer","Macro"),
        ("alarmClock","Alarm","Macro"), ("temp_record","Record","Macro"), ("buzzer","Buzzer","Macro"), ("buzzer_off","Buzzer Off","Macro"),
        // 3D printer
        ("printer_camera","Printer Cam","Printer"), ("printer_control","Printer Ctrl","Printer"), ("printer_status","Printer Status","Printer"),
        // Navigation / misc
        ("back","Back","Nav"), ("open","Open","Nav"), ("more","More","Nav"), ("help","Help","Nav"),
        ("question","Question","Nav"), ("exclamation","Alert","Nav"), ("attention","Attention","Nav"),
        ("checkmark","Done","Nav"), ("copy","Copy","Nav"), ("disable","Disable","Nav"),
        ("pageUp","Page Up","Nav"), ("pageDown","Page Down","Nav"), ("pageNo","Page No","Nav"), ("goToPage","Go To Page","Nav"),
    ]

    private static func tint(for cat: String) -> Color {
        switch cat {
        case "Media":       return .green
        case "Premiere":    return .purple
        case "AI & Chat":   return .cyan
        case "System":      return .gray
        case "System Info": return .mint
        case "Display":     return .orange
        case "Text":        return .blue
        case "Numbers":     return .teal
        case "Web":         return .blue
        case "Macro":       return .yellow
        case "Printer":     return .orange
        case "Nav":         return Color(white: 0.6)
        default:            return .purple
        }
    }
    private static func symbol(for cat: String) -> String {
        switch cat {
        case "Media":       return "play.fill"
        case "Premiere":    return "film"
        case "AI & Chat":   return "bubble.left.fill"
        case "System":      return "gearshape.fill"
        case "System Info": return "cpu"
        case "Display":     return "sun.max.fill"
        case "Text":        return "textformat"
        case "Numbers":     return "number"
        case "Web":         return "globe"
        case "Macro":       return "bolt.fill"
        case "Printer":     return "printer.fill"
        case "Nav":         return "arrow.right"
        default:            return "square.fill"
        }
    }

    static var categories: [String] {
        var seen: [String] = []
        for s in all where !seen.contains(s.category) { seen.append(s.category) }
        return seen
    }

    static func tiles(category: String) -> [TileSpec] {
        category == "All" ? all : all.filter { $0.category == category }
    }
}
