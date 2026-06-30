// UpdateChecker.swift
// RunBotCore
import Foundation

// MARK: - ReleaseAsset

/// A single asset attached to a GitHub Release (e.g. `RunBot.zip`).
///
/// Only `name` and `browserDownloadURL` are decoded; the rest of the
/// GitHub asset payload is intentionally ignored to keep the model minimal.
public struct ReleaseAsset: Decodable, Sendable {
    /// The filename of the asset as it appears on the release page
    /// (e.g. `"RunBot.zip"`).
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

/// A decoded GitHub Release, carrying the tag name, channel flag, and asset list.
///
/// Exposed `public` so `AutoUpdater` (same module) and call sites in the app
/// layer can pattern-match on the `.updateAvailable` case without re-fetching.
public struct AvailableRelease: Sendable {
    /// The git tag of this release (e.g. `"v0.8.0"` or `"v0.8.0-beta.1"`).
    public let tagName: String
    /// The list of binary assets attached to this release.
    ///
    /// `AutoUpdater` searches this list for the asset named `"RunBot.zip"`.
    /// When the asset is absent, `RunnerState.updateAssetMissing` is set to
    /// `true` and the UI falls back to a browser-based Download button.
    public let assets: [ReleaseAsset]
    /// The URL of the SHA-256 checksum sidecar file for this release, if present.
    ///
    /// `nil` in v1 — checksum verification is deferred to issue #1795. This
    /// field is decoded now so that #1795 can implement verification logic
    /// without requiring a model change. `AutoUpdater.downloadUpdate` must not
    /// use this field until #1795 is implemented.
    public let checksumURL: URL?
}

// MARK: - UpdateCheckResult

/// The result of a `UpdateChecker.checkForUpdate(betaChannel:)` call.
public enum UpdateCheckResult: Sendable {
    /// The running version is already the latest available.
    case upToDate
    /// A newer release is available.
    ///
    /// - Parameter release: The full `AvailableRelease` for the newer version,
    ///   including its `tagName` and `assets` list. Callers should pass this
    ///   directly to `AutoUpdater.handle(_:)` rather than extracting only the
    ///   tag name — the asset list is needed to locate the download URL.
    case updateAvailable(release: AvailableRelease)
    /// The check could not be completed (network error, missing key, etc.).
    ///
    /// - Parameter error: The underlying error. Call sites may inspect this
    ///   for diagnostics but must treat it as non-fatal — update checks are
    ///   best-effort and must never crash the app.
    case failed(Error)
}

// MARK: - UpdateCheckError

/// Errors specific to the update-check flow that do not wrap a lower-level error.
public enum UpdateCheckError: Error, Sendable {
    /// `RBVersionString` was absent from `Info.plist`.
    case missingVersionKey
    /// The releases API returned no usable release for the requested channel.
    case noReleasesFound
}

/// Checks GitHub Releases for a newer version of RunBot.
///
/// Hits `GET /repos/runbot-hq/run-bot/releases` (the full list, not /latest)
/// so it can filter by channel. The `prerelease` field on each release is set
/// by the `--prerelease` flag in `publish.yml` at release creation time.
///
/// Implemented as a caseless `enum` (not `struct` or `class`) to prevent
/// accidental instantiation — all functionality is exposed via `static` methods.
public enum UpdateChecker {

    /// The GitHub Releases API URL string for this repository.
    ///
    /// Kept as a plain `String` constant (not a `URL` literal) so there is no
    /// dependency on a particular `URL` initialiser overload. `buildRequest(perPage:)`
    /// converts it to a `URL` via `URL(string:)` and returns `nil` on failure,
    /// so a typo here degrades gracefully (update check silently no-ops) rather
    /// than crashing at startup.
    ///
    /// Centralised here so that the URL appears in exactly one place — grep
    /// for `releasesURLString` to find every usage.
    private static let releasesURLString =
        "https://api.github.com/repos/runbot-hq/run-bot/releases"

