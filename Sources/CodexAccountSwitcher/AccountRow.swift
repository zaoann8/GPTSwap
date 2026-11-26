import SwiftUI
import SwitcherCore

struct AccountRow: View {
  private static let isoDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  let account: AccountProfile
  let usageState: UsageViewState
  let subscription: SubscriptionSnapshot?
  let subscriptionState: LiveSubscriptionState
  let isActive: Bool
  let language: AppLanguage
  let showsFiveHourUsage: Bool
  var now: Date = Date()
  @ViewState private var isHovering = false

  var body: some View {
    let title = account.preferredTitle
    let presentation = SubscriptionPresentation(state: subscriptionState, historical: subscription)
    let subscriptionDetail = presentation.detailText(
      at: now,
      language: language,
      formatDay: subscriptionDate,
      formatTimestamp: subscriptionTime
    )
    let resetCards = Self.resetCardLabels(
      for: usageState, at: now, language: language, formatTimestamp: subscriptionTime
    )
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(account.initials)
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .frame(width: 24, height: 24)
          .background(Color.primary.opacity(0.08), in: Circle())
        Text(verbatim: title)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.tail)
          .help(title)
        Spacer(minLength: 4)
        if let plan = presentation.planType {
          Text(plan.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        if isActive {
          Label(text("active"), systemImage: "checkmark.circle.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .fixedSize()
        }
        if let message = usageState.refreshError {
          warningIcon(message)
        }
      }

      if let email = account.labeledEmail {
        Text(verbatim: email)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(email)
      }

      usageContent
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(presentation.primaryText(at: now, language: language, formatDay: subscriptionDate))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(presentation.needsUpdate(at: now) ? Color.orange : Color.primary)
          .help(subscriptionDetail)
          .accessibilityHint(subscriptionDetail)
        if let resetCards {
          Text(resetCards.balance)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .font(.system(size: 11.5, weight: .medium).monospacedDigit())
      .foregroundStyle(.secondary)

      if let expiry = resetCards?.expiry {
        Text(expiry)
          .font(.system(size: 11.5).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .background(
      rowBackground,
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .strokeBorder(isActive ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
    }
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }

  @ViewBuilder
  private var usageContent: some View {
    switch usageState {
    case .idle:
      Text("\(text("usage")) -")
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    case let .unavailable(message):
      Text(text("usage_unavailable"))
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .help(message)
    case let .loaded(usage), let .stale(usage, _):
      if showsFiveHourUsage {
        expandedUsageContent(usage)
      } else if let remaining = usage.remainingPercent {
        limitRow(
          title: text("weekly"), remainingPercent: remaining, resetsAt: usage.resetsAt,
          includesDate: true)
      } else if let remaining = usage.fiveHourRemainingPercent {
        limitRow(
          title: text("five_hour"), remainingPercent: remaining, resetsAt: usage.fiveHourResetsAt,
          includesDate: false)
      } else {
        Text(text("usage_unavailable"))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func expandedUsageContent(_ usage: WeeklyUsage) -> some View {
    VStack(spacing: 6) {
      if let remaining = usage.fiveHourRemainingPercent {
        limitRow(
          title: text("five_hour"),
          remainingPercent: remaining,
          resetsAt: usage.fiveHourResetsAt,
          includesDate: false
        )
      }
      if let remaining = usage.remainingPercent {
        limitRow(
          title: text("weekly"),
          remainingPercent: remaining,
          resetsAt: usage.resetsAt,
          includesDate: true
        )
      }
    }
  }

  private func limitRow(
    title: String,
    remainingPercent: Int,
    resetsAt: Date?,
    includesDate: Bool
  ) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.primary)
        .frame(width: 42, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)

      UsageBar(remainingPercent: remainingPercent)
        .accessibilityLabel(title)
        .accessibilityValue("\(remainingPercent)\(text("left"))")

      Text("\(remainingPercent)%")
        .font(.system(size: 15, weight: .semibold).monospacedDigit())
        .foregroundStyle(remainingPercent <= 10 ? Color.red : Color.primary)
        .frame(width: 46, alignment: .trailing)

      Text(
        resetsAt.map {
          resetText(
            for: $0, includesDate: includesDate || !Calendar.current.isDate($0, inSameDayAs: now))
        } ?? "—"
      )
      .font(.system(size: 11).monospacedDigit())
      .foregroundStyle(Color.primary.opacity(0.75))
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 128, alignment: .trailing)
    }
  }

  private var rowBackground: Color {
    if isActive {
      return Color.accentColor.opacity(0.10)
    }
    return Color.primary.opacity(isHovering ? 0.055 : 0)
  }

  private func warningIcon(_ message: String) -> some View {
    Image(systemName: "exclamationmark.triangle.fill")
      .font(.system(size: 9))
      .foregroundStyle(.orange)
      .help(message)
      .accessibilityLabel(message)
  }

  private func text(_ key: String) -> String {
    L10n.string(key, language: language)
  }

  static func resetCardLabels(
    for usageState: UsageViewState,
    at now: Date,
    language: AppLanguage,
    formatTimestamp: (Date) -> String
  ) -> (balance: String, expiry: String?)? {
    guard let usage = usageState.displayedUsage else { return nil }

    let count =
      usage.resetCreditsRemaining.map(String.init) ?? L10n.string("unknown", language: language)
    let label = L10n.string("reset_credits", language: language)
    var balance = "\(label): \(count)"
    if case .stale = usageState {
      balance += " · " + L10n.string("reset_card_cached", language: language)
    }
    // An explicit zero takes precedence over any stale card details.
    guard usage.resetCreditsRemaining != 0 else { return (balance, nil) }

    let available = (usage.resetCredits ?? []).filter { credit in
      credit.status == "available" && credit.resetType == "codexRateLimits"
        && (credit.expiresAt.map { $0 > now } ?? true)
    }
    if let earliest = available.compactMap(\.expiresAt).min() {
      let hasMultipleCards = available.count > 1 || (usage.resetCreditsRemaining ?? 0) > 1
      let key = hasMultipleCards ? "reset_card_earliest_expiry" : "reset_card_expiry"
      return (
        balance, String(format: L10n.string(key, language: language), formatTimestamp(earliest))
      )
    }
    if !available.isEmpty || (usage.resetCreditsRemaining ?? 0) > 0 {
      return (balance, L10n.string("reset_card_expiry_unknown", language: language))
    }
    return (balance, nil)
  }

  private var dateLocale: Locale {
    switch language {
    case .simplifiedChinese:
      Locale(identifier: "zh_CN")
    case .english:
      Locale(identifier: "en_US")
    case .italian:
      Locale(identifier: "it_IT")
    case .system:
      switch L10n.systemLanguage(
        for: Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier)
      {
      case .simplifiedChinese: Locale(identifier: "zh_CN")
      case .italian: Locale(identifier: "it_IT")
      case .english, .system: .autoupdatingCurrent
      }
    }
  }

  private func subscriptionDate(_ date: Date) -> String {
    Self.isoDayFormatter.string(from: date)
  }

  private func subscriptionTime(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute().locale(dateLocale))
  }

  private func resetText(for resetsAt: Date, includesDate: Bool) -> String {
    let date =
      includesDate
      ? resetsAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(dateLocale))
      : resetsAt.formatted(.dateTime.hour().minute().locale(dateLocale))
    return "\(text("resets")) \(date)"
  }
}

private struct UsageBar: View {
  let remainingPercent: Int

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.primary.opacity(0.12))
        Capsule()
          .fill(remainingPercent <= 10 ? Color.red : Color.accentColor)
          .frame(width: geometry.size.width * fraction)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 5)
  }

  private var fraction: CGFloat {
    CGFloat(min(max(remainingPercent, 0), 100)) / 100
  }
}
