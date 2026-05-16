import XCTest

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

    func testBuildsUsageSnapshotWithAggregateAndModelBuckets() throws {
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
                "codex_gpt55": {
                  "limitId": "codex_gpt55",
                  "limitName": "GPT-5.5",
                  "primary": {
                    "usedPercent": 9,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 4,
                    "windowDurationMins": 10080,
                    "resetsAt": 1776211494
                  },
                  "planType": "pro"
                },
                "codex_gpt54": {
                  "limitId": "codex_gpt54",
                  "limitName": "GPT-5.4",
                  "primary": {
                    "usedPercent": 3,
                    "windowDurationMins": 300,
                    "resetsAt": 1775624694
                  },
                  "secondary": {
                    "usedPercent": 1,
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
        let usageSnapshot = response.usageSnapshot()

        XCTAssertEqual(usageSnapshot.displaySnapshot.primary?.usedPercent, 6)
        XCTAssertEqual(usageSnapshot.buckets.map(\.id), ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertEqual(usageSnapshot.buckets.map(\.name), ["All models", "GPT-5.4", "GPT-5.5"])
        XCTAssertEqual(usageSnapshot.buckets.map(\.kind), [.aggregate, .model, .model])
        XCTAssertEqual(usageSnapshot.buckets.first { $0.id == "codex_gpt55" }?.snapshot.secondary?.usedPercent, 4)
    }

    func testDecodesWhamUsagePayloadIntoSnapshot() throws {
        let data = Data(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 25,
                  "limit_window_seconds": 18000,
                  "reset_at": 1775622013
                },
                "secondary_window": {
                  "used_percent": 8,
                  "limit_window_seconds": 604800,
                  "reset_at": 1776208813
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(WhamUsageResponse.self, from: data)
        let snapshot = try XCTUnwrap(response.selectedSnapshot())

        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 8)
        XCTAssertEqual(snapshot.secondary?.windowDurationMinutes, 10080)
    }

    func testDecodesThreadTokenUsageNotification() throws {
        let data = Data(
            """
            {
              "threadId": "thread-123",
              "turnId": "turn-456",
              "tokenUsage": {
                "last": {
                  "inputTokens": 1200,
                  "cachedInputTokens": 900,
                  "outputTokens": 300,
                  "reasoningOutputTokens": 40,
                  "totalTokens": 1500
                },
                "total": {
                  "inputTokens": 10000,
                  "cachedInputTokens": 7000,
                  "outputTokens": 2000,
                  "reasoningOutputTokens": 400,
                  "totalTokens": 12000
                },
                "modelContextWindow": 258400
              }
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(ThreadTokenUsageUpdatedNotificationPayload.self, from: data)
        let notification = payload.toDomainNotification()

        XCTAssertEqual(notification.threadID, "thread-123")
        XCTAssertEqual(notification.turnID, "turn-456")
        XCTAssertNil(notification.model)
        XCTAssertEqual(notification.tokenUsage.modelContextWindow, 258400)
        XCTAssertEqual(notification.tokenUsage.last.cachedInputTokens, 900)
        XCTAssertEqual(notification.tokenUsage.last.reasoningOutputTokens, 40)
        XCTAssertEqual(notification.tokenUsage.total.inputTokens, 10000)
        XCTAssertEqual(notification.tokenUsage.total.totalTokens, 12000)
    }
}
