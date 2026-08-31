import SwiftUI

// MARK: - Appearance Helper

extension NSAppearance {
  var isDark: Bool {
    bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }
}

// MARK: - Adaptive Color Helper

private func adaptiveColor(
  light: (r: CGFloat, g: CGFloat, b: CGFloat),
  dark: (r: CGFloat, g: CGFloat, b: CGFloat)
) -> Color {
  Color(
    nsColor: NSColor(
      name: nil,
      dynamicProvider: { appearance in
        if appearance.isDark {
          return NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: 1.0)
        }
        return NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: 1.0)
      }))
}

// MARK: - Design Tokens

enum TF {

  // MARK: Colors

  /// Warm amber accent: the signature "indicator light" color
  static let amber = adaptiveColor(
    light: (0.76, 0.49, 0.16),
    dark: (0.83, 0.57, 0.24)
  )

  /// Recording active: warm red-orange, urgent but not alarming
  static let recording = adaptiveColor(
    light: (0.84, 0.34, 0.27),
    dark: (0.87, 0.38, 0.30)
  )

  /// Success: muted warm green
  static let success = adaptiveColor(
    light: (0.35, 0.65, 0.35),
    dark: (0.42, 0.70, 0.42)
  )

  // MARK: Settings Palette

  static let settingsBg = Color(red: 0.95, green: 0.92, blue: 0.88)
  static let settingsCard = Color(red: 0.98, green: 0.96, blue: 0.93)
  static let settingsCardAlt = Color(red: 0.91, green: 0.89, blue: 0.85)
  static let settingsNavActive = Color(red: 0.10, green: 0.10, blue: 0.10)
  static let settingsText = Color(red: 0.10, green: 0.10, blue: 0.10)
  static let settingsTextSecondary = Color(red: 0.24, green: 0.24, blue: 0.24)
  static let settingsTextTertiary = Color(red: 0.42, green: 0.42, blue: 0.42)
  static let settingsAccentGreen = Color(red: 0.30, green: 0.62, blue: 0.35)
  static let settingsAccentAmber = Color(red: 0.78, green: 0.55, blue: 0.15)
  static let settingsAccentRed = Color(red: 0.80, green: 0.28, blue: 0.22)
  static let settingsAccentBlue = Color(red: 0.20, green: 0.45, blue: 0.75)

  // MARK: Quiet Frost — the single overlay design language
  //
  // Every floating surface (style-3 capsule, shortcut deck, top transcript
  // panel, bottom indicator, headset toast, selection-ask) renders with the
  // same recipe: `.ultraThinMaterial` under `frostTint`, hairline
  // `frostBorder`, and NEVER a drop shadow. Before this consolidation there
  // were three competing languages — warm ink glass, frosted capsule, and an
  // opaque light-paper sheet — which is what made the overlays feel unrelated
  // when two happened to be onscreen at once.

  /// Dark tint over the frosted material. Deliberately light: the wallpaper's
  /// hue bleeds through so overlays read as glass, not as painted panels.
  static let frostTint = Color.black.opacity(0.42)
  /// Hairline edge. One value, one width — the old 1px/0.5px split along the
  /// "deck vs capsule" line was the most visible seam between the languages.
  static let frostBorder = Color.white.opacity(0.13)
  static let frostBorderWidth: CGFloat = 0.5
  /// Internal rules (column dividers, meter-bridge edges, header underlines).
  /// Lighter than the outer `frostBorder`: at the outer weight a panel with
  /// four internal rules reads as a wireframe grid rather than one surface.
  static let frostRule = Color.white.opacity(0.08)

  /// Recessed wells inside a frost surface (meter bridge, key caps, columns).
  static let frostWell = Color.white.opacity(0.05)
  static let frostWellRaised = Color.white.opacity(0.08)

  /// Text ramp. Pure white, not paper — warm text over a neutral frost read
  /// as a color cast rather than as warmth.
  static let frostText = Color.white.opacity(0.93)
  /// Frozen / secondary body text (post-capture, unoptimized column).
  static let frostTextDim = Color.white.opacity(0.66)
  /// Metadata, column headers, placeholder copy.
  static let frostTextFaint = Color.white.opacity(0.34)

  /// Deep teal-ink glass tones lifted from the app icon. Retained for the
  /// tally lamp's dial plate and bezel, which are a physical object rather
  /// than a glass surface; no flat panel should use these any more.
  static let ink0 = Color(red: 0.031, green: 0.067, blue: 0.102)
  static let ink1 = Color(red: 0.051, green: 0.102, blue: 0.141)
  static let ink2 = Color(red: 0.078, green: 0.153, blue: 0.212)
  static let ink3 = Color(red: 0.106, green: 0.200, blue: 0.278)

  /// Warm paper text tones, kept for the light Settings surfaces only.
  static let paper = Color(red: 0.949, green: 0.925, blue: 0.875)
  static let paperDim = Color(red: 0.949, green: 0.925, blue: 0.875).opacity(0.60)
  static let paperFaint = Color(red: 0.949, green: 0.925, blue: 0.875).opacity(0.34)

  /// Warm hairline borders on ink glass (tally lamp only).
  static let deckLine = Color(red: 0.922, green: 0.894, blue: 0.831).opacity(0.11)
  static let deckLineStrong = Color(red: 0.922, green: 0.894, blue: 0.831).opacity(0.20)

  /// The one accent. Live capture, primary actions, healthy LEDs, meter
  /// bridge. Replaces three near-identical literals (#5FD3C0, #61D9C2 twice)
  /// plus the style-2 card's IME-candidate green #7EF214, which was the
  /// loudest color in the app and belonged to no other surface.
  static let signalTeal = Color(red: 0.373, green: 0.827, blue: 0.753)

