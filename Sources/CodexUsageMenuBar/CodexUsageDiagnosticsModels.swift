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

struct CodexUsageDiagnosticsReview: Equatable {
    let captureCount: Int
    let classification: CodexUsageDiagnosticsClassification
    let summaries: [CodexUsageDiagnosticsReviewWindowSummary]
    let notes: [String]
}

struct CodexUsageDiagnosticsReviewWindowSummary: Equatable {
    let window: UsageLimitWindow
    let classification: CodexUsageDiagnosticsClassification
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

enum CodexUsageDiagnosticsReviewer {
    private static let minimumCaptureCount = 3
    private static let movementTolerance = 1

    static func review(_ snapshots: [CodexUsageDiagnosticsSnapshot]) -> CodexUsageDiagnosticsReview {
        let sortedSnapshots = snapshots.sorted { $0.generatedAt < $1.generatedAt }
        let summaries = UsageLimitWindow.allCases.map { window in
            review(window: window, snapshots: sortedSnapshots)
        }
        let classification = CodexUsageDiagnosticsSnapshot.overallClassification(from: summaries)
        let notes = if sortedSnapshots.count < minimumCaptureCount {
            ["At least 3 diagnostics captures are required before changing chart semantics."]
        } else {
            summaries.flatMap(\.notes)
        }

        return CodexUsageDiagnosticsReview(
            captureCount: sortedSnapshots.count,
            classification: classification,
            summaries: summaries,
            notes: notes
        )
    }

    private static func review(
        window: UsageLimitWindow,
        snapshots: [CodexUsageDiagnosticsSnapshot]
    ) -> CodexUsageDiagnosticsReviewWindowSummary {
        guard snapshots.count >= minimumCaptureCount else {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .inconclusive,
                notes: ["At least 3 diagnostics captures are required for \(window.displayTitle)."]
            )
        }

        let observations = snapshots.compactMap { snapshot in
            observation(in: snapshot, window: window)
        }

        guard observations.count == snapshots.count else {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .inconclusive,
                notes: ["One or more captures are missing aggregate or model data for \(window.displayTitle)."]
            )
        }

        if observations.contains(where: { !$0.durationsAligned }) {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .independentLikely,
                notes: ["One or more \(window.displayTitle) captures have model durations that differ from aggregate."]
            )
        }

        if observations.contains(where: { !$0.resetsAligned }) {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .independentLikely,
                notes: ["One or more \(window.displayTitle) captures have model resets that differ from aggregate."]
            )
        }

        if observations.contains(where: { !$0.modelValuesWithinAggregate }) {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .independentLikely,
                notes: ["One or more \(window.displayTitle) captures have model percentages outside the aggregate value."]
            )
        }

        var movingDeltas: [(aggregateDelta: Int, modelDelta: Int)] = []
        for (current, previous) in zip(observations.dropFirst(), observations) {
            let aggregateDelta = current.aggregateUsedPercent - previous.aggregateUsedPercent
            let modelDelta = current.modelUsedPercentSum - previous.modelUsedPercentSum

            guard aggregateDelta != 0 || modelDelta != 0 else {
                continue
            }

            movingDeltas.append((aggregateDelta: aggregateDelta, modelDelta: modelDelta))
        }

        guard !movingDeltas.isEmpty else {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .inconclusive,
                notes: ["The \(window.displayTitle) captures do not include enough percentage movement."]
            )
        }

        guard movingDeltas.allSatisfy({ abs($0.aggregateDelta - $0.modelDelta) <= movementTolerance }) else {
            return CodexUsageDiagnosticsReviewWindowSummary(
                window: window,
                classification: .independentLikely,
                notes: ["The \(window.displayTitle) model deltas do not consistently explain aggregate deltas."]
            )
        }

        return CodexUsageDiagnosticsReviewWindowSummary(
            window: window,
            classification: .comparableCandidate,
            notes: ["The \(window.displayTitle) model deltas consistently explain aggregate deltas."]
        )
    }

    private static func observation(
        in snapshot: CodexUsageDiagnosticsSnapshot,
        window: UsageLimitWindow
    ) -> WindowObservation? {
        guard let summary = snapshot.summaries.first(where: { $0.window == window }),
              let aggregateUsedPercent = summary.aggregateUsedPercent,
              let modelUsedPercentSum = summary.modelUsedPercentSum,
              summary.modelBucketCount > 0
        else {
            return nil
        }

        return WindowObservation(
            aggregateUsedPercent: aggregateUsedPercent,
            modelUsedPercentSum: modelUsedPercentSum,
            durationsAligned: summary.durationsAligned,
            resetsAligned: summary.resetsAligned,
            modelValuesWithinAggregate: summary.modelValuesWithinAggregate
        )
    }

    private struct WindowObservation {
        let aggregateUsedPercent: Int
        let modelUsedPercentSum: Int
        let durationsAligned: Bool
        let resetsAligned: Bool
        let modelValuesWithinAggregate: Bool
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

private extension CodexUsageDiagnosticsSnapshot {
    static func overallClassification(
        from summaries: [CodexUsageDiagnosticsReviewWindowSummary]
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
