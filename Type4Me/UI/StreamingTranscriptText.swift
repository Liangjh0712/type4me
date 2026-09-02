import SwiftUI

/// Per-character transcript renderer for the live overlays.
///
/// A single `Text` can only animate as a whole: append-and-retype, or
/// cross-fade the entire line. Neither reads well against streaming ASR,
/// which rewrites its tail constantly — the line either flickers or the eye
/// is dragged back over words it already read.
///
/// Rendering each character as its own view fixes both. Characters carry a
/// stable identity (position + value), so SwiftUI animates exactly the ones
/// that changed and leaves the settled prefix alone. New characters develop
/// into place — rising 3pt, un-blurring, fading up — staggered so a burst of
/// recognized text arrives as a wave rather than a block.
///
/// Layout note: this is a single line that head-truncates, so it builds the
/// visible tail itself rather than relying on `Text`'s truncation. The
/// character count that fits is measured against the same font the glyphs
/// render with.
struct StreamingTranscriptText: View {
  let text: String
  let font: Font
  /// Font used to measure how much of the tail fits; must match `font`.
  let measuringFont: NSFont
  let color: Color
  let maxWidth: CGFloat
  /// Set false for frozen states (processing, error) so settled text doesn't
  /// re-animate when the color changes.
  var animates: Bool = true

  /// Identity for one rendered glyph. Both the position AND the character
  /// are part of the key. Position alone would let a corrected character
  /// ("觉" → "记" at index 1) reuse the same view and change silently, with
  /// no transition; the character alone would make repeated glyphs ("好好好")
  /// share identity and swap views between unrelated positions.
  private struct Glyph: Identifiable {
    let index: Int
    let character: Character
    var id: String { "\(index):\(character)" }
  }

  /// Per-character stagger. 18ms reads as a wave; below ~10 it looks
  /// simultaneous, above ~30 the tail visibly lags the speech.
  private static let stagger: Double = 0.018
  /// Longest wave, in characters. Fast speech delivers 10-20 characters in
  /// one update; letting all of them ripple would run for half a second and
  /// keep the whole line in motion while the next burst already arrives.
  private static let maxStaggerSteps = 5
  /// How much of the rise/blur a glyph shows. Kept subtle — at 13.5pt a
  /// bigger move reads as the line shaking rather than as text settling.
  private static let riseDistance: CGFloat = 2.5
  private static let blurRadius: CGFloat = 1.6

  var body: some View {
    HStack(spacing: 0) {
      ForEach(visibleGlyphs) { glyph in
        Text(String(glyph.character))
          .font(font)
          .foregroundStyle(color)
          .fixedSize()
          .transition(
            animates
              ? characterTransition(at: glyph.index)
              // Frozen phases (processing, error) shouldn't re-develop
              // settled text just because the color changed.
              : .identity
          )
      }
    }
    .frame(maxWidth: maxWidth, alignment: .leading)
  }

  /// Glyphs for the tail that fits `maxWidth`, keyed by their position in the
  /// FULL string.
  ///
  /// Indexing within the visible window was a bug: once the text overflows,
  /// the head is dropped and every remaining character shifts down one slot,
  /// so `"5:方"` became `"4:方"` and SwiftUI saw the entire line as new —
  /// every glyph re-developed at once. That is the flicker that showed up
  /// when speaking quickly, because fast speech is what overflows the line.
  private var visibleGlyphs: [Glyph] {
    let characters = Array(text)
    guard !characters.isEmpty else { return [] }
    let attributes: [NSAttributedString.Key: Any] = [.font: measuringFont]
    if ceil((text as NSString).size(withAttributes: attributes).width) <= maxWidth {
      return characters.enumerated().map { Glyph(index: $0.offset, character: $0.element) }
    }
    var start = characters.count
    var tail = ""
    while start > 0 {
      let candidate = String(characters[start - 1]) + tail
      if ceil((candidate as NSString).size(withAttributes: attributes).width) > maxWidth {
        break
      }
      tail = candidate
      start -= 1
    }
    return characters[start...].enumerated().map {
      Glyph(index: start + $0.offset, character: $0.element)
    }
  }

  /// Rise + un-blur + fade. Removal is a plain fade: a character being
  /// corrected away should get out of the way, not perform an exit.
  ///
  /// The stagger is keyed to absolute position, so a glyph's delay does not
  /// change as the line scrolls — and characters that arrive together still
  /// land in reading order.
  private func characterTransition(at index: Int) -> AnyTransition {
    let delay = Double(index % (Self.maxStaggerSteps + 1)) * Self.stagger
    return .asymmetric(
      insertion: .modifier(
        active: DevelopingGlyph(
          progress: 0, rise: Self.riseDistance, blur: Self.blurRadius),
        identity: DevelopingGlyph(
          progress: 1, rise: Self.riseDistance, blur: Self.blurRadius)
      )
      .animation(.easeOut(duration: 0.22).delay(delay)),
      removal: .opacity.animation(.easeIn(duration: 0.08))
    )
  }

}

/// The "developing" effect: a glyph rises into place while its blur clears.
/// Deliberately restrained — at 13.5pt a larger move stops reading as focus
/// and starts reading as the line shaking, which is exactly the "flicker"
/// complaint that a too-eager version of this produced.
private struct DevelopingGlyph: ViewModifier {
  /// 0 = just spoken, 1 = settled.
  let progress: Double
  let rise: CGFloat
  let blur: CGFloat

  func body(content: Content) -> some View {
    content
      .opacity(progress)
      .blur(radius: (1 - progress) * blur)
      .offset(y: (1 - progress) * rise)
  }
}
