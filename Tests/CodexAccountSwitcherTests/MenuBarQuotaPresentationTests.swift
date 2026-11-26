import Foundation
import SwitcherCore
import Testing

@testable import CodexAccountSwitcher

struct MenuBarQuotaPresentationTests {
  private let now = Date(timeIntervalSince1970: 1_795_651_200)

  @Test(arguments: [
    (1.0, "1m"), (59.0, "1m"), (60.0, "1m"), (61.0, "2m"),
    (3_599.0, "1h00"), (3_600.0, "1h00"), (3_601.0, "1h01"),
    (18_000.0, "5h00"), (86_400.0, "1d00"), (604_800.0, "7d00"),
  ])
  func countdownComesFromTheReportedDeadline(sample: (TimeInterval, String)) {
    #expect(
      MenuBarQuotaPresentation.countdown(until: now.addingTimeInterval(sample.0), now: now)
        == sample.1)
  }

  @Test func countdownDecreasesButNeverInventsANewBalanceAfterReset() {
    let deadline = now.addingTimeInterval(3_600)
    let initial = presentation(percent: 0, deadline: deadline, success: now, time: now)
    #expect(initial.percentage == "0%")
    #expect(initial.countdown == "1h00")
    let later = presentation(
      percent: 0, deadline: deadline, success: now, time: now.addingTimeInterval(61))
    #expect(later.countdown == "59m")
    let expired = presentation(percent: 0, deadline: deadline, success: deadline, time: deadline)
    #expect(expired.percentage == "--")
    #expect(expired.countdown == nil)
    #expect(expired.expired)
    let confirmed = presentation(
      percent: 100, deadline: deadline.addingTimeInterval(18_000), success: deadline, time: deadline
    )
    #expect(confirmed.percentage == "100%")
    #expect(confirmed.countdown == "5h00")
  }

  @Test func startupCacheAndFailedOrOldDataCannotRunALiveCountdown() {
    let deadline = now.addingTimeInterval(18_000)
    let cached = presentation(percent: 79, deadline: deadline, success: nil, time: now)
    #expect(cached.percentage == "79%*")
    #expect(cached.countdown == nil)
    let failed = presentation(
      percent: 79, deadline: deadline, success: now, time: now, loaded: false)
    #expect(failed.percentage == "79%*")
    #expect(failed.countdown == nil)
    let tooOld = presentation(
      percent: 79, deadline: deadline, success: now, time: now.addingTimeInterval(360))
    #expect(tooOld.percentage == "79%*")
    #expect(tooOld.countdown == nil)
    let refreshed = presentation(percent: 63, deadline: deadline, success: now, time: now)
    #expect(refreshed.percentage == "63%")
    #expect(refreshed.countdown == "5h00")
  }

  @Test func missingOrInvalidDeadlineDoesNotManufactureACountdown() {
    for deadline in [nil, now.addingTimeInterval(1e20)] {
      let result = presentation(percent: 79, deadline: deadline, success: now, time: now)
      #expect(result.percentage == "79%")
      #expect(result.countdown == nil)
    }
    let unknown = MenuBarQuotaPresentation(
      reading: nil, lastSuccess: now, isLoaded: true, now: now, language: .english)
    #expect(unknown.percentage == "--")
    #expect(unknown.countdown == nil)
    let invalidBalance = presentation(
      percent: 101, deadline: now.addingTimeInterval(3_600), success: now, time: now)
    #expect(invalidBalance.percentage == "--")
    #expect(invalidBalance.countdown == nil)
  }

  @Test func clockRollbackDoesNotTreatAFutureSampleAsFresh() {
    let result = presentation(
      percent: 79, deadline: now.addingTimeInterval(3_600), success: now,
      time: now.addingTimeInterval(-600))
    #expect(result.percentage == "79%*")
    #expect(result.countdown == nil)
  }

  private func presentation(
    percent: Int, deadline: Date?, success: Date?, time: Date, loaded: Bool = true
  ) -> MenuBarQuotaPresentation {
    .init(
      reading: .init(window: .fiveHour, percent: percent, resetsAt: deadline),
      lastSuccess: success, isLoaded: loaded, now: time, language: .simplifiedChinese)
  }
}
