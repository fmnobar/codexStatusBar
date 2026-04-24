import Foundation

enum CodexUsageDiagnosticsClassification: String, Codable, Equatable {
    case comparableCandidate
    case independentLikely
    case inconclusive
}

struct CodexUsageDiagnosticsSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let classification: CodexUsageDiagnosticsClassification
    let buckets: [CodexUsageDiagnosticsBucket]
    let summaries: [CodexUsageDiagnosticsWindowSummary]

    init(
        generatedAt: Date,
        buckets: [CodexUsageDiagnosticsBucket],
        summaries: [CodexUsageDiagnosticsWindowSummary]
    ) {
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.buckets = buckets
        self.summaries = summaries
        classification = Self.overallClassification(from: summaries)
    }

    private static func overallClassification(
        from summaries: [CodexUsageDiagnosticsWindowSummary]
    ) -> CodexUsageDiagnosticsClassification {
        if summaries.contains(where: { $0.classification == .independentLikely }) {
            return .independentLikely
        }

        if !summaries.isEmpty, summaries.allSatisfy({ $0.classification == .comparableCandidate }) {
            return .comparableCandidate
        }

        return .inconclusive
    }
}

struct CodexUsageDiagnosticsBucket: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let kind: CodexUsageBucketKind
    let planType: String?
    let primary: CodexUsageDiagnosticsWindow?
    let secondary: CodexUsageDiagnosticsWindow?
}

struct CodexUsageDiagnosticsWindow: Codable, Equatable {
    let usedPercent: Int
    let windowDurationMinutes: Int?
    let resetsAt: Date?
}

struct CodexUsageDiagnosticsWindowSummary: Codable, Equatable {
    let window: UsageLimitWindow
    let classification: CodexUsageDiagnosticsClassification
    let aggregateBucketID: String?
    let aggregateUsedPercent: Int?
    let modelBucketCount: Int
    let modelUsedPercentSum: Int?
    let durationsAligned: Bool
    let resetsAligned: Bool
    let modelValuesWithinAggregate: Bool
    let notes: [String]
}

enum CodexUsageDiagnosticsExporter {
    static func jsonData(for snapshot: CodexUsageDiagnosticsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }
}

extension AccountRateLimitsResponse {
    func diagnosticsSnapshot(generatedAt: Date) -> CodexUsageDiagnosticsSnapshot {
        let buckets = diagnosticsBuckets()
        let summaries = UsageLimitWindow.allCases.map { window in
            CodexUsageDiagnosticsClassifier.summary(for: window, buckets: buckets)
        }

        return CodexUsageDiagnosticsSnapshot(
            generatedAt: generatedAt,
            buckets: buckets,
            summaries: summaries
        )
    }

    private func diagnosticsBuckets() -> [CodexUsageDiagnosticsBucket] {
        if let rateLimitsByLimitId, !rateLimitsByLimitId.isEmpty {
            return rateLimitsByLimitId
                .map { key, payload in
                    payload.toDiagnosticsBucket(fallbackId: key)
                }
                .sortedByDiagnosticsOrder()
        }

        return [
            rateLimits.toDiagnosticsBucket(fallbackId: rateLimits.limitId ?? "codex"),
        ]
    }
}

private enum CodexUsageDiagnosticsClassifier {
    private static let resetAlignmentTolerance: TimeInterval = 60

