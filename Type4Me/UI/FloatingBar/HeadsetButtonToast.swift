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

  private var label: String {
    switch keyType {
    case 0: return L("耳机音量 + 已识别", "Headset Volume + detected")
    case 1: return L("耳机音量 − 已识别", "Headset Volume − detected")
    default: return L("耳机中键已识别", "Headset center detected")
    }
  }

  private var icon: String {
    switch keyType {
    case 0: return "speaker.plus.fill"
    case 1: return "speaker.minus.fill"
    default: return "headphones"
    }
  }

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(TF.signalTeal)
        .frame(width: 6, height: 6)
      Image(systemName: icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(TF.paperDim)
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(TF.paper)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .frame(height: 32)
    .background(.ultraThinMaterial, in: Capsule())
    .background(TF.ink1.opacity(0.86), in: Capsule())
    .overlay(Capsule().stroke(TF.deckLineStrong, lineWidth: 1))
    .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 2)
  }
}

@MainActor
final class HeadsetButtonToastController {
  private let size = NSSize(width: 172, height: 36)
  private let panel: HeadsetButtonToastPanel
  private var hosting: NSHostingView<HeadsetButtonToastView>
  private var hideTask: DispatchWorkItem?
  private var generation = 0

  init() {
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
    hosting.rootView = HeadsetButtonToastView(keyType: keyType)
    hosting.frame = NSRect(origin: .zero, size: size)

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