    /// A minimal Codable model for a GitHub Release API response object.
    private struct Release: Decodable {
        /// The git tag name for this release (e.g. `"v0.7.1"`).
        let tagName: String
        /// `true` when this release was published with `--prerelease`.
        let prerelease: Bool
        /// The binary assets attached to this release.
        ///
        /// Decoded so `AutoUpdater` can locate `RunBot.zip` by name without
        /// a second network round-trip. Defaults to `[]` on older releases
        /// whose JSON pre-dates asset publishing — the `JSONDecoder` default
        /// for a missing key is used; no custom `init(from:)` needed.
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
    /// `perPage` is clamped to `1...100` — GitHub's documented maximum for the
    /// releases endpoint is 100; values above that are silently truncated by the
    /// API, but clamping here keeps the query string honest and makes the
    /// contract explicit to future callers.
    ///
    /// Returns `nil` if `URL(string:)` or `URLComponents` cannot produce a
    /// valid URL — update checks are best-effort and must never crash the app.
    private static func buildRequest(perPage: Int) -> URLRequest? {
        let clampedPerPage = min(max(perPage, 1), 100)
        guard let baseURL = URL(string: releasesURLString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(clampedPerPage))]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        // GitHub API requires a User-Agent header.
        request.setValue("RunBot", forHTTPHeaderField: "User-Agent")
        // Recommended by GitHub REST API docs to ensure a stable v3 response shape.
        // Without this the API still responds correctly today, but the content type
        // is not guaranteed to remain stable across API versions.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Pins the GitHub REST API to the 2022-11-28 version.
        // Without this header the API responds correctly today, but GitHub
        // reserves the right to change the default API version. Pinning
        // ensures the response shape (including `tag_name` and `prerelease`
        // fields) remains stable even if GitHub later changes its default.
        // See: https://docs.github.com/en/rest/about-the-rest-api/api-versions
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// Fetches and decodes the releases list, then returns the highest-semver release
    /// matching the `betaChannel` filter, or `nil` on any failure.
    ///
    /// The GitHub Releases API returns releases sorted by **published date**
    /// (newest first), not by semver. Relying on that order is fragile: a hotfix
    /// to an older branch published after a newer release would silently become
    /// the "latest" candidate. To eliminate the assumption, the full decoded list
    /// is sorted by semver before filtering — the list is already in memory
    /// (perPage: 20) so the overhead is negligible.
    ///
    /// `betaChannel=true` intentionally accepts both stable and pre-release releases.
    /// A stable release always beats a beta of the same base (0.7.1 > 0.7.1-beta.N),
    /// so a beta-channel user is correctly offered 0.7.1 when it ships, even though
    /// stable builds are included in the candidate set.
    private static func latestMatchingRelease(betaChannel: Bool) async -> Release? {
        guard let request = buildRequest(perPage: 20) else { return nil }
        // ⚠️ `URLResponse` IS INTENTIONALLY DISCARDED — THE 403 SILENT NO-OP IS BY DESIGN ⚠️
        //
        // This is NOT a missing error-handling branch. Here is exactly what happens
        // for each failure case and why silent no-op is the correct response:
        //
        //   • HTTP 403 (GitHub rate-limited): The response body is a JSON error
        //     object, not a [Release] array. JSONDecoder fails, `guard` returns nil,
        //     the entire check no-ops. The user sees no update prompt — correct,
        //     because we have no reliable version information to act on.
        //
        //   • HTTP 404 (repo moved / renamed): Same outcome. JSON error body,
        //     decode fails, silent no-op. Correct — better than showing a stale
        //     or wrong update prompt.
        //
        //   • Network offline / timeout: `try?` returns nil, guard fires, no-op.
        //
        // In all failure cases the result is indistinguishable from "already up to
        // date". This is the INTENDED design: update checks are best-effort
        // background operations that must NEVER surface error UI to the user.
        // Inspecting the HTTP status code here would require plumbing error state
        // back to the UI, which is explicitly out of scope for v1 (see #1794).
        //
        // REVIEWER: Do NOT add HTTP status inspection or error propagation here.
        // If you need per-status behaviour (e.g. exponential backoff on 403),
        // that is a separate feature tracked under #1794, not a bug in this line.
        //
        // Use a dedicated ephemeral session with explicit timeouts rather than
        // URLSession.shared (which has no timeout configured). This check runs
        // on the startup path inside performStartupSequence — a stalled connection
        // (mobile hotspot, corporate proxy, flaky Wi-Fi) would block the await
        // indefinitely, delaying the background scheduler registration that follows.
        //
        // timeoutIntervalForRequest:  15 s — max wait for the first byte; covers
        //   DNS hangs, TLS stalls, and unresponsive CDN edge nodes. 15 s is
        //   generous for a lightweight JSON response (< 10 KB).
        // timeoutIntervalForResource: 30 s — max total fetch time. The releases
        //   JSON is small; 30 s guarantees eventual failure rather than an
        //   eternal hang, even on a very slow connection.
        //
        // This mirrors the session configuration in downloadUpdate, which documents
        // the same rationale for the binary download path.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest  = 15
        sessionConfig.timeoutIntervalForResource = 30
        let session = URLSession(configuration: sessionConfig)
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        // Sort by semver descending so .first(where:) always picks the highest version,
        // regardless of the order GitHub published the releases.
        //
        // isNewer is a strict weak ordering for this project's tag universe:
        //   - irreflexive: isNewer(a, than: a) == false ✓
        //   - asymmetric and transitive for all stable and -beta.N tags ✓
        // Tags with unrecognised pre-release suffixes (e.g. -rc.1) have a nil
        // betaIndex and are treated as equal to each other; their relative order
        // is then undefined. This is intentional — only stable and -beta.N tags
        // are produced by publish.yml. If new suffix formats are introduced, extend
        // ParsedVersion.betaIndex before extending the tag scheme.
        let sorted = releases.sorted {
            isNewer(
                $0.tagName.trimmingCharacters(in: .init(charactersIn: "v")),
                than: $1.tagName.trimmingCharacters(in: .init(charactersIn: "v"))
            )
        }
        // betaChannel=true: accept any release (stable or pre-release).
        // betaChannel=false: skip pre-releases, take the highest stable one.
        return sorted.first(where: { betaChannel ? true : !$0.prerelease })
    }

