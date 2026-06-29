// UpdateChecker.swift
// RunBotCore
import Foundation

/// Checks GitHub Releases for a newer version of RunBot.
///
/// Hits `GET /repos/runbot-hq/run-bot/releases` (the full list, not /latest)
/// so it can filter by channel. The `prerelease` field on each release is set
/// by the `--prerelease` flag in `publish.yml` at release creation time.
public enum UpdateChecker {

    /// The GitHub Releases API URL string for this repository.
    ///
    /// Kept as a plain `String` constant so there is no dependency on a
    /// particular `URL` initialiser overload. `buildRequest(perPage:)` converts
    /// it to a `URL` via `URL(string:)` and returns `nil` on failure, so a
    /// typo here degrades gracefully (update check silently no-ops) rather
    /// than crashing at startup.
    private static let releasesURLString =
        "https://api.github.com/repos/runbot-hq/run-bot/releases"

    /// A minimal Codable model for a GitHub Release API response object.
    private struct Release: Decodable {
        /// The git tag name for this release (e.g. `"v0.7.1"`).
        let tagName: String
        /// `true` when this release was published with `--prerelease`.
        let prerelease: Bool

        /// Maps snake_case JSON keys to Swift property names.
        enum CodingKeys: String, CodingKey {
            /// Maps to the `tag_name` field in the GitHub API response.
            case tagName = "tag_name"
            /// Maps to the `prerelease` field in the GitHub API response.
            case prerelease
        }
    }

    /// Parsed semver components extracted from a version string.
    private struct ParsedVersion {
        /// Major version component.
        let major: Int
        /// Minor version component.
        let minor: Int
        /// Patch version component.
        let patch: Int
        /// `true` when the version string contains a pre-release suffix (e.g. `-beta.2`).
        let isPrerelease: Bool
        /// The numeric suffix from a `-beta.N` pre-release tag, or `nil` if not a
        /// beta tag or if the suffix cannot be parsed. Used to order beta.1 < beta.2
        /// when major/minor/patch are identical — without this, two betas of the same
        /// base version compare equal and `isNewer` returns `false`, silently
        /// suppressing beta-to-beta update prompts.
        let betaIndex: Int?

        /// Parses a version string of the form `"X.Y.Z"` or `"X.Y.Z-beta.N"`.
        ///
        /// Components that cannot be parsed default to `0`. `betaIndex` defaults to `nil`.
        init(_ version: String) {
            let parts = version.split(separator: "-", maxSplits: 1)
            let core = String(parts[0])
            isPrerelease = parts.count > 1
            let nums = core.split(separator: ".").compactMap { Int($0) }
            major = nums.isEmpty ? 0 : nums[0]
            minor = nums.count > 1 ? nums[1] : 0
            patch = nums.count > 2 ? nums[2] : 0
            // Parse beta.N suffix — e.g. "beta.2" → betaIndex = 2.
            if parts.count > 1 {
                let suffix = String(parts[1]) // e.g. "beta.2"
                let suffixParts = suffix.split(separator: ".")
                if suffixParts.count == 2, suffixParts[0] == "beta",
                   let n = Int(suffixParts[1]) {
                    betaIndex = n
                } else {
                    betaIndex = nil
                }
            } else {
                betaIndex = nil
            }
        }
    }

    /// Builds a `URLRequest` for the releases endpoint with the given page size.
    ///
    /// Returns `nil` if `URL(string:)` or `URLComponents` cannot produce a
    /// valid URL — update checks are best-effort and must never crash the app.
    private static func buildRequest(perPage: Int) -> URLRequest? {
        guard let baseURL = URL(string: releasesURLString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(perPage))]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        // GitHub API requires a User-Agent header.
        request.setValue("RunBot", forHTTPHeaderField: "User-Agent")
        // Recommended by GitHub REST API docs to ensure a stable v3 response shape.
        // Without this the API still responds correctly today, but the content type
        // is not guaranteed to remain stable across API versions.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Fetches and decodes the releases list, then returns the first release
    /// matching `betaChannel` filter, or `nil` on failure.
    private static func latestMatchingRelease(betaChannel: Bool) async -> Release? {
        guard let request = buildRequest(perPage: 20) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        return releases.first(where: { betaChannel ? true : !$0.prerelease })
    }

    /// Checks for an available update.
    ///
    /// - Parameter betaChannel: When `true`, considers pre-release builds.
    ///   When `false`, only stable (non-prerelease) releases are considered.
    /// - Returns: The tag name string (e.g. `"v0.7.1"` or `"v0.7.1-beta.2"`)
    ///   if a newer version is available, or `nil` if already up to date or
    ///   if the check fails (network error, decode error, etc.).
    public static func checkForUpdate(betaChannel: Bool) async -> String? {
        guard let current = Bundle.main
            .infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        guard let latest = await latestMatchingRelease(betaChannel: betaChannel) else { return nil }

        let latestVersion = latest.tagName.trimmingCharacters(in: .init(charactersIn: "v"))
        let currentVersion = current
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: .init(charactersIn: "v"))

        // NOTE: Component-wise semver comparison.
        // Lexicographic string comparison fails once any component reaches
        // two digits (e.g. "1.10.0" < "1.9.0" lexicographically).
        // The rollover-at-10 rule prevents this in practice, but a proper
        // numeric compare is used here for safety.
        // Beta tags ("0.7.1-beta.2") are handled by splitting on "-" first:
        // the stable version "0.7.1" is always considered newer than "0.7.1-beta.N".
        return isNewer(latestVersion, than: currentVersion) ? latest.tagName : nil
    }

    /// Returns `true` if `candidate` is a strictly newer semver than `current`.
    ///
    /// Handles pre-release suffixes: `"0.7.1"` is newer than `"0.7.1-beta.2"`
    /// because a stable release supersedes any beta of the same base version.
    internal static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParsed = ParsedVersion(candidate)
        let runningParsed = ParsedVersion(current)

        if candidateParsed.major != runningParsed.major { return candidateParsed.major > runningParsed.major }
        if candidateParsed.minor != runningParsed.minor { return candidateParsed.minor > runningParsed.minor }
        if candidateParsed.patch != runningParsed.patch { return candidateParsed.patch > runningParsed.patch }
        // Same base version: stable (isPrerelease=false) beats a beta (isPrerelease=true)
        if candidateParsed.isPrerelease != runningParsed.isPrerelease { return !candidateParsed.isPrerelease }
        // Both are betas of the same base: compare beta.N index so that
        // beta.2 is correctly seen as newer than beta.1. Without this,
        // two betas with identical major/minor/patch return false and
        // users on beta.1 are never offered the beta.2 update.
        if let ci = candidateParsed.betaIndex, let ri = runningParsed.betaIndex {
            return ci > ri
        }
        return false
    }
}
