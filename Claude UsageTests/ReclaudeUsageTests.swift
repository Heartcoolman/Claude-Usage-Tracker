//
//  ReclaudeUsageTests.swift
//  Claude UsageTests
//
//  Smoke tests for the ReclaudeUsage model: percent clamping, time-window
//  math, and the active/inactive flag.
//

import XCTest
@testable import Claude_Usage

final class ReclaudeUsageTests: XCTestCase {

    // MARK: - usdPercentage

    func testUsdPercentage_Zero_WhenQuotaIsZero() {
        let u = ReclaudeUsage(
            usedUsd: 12.0, quotaUsd: 0,
            resetAt: nil, fetchedAt: Date(),
            enabled: true, status: "active"
        )
        XCTAssertEqual(u.usdPercentage, 0)
    }

    func testUsdPercentage_Clamped_When_UsedExceedsQuota() {
        let u = ReclaudeUsage(
            usedUsd: 75.0, quotaUsd: 50.0,
            resetAt: nil, fetchedAt: Date(),
            enabled: true, status: "active"
        )
        XCTAssertEqual(u.usdPercentage, 100)
    }

    func testUsdPercentage_HalfQuota() {
        let u = ReclaudeUsage(
            usedUsd: 5.0, quotaUsd: 10.0,
            resetAt: nil, fetchedAt: Date(),
            enabled: true, status: "active"
        )
        XCTAssertEqual(u.usdPercentage, 50)
    }

    // MARK: - timeElapsedFraction

    func testTimeElapsedFraction_NoReset_IsZero() {
        let u = ReclaudeUsage(
            usedUsd: 1, quotaUsd: 5,
            resetAt: nil, fetchedAt: Date(),
            enabled: true, status: "active"
        )
        XCTAssertEqual(u.timeElapsedFraction, 0)
    }

    func testTimeElapsedFraction_MidWindow_IsAroundHalf() {
        // resetAt = now + 2.5h → window started 2.5h ago → 50% elapsed
        let reset = Date().addingTimeInterval(2.5 * 3600)
        let u = ReclaudeUsage(
            usedUsd: 1, quotaUsd: 5,
            resetAt: reset, fetchedAt: Date(),
            enabled: true, status: "active"
        )
        XCTAssertEqual(u.timeElapsedFraction, 0.5, accuracy: 0.01)
    }

    func testTimeElapsedFraction_ClampedTo_1_AfterReset() {
        // resetAt in the past → window already ended → fraction clamped to 1
        let reset = Date().addingTimeInterval(-3600)
        let u = ReclaudeUsage(
            usedUsd: 1, quotaUsd: 5,
            resetAt: reset, fetchedAt: Date(),
            enabled: true, status: "active"
        )
        XCTAssertEqual(u.timeElapsedFraction, 1.0, accuracy: 0.001)
    }

    // MARK: - isActive

    func testIsActive_RequiresEnabledAndActiveStatus() {
        XCTAssertTrue(make("active", enabled: true).isActive)
        XCTAssertFalse(make("active", enabled: false).isActive)
        XCTAssertFalse(make("expired", enabled: true).isActive)
        XCTAssertFalse(make("", enabled: true).isActive)
        // Case-insensitive
        XCTAssertTrue(make("ACTIVE", enabled: true).isActive)
    }

    private func make(_ status: String, enabled: Bool) -> ReclaudeUsage {
        ReclaudeUsage(
            usedUsd: 0, quotaUsd: 1,
            resetAt: nil, fetchedAt: Date(),
            enabled: enabled, status: status
        )
    }
}
