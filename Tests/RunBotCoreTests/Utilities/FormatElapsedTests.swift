// FormatElapsedTests.swift
// RunBotCoreTests
import Foundation
import Testing

@testable import RunBotCore

// MARK: - FormatElapsedTests

@Suite("formatElapsed")
struct FormatElapsedTests {

  // MARK: - Sentinel values (nil start)

  /// `start: nil, isCompleted: false` → not yet started sentinel.
  @Test func nilStartNotCompletedReturnsZero() {
    #expect(formatElapsed(start: nil, end: nil, isCompleted: false) == "00:00")
  }

  /// `start: nil, isCompleted: true` → timing unavailable sentinel.
  @Test func nilStartCompletedReturnsDashes() {
    #expect(formatElapsed(start: nil, end: nil, isCompleted: true) == "--:--")
  }

  /// `end` is ignored when `start` is nil — still returns sentinel.
  @Test func nilStartWithEndIgnoresEnd() {
    let end = Date()
    #expect(formatElapsed(start: nil, end: end, isCompleted: false) == "00:00")
    #expect(formatElapsed(start: nil, end: end, isCompleted: true) == "--:--")
  }

  // MARK: - Known intervals

  /// 0 seconds elapsed → `"00:00"`.
  @Test func zeroSecondsReturnsZero() {
    let now = Date()
    #expect(formatElapsed(start: now, end: now, isCompleted: false) == "00:00")
  }

  /// 47 seconds elapsed → `"00:47"`.
  @Test func fortySevenSecondsFormatsCorrectly() {
    let start = Date()
    let end = start.addingTimeInterval(47)
    #expect(formatElapsed(start: start, end: end, isCompleted: false) == "00:47")
  }

  /// Exactly 1 minute → `"01:00"`.
  @Test func sixtySecondsFormatsAsOneMinute() {
    let start = Date()
    let end = start.addingTimeInterval(60)
    #expect(formatElapsed(start: start, end: end, isCompleted: false) == "01:00")
  }

  /// 2 minutes 47 seconds → `"02:47"`.
  @Test func twoMinutesFortySevenSecondsFormatsCorrectly() {
    let start = Date()
    let end = start.addingTimeInterval(167)
    #expect(formatElapsed(start: start, end: end, isCompleted: false) == "02:47")
  }

  /// 99 minutes 59 seconds — upper boundary of mm:ss display.
  @Test func ninetyNineMinutesFormatsCorrectly() {
    let start = Date()
    let end = start.addingTimeInterval(99 * 60 + 59)
    #expect(formatElapsed(start: start, end: end, isCompleted: false) == "99:59")
  }

  // MARK: - Negative interval guard

  /// When `end` is before `start` the result must be `"00:00"`, not negative.
  @Test func endBeforeStartClampsToZero() {
    let start = Date()
    let end = start.addingTimeInterval(-30)
    #expect(formatElapsed(start: start, end: end, isCompleted: false) == "00:00")
  }

  // MARK: - Live clock (end: nil)

  /// When `end` is nil the function uses `Date()` — assert the output matches
  /// the `mm:ss` format without pinning an exact value.
  @Test func nilEndUsesCurrentDateAndMatchesFormat() {
    let start = Date().addingTimeInterval(-5)
    let result = formatElapsed(start: start, end: nil, isCompleted: false)
    let isMMSS = result.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil
    #expect(isMMSS)
  }
}
