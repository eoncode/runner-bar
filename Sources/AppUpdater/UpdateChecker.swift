// UpdateChecker.swift
// AppUpdater
import Foundation

// MARK: - ReleaseAsset

/// A single asset attached to a GitHub Release (e.g. `RunBot.zip`).
///
/// Only `name` and `browserDownloadURL` are decoded; the rest of the
/// GitHub asset payload is intentionally ignored to keep the model minimal.
public struct ReleaseAsset: Decodable, Sendable {
    /// The filename of the asset as it appears on the release page.
    public let name: String
    /// The direct download URL for this asset.
    ///
    /// This is always an `https://objects.githubusercontent.com/…` URL;
    /// it does not require authentication for public repositories.
    public let browserDownloadURL: URL

    /// Maps JSON keys to Swift property names.
    enum CodingKeys: String, CodingKey {
        /// Maps to the `name` field in the GitHub API response.
        case name
        /// Maps to the `browser_download_url` field in the GitHub API response.
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - AvailableRelease

/// A decoded GitHub Release, carrying the tag name and asset list.
public struct AvailableRelease: Sendable {
    /// The git tag of this release (e.g. `"v0.8.0"` or `"v0.8.0-beta.1"`).
    public let tagName: String
    /// The list of binary assets attached to this release.
    ///
    /// `AppUpdater` searches this list for the asset named by its `assetName`
    /// closure. When the asset is absent the host's failure state is set and
    /// the UI falls back to a browser-based Download button.
    public let assets: [ReleaseAsset]
    /// The URL of the SHA-256 checksum sidecar asset for this release, or `nil`
    /// if the release did not attach one.
    ///
    /// Populated at the `AvailableRelease(…)` construction site in
    /// `checkForUpdate` — the GitHub Releases API has no top-level checksum
    /// field. `AppUpdater.downloadUpdate` fetches this URL in parallel with the
    /// zip and verifies the SHA-256 digest before caching.
    ///
    /// A `nil` value is treated as a hard failure in `downloadUpdate` — the
    /// download is aborted and the host's failure state is set.
    public let checksumURL: URL?
}

// MARK: - UpdateCheckResult

/// The result of an `UpdateChecker.checkForUpdate(...)` call.
public enum UpdateCheckResult: Sendable {
    /// The running version is already the latest available.
    case upToDate
    /// A newer release is available.
    case updateAvailable(release: AvailableRelease)
    /// The check could not be completed (network error, missing key, etc.).
    ///
    /// Update checks are best-effort and must be treated as non-fatal.
    case failed(Error)
}

// MARK: - UpdateCheckError

/// Errors specific to the update-check flow that do not wrap a lower-level error.
public enum UpdateCheckError: Error, Sendable {
    /// The host supplied an empty `currentVersion`.
    case missingVersionKey
    /// No release matched the channel filter, or the API call failed.
    ///
    /// Collapses "empty list", "no channel match", and "network/API failure"
    /// into one code because update checks are best-effort background
    /// operations that must never surface error UI — the only observable
    /// consequence of any of these is "no update offered", which is correct.
    case noReleasesFound
}

// MARK: - UpdateChecker

/// Checks a GitHub repository's Releases for a newer version.
///
/// Hits `GET /repos/<repo>/releases` (the full list, not `/latest`) so it can
/// filter by channel. The `prerelease` field on each release distinguishes
/// stable from pre-release builds.
///
/// Caseless `enum` — all functionality is exposed via `static` methods; the
/// repository and current version are passed as parameters so the type carries
/// no host-specific state.
public enum UpdateChecker {

    /// A minimal Codable model for a GitHub Release API response object.
    private struct Release: Decodable {
        /// The git tag name for this release (e.g. `"v0.7.1"`).
        let tagName: String
        /// `true` when this release was published with `--prerelease`.
        let prerelease: Bool
        /// The binary assets attached to this release.
        let assets: [ReleaseAsset]

        /// Maps snake_case JSON keys to Swift property names.
        enum CodingKeys: String, CodingKey {
            /// Maps to the `tag_name` field in the GitHub API response.
            case tagName = "tag_name"
            /// Maps to the `prerelease` field in the GitHub API response.
            case prerelease
            /// Maps to the `assets` array in the GitHub API response.
            case assets
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
        /// `true` when the version string contains a pre-release suffix.
        let isPrerelease: Bool
        /// The numeric suffix from a `-beta.N` pre-release tag, or `nil`.
        ///
        /// Used to order beta.1 < beta.2 when major/minor/patch are identical.
        /// Only the exact `-beta.N` form is recognised; other suffixes parse as
        /// `isPrerelease = true` but `betaIndex = nil`.
        let betaIndex: Int?

