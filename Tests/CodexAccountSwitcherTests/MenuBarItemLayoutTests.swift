import AppKit
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct MenuBarItemLayoutTests {
    @Test(arguments: [0, 9, 79, 100])
    func fullPercentageFitsBesideTheIconWithoutSideMargins(percent: Int) throws {
        let item = MenuBarItemLayout(remainingPercent: percent)
        let bounds = NSRect(x: 0, y: 0, width: item.width, height: 24)
        let icon = item.iconFrame(in: bounds)
        let text = try #require(item.textFrame(in: bounds))

        #expect(item.text == "\(percent)%")
        #expect(icon.width == MenuBarItemLayout.iconSide)
        #expect(icon.minX == bounds.minX)
        #expect(text.minX == icon.maxX)
        #expect(bounds.maxX - text.maxX >= 0)
        #expect(bounds.maxX - text.maxX < 1)
    }

    @Test func undefinedAndHiddenPercentageKeepTheCompactIcon() {
        let unavailable = MenuBarItemLayout(remainingPercent: nil)
        let hidden = MenuBarItemLayout(remainingPercent: 100, showsPercentage: false)
        let bounds = NSRect(x: 0, y: 0, width: hidden.width, height: 24)

        #expect(hidden.textFrame(in: bounds) == nil)
        #expect(unavailable.width == hidden.width)
        #expect(hidden.width == ceil(MenuBarItemLayout.iconSide))
        #expect(hidden.iconFrame(in: bounds).minX == bounds.minX)
    }

    @Test(arguments: ["0%", "96%", "100%", "79%*", "--", "22:09", "11/28 22:09"])
    func eachPhaseUsesOnlyItsVisibleTextWidth(sample: String) throws {
        let layout = MenuBarItemLayout(text: sample)
        let bounds = NSRect(x: 0, y: 0, width: layout.width, height: 24)
        let icon = layout.iconFrame(in: bounds)
        let text = try #require(layout.textFrame(in: bounds))
        let measuredTextWidth = sample.size(withAttributes: layout.textAttributes).width

        #expect(layout.text == sample)
        #expect(layout.width == ceil(MenuBarItemLayout.iconSide + measuredTextWidth))
        #expect(icon.width == MenuBarItemLayout.iconSide)
        #expect(icon.minX == bounds.minX)
        #expect(text.minX == icon.maxX)
        #expect(bounds.maxX - text.maxX >= 0)
        #expect(bounds.maxX - text.maxX < 1)
    }

    @Test func rotationShrinksBackToThePercentageWithoutRememberingTheLongTime() {
        var layout = MenuBarItemLayout(text: "96%")
        let percentageWidth = layout.width
        layout = MenuBarItemLayout(text: "11/28 22:09")
        #expect(layout.width > percentageWidth)
        layout = MenuBarItemLayout(text: "96%")
        #expect(layout.width == percentageWidth)
        #expect(MenuBarItemLayout(text: "22:09").width < MenuBarItemLayout(text: "11/28 22:09").width)
        #expect(MenuBarItemLayout(text: "0%").width < MenuBarItemLayout(text: "100%").width)
    }

    @Test func extraHostSpaceDoesNotIntroduceALeadingMargin() throws {
        let layout = MenuBarItemLayout(text: "22:09")
        let bounds = NSRect(x: 5, y: 0, width: layout.width + 16, height: 24)
        let icon = layout.iconFrame(in: bounds)
        let text = try #require(layout.textFrame(in: bounds))
        #expect(icon.minX == bounds.minX)
        #expect(text.minX == icon.maxX)
    }
}
