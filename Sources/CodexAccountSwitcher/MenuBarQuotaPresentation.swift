import Foundation
import SwitcherCore

/// Formats reported quota data only; it never predicts a replenished balance.
struct MenuBarQuotaPresentation {
  static let freshnessLimit: TimeInterval = 360
  let percentage: String
  let resetTime: String?
  let expired: Bool
  let tooltip: String
  let nextValidationAt: Date?

  init(
    reading: StatusBarQuotaReading?, lastSuccess: Date?, isLoaded: Bool, now: Date,
    language: AppLanguage, timeZone: TimeZone = .autoupdatingCurrent
  ) {
    func text(_ key: String) -> String { L10n.string(key, language: language) }
    guard let reading, (0...100).contains(reading.percent) else {
      percentage = "--"
      resetTime = nil
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
    resetTime = fresh && !expired
      ? deadline.flatMap { Self.resetTimestamp(for: $0, now: now, timeZone: timeZone) } : nil

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
      let timestamp = deadline.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
      details.append(text("resets") + " " + timestamp)
    } else {
      details.append(text("quota_no_reset_time"))
    }
    if !fresh { details.append(text("quota_cached")) }
    if resetTime != nil { details.append(text("quota_reset_time_format")) }
    tooltip = details.joined(separator: "\n")

    var validations: [Date] = []
    if fresh, let lastSuccess {
      validations.append(lastSuccess.addingTimeInterval(Self.freshnessLimit))
    }
    if let deadline, deadline > now { validations.append(deadline) }
    nextValidationAt = validations.min()
  }

  static func resetTimestamp(
    for deadline: Date, now: Date, timeZone: TimeZone = .autoupdatingCurrent
  ) -> String? {
    let remaining = deadline.timeIntervalSince(now)
    // Reject implausible/overflowing values instead of clamping them into fake data.
    guard remaining.isFinite, remaining > 0, remaining <= 366 * 86_400 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.month, .day, .hour, .minute], from: deadline)
    guard let month = components.month, let day = components.day,
      let hour = components.hour, let minute = components.minute else { return nil }
    let clock = String(format: "%02d:%02d", hour, minute)
    if calendar.isDate(deadline, inSameDayAs: now) { return clock }
    return String(format: "%02d/%02d %@", month, day, clock)
  }
}
