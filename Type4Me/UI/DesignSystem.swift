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

  // MARK: Signal Desk Palette (floating deck + tally lamp)

  /// Deep teal-ink glass tones lifted from the app icon.
  static let ink0 = Color(red: 0.031, green: 0.067, blue: 0.102)
  static let ink1 = Color(red: 0.051, green: 0.102, blue: 0.141)
  static let ink2 = Color(red: 0.078, green: 0.153, blue: 0.212)
  static let ink3 = Color(red: 0.106, green: 0.200, blue: 0.278)

  /// Warm paper text tones.
  static let paper = Color(red: 0.949, green: 0.925, blue: 0.875)
  static let paperDim = Color(red: 0.949, green: 0.925, blue: 0.875).opacity(0.60)
  static let paperFaint = Color(red: 0.949, green: 0.925, blue: 0.875).opacity(0.34)

  /// Warm hairline borders on ink glass.
  static let deckLine = Color(red: 0.922, green: 0.894, blue: 0.831).opacity(0.11)
  static let deckLineStrong = Color(red: 0.922, green: 0.894, blue: 0.831).opacity(0.20)

  /// Teal signal color: meter bridge, processing ring, live LEDs.
  static let signalTeal = Color(red: 0.373, green: 0.827, blue: 0.753)

  /// Hot filament amber for the tally lamp core and active LEDs.
  static let lampAmber = Color(red: 1.0, green: 0.714, blue: 0.282)
  static let lampAmberHot = Color(red: 1.0, green: 0.890, blue: 0.690)

  // MARK: Spacing

  static let spacingXS: CGFloat = 4
  static let spacingSM: CGFloat = 8
  static let spacingMD: CGFloat = 12
  static let spacingLG: CGFloat = 16
  static let spacingXL: CGFloat = 24

  // MARK: Corner Radius

  static let cornerSM: CGFloat = 6
  static let cornerMD: CGFloat = 10
  static let cornerLG: CGFloat = 16

  // MARK: Floating Bar

  static let barWidth: CGFloat = 600
  static let barWidthCompact: CGFloat = 200
  static let barHeight: CGFloat = 40
  static let barBottomOffset: CGFloat = 32
  static let screenBottomIndicatorWidth: CGFloat = 132
  static let screenBottomIndicatorHeight: CGFloat = 130

  // MARK: Transcript Popup (hover preview above bar)

  static let transcriptPopupMaxHeight: CGFloat = 400
  static let transcriptPopupCorner: CGFloat = 14
  static let transcriptPopupGap: CGFloat = 8
  static let topTranscriptPanelMaxWidth: CGFloat = 1120
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
  static let topTranscriptPanelBodyLineSpacing: CGFloat = 3
  static let topTranscriptPanelTopOffset: CGFloat = 10
  static let topTranscriptPanelBottomMargin: CGFloat = 12

  // MARK: Animation

  static let springSnappy = Animation.spring(response: 0.35, dampingFraction: 0.8)
  static let springGentle = Animation.spring(response: 0.5, dampingFraction: 0.75)
  static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.65)
  static let easeQuick = Animation.easeOut(duration: 0.2)
  static let glassTint = Animation.easeInOut(duration: 0.5)
}
