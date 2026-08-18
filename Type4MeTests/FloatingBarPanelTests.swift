import AppKit
import SwiftUI
import XCTest

@testable import Type4Me

@MainActor
final class FloatingBarPanelTests: XCTestCase {
  func testHostingViewDoesNotDrivePanelSize() throws {
    let (_, panel) = try makeControllerAndPanel()
    defer { panel.orderOut(nil) }

    let hosting = try XCTUnwrap(
      panel.contentView as? NSHostingView<FloatingBarView<AppState>>
    )

    XCTAssertEqual(hosting.sizingOptions, [])
  }

  func testPanelUsesTopAdaptiveGeometry() throws {
    let (controller, panel) = try makeControllerAndPanel()
    defer { panel.orderOut(nil) }
    let screen = try XCTUnwrap(panel.preferredScreen())

    XCTAssertEqual(TF.topTranscriptPanelMaxWidth, 1120)
    XCTAssertLessThanOrEqual(
      panel.frame.width, TF.topTranscriptPanelMaxWidth + TF.topTranscriptPanelOuterInset)
    XCTAssertEqual(
      panel.frame.maxY,
      screen.visibleFrame.maxY - TF.topTranscriptPanelTopOffset,
      accuracy: 0.5
    )
    withExtendedLifetime(controller) {}
  }

