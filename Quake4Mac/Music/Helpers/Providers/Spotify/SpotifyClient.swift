// SpotifyClient.swift — Quake4Mac
//
// Thin Spotify Web API client used by the music screen: now-playing (with album art),
// the up-next queue, the user's playlists, and transport control. All requests carry a
// bearer token minted by SpotifyAuth.

import Foundation
import Combine

final class SpotifyClient: ObservableObject {
    static let shared = SpotifyClient()
    private let auth = SpotifyAuth.shared

    struct Track: Identifiable { let id = UUID(); let title: String; let artist: String; let art: String?; let uri: String }
    struct Playlist: Identifiable { let id: String; let name: String; let art: String?; let uri: String }

    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var art: String? = nil
    @Published var isPlaying = false
    @Published var durationMs = 0
    @Published var progressMs = 0
    @Published var queue: [Track] = []
    @Published var shuffle = false
    @Published var repeatMode = "off"  // "off" | "track" | "context"
    @Published var available = false   // a token exists and the API answered
    @Published var contextURI: String? = nil
    @Published var currentTrackURI: String? = nil
    @Published var playlists: [Playlist] = []
    @Published var contextTracks: [[String: Any]] = []     // tracks of the currently-playing context (Current tab)
    @Published var playlistTracks: [[String: Any]] = []    // tracks of a playlist the user opened (Playlists tab)
    @Published var deviceID: String? = nil                 // active (or first available) device, for control
    @Published var tracksDebug = ""                        // last track-fetch outcome (for diagnosing "Loading")

    private func withDevice(_ path: String) -> String {
        guard let d = deviceID else { return path }
        return path + (path.contains("?") ? "&" : "?") + "device_id=\(d)"
    }

    private var timer: Timer?
    private var pollBusy = false

    /// When Spotify rate-limits us (HTTP 429), skip all player calls until this time —
    /// hammering through a 429 only makes Spotify extend the ban.
    var rateLimitedUntil: Date?

    var isConnected: Bool { auth.isConnected }

    /// When the RGB music-tint feature is on we keep polling even after the music screen closes,
    /// so the ring can follow now-playing anywhere. `pinned` makes stop() a no-op.
    var pinned = false

