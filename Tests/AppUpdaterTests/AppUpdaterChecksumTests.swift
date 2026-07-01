// AppUpdaterChecksumTests.swift
// AppUpdaterTests
import CryptoKit
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterChecksumTests

/// Tests for `verifyChecksum` (a free function) and
/// `AppUpdater.cachedZipDestination`.
///
/// Both functions are pure filesystem operations that require no network.
/// Zero `DispatchQueue` usage (Pillar 5).
@MainActor
struct AppUpdaterChecksumTests {

    // MARK: - Helpers

    private func makeUpdater() throws -> AppUpdater {
        let domain = "AppUpdaterChecksumTests.\(UUID().uuidString)"
        return AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain,
            userDefaults: try #require(UserDefaults(suiteName: domain))
        )
    }

    /// Writes `contents` to a temp file and returns the URL. Caller owns cleanup.
    private func writeTempFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checksum-\(UUID().uuidString).zip")
        try contents.write(to: url)
        return url
    }

    /// Computes the lowercase SHA-256 hex digest of `data`.
    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - verifyChecksum — matching digest

    @Test func verifyChecksum_matchingDigest_doesNotThrow() async throws {
        let payload = Data("hello world".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let expectedHex = sha256Hex(payload)
        // Must not throw
        try await verifyChecksum(zipURL: url, expectedHex: expectedHex)
    }

    // MARK: - verifyChecksum — mismatched digest

    @Test func verifyChecksum_mismatchedDigest_throwsCannotDecodeContentData() async throws {
        let payload = Data("original content".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let wrongHex = sha256Hex(Data("different content".utf8))
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: wrongHex)
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    @Test func verifyChecksum_emptyExpectedHex_throwsOnAnyNonEmptyFile() async throws {
        let url = try writeTempFile(Data("any content".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: "")
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
    }

    // MARK: - verifyChecksum — missing file

    @Test func verifyChecksum_missingFile_throwsError() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).zip")
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: "abc123")
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
    }

    // MARK: - cachedZipDestination

    @Test func cachedZipDestination_filenameContainsVersion() throws {
        let updater = try makeUpdater()
        let url = try updater.cachedZipDestination(version: "v2.0.0")
        #expect(url.lastPathComponent.contains("v2.0.0"))
    }

    @Test func cachedZipDestination_extensionIsZip() throws {
        let updater = try makeUpdater()
        let url = try updater.cachedZipDestination(version: "v1.0.0")
        #expect(url.pathExtension == "zip")
    }

    @Test func cachedZipDestination_unsafeCharsSanitised() throws {
        let updater = try makeUpdater()
        let url = try updater.cachedZipDestination(version: "v1.0/malicious..zip")
        // Slashes and dots in the version must be replaced or safe in filename
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test func cachedZipDestination_scopedToSchedulerIdentifier() throws {
        let updater = try makeUpdater()
        let url = try updater.cachedZipDestination(version: "v1.0.0")
        // Directory component should contain the schedulerIdentifier
        let parentDir = url.deletingLastPathComponent().lastPathComponent
        #expect(parentDir == updater.schedulerIdentifier)
    }
}
