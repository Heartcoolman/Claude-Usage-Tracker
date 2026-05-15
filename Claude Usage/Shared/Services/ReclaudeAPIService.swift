//
//  ReclaudeAPIService.swift
//  Claude Usage
//
//  reclaude.ai carpool quota fetcher. Ports the upstream `claude-hud`
//  TypeScript implementation (proxy-usage-fetcher.ts + proxy-login.ts) to
//  native Swift. Two endpoints, no SDK:
//    • GET  /api/app/billing/carpool-quota   (auth: Cookie rc_sid)
//    • POST /api/auth/login                  (body: {email, password})
//
//  Auto-refresh flow (mirrors claude-hud Tier 1 → Tier 3, no Chrome reader):
//    1. Try the profile's cached `rc_sid`.
//    2. On 401: if auto-refresh is enabled and not in cooldown, pull the
//       password from macOS Keychain (per-profile), POST /api/auth/login,
//       grab the new `rc_sid` from Set-Cookie, persist it, retry.
//    3. On login failure: arm a 5-minute cooldown so we don't storm the
//       endpoint with bad credentials.
//

import Foundation

final class ReclaudeAPIService {
    static let shared = ReclaudeAPIService()

    private let session = URLSession.shared

    /// User-Agent advertised to reclaude.ai for transparency / rate-limiting.
    private let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "claude-usage-tracker/\(version)"
    }()

    /// Cooldown window after a failed `/api/auth/login` (mirrors claude-hud).
    private static let loginFailureCooldown: TimeInterval = 5 * 60

    private init() {}

    // MARK: - DTOs

    /// Carpool quota response. The upstream schema is loose: `used_usd` and
    /// `quota_usd` arrive as Double, Int, or numeric string depending on
    /// backend version, so we accept all three.
    struct ReclaudeQuotaResponse: Decodable, Equatable {
        let usedUsd: Double
        let quotaUsd: Double
        let resetsAtMs: Double?
        let enabled: Bool
        let status: String
        /// `"active"` for the carpool org, `"not_applicable"` for orgs without
        /// carpool entitlement. Reclaude.ai sets this independently of `status`.
        let state: String

        enum CodingKeys: String, CodingKey {
            case usedUsd = "used_usd"
            case quotaUsd = "quota_usd"
            case resetsAtMs = "resets_at_ms"
            case enabled
            case status
            case state
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedUsd = Self.decodeNumber(c, .usedUsd) ?? 0
            quotaUsd = Self.decodeNumber(c, .quotaUsd) ?? 0
            resetsAtMs = Self.decodeNumber(c, .resetsAtMs)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
            state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        }

        init(usedUsd: Double, quotaUsd: Double, resetsAtMs: Double?, enabled: Bool, status: String, state: String = "") {
            self.usedUsd = usedUsd
            self.quotaUsd = quotaUsd
            self.resetsAtMs = resetsAtMs
            self.enabled = enabled
            self.status = status
            self.state = state
        }

        /// Three-way numeric tolerance: Double → Int → numeric-string → nil.
        static func decodeNumber(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Double? {
            if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return d }
            if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return Double(i) }
            if let s = try? c.decodeIfPresent(String.self, forKey: k), let d = Double(s) { return d }
            return nil
        }
    }

    struct ReclaudeLoginResult: Equatable {
        let cookie: String
        let expiresAt: Date?
    }

    // MARK: - Public API

    /// GET the carpool-quota endpoint with the supplied `rc_sid` cookie.
    ///
    /// `urlOverride` mirrors claude-hud's `display.reclaude.apiUrl`: when the
    /// account's default organization isn't the carpool one (reclaude.ai picks
    /// the default org server-side when the URL has no `?org_id=…`), passing
    /// the full URL with an explicit `org_id` query routes the request to the
    /// correct org. `nil` falls back to the bare default URL.
    func fetchCarpoolQuota(cookie: String, urlOverride: String? = nil) async throws -> ReclaudeQuotaResponse {
        let endpoint = (urlOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Constants.APIEndpoints.reclaudeCarpoolQuota
        guard let url = URL(string: endpoint) else {
            throw AppError.reclaudeInvalidResponse()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("rc_sid=\(Self.normalizeCookieValue(cookie))", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let start = CFAbsoluteTimeGetCurrent()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - start
            NetworkLoggerService.shared.logRequest(
                url: url.absoluteString, method: "GET", requestBody: nil,
                responseData: nil, statusCode: nil, duration: duration, error: error
            )
            throw error
        }
        let duration = CFAbsoluteTimeGetCurrent() - start

        guard let http = response as? HTTPURLResponse else {
            NetworkLoggerService.shared.logRequest(
                url: url.absoluteString, method: "GET", requestBody: nil,
                responseData: data, statusCode: nil, duration: duration, error: nil
            )
            throw AppError.reclaudeInvalidResponse()
        }

        NetworkLoggerService.shared.logRequest(
            url: url.absoluteString, method: "GET", requestBody: nil,
            responseData: data, statusCode: http.statusCode, duration: duration, error: nil
        )

        switch http.statusCode {
        case 200:
            let decoded: ReclaudeQuotaResponse
            do {
                decoded = try JSONDecoder().decode(ReclaudeQuotaResponse.self, from: data)
            } catch {
                throw AppError.reclaudeInvalidResponse()
            }
            // Server returns 200 even for orgs without carpool entitlement, with
            // `enabled=false` / `state="not_applicable"`. Surface that as a
            // distinct error so the UI can guide the user to set `?org_id=…`
            // for the correct org instead of reporting "session expired".
            if decoded.enabled == false || decoded.state == "not_applicable" {
                throw AppError.reclaudeCarpoolNotEntitled()
            }
            return decoded
        case 401, 403:
            throw AppError.reclaudeUnauthorized()
        case 429:
            throw AppError.apiRateLimited()
        case 500...599:
            throw AppError.apiServerError(statusCode: http.statusCode)
        default:
            throw AppError.reclaudeGeneric(statusCode: http.statusCode)
        }
    }

    /// POST /api/auth/login with the supplied credentials. Extracts the
    /// `rc_sid` value from the response's Set-Cookie header using Apple's
    /// HTTPCookie parser (more robust than regex against `Expires=…` commas
    /// that `HTTPURLResponse.allHeaderFields` happily folds together).
    func login(email: String, password: String) async throws -> ReclaudeLoginResult {
        guard let url = URL(string: Constants.APIEndpoints.reclaudeLogin) else {
            throw AppError.reclaudeInvalidResponse()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])

        let start = CFAbsoluteTimeGetCurrent()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - start
            NetworkLoggerService.shared.logRequest(
                url: url.absoluteString, method: "POST", requestBody: redactedLoginBody(email: email),
                responseData: nil, statusCode: nil, duration: duration, error: error
            )
            throw error
        }
        let duration = CFAbsoluteTimeGetCurrent() - start

        guard let http = response as? HTTPURLResponse else {
            NetworkLoggerService.shared.logRequest(
                url: url.absoluteString, method: "POST", requestBody: redactedLoginBody(email: email),
                responseData: data, statusCode: nil, duration: duration, error: nil
            )
            throw AppError.reclaudeInvalidResponse()
        }

        NetworkLoggerService.shared.logRequest(
            url: url.absoluteString, method: "POST", requestBody: redactedLoginBody(email: email),
            responseData: nil, // never log auth response bodies — may contain tokens
            statusCode: http.statusCode, duration: duration, error: nil
        )

        guard (200...299).contains(http.statusCode) else {
            throw AppError.reclaudeLoginFailed(statusCode: http.statusCode)
        }

        guard let cookie = Self.extractRcSid(from: http, url: url) else {
            throw AppError.reclaudeNoCookieReturned()
        }
        return ReclaudeLoginResult(cookie: cookie.value, expiresAt: cookie.expiresDate)
    }

    /// Orchestrate the full Tier 1 → Tier 3 flow for the given profile and
    /// return a normalized `ReclaudeUsage`. Must be called on MainActor
    /// because it reads/writes ProfileManager.
    @MainActor
    func fetchWithAutoRefresh(profileId: UUID) async throws -> ReclaudeUsage {
        guard let profile = ProfileManager.shared.profiles.first(where: { $0.id == profileId }) else {
            throw AppError.reclaudeNoProfile()
        }
        guard let cookie = profile.reclaudeSessionCookie, !cookie.isEmpty else {
            throw AppError.reclaudeNotConfigured()
        }
        let urlOverride = profile.reclaudeApiUrl

        // Tier 1: try cached cookie.
        do {
            let resp = try await fetchCarpoolQuota(cookie: cookie, urlOverride: urlOverride)
            return Self.toUsage(resp)
        } catch let err as AppError where err.code == .reclaudeUnauthorized {
            // Tier 3: relogin via Keychain password (we never grew a Chrome reader).
            return try await reloginAndRetry(profileId: profileId, originalError: err, urlOverride: urlOverride)
        }
    }

    // MARK: - Private — Relogin

    @MainActor
    private func reloginAndRetry(profileId: UUID, originalError: AppError, urlOverride: String?) async throws -> ReclaudeUsage {
        let pm = ProfileManager.shared
        guard let profile = pm.profiles.first(where: { $0.id == profileId }) else {
            throw AppError.reclaudeNoProfile()
        }

        // Respect the cooldown set by a previous login failure.
        if let cooldownUntil = profile.reclaudePasswordCooldownUntil, cooldownUntil > Date() {
            throw AppError.reclaudeCooldownActive(until: cooldownUntil)
        }

        guard profile.reclaudeAutoRefreshEnabled,
              let email = profile.reclaudeEmail, !email.isEmpty,
              let password = try? KeychainService.shared.loadReclaudePassword(profileId: profileId),
              !password.isEmpty
        else {
            // No auto-refresh available — surface the original 401 to the caller.
            throw originalError
        }

        do {
            let login = try await login(email: email, password: password)

            // Persist new cookie + clear cooldown. ProfileManager.updateProfile
            // is the canonical write path and re-publishes `activeProfile`.
            if var p = pm.profiles.first(where: { $0.id == profileId }) {
                p.reclaudeSessionCookie = login.cookie
                p.reclaudePasswordCooldownUntil = nil
                pm.updateProfile(p)
            }

            let resp = try await fetchCarpoolQuota(cookie: login.cookie, urlOverride: urlOverride)
            return Self.toUsage(resp)
        } catch {
            // Login or follow-up fetch failed → arm cooldown to prevent storms.
            if var p = pm.profiles.first(where: { $0.id == profileId }) {
                p.reclaudePasswordCooldownUntil = Date().addingTimeInterval(Self.loginFailureCooldown)
                pm.updateProfile(p)
            }
            throw error
        }
    }

    // MARK: - Helpers

    /// Strip a leading `rc_sid=` (any whitespace, single trailing `;` tolerated)
    /// so users who paste the whole "name=value" pair from DevTools / a
    /// Set-Cookie header still get a valid Cookie request header. Without
    /// this we'd send `Cookie: rc_sid=rc_sid=<value>` and the server 401s.
    static func normalizeCookieValue(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Case-insensitive prefix strip.
        if s.lowercased().hasPrefix("rc_sid=") {
            s = String(s.dropFirst("rc_sid=".count))
        }
        if s.hasSuffix(";") { s = String(s.dropLast()) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Pull the `rc_sid` cookie from an HTTPURLResponse by handing the
    /// header fields to `HTTPCookie.cookies(withResponseHeaderFields:for:)`.
    /// More robust than regex against `Set-Cookie` values whose `Expires=`
    /// segment contains commas (which `allHeaderFields` joins naively).
    static func extractRcSid(from response: HTTPURLResponse, url: URL) -> HTTPCookie? {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let k = pair.key as? String, let v = pair.value as? String {
                acc[k] = v
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        return cookies.first(where: { $0.name == "rc_sid" })
    }

    /// Build a redacted request body for logging (never log passwords).
    private func redactedLoginBody(email: String) -> Data? {
        let redacted: [String: String] = ["email": email, "password": "<redacted>"]
        return try? JSONEncoder().encode(redacted)
    }

    static func toUsage(_ r: ReclaudeQuotaResponse) -> ReclaudeUsage {
        let resetAt: Date? = r.resetsAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ReclaudeUsage(
            usedUsd: r.usedUsd,
            quotaUsd: r.quotaUsd,
            resetAt: resetAt,
            fetchedAt: Date(),
            enabled: r.enabled,
            status: r.status
        )
    }
}
