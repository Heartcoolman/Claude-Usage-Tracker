//
//  Profile.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

/// Represents a complete isolated profile with all credentials and settings
struct Profile: Codable, Identifiable, Equatable {
    // MARK: - Identity
    let id: UUID
    var name: String

    // MARK: - Credentials (stored directly in profile)
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?

    // MARK: - CLI Account Sync Metadata
    var hasCliAccount: Bool
    var cliAccountSyncedAt: Date?

    /// Serialized `oauthAccount` object from Claude Code's `.claude.json` config file.
    /// Captured at sync time and re-applied during profile switches so that
    /// Claude Code's `/status` command shows the correct account for the active
    /// profile. Stored as a raw JSON string to preserve unknown/future fields
    /// (emailAddress, accountUuid, organizationName, billingType, etc.).
    var oauthAccountJSON: String?

    // MARK: - Usage Data (Per-Profile)
    var claudeUsage: ClaudeUsage?
    var apiUsage: APIUsage?
    var reclaudeUsage: ReclaudeUsage?

    // MARK: - Reclaude.ai Credentials (Per-Profile)
    /// Current `rc_sid` session cookie value extracted from reclaude.ai. The
    /// password (if `reclaudeAutoRefresh == true`) lives in macOS Keychain
    /// under service `com.claudeusagetracker.reclaude-password`, account = profile UUID.
    var reclaudeSessionCookie: String?
    var reclaudeEmail: String?
    /// Optional in storage so legacy v3 profiles missing this key still decode.
    /// Read via the `reclaudeAutoRefreshEnabled` computed property.
    var reclaudeAutoRefresh: Bool?
    /// Full carpool-quota URL. Mirrors claude-hud's `display.reclaude.apiUrl`:
    /// the user pastes a complete URL (typically `…/carpool-quota?org_id=<id>`)
    /// and the fetcher uses it verbatim. `nil` means fall back to the bare
    /// default in `Constants.APIEndpoints.reclaudeCarpoolQuota`.
    var reclaudeApiUrl: String?
    /// When set in the future, suppress re-login attempts until then (5-minute
    /// cooldown after a failed `/api/auth/login`, mirrors claude-hud).
    var reclaudePasswordCooldownUntil: Date?

    /// Normalized read for `reclaudeAutoRefresh` (defaults to false).
    var reclaudeAutoRefreshEnabled: Bool {
        reclaudeAutoRefresh ?? false
    }

    // MARK: - Appearance Settings (Per-Profile)
    var iconConfig: MenuBarIconConfiguration

    // MARK: - Behavior Settings (Per-Profile)
    var refreshInterval: TimeInterval
    var autoStartSessionEnabled: Bool
    var checkOverageLimitEnabled: Bool

    // MARK: - Notification Settings (Per-Profile)
    var notificationSettings: NotificationSettings

    // MARK: - Display Configuration
    var isSelectedForDisplay: Bool  // For multi-profile menu bar mode

    // MARK: - Metadata
    var createdAt: Date
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        claudeSessionKey: String? = nil,
        organizationId: String? = nil,
        apiSessionKey: String? = nil,
        apiOrganizationId: String? = nil,
        apiSessionKeyExpiry: Date? = nil,
        cliCredentialsJSON: String? = nil,
        hasCliAccount: Bool = false,
        cliAccountSyncedAt: Date? = nil,
        oauthAccountJSON: String? = nil,
        claudeUsage: ClaudeUsage? = nil,
        apiUsage: APIUsage? = nil,
        reclaudeUsage: ReclaudeUsage? = nil,
        reclaudeSessionCookie: String? = nil,
        reclaudeEmail: String? = nil,
        reclaudeAutoRefresh: Bool? = nil,
        reclaudeApiUrl: String? = nil,
        reclaudePasswordCooldownUntil: Date? = nil,
        iconConfig: MenuBarIconConfiguration = .default,
        refreshInterval: TimeInterval = 30.0,
        autoStartSessionEnabled: Bool = false,
        checkOverageLimitEnabled: Bool = true,
        notificationSettings: NotificationSettings = NotificationSettings(),
        isSelectedForDisplay: Bool = true,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.claudeSessionKey = claudeSessionKey
        self.organizationId = organizationId
        self.apiSessionKey = apiSessionKey
        self.apiOrganizationId = apiOrganizationId
        self.apiSessionKeyExpiry = apiSessionKeyExpiry
        self.cliCredentialsJSON = cliCredentialsJSON
        self.hasCliAccount = hasCliAccount
        self.cliAccountSyncedAt = cliAccountSyncedAt
        self.oauthAccountJSON = oauthAccountJSON
        self.claudeUsage = claudeUsage
        self.apiUsage = apiUsage
        self.reclaudeUsage = reclaudeUsage
        self.reclaudeSessionCookie = reclaudeSessionCookie
        self.reclaudeEmail = reclaudeEmail
        self.reclaudeAutoRefresh = reclaudeAutoRefresh
        self.reclaudeApiUrl = reclaudeApiUrl
        self.reclaudePasswordCooldownUntil = reclaudePasswordCooldownUntil
        self.iconConfig = iconConfig
        self.refreshInterval = refreshInterval
        self.autoStartSessionEnabled = autoStartSessionEnabled
        self.checkOverageLimitEnabled = checkOverageLimitEnabled
        self.notificationSettings = notificationSettings
        self.isSelectedForDisplay = isSelectedForDisplay
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    // MARK: - Computed Properties
    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    /// True if profile has credentials that can fetch usage data (Claude.ai, CLI OAuth, API Console, or reclaude carpool)
    /// Note: System keychain fallback is handled in ClaudeAPIService.getAuthentication() during actual API calls.
    /// `hasReclaude` is included so reclaude-only profiles (carpool proxy account, no Anthropic creds) still render
    /// the menu bar icon — the renderer / popover repurpose the session metric onto carpool USD data in that case.
    var hasUsageCredentials: Bool {
        hasClaudeAI || hasAPIConsole || hasValidCLIOAuth || hasReclaude
    }

    /// True if profile has CLI OAuth credentials that are not expired
    var hasValidCLIOAuth: Bool {
        guard let cliJSON = cliCredentialsJSON else { return false }
        return !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON)
    }

    var hasAnyCredentials: Bool {
        hasClaudeAI || hasAPIConsole || cliCredentialsJSON != nil || hasReclaude
    }

    /// True when a reclaude.ai session cookie is configured for this profile.
    var hasReclaude: Bool {
        !(reclaudeSessionCookie?.isEmpty ?? true)
    }
}

// MARK: - ProfileCredentials (for compatibility)
/// Simple struct for passing credentials around
struct ProfileCredentials {
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?

    // Reclaude.ai
    var reclaudeSessionCookie: String?
    var reclaudeEmail: String?
    var reclaudeAutoRefresh: Bool = false
    /// Full carpool-quota URL override (e.g. `…?org_id=2323`). `nil` → default.
    var reclaudeApiUrl: String?

    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    var hasCLI: Bool {
        cliCredentialsJSON != nil
    }

    var hasReclaude: Bool {
        !(reclaudeSessionCookie?.isEmpty ?? true)
    }
}
