import AppKit
import SwiftUI
import SwitcherCore

/// A status button uses the exact width of its icon and measured percentage.
struct MenuBarItemLayout {
  static let iconSide: CGFloat = 17.5
  static let sidePadding: CGFloat = 1

  let text: String?
  private let reservedTexts: [String]

  init(remainingPercent: Int?, showsPercentage: Bool = true) {
    text = (showsPercentage ? remainingPercent : nil).map { "\($0)%" }
    reservedTexts = []
  }

  init(text: String?, reservedTexts: [String] = []) {
    self.text = text
    self.reservedTexts = reservedTexts
  }

  var textAttributes: [NSAttributedString.Key: Any] {
    [
      .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
      .foregroundColor: NSColor.labelColor,
    ]
  }

  var width: CGFloat {
    let candidates = text.map { [$0] + reservedTexts } ?? []
    let textWidth = candidates.map { $0.size(withAttributes: textAttributes).width }.max() ?? 0
    return ceil(Self.iconSide + textWidth) + 2 * Self.sidePadding
  }

  func iconFrame(in bounds: NSRect) -> NSRect {
    NSRect(
      x: bounds.midX - width / 2 + Self.sidePadding,
      y: bounds.midY - Self.iconSide / 2,
      width: Self.iconSide,
      height: Self.iconSide
    )
  }

  func textFrame(in bounds: NSRect) -> NSRect? {
    guard let text else { return nil }
    let size = text.size(withAttributes: textAttributes)
    return NSRect(
      x: iconFrame(in: bounds).maxX, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height)
  }
}

@MainActor
final class MenuBarItemController: NSObject, NSPopoverDelegate {
  private let model: AppModel
  private let updater: AppUpdater
  private let item: NSStatusItem
  private let contentView = MenuBarItemContentView()
  private let popover = NSPopover()
  private var localClickMonitor: Any?
  private var globalClickMonitor: Any?
  private var displayTask: Task<Void, Never>?
  private var showsCountdown = false
  private var cycleKey: QuotaCycleKey?
  private var lastExpiredRefreshKey: QuotaCycleKey?

  private struct QuotaCycleKey: Equatable {
    let accountID: UUID
    let window: StatusBarUsageWindow
    let resetsAt: Date?
  }

  init(model: AppModel, updater: AppUpdater) {
    self.model = model
    self.updater = updater
    item = NSStatusBar.system.statusItem(withLength: MenuBarItemLayout(remainingPercent: nil).width)
    super.init()

    if let button = item.button {
      button.target = self
      button.action = #selector(togglePopover(_:))
      button.setAccessibilityLabel("gptswap")
      contentView.frame = button.bounds
      contentView.autoresizingMask = [.width, .height]
      button.addSubview(contentView)
    }
    popover.behavior = .transient
    popover.delegate = self
    refresh()
  }

