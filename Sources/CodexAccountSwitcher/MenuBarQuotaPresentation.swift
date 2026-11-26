import Foundation
import SwitcherCore

/// Formats reported quota data only; it never predicts a replenished balance.
struct MenuBarQuotaPresentation {
  static let freshnessLimit: TimeInterval = 360
  let percentage: String
  let countdown: String?
  let expired: Bool
  let tooltip: String
  let nextValidationAt: Date?

  init(
    reading: StatusBarQuotaReading?, lastSuccess: Date?, isLoaded: Bool, now: Date,
    language: AppLanguage
  ) {
    func text(_ key: String) -> String { L10n.string(key, language: language) }
    guard let reading, (0...100).contains(reading.percent) else {
      percentage = "--"
      countdown = nil
      expired = false
      tooltip = text("quota_no_data")
      nextValidationAt = nil
      return
    }
    let age = lastSuccess.map { now.timeIntervalSince($0) }
    let fresh = isLoaded && age.map { $0 >= -30 && $0 < Self.freshnessLimit } == true
    let deadline = reading.resetsAt.flatMap { date -> Date? in
      let interval = date.timeIntervalSince(now)
      return interval.isFinite && abs(interval) <= 366 * 86_400 ? date : nil
    }
    expired = deadline.map { $0 <= now } ?? false
    percentage = expired ? "--" : "\(reading.percent)%" + (fresh ? "" : "*")
    countdown = fresh && !expired ? deadline.flatMap { Self.countdown(until: $0, now: now) } : nil

    var details = [text(reading.window == .fiveHour ? "five_hour" : "weekly")]
    if expired {
      details.append(text("quota_reset_pending"))
    } else {
      details.append("\(reading.percent)% " + text("quota_remaining"))
    }
    if let deadline {
      let locale: Locale
      switch language {
      case .simplifiedChinese: locale = Locale(identifier: "zh_CN")
      case .english: locale = Locale(identifier: "en_US")
      case .italian: locale = Locale(identifier: "it_IT")
      case .system: locale = .autoupdatingCurrent
      }
      let timestamp = deadline.formatted(.dateTime.month().day().hour().minute().locale(locale))
      details.append(text("resets") + " " + timestamp)
    } else {
      details.append(text("quota_no_reset_time"))
    }
    if !fresh { details.append(text("quota_cached")) }
    if countdown != nil { details.append(text("quota_countdown_units")) }
    tooltip = details.joined(separator: "\n")

    var validations: [Date] = []
    if fresh, let lastSuccess {
      validations.append(lastSuccess.addingTimeInterval(Self.freshnessLimit))
    }
    if let deadline, deadline > now { validations.append(deadline) }
    nextValidationAt = validations.min()
  }

  static func countdown(until deadline: Date, now: Date) -> String? {
    let remaining = deadline.timeIntervalSince(now)
    // Reject implausible/overflowing values instead of clamping them into fake data.
    guard remaining.isFinite, remaining > 0, remaining <= 366 * 86_400 else { return nil }
    let minutes = Int(ceil(remaining / 60))
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 1_440 { return "\(minutes / 60)h" + String(format: "%02d", minutes % 60) }
    return "\(minutes / 1_440)d" + String(format: "%02d", minutes / 60 % 24)
  }
}
