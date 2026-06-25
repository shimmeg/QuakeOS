// NowPlaying.swift — Quake4Mac
//
// Polls the user's current track from Spotify (preferred, gives an artwork URL) or
// Apple Music via AppleScript. Feeds the web music preset. Lightweight: only runs
// while the music screen is visible.

import Foundation
import Combine

final class NowPlaying: ObservableObject {
    @Published var source = ""        // "Spotify" | "Music" | ""
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var isPlaying = false
    @Published var artwork: String? = nil   // http(s) URL (Spotify) or nil
    @Published var positionMs = 0

    private var timer: Timer?
    private var pollBusy = false

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private static let script = """
    set sep to (ASCII character 31)
    set out to "none" & sep & sep & sep & sep & sep
    tell application "System Events"
        set hasSpot to (exists process "Spotify")
        set hasMusic to (exists process "Music")
    end tell
    if hasSpot then
        tell application "Spotify"
            if player state is not stopped then
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set u to artwork url of current track
                set out to "Spotify" & sep & (player state as text) & sep & t & sep & a & sep & al & sep & u & sep & (player position as text)
            end if
        end tell
    end if
    if out starts with "none" and hasMusic then
        tell application "Music"
            if player state is not stopped then
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set out to "Music" & sep & (player state as text) & sep & t & sep & a & sep & al & sep & sep & (player position as text)
            end if
        end tell
    end if
    return out
    """

    private func poll() {
        guard !pollBusy else { return }
        pollBusy = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", Self.script]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                DispatchQueue.main.async { self.pollBusy = false }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let f = raw.components(separatedBy: "\u{1F}")
            DispatchQueue.main.async {
                self.pollBusy = false
                guard f.count >= 6, f[0] != "none" else {
                    self.source = ""; self.title = ""; self.artist = ""; self.album = ""
                    self.isPlaying = false; self.artwork = nil; self.positionMs = 0
                    return
                }
                self.source = f[0]
                self.isPlaying = (f[1] == "playing")
                self.title = f[2]
                self.artist = f[3]
                self.album = f[4]
                self.artwork = f[5].isEmpty ? nil : f[5]
                self.positionMs = f.count >= 7 ? Int((Double(f[6]) ?? 0) * 1000) : 0
            }
        }
    }
}
