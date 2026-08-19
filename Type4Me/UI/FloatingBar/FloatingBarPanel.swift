import AppKit
import ApplicationServices
import SwiftUI

// MARK: - NSPanel Subclass

/// Non-activating floating panel that never steals focus from the target app.
/// Forces dark appearance for the sci-fi themed floating bar.
final class FloatingBarPanel: NSPanel {

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    level = .floating
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isMovableByWindowBackground = false
    hidesOnDeactivate = false
    animationBehavior = .utilityWindow
    appearance = NSAppearance(named: .darkAqua)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func preferredScreen() -> NSScreen? {
    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
      if let focusedBounds = Self.focusedWindowBounds(for: pid),
        let screen = Self.screen(containingQuartzBounds: focusedBounds)
      {
        return screen
      }

      if let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]],
        let frontWindow = info.lazy
          .filter({ ($0[kCGWindowOwnerPID as String] as? pid_t) == pid })
          .filter({ ($0[kCGWindowLayer as String] as? Int) == 0 })
          .compactMap({ entry -> CGRect? in
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any] else {
              return nil
            }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
          })
          .first,
        let screen = Self.screen(containingQuartzBounds: frontWindow)
      {
        return screen
      }
    }

    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
  }

  private static func focusedWindowBounds(for pid: pid_t) -> CGRect? {
    let application = AXUIElementCreateApplication(pid)
    var focusedWindowValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindowValue
      ) == .success,
      let focusedWindowValue,
      CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID()
    else { return nil }
    let focusedWindow = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)

    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focusedWindow,
        kAXPositionAttribute as CFString,
        &positionValue
      ) == .success,
      AXUIElementCopyAttributeValue(
        focusedWindow,
        kAXSizeAttribute as CFString,
        &sizeValue
      ) == .success,
      let positionValue,
      let sizeValue,
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }

    let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
    let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionAXValue, .cgPoint, &origin),
      AXValueGetValue(sizeAXValue, .cgSize, &size),
      size.width > 1,
      size.height > 1
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  private static func screen(containingQuartzBounds bounds: CGRect) -> NSScreen? {
    let primaryHeight =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height
      ?? 0
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    return NSScreen.screens.first { screen in
      let frame = screen.frame
      let quartzFrame = CGRect(
        x: frame.minX,
        y: primaryHeight - frame.maxY,
        width: frame.width,
        height: frame.height
      )
      return quartzFrame.contains(center)
    }
  }

  func positionAtTopCenter(in screen: NSScreen, size: NSSize) {
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.maxY - TF.topTranscriptPanelTopOffset - size.height
    )
    setFrame(NSRect(origin: origin, size: size), display: false)
  }
}

/// Dedicated bottom-screen panel for recording feedback and immediate cancellation.
/// Kept separate from the transcript panel so either surface can move or hide independently.
final class ScreenBottomIndicatorPanel: NSPanel {
  init() {
    let size = NSSize(
      width: TF.screenBottomIndicatorWidth,
      height: TF.screenBottomIndicatorHeight
    )
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    identifier = NSUserInterfaceItemIdentifier("Type4Me.ScreenBottomRecordingIndicator")
    isFloatingPanel = true
    level = .floating
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isMovableByWindowBackground = false
    ignoresMouseEvents = false
    hidesOnDeactivate = false
    animationBehavior = .none
    appearance = NSAppearance(named: .darkAqua)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown {
      performDrag(with: event)
      return
    }
    super.sendEvent(event)
  }

  func positionAtBottomCenter(in screen: NSScreen) {
    let visible = screen.visibleFrame
    let size = frame.size
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.minY + TF.barBottomOffset
    )
    setFrame(NSRect(origin: origin, size: size), display: false)
  }
}

// MARK: - Controller