        /// Parses a version string of the form `"X.Y.Z"` or `"X.Y.Z-beta.N"`.
        ///
        /// Components that cannot be parsed default to `0`; `betaIndex` to `nil`.
        init(_ version: String) { // skipcq: SW-R1002 — reviewed; complexity acceptable for this version parser
            let parts = version.split(separator: "-", maxSplits: 1)
            // `String.split` returns `[]` for an empty string (e.g. `"v"`
            // stripped of its prefix), so `parts[0]` would crash — default to
            // `""`, which degrades to major/minor/patch = 0.
            let core = parts.isEmpty ? "" : String(parts[0])
            isPrerelease = parts.count > 1
            let nums = core.split(separator: ".").compactMap { Int($0) }
            major = nums.isEmpty ? 0 : nums[0]
            minor = nums.count > 1 ? nums[1] : 0
            patch = nums.count > 2 ? nums[2] : 0
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

    /// Builds a `URLRequest` for the releases endpoint of `repo`.
    ///
    /// `perPage` is clamped to `1...100` (GitHub's documented maximum).
    /// Returns `nil` if a valid URL cannot be produced — update checks are
    /// best-effort and must never crash.
    private static func buildRequest(repo: String, perPage: Int) -> URLRequest? {
        let clampedPerPage = min(max(perPage, 1), 100)
        let releasesURLString = "https://api.github.com/repos/\(repo)/releases"
        guard let baseURL = URL(string: releasesURLString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(clampedPerPage))]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        // GitHub API requires a User-Agent header.
        request.setValue("AppUpdater", forHTTPHeaderField: "User-Agent")
        // Unauthenticated: GitHub's public Releases API needs no token. The
        // 60 req/hr unauthenticated limit is ample for a daily check.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Pin the REST API version so the response shape stays stable.
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// Fetches the releases list for `repo`, sorts by semver, and returns the
    /// highest release matching `betaChannel`, or `nil` on any failure.
    ///
    /// The list is sorted by semver (not GitHub's published-date order) before
    /// filtering, so a hotfix published to an older branch cannot masquerade as
    /// the latest. Per-page is 100 so all releases fit in one response.
    ///
    /// A `nil` result is returned for every failure mode (network error,
    /// non-200 status, decode failure, empty list, no channel match). All are
    /// indistinguishable from "already up to date" — the intended best-effort
    /// design; update checks never surface error UI. Non-200 HTTP status codes
    /// are logged at debug level so misconfiguration (bad repo slug, rate limit)
    /// is visible in Console.app without surfacing UI.
    private static func latestMatchingRelease(repo: String, betaChannel: Bool) async -> Release? {
        guard let request = buildRequest(repo: repo, perPage: 100) else { return nil }

        // Dedicated session with explicit timeouts, mirroring `downloadUpdate`:
        // `URLSession.shared` has no timeout, so a stalled connection would hang
        // a background update check indefinitely. This is a small JSON API call
        // (not a zip download), so the resource timeout is much shorter than the
        // download path's 300s.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request) else { return nil }

        // Log non-200 responses at debug level so misconfiguration (e.g. a 403
        // rate-limit, 404 bad repo slug, or 429 throttle) is visible in
        // Console.app. Without this the entire failure was a silent nil — a
        // developer black hole when first configuring an AppUpdater instance.
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            appUpdaterLogger.debug("releases API returned \(httpResponse.statusCode, privacy: .public) for \(repo, privacy: .public)")
            return nil
        }

        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }

        let sorted = releases.sorted { isNewer($0.tagName, than: $1.tagName) }
        return sorted.first(where: { betaChannel ? true : !$0.prerelease })
    }

    /// Returns `true` when `candidate` is strictly newer than `current` using
    /// numeric semver comparison, including beta ordering.
    ///
    /// Both strings are stripped of a leading `v` prefix before parsing.
    /// Pre-release versions are older than their stable base
    /// (`1.0.0-beta.1 < 1.0.0`); within the same base, higher beta index wins
    /// (`1.0.0-beta.2 > 1.0.0-beta.1`).
    ///
    /// Exposed `public` so host apps can reuse the same comparison (e.g. to
    /// gate a cached-zip rehydration against the running version).
    public static func isNewer(_ candidate: String, than current: String) -> Bool { // skipcq: SW-R1002 — reviewed; complexity acceptable for this semver comparison
        let cv = ParsedVersion(candidate.hasPrefix("v") ? String(candidate.dropFirst()) : candidate)
        let sv = ParsedVersion(current.hasPrefix("v")   ? String(current.dropFirst())   : current)

        if cv.major != sv.major { return cv.major > sv.major }
        if cv.minor != sv.minor { return cv.minor > sv.minor }
        if cv.patch != sv.patch { return cv.patch > sv.patch }

        // Same X.Y.Z — stable beats pre-release, then compare beta index.
        if cv.isPrerelease != sv.isPrerelease { return !cv.isPrerelease }
        if let ci = cv.betaIndex, let si = sv.betaIndex { return ci > si }

        return false
    }

    /// Checks whether an update is available for `currentVersion` in `repo`.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug.
    ///   - currentVersion: The running app's version (full semver, incl. any
    ///     pre-release suffix). An empty string yields `.failed(.missingVersionKey)`.
    ///   - betaChannel: When `true`, pre-release builds are candidates.
    ///   - assetName: Maps a tag name to the expected zip asset filename; used
    ///     to locate the SHA-256 sidecar (`<assetName>.sha256`) for this release.
    public static func checkForUpdate(
        repo: String,
        currentVersion: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> UpdateCheckResult {
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }

        guard let latest = await latestMatchingRelease(repo: repo, betaChannel: betaChannel) else {
            return .failed(UpdateCheckError.noReleasesFound)
        }

        guard isNewer(latest.tagName, than: currentVersion) else {
            return .upToDate
        }

        // Locate the SHA-256 sidecar from the already-decoded assets array.
        let checksumAssetName = assetName(latest.tagName) + ".sha256"
        let checksumAsset = latest.assets.first(where: { $0.name == checksumAssetName })
        let release = AvailableRelease(
            tagName: latest.tagName,
            assets: latest.assets,
            checksumURL: checksumAsset?.browserDownloadURL
        )
        return .updateAvailable(release: release)
    }
}
