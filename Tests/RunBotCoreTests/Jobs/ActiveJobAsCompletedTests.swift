// ActiveJobAsCompletedTests.swift
// RunBotCoreTests
import Foundation
import Testing

@testable import RunBotCore

// MARK: - ActiveJob.asCompleted(at:)

@Suite("ActiveJob.asCompleted")
struct ActiveJobAsCompletedTests {

  private let fallback = Date(timeIntervalSince1970: 1_000)
  private let existing = Date(timeIntervalSince1970: 500)
  private let createdAtDate = Date(timeIntervalSince1970: 100)
  private let startedAtDate = Date(timeIntervalSince1970: 200)

  // MARK: Helpers

  private func makeJob(
    completedAt: Date? = nil,
    createdAt: Date? = nil,
    startedAt: Date? = nil,
    conclusion: JobConclusion? = nil,
    isDimmed: Bool = false,
    htmlUrl: String? = "https://example.com",
    runnerName: String? = "self-hosted",
    scope: String? = "org/repo"
  ) -> ActiveJob {
    ActiveJob(
      id: 42,
      name: "build",
      status: .inProgress,
      htmlUrl: htmlUrl,
      conclusion: conclusion,
      isDimmed: isDimmed,
      runnerName: runnerName,
      scope: scope,
      startedAt: startedAt,
      completedAt: completedAt,
      createdAt: createdAt
    )
  }

  // MARK: completedAt

  /// When the job already has a completedAt, asCompleted(at:) must ignore the fallback.
  @Test func asCompleted_existingCompletedAt_fallbackIgnored() {
    let job = makeJob(completedAt: existing)
    let result = job.asCompleted(at: fallback)
    #expect(result.completedAt == existing)
  }

  /// When completedAt is nil, asCompleted(at:) must use the fallback date.
  @Test func asCompleted_nilCompletedAt_fallbackUsed() {
    let job = makeJob(completedAt: nil)
    let result = job.asCompleted(at: fallback)
    #expect(result.completedAt == fallback)
  }

  // MARK: createdAt

  /// createdAt must be preserved verbatim so that elapsed display works for
  /// queued-only jobs (where startedAt is nil and createdAt is the only timing field).
  @Test func asCompleted_createdAtPreserved() {
    let job = makeJob(createdAt: createdAtDate)
    let result = job.asCompleted(at: fallback)
    #expect(result.createdAt == createdAtDate)
  }

  // MARK: status / isDimmed

  /// Confirm that status and isDimmed are always forced to their cache values.
  @Test func asCompleted_statusAndDimmedAlwaysSet() {
    let job = makeJob()
    let result = job.asCompleted(at: fallback)
    #expect(result.status == .completed)
    #expect(result.isDimmed)
  }

  /// Even when the source job was already dimmed, the result must still be dimmed.
  @Test func asCompleted_alreadyDimmed_remainsDimmed() {
    let job = makeJob(isDimmed: true)
    let result = job.asCompleted(at: fallback)
    #expect(result.isDimmed)
  }

  // MARK: conclusion

  /// When the source job has no conclusion (e.g. API timing race), asCompleted(at:)
  /// must fall back to .neutral — an informational, non-actionable conclusion that
  /// avoids the hook-firing and ⊘-icon side-effects of .cancelled.
  @Test func asCompleted_nilConclusion_defaultsToNeutral() {
    let job = makeJob(conclusion: nil)
    let result = job.asCompleted(at: fallback)
    #expect(result.conclusion == .neutral)
  }

  /// When the source job has a recorded conclusion, it must be preserved.
  @Test func asCompleted_existingConclusion_preserved() {
    let job = makeJob(conclusion: .success)
    let result = job.asCompleted(at: fallback)
    #expect(result.conclusion == .success)
  }

  // MARK: Idempotency

  /// Calling asCompleted(at:) on a job that is already .completed must produce
  /// the same result as calling it once — completedAt and conclusion are preserved,
  /// status and isDimmed remain forced to their cache values.
  @Test func asCompleted_idempotent_alreadyCompleted() {
    let once = makeJob(completedAt: existing, conclusion: .success)
      .asCompleted(at: fallback)
    let twice = once.asCompleted(at: fallback)
    #expect(twice.completedAt == existing)
    #expect(twice.conclusion == .success)
    #expect(twice.status == .completed)
    #expect(twice.isDimmed)
  }

  // MARK: Round-trip / field exhaustiveness

  /// All fields not explicitly overridden by asCompleted(at:) must be preserved
  /// verbatim. This acts as a guard against future ActiveJob fields being silently
  /// dropped if asCompleted(at:) is not updated alongside them.
  @Test func asCompleted_allOtherFieldsPreserved() {
    let step = JobStep(id: 1, name: "checkout", status: .completed, conclusion: .success, number: 1)
    let job = ActiveJob(
      id: 99,
      name: "deploy",
      status: .inProgress,
      htmlUrl: "https://github.com/org/repo/actions/runs/1",
      conclusion: .failure,
      isDimmed: false,
      runnerName: "my-runner",
      scope: "org/repo",
      startedAt: startedAtDate,
      completedAt: nil,
      createdAt: createdAtDate,
      steps: [step]
    )
    let result = job.asCompleted(at: fallback)
    #expect(result.id == 99)
    #expect(result.name == "deploy")
    #expect(result.htmlUrl == "https://github.com/org/repo/actions/runs/1")
    #expect(result.runnerName == "my-runner")
    #expect(result.scope == "org/repo")
    #expect(result.startedAt == startedAtDate)
    #expect(result.createdAt == createdAtDate)
    #expect(result.steps == [step])
    // Overridden fields
    #expect(result.status == .completed)
    #expect(result.isDimmed)
    #expect(result.completedAt == fallback)
    // conclusion is preserved verbatim when non-nil
    #expect(result.conclusion == .failure)
  }
}
