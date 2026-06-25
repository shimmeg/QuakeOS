// Lyrics.swift — Quake4Mac
//
// Fetches lyrics from lrclib.net (free, no auth) by artist + title (+ album/duration when
// known). Returns plain lyrics; lrclib also offers synced lyrics if we want karaoke later.

import Foundation
import Combine

final class Lyrics: ObservableObject {
    static let shared = Lyrics()

    @Published var lines: [String] = []                 // plain fallback
    @Published var synced: [[String: Any]] = []         // [{t: ms, text: String}] for real-time sync
    @Published var status: String = ""                  // "", "searching", "none"
    private var lastKey = ""
    private struct Entry { let lines: [String]; let synced: [[String: Any]] }
    private var cache: [String: Entry] = [:]            // song → lyrics, so we never re-fetch the same song

    func update(title: String, artist: String, album: String = "", durationSec: Int = 0) {
        let key = "\(title.lowercased())|\(artist.lowercased())"
        guard !title.isEmpty, key != lastKey else { return }
        lastKey = key

        // Instant if we've already fetched this song this session.
        if let cached = cache[key] {
            lines = cached.lines; synced = cached.synced
            status = (cached.lines.isEmpty && cached.synced.isEmpty) ? "none" : ""
            return
        }
        status = "searching"; lines = []; synced = []

        // Search all matches and pick the original-language version (most non-Latin script),
        // rather than an exact-match that might be an English translation.
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        guard let url = c.url else { return }
        var req = URLRequest(url: url)
        req.setValue("Quake4Mac (https://github.com)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            var plain: [String] = []
            var sync: [[String: Any]] = []
            if let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // Prefer original language (most non-Latin), then prefer entries that have timed lyrics.
                func score(_ d: [String: Any]) -> Int {
                    let p = d["plainLyrics"] as? String ?? ""
                    let hasSync = !((d["syncedLyrics"] as? String ?? "").isEmpty)
                    return Self.nonLatin(p) * 1000 + (hasSync ? 1 : 0)
                }
                let usable = arr.filter { !(($0["plainLyrics"] as? String ?? "").isEmpty) || !(($0["syncedLyrics"] as? String ?? "").isEmpty) }
                // Deterministic pick: highest score, ties broken by earliest original order (so equal-scored candidates don't shuffle).
                if let best = usable.enumerated().max(by: { a, b in
                    let sa = score(a.element), sb = score(b.element)
                    return sa != sb ? sa < sb : a.offset > b.offset
                })?.element {
                    plain = (best["plainLyrics"] as? String ?? "").components(separatedBy: "\n")
                    sync = Self.parseLRC(best["syncedLyrics"] as? String ?? "")
                }
            }
            DispatchQueue.main.async {
                self.cache[key] = Entry(lines: plain, synced: sync)
                if self.lastKey == key {
                    self.lines = plain; self.synced = sync
                    self.status = (plain.isEmpty && sync.isEmpty) ? "none" : ""
                }
            }
        }.resume()
    }

    /// Parse LRC ("[mm:ss.xx] text") into [{t: ms, text}], sorted by time.
    private static func parseLRC(_ s: String) -> [[String: Any]] {
        guard !s.isEmpty,
              let re = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?:[.:](\\d{1,3}))?\\]") else { return [] }
        var out: [[String: Any]] = []
        for line in s.components(separatedBy: "\n") {
            let ns = line as NSString
            let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty, let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let mm = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Int(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = Int(f.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
                }
                let ms = (mm * 60 + ss) * 1000 + frac
                out.append(["t": ms, "text": text])
            }
        }
        return out.sorted { ($0["t"] as? Int ?? 0) < ($1["t"] as? Int ?? 0) }
    }

    /// Count of non-Latin alphabetic letters (Cyrillic, CJK, Arabic, Hebrew, Korean, Thai, Greek,
    /// Devanagari, …) — higher means more likely the original language rather than an English
    /// translation. Letters only (ignores digits/punctuation/spaces); a scalar counts as non-Latin
    /// when it is alphabetic and lies beyond the Latin ranges (Basic Latin + Latin-1/Extended-A/B).
    private static func nonLatin(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { acc, u in
            acc + ((u.value > 0x024F && u.properties.isAlphabetic) ? 1 : 0)
        }
    }
}
