import Foundation
import AuthenticationServices
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
    case notConfigured
    case authenticationFailed(String)
    case tokenRefreshFailed(String)
    case noRefreshToken
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google OAuth client ID is not configured. Set it in Settings."
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

/// Manages Google OAuth 2.0 authentication using `ASWebAuthenticationSession`.
///
/// Tokens are persisted in the macOS Keychain via `KeychainHelper`. When the
/// Google Sign-In SDK is integrated later, the `signIn()` and token-refresh
/// logic can be swapped out while the rest of the app continues to use the
/// same `GoogleAuthManager` interface.
@Observable
@MainActor
final class GoogleAuthManager {

    // MARK: - Public State

    private(set) var isSignedIn = false
    private(set) var userEmail: String?

    // MARK: - Keychain Keys

    private enum Keys {
        static let accessToken = "google-oauth-access-token"
        static let refreshToken = "google-oauth-refresh-token"
        static let oauthTokens = "google-oauth-tokens"
    }

    // MARK: - OAuth Configuration

    /// Replace these with your real Google Cloud OAuth credentials.
    /// In production these would come from a plist or environment config.
    private enum OAuthConfig {
        static let clientId = "YOUR_CLIENT_ID.apps.googleusercontent.com"
        static let redirectURI = "com.meetingmanager:/oauth2callback"
        static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
        static let tokenURL = "https://oauth2.googleapis.com/token"
        static let scopes = "https://www.googleapis.com/auth/calendar.readonly email profile"
    }

    // MARK: - Private

    private let session: URLSession
    private var cachedTokens: OAuthTokens?

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
        restoreSession()
    }

    // MARK: - Public API

    /// Initiates the Google OAuth 2.0 sign-in flow via `ASWebAuthenticationSession`.
    ///
    /// Opens the system browser sheet, exchanges the authorization code for
    /// tokens, and persists them in the Keychain.
    func signIn() async throws {
        Logger.calendar.info("Starting Google sign-in flow")

        let authorizationCode = try await requestAuthorizationCode()
        let tokens = try await exchangeCodeForTokens(authorizationCode)

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
            try KeychainHelper.delete(forKey: Keys.accessToken)
            try KeychainHelper.delete(forKey: Keys.refreshToken)
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
            throw GoogleAuthError.notConfigured
        }

        // If the token is still valid (with a 60-second buffer), return it.
        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }

        Logger.calendar.info("Access token expired, refreshing...")
        return try await refreshAccessToken()
    }

    // MARK: - Session Restoration

    /// Restores a previous session from the Keychain on launch.
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

    // MARK: - Authorization Code Flow

    /// Opens `ASWebAuthenticationSession` to get an authorization code.
    private func requestAuthorizationCode() async throws -> String {
        var components = URLComponents(string: OAuthConfig.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.clientId),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: OAuthConfig.scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url else {
            throw GoogleAuthError.authenticationFailed("Failed to build authorization URL")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "com.meetingmanager"
            ) { callbackURL, error in
                if let error {
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

            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    // MARK: - Token Exchange

    /// Exchanges an authorization code for access and refresh tokens.
    private func exchangeCodeForTokens(_ code: String) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "code": code,
            "client_id": OAuthConfig.clientId,
            "redirect_uri": OAuthConfig.redirectURI,
            "grant_type": "authorization_code",
        ]
        let body = params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)

        return try parseTokenResponse(data)
    }

    // MARK: - Token Refresh

    /// Uses the stored refresh token to obtain a new access token.
    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = cachedTokens?.refreshToken else {
            throw GoogleAuthError.noRefreshToken
        }

        var request = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "refresh_token": refreshToken,
            "client_id": OAuthConfig.clientId,
            "grant_type": "refresh_token",
        ]
        let body = params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)

        let newTokens = try parseTokenResponse(data, existingRefreshToken: refreshToken)
        try persistTokens(newTokens)
        cachedTokens = newTokens

        Logger.calendar.info("Access token refreshed successfully")
        return newTokens.accessToken
    }

    // MARK: - Helpers

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

    /// Parses the JSON token response from Google's OAuth endpoint.
    private func parseTokenResponse(_ data: Data, existingRefreshToken: String? = nil) throws -> OAuthTokens {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? TimeInterval else {
            throw GoogleAuthError.invalidResponse
        }

        let refreshToken = json["refresh_token"] as? String ?? existingRefreshToken
        let expiresAt = Date().addingTimeInterval(expiresIn)

        // Decode the email from the id_token if present (JWT payload).
        let email = extractEmail(from: json["id_token"] as? String)

        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            email: email
        )
    }

    /// Extracts the email claim from a JWT id_token without verification.
    /// This is only used for display purposes; the server validates the token.
    private func extractEmail(from idToken: String?) -> String? {
        guard let idToken,
              let payloadSegment = idToken.split(separator: ".").dropFirst().first else {
            return cachedTokens?.email
        }

        // Base64URL decode the payload
        var base64 = String(payloadSegment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

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
}
