import Foundation
import AuthenticationServices
import CryptoKit
import os

// MARK: - OAuth Token Model

/// Stores OAuth 2.0 tokens and expiry metadata for Google sign-in.
private struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let email: String?
}

// MARK: - GoogleAuthError

enum GoogleAuthError: LocalizedError {
    case authenticationFailed(String)
    case tokenRefreshFailed(String)
    case noRefreshToken
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .tokenRefreshFailed(let message):
            return "Token refresh failed: \(message)"
        case .noRefreshToken:
            return "No refresh token available. Please sign in again."
        case .invalidResponse:
            return "Received an invalid response from Google."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - GoogleAuthManager

/// Manages Google OAuth 2.0 authentication using PKCE + `ASWebAuthenticationSession`.
///
/// No client secret is required — PKCE (RFC 7636) replaces it for native apps.
/// Tokens are persisted in the macOS Keychain via `KeychainHelper`.
/// Dedicated NSObject subclass that provides the macOS window anchor for
/// `ASWebAuthenticationSession`. Kept separate from `GoogleAuthManager` so
/// the `@Observable` macro doesn't interfere with NSObject/KVO machinery.
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
            ?? NSWindow()
    }
}

@Observable
@MainActor
final class GoogleAuthManager {

    // MARK: - OAuth Configuration

    /// Built-in client ID — used when the user hasn't supplied their own.
    /// Users can override this in Settings > Google Calendar.
    /// This is a native PKCE OAuth client ID — safe to embed (no client secret used).
    private static let builtInClientId = "168814758458-p49njtppjg4rpbjtqegu0f6b2hs3ilfu.apps.googleusercontent.com"

    private enum OAuthConfig {
        static let authURL  = "https://accounts.google.com/o/oauth2/v2/auth"
        static let tokenURL = "https://oauth2.googleapis.com/token"
        static let scopes   = "https://www.googleapis.com/auth/calendar.readonly email profile"
    }

    /// Resolves the active client ID: user-supplied (Keychain) → built-in fallback.
    static func resolvedClientId() -> String {
        let stored = (try? KeychainHelper.loadString(forKey: KeychainHelper.Key.googleOAuthClientId))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? builtInClientId : stored
    }

    /// True if the user has entered their own client ID (not using the built-in one).
    static func hasCustomClientId() -> Bool {
        guard let stored = try? KeychainHelper.loadString(forKey: KeychainHelper.Key.googleOAuthClientId),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// Derives the redirect URI from a client ID (reversed + ":/" suffix).
    private static func redirectURI(for clientId: String) -> String {
        // Reverse the domain parts: "12345.apps.googleusercontent.com" → "com.googleusercontent.apps.12345"
        let parts = clientId.components(separatedBy: ".").reversed()
        return parts.joined(separator: ".") + ":/"
    }

    // MARK: - Keychain Keys

    private enum Keys {
        static let oauthTokens = "google-oauth-tokens"
    }

    // MARK: - Public State

    private(set) var isSignedIn = false
    private(set) var userEmail: String?

    // MARK: - Private

    private let session: URLSession
    private var cachedTokens: OAuthTokens?
    /// Held strongly so the OS doesn't cancel the in-flight session.
    private var authSession: ASWebAuthenticationSession?
    /// Must be retained for the lifetime of the auth session.
    private var authPresenter: WebAuthPresenter?

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
        restoreSession()
    }

    // MARK: - Public API

    /// Initiates the Google OAuth 2.0 sign-in flow via `ASWebAuthenticationSession`.
    ///
    /// Opens the system browser, the user signs in, Google redirects back via
    /// the custom URL scheme, and the auth code is exchanged for tokens using PKCE.
    func signIn() async throws {
        Logger.calendar.info("Starting Google sign-in flow (PKCE)")

        let (verifier, challenge) = pkceChallenge()
        let authorizationCode = try await requestAuthorizationCode(challenge: challenge)
        let tokens = try await exchangeCodeForTokens(authorizationCode, verifier: verifier)

        try persistTokens(tokens)
        cachedTokens = tokens
        isSignedIn = true
        userEmail = tokens.email

        Logger.calendar.info("Google sign-in successful for \(tokens.email ?? "unknown")")
    }

    /// Signs the user out and removes all stored tokens.
    func signOut() {
        Logger.calendar.info("Signing out of Google")

        do {
            try KeychainHelper.delete(forKey: Keys.oauthTokens)
        } catch {
            Logger.calendar.warning("Error clearing tokens from Keychain: \(error.localizedDescription)")
        }

        cachedTokens = nil
        isSignedIn = false
        userEmail = nil
    }

    /// Returns a valid access token, refreshing it first if expired.
    func refreshTokenIfNeeded() async throws -> String {
        guard let tokens = cachedTokens else {
            throw GoogleAuthError.authenticationFailed("Not signed in")
        }

        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }

