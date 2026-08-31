import AppKit
import SwiftUI

enum HeadsetButtonFeedbackPreference {
  static let storageKey = "tf_headsetButtonFeedback"

  static var isEnabled: Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: storageKey) != nil else { return true }
    return defaults.bool(forKey: storageKey)
  }
}

private final class HeadsetButtonToastPanel: NSPanel {
  init(size: NSSize) {
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    level = .statusBar
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    animationBehavior = .none
    appearance = NSAppearance(named: .darkAqua)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private struct HeadsetButtonToastView: View {
  let keyType: Int

  static func label(for keyType: Int) -> String {
    switch keyType {
    case 0: return L("耳机音量 + 已识别", "Headset Volume + detected")
    case 1: return L("耳机音量 − 已识别", "Headset Volume − detected")
    default: return L("耳机中键已识别", "Headset center detected")
    }
  }

  private var label: String { Self.label(for: keyType) }

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(TF.signalTeal)
        .frame(width: 6, height: 6)
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(TF.frostText)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .frame(height: 32)
    .frostSurface(Capsule())
  }
}

@MainActor
final class HeadsetButtonToastController {
  /// The panel hugs the capsule exactly — the old 36pt height carried a 4pt
  /// allowance for a drop shadow that no longer exists.
  private static let height: CGFloat = 32
  /// Width is measured per label, not fixed. The capsule hugs its content, so
  /// a hard 172pt truncated the longer English strings ("Headset Volume +
  /// detected" needs ~202pt) while Chinese happened to fit.
  private static func size(for keyType: Int) -> NSSize {
    let label = HeadsetButtonToastView.label(for: keyType)
    let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
    // 12pt padding ×2 + dot(6) + gap(7).
    return NSSize(width: max(132, 12 * 2 + 6 + 7 + textWidth), height: height)
  }
  private var size: NSSize
  private let panel: HeadsetButtonToastPanel
  private var hosting: NSHostingView<HeadsetButtonToastView>
  private var hideTask: DispatchWorkItem?
  private var generation = 0

  init() {
    size = Self.size(for: 16)
    panel = HeadsetButtonToastPanel(size: size)
    hosting = NSHostingView(rootView: HeadsetButtonToastView(keyType: 16))
    hosting.sizingOptions = []
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = NSColor.clear.cgColor
    hosting.frame = NSRect(origin: .zero, size: size)
    panel.contentView = hosting
  }

  func show(keyType: Int) {
    guard HeadsetButtonFeedbackPreference.isEnabled else { return }

    generation &+= 1
    let currentGeneration = generation
    hideTask?.cancel()
    size = Self.size(for: keyType)
    hosting.rootView = HeadsetButtonToastView(keyType: keyType)
    hosting.frame = NSRect(origin: .zero, size: size)
    panel.setContentSize(size)

    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let screen else { return }
    let visible = screen.visibleFrame
    panel.setFrameOrigin(
      NSPoint(
        x: visible.maxX - size.width - 18,
        y: visible.maxY - size.height - 18
      )
    )

    panel.contentView?.layer?.removeAllAnimations()
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    let task = DispatchWorkItem { [weak self] in
      guard let self, self.generation == currentGeneration else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        self.panel.animator().alphaValue = 0
      } completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.generation == currentGeneration else { return }
          self.panel.orderOut(nil)
        }
      }
    }
    hideTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: task)
  }
}
