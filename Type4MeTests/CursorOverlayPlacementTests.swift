import XCTest

@testable import Type4Me

final class CursorOverlayPlacementTests: XCTestCase {

  /// A 1440×900 display with a 25pt menu bar, in Cocoa coordinates.
  private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
  /// A second display parked to the right, at a different resolution.
  private let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
  private let panelSize = NSSize(width: 200, height: 55)

  private var margin: CGFloat { CursorOverlayPlacement.screenMargin }
  private var lift: CGFloat { CursorOverlayPlacement.defaultBottomLift }

  // MARK: - Clamping

  func testClampsAtLeftEdge() {
    let origin = CursorOverlayPlacement.clamped(
      NSPoint(x: -50, y: 400), size: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.x, visible.minX + margin)
  }

  func testClampsAtRightEdge() {
    let origin = CursorOverlayPlacement.clamped(
      NSPoint(x: 5000, y: 400), size: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.x, visible.maxX - margin - panelSize.width)
  }

  func testClampsAtBottomEdge() {
    let origin = CursorOverlayPlacement.clamped(
      NSPoint(x: 400, y: -80), size: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.y, visible.minY + margin)
  }

  func testClampsAtTopEdge() {
    let origin = CursorOverlayPlacement.clamped(
      NSPoint(x: 400, y: 9000), size: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.y, visible.maxY - margin - panelSize.height)
  }

  func testPanelWiderThanScreenClampsToMargin() {
    let huge = NSSize(width: 2000, height: 55)
    let origin = CursorOverlayPlacement.clamped(
      NSPoint(x: 700, y: 400), size: huge, visibleFrame: visible)
    XCTAssertEqual(origin.x, visible.minX + margin)
  }

  // MARK: - Default placement

  func testDefaultOriginIsBottomCentered() {
    let origin = CursorOverlayPlacement.defaultOrigin(
      size: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.x, visible.midX - panelSize.width / 2)
    XCTAssertEqual(origin.y, visible.minY + lift)
  }

  // MARK: - Display-independent anchoring

  func testAnchorRoundTripsOnSameScreen() {
    let parked = NSPoint(x: 900, y: 620)
    let anchor = CursorOverlayPlacement.relativeAnchor(
      origin: parked, size: panelSize, visibleFrame: visible)
    let resolved = CursorOverlayPlacement.origin(
      anchor: anchor, size: panelSize, visibleFrame: visible)
    XCTAssertEqual(resolved.x, parked.x, accuracy: 0.001)
    XCTAssertEqual(resolved.y, parked.y, accuracy: 0.001)
  }

  /// The whole point of the anchor: a capsule parked bottom-right on one
  /// display lands bottom-right on a differently sized one, not offscreen.
  func testAnchorTransfersProportionallyToAnotherScreen() {
    let bottomRight = NSPoint(
      x: visible.maxX - margin - panelSize.width, y: visible.minY + margin)
    let anchor = CursorOverlayPlacement.relativeAnchor(
      origin: bottomRight, size: panelSize, visibleFrame: visible)
    XCTAssertEqual(anchor.x, 1, accuracy: 0.001)
    XCTAssertEqual(anchor.y, 0, accuracy: 0.001)

    let resolved = CursorOverlayPlacement.origin(
      anchor: anchor, size: panelSize, visibleFrame: secondary)
    XCTAssertEqual(resolved.x, secondary.maxX - margin - panelSize.width, accuracy: 0.001)
    XCTAssertEqual(resolved.y, secondary.minY + margin, accuracy: 0.001)
  }

  func testCenteredAnchorStaysCenteredAcrossScreens() {
    let centered = NSPoint(
      x: visible.midX - panelSize.width / 2, y: visible.midY - panelSize.height / 2)
    let anchor = CursorOverlayPlacement.relativeAnchor(
      origin: centered, size: panelSize, visibleFrame: visible)
    let resolved = CursorOverlayPlacement.origin(
      anchor: anchor, size: panelSize, visibleFrame: secondary)
    XCTAssertEqual(resolved.x, secondary.midX - panelSize.width / 2, accuracy: 0.001)
    XCTAssertEqual(resolved.y, secondary.midY - panelSize.height / 2, accuracy: 0.001)
  }

  func testResolvedAnchorAlwaysStaysOnScreen() {
    for anchor in [
      CursorOverlayPlacement.RelativeAnchor(x: -5, y: -5),
      CursorOverlayPlacement.RelativeAnchor(x: 9, y: 9),
      CursorOverlayPlacement.RelativeAnchor(x: 0.5, y: 0.5),
    ] {
      let origin = CursorOverlayPlacement.origin(
        anchor: anchor, size: panelSize, visibleFrame: secondary)
      XCTAssertGreaterThanOrEqual(origin.x, secondary.minX + margin)
      XCTAssertLessThanOrEqual(origin.x + panelSize.width, secondary.maxX - margin)
      XCTAssertGreaterThanOrEqual(origin.y, secondary.minY + margin)
      XCTAssertLessThanOrEqual(origin.y + panelSize.height, secondary.maxY - margin)
    }
  }

  /// A panel too big for the screen has no free space to express a fraction
  /// against; it must degrade to the clamped corner rather than divide by zero.
  func testOversizedPanelYieldsFiniteAnchor() {
    let huge = NSSize(width: 3000, height: 2000)
    let anchor = CursorOverlayPlacement.relativeAnchor(
      origin: NSPoint(x: 100, y: 100), size: huge, visibleFrame: visible)
    XCTAssertTrue(anchor.x.isFinite)
    XCTAssertTrue(anchor.y.isFinite)
    let origin = CursorOverlayPlacement.origin(
      anchor: anchor, size: huge, visibleFrame: visible)
    XCTAssertEqual(origin.x, visible.minX + margin)
    XCTAssertEqual(origin.y, visible.minY + margin)
  }

  func testCursorStyleRawValueRoundTrips() {
    XCTAssertEqual(TranscriptPanelStyle(rawValue: "cursor"), .cursor)
    XCTAssertEqual(TranscriptPanelStyle.cursor.rawValue, "cursor")
    XCTAssertTrue(TranscriptPanelStyle.allCases.contains(.cursor))
  }
}
