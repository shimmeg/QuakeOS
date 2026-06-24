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
    private var listener: NWListener?

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
        let challenge = Self.challenge(for: verifier)

        startListener()

        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
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
                let body = """
                <html><body style="font-family:-apple-system,sans-serif;background:#0b0b0f;color:#e8eef6;text-align:center;padding-top:90px">
                <h2>\(code != nil ? "Quake4Mac connected ✓" : "Login cancelled")</h2><p>You can close this tab and return to Quake4Mac.</p></body></html>
                """
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                if let code = code { self.exchange(code: code) }
                else if let denied = denied { DispatchQueue.main.async { self.lastError = "Spotify: \(denied)" } }
                self.listener?.cancel(); self.listener = nil
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func exchange(code: String) {
        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "client_id", value: clientID),
            .init(name: "code_verifier", value: verifier)
        ]
        post(body: body.percentEncodedQuery ?? "") { [weak self] json in
            guard let self else { return }
            if let rt = json?["refresh_token"] as? String { self.refreshToken = rt }
            else if json?["error"] != nil { self.lastError = "Token exchange failed: \(json?["error_description"] ?? json?["error"] ?? "")" }
            self.store(json)
        }
    }

    // MARK: Token access

    func validToken(_ completion: @escaping (String?) -> Void) {
        if let t = accessToken, expiry > Date().addingTimeInterval(30) { completion(t); return }
        guard let rt = refreshToken, !clientID.isEmpty else { completion(nil); return }
        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: rt),
            .init(name: "client_id", value: clientID)
        ]
        post(body: body.percentEncodedQuery ?? "") { [weak self] json in
            guard let self else { completion(nil); return }
            if let rt = json?["refresh_token"] as? String { self.refreshToken = rt }
            self.store(json)
            completion(self.accessToken)
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
