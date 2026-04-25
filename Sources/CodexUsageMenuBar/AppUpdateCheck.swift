import Foundation

struct AppUpdateRelease: Equatable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: Date?

    var displayVersionText: String {
        tagName
    }

    var displayNameText: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        return tagName
    }
}

enum AppUpdateCheckClientError: Error, Equatable {
    case noPublishedRelease
    case invalidResponse
    case requestFailed(statusCode: Int)
    case decodingFailed
}

@MainActor
protocol AppUpdateCheckClientProtocol: AnyObject {
    func latestRelease() async throws -> AppUpdateRelease
}

@MainActor
final class GitHubLatestReleaseClient: AppUpdateCheckClientProtocol {
    typealias ResponseLoader = (URLRequest) async throws -> (Data, URLResponse)

    static let defaultEndpoint = URL(string: "https://api.github.com/repos/fmnobar/codexStatusBar/releases/latest")!

    private let endpoint: URL
    private let responseLoader: ResponseLoader

    init(
        endpoint: URL = GitHubLatestReleaseClient.defaultEndpoint,
        responseLoader: @escaping ResponseLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.endpoint = endpoint
        self.responseLoader = responseLoader
    }

    func latestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CodexStatusBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await responseLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateCheckClientError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            throw AppUpdateCheckClientError.noPublishedRelease
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateCheckClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(GitHubLatestReleasePayload.self, from: data)
            return AppUpdateRelease(
                tagName: payload.tagName,
                name: payload.name,
                htmlURL: payload.htmlURL,
                publishedAt: payload.publishedAt
            )
        } catch {
            throw AppUpdateCheckClientError.decodingFailed
        }
    }
}

private struct GitHubLatestReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

enum AppVersionComparison: Equatable {
    case updateAvailable
    case upToDate
    case inconclusive

    static func compare(installedVersion: String, latestTag: String) -> AppVersionComparison {
        guard
            let installed = SemanticAppVersion.parse(installedVersion),
            let latest = SemanticAppVersion.parse(latestTag)
        else {
            return .inconclusive
        }

        return latest > installed ? .updateAvailable : .upToDate
    }
}

private struct SemanticAppVersion: Comparable {
    let components: [Int]

    static func parse(_ rawValue: String) -> SemanticAppVersion? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }

        if let prereleaseIndex = value.firstIndex(of: "-") {
            value = String(value[..<prereleaseIndex])
        }
        if let buildIndex = value.firstIndex(of: "+") {
            value = String(value[..<buildIndex])
        }

        let rawComponents = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else {
            return nil
        }

        let components = rawComponents.compactMap { component -> Int? in
            guard !component.isEmpty, component.allSatisfy(\.isNumber) else {
                return nil
            }
            return Int(component)
        }

        guard components.count == rawComponents.count else {
            return nil
        }

        return SemanticAppVersion(components: components)
    }

    static func < (lhs: SemanticAppVersion, rhs: SemanticAppVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let leftComponent = lhs.components.indices.contains(index) ? lhs.components[index] : 0
            let rightComponent = rhs.components.indices.contains(index) ? rhs.components[index] : 0

            if leftComponent != rightComponent {
                return leftComponent < rightComponent
            }
        }

        return false
    }
}

enum AppUpdateCheckState: Equatable {
    case idle
    case checking
    case updateAvailable(AppUpdateRelease)
    case upToDate(AppUpdateRelease)
    case noPublishedRelease
    case inconclusive(AppUpdateRelease)
    case failed

    var release: AppUpdateRelease? {
        switch self {
        case .updateAvailable(let release), .upToDate(let release), .inconclusive(let release):
            return release
        case .idle, .checking, .noPublishedRelease, .failed:
            return nil
        }
    }
}