    static func summary(
        for window: UsageLimitWindow,
        buckets: [CodexUsageDiagnosticsBucket]
    ) -> CodexUsageDiagnosticsWindowSummary {
        let aggregateBucket = buckets.first { $0.kind == .aggregate }
        let modelBuckets = buckets.filter { $0.kind == .model }
        let aggregateWindow = aggregateBucket?.window(for: window)
        let modelWindows = modelBuckets.compactMap { bucket -> CodexUsageDiagnosticsWindow? in
            bucket.window(for: window)
        }
        let modelUsedPercentSum = modelWindows.isEmpty ? nil : modelWindows.reduce(0) { $0 + $1.usedPercent }

        guard let aggregateWindow else {
            return CodexUsageDiagnosticsWindowSummary(
                window: window,
                classification: .inconclusive,
                aggregateBucketID: nil,
                aggregateUsedPercent: nil,
                modelBucketCount: modelWindows.count,
                modelUsedPercentSum: modelUsedPercentSum,
                durationsAligned: false,
                resetsAligned: false,
                modelValuesWithinAggregate: false,
                notes: ["No aggregate bucket was available for this window."]
            )
        }

        guard !modelWindows.isEmpty else {
            return CodexUsageDiagnosticsWindowSummary(
                window: window,
                classification: .inconclusive,
                aggregateBucketID: aggregateBucket?.id,
                aggregateUsedPercent: aggregateWindow.usedPercent,
                modelBucketCount: 0,
                modelUsedPercentSum: nil,
                durationsAligned: true,
                resetsAligned: true,
                modelValuesWithinAggregate: true,
                notes: ["No model buckets were available for this window."]
            )
        }

        let durationsAligned = modelWindows.allSatisfy {
            $0.windowDurationMinutes == aggregateWindow.windowDurationMinutes
        }
        let resetsAligned = modelWindows.allSatisfy {
            resetDatesAreAligned(aggregateWindow.resetsAt, $0.resetsAt)
        }
        let modelValuesWithinAggregate = modelWindows.allSatisfy {
            $0.usedPercent <= aggregateWindow.usedPercent
        } && (modelUsedPercentSum ?? 0) <= aggregateWindow.usedPercent

        let classification: CodexUsageDiagnosticsClassification
        var notes: [String] = []

        if !durationsAligned {
            notes.append("One or more model buckets use a different window duration than the aggregate bucket.")
        }

        if !resetsAligned {
            notes.append("One or more model buckets reset at a different time than the aggregate bucket.")
        }

        if !modelValuesWithinAggregate {
            notes.append("Model bucket percentages do not fit within the aggregate used percentage.")
        }

        if durationsAligned && resetsAligned && modelValuesWithinAggregate {
            classification = .comparableCandidate
            notes.append("Model buckets align with the aggregate bucket for this single captured sample.")
        } else {
            classification = .independentLikely
        }

        return CodexUsageDiagnosticsWindowSummary(
            window: window,
            classification: classification,
            aggregateBucketID: aggregateBucket?.id,
            aggregateUsedPercent: aggregateWindow.usedPercent,
            modelBucketCount: modelWindows.count,
            modelUsedPercentSum: modelUsedPercentSum,
            durationsAligned: durationsAligned,
            resetsAligned: resetsAligned,
            modelValuesWithinAggregate: modelValuesWithinAggregate,
            notes: notes
        )
    }

    private static func resetDatesAreAligned(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.some(let lhs), .some(let rhs)):
            return abs(lhs.timeIntervalSince(rhs)) <= resetAlignmentTolerance
        default:
            return false
        }
    }
}

private extension RateLimitSnapshotPayload {
    func toDiagnosticsBucket(fallbackId: String) -> CodexUsageDiagnosticsBucket {
        let resolvedId = limitId ?? fallbackId
        let kind: CodexUsageBucketKind = isMainCodexBucket ? .aggregate : .model
        let resolvedName = if kind == .aggregate {
            "All models"
        } else {
            limitName ?? resolvedId
        }

        return CodexUsageDiagnosticsBucket(
            id: resolvedId,
            name: resolvedName,
            kind: kind,
            planType: planType,
            primary: primary?.toDiagnosticsWindow(),
            secondary: secondary?.toDiagnosticsWindow()
        )
    }
}

private extension RateLimitWindowPayload {
    func toDiagnosticsWindow() -> CodexUsageDiagnosticsWindow {
        CodexUsageDiagnosticsWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMins,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private extension CodexUsageDiagnosticsBucket {
    func window(for usageWindow: UsageLimitWindow) -> CodexUsageDiagnosticsWindow? {
        switch usageWindow {
        case .fiveHour:
            return primary
        case .sevenDay:
            return secondary
        }
    }
}

private extension Array where Element == CodexUsageDiagnosticsBucket {
    func sortedByDiagnosticsOrder() -> [CodexUsageDiagnosticsBucket] {
        sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .aggregate
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