        Logger.calendar.info("Access token expired, refreshing...")
        return try await refreshAccessToken()
    }

    // MARK: - Session Restoration

    private func restoreSession() {
        do {
            if let tokens: OAuthTokens = try KeychainHelper.load(forKey: Keys.oauthTokens) {
                cachedTokens = tokens
                isSignedIn = true
                userEmail = tokens.email
                Logger.calendar.info("Restored Google session for \(tokens.email ?? "unknown")")
            }
        } catch {
            Logger.calendar.warning("Failed to restore Google session: \(error.localizedDescription)")
        }
    }

    // MARK: - PKCE

    /// Generates a PKCE code_verifier and its SHA-256 code_challenge (S256 method).
    private func pkceChallenge() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return (verifier, challenge)
    }

    // MARK: - Authorization Code Flow

    private func requestAuthorizationCode(challenge: String) async throws -> String {
        let clientId = GoogleAuthManager.resolvedClientId()
        let redirectURI = GoogleAuthManager.redirectURI(for: clientId)
        // Extract the scheme from the redirect URI (everything before ":/")
        let redirectScheme = redirectURI.components(separatedBy: ":").first ?? ""

        var components = URLComponents(string: OAuthConfig.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id",             value: clientId),
            URLQueryItem(name: "redirect_uri",          value: redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: OAuthConfig.scopes),
            URLQueryItem(name: "access_type",           value: "offline"),
            URLQueryItem(name: "prompt",                value: "consent"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url else {
            throw GoogleAuthError.authenticationFailed("Failed to build authorization URL")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let presenter = WebAuthPresenter()
            let webSession = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: redirectScheme
            ) { [weak self] callbackURL, error in
                self?.authSession = nil
                self?.authPresenter = nil

                if let error {
                    // User cancelled — don't surface as an error
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: GoogleAuthError.authenticationFailed("Sign-in cancelled"))
                        return
                    }
                    continuation.resume(throwing: GoogleAuthError.authenticationFailed(error.localizedDescription))
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: GoogleAuthError.authenticationFailed("No authorization code received"))
                    return
                }

                continuation.resume(returning: code)
            }

            webSession.presentationContextProvider = presenter
            webSession.prefersEphemeralWebBrowserSession = false
            self.authPresenter = presenter
            self.authSession = webSession

            // Ensure the app is frontmost and has a visible window for the auth sheet
            NSApp.activate(ignoringOtherApps: true)

            webSession.start()
        }
    }

    // MARK: - Token Exchange (PKCE — no client_secret needed)

    private func exchangeCodeForTokens(_ code: String, verifier: String) async throws -> OAuthTokens {
        let clientId = GoogleAuthManager.resolvedClientId()
        var request = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "code":          code,
            "client_id":     clientId,
            "redirect_uri":  GoogleAuthManager.redirectURI(for: clientId),
            "grant_type":    "authorization_code",
            "code_verifier": verifier,
        ]
        request.httpBody = urlEncode(params)

        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)
        return try parseTokenResponse(data)
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = cachedTokens?.refreshToken else {
            throw GoogleAuthError.noRefreshToken
        }

        var request = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "refresh_token": refreshToken,
            "client_id":     GoogleAuthManager.resolvedClientId(),
            "grant_type":    "refresh_token",
        ]
        request.httpBody = urlEncode(params)

        let newTokens: OAuthTokens = try await withRetry { [session] in
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw GoogleAuthError.networkError(error)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GoogleAuthError.invalidResponse
            }
            // Don't retry on 400/401/403
            if [400, 401, 403].contains(httpResponse.statusCode) {
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw GoogleAuthError.tokenRefreshFailed("HTTP \(httpResponse.statusCode): \(message)")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw GoogleAuthError.tokenRefreshFailed("HTTP \(httpResponse.statusCode): \(message)")
            }

            return try self.parseTokenResponse(data, existingRefreshToken: refreshToken)
        }

        try persistTokens(newTokens)
        cachedTokens = newTokens

        Logger.calendar.info("Access token refreshed successfully")
        return newTokens.accessToken
    }

    // MARK: - Helpers

    private func urlEncode(_ params: [String: String]) -> Data? {
        params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw GoogleAuthError.networkError(error)
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAuthError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleAuthError.tokenRefreshFailed("HTTP \(httpResponse.statusCode): \(message)")
        }
    }

    private func parseTokenResponse(_ data: Data, existingRefreshToken: String? = nil) throws -> OAuthTokens {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? TimeInterval else {
            throw GoogleAuthError.invalidResponse
        }

        let refreshToken = json["refresh_token"] as? String ?? existingRefreshToken
        let expiresAt = Date().addingTimeInterval(expiresIn)
        let email = extractEmail(from: json["id_token"] as? String)

        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            email: email
        )
    }

    /// Extracts the email claim from a JWT id_token without verification.
    /// Used only for display purposes.
    private func extractEmail(from idToken: String?) -> String? {
        guard let idToken,
              let payloadSegment = idToken.split(separator: ".").dropFirst().first else {
            return cachedTokens?.email
        }

        var base64 = String(payloadSegment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = payload["email"] as? String else {
            return cachedTokens?.email
        }
        return email
    }

    private func persistTokens(_ tokens: OAuthTokens) throws {
        try KeychainHelper.save(tokens, forKey: Keys.oauthTokens)
        Logger.calendar.debug("OAuth tokens persisted to Keychain")
    }

    /// Retry an async operation up to `maxAttempts` times with exponential backoff.
    private func withRetry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let delay = Double(attempt) * 1.0
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        // maxAttempts >= 1 at call sites, so lastError is always set here. Guard
        // defensively anyway — a retry path must never be a crash vector.
        throw lastError ?? GoogleAuthError.networkError(URLError(.unknown))
    }
}