  func refresh() {
    let now = Date()
    let reading = model.activeIdentityConfirmed ? model.activeQuotaReading : nil
    let key = model.activeAccountID.flatMap { id in
      reading.map { QuotaCycleKey(accountID: id, window: $0.window, resetsAt: $0.resetsAt) }
    }
    if cycleKey != key {
      cycleKey = key
      showsCountdown = false
      lastExpiredRefreshKey = nil
    }
    let state = model.activeAccountID.flatMap { model.usageStates[$0] }
    let isLoaded: Bool
    if case .loaded = state { isLoaded = true } else { isLoaded = false }
    let lastSuccess = model.activeAccountID.flatMap { model.usageUpdatedAt[$0] }
    let display = MenuBarQuotaPresentation(
      reading: reading, lastSuccess: lastSuccess, isLoaded: isLoaded, now: now,
      language: model.settings.language
    )
    let visible = model.settings.showsMenuBarPercentage
    let rotates = visible && model.settings.rotatesMenuBarQuota && display.countdown != nil
    if !rotates { showsCountdown = false }
    let text = showsCountdown ? display.countdown : display.percentage
    // These strings measure a stable width only; displayed values always come from real data.
    let reserved = rotates ? ["100%*", "23h59", display.percentage, display.countdown ?? ""] : []
    let label = MenuBarItemLayout(text: visible ? text : nil, reservedTexts: reserved)
    if label.text != contentView.label.text || label.width != contentView.label.width {
      contentView.label = label
      item.length = label.width
    }
    item.button?.toolTip = display.tooltip
    item.button?.setAccessibilityValue(display.tooltip)

    displayTask?.cancel()
    displayTask = nil
    var delay: TimeInterval? = rotates ? (showsCountdown ? 2 : 8) : nil
    if visible, let validation = display.nextValidationAt {
      let untilValidation = max(0.2, validation.timeIntervalSince(now))
      delay = min(delay ?? untilValidation, untilValidation)
    }
    if let delay {
      displayTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard !Task.isCancelled, let self else { return }
        if rotates { self.showsCountdown.toggle() }
        self.refresh()
      }
    }
    if visible, display.expired, let key, lastExpiredRefreshKey != key {
      lastExpiredRefreshKey = key
      model.refreshWeeklyUsage()
    }
  }

  func stop() {
    displayTask?.cancel()
    displayTask = nil
    stopOutsideClickMonitoring()
  }

  @objc private func togglePopover(_ button: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(button)
      return
    }

    let controller = NSHostingController(rootView: MenuBarPopover(model: model, updater: updater))
    controller.sizingOptions.insert(.preferredContentSize)
    popover.contentViewController = controller
    popover.contentSize = controller.view.fittingSize
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    if popover.isShown { startOutsideClickMonitoring() }
    button.highlight(popover.isShown)
  }

  private func startOutsideClickMonitoring() {
    stopOutsideClickMonitoring()
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, self.popover.isShown else { return }
        let insidePopover = event.window === self.popover.contentViewController?.view.window
        // Let the status button handle its own toggle without closing and reopening.
        let insideButton =
          self.item.button.map { button in
            guard event.window === button.window else { return false }
            return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
          } ?? false
        if !insidePopover && !insideButton { self.popover.performClose(nil) }
      }
      return event
    }
    globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
      Task { @MainActor in self?.popover.performClose(nil) }
    }
  }

  private func stopOutsideClickMonitoring() {
    if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
    localClickMonitor = nil
    globalClickMonitor = nil
  }

  func popoverDidClose(_ notification: Notification) {
    stopOutsideClickMonitoring()
    item.button?.highlight(false)
    // Each open already creates a fresh controller. Release the hidden SwiftUI tree now.
    popover.contentViewController = nil
  }
}

@MainActor
private final class MenuBarItemContentView: NSView {
  var label = MenuBarItemLayout(remainingPercent: nil) {
    didSet { needsDisplay = true }
  }

  private static let icon: NSImage = {
    let name = "CodexAccountSwitcher_CodexAccountSwitcher.bundle"
    let resources = [Bundle.main.resourceURL, Bundle.main.bundleURL]
      .compactMap { $0 }
      .map { $0.appending(path: name) }
      .compactMap { Bundle(url: $0) }
      .first
    guard let url = resources?.url(forResource: "menu-icon-template", withExtension: "png"),
      let image = NSImage(contentsOf: url)
    else {
      preconditionFailure("Missing menu-icon-template.png")
    }
    image.isTemplate = true
    return image
  }()

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      if let mask = Self.icon.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let context = NSGraphicsContext.current?.cgContext
      {
        let frame = label.iconFrame(in: bounds)
        context.saveGState()
        context.clip(to: frame, mask: mask)
        context.setFillColor(NSColor.labelColor.cgColor)
        context.fill(frame)
        context.restoreGState()
      }
      if let text = label.text, let frame = label.textFrame(in: bounds) {
        text.draw(at: frame.origin, withAttributes: label.textAttributes)
      }
    }
  }
}
