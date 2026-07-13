import XCTest
@testable import CodexUsageCore

final class CodexUsageDiagnosticsTests: XCTestCase {
    func testBuildsSanitizedDiagnosticsSnapshotWithComparableSummary() throws {
        let response = try decodeResponse(
            aggregatePrimaryReset: 1775622013,
            aggregateSecondaryReset: 1776208813,
            modelPrimaryReset: 1775622013,
            modelSecondaryReset: 1776208813,
            aggregatePrimaryUsed: 12,
            aggregateSecondaryUsed: 8,
            modelPrimaryUsed: 5,
            modelSecondaryUsed: 3
        )

        let generatedAt = ISO8601DateFormatter().date(from: "2026-04-14T20:00:00Z")!
        let diagnostics = response.diagnosticsSnapshot(generatedAt: generatedAt)

        XCTAssertEqual(diagnostics.schemaVersion, 1)
        XCTAssertEqual(diagnostics.generatedAt, generatedAt)
        XCTAssertEqual(diagnostics.classification, .comparableCandidate)
        XCTAssertEqual(diagnostics.buckets.map(\.id), ["codex", "codex_gpt54", "codex_gpt55"])
        XCTAssertEqual(diagnostics.buckets.map(\.name), ["All models", "GPT-5.4", "GPT-5.5"])
        XCTAssertEqual(diagnostics.buckets.first?.planType, "pro")
        XCTAssertEqual(diagnostics.summaries.map(\.classification), [.comparableCandidate, .comparableCandidate])
        XCTAssertEqual(diagnostics.summaries.first?.modelUsedPercentSum, 10)
    }