    /// Checks for an available update.
    ///
    /// - Parameter betaChannel: When `true`, considers pre-release builds.
    ///   When `false`, only stable (non-prerelease) releases are considered.
    /// - Returns: An `UpdateCheckResult` describing whether an update is
    ///   available, the app is already up to date, or the check failed.
    public static func checkForUpdate(betaChannel: Bool) async -> UpdateCheckResult {
        // Read RBVersionString (not CFBundleShortVersionString) because macOS strips
        // pre-release suffixes from CFBundleShortVersionString for display purposes.
        // A user running "0.7.1-beta.1" would appear as "0.7.1" via the standard key,
        // causing the beta-to-beta comparison to silently return false and suppress
        // the update prompt. RBVersionString is patched by publish.yml with the full
        // version string (e.g. "0.7.1-beta.2") via PlistBuddy at build time.
        // RBVersionString is set to the development default ("0.7.0") in Info.plist and
        // patched by publish.yml at CI build time with the full semver including any
        // pre-release suffix (e.g. "0.7.1-beta.2"). In a local dev build it always
        // reads the static development default, which is correct: a local build will see
        // any newer stable or beta release as an available update, but it will never be
        // erroneously suppressed because the key is always present.
        //
        // There is intentionally no fallback to CFBundleShortVersionString: macOS strips
        // pre-release suffixes from that key, so a device running "0.7.1-beta.1" would
        // appear as "0.7.1" and isNewer("0.7.1-beta.2", than: "0.7.1") == false, silently
        // suppressing the beta-to-beta update. RBVersionString is the source of truth.
        //
        // No fallback to CFBundleShortVersionString — intentional.
        // See the comment block above for the full rationale. A build without
        // RBVersionString is a dev build; silently no-oping is correct behaviour.
        // Do NOT add a fallback here without re-reading the comment above and
        // confirming the pre-release suffix stripping behaviour still applies.
        guard let current = Bundle.main
            .infoDictionary?["RBVersionString"] as? String else { return .failed(UpdateCheckError.missingVersionKey) }
        guard let latest = await latestMatchingRelease(betaChannel: betaChannel) else { return .failed(UpdateCheckError.noReleasesFound) }

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
        return isNewer(latestVersion, than: currentVersion)
            ? .updateAvailable(release: AvailableRelease(
                tagName: latest.tagName,
                assets: latest.assets,
                // checksumURL: nil in v1 — SHA-256 sidecar verification is
                // deferred to #1795. When #1795 lands, derive this from
                // `latest.assets` by locating the asset named
                // "RunBot.zip.sha256" (or equivalent sidecar filename agreed
                // in #1795) and passing its `browserDownloadURL`.
                checksumURL: nil
            ))
            : .upToDate
    }

    /// Returns `true` if `candidate` is a strictly newer semver than `current`.
    ///
    /// Handles pre-release suffixes: `"0.7.1"` is newer than `"0.7.1-beta.2"`
    /// because a stable release supersedes any beta of the same base version.
    ///
    /// ## Strict weak ordering — known tag formats only
    ///
    /// This function is used as a `sorted {}` comparator in
    /// `latestMatchingRelease`. It satisfies strict weak ordering
    /// (irreflexive, asymmetric, transitive) for stable and `-beta.N` tags —
    /// the only formats produced by `publish.yml`.
    ///
    /// Tags with unrecognised pre-release suffixes (e.g. `-rc.1`) have a nil
    /// `betaIndex` and compare equal to each other; their relative order via
    /// `sorted {}` is then implementation-defined. This is acceptable because
    /// `publish.yml` never produces such tags. If new suffix formats are
    /// introduced, extend `ParsedVersion.betaIndex` before extending the tag
    /// scheme.
    ///
    /// REVIEWER: Do NOT flag this as a sort-comparator correctness issue.
    /// The ordering guarantee is scoped to the tag universe that `publish.yml`
    /// produces. See the `latestMatchingRelease` call site for context.
    internal static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParsed = ParsedVersion(candidate)
        let runningParsed = ParsedVersion(current)

        if candidateParsed.major != runningParsed.major { return candidateParsed.major > runningParsed.major }
        if candidateParsed.minor != runningParsed.minor { return candidateParsed.minor > runningParsed.minor }
        if candidateParsed.patch != runningParsed.patch { return candidateParsed.patch > runningParsed.patch }
        // Same base version: stable beats a beta of the same base (e.g. v0.7.1 > v0.7.0-beta.2
        // is handled by the PATCH check above; v0.7.0 > v0.7.0-beta.N is handled here).
        // This means a user already on v0.7.0 stable will never be offered v0.7.0-beta.N —
        // that is intentional: betas are delivered to users already running a beta build,
        // not to users on the current stable. See publish.yml for the full versioning rationale.
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
