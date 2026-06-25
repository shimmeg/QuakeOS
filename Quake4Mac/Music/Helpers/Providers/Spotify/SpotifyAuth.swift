// SpotifyAuth.swift — Quake4Mac
//
// Spotify "Authorization Code with PKCE" login (no client secret needed). Per Spotify's
// 2025 security rules the redirect URI must be HTTPS or a loopback address, so we run a
// tiny local listener on 127.0.0.1 and use http://127.0.0.1:8765/callback. The user
// registers that exact URI on their Spotify app and pastes the Client ID in Settings.

import Foundation
import CryptoKit
import AppKit
import Network

final class SpotifyAuth: NSObject, ObservableObject {

    static let shared = SpotifyAuth()

    static let port: UInt16 = 8765
    static let redirectURI = "http://127.0.0.1:8765/callback"
    static let scopes = "user-read-playback-state user-read-currently-playing user-modify-playback-state playlist-read-private playlist-read-collaborative user-read-recently-played"
    private static let defaultClientID = "6a6e71c369494e2fa70dd5c1608dd435"
    private static let clientIDKey = "spotify.clientID"
    private static let refreshTokenKey = "spotify.refreshToken"
    // Keys used to persist the in-flight PKCE round-trip so it survives an app relaunch.
    private static let pendingVerifierKey = "spotify.pendingVerifier"
    private static let pendingStateKey = "spotify.pendingState"

    // Pre-filled with our Spotify app Client ID (public, not a secret). A value saved in
    // Settings overrides it.
    @Published var clientID: String
    @Published var isConnected: Bool
    @Published var lastError: String = ""

    private let defaults: UserDefaults
    private let secretStore: SecretStore
    private var accessToken: String?
    private var expiry: Date = .distantPast
    private var verifier: String = ""
    private var state: String = ""                       // CSRF nonce binding the callback to this attempt
    private var listener: NWListener?

    // Coalesce overlapping token refreshes: while a refresh POST is in flight, queue
    // additional callers here and fan the single result out to all of them. Touched only
    // on the main thread (validToken/post completions are main-dispatched).
    private var isRefreshing = false
    private var refreshWaiters: [(String?) -> Void] = []

    init(defaults: UserDefaults = .standard, secretStore: SecretStore = KeychainStore.shared) {
        self.defaults = defaults
        self.secretStore = secretStore
        clientID = defaults.string(forKey: Self.clientIDKey) ?? Self.defaultClientID
        isConnected = secretStore.string(forKey: Self.refreshTokenKey) != nil
            || defaults.string(forKey: Self.refreshTokenKey) != nil
        super.init()
        migrateLegacyRefreshToken()
        isConnected = secretStore.string(forKey: Self.refreshTokenKey) != nil
    }

