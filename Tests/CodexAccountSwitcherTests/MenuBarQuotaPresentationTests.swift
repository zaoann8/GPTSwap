import Foundation
import SwitcherCore
import Testing

@testable import CodexAccountSwitcher

struct MenuBarQuotaPresentationTests {
  private let now = Date(timeIntervalSince1970: 1_795_780_800) // 2026-11-27 20:00 in Shanghai
  private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

  @Test(arguments: [
    ("2026-11-27T14:09:00Z", "22:09"),
    ("2026-11-27T14:09:59Z", "22:09"),
    ("2026-11-28T14:09:00Z", "11/28 22:09"),
    ("2026-12-04T14:09:00Z", "12/04 22:09"),
  ])
  func resetTimeUsesTheReportedLocalDate(sample: (String, String)) throws {
    let deadline = try #require(ISO8601DateFormatter().date(from: sample.0))
    let result = presentation(percent: 79, deadline: deadline, success: now, time: now)
    #expect(result.resetTime == sample.1)
  }

  @Test func timeStaysAbsoluteAndNeverInventsANewBalanceAfterReset() {
    let deadline = now.addingTimeInterval(3_600)
    let initial = presentation(percent: 0, deadline: deadline, success: now, time: now)
    #expect(initial.percentage == "0%")
    #expect(initial.resetTime == "21:00")
    let later = presentation(
      percent: 0, deadline: deadline, success: now, time: now.addingTimeInterval(61))
    #expect(later.resetTime == initial.resetTime)
    let expired = presentation(percent: 0, deadline: deadline, success: deadline, time: deadline)
    #expect(expired.percentage == "--")
    #expect(expired.resetTime == nil)
    #expect(expired.expired)
    let confirmed = presentation(
      percent: 100, deadline: deadline.addingTimeInterval(18_000), success: deadline, time: deadline)
    #expect(confirmed.percentage == "100%")
    #expect(confirmed.resetTime == "11/28 02:00")
  }

  @Test func startupCacheAndFailedOrOldDataCannotPresentAConfirmedResetTime() {
    let deadline = now.addingTimeInterval(3_600)
    let cached = presentation(percent: 79, deadline: deadline, success: nil, time: now)
    #expect(cached.percentage == "79%*")
    #expect(cached.resetTime == nil)
    let failed = presentation(
      percent: 79, deadline: deadline, success: now, time: now, loaded: false)
    #expect(failed.percentage == "79%*")
    #expect(failed.resetTime == nil)
    let tooOld = presentation(
      percent: 79, deadline: deadline, success: now, time: now.addingTimeInterval(360))
    #expect(tooOld.percentage == "79%*")
    #expect(tooOld.resetTime == nil)
    let refreshed = presentation(percent: 63, deadline: deadline, success: now, time: now)
    #expect(refreshed.percentage == "63%")
    #expect(refreshed.resetTime == "21:00")
  }

  @Test func missingOrInvalidDeadlineDoesNotManufactureATime() {
    for deadline in [nil, now.addingTimeInterval(1e20), Date(timeIntervalSince1970: .nan)] {
      let result = presentation(percent: 79, deadline: deadline, success: now, time: now)
      #expect(result.percentage == "79%")
      #expect(result.resetTime == nil)
    }
    let unknown = MenuBarQuotaPresentation(
      reading: nil, lastSuccess: now, isLoaded: true, now: now, language: .english)
    #expect(unknown.percentage == "--")
    #expect(unknown.resetTime == nil)
    let invalidBalance = presentation(
      percent: 101, deadline: now.addingTimeInterval(3_600), success: now, time: now)
    #expect(invalidBalance.percentage == "--")
    #expect(invalidBalance.resetTime == nil)
  }

  @Test func clockRollbackDoesNotTreatAFutureSampleAsFresh() {
    let result = presentation(
      percent: 79, deadline: now.addingTimeInterval(3_600), success: now,
      time: now.addingTimeInterval(-600))
    #expect(result.percentage == "79%*")
    #expect(result.resetTime == nil)
  }

  @Test func midnightChangesTheDatePrefixWithoutChangingTheDeadline() throws {
    let beforeMidnight = try date("2026-11-27T15:59:30Z")
    let afterMidnight = beforeMidnight.addingTimeInterval(60)
    let deadline = try date("2026-11-27T16:09:00Z")
    let before = presentation(percent: 79, deadline: deadline, success: beforeMidnight, time: beforeMidnight)
    let after = presentation(percent: 79, deadline: deadline, success: beforeMidnight, time: afterMidnight)
    #expect(before.resetTime == "11/28 00:09")
    #expect(after.resetTime == "00:09")
    #expect(before.nextValidationAt == after.nextValidationAt)
  }

  @Test func yearBoundaryIncludesTheCorrectMonthAndDay() throws {
    let current = try date("2026-12-31T15:00:00Z")
    let result = presentation(
      percent: 79, deadline: try date("2027-01-01T14:09:00Z"), success: current, time: current)
    #expect(result.resetTime == "01/01 22:09")
  }

  @Test func datePrefixAndClockUseTheSameLocalTimeZone() throws {
    let deadline = try date("2026-11-27T23:00:00Z")
    let reading = StatusBarQuotaReading(window: .weekly, percent: 79, resetsAt: deadline)
    let shanghai = MenuBarQuotaPresentation(
      reading: reading, lastSuccess: now, isLoaded: true, now: now,
      language: .english, timeZone: timeZone)
    let losAngeles = MenuBarQuotaPresentation(
      reading: reading, lastSuccess: now, isLoaded: true, now: now,
      language: .english, timeZone: try #require(TimeZone(identifier: "America/Los_Angeles")))
    #expect(shanghai.resetTime == "11/28 07:00")
    #expect(losAngeles.resetTime == "15:00")
  }

  @Test func daylightSavingUsesTheReportedInstantRatherThanAddingWallClockHours() throws {
    let current = try date("2026-11-01T07:30:00Z")
    let result = MenuBarQuotaPresentation(
      reading: .init(window: .fiveHour, percent: 79, resetsAt: try date("2026-11-01T09:09:00Z")),
      lastSuccess: current, isLoaded: true, now: current, language: .english,
      timeZone: try #require(TimeZone(identifier: "America/Los_Angeles")))
    #expect(result.resetTime == "01:09")
  }

  private func date(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
  }

  private func presentation(
    percent: Int, deadline: Date?, success: Date?, time: Date, loaded: Bool = true
  ) -> MenuBarQuotaPresentation {
    .init(
      reading: .init(window: .fiveHour, percent: percent, resetsAt: deadline),
      lastSuccess: success, isLoaded: loaded, now: time, language: .simplifiedChinese,
      timeZone: timeZone)
  }
}
