import Foundation

// One quota interpretation on macOS and Windows.

public struct RateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int
    public let resetsAt: TimeInterval

    public init(usedPercent: Double, windowDurationMins: Int, resetsAt: TimeInterval) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public enum WeeklyUsageNormalizer {
    public static let fiveHourMinutes = 5 * 60
    public static let minimumWeeklyMinutes = 6 * 24 * 60
    public static let maximumWeeklyMinutes = 8 * 24 * 60

    public static func normalize(
        _ windows: [RateLimitWindow], resetCreditsRemaining: Int? = nil,
        resetCredits: [BankedResetCredit]? = nil
    ) throws -> WeeklyUsage {
        let weekly = windows
            .filter({ minimumWeeklyMinutes...maximumWeeklyMinutes ~= $0.windowDurationMins })
            .max(by: { $0.windowDurationMins < $1.windowDurationMins })
        let fiveHour = windows.first { $0.windowDurationMins == fiveHourMinutes }
        guard weekly != nil || fiveHour != nil else { throw CodexClientError.weeklyUsageUnavailable }

        return WeeklyUsage(
            remainingPercent: weekly.map { remainingPercent(for: $0) },
            resetsAt: weekly.map { Date(timeIntervalSince1970: $0.resetsAt) },
            fiveHourRemainingPercent: fiveHour.map { remainingPercent(for: $0) },
            fiveHourResetsAt: fiveHour.map { Date(timeIntervalSince1970: $0.resetsAt) },
            resetCreditsRemaining: resetCreditsRemaining,
            resetCredits: resetCredits
        )
    }

    private static func remainingPercent(for window: RateLimitWindow) -> Int {
        Int(min(100, max(0, (100 - window.usedPercent).rounded())))
    }
}