/// Manages the floating bar panel lifecycle.
/// All visual styling is handled in SwiftUI (FloatingBarView).
@MainActor
final class FloatingBarController {
  private let panel: FloatingBarPanel
  private let screenBottomIndicatorPanel: ScreenBottomIndicatorPanel
  private let state: AppState
  private var hosting: NSHostingView<FloatingBarView<AppState>>!
  private var screenBottomIndicatorHosting: NSHostingView<ScreenBottomRecordingIndicator>!
  private var targetScreen: NSScreen?
  private var expandedPanelWidth = TF.topTranscriptPanelMaxWidth
  private var maximumPanelHeight: CGFloat = 500
  private var panelGeneration = 0
  private var pendingResize: DispatchWorkItem?
  private var lastPanelCollapsed = false
  private var recenterPanelOnNextResize = false
  private var collapsedPanelOrigin: NSPoint?
  /// Last position of the bottom indicator, keyed by display ID. The indicator
  /// always appears on the target (frontmost) screen; a position is only
  /// restored when recording again on the same display where the user left it.
  private var screenBottomIndicatorOrigins: [NSNumber: NSPoint] = [:]

  init(state: AppState) {
    self.state = state
    panel = FloatingBarPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480))
    screenBottomIndicatorPanel = ScreenBottomIndicatorPanel()
    lastPanelCollapsed = state.isTranscriptPanelCollapsed
    panel.isMovableByWindowBackground = state.isTranscriptPanelCollapsed

    configureForCurrentTarget()
    hosting = NSHostingView(rootView: makeRootView())
    // The controller is the only owner of NSWindow geometry. SwiftUI reports
    // its natural card size, then resizing is deferred out of the current
    // AppKit display cycle to avoid NSHostingView constraint recursion.
    hosting.sizingOptions = []
    hosting.layer?.backgroundColor = .clear
    hosting.autoresizingMask = [.width, .height]
    panel.contentView = hosting

    screenBottomIndicatorHosting = NSHostingView(
      rootView: ScreenBottomRecordingIndicator(
        meter: state.audioLevel,
        modeName: state.currentMode.name
      )
    )
    screenBottomIndicatorHosting.sizingOptions = []
    screenBottomIndicatorHosting.wantsLayer = true
    screenBottomIndicatorHosting.layer?.backgroundColor = NSColor.clear.cgColor
    screenBottomIndicatorHosting.layer?.isOpaque = false
    screenBottomIndicatorHosting.frame = NSRect(
      origin: .zero,
      size: NSSize(
        width: TF.screenBottomIndicatorWidth,
        height: TF.screenBottomIndicatorHeight
      )
    )
    screenBottomIndicatorHosting.autoresizingMask = [.width, .height]
    screenBottomIndicatorPanel.contentView = screenBottomIndicatorHosting

    let initialSize = maximumSize
    hosting.frame = NSRect(origin: .zero, size: initialSize)
    if let targetScreen {
      panel.positionAtTopCenter(in: targetScreen, size: initialSize)
    }

    state.onShowPanel = { [weak self] in self?.show() }
    state.onHidePanel = { [weak self] in self?.hide() }
    state.onPanelLayoutChanged = { [weak self] in self?.handleStateLayoutChanged() }
  }

  private var maximumSize: NSSize {
    NSSize(width: expandedPanelWidth + TF.topTranscriptPanelOuterInset, height: maximumPanelHeight)
  }

  private func makeRootView() -> FloatingBarView<AppState> {
    FloatingBarView(
      state: state,
      expandedPanelWidth: expandedPanelWidth
    )
  }

  private func configureForCurrentTarget() {
    targetScreen = panel.preferredScreen()
    guard let targetScreen else { return }
    let visible = targetScreen.visibleFrame
    expandedPanelWidth = min(
      TF.topTranscriptPanelMaxWidth,
      max(TF.topTranscriptPanelCollapsedWidth, visible.width - 80)
    )
    maximumPanelHeight = max(
      80,
      visible.height - TF.topTranscriptPanelTopOffset - TF.topTranscriptPanelBottomMargin
    )
  }

  private func handleStateLayoutChanged() {
    let collapseChanged = lastPanelCollapsed != state.isTranscriptPanelCollapsed
    lastPanelCollapsed = state.isTranscriptPanelCollapsed
    if collapseChanged {
      // Keep the collapse-button mouse-up from being reinterpreted as a window drag.
      // Enable background dragging only after the async resize has recentered the panel.
      panel.isMovableByWindowBackground = false
      recenterPanelOnNextResize = true
    } else {
      panel.isMovableByWindowBackground = state.isTranscriptPanelCollapsed
    }
    scheduleComputedSizeUpdate()
    syncScreenBottomIndicator()
  }

  private func scheduleComputedSizeUpdate() {
    pendingResize?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.applyResize(to: self.desiredPanelSize())
    }
    pendingResize = work
    DispatchQueue.main.async(execute: work)
  }

  private func desiredPanelSize() -> CGSize {
    let outerInset = TF.topTranscriptPanelOuterInset
    guard
      state.barPhase == .preparing
        || state.barPhase == .recording
        || state.barPhase == .processing
        || ((state.barPhase == .done || state.barPhase == .error)
          && (!state.transcriptionText.isEmpty || !state.optimizedPanelText.isEmpty))
    else {
      return maximumSize
    }
    if state.isTranscriptPanelCollapsed {
      return CGSize(
        width: TF.topTranscriptPanelCollapsedWidth + outerInset,
        height: TF.topTranscriptPanelCollapsedHeaderHeight + outerInset
      )
    }

    let dividerWidth: CGFloat = 1
    let leftColumnWidth = (expandedPanelWidth - dividerWidth) * 0.45
    let rightColumnWidth = expandedPanelWidth - dividerWidth - leftColumnWidth
    let textWidthInset = TF.topTranscriptPanelHorizontalPadding * 2
    let raw =
      state.transcriptionText.isEmpty ? L("等待语音…", "Waiting for speech…") : state.transcriptionText
    let optimized: String = {
      if state.supportsLiveOptimizationPreview {
        return state.optimizedPanelText.isEmpty
          ? L("等待停顿后优化…", "Waiting for a pause to optimize…")
          : state.optimizedPanelText
      }
      return state.processingResultText.isEmpty
        ? state.transcriptionText : state.processingResultText
    }()
    let rawHeight = measuredTranscriptHeight(raw, width: leftColumnWidth - textWidthInset)
    var optimizedHeight = measuredTranscriptHeight(
      optimized, width: rightColumnWidth - textWidthInset)
    if let failure = state.finalOptimizationFailureMessage {
      let failureMessageHeight = measuredTranscriptHeight(
        failure,
        width: rightColumnWidth - 56,
        fontSize: 10,
        lineSpacing: 0
      )
      optimizedHeight +=
        108
        + failureMessageHeight
        + CGFloat(state.llmCallAttempts.filter { !$0.succeeded }.count) * 18
    }
    let contentHeight =
      TF.topTranscriptPanelHeaderHeight
      + TF.topTranscriptPanelMeterBridgeHeight
      + TF.topTranscriptPanelColumnHeaderHeight
      + max(rawHeight, optimizedHeight)
      + TF.topTranscriptPanelBodyTopPadding
      + TF.topTranscriptPanelBodyBottomPadding
    return CGSize(
      width: expandedPanelWidth + outerInset,
      height: min(contentHeight + outerInset, maximumPanelHeight)
    )
  }

  private func measuredTranscriptHeight(
    _ text: String,
    width: CGFloat,
    fontSize: CGFloat = TF.topTranscriptPanelBodyFontSize,
    lineSpacing: CGFloat = TF.topTranscriptPanelBodyLineSpacing
  ) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    let bounds = (text as NSString).boundingRect(
      with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
        .paragraphStyle: paragraph,
      ]
    )
    return ceil(bounds.height)
  }

  private func applyResize(to measuredSize: CGSize) {
    guard let targetScreen else { return }
    let size = NSSize(
      width: min(measuredSize.width, targetScreen.visibleFrame.width),
      height: min(measuredSize.height, maximumPanelHeight)
    )
    let shouldRecenter = recenterPanelOnNextResize
    recenterPanelOnNextResize = false
    let sizeChanged =
      abs(panel.frame.width - size.width) > 0.5
      || abs(panel.frame.height - size.height) > 0.5
    guard sizeChanged || shouldRecenter else { return }

    hosting.frame = NSRect(origin: .zero, size: size)
    if state.isTranscriptPanelCollapsed, !shouldRecenter {
      let origin = constrainedPanelOrigin(panel.frame.origin, size: size, in: targetScreen)
      panel.setFrame(NSRect(origin: origin, size: size), display: false)
    } else {
      panel.positionAtTopCenter(in: targetScreen, size: size)
    }
    panel.isMovableByWindowBackground = state.isTranscriptPanelCollapsed
  }

  private func constrainedPanelOrigin(
    _ origin: NSPoint,
    size: NSSize,
    in screen: NSScreen
  ) -> NSPoint {
    let visible = screen.visibleFrame
    return NSPoint(
      x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
      y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
    )
  }

  private func syncScreenBottomIndicator() {
    if state.barPhase == .recording {
      showScreenBottomIndicator()
    } else {
      hideScreenBottomIndicator()
    }
  }

  private func showScreenBottomIndicator() {
    screenBottomIndicatorHosting.rootView = ScreenBottomRecordingIndicator(
      meter: state.audioLevel,
      modeName: state.currentMode.name
    )
    screenBottomIndicatorPanel.contentView?.layer?.removeAllAnimations()
    if screenBottomIndicatorPanel.isVisible {
      screenBottomIndicatorPanel.alphaValue = 1
      return
    }

    configureForCurrentTarget()
    guard let targetScreen else { return }
    if let displayID = Self.displayID(for: targetScreen),
      let savedOrigin = screenBottomIndicatorOrigins[displayID]
    {
      let indicatorSize = screenBottomIndicatorPanel.frame.size
      let origin = constrainedPanelOrigin(savedOrigin, size: indicatorSize, in: targetScreen)
      screenBottomIndicatorPanel.setFrame(
        NSRect(origin: origin, size: indicatorSize),
        display: false
      )
    } else {
      screenBottomIndicatorPanel.positionAtBottomCenter(in: targetScreen)
    }

    screenBottomIndicatorPanel.alphaValue = 1
    screenBottomIndicatorPanel.orderFrontRegardless()
  }

  private func hideScreenBottomIndicator() {
    guard screenBottomIndicatorPanel.isVisible else { return }
    let frame = screenBottomIndicatorPanel.frame
    if let screen = NSScreen.screens.first(where: {
      $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
    }),
      let displayID = Self.displayID(for: screen)
    {
      screenBottomIndicatorOrigins[displayID] = frame.origin
    }
    screenBottomIndicatorPanel.alphaValue = 0
    screenBottomIndicatorPanel.orderOut(nil)
  }

  private static func displayID(for screen: NSScreen) -> NSNumber? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  }

  func show() {
    panelGeneration &+= 1
    pendingResize?.cancel()

    // Recording → processing reuses the same visible panel. Rebuilding the
    // hosting view and fading from zero here caused a visible disappear/reappear flash.
    if panel.isVisible {
      panel.contentView?.layer?.removeAllAnimations()
      panel.alphaValue = 1
      scheduleComputedSizeUpdate()
      syncScreenBottomIndicator()
      return
    }

    configureForCurrentTarget()
    hosting.rootView = makeRootView()
    let initialSize =
      state.isTranscriptPanelCollapsed
      ? NSSize(
        width: TF.topTranscriptPanelCollapsedWidth + TF.topTranscriptPanelOuterInset,
        height: TF.topTranscriptPanelCollapsedHeaderHeight + TF.topTranscriptPanelOuterInset
      )
      : maximumSize
    hosting.frame = NSRect(origin: .zero, size: initialSize)
    if let targetScreen {
      if state.isTranscriptPanelCollapsed, let collapsedPanelOrigin {
        let origin = constrainedPanelOrigin(
          collapsedPanelOrigin,
          size: initialSize,
          in: targetScreen
        )
        panel.setFrame(NSRect(origin: origin, size: initialSize), display: false)
      } else {
        panel.positionAtTopCenter(in: targetScreen, size: initialSize)
      }
    }
    panel.isMovableByWindowBackground = state.isTranscriptPanelCollapsed
    panel.contentView?.layer?.removeAllAnimations()
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    scheduleComputedSizeUpdate()
    syncScreenBottomIndicator()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
  }

  func hide() {
    hideScreenBottomIndicator()
    if state.isTranscriptPanelCollapsed {
      collapsedPanelOrigin = panel.frame.origin
    }
    guard panel.isVisible else { return }
    pendingResize?.cancel()
    let expectedGeneration = panelGeneration
    let panelRef = panel
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panelRef.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.panelGeneration == expectedGeneration else { return }
          panelRef.orderOut(nil)
        }
      })
  }
}
