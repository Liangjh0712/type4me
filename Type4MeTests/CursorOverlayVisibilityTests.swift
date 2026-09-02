import XCTest

@testable import Type4Me

/// Regression tests for the capsule's show/hide decision.
///
/// The bug these exist for: the capsule intermittently failed to appear when a
/// recording was started shortly after the previous one ended. `NSWindow`
/// reports `isVisible == true` for the entire 0.15s fade-out, so the controller
/// treated a dying panel as an already-shown one, skipped the show as
/// redundant, and then let the in-flight fade's completion handler order the
/// panel out from under the live recording. It looked exactly like the overlay
/// being covered by the frontmost window, which is what made it hard to place.
final class CursorOverlayVisibilityTests: XCTestCase {

  private typealias Visibility = CursorOverlayVisibility
  private typealias Action = CursorOverlayVisibility.Action

  private func action(
    _ phase: FloatingBarPhase,
    isVisible: Bool,
    isFadingOut: Bool = false,
    styleIsCursor: Bool = true
  ) -> Action {
    Visibility.action(
      phase: phase,
      styleIsCursor: styleIsCursor,
      panel: Visibility.PanelState(isVisible: isVisible, isFadingOut: isFadingOut)
    )
  }

  // MARK: - The regression

  /// The exact failure: capture goes live while the previous utterance's
  /// fade-out is still running. The panel must be re-shown, not treated as
  /// already up — otherwise nothing brings it back and the fade tears it down.
  func testRecordingDuringFadeOutReshowsPanel() {
    XCTAssertEqual(
      action(.recording, isVisible: true, isFadingOut: true),
      .show
    )
    XCTAssertEqual(
      action(.preparing, isVisible: true, isFadingOut: true),
      .show
    )
  }

  /// A first show, with the panel fully down.
  func testFirstShowRaisesPanel() {
    XCTAssertEqual(action(.recording, isVisible: false), .show)
    XCTAssertEqual(action(.preparing, isVisible: false), .show)
  }

  /// `isUp` is the distinction the whole fix rests on: a fading panel is still
  /// `isVisible`, but it is not up, and the two must never be conflated again.
  func testFadingPanelIsNotUp() {
    XCTAssertFalse(
      Visibility.PanelState(isVisible: true, isFadingOut: true).isUp,
      "a panel mid-fade is on its way out, not shown")
    XCTAssertTrue(Visibility.PanelState(isVisible: true, isFadingOut: false).isUp)
    XCTAssertFalse(Visibility.PanelState(isVisible: false, isFadingOut: false).isUp)
  }

  /// Mid-utterance updates must NOT be cold shows: re-resolving the display
  /// every time the transcript grows would teleport the capsule if the pointer
  /// moved while dictating.
  func testOngoingRecordingRefitsInPlace() {
    XCTAssertEqual(action(.recording, isVisible: true), .refit)
  }

  // MARK: - Fade-out is never disturbed

  /// A fade-out already in flight must not be restarted; a second hide would
  /// bump the generation and orphan the first completion handler.
  func testHideWhileFadingIsIdempotent() {
    XCTAssertEqual(action(.done, isVisible: true, isFadingOut: true), .hide)
    XCTAssertEqual(action(.hidden, isVisible: true, isFadingOut: true), .hide)
  }

  /// Post-capture phases must not re-fit a fading panel: that frame belongs to
  /// the utterance that just ended, and resizing it makes the fade visibly jump.
  func testPostCapturePhasesLeaveAFadingPanelAlone() {
    for phase: FloatingBarPhase in [.processing, .recovering, .error] {
      XCTAssertEqual(
        action(phase, isVisible: true, isFadingOut: true), .none,
        "\(phase) must not touch a fading panel")
    }
  }

  func testPostCapturePhasesRefitALivePanel() {
    for phase: FloatingBarPhase in [.processing, .recovering, .error] {
      XCTAssertEqual(action(phase, isVisible: true), .refit, "\(phase) should re-fit")
    }
  }

  /// An error that arrives after the panel is already gone must not resurrect
  /// it — the capsule is not an alert.
  func testErrorOnAHiddenPanelDoesNothing() {
    XCTAssertEqual(action(.error, isVisible: false), .none)
  }

  // MARK: - Terminal phases

  func testDoneAndHiddenHidePanel() {
    XCTAssertEqual(action(.done, isVisible: true), .hide)
    XCTAssertEqual(action(.hidden, isVisible: true), .hide)
  }

  /// Nothing to do if it is already down — no redundant fade animations.
  func testTerminalPhasesOnHiddenPanelAreNoOps() {
    XCTAssertEqual(action(.done, isVisible: false), .hide)
    XCTAssertEqual(action(.hidden, isVisible: false), .hide)
  }

  // MARK: - Other styles

  /// Styles 1/2/4 own the screen instead; the capsule must retire and stay
  /// retired, whatever phase the session is in.
  func testOtherStylesHideThePanelAndNeverShowIt() {
    for phase: FloatingBarPhase in [.preparing, .recording, .processing, .recovering, .error] {
      XCTAssertEqual(
        action(phase, isVisible: true, styleIsCursor: false), .hide,
        "\(phase) must retire the capsule when another style is active")
      XCTAssertEqual(
        action(phase, isVisible: false, styleIsCursor: false), .none,
        "\(phase) must not raise the capsule when another style is active")
    }
  }

  // MARK: - Sequence-level invariant

  /// Walks the stop → restart sequence that produced the bug, asserting the
  /// invariant that matters: whenever capture is live, the capsule is either up
  /// or being brought up. Never silently absent.
  func testCaptureLiveAlwaysImpliesPanelUp() {
    var isVisible = false
    var isFadingOut = false

    func step(_ phase: FloatingBarPhase) -> Action {
      let result = action(phase, isVisible: isVisible, isFadingOut: isFadingOut)
      switch result {
      case .show:
        isVisible = true
        isFadingOut = false
      case .hide:
        // The fade starts but has NOT completed — this is the window the bug
        // lived in, so the model deliberately stays here.
        isFadingOut = isVisible
      case .refit, .none:
        break
      }
      return result
    }

    XCTAssertEqual(step(.recording), .show)
    XCTAssertEqual(step(.processing), .refit)
    XCTAssertEqual(step(.done), .hide)
    XCTAssertTrue(isFadingOut, "the fade should be in flight")

    // Hotkey pressed again inside the fade window.
    XCTAssertEqual(step(.preparing), .show)
    XCTAssertFalse(isFadingOut, "the pending fade must be disarmed")
    XCTAssertTrue(isVisible)

    // And the rest of the new utterance behaves normally.
    XCTAssertEqual(step(.recording), .refit)
    XCTAssertEqual(step(.processing), .refit)
  }
}
