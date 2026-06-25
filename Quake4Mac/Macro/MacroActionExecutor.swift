// MacroActionExecutor.swift - Quake4Mac
//
// Central execution boundary for macro tile actions. Shell and AppleScript are
// executable content, so they are blocked unless the user enables advanced macros.

import AppKit
import Foundation

enum MacroActionExecutor {
    static let executableMacrosEnabledKey = "settings.allowExecutableMacros"
    private static let macroTimeout: TimeInterval = 30
    private static let maxMacroErrorBytes = 4_096

    static var executableMacrosEnabled: Bool {
        UserDefaults.standard.bool(forKey: executableMacrosEnabledKey)
    }

    static func execute(_ action: PadAction, input: QuakeInputReader,
                        openPage: @escaping (String) -> Void,
                        log: @escaping (String) -> Void) {
        switch action {
        case .launchApp(let bid):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                log("launch app \(bid)")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                log("launch app failed: \(bid) not found")
            }
        case .openURL(let s):
            if let url = Self.webURL(from: s) {
                log("open URL")
                NSWorkspace.shared.open(url)
            } else {
                log("open URL blocked: only http and https URLs are allowed")
            }
        case .shell(let command):
            runExecutableMacro(
                label: "shell",
                executable: "/bin/zsh",
                arguments: ["-lc", command],
                log: log
            )
        case .appleScript(let source):
            runExecutableMacro(
                label: "applescript",
                executable: "/usr/bin/osascript",
                arguments: ["-e", source],
                log: log
            )
        case .luminance(let delta):
            input.setLuminance(input.luminance + delta)
        case .system(let action):
            runSystem(action, log: log)
        case .openPage(let name):
            openPage(name)
        case .none:
            log("tile action skipped: no action assigned")
        }
    }

    static func executableWarning(for kind: String) -> String? {
        guard kind == "shell" || kind == "ascript" else { return nil }
        return "Shell and AppleScript tiles are advanced macros. They run local code and are blocked until enabled in General settings."
    }

    static func webURL(from raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              isSafeWebURL(url) else { return nil }
        return url
    }

    static func isSafeWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    private static func runExecutableMacro(label: String, executable: String, arguments: [String],
                                           log: @escaping (String) -> Void) {
        guard executableMacrosEnabled else {
            log("\(label) blocked: enable advanced macros in Settings before running executable tile actions")
            return
        }
        runProcess(executable, arguments: arguments, label: label, log: log)
    }

    private static func runSystem(_ action: SystemAction, log: @escaping (String) -> Void) {
        switch action {
        case .activityMonitor:
            openApp(bundleID: "com.apple.ActivityMonitor",
                    fallbackPath: "/System/Applications/Utilities/Activity Monitor.app",
                    label: "Activity Monitor",
                    log: log)
        case .missionControl:
            openApp(bundleID: "com.apple.exposelauncher",
                    fallbackPath: "/System/Applications/Mission Control.app",
                    label: "Mission Control",
                    log: log)
        case .volumeUp:
            runFixedAppleScript("set volume output volume ((output volume of (get volume settings)) + 12)",
                                label: "volume up",
                                log: log)
        case .volumeDown:
            runFixedAppleScript("set volume output volume ((output volume of (get volume settings)) - 12)",
                                label: "volume down",
                                log: log)
        case .mute:
            runFixedAppleScript("set volume output muted (not (output muted of (get volume settings)))",
                                label: "mute",
                                log: log)
        }
    }

    private static func openApp(bundleID: String, fallbackPath: String, label: String,
                                log: @escaping (String) -> Void) {
        let fallback = URL(fileURLWithPath: fallbackPath)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? (FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil) else {
            log("system \(label) failed: app not found")
            return
        }
        log("system \(label)")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func runFixedAppleScript(_ source: String, label: String,
                                            log: @escaping (String) -> Void) {
        guard let script = NSAppleScript(source: source) else {
            log("system \(label) failed: invalid script")
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            log("system \(label) failed: \(error)")
        } else {
            log("system \(label) OK")
        }
    }

    private static func runProcess(_ executable: String, arguments: [String], label: String,
                                   log: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let err = Pipe()
        p.standardError = err
        let errHandle = err.fileHandleForReading
        let errQueue = DispatchQueue(label: "com.quake4mac.macro.stderr")
        let stateQueue = DispatchQueue(label: "com.quake4mac.macro.state")
        var errData = Data()
        var timedOut = false

        let appendError: (Data) -> Void = { chunk in
            guard !chunk.isEmpty, errData.count < maxMacroErrorBytes else { return }
            let remaining = maxMacroErrorBytes - errData.count
            errData.append(contentsOf: chunk.prefix(remaining))
        }

        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errQueue.async { appendError(chunk) }
            }
        }

        let timeout = DispatchWorkItem { [weak p] in
            guard let p, p.isRunning else { return }
            stateQueue.sync { timedOut = true }
            p.terminate()
        }

        p.terminationHandler = { proc in
            timeout.cancel()
            errHandle.readabilityHandler = nil
            let didTimeout = stateQueue.sync { timedOut }
            errQueue.async {
                let detail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    if didTimeout {
                        log("\(label) timed out after \(Int(macroTimeout))s and was terminated")
                    } else if proc.terminationStatus == 0 {
                        log("\(label) OK")
                    } else if detail.isEmpty {
                        log("\(label) failed with status \(proc.terminationStatus)")
                    } else {
                        log("\(label) failed with status \(proc.terminationStatus): \(detail)")
                    }
                }
            }
        }
        do {
            try p.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + macroTimeout, execute: timeout)
        } catch {
            timeout.cancel()
            errHandle.readabilityHandler = nil
            log("\(label) launch failed: \(error.localizedDescription)")
        }
    }
}
