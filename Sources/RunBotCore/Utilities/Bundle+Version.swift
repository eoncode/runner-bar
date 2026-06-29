import Foundation

extension Bundle {
    /// The full version string for this bundle, read from `RBVersionString`.
    ///
    /// `RBVersionString` is patched by `publish.yml` at build time and preserves
    /// pre-release suffixes (e.g. `0.7.0-beta.1`) that macOS strips from
    /// `CFBundleShortVersionString`. Falls back to `CFBundleShortVersionString`
    /// when running in development and `RBVersionString` is absent.
    public var rbVersionString: String {
        if let v = infoDictionary?["RBVersionString"] as? String, !v.isEmpty { return v }
        return infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Returns `true` when `version` is strictly newer than the running bundle's
    /// `RBVersionString`.
    ///
    /// Uses the same `ParsedVersion` comparison logic as `UpdateChecker` so beta
    /// ordering is consistent throughout the app.
    ///
    /// ```swift
    /// if Bundle.main.isOlderThan(version: release.version) { … }
    /// ```
    public func isOlderThan(version: String) -> Bool {
        UpdateChecker.isNewer(version, than: rbVersionString)
    }
}
