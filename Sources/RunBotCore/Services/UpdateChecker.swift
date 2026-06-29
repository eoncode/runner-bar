// UpdateChecker.swift
// RunBotCore
import Foundation

/// Checks GitHub Releases for a newer version of RunBot.
///
/// Hits `GET /repos/runbot-hq/run-bot/releases` (the full list, not /latest)
/// so it can filter by channel. The `prerelease` field on each release is set
/// by the `--prerelease` flag in `publish.yml` at release creation time.
public struct UpdateChecker {

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/runbot-hq/run-bot/releases"
    )!

    /// A minimal Codable model for a GitHub Release API response object.
    private struct Release: Decodable {
        let tagName: String
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName  = "tag_name"
            case prerelease
        }
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
            .infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }

        do {
            var components = URLComponents(url: releasesURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "per_page", value: "20")]
            var request = URLRequest(url: components.url!)
            // GitHub API requires a User-Agent header.
            request.setValue("RunBot", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)
            let releases = try JSONDecoder().decode([Release].self, from: data)

            // Pick the first release that matches the channel filter.
            // Releases are returned newest-first by the GitHub API.
            guard let latest = releases.first(where: { betaChannel ? true : !$0.prerelease })
            else { return nil }

            let latestVersion  = latest.tagName.trimmingCharacters(in: .init(charactersIn: "v"))
            let currentVersion = current.trimmingCharacters(in: .whitespaces)

            // NOTE: Component-wise semver comparison.
            // Lexicographic string comparison fails once any component reaches
            // two digits (e.g. "1.10.0" < "1.9.0" lexicographically).
            // The rollover-at-10 rule prevents this in practice, but a proper
            // numeric compare is used here for safety.
            // Beta tags ("0.7.1-beta.2") are handled by splitting on "-" first:
            // the stable version "0.7.1" is always considered newer than "0.7.1-beta.N".
            return isNewer(latestVersion, than: currentVersion) ? latest.tagName : nil

        } catch {
            // Network failures and decode errors are silently swallowed —
            // update checks are best-effort and must never crash the app.
            return nil
        }
    }

    /// Returns `true` if `candidate` is a strictly newer semver than `current`.
    ///
    /// Handles pre-release suffixes: `"0.7.1"` is newer than `"0.7.1-beta.2"`
    /// because a stable release supersedes any beta of the same base version.
    internal static func isNewer(_ candidate: String, than current: String) -> Bool {
        // Split off any pre-release suffix (everything after the first "-").
        func parse(_ v: String) -> (major: Int, minor: Int, patch: Int, isPrerelease: Bool) {
            let parts        = v.split(separator: "-", maxSplits: 1)
            let core         = String(parts[0])
            let isPrerelease = parts.count > 1
            let nums         = core.split(separator: ".").compactMap { Int($0) }
            return (
                major:        nums.count > 0 ? nums[0] : 0,
                minor:        nums.count > 1 ? nums[1] : 0,
                patch:        nums.count > 2 ? nums[2] : 0,
                isPrerelease: isPrerelease
            )
        }

        let c = parse(candidate)
        let r = parse(current)

        if c.major != r.major { return c.major > r.major }
        if c.minor != r.minor { return c.minor > r.minor }
        if c.patch != r.patch { return c.patch > r.patch }
        // Same base version: stable (isPrerelease=false) beats a beta (isPrerelease=true)
        if c.isPrerelease != r.isPrerelease { return !c.isPrerelease }
        return false
    }
}
