import Foundation
import AppKit
import SwiftUI
import SwitcherCore
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct AccountRowTests {
    private let now = Date(timeIntervalSince1970: 1_795_651_200)
    private let language = AppLanguage.simplifiedChinese

    @Test(arguments: [AppLanguage.simplifiedChinese, .english, .italian])
    func cardsRenderLegiblyInBothAppearances(language: AppLanguage) throws {
        for dark in [false, true] {
            let content = VStack(spacing: 6) {
                ForEach(0..<3) { index in
                    AccountRow(
                        account: AccountProfile(
                            id: UUID(), displayName: "Account \(index)",
                            email: index == 2 ? "long-account-name@example.test" : "account\(index)@example.test",
                            accountID: "fixture-\(index)", createdAt: now
                        ),
                        usageState: index == 2 ? .unavailable("Fixture offline") : .loaded(
                            WeeklyUsage(
                                remainingPercent: index == 0 ? 84 : 100,
                                resetsAt: now.addingTimeInterval(7 * 86_400),
                                fiveHourRemainingPercent: index == 0 ? 0 : 99,
                                fiveHourResetsAt: now.addingTimeInterval(3_600), resetCreditsRemaining: 0
                            )
                        ), subscription: nil,
                        subscriptionState: index == 2 ? .idle : .loaded(LiveSubscription(
                            activeUntil: now.addingTimeInterval(5 * 86_400), planType: "pro", isActive: true,
                            willRenew: true, isDelinquent: false, fetchedAt: now
                        )),
                        isActive: index == 1, language: language, showsFiveHourUsage: true, now: now
                    )
                }
            }
            .padding(8)
            .frame(width: MenuBarPopover.contentWidth)
            .background(dark ? Color(white: 0.12) : Color(white: 0.98))
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(MenuBarPopover.contentWidth * 2))
            #expect(image.height > 350 && image.height < 1000)
            if let directory = ProcessInfo.processInfo.environment["GPTSWAP_UI_PREVIEW_DIR"] {
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = root.appending(path: "accounts-\(language.rawValue)-\(dark ? "dark" : "light").png")
                try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    .write(to: destination)
            }
        }
    }

    @Test func subscriptionDateAndResetCardBalanceHaveDistinctLabels() {
        let subscription = LiveSubscription(
            activeUntil: now.addingTimeInterval(86_400), planType: "pro", isActive: true,
            willRenew: nil, isDelinquent: nil, fetchedAt: now
        )
        let presentation = SubscriptionPresentation(state: .loaded(subscription), historical: nil)
        #expect(presentation.primaryText(at: now, language: language) { _ in "2026-12-01" }
                == "订阅有效至 2026-12-01")
        let resetDate = now.addingTimeInterval(3_600)
        let result = labels(count: 1, credits: [credit(expiry: resetDate)])
        #expect(result?.balance == "重置卡: 1")
        #expect(result?.expiry == "重置卡到期：\(Int(resetDate.timeIntervalSince1970))")
    }

    @Test func explicitZeroHidesExpiryEvenWhenCardDetailsRemain() {
        let result = labels(count: 0, credits: [credit(expiry: now.addingTimeInterval(3_600))])
        #expect(result?.balance == "重置卡: 0")
        #expect(result?.expiry == nil)
    }

    @Test func choosesEarliestKnownFutureExpiryAmongAvailableCodexCards() {
        let soon = now.addingTimeInterval(3_600)
        let cards = [
            credit(expiry: now.addingTimeInterval(7_200)),
            credit(expiry: nil),
            credit(expiry: now.addingTimeInterval(1), status: "redeemed"),
            credit(expiry: now.addingTimeInterval(5), type: "other"),
            credit(expiry: soon),
            credit(expiry: now),
        ]
        let result = labels(count: 3, credits: cards)
        #expect(result?.expiry == "重置卡最早已知到期：\(Int(soon.timeIntervalSince1970))")
    }

    @Test func missingMetadataDoesNotBorrowTheRateLimitResetTime() {
        let result = labels(count: 1, credits: nil)
        #expect(result?.expiry == "重置卡到期时间未提供")
        let undated = labels(count: 1, credits: [credit(expiry: nil)])
        #expect(undated?.expiry == "重置卡到期时间未提供")
        let unknown = labels(count: nil, credits: nil)
        #expect(unknown?.balance == "重置卡: 未知")
        #expect(unknown?.expiry == nil)
    }

    @Test func staleUsageLabelsTheCachedBalanceAndDoesNotShowExpiredDate() {
        let reading = usage(count: 1, credits: [credit(expiry: now.addingTimeInterval(-1))])
        let result = AccountRow.resetCardLabels(for: .stale(reading, "offline"), at: now, language: language) { _ in
            Issue.record("An expired card cannot supply a display date")
            return ""
        }
        #expect(result?.balance == "重置卡: 1 · 缓存")
        #expect(result?.expiry == "重置卡到期时间未提供")
    }

    @Test func usesDisplayTimeZoneAcrossMidnight() throws {
        let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-12-01T16:30:00Z"))
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let reading = usage(count: 1, credits: [credit(expiry: timestamp)])
        let result = AccountRow.resetCardLabels(
            for: .loaded(reading), at: now, language: language, formatTimestamp: formatter.string(from:)
        )
        #expect(result?.expiry == "重置卡到期：2026-12-02 00:30")
    }

    private func labels(count: Int?, credits: [BankedResetCredit]?) -> (balance: String, expiry: String?)? {
        AccountRow.resetCardLabels(for: .loaded(usage(count: count, credits: credits)), at: now, language: language) {
            String(Int($0.timeIntervalSince1970))
        }
    }

    private func usage(count: Int?, credits: [BankedResetCredit]?) -> WeeklyUsage {
        WeeklyUsage(remainingPercent: 50, resetsAt: now.addingTimeInterval(600),
                    resetCreditsRemaining: count, resetCredits: credits)
    }

    private func credit(expiry: Date?, status: String = "available", type: String = "codexRateLimits") -> BankedResetCredit {
        BankedResetCredit(id: UUID().uuidString, status: status, resetType: type, expiresAt: expiry)
    }
}