    func start() {
        // Always poll; calls are no-ops until a token exists, then pick up automatically.
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { guard !pinned else { return }; timer?.invalidate(); timer = nil }

    private var pollTick = 0
    private func poll() {
        if isBackingOff { return }   // backing off after a 429
        guard !pollBusy else { return }
        pollBusy = true
        let shouldFetchQueue = pollTick % 3 == 0
        let shouldFetchDevices = deviceID == nil
        pollTick &+= 1
        fetchNowPlaying { [weak self] in        // ONE /me/player call: now-playing + state + device
            guard let self else { return }
            self.pollBusy = false
            if shouldFetchQueue { self.fetchQueue() }       // queue changes slowly — fetch every ~9s
            if shouldFetchDevices { self.fetchDevices() }   // only until we learn a device
        }
    }

    private func fetchDevices() {
        get("/me/player/devices") { [weak self] json, code in
            guard let self else { return }
            guard (200..<300).contains(code), let json else { return }
            let ds = json["devices"] as? [[String: Any]] ?? []
            self.deviceID = (ds.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String) ?? (ds.first?["id"] as? String)
        }
    }

    // MARK: Reads

    /// One consolidated /me/player call — returns now-playing track, play state, shuffle,
    /// repeat, progress, context AND the active device, replacing the 3 separate calls that
    /// were tripping Spotify's rate limit.
    private func fetchNowPlaying(completion: (() -> Void)? = nil) {
        get("/me/player") { [weak self] json, code in
            defer { completion?() }
            guard let self else { return }
            // 204/empty = nothing active on any device; keep last-known title/artist/art to
            // avoid flicker, but clear the "playing" state so the scrubber doesn't look like
            // it's playing a frozen track.
            guard let json, let item = json["item"] as? [String: Any] else {
                if code == 204 {
                    self.isPlaying = false
                    self.progressMs = 0
                }
                return
            }
            self.available = true
            self.title = item["name"] as? String ?? ""
            self.artist = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
            if let alb = item["album"] as? [String: Any] {
                self.album = alb["name"] as? String ?? ""
                self.art = (alb["images"] as? [[String: Any]])?.first?["url"] as? String
            }
            self.isPlaying = json["is_playing"] as? Bool ?? false
            self.durationMs = item["duration_ms"] as? Int ?? 0
            self.progressMs = json["progress_ms"] as? Int ?? 0
            self.contextURI = (json["context"] as? [String: Any])?["uri"] as? String
            self.currentTrackURI = item["uri"] as? String
            self.shuffle = json["shuffle_state"] as? Bool ?? self.shuffle
            self.repeatMode = json["repeat_state"] as? String ?? self.repeatMode
            if let dev = json["device"] as? [String: Any], let id = dev["id"] as? String { self.deviceID = id }
        }
    }

    private func fetchQueue() {
        get("/me/player/queue") { [weak self] json, code in
            guard let self, let json else { return }
            guard (200..<300).contains(code) else { return }
            let items = json["queue"] as? [[String: Any]] ?? []
            self.queue = items.prefix(8).map { Self.track(from: $0) }
        }
    }

    func loadPlaylists() {
        get("/me/playlists?limit=30") { [weak self] json, code in
            guard let self else { return }
            guard (200..<300).contains(code), let json else { return }
            let items = json["items"] as? [[String: Any]] ?? []
            self.playlists = items.compactMap { p in
                guard let name = p["name"] as? String, let uri = p["uri"] as? String else { return nil }
                let art = (p["images"] as? [[String: Any]])?.first?["url"] as? String
                return Playlist(id: p["id"] as? String ?? uri, name: name, art: art, uri: uri)
            }
        }
    }

    func loadContextTracks() {
        guard let ctx = contextURI else { contextTracks = []; return }
        fetchTracks(forContextURI: ctx) { [weak self] tracks in self?.contextTracks = tracks }
    }

    func loadPlaylistTracks(_ uri: String) {
        fetchTracks(forContextURI: uri) { [weak self] tracks in self?.playlistTracks = tracks }
    }

    /// Fetch tracks for a playlist OR album context URI. Reports the actual outcome to tracksDebug.
    private func fetchTracks(forContextURI uri: String, _ completion: @escaping ([[String: Any]]) -> Void) {
        if isBackingOff { setDebug("rate limited"); return }   // backing off after a 429
        let parts = uri.components(separatedBy: ":")   // spotify:playlist:ID  /  spotify:album:ID
        guard parts.count >= 3 else { setDebug("bad uri: \(uri)"); completion([]); return }
        let type = parts[1], id = parts[2]
        let path: String
        if type == "playlist" { path = "/playlists/\(id)/items?limit=100" }   // /tracks was deprecated Feb 2026 → 403
        else if type == "album" { path = "/albums/\(id)/tracks?limit=50" }
        else { setDebug("unsupported context: \(type)"); completion([]); return }

        // currentTrackURI is @Published, written on main by fetchNowPlaying — capture it here
        // (fetchTracks runs on main) so the background dataTask doesn't read it concurrently.
        let currentURI = self.currentTrackURI

        auth.validToken { [weak self] tok in
            guard let self else { return }
            guard let tok, let url = URL(string: "https://api.spotify.com/v1" + path) else {
                self.setDebug("no token"); DispatchQueue.main.async { completion([]) }; return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { data, resp, err in
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                if code == 429 {
                    self.backOff(http)
                    self.setDebug("HTTP 429: rate limited")
                    return
                }
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
                if let apiErr = (json?["error"] as? [String: Any])?["message"] as? String {
                    self.setDebug("HTTP \(code): \(apiErr)"); DispatchQueue.main.async { completion([]) }; return
                }
                let items = json?["items"] as? [[String: Any]] ?? []
                let tracks: [[String: Any]] = items.compactMap { it in
                    // New /items can wrap under "track" or "item", or be the track itself.
                    let tr = (it["track"] as? [String: Any]) ?? (it["item"] as? [String: Any]) ?? it
                    let uri = (tr["uri"] as? String) ?? (tr["id"] as? String).map { "spotify:track:\($0)" }
                    guard let u = uri else { return nil }
                    let title = tr["name"] as? String ?? ""
                    let artist = (tr["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
                    let art = ((tr["album"] as? [String: Any])?["images"] as? [[String: Any]])?.last?["url"] as? String
                    return ["uri": u, "title": title, "artist": artist, "art": art ?? NSNull(), "current": (u == currentURI)]
                }
                if tracks.isEmpty {
                    let ik = items.first.map { Array($0.keys).joined(separator: ",") } ?? "nil"
                    let tk = (items.first?["track"] as? [String: Any]).map { Array($0.keys).joined(separator: ",") } ?? "no-track-key"
                    self.setDebug("HTTP \(code): 0/\(items.count) · itemKeys[\(ik)] · trackKeys[\(tk)]")
                } else { self.setDebug("") }
                DispatchQueue.main.async { completion(tracks) }
            }.resume()
        }
    }

    private func setDebug(_ s: String) { DispatchQueue.main.async { self.tracksDebug = s } }

    private static func track(from t: [String: Any]) -> Track {
        let title = t["name"] as? String ?? ""
        let artist = (t["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
        let art = ((t["album"] as? [String: Any])?["images"] as? [[String: Any]])?.last?["url"] as? String
        return Track(title: title, artist: artist, art: art, uri: t["uri"] as? String ?? "")
    }

    // MARK: Control

    func playPause() {
        if isBackingOff { return }
        let wasPlaying = isPlaying
        isPlaying.toggle()
        command("PUT", withDevice(wasPlaying ? "/me/player/pause" : "/me/player/play")) { self.fetchNowPlaying() }
    }
    func next()      { command("POST", withDevice("/me/player/next")) { self.poll() } }
    func previous()  { command("POST", withDevice("/me/player/previous")) { self.poll() } }

    func toggleShuffle() { command("PUT", withDevice("/me/player/shuffle?state=\(!shuffle)")) { self.fetchNowPlaying() } }
    /// off → loop current song (track) → loop playlist (context) → off
    func cycleRepeat() {
        let next = repeatMode == "off" ? "track" : (repeatMode == "track" ? "context" : "off")
        command("PUT", withDevice("/me/player/repeat?state=\(next)")) { self.fetchNowPlaying() }
    }

    func play(contextURI uri: String, offsetURI: String? = nil) {
        var body: [String: Any] = ["context_uri": uri]
        if let off = offsetURI { body["offset"] = ["uri": off] }
        command("PUT", withDevice("/me/player/play"), body: body) { self.poll() }
    }

    /// Switch straight to specific track(s) — used when tapping a song in the queue.
    func playURIs(_ uris: [String]) {
        command("PUT", withDevice("/me/player/play"), body: ["uris": uris]) { self.poll() }
    }

    // MARK: HTTP

    /// Pause all polling after a 429. Honour Spotify's full Retry-After (so we stop probing
    /// until it's actually clear) and log the real value so we know how long it wants.
    private func backOff(_ http: HTTPURLResponse?) {
        let raw = http?.value(forHTTPHeaderField: "Retry-After") ?? "(none)"
        let secs = max(5, min(3600, Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30))
        DispatchQueue.main.async {
            self.rateLimitedUntil = Date().addingTimeInterval(secs)
            NSLog("[Quake] Spotify 429 — Retry-After: \(raw)  → pausing all calls for \(Int(secs))s")
        }
    }

    private var isBackingOff: Bool {
        if let until = rateLimitedUntil, Date() < until { return true }
        return false
    }

    private func get(_ path: String, _ completion: @escaping ([String: Any]?, Int) -> Void) {
        if isBackingOff { DispatchQueue.main.async { completion(nil, 429) }; return }   // backing off after a 429
        auth.validToken { tok in
            guard let tok else { DispatchQueue.main.async { completion(nil, 401) }; return }
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
            req.timeoutInterval = 10
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                if code == 429 { self.backOff(http) }
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
                DispatchQueue.main.async { completion(json, code) }
            }.resume()
        }
    }

    private func command(_ method: String, _ path: String, body: [String: Any]? = nil, then: (() -> Void)? = nil) {
        if isBackingOff { return }   // backing off after a 429
        auth.validToken { tok in
            guard let tok else { return }
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
            req.timeoutInterval = 10
            req.httpMethod = method
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            if let body = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                if code == 429 { self.backOff(http) }
                else if code < 200 || code >= 300 {
                    NSLog("[Quake] Spotify \(method) \(path) → HTTP \(code) (403=scope/Premium, 404=no active device, 401=token)")
                }
                DispatchQueue.main.async {
                    if let then = then { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { then() } }
                    else { self.fetchNowPlaying() }
                }
            }.resume()
        }
    }
}
