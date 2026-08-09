import AppKit
import Foundation

/// Checks the project's public GitHub Releases feed for a newer app version.
///
/// This intentionally opens the matching release page instead of replacing the
/// running app. The app bundle may live in a user-writable folder, /Applications,
/// or on a read-only disk image; asking Finder to install the signed release
/// keeps those cases predictable and lets macOS perform its normal validation.
@MainActor
final class AppUpdateManager: ObservableObject {
    struct Release: Equatable {
        let version: String
        let pageURL: URL
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let repository: String?
    private let currentVersion: String
    private var checkTask: Task<Void, Never>?

    init(
        repository: String? = ProcessInfo.processInfo.environment["WHISPR_UPDATE_REPOSITORY"]
            ?? Bundle.main.object(forInfoDictionaryKey: "WhisprUpdateRepository") as? String,
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    ) {
        self.repository = repository?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentVersion = currentVersion
    }

    deinit { checkTask?.cancel() }

    func checkForUpdates() {
        guard checkTask == nil else { return }
        guard let repository, Self.isValidRepository(repository) else {
            status = .failed("This build does not have a GitHub update feed configured.")
            return
        }

        status = .checking
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkTask = nil }

            do {
                let release = try await Self.fetchLatestRelease(for: repository)
                guard let latest = SemanticVersion(release.tagName),
                      let current = SemanticVersion(self.currentVersion) else {
                    throw UpdateError.invalidVersion
                }

                self.status = latest > current
                    ? .available(Release(version: latest.description, pageURL: release.pageURL))
                    : .upToDate
            } catch is CancellationError {
                self.status = .idle
            } catch {
                Log.write("update check failed: \(error.localizedDescription)")
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func openAvailableRelease() {
        guard case let .available(release) = status else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    private static func fetchLatestRelease(for repository: String) async throws -> GitHubRelease {
        guard let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.invalidRepository
        }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WhisprStream", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.unavailable }
        guard response.statusCode == 200 else {
            throw response.statusCode == 404 ? UpdateError.noPublishedRelease : UpdateError.unavailable
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { throw UpdateError.noPublishedRelease }
        return release
    }

    private static func isValidRepository(_ repository: String) -> Bool {
        repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let pageURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case pageURL = "html_url"
            case draft, prerelease
        }
    }

    private enum UpdateError: LocalizedError {
        case invalidRepository
        case invalidVersion
        case noPublishedRelease
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidRepository: "The GitHub update feed is invalid."
            case .invalidVersion: "The published release does not use a supported version number."
            case .noPublishedRelease: "There is no published update yet."
            case .unavailable: "Could not reach GitHub to check for updates."
            }
        }
    }
}

/// A deliberately small semantic-version parser for stable `v1.2.3` GitHub
/// release tags. Pre-release tags are excluded by the GitHub API request.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}
