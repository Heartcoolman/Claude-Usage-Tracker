//
//  ReclaudeAPIServiceTests.swift
//  Claude UsageTests
//
//  Decoding + Set-Cookie parsing for ReclaudeAPIService. We don't exercise
//  the live HTTP path here; that's covered by manual verification per the
//  implementation plan.
//

import XCTest
@testable import Claude_Usage

final class ReclaudeAPIServiceTests: XCTestCase {

    // MARK: - Set-Cookie parsing via HTTPCookie

    func testExtractRcSidFromSetCookie_Basic() {
        let url = URL(string: "https://reclaude.ai/api/auth/login")!
        let headers = ["Set-Cookie": "rc_sid=abc123def; Path=/; HttpOnly; Secure"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        let cookie = ReclaudeAPIService.extractRcSid(from: response, url: url)
        XCTAssertEqual(cookie?.value, "abc123def")
    }

    func testExtractRcSidFromSetCookie_WithExpiresComma() {
        // The Expires segment contains a comma — naive regex on the raw header
        // would break here, but HTTPCookie.cookies(withResponseHeaderFields:for:)
        // parses cleanly. Keeps us robust to backend response variations.
        let url = URL(string: "https://reclaude.ai/api/auth/login")!
        let headers = [
            "Set-Cookie": "rc_sid=xyz789; Expires=Mon, 20 Jul 2026 12:34:56 GMT; Path=/"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        let cookie = ReclaudeAPIService.extractRcSid(from: response, url: url)
        XCTAssertEqual(cookie?.value, "xyz789")
    }

    func testExtractRcSidFromSetCookie_Missing_ReturnsNil() {
        let url = URL(string: "https://reclaude.ai/api/auth/login")!
        let headers = ["Set-Cookie": "other_cookie=val; Path=/"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        let cookie = ReclaudeAPIService.extractRcSid(from: response, url: url)
        XCTAssertNil(cookie)
    }

    // MARK: - Quota response decoding (string|number tolerance)

    func testQuotaResponseDecoding_NumericFields() throws {
        let json = """
        {
          "used_usd": 1.23,
          "quota_usd": 5.0,
          "resets_at_ms": 1700000000000,
          "enabled": true,
          "status": "active"
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ReclaudeAPIService.ReclaudeQuotaResponse.self, from: json)
        XCTAssertEqual(r.usedUsd, 1.23, accuracy: 0.001)
        XCTAssertEqual(r.quotaUsd, 5.0, accuracy: 0.001)
        XCTAssertEqual(r.resetsAtMs ?? 0, 1_700_000_000_000, accuracy: 0.001)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.status, "active")
    }

    func testQuotaResponseDecoding_StringFields() throws {
        let json = """
        { "used_usd": "1.23", "quota_usd": "5", "enabled": true, "status": "active" }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ReclaudeAPIService.ReclaudeQuotaResponse.self, from: json)
        XCTAssertEqual(r.usedUsd, 1.23, accuracy: 0.001)
        XCTAssertEqual(r.quotaUsd, 5.0, accuracy: 0.001)
    }

    func testQuotaResponseDecoding_IntFields() throws {
        let json = """
        { "used_usd": 1, "quota_usd": 5, "enabled": false, "status": "expired" }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ReclaudeAPIService.ReclaudeQuotaResponse.self, from: json)
        XCTAssertEqual(r.usedUsd, 1.0)
        XCTAssertEqual(r.quotaUsd, 5.0)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.status, "expired")
    }

    func testQuotaResponseDecoding_MissingOptionalFields_FallBack() throws {
        // resets_at_ms / enabled / status all absent — should not throw.
        let json = """
        { "used_usd": 0, "quota_usd": 10 }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ReclaudeAPIService.ReclaudeQuotaResponse.self, from: json)
        XCTAssertEqual(r.usedUsd, 0)
        XCTAssertEqual(r.quotaUsd, 10)
        XCTAssertNil(r.resetsAtMs)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.status, "")
    }

    // MARK: - toUsage conversion

    func testToUsage_ConvertsResetsAtMsToDate() {
        let resp = ReclaudeAPIService.ReclaudeQuotaResponse(
            usedUsd: 2, quotaUsd: 10,
            resetsAtMs: 1_700_000_000_000,
            enabled: true, status: "active"
        )
        let u = ReclaudeAPIService.toUsage(resp)
        XCTAssertNotNil(u.resetAt)
        XCTAssertEqual(u.resetAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
        XCTAssertTrue(u.isActive)
        XCTAssertEqual(u.usdPercentage, 20)
    }
}
