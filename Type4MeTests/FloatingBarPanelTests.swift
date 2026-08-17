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

    func testPanelUsesWiderLowerGeometry() throws {
        let (controller, panel) = try makeControllerAndPanel()
        defer { panel.orderOut(nil) }
        let mouseLocation = NSEvent.mouseLocation
        let screen = try XCTUnwrap(
            NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        )

        XCTAssertEqual(TF.barWidth, 600)
        XCTAssertEqual(TF.barBottomOffset, 32)
        XCTAssertEqual(panel.frame.width, 632, accuracy: 0.5)
        XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY + 16, accuracy: 0.5)
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


    func testLongDualTranscriptKeepsPanelWithinReservedSize() throws {
        let previousDisplayMode = UserDefaults.standard.string(forKey: TranscriptDisplayMode.storageKey)
        UserDefaults.standard.set(TranscriptDisplayMode.expanded.rawValue, forKey: TranscriptDisplayMode.storageKey)
        defer {
            if let previousDisplayMode {
                UserDefaults.standard.set(previousDisplayMode, forKey: TranscriptDisplayMode.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: TranscriptDisplayMode.storageKey)
            }
        }

        let state = AppState()
        state.currentMode = .formalWriting
        let (_, controller, panel) = try makeStateControllerAndPanel(state: state)
        defer { panel.orderOut(nil) }
        let expectedSize = panel.frame.size
        let raw = String(repeating: "这是需要保留的完整原始转写内容。", count: 200)
        let optimized = String(repeating: "这是持续优化后的完整内容。", count: 200)

        state.startRecording()
        state.markRecordingReady()
        state.setLiveTranscript(RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: false
        ))
        state.beginLiveOptimization(sourceText: raw)
        state.showLiveOptimizationResult(optimized, sourceText: raw)

        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            panel.contentView?.layoutSubtreeIfNeeded()
        }

        let hosting = try XCTUnwrap(
            panel.contentView as? NSHostingView<FloatingBarView<AppState>>
        )
        XCTAssertEqual(panel.frame.width, expectedSize.width, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, expectedSize.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, expectedSize.height)
        XCTAssertEqual(state.liveOptimizationPhase, .ready)
        let transcriptScrollViews = descendantViews(of: hosting)
            .compactMap { $0 as? NSScrollView }
            .filter { $0.documentView is NSTextView }
        let renderedTranscripts = transcriptScrollViews
            .compactMap { $0.documentView as? NSTextView }
            .map(\.string)
        XCTAssertTrue(renderedTranscripts.contains(raw))
        XCTAssertTrue(renderedTranscripts.contains(optimized))

        for scrollView in transcriptScrollViews {
            (scrollView as? TranscriptNSScrollView)?.notifyUserWillScroll()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let updatedRaw = raw + "补充信息。"
        let updatedOptimized = optimized + "已合并补充信息。"
        state.setLiveTranscript(RecognitionTranscript(
            confirmedSegments: [updatedRaw],
            partialText: "",
            authoritativeText: updatedRaw,
            isFinal: false
        ))
        state.beginLiveOptimization(sourceText: updatedRaw)
        state.showLiveOptimizationResult(updatedOptimized, sourceText: updatedRaw)
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            panel.contentView?.layoutSubtreeIfNeeded()
        }

        for scrollView in transcriptScrollViews {
            XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)
        }
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
