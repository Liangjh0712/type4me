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

  func preferredScreen() -> NSScreen? { ActiveScreenResolver.preferredScreen() }

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

  /// True while the user is modal-dragging the indicator. The controller
  /// suppresses deferred resizes during a drag so the frame can't fight it.
  private(set) var isDragging = false

  /// Height of the status-pill band at the bottom of a style-2 frame;
  /// everything above it is the transcript card, which hosts interactive
  /// controls.
  private static let pillBandHeight: CGFloat = TF.screenBottomIndicatorHeight

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown {
      // Style 2's card contains an interactive mode menu — clicks there must
      // reach SwiftUI, so only the pill band below it stays a drag handle.
      // The pill-only styles have no interactive content: drag from anywhere.
      let inDragArea =
        TranscriptPanelStyle.current() != .bottom
        || event.locationInWindow.y <= Self.pillBandHeight
      if inDragArea {
        isDragging = true
        performDrag(with: event)
        isDragging = false
      } else {
        super.sendEvent(event)
      }
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
  private var screenBottomIndicatorHosting: NSHostingView<ScreenBottomIndicatorView<AppState>>!
  private var targetScreen: NSScreen?
  private var expandedPanelWidth = TF.topTranscriptPanelMaxWidth
  private var maximumPanelHeight: CGFloat = 500
  private var panelGeneration = 0
  private var pendingResize: DispatchWorkItem?
  private var pendingBottomResize: DispatchWorkItem?
  private var lastPanelCollapsed = false
  private var recenterPanelOnNextResize = false
  private var collapsedPanelOrigin: NSPoint?
  /// Last pill anchor (bottom-center of the indicator frame), keyed by display
  /// ID. The indicator always appears on the target (frontmost) screen; a
  /// position is only restored when recording again on the same display where
  /// the user left it. Stored as an anchor rather than the frame origin so
  /// the style-2 text card can grow the frame upward above the pill without
  /// moving it.
  private var screenBottomIndicatorAnchors: [NSNumber: NSPoint] = [:]

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
      rootView: ScreenBottomIndicatorView(state: state)
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
    // Skip measuring the top deck while style 2/3 suppresses it: every layout
    // change would otherwise run two NSString boundingRect passes for an
    // invisible panel, competing with the bottom indicator's own resize.
    let layoutStyle = TranscriptPanelStyle.current()
    let layoutTopSuppressed =
      (layoutStyle == .bottom || layoutStyle == .cursor)
      && state.finalOptimizationFailureMessage == nil
    if !layoutTopSuppressed {
      scheduleComputedSizeUpdate()
    }
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
        height: TF.topTranscriptPanelHeaderHeight + outerInset
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
    if shouldShowScreenBottomIndicator {
      showScreenBottomIndicator()
    } else {
      hideScreenBottomIndicator()
    }
  }

  private var shouldShowScreenBottomIndicator: Bool {
    switch TranscriptPanelStyle.current() {
    case .top, .hidden:
      return state.barPhase == .recording
    case .cursor:
      // Style 3 is minimal by design: the mouse-anchored capsule is the only
      // recording UI (its status dot carries the live/processing state), so
      // the status pill stays hidden.
      return false
    case .bottom:
      switch state.barPhase {
      case .preparing, .recording, .processing, .recovering:
        return true
      case .error:
        // Errors always carry a user-facing message worth surfacing.
        return true
      case .done:
        // Mirrors the top deck's content predicate (feedbackMessage is always
        // non-empty, so it can't be used directly): transcript text, a pending
        // failure, or a non-standard feedback (Mac Action result).
        return !state.transcriptionText.isEmpty
          || !state.optimizedPanelText.isEmpty
          || state.finalOptimizationFailureMessage != nil
          || state.feedbackKind != .standard
      case .hidden:
        return false
      }
    }
  }

  private func showScreenBottomIndicator() {
    screenBottomIndicatorPanel.contentView?.layer?.removeAllAnimations()
    if screenBottomIndicatorPanel.isVisible {
      screenBottomIndicatorPanel.alphaValue = 1
      scheduleBottomIndicatorResize()
      return
    }

    configureForCurrentTarget()
    guard let targetScreen else { return }
    // Cold open: reset to the current desired size BEFORE restoring the
    // remembered anchor, so a tall style-2 frame from the last session can't
    // be clamped against stale geometry and then yank the pill when it shrinks.
    let size = desiredBottomIndicatorSize()
    screenBottomIndicatorHosting.frame = NSRect(origin: .zero, size: size)
    if let displayID = Self.displayID(for: targetScreen),
      let anchor = screenBottomIndicatorAnchors[displayID]
    {
      let origin = constrainedPanelOrigin(
        NSPoint(x: anchor.x - size.width / 2, y: anchor.y),
        size: size,
        in: targetScreen
      )
      screenBottomIndicatorPanel.setFrame(NSRect(origin: origin, size: size), display: false)
    } else {
      screenBottomIndicatorPanel.positionAtBottomCenter(in: targetScreen)
      if screenBottomIndicatorPanel.frame.size != size {
        var frame = screenBottomIndicatorPanel.frame
        frame.origin.x = frame.midX - size.width / 2
        frame.size = size
        screenBottomIndicatorPanel.setFrame(frame, display: false)
      }
    }

    screenBottomIndicatorPanel.alphaValue = 1
    screenBottomIndicatorPanel.orderFrontRegardless()
  }

  private func hideScreenBottomIndicator() {
    pendingBottomResize?.cancel()
    guard screenBottomIndicatorPanel.isVisible else { return }
    let frame = screenBottomIndicatorPanel.frame
    if let screen = NSScreen.screens.first(where: {
      $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
    }),
      let displayID = Self.displayID(for: screen)
    {
      screenBottomIndicatorAnchors[displayID] = NSPoint(x: frame.midX, y: frame.minY)
    }
    screenBottomIndicatorPanel.alphaValue = 0
    screenBottomIndicatorPanel.orderOut(nil)
  }

  // MARK: Bottom Indicator Sizing (style 2)

  /// Pill-only size by default; in style 2 the frame grows upward above the
  /// pill to fit the optimized-transcript card.
  private func desiredBottomIndicatorSize() -> CGSize {
    let pillWidth = measuredStatusPillWidth()
    let base = NSSize(width: pillWidth, height: TF.screenBottomIndicatorHeight)
    guard TranscriptPanelStyle.current() == .bottom, state.barPhase != .hidden else {
      return base
    }
    let cardWidth = min(520, (targetScreen?.visibleFrame.width ?? 800) - 80)
    // Card text width in the view is cardWidth - horizontal padding (12×2).
    // Measure with an extra 8pt of headroom: SwiftUI and TextKit don't always
    // agree on CJK kinsoku line breaks, and if the view wraps one line earlier
    // than the measurement the panel ends up a line short and the text is
    // truncated with an ellipsis until the next resize.
    let textWidth = cardWidth - TF.topTranscriptPanelHorizontalPadding * 2 - 8
    let cardText = OptimizedPanelCopy.bottomCardString(for: state)
    // +40: vertical padding (9×2) + status row (~11pt) + row spacing (5pt)
    // + 6pt safety against line-metric differences.
    var cardHeight = measuredTranscriptHeight(cardText, width: textWidth) + 40
    // Style 2 folds the mode into the card's status row, so the stack below
    // the card is just the status pill.
    let pillStackHeight = TF.screenBottomIndicatorHeight
    // Cap so the grown frame can never reach past the top of the screen.
    if let visible = targetScreen?.visibleFrame.height {
      cardHeight = min(cardHeight, max(60, visible - TF.barBottomOffset - 40 - pillStackHeight))
    }
    let spacing: CGFloat = 10
    return CGSize(
      width: max(cardWidth + 4, base.width),
      height: pillStackHeight + spacing + cardHeight
    )
  }

  /// Width of the status pill's content, so the panel can hug it. The pill
  /// hugs its own content via `fixedSize`, so a fixed panel width silently
  /// clipped the label and clock — in the pill-only styles, which also show
  /// the mode name, the text ran straight off the end.
  private func measuredStatusPillWidth() -> CGFloat {
    let style = TranscriptPanelStyle.current()
    // Mirrors ScreenBottomIndicatorView.statusPill: 16pt leading + dot(6) +
    // gap(9) + meter(26) + gap(9) + label + [gap(9) + clock] +
    // [gap(9) + separator + gap(9) + mode] + 16pt trailing.
    var width: CGFloat = 16 + 6 + 9 + 26 + 9 + 16

    let label: String = {
      switch state.barPhase {
      case .preparing: return L("准备中", "Preparing")
      case .recording: return L("正在聆听", "Listening")
      case .processing, .recovering: return state.effectiveProcessingLabel
      case .done: return L("已完成", "Done")
      case .error: return L("失败", "Failed")
      case .hidden: return ""
      }
    }()
    width += measuredTextWidth(label, fontSize: 11.5, weight: .medium)

    if state.recordingStartDate != nil {
      // "00:00" at 10pt monospaced; the clock never gets wider than mm:ss.
      width += 9 + measuredTextWidth("00:00", fontSize: 10, weight: .medium, monospaced: true)
    }
    if style != .bottom {
      width += 9 + measuredTextWidth("·", fontSize: 10, monospaced: true)
      width += 9 + measuredTextWidth(
        state.currentMode.name, fontSize: 10, weight: .medium, monospaced: true)
    }
    // Keep a floor so a one-word phase label still looks like a control.
    return max(TF.screenBottomIndicatorWidth, ceil(width))
  }

  private func measuredTextWidth(
    _ text: String,
    fontSize: CGFloat,
    weight: NSFont.Weight = .regular,
    monospaced: Bool = false
  ) -> CGFloat {
    let font =
      monospaced
      ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
      : NSFont.systemFont(ofSize: fontSize, weight: weight)
    return ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }

  private func scheduleBottomIndicatorResize() {
    guard !screenBottomIndicatorPanel.isDragging else { return }
    pendingBottomResize?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.applyBottomIndicatorResize(to: self.desiredBottomIndicatorSize())
    }
    pendingBottomResize = work
    DispatchQueue.main.async(execute: work)
  }

  /// Grows/shrinks around the pill: bottom edge fixed, width anchored at the
  /// pill's horizontal center, so it never moves as text arrives.
  private func applyBottomIndicatorResize(to size: CGSize) {
    guard screenBottomIndicatorPanel.isVisible else { return }
    guard !screenBottomIndicatorPanel.isDragging else { return }
    let old = screenBottomIndicatorPanel.frame
    guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
    var frame = NSRect(
      origin: NSPoint(x: old.midX - size.width / 2, y: old.minY),
      size: size
    )
    if let screen = NSScreen.screens.first(where: {
      $0.frame.contains(NSPoint(x: old.midX, y: old.midY))
    }) {
      frame.origin = constrainedPanelOrigin(frame.origin, size: size, in: screen)
    }
    screenBottomIndicatorHosting.frame = NSRect(origin: .zero, size: size)
    screenBottomIndicatorPanel.setFrame(frame, display: true)
  }

  private static func displayID(for screen: NSScreen) -> NSNumber? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  }

  func show() {
    panelGeneration &+= 1
    pendingResize?.cancel()

    // Styles 2/3 keep the top deck out of the way — except when an
    // optimization failure is pending: the deck's retry/insert-raw actions
    // are the only way out of that no-auto-hide state, so every style shows it.
    let style = TranscriptPanelStyle.current()
    let topSuppressed =
      (style == .bottom || style == .cursor)
      && state.finalOptimizationFailureMessage == nil
    if topSuppressed {
      hideTopPanel()
      syncScreenBottomIndicator()
      return
    }

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
        height: TF.topTranscriptPanelHeaderHeight + TF.topTranscriptPanelOuterInset
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
    hideTopPanel()
  }

  private func hideTopPanel() {
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