    func testClassifiesIndependentWhenResetsDiffer() throws {
        let response = try decodeResponse(
            aggregatePrimaryReset: 1775622013,
            aggregateSecondaryReset: 1776208813,
            modelPrimaryReset: 1775624694,
            modelSecondaryReset: 1776211494,
            aggregatePrimaryUsed: 12,
            aggregateSecondaryUsed: 8,
            modelPrimaryUsed: 5,
            modelSecondaryUsed: 3
        )

        let diagnostics = response.diagnosticsSnapshot(generatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(diagnostics.classification, .independentLikely)
        XCTAssertTrue(diagnostics.summaries.allSatisfy { !$0.resetsAligned })
        XCTAssertTrue(diagnostics.summaries.allSatisfy { $0.notes.contains { $0.contains("reset") } })
    }

    func testClassifiesIndependentWhenModelValuesExceedAggregate() throws {
        let response = try decodeResponse(
            aggregatePrimaryReset: 1775622013,
            aggregateSecondaryReset: 1776208813,
            modelPrimaryReset: 1775622013,
            modelSecondaryReset: 1776208813,
            aggregatePrimaryUsed: 6,
            aggregateSecondaryUsed: 4,
            modelPrimaryUsed: 7,
            modelSecondaryUsed: 5
        )

        let diagnostics = response.diagnosticsSnapshot(generatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(diagnostics.classification, .independentLikely)
        XCTAssertTrue(diagnostics.summaries.allSatisfy { !$0.modelValuesWithinAggregate })
    }

    func testClassifiesInconclusiveWithoutModelBuckets() throws {
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
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
        let diagnostics = response.diagnosticsSnapshot(generatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(diagnostics.classification, .inconclusive)
        XCTAssertEqual(diagnostics.buckets.count, 1)
        XCTAssertTrue(diagnostics.summaries.allSatisfy { $0.modelBucketCount == 0 })
    }

    func testDiagnosticsClassifiesReversedSlotsByDuration() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": { "usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1776208813 },
                "secondary": { "usedPercent": 20, "windowDurationMins": 300, "resetsAt": 1775622013 },
                "planType": "pro"
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "primary": { "usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1776208813 },
                  "secondary": { "usedPercent": 20, "windowDurationMins": 300, "resetsAt": 1775622013 },
                  "planType": "pro"
                },
                "codex_gpt55": {
                  "limitId": "codex_gpt55",
                  "limitName": "GPT-5.5",
                  "primary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1776208813 },
                  "secondary": { "usedPercent": 5, "windowDurationMins": 300, "resetsAt": 1775622013 },
                  "planType": "pro"
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
        let diagnostics = response.diagnosticsSnapshot(generatedAt: Date(timeIntervalSince1970: 0))
        let fiveHour = try XCTUnwrap(diagnostics.summaries.first { $0.window == .fiveHour })
        let sevenDay = try XCTUnwrap(diagnostics.summaries.first { $0.window == .sevenDay })

        XCTAssertEqual(fiveHour.aggregateUsedPercent, 20)
        XCTAssertEqual(fiveHour.modelUsedPercentSum, 5)
        XCTAssertEqual(sevenDay.aggregateUsedPercent, 40)
        XCTAssertEqual(sevenDay.modelUsedPercentSum, 10)
        XCTAssertEqual(diagnostics.summaries.map(\.classification), [.comparableCandidate, .comparableCandidate])
    }

    func testDiagnosticsExporterUsesSanitizedJSON() throws {
        let response = try decodeResponse(
            aggregatePrimaryReset: 1775622013,
            aggregateSecondaryReset: 1776208813,
            modelPrimaryReset: 1775622013,
            modelSecondaryReset: 1776208813,
            aggregatePrimaryUsed: 12,
            aggregateSecondaryUsed: 8,
            modelPrimaryUsed: 5,
            modelSecondaryUsed: 3
        )
        let diagnostics = response.diagnosticsSnapshot(generatedAt: Date(timeIntervalSince1970: 0))

        let json = String(decoding: try CodexUsageDiagnosticsExporter.jsonData(for: diagnostics), as: UTF8.self)

        XCTAssertTrue(json.contains("\"classification\" : \"comparableCandidate\""))
        XCTAssertTrue(json.contains("\"bucket_kind\"") == false)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("token"))
    }

    func testReviewClassifiesComparableAcrossThreeAlignedCaptures() {
        let review = CodexUsageDiagnosticsReviewer.review([
            reviewSnapshot(
                generatedAt: "2026-04-14T20:00:00Z",
                primaryAggregate: 10,
                primaryModelSum: 6,
                secondaryAggregate: 20,
                secondaryModelSum: 15
            ),
            reviewSnapshot(
                generatedAt: "2026-04-14T21:00:00Z",
                primaryAggregate: 13,
                primaryModelSum: 9,
                secondaryAggregate: 24,
                secondaryModelSum: 19
            ),
            reviewSnapshot(
                generatedAt: "2026-04-14T22:00:00Z",
                primaryAggregate: 16,
                primaryModelSum: 12,
                secondaryAggregate: 27,
                secondaryModelSum: 22
            ),
        ])

        XCTAssertEqual(review.captureCount, 3)
        XCTAssertEqual(review.classification, .comparableCandidate)
        XCTAssertEqual(review.summaries.map(\.classification), [.comparableCandidate, .comparableCandidate])
    }

    func testReviewClassifiesIndependentWhenDurationDiffers() {
        let review = CodexUsageDiagnosticsReviewer.review([
            reviewSnapshot(
                generatedAt: "2026-04-14T20:00:00Z",
                primaryAggregate: 10,
                primaryModelSum: 6,
                secondaryAggregate: 20,
                secondaryModelSum: 15
            ),
            reviewSnapshot(
                generatedAt: "2026-04-14T21:00:00Z",
                primaryAggregate: 13,
                primaryModelSum: 9,
                secondaryAggregate: 24,
                secondaryModelSum: 19,
                durationsAligned: false
            ),
            reviewSnapshot(
                generatedAt: "2026-04-14T22:00:00Z",
                primaryAggregate: 16,
                primaryModelSum: 12,
                secondaryAggregate: 27,
                secondaryModelSum: 22
            ),
        ])

        XCTAssertEqual(review.classification, .independentLikely)
        XCTAssertTrue(review.notes.contains { $0.contains("durations") })
    }

    func testReviewClassifiesIndependentWhenModelMovementConflictsWithAggregate() {
        let review = CodexUsageDiagnosticsReviewer.review([
            reviewSnapshot(
                generatedAt: "2026-04-14T20:00:00Z",
                primaryAggregate: 10,
                primaryModelSum: 6,
                secondaryAggregate: 20,
                secondaryModelSum: 15
            ),
            reviewSnapshot(
                generatedAt: "2026-04-14T21:00:00Z",
                primaryAggregate: 13,
                primaryModelSum: 6,
                secondaryAggregate: 24,
                secondaryModelSum: 19
            ),
            reviewSnapshot(
                generatedAt: "2026-04-14T22:00:00Z",
                primaryAggregate: 16,
                primaryModelSum: 9,
                secondaryAggregate: 27,
                secondaryModelSum: 22
            ),
        ])

        XCTAssertEqual(review.classification, .independentLikely)
        XCTAssertTrue(review.notes.contains { $0.contains("model deltas") })
    }

    func testReviewClassifiesInconclusiveWithTooFewCaptures() {
        let review = CodexUsageDiagnosticsReviewer.review([
            reviewSnapshot(
                generatedAt: "2026-04-14T20:00:00Z",
                primaryAggregate: 10,
                primaryModelSum: 6,
                secondaryAggregate: 20,
                secondaryModelSum: 15
            ),
            reviewSnapshot(
                generatedAt: "2026-04-14T21:00:00Z",
                primaryAggregate: 13,
                primaryModelSum: 9,
                secondaryAggregate: 24,
                secondaryModelSum: 19
            ),
        ])

        XCTAssertEqual(review.captureCount, 2)
        XCTAssertEqual(review.classification, .inconclusive)
        XCTAssertTrue(review.summaries.allSatisfy { $0.classification == .inconclusive })
    }

    private func decodeResponse(
        aggregatePrimaryReset: Int64,
        aggregateSecondaryReset: Int64,
        modelPrimaryReset: Int64,
        modelSecondaryReset: Int64,
        aggregatePrimaryUsed: Int,
        aggregateSecondaryUsed: Int,
        modelPrimaryUsed: Int,
        modelSecondaryUsed: Int
    ) throws -> AccountRateLimitsResponse {
        let modelPrimaryUsed2 = max(0, aggregatePrimaryUsed - modelPrimaryUsed - 2)
        let modelSecondaryUsed2 = max(0, aggregateSecondaryUsed - modelSecondaryUsed - 1)
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": null,
                "primary": {
                  "usedPercent": \(aggregatePrimaryUsed),
                  "windowDurationMins": 300,
                  "resetsAt": \(aggregatePrimaryReset)
                },
                "secondary": {
                  "usedPercent": \(aggregateSecondaryUsed),
                  "windowDurationMins": 10080,
                  "resetsAt": \(aggregateSecondaryReset)
                },
                "planType": "pro"
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "limitName": null,
                  "primary": {
                    "usedPercent": \(aggregatePrimaryUsed),
                    "windowDurationMins": 300,
                    "resetsAt": \(aggregatePrimaryReset)
                  },
                  "secondary": {
                    "usedPercent": \(aggregateSecondaryUsed),
                    "windowDurationMins": 10080,
                    "resetsAt": \(aggregateSecondaryReset)
                  },
                  "planType": "pro"
                },
                "codex_gpt55": {
                  "limitId": "codex_gpt55",
                  "limitName": "GPT-5.5",
                  "primary": {
                    "usedPercent": \(modelPrimaryUsed),
                    "windowDurationMins": 300,
                    "resetsAt": \(modelPrimaryReset)
                  },
                  "secondary": {
                    "usedPercent": \(modelSecondaryUsed),
                    "windowDurationMins": 10080,
                    "resetsAt": \(modelSecondaryReset)
                  },
                  "planType": "pro"
                },
                "codex_gpt54": {
                  "limitId": "codex_gpt54",
                  "limitName": "GPT-5.4",
                  "primary": {
                    "usedPercent": \(modelPrimaryUsed2),
                    "windowDurationMins": 300,
                    "resetsAt": \(modelPrimaryReset)
                  },
                  "secondary": {
                    "usedPercent": \(modelSecondaryUsed2),
                    "windowDurationMins": 10080,
                    "resetsAt": \(modelSecondaryReset)
                  },
                  "planType": "pro"
                }
              }
            }
            """.utf8
        )

        return try JSONDecoder().decode(AccountRateLimitsResponse.self, from: data)
    }

    private func reviewSnapshot(
        generatedAt: String,
        primaryAggregate: Int,
        primaryModelSum: Int,
        secondaryAggregate: Int,
        secondaryModelSum: Int,
        durationsAligned: Bool = true,
        resetsAligned: Bool = true,
        modelValuesWithinAggregate: Bool = true
    ) -> CodexUsageDiagnosticsSnapshot {
        CodexUsageDiagnosticsSnapshot(
            generatedAt: ISO8601DateFormatter().date(from: generatedAt)!,
            buckets: [],
            summaries: [
                reviewSummary(
                    window: .fiveHour,
                    aggregate: primaryAggregate,
                    modelSum: primaryModelSum,
                    durationsAligned: durationsAligned,
                    resetsAligned: resetsAligned,
                    modelValuesWithinAggregate: modelValuesWithinAggregate
                ),
                reviewSummary(
                    window: .sevenDay,
                    aggregate: secondaryAggregate,
                    modelSum: secondaryModelSum,
                    durationsAligned: durationsAligned,
                    resetsAligned: resetsAligned,
                    modelValuesWithinAggregate: modelValuesWithinAggregate
                ),
            ]
        )
    }

    private func reviewSummary(
        window: UsageLimitWindow,
        aggregate: Int,
        modelSum: Int,
        durationsAligned: Bool,
        resetsAligned: Bool,
        modelValuesWithinAggregate: Bool
    ) -> CodexUsageDiagnosticsWindowSummary {
        let classification: CodexUsageDiagnosticsClassification =
            durationsAligned && resetsAligned && modelValuesWithinAggregate ? .comparableCandidate : .independentLikely

        return CodexUsageDiagnosticsWindowSummary(
            window: window,
            classification: classification,
            aggregateBucketID: "codex",
            aggregateUsedPercent: aggregate,
            modelBucketCount: 2,
            modelUsedPercentSum: modelSum,
            durationsAligned: durationsAligned,
            resetsAligned: resetsAligned,
            modelValuesWithinAggregate: modelValuesWithinAggregate,
            notes: []
        )
    }
}
