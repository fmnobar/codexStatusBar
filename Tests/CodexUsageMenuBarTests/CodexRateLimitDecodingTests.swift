import XCTest
@testable import CodexUsageMenuBar

final class CodexRateLimitDecodingTests: XCTestCase {
    func testDecodesPayloadAndPrefersMainCodexBucket() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": null,
                "primary": {
                  "usedPercent": 6,
                  "windowDurationMins": 300,
                  "resetsAt": 1775622013
                },
                "secondary": {
                  "usedPercent": 2,
                  "windowDurationMins": 10080,
                  "resetsAt": 1776208813
                },
                "planType": "pro"
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "limitName": null,
                  "primary": {
                    "usedPercent": 6,
                    "windowDurationMins": 300,
                    "resetsAt": 1775622013
                  },
                  "secondary": {
                    "usedPercent": 2,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776208813
                  },
                  "planType": "pro"
                },
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox",
                  "limitName": "GPT-5.3-Codex-Spark",
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 0,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776211494
                  },
                  "planType": "pro"
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
        let snapshot = response.selectedSnapshot()

        XCTAssertEqual(snapshot.primary?.usedPercent, 6)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 2)
        XCTAssertEqual(snapshot.secondary?.windowDurationMinutes, 10080)
    }
}
