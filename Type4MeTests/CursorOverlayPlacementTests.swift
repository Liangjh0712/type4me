import XCTest

@testable import Type4Me

final class CursorOverlayPlacementTests: XCTestCase {

  /// A 1440×900 display with a 25pt menu bar, in Cocoa coordinates.
  private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
  private let panelSize = NSSize(width: 200, height: 30)

  private var gap: CGFloat { CursorOverlayPlacement.gap }
  private var margin: CGFloat { CursorOverlayPlacement.screenMargin }

  func testPrefersBelowCaret() {
    let anchor = CGRect(x: 400, y: 500, width: 1, height: 16)
    let origin = CursorOverlayPlacement.origin(
      anchor: anchor, panelSize: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.x, 400)
    XCTAssertEqual(origin.y, anchor.minY - gap - panelSize.height)
  }

  func testFlipsAboveWhenNoRoomBelow() {
    // Caret sits on the last line of a bottom-docked input field.
    let anchor = CGRect(x: 400, y: 12, width: 1, height: 16)
    let origin = CursorOverlayPlacement.origin(
      anchor: anchor, panelSize: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.y, anchor.maxY + gap)
  }

  func testClampsWhenNeitherSideFits() {
    // Panel too tall for the space on either side of the caret.
    let anchor = CGRect(x: 400, y: 40, width: 1, height: 16)
    let tall = NSSize(width: 200, height: 810)
    let origin = CursorOverlayPlacement.origin(
      anchor: anchor, panelSize: tall, visibleFrame: visible)
    XCTAssertEqual(origin.y, visible.minY + margin)
  }

  func testClampsHorizontallyAtLeftEdge() {
    let anchor = CGRect(x: -30, y: 500, width: 1, height: 16)
    let origin = CursorOverlayPlacement.origin(
      anchor: anchor, panelSize: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.x, visible.minX + margin)
  }

  func testClampsHorizontallyAtRightEdge() {
    let anchor = CGRect(x: 1439, y: 500, width: 1, height: 16)
    let origin = CursorOverlayPlacement.origin(
      anchor: anchor, panelSize: panelSize, visibleFrame: visible)
    XCTAssertEqual(origin.x, visible.maxX - margin - panelSize.width)
  }

  func testPanelWiderThanScreenClampsToMargin() {
    let huge = NSSize(width: 2000, height: 30)
    let anchor = CGRect(x: 700, y: 500, width: 1, height: 16)
    let origin = CursorOverlayPlacement.origin(
      anchor: anchor, panelSize: huge, visibleFrame: visible)
    XCTAssertEqual(origin.x, visible.minX + margin)
  }

  func testPanelTallerThanScreenClampsToMargin() {
    let huge = NSSize(width: 200, height: 2000)
    let anchor = CGRect(x: 400, y: 500, width: 1, height: 16)
    let origin = CursorOverlayPlacement.origin(
      anchor: anchor, panelSize: huge, visibleFrame: visible)
    XCTAssertEqual(origin.y, visible.minY + margin)
  }

  func testCursorStyleRawValueRoundTrips() {
    XCTAssertEqual(TranscriptPanelStyle(rawValue: "cursor"), .cursor)
    XCTAssertEqual(TranscriptPanelStyle.cursor.rawValue, "cursor")
    XCTAssertTrue(TranscriptPanelStyle.allCases.contains(.cursor))
  }
}
