//
//  ReclaudeUsage.swift
//  Claude Usage
//
//  Per-profile snapshot of reclaude.ai carpool 5-hour USD quota.
//  Mirrors the upstream `claude-hud` `ProxyUsageData` contract; lives
//  alongside `ClaudeUsage` / `APIUsage` in the profile.
//

import Foundation

/// reclaude.ai carpool quota for the current rolling 5-hour window.
/// The upstream `quota_usd` is a USD cap (independent of Anthropic's percentage),
/// `used_usd` is amount spent so far, `resets_at_ms` is the window end (UNIX ms).
struct ReclaudeUsage: Codable, Equatable {
    var usedUsd: Double
    var quotaUsd: Double
    var resetAt: Date?
    var fetchedAt: Date
    var enabled: Bool
    var status: String

    /// Length of the carpool quota window (matches claude-hud).
    static let windowDuration: TimeInterval = 5 * 60 * 60

    /// USD spend as 0..100 integer percentage. Zero when `quotaUsd <= 0`.
    var usdPercentage: Int {
        guard quotaUsd > 0 else { return 0 }
        let raw = (usedUsd / quotaUsd) * 100
        return max(0, min(100, Int(raw.rounded())))
    }

    /// Fraction (0.0–1.0) of the 5h window elapsed.
    /// Window start = resetAt − 5h; "now" clamped to that range.
    var timeElapsedFraction: Double {
        guard let reset = resetAt else { return 0 }
        let start = reset.addingTimeInterval(-Self.windowDuration)
        let now = Date()
        let frac = now.timeIntervalSince(start) / Self.windowDuration
        return max(0, min(1, frac))
    }

    /// Upstream considers the carpool active iff `enabled` and `status == "active"`.
    var isActive: Bool {
        enabled && status.lowercased() == "active"
    }

    /// Empty placeholder used while data has never been fetched.
    static var empty: ReclaudeUsage {
        ReclaudeUsage(
            usedUsd: 0,
            quotaUsd: 0,
            resetAt: nil,
            fetchedAt: Date(),
            enabled: false,
            status: ""
        )
    }
}
