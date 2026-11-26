import AppKit
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct MenuBarItemLayoutTests {
    @Test(arguments: [0, 9, 79, 100])
    func fullPercentageFitsBesideTheIconWithNarrowMargins(percent: Int) throws {
        let item = MenuBarItemLayout(remainingPercent: percent)
        let bounds = NSRect(x: 0, y: 0, width: item.width, height: 24)
        let icon = item.iconFrame(in: bounds)
        let text = try #require(item.textFrame(in: bounds))

        #expect(item.text == "\(percent)%")
        #expect(icon.width == MenuBarItemLayout.iconSide)
        #expect(icon.minX == MenuBarItemLayout.sidePadding)
        #expect(text.minX == icon.maxX)
        #expect(bounds.maxX - text.maxX >= MenuBarItemLayout.sidePadding)
        #expect(bounds.maxX - text.maxX < MenuBarItemLayout.sidePadding + 1)
    }

    @Test func undefinedAndHiddenPercentageKeepTheCompactIcon() {
        let unavailable = MenuBarItemLayout(remainingPercent: nil)
        let hidden = MenuBarItemLayout(remainingPercent: 100, showsPercentage: false)
        let bounds = NSRect(x: 0, y: 0, width: hidden.width, height: 24)

        #expect(hidden.textFrame(in: bounds) == nil)
        #expect(unavailable.width == hidden.width)
        #expect(hidden.width == ceil(MenuBarItemLayout.iconSide) + 2 * MenuBarItemLayout.sidePadding)
        #expect(hidden.iconFrame(in: bounds).minX == MenuBarItemLayout.sidePadding)
    }

    @Test func rotatedValuesReserveTheSameNarrowWidth() throws {
        let samples = ["0%", "79%", "100%", "59m", "4h59", "23h59", "6d23"]
        let reserved = ["100%*", "23h59"] + samples
        let widths = samples.map { MenuBarItemLayout(text: $0, reservedTexts: reserved).width }
        #expect(Set(widths).count == 1)
        for sample in samples {
            let layout = MenuBarItemLayout(text: sample, reservedTexts: reserved)
            let bounds = NSRect(x: 0, y: 0, width: layout.width, height: 24)
            let text = try #require(layout.textFrame(in: bounds))
            #expect(text.minX == layout.iconFrame(in: bounds).maxX)
            #expect(text.maxX <= bounds.maxX - MenuBarItemLayout.sidePadding)
        }
    }
}