  /// The one warning/working color. Replaces the deck's near-duplicate
  /// #FFBD57 latch amber.
  static let lampAmber = Color(red: 1.0, green: 0.714, blue: 0.282)
  static let lampAmberHot = Color(red: 1.0, green: 0.890, blue: 0.690)

  // MARK: Spacing

  static let spacingXS: CGFloat = 4
  static let spacingSM: CGFloat = 8
  static let spacingMD: CGFloat = 12
  static let spacingLG: CGFloat = 16
  static let spacingXL: CGFloat = 24

  // MARK: Corner Radius

  /// Overlay corner ramp, collapsed from six ad-hoc values (28/20/14/13/9/5).
  /// `frostKey` for key caps and inline chips, `frostPanel` for any surface
  /// that holds body text, `frostSheet` for the selection-ask sheet. The
  /// latter two are equal by design — a bigger sheet does not get a rounder
  /// corner, or the family stops looking cut from one material.
  static let frostKey: CGFloat = 6
  static let frostPanel: CGFloat = 14
  static let frostSheet: CGFloat = 14

  static let cornerSM: CGFloat = 6
  static let cornerMD: CGFloat = 10
  static let cornerLG: CGFloat = 16

  // MARK: Floating Bar

  static let barWidth: CGFloat = 600
  static let barWidthCompact: CGFloat = 200
  static let barHeight: CGFloat = 40
  static let barBottomOffset: CGFloat = 32
  /// Style-2 status pill. Width is a floor — the pill hugs its content and
  /// the panel grows to fit. Height is the pill itself, down from the 130pt
  /// square the machined tally lamp needed.
  static let screenBottomIndicatorWidth: CGFloat = 132
  static let screenBottomIndicatorHeight: CGFloat = 32

  // MARK: Transcript Popup (hover preview above bar)

  static let transcriptPopupMaxHeight: CGFloat = 400
  static let transcriptPopupCorner: CGFloat = 14
  static let transcriptPopupGap: CGFloat = 8
  /// Expanded transcript panel cap. 1120 ran nearly edge to edge on a laptop,
  /// which read as a system banner rather than as a card sitting on the
  /// desktop; 860 keeps two comfortable columns and leaves the wallpaper
  /// visible on both sides.
  static let topTranscriptPanelMaxWidth: CGFloat = 860
  static let topTranscriptPanelCollapsedWidth: CGFloat = 380
  static let topTranscriptPanelOuterInset: CGFloat = 10
  static let topTranscriptPanelHeaderHeight: CGFloat = 34
  static let topTranscriptPanelCollapsedHeaderHeight: CGFloat = 34
  static let topTranscriptPanelMeterBridgeHeight: CGFloat = 13
  static let topTranscriptPanelColumnHeaderHeight: CGFloat = 24
  static let topTranscriptPanelHorizontalPadding: CGFloat = 12
  static let topTranscriptPanelBodyTopPadding: CGFloat = 6
  static let topTranscriptPanelBodyBottomPadding: CGFloat = 8
  static let topTranscriptPanelBodyFontSize: CGFloat = 13
  /// 13pt body at 1.62 line-height, matching the mockup's airier columns.
  static let topTranscriptPanelBodyLineSpacing: CGFloat = 5
  static let topTranscriptPanelTopOffset: CGFloat = 10
  static let topTranscriptPanelBottomMargin: CGFloat = 12

  // MARK: Animation

  static let springSnappy = Animation.spring(response: 0.35, dampingFraction: 0.8)
  static let springGentle = Animation.spring(response: 0.5, dampingFraction: 0.75)
  static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.65)
  static let easeQuick = Animation.easeOut(duration: 0.2)
  static let glassTint = Animation.easeInOut(duration: 0.5)
}

// MARK: - Frost Surface

/// The one background recipe every floating overlay uses: frosted material,
/// dark tint, hairline border, no shadow. Taking a `Shape` rather than a
/// radius lets the capsule surfaces share it without special-casing.
///
/// Deliberately shadowless. Shadows were rejected twice — they stack when
/// overlays overlap, and they defeat the point of a surface that is supposed
/// to sit *in* the desktop rather than hover above it.
struct FrostSurface<S: InsettableShape>: ViewModifier {
  let shape: S
  /// Optional state backlight bleeding in from the leading edge.
  var backlight: Color?

  func body(content: Content) -> some View {
    content
      .background {
        shape
          .fill(.ultraThinMaterial)
          .overlay { shape.fill(TF.frostTint) }
          .overlay {
            if let backlight {
              shape.fill(
                RadialGradient(
                  colors: [backlight.opacity(0.12), .clear],
                  center: .leading,
                  startRadius: 0,
                  endRadius: 180
                )
              )
            }
          }
      }
      .overlay {
        shape.strokeBorder(TF.frostBorder, lineWidth: TF.frostBorderWidth)
      }
  }
}

extension View {
  /// Applies the shared frost surface with an arbitrary shape.
  func frostSurface<S: InsettableShape>(_ shape: S, backlight: Color? = nil) -> some View {
    modifier(FrostSurface(shape: shape, backlight: backlight))
  }

  /// Applies the shared frost surface with a continuous rounded rectangle.
  func frostSurface(cornerRadius: CGFloat, backlight: Color? = nil) -> some View {
    modifier(
      FrostSurface(
        shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
        backlight: backlight
      )
    )
  }
}