  func testStopTransitionKeepsVisiblePanelStable() throws {
    let state = AppState()
    state.currentMode = .formalWriting
    let (_, controller, panel) = try makeStateControllerAndPanel(state: state)
    defer { panel.orderOut(nil) }

    state.startRecording()
    state.markRecordingReady()
    state.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: ["这是一段正在转写的测试内容"],
        partialText: "",
        authoritativeText: "",
        isFinal: false
      ))
    for _ in 0..<15 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      panel.contentView?.layoutSubtreeIfNeeded()
    }
    let frameBeforeStop = panel.frame
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)

    state.stopRecording()

    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
    XCTAssertEqual(panel.frame.width, frameBeforeStop.width, accuracy: 0.5)
    XCTAssertEqual(panel.frame.height, frameBeforeStop.height, accuracy: 0.5)
    withExtendedLifetime(controller) {}
  }

  func testScreenBottomIndicatorShowsOnlyWhileRecording() throws {
    _ = NSApplication.shared
    let existingIndicators = Set(
      NSApp.windows.compactMap { $0 as? ScreenBottomIndicatorPanel }.map(ObjectIdentifier.init)
    )
    let state = AppState()
    state.currentMode = .formalWriting
    let (_, controller, topPanel) = try makeStateControllerAndPanel(state: state)
    defer { topPanel.orderOut(nil) }
    let indicator = try XCTUnwrap(
      NSApp.windows.compactMap { $0 as? ScreenBottomIndicatorPanel }
        .first { !existingIndicators.contains(ObjectIdentifier($0)) }
    )
    defer { indicator.orderOut(nil) }

    XCTAssertFalse(indicator.isVisible)
    state.startRecording()
    state.markRecordingReady()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    let screen = try XCTUnwrap(topPanel.preferredScreen())
    XCTAssertTrue(indicator.isVisible)
    XCTAssertEqual(
      indicator.frame.size,
      NSSize(width: TF.screenBottomIndicatorWidth, height: TF.screenBottomIndicatorHeight)
    )
    XCTAssertEqual(indicator.frame.midX, screen.visibleFrame.midX, accuracy: 0.5)
    XCTAssertEqual(
      indicator.frame.minY,
      screen.visibleFrame.minY + TF.barBottomOffset,
      accuracy: 0.5
    )
    XCTAssertFalse(indicator.ignoresMouseEvents)
    XCTAssertTrue(
      indicator.shouldPerformWindowDrag(
        at: NSPoint(x: indicator.frame.width / 2, y: indicator.frame.height / 2)
      )
    )
    XCTAssertFalse(
      indicator.shouldPerformWindowDrag(
        at: NSPoint(x: indicator.frame.width - 18, y: indicator.frame.height - 15)
      )
    )

    state.stopRecording()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertFalse(indicator.isVisible)
    withExtendedLifetime(controller) {}
  }

  func testScreenBottomIndicatorRestoresDraggedPosition() throws {
    _ = NSApplication.shared
    let existingIndicators = Set(
      NSApp.windows.compactMap { $0 as? ScreenBottomIndicatorPanel }.map(ObjectIdentifier.init)
    )
    let state = AppState()
    let (_, controller, topPanel) = try makeStateControllerAndPanel(state: state)
    defer { topPanel.orderOut(nil) }
    let indicator = try XCTUnwrap(
      NSApp.windows.compactMap { $0 as? ScreenBottomIndicatorPanel }
        .first { !existingIndicators.contains(ObjectIdentifier($0)) }
    )
    defer { indicator.orderOut(nil) }

    state.startRecording()
    state.markRecordingReady()
    for _ in 0..<8 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    let screen = try XCTUnwrap(topPanel.preferredScreen())
    let movedOrigin = NSPoint(
      x: screen.visibleFrame.minX + 70,
      y: screen.visibleFrame.minY + 120
    )
    indicator.setFrameOrigin(movedOrigin)

    state.cancel()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    state.startRecording()
    state.markRecordingReady()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    XCTAssertEqual(indicator.frame.origin.x, movedOrigin.x, accuracy: 0.5)
    XCTAssertEqual(indicator.frame.origin.y, movedOrigin.y, accuracy: 0.5)
    withExtendedLifetime(controller) {}
  }

  func testOneLineDualTranscriptStaysCompact() throws {
    let state = AppState()
    state.currentMode = .formalWriting
    let (_, controller, panel) = try makeStateControllerAndPanel(state: state)
    defer { panel.orderOut(nil) }

    state.startRecording()
    state.markRecordingReady()
    state.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: ["一行原文"],
        partialText: "",
        authoritativeText: "一行原文",
        isFinal: false
      ))
    state.showLiveOptimizationResult(
      "一行优化稿",
      sourceText: "一行原文",
      modeID: state.currentMode.id
    )

    for _ in 0..<12 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      panel.contentView?.layoutSubtreeIfNeeded()
    }

    XCTAssertLessThanOrEqual(panel.frame.height, 105)
    XCTAssertGreaterThanOrEqual(panel.frame.height, 85)
    withExtendedLifetime(controller) {}
  }

  func testCollapsedPanelCanMoveAndRestoresItsPosition() throws {
    let state = AppState()
    state.currentMode = .formalWriting
    let (_, controller, panel) = try makeStateControllerAndPanel(state: state)
    defer { panel.orderOut(nil) }

    state.startRecording()
    state.markRecordingReady()
    state.toggleTranscriptPanelCollapsed()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertTrue(panel.isMovableByWindowBackground)
    let screen = try XCTUnwrap(panel.preferredScreen())
    XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 0.5)
    let movedOrigin = NSPoint(
      x: screen.visibleFrame.minX + 44,
      y: screen.visibleFrame.minY + 180
    )
    panel.setFrameOrigin(movedOrigin)
    state.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: ["移动后继续识别"],
        partialText: "",
        authoritativeText: "移动后继续识别",
        isFinal: false
      )
    )
    for _ in 0..<8 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertEqual(panel.frame.origin.x, movedOrigin.x, accuracy: 0.5)
    XCTAssertEqual(panel.frame.origin.y, movedOrigin.y, accuracy: 0.5)

    state.cancel()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    state.startRecording()
    state.markRecordingReady()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertEqual(panel.frame.origin.x, movedOrigin.x, accuracy: 0.5)
    XCTAssertEqual(panel.frame.origin.y, movedOrigin.y, accuracy: 0.5)

    state.toggleTranscriptPanelCollapsed()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertFalse(panel.isMovableByWindowBackground)
    withExtendedLifetime(controller) {}
  }

  func testLongPinnedTranscriptKeepsPanelWithinReservedSize() throws {
    let (state, controller, panel) = try makeStateControllerAndPanel()
    defer { panel.orderOut(nil) }
    let expectedSize = panel.frame.size

    state.showRecovery(
      text: String(repeating: "This is a long transcript segment. ", count: 1_000),
      message: "Recovering"
    )

    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      panel.contentView?.layoutSubtreeIfNeeded()
    }

    let hosting = try XCTUnwrap(
      panel.contentView as? NSHostingView<FloatingBarView<AppState>>
    )
    let fittingSize = hosting.fittingSize

    XCTAssertEqual(panel.frame.width, expectedSize.width, accuracy: 0.5)
    XCTAssertEqual(panel.frame.height, expectedSize.height, accuracy: 0.5)
    XCTAssertLessThanOrEqual(fittingSize.height, expectedSize.height)
    withExtendedLifetime(controller) {}
  }

  func testLongDualTranscriptUsesFlatContentAndCanCollapse() throws {
    let state = AppState()
    state.currentMode = .formalWriting
    let (_, controller, panel) = try makeStateControllerAndPanel(state: state)
    defer { panel.orderOut(nil) }
    let raw = String(repeating: "原", count: 600)
    let optimized = String(repeating: "优", count: 600)

    state.startRecording()
    state.markRecordingReady()
    state.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: [raw],
        partialText: "",
        authoritativeText: raw,
        isFinal: false
      ))
    state.beginLiveOptimization(sourceText: raw, modeID: state.currentMode.id)
    state.showLiveOptimizationResult(optimized, sourceText: raw, modeID: state.currentMode.id)

    for _ in 0..<15 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      panel.contentView?.layoutSubtreeIfNeeded()
    }

    let hosting = try XCTUnwrap(panel.contentView as? NSHostingView<FloatingBarView<AppState>>)
    let transcriptScrollViews = descendantViews(of: hosting)
      .compactMap { $0 as? NSScrollView }
      .filter { $0.documentView is NSTextView }
    XCTAssertTrue(transcriptScrollViews.isEmpty)
    XCTAssertGreaterThan(panel.frame.height, 300)
    let screenHeight = panel.preferredScreen()?.visibleFrame.height ?? .greatestFiniteMagnitude
    XCTAssertLessThan(
      panel.frame.height,
      screenHeight - TF.topTranscriptPanelTopOffset - TF.topTranscriptPanelBottomMargin)
    XCTAssertEqual(state.liveOptimizationPhase, .ready)

    state.toggleTranscriptPanelCollapsed()
    for _ in 0..<10 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      panel.contentView?.layoutSubtreeIfNeeded()
    }
    XCTAssertEqual(
      panel.frame.width,
      TF.topTranscriptPanelCollapsedWidth + TF.topTranscriptPanelOuterInset,
      accuracy: 1
    )
    XCTAssertLessThan(panel.frame.height, 100)
    XCTAssertTrue(panel.isMovableByWindowBackground)
    withExtendedLifetime(controller) {}
  }

  private func descendantViews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendantViews(of:))
  }

  private func makeControllerAndPanel() throws -> (FloatingBarController, FloatingBarPanel) {
    let state = AppState()
    let (_, controller, panel) = try makeStateControllerAndPanel(state: state)
    return (controller, panel)
  }

  private func makeStateControllerAndPanel(
    state: AppState = AppState()
  ) throws -> (AppState, FloatingBarController, FloatingBarPanel) {
    _ = NSApplication.shared
    let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    let controller = FloatingBarController(state: state)
    let panel = try XCTUnwrap(
      NSApp.windows
        .compactMap { $0 as? FloatingBarPanel }
        .first { !existingWindows.contains(ObjectIdentifier($0)) }
    )
    return (state, controller, panel)
  }
}