    private var refreshToken: String? {
        get { secretStore.string(forKey: Self.refreshTokenKey) }
        set {
            do {
                try secretStore.setString(newValue, forKey: Self.refreshTokenKey)
                DispatchQueue.main.async { self.isConnected = (newValue != nil) }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = "Couldn't update Spotify credentials: \(error.localizedDescription)"
                    self.isConnected = (self.refreshToken != nil)
                }
            }
        }
    }

    func saveClientID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        clientID = trimmed
        defaults.set(trimmed, forKey: Self.clientIDKey)
    }

    func disconnect() {
        refreshToken = nil; accessToken = nil; expiry = .distantPast
        // Tear down any in-flight refresh: tell pending waiters there's no token now.
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        isRefreshing = false
        waiters.forEach { $0(nil) }
    }

    private func migrateLegacyRefreshToken() {
        guard secretStore.string(forKey: Self.refreshTokenKey) == nil,
              let legacy = defaults.string(forKey: Self.refreshTokenKey),
              !legacy.isEmpty else {
            defaults.removeObject(forKey: Self.refreshTokenKey)
            return
        }
        do {
            try secretStore.setString(legacy, forKey: Self.refreshTokenKey)
            defaults.removeObject(forKey: Self.refreshTokenKey)
        } catch {
            lastError = "Couldn't migrate Spotify credentials: \(error.localizedDescription)"
        }
    }

    // MARK: Login

    func connect() {
        guard !clientID.isEmpty else { lastError = "Enter your Spotify Client ID first."; return }
        lastError = ""
        verifier = Self.randomVerifier()
        state = Self.randomVerifier()                    // same RNG/charset as the PKCE verifier
        let challenge = Self.challenge(for: verifier)

        // Persist the in-flight verifier+state so an OAuth round-trip survives a relaunch.
        defaults.set(verifier, forKey: Self.pendingVerifierKey)
        defaults.set(state, forKey: Self.pendingStateKey)

        startListener()

        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes),
            .init(name: "show_dialog", value: "true")   // force fresh consent so playlist access is actually granted
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    private func startListener() {
        listener?.cancel()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else {
            DispatchQueue.main.async { self.lastError = "Couldn't open local port \(Self.port). Is it in use?" }
            return
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                guard let self else { return }
                let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let code = Self.queryValue(in: req, key: "code")
                let denied = Self.queryValue(in: req, key: "error")
                let returnedState = Self.queryValue(in: req, key: "state")
                // CSRF: the callback must carry the exact state nonce we sent. A relaunch may have
                // dropped the in-memory copy, so fall back to the persisted value before validating.
                let expectedState = self.state.isEmpty ? (self.defaults.string(forKey: Self.pendingStateKey) ?? "") : self.state
                let stateOK = !expectedState.isEmpty && returnedState == expectedState
                // Only treat a callback as accepted once both the code and the state check out.
                let accepted = code != nil && stateOK
                let body = """
                <html><body style="font-family:-apple-system,sans-serif;background:#0b0b0f;color:#e8eef6;text-align:center;padding-top:90px">
                <h2>\(accepted ? "Quake4Mac connected ✓" : "Login cancelled")</h2><p>You can close this tab and return to Quake4Mac.</p></body></html>
                """
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                if let code = code {
                    if stateOK {
                        self.state = ""                              // clear after a successful match
                        self.defaults.removeObject(forKey: Self.pendingStateKey)
                        self.exchange(code: code)
                    } else {
                        DispatchQueue.main.async { self.lastError = "Spotify: state mismatch (ignored callback)" }
                    }
                }
                else if let denied = denied { DispatchQueue.main.async { self.lastError = "Spotify: \(denied)" } }
                self.listener?.cancel(); self.listener = nil
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func exchange(code: String) {
        // Prefer the in-memory verifier; fall back to the persisted one if we were relaunched.
        let usedVerifier = verifier.isEmpty ? (defaults.string(forKey: Self.pendingVerifierKey) ?? "") : verifier
        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "client_id", value: clientID),
            .init(name: "code_verifier", value: usedVerifier)
        ]
        post(body: body.percentEncodedQuery ?? "") { [weak self] json in
            guard let self else { return }
            // The round-trip is done either way — drop the persisted PKCE material.
            self.defaults.removeObject(forKey: Self.pendingVerifierKey)
            self.defaults.removeObject(forKey: Self.pendingStateKey)
            if let rt = json?["refresh_token"] as? String { self.refreshToken = rt }
            else if json?["error"] != nil { self.lastError = "Token exchange failed: \(json?["error_description"] ?? json?["error"] ?? "")" }
            self.store(json)
        }
    }

    // MARK: Token access

    func validToken(_ completion: @escaping (String?) -> Void) {
        // Fast path: a still-valid cached token, no network needed.
        if let t = accessToken, expiry > Date().addingTimeInterval(30) { completion(t); return }
        guard let rt = refreshToken, !clientID.isEmpty else { completion(nil); return }

        // Coalesce concurrent refreshes. Spotify can rotate the refresh token, so two
        // overlapping POSTs could invalidate each other and log the user out. Queue this
        // caller and let the single in-flight refresh fan its result out to everyone.
        // All access to isRefreshing/refreshWaiters happens on the main thread (post()'s
        // completion is main-dispatched and the poll/commands call in on main too).
        refreshWaiters.append(completion)
        if isRefreshing { return }
        isRefreshing = true

        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: rt),
            .init(name: "client_id", value: clientID)
        ]
        post(body: body.percentEncodedQuery ?? "") { [weak self] json in
            guard let self else { return }
            if let rt = json?["refresh_token"] as? String { self.refreshToken = rt }
            self.store(json)
            // Hand the one result to every waiter, then reset for the next refresh.
            let result = self.accessToken
            let waiters = self.refreshWaiters
            self.refreshWaiters.removeAll()
            self.isRefreshing = false
            waiters.forEach { $0(result) }
        }
    }

    private func store(_ json: [String: Any]?) {
        guard let json, let tok = json["access_token"] as? String else { return }
        accessToken = tok
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
    }

    private func post(body: String, completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            DispatchQueue.main.async { completion(json) }
        }.resume()
    }

    // MARK: Helpers

    private static func queryValue(in request: String, key: String) -> String? {
        // First line looks like: GET /callback?code=...&state=... HTTP/1.1
        guard let line = request.split(separator: "\r\n").first,
              let pathPart = line.split(separator: " ").dropFirst().first,
              let q = pathPart.split(separator: "?").dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.first.map(String.init) == key {
                return kv.count > 1 ? String(kv[1]).removingPercentEncoding : ""
            }
        }
        return nil
    }

    private static func randomVerifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    private static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
