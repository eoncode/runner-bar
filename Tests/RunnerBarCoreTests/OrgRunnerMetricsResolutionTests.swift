// OrgRunnerMetricsResolutionTests.swift
// RunnerBarCoreTests
//
// Regression tests for #1209 / #1192: org-scoped runners must receive CPU/MEM
// metrics even when the local .runner JSON AgentId differs from the GitHub API id.
import XCTest
@testable import RunnerBarCore

// MARK: - OrgRunnerMetricsResolutionTests

/// Tests that verify `RunnerModel.apiId` is preserved through `copying(…)` and
/// can be used to distinguish the GitHub REST API runner id from the local agentId.
///
/// The full `byApiId` lookup lives in `RunnerStore` (a `@MainActor` type in the
/// app target), which cannot be imported from a core-only unit-test target.
/// These tests therefore cover the data-model layer: that `apiId` round-trips
/// correctly and that a `RunnerModel` with mismatched `agentId` / `apiId` values
/// behaves as expected.
final class OrgRunnerMetricsResolutionTests: XCTestCase {

    // MARK: - Helpers

    private func makeOrgRunner(
        agentId: Int?,
        apiId: Int?,
        installPath: String? = "/tmp/org-runner", // NOSONAR — test-only fixture path
        metrics: RunnerMetrics? = nil
    ) -> RunnerModel {
        RunnerModel(
            runnerName: "org-runner-1",
            gitHubUrl: "https://github.com/myorg",
            agentId: agentId,
            apiId: apiId,
            workFolder: nil,
            installPath: installPath,
            isRunning: true,
            metrics: metrics
        )
    }

    // MARK: - apiId storage

    /// `apiId` set in init must be readable after construction.
    func testApiIdIsStoredOnInit() {
        let runner = makeOrgRunner(agentId: 100, apiId: 999)
        XCTAssertEqual(runner.apiId, 999)
        XCTAssertEqual(runner.agentId, 100)
    }

    /// `apiId` defaults to `nil` when omitted (preserves backward-compatible call sites).
    func testApiIdDefaultsToNilWhenOmitted() {
        let runner = RunnerModel(
            runnerName: "runner",
            gitHubUrl: nil,
            agentId: 42,
            workFolder: nil,
            installPath: nil,
            isRunning: false
        )
        XCTAssertNil(runner.apiId)
    }

    // MARK: - copying() round-trips

    /// `copying(…)` must preserve `apiId` when no apiId-related field is changed.
    func testCopyingPreservesApiId() {
        let original = makeOrgRunner(agentId: 100, apiId: 999)
        let copy = original.copying(isRunning: false)
        XCTAssertEqual(copy.apiId, 999, "copying() must forward apiId unchanged")
        XCTAssertEqual(copy.agentId, 100, "copying() must forward agentId unchanged")
    }

    /// `copying(metrics:)` must preserve both `agentId` and `apiId`.
    func testCopyingWithMetricsPreservesApiId() {
        let original = makeOrgRunner(agentId: 100, apiId: 999)
        let metrics = RunnerMetrics(cpu: 55.0, mem: 30.0)
        let copy = original.copying(metrics: .some(metrics))
        XCTAssertEqual(copy.apiId, 999)
        XCTAssertEqual(copy.agentId, 100)
        XCTAssertEqual(copy.metrics?.cpu, 55.0)
    }

    // MARK: - ID mismatch scenario (org runner)

    /// Simulates the org-runner mismatch: agentId (from .runner JSON) differs from
    /// apiId (from GitHub REST API). The model must hold both simultaneously so the
    /// caller can build both a `byId` and a `byApiId` lookup map.
    func testAgentIdAndApiIdCanDifferForOrgRunners() {
        // agentId=100 is what the local .runner JSON stores (AgentId field).
        // apiId=5001 is what the GitHub org-level runners API returns as `id`.
        let runner = makeOrgRunner(agentId: 100, apiId: 5001)
        XCTAssertNotEqual(runner.agentId, runner.apiId,
            "Org runners must be able to carry different agentId and apiId values")
    }

    /// A runner whose `apiId` matches the GitHub API runner id (5001) must be
    /// identifiable by that id even when `agentId` (100) does not match.
    func testApiIdMatchesGitHubApiRunnerIdForLookup() {
        let runner = makeOrgRunner(agentId: 100, apiId: 5001)
        // Simulate what buildInstallPathMap does: build a byApiId dict.
        let byApiId: [Int: String] = runner.apiId.map { [$0: runner.installPath!] } ?? [:]
        // Lookup using the GitHub API runner id (5001) must succeed.
        XCTAssertNotNil(byApiId[5001], "byApiId lookup with apiId=5001 must resolve installPath")
        // Lookup using the local agentId (100) would miss in this map — that is expected;
        // the existing byId map covers agentId-based lookups.
        XCTAssertNil(byApiId[100], "byApiId must NOT contain the agentId key — use byId for agentId lookups")
    }

    /// `nil` apiId must produce an empty `byApiId` map entry (no crash, no spurious hit).
    func testNilApiIdProducesNoByApiIdEntry() {
        let runner = makeOrgRunner(agentId: 100, apiId: nil)
        let byApiId: [Int: String] = runner.apiId.map { [$0: runner.installPath!] } ?? [:]
        XCTAssertTrue(byApiId.isEmpty, "nil apiId must not produce any byApiId entry")
    }

    // MARK: - Equatable

    /// Two runners with the same fields including matching apiId must be equal.
    func testEqualityWithMatchingApiId() {
        let a = makeOrgRunner(agentId: 100, apiId: 999)
        let b = makeOrgRunner(agentId: 100, apiId: 999)
        XCTAssertEqual(a, b)
    }

    /// Two runners that differ only in apiId must not be equal.
    func testInequalityWhenApiIdDiffers() {
        let a = makeOrgRunner(agentId: 100, apiId: 999)
        let b = makeOrgRunner(agentId: 100, apiId: 888)
        XCTAssertNotEqual(a, b, "Runners with different apiId values must not be equal")
    }
}
