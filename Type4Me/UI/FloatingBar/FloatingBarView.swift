import SwiftUI

/// Cached font for text measurement (module-level to avoid generic-type static restriction).
private let floatingBarFont = NSFont.systemFont(ofSize: 14, weight: .medium)
private let expandedTranscriptLineHeight: CGFloat = 18

// MARK: - FloatingBarState Protocol

@MainActor
protocol FloatingBarState: AnyObject, Observable {
    var barPhase: FloatingBarPhase { get }
    var segments: [TranscriptionSegment] { get }
    var audioLevel: AudioLevelMeter { get }
    var currentMode: ProcessingMode { get }
    var feedbackMessage: String { get }
    var feedbackKind: FeedbackKind { get }
    var processingFinishTime: Date? { get }
    var transcriptionText: String { get }
    var recordingStartDate: Date? { get }
    var pinsTranscriptPopup: Bool { get }
    var liveOptimizedText: String { get }
    var liveOptimizationPhase: LiveOptimizationPhase { get }
    var supportsLiveOptimizationPreview: Bool { get }
    /// True when recording without SenseVoice streaming (Qwen3-only).
    var isQwen3OnlyMode: Bool { get }
    var effectiveProcessingLabel: String { get }
}

/// Dark-themed floating transcription bar with smooth morphing between states.
///
/// Design: single capsule container that animates width + content transitions.
/// - Recording: audio-reactive dot + live text + timer, breathing border
/// - Processing: rotating orb with breathing glow + "AI" badge
/// - Done: full progress bar + centered text
struct FloatingBarView<S: FloatingBarState>: View {

    let state: S


    @State private var breathe = false
    @State private var doneGlow = true
    /// High-water mark: only grows during recording, never shrinks (prevents ASR correction jitter)
    @State private var recordingPeakWidth: CGFloat = TF.barHeight
    @State private var processingStartDate: Date?
    @State private var doneStartDate: Date?
    @State private var isHovered = false
    @State private var rawFollowsLatest = true
    @State private var optimizedFollowsLatest = true
    @State private var rawHasNewContent = false
    @State private var optimizedHasNewContent = false
    @State private var rawScrollRequest = 0
    @State private var optimizedScrollRequest = 0
    @AppStorage(TranscriptDisplayMode.storageKey) private var transcriptDisplayModeValue = TranscriptDisplayMode.defaultValue
    @AppStorage(RecordingVisualStyle.storageKey) private var visualStyle = RecordingVisualStyle.defaultValue

    // MARK: - Transcript Popup

    private var recordingVisualStyle: RecordingVisualStyle {
        RecordingVisualStyle(rawValue: visualStyle) ?? .timeline
    }

    private var transcriptDisplayMode: TranscriptDisplayMode {
        TranscriptDisplayMode(rawValue: transcriptDisplayModeValue) ?? .expanded
    }

    private var showExpandedRecording: Bool {
        transcriptDisplayMode == .expanded
            && recordingVisualStyle.showsRecordingPanel
            && state.barPhase == .recording
            && !state.segments.isEmpty
    }

    private var shouldRenderCapsule: Bool {
        guard state.barPhase != .hidden else { return false }
        if showExpandedRecording { return false }
        if !recordingVisualStyle.showsRecordingPanel,
           state.barPhase == .preparing || state.barPhase == .recording {
            return false
        }
        return true
    }

    private var showTranscriptPopup: Bool {
        if state.pinsTranscriptPopup {
            return !state.segments.isEmpty
        }
        if state.barPhase == .recovering {
            return !state.segments.isEmpty
        }
        guard transcriptDisplayMode == .compact,
              recordingVisualStyle.showsRecordingPanel,
              isHovered,
              state.barPhase == .recording,
              !state.segments.isEmpty
        else { return false }
        let textWidth = measureText(state.transcriptionText)
        return textWidth + 66 > TF.barWidth
    }

    private var capsuleWidth: CGFloat {
        switch state.barPhase {
        case .preparing:
            return TF.barHeight
        case .recording:
            if state.segments.isEmpty {
                return state.isQwen3OnlyMode ? 110 : TF.barHeight
            }
            return recordingPeakWidth
        case .processing:
            return measureText(state.effectiveProcessingLabel) + 66.0
        case .recovering:
            return min(TF.barWidth, measureText(state.effectiveProcessingLabel) + 86.0)
        case .done:
            return feedbackWidth(for: state.feedbackMessage)
        case .error:
            return feedbackWidth(for: state.feedbackMessage)
        case .hidden:
            return TF.barHeight
        }
    }

    var body: some View {
        VStack(spacing: TF.transcriptPopupGap) {
            if showTranscriptPopup {
                transcriptPopup
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95, anchor: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if showExpandedRecording {
                expandedRecordingCard
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if shouldRenderCapsule {
                capsuleBar
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .background {
            FloatingBarHoverTracker { hovered in
                withAnimation(TF.springSnappy) {
                    isHovered = hovered
                }
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(TF.springSnappy, value: state.barPhase != .hidden)
        .animation(TF.springSnappy, value: shouldRenderCapsule)
        .animation(TF.springSnappy, value: visualStyle)
        .animation(TF.springSnappy, value: transcriptDisplayModeValue)
        .animation(TF.springSnappy, value: showExpandedRecording)
        .animation(TF.springSnappy, value: showTranscriptPopup)
        .onChange(of: state.barPhase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .onChange(of: state.segments) { _, newSegments in
            guard state.barPhase == .recording else { return }
            let text = newSegments.map(\.text).joined()
            let textWidth = measureText(text)
            let needed = min(TF.barWidth, max(TF.barHeight, textWidth + 66.0))
            if needed > recordingPeakWidth {
                // Growing: fixed velocity 250pt/s
                let distance = needed - recordingPeakWidth
                let duration = max(0.12, Double(distance / 250.0))
                withAnimation(.linear(duration: duration)) {
                    recordingPeakWidth = needed
                }
            } else if recordingPeakWidth - needed > 30 {
                // Large correction (hotword etc.): allow shrink
                withAnimation(.easeInOut(duration: 0.2)) {
                    recordingPeakWidth = needed
                }
            }
        }
    }

    // MARK: - Capsule Container

    private var capsuleBar: some View {
        barContent
            .animation(TF.springSnappy, value: state.barPhase)
            .frame(width: capsuleWidth, height: TF.barHeight)
            .clipShape(Capsule())
            .background {
                capsuleBackground
                    .clipShape(Capsule())
            }
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
            .animation(TF.springSnappy, value: state.barPhase)
    }

    // MARK: - Content by Phase

    @ViewBuilder
    private var barContent: some View {
        switch state.barPhase {
        case .preparing:
            preparingContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                    removal: .opacity
                ))
        case .recording:
            recordingContent
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
                ))
        case .processing:
            processingContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .scale(scale: 0.9).combined(with: .opacity)
                ))
        case .recovering:
            recoveringContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .scale(scale: 0.9).combined(with: .opacity)
                ))
        case .done:
            doneContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .opacity
                ))
        case .error:
            errorContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                    removal: .opacity
                ))
        case .hidden:
            EmptyView()
        }
    }

    private var preparingContent: some View {
        HStack(spacing: 0) {
            PreparingDot()
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingContent: some View {
        HStack(spacing: 10) {
            // Module 1: dot (fixed position, 14pt from left edge)
            RecordingDot(meter: state.audioLevel)

            // Module 2: text container (fills remaining space, grows with frame)
            // Uses overlay so text sizing never affects HStack layout
            if state.segments.isEmpty && state.isQwen3OnlyMode {
                Text(L("录音中", "Recording"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            } else if !state.segments.isEmpty {
                Color.clear
                    .overlay(alignment: .trailing) {
                        Text(state.transcriptionText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .mask {
                        if recordingPeakWidth >= TF.barWidth {
                            HStack(spacing: 0) {
                                LinearGradient(
                                    colors: [.clear, .white],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 12)
                                Rectangle()
                            }
                        } else {
                            Rectangle()
                        }
                    }
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
    }

    private var processingContent: some View {
        ZStack {
            Text(state.effectiveProcessingLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var recoveringContent: some View {
        HStack(spacing: 10) {
            PreparingDot()

            Text(state.effectiveProcessingLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
    }

    private var doneContent: some View {
        Group {
            if let icon = feedbackIcon {
                HStack(spacing: 10) {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(icon.color)
                    Text(state.feedbackMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
            } else {
                Text(state.feedbackMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var errorContent: some View {
        HStack(spacing: 10) {
            if let icon = feedbackIcon {
                Image(systemName: icon.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(icon.color)
            } else {
                ErrorDot()
            }

            Text(state.feedbackMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
    }

    /// SF Symbol + tint for the current feedback kind, or nil for the standard
    /// look (no leading icon, centered text — the existing `.done`/`.error` UI).
    private var feedbackIcon: (symbol: String, color: Color)? {
        switch state.feedbackKind {
        case .standard:
            return nil
        case .macActionSuccess:
            return ("checkmark.circle.fill", TF.success)
        case .macActionFailure:
            return ("xmark.circle.fill", TF.settingsAccentRed)
        case .macActionUnsure:
            return ("questionmark.circle.fill", TF.amber)
        }
    }

    // MARK: - Expanded Live Transcript

    private var usesDualTranscript: Bool {
        state.supportsLiveOptimizationPreview
            && state.liveOptimizationPhase.failureMessage == nil
    }

    private var expandedRecordingCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            rawTranscriptSection

            if usesDualTranscript {
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 1)
                optimizedTranscriptSection
            } else if let message = state.liveOptimizationPhase.failureMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TF.amber.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: TF.barWidth)
        .background {
            ZStack {
                glassBackground
                LinearGradient(
                    colors: [TF.recording.opacity(0.08), .clear],
                    startPoint: .bottomLeading,
                    endPoint: UnitPoint(x: 0.55, y: 0.45)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                .stroke(.white.opacity(breathe ? 0.18 : 0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
    }

    private var rawTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RecordingDot(meter: state.audioLevel)
                    .scaleEffect(0.72)
                    .frame(width: 16, height: 16)
                Text(L("原始转写", "RAW TRANSCRIPT"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 8)
                if !rawFollowsLatest {
                    transcriptFollowButton(
                        hasNewContent: rawHasNewContent,
                        action: {
                            rawScrollRequest &+= 1
                            rawFollowsLatest = true
                            rawHasNewContent = false
                        }
                    )
                }
            }

            transcriptViewport(
                text: state.transcriptionText,
                maxLines: usesDualTranscript ? 2 : 6,
                opacity: 0.82,
                isFollowingLatest: $rawFollowsLatest,
                hasNewContent: $rawHasNewContent,
                scrollRequest: rawScrollRequest
            )
        }
    }

    private var optimizedTranscriptSection: some View {
        let text = state.liveOptimizedText.isEmpty
            ? L("停顿约 0.8 秒后显示优化结果", "Optimized text appears after a short pause")
            : state.liveOptimizedText
        let opacity: Double = switch state.liveOptimizationPhase {
        case .stale, .updating: 0.72
        default: state.liveOptimizedText.isEmpty ? 0.42 : 0.96
        }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TF.amber.opacity(0.9))
                Text(L("优化预览", "OPTIMIZED PREVIEW"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.58))
                if let status = state.liveOptimizationPhase.statusLabel {
                    Text("· \(status)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.amber.opacity(0.78))
                }
                Spacer(minLength: 8)
                if !optimizedFollowsLatest {
                    transcriptFollowButton(
                        hasNewContent: optimizedHasNewContent,
                        action: {
                            optimizedScrollRequest &+= 1
                            optimizedFollowsLatest = true
                            optimizedHasNewContent = false
                        }
                    )
                }
            }

            transcriptViewport(
                text: text,
                maxLines: 4,
                opacity: opacity,
                isFollowingLatest: $optimizedFollowsLatest,
                hasNewContent: $optimizedHasNewContent,
                scrollRequest: optimizedScrollRequest
            )
        }

    }

    private func transcriptViewport(
        text: String,
        maxLines: Int,
        opacity: Double,
        isFollowingLatest: Binding<Bool>,
        hasNewContent: Binding<Bool>,
        scrollRequest: Int
    ) -> some View {
        FollowableTranscriptText(
            text: text,
            opacity: opacity,
            isFollowingLatest: isFollowingLatest,
            hasNewContent: hasNewContent,
            scrollRequest: scrollRequest
        )
        .frame(height: transcriptViewportHeight(for: text, maxLines: maxLines))
    }

    private func transcriptViewportHeight(for text: String, maxLines: Int) -> CGFloat {
        let width = TF.barWidth - 28
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: floatingBarFont]
        )
        let lines = max(1, Int(ceil(bounds.height / expandedTranscriptLineHeight)))
        return CGFloat(min(maxLines, lines)) * expandedTranscriptLineHeight
    }

    private func transcriptFollowButton(
        hasNewContent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if hasNewContent {
                    Circle()
                        .fill(TF.amber)
                        .frame(width: 4, height: 4)
                    Text(L("有新内容", "New text"))
                }
                Text(L("回到最新", "Latest"))
                Image(systemName: "arrow.down.to.line.compact")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Background & Border

    /// Dark frosted-glass fill shared by the capsule and the transcript popup.
    /// Shape-agnostic: the caller clips it (Capsule / RoundedRectangle).
    private var glassBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(red: 0.20, green: 0.15, blue: 0.09, opacity: 0.45)
        }
    }

    private var capsuleBackground: some View {
        ZStack {
            glassBackground

            if state.barPhase == .recording {
                AudioRipple(meter: state.audioLevel, style: recordingVisualStyle)
                    .id(recordingVisualStyle.rawValue)
                    .transition(.opacity)
            }

            if state.barPhase == .processing || state.barPhase == .recovering || state.barPhase == .done {
                ProcessingProgress(
                    finishTime: state.processingFinishTime,
                    processingStartDate: processingStartDate,
                    doneStartDate: doneStartDate
                )
                .transition(.opacity)
            }

            if state.barPhase == .error {
                LinearGradient(
                    colors: [TF.settingsAccentRed.opacity(0.16), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.45, y: 0.5)
                )
                .transition(.opacity)
            }
        }
    }

    private var capsuleBorder: some View {
        Capsule()
            .stroke(borderColor, lineWidth: 1)
    }

    private var borderColor: Color {
        switch state.barPhase {
        case .preparing:
            .white.opacity(0.08)
        case .recording:
            .white.opacity(breathe ? 0.20 : 0.10)
        case .processing:
            .white.opacity(0.12)
        case .recovering:
            .white.opacity(0.16)
        case .done:
            switch state.feedbackKind {
            case .macActionUnsure:
                TF.amber.opacity(0.30)
            case .macActionSuccess, .macActionFailure, .standard:
                TF.success.opacity(doneGlow ? 0.3 : 0.08)
            }
        case .error:
            TF.settingsAccentRed.opacity(0.22)
        case .hidden:
            .clear
        }
    }

    // MARK: - Phase Transitions

    private func handlePhaseChange(_ phase: FloatingBarPhase) {
        // Reset hover state on panel show/hide boundaries.
        // NSTrackingArea suspends events when the view is hidden (panel orderOut)
        // instead of firing mouseExited, so isHovered would otherwise leak across
        // recording sessions and auto-show the popup without any actual hover.
        if phase == .preparing || phase == .hidden {
            isHovered = false
        }
        switch phase {
        case .preparing:
            recordingPeakWidth = TF.barHeight
            processingStartDate = nil
            doneStartDate = nil
            breathe = false
            rawFollowsLatest = true
            optimizedFollowsLatest = true
            rawHasNewContent = false
            optimizedHasNewContent = false
            rawScrollRequest &+= 1
            optimizedScrollRequest &+= 1
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
        case .recording:
            recordingPeakWidth = TF.barHeight
            breathe = false
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
        case .processing:
            processingStartDate = Date()
            doneStartDate = nil
            breathe = false
        case .recovering:
            processingStartDate = Date()
            doneStartDate = nil
            breathe = false
        case .done:
            doneStartDate = Date()
            breathe = false
            doneGlow = true
            withAnimation(.easeOut(duration: 1.0)) { doneGlow = false }
        case .error:
            breathe = false
            doneGlow = false
        default:
            breathe = false
        }
    }

    private func feedbackWidth(for message: String) -> CGFloat {
        // Reserve extra room when an SF Symbol icon is shown (icon + spacing).
        let iconExtra: CGFloat = feedbackIcon == nil ? 0 : 26
        return measureText(message) + 66.0 + iconExtra
    }

    /// Measure actual rendered width using the same font as the floating bar text.
    private func measureText(_ string: String) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: floatingBarFont]).width)
    }

    // MARK: - Transcript Popup View

    private var transcriptPopup: some View {
        ScrollView(.vertical) {
            Text(state.transcriptionText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: TF.barWidth)
        .frame(maxHeight: TF.transcriptPopupMaxHeight)
        .background(glassBackground)
        .clipShape(RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous))
        .shadow(color: Color.black.opacity(0.3), radius: 8, y: -2)
    }
}

private struct FollowableTranscriptText: NSViewRepresentable {
    let text: String
    let opacity: Double
    @Binding var isFollowingLatest: Bool
    @Binding var hasNewContent: Bool
    let scrollRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TranscriptNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        scrollView.documentView = textView

        context.coordinator.attach(scrollView: scrollView, textView: textView)
        scrollView.layoutHandler = { [weak coordinator = context.coordinator] in
            coordinator?.layoutDocumentAndFollowIfNeeded()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        private var parent: FollowableTranscriptText
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var lastText = ""
        private var lastOpacity = -1.0
        private var lastScrollRequest: Int
        private var followingLatest: Bool
        private var suppressBoundsObservation = false
        private var isLayingOut = false

        init(parent: FollowableTranscriptText) {
            self.parent = parent
            self.lastScrollRequest = parent.scrollRequest
            self.followingLatest = parent.isFollowingLatest
        }

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            (scrollView as? TranscriptNSScrollView)?.userWillScrollHandler = { [weak self] in
                self?.userWillScroll()
            }
            (scrollView as? TranscriptNSScrollView)?.userDidScrollHandler = { [weak self] in
                self?.boundsDidChange()
            }
        }

        func detach() {
            (scrollView as? TranscriptNSScrollView)?.userWillScrollHandler = nil
            (scrollView as? TranscriptNSScrollView)?.userDidScrollHandler = nil
            NotificationCenter.default.removeObserver(self)
            (scrollView as? TranscriptNSScrollView)?.layoutHandler = nil
        }

        func update(parent: FollowableTranscriptText) {
            self.parent = parent
            guard let textView else { return }

            let textChanged = lastText != parent.text
            let appearanceChanged = lastOpacity != parent.opacity
            let requestedLatest = lastScrollRequest != parent.scrollRequest
            let oldOrigin = scrollView?.contentView.bounds.origin ?? .zero
            if !parent.isFollowingLatest {
                followingLatest = false
            }
            if requestedLatest {
                followingLatest = true
            }

            if textChanged || appearanceChanged {
                textView.textStorage?.setAttributedString(NSAttributedString(
                    string: parent.text,
                    attributes: [
                        .font: floatingBarFont,
                        .foregroundColor: NSColor.white.withAlphaComponent(parent.opacity),
                    ]
                ))
                lastText = parent.text
                lastOpacity = parent.opacity
            }

            layoutDocument()

            if followingLatest {
                scrollToBottom()
            } else if textChanged {
                restoreScrollOrigin(oldOrigin)
                if !parent.hasNewContent {
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.hasNewContent = true
                    }
                }
            }
            lastScrollRequest = parent.scrollRequest
        }

        func layoutDocumentAndFollowIfNeeded() {
            guard !isLayingOut else { return }
            layoutDocument()
            if followingLatest {
                scrollToBottom()
            }
        }

        private func userWillScroll() {
            followingLatest = false
            if parent.isFollowingLatest {
                parent.isFollowingLatest = false
            }
        }

        private func layoutDocument() {
            guard let scrollView, let textView, !isLayingOut else { return }
            isLayingOut = true
            defer { isLayingOut = false }

            let width = max(1, scrollView.contentSize.width)
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: .greatestFiniteMagnitude
            )
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let usedHeight = textView.layoutManager?
                .usedRect(for: textView.textContainer!)
                .height ?? expandedTranscriptLineHeight
            textView.frame = NSRect(
                x: 0,
                y: 0,
                width: width,
                height: max(scrollView.contentSize.height, ceil(usedHeight))
            )
        }

        private func restoreScrollOrigin(_ origin: NSPoint) {
            guard let scrollView else { return }
            suppressBoundsObservation = true
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            releaseBoundsObservation()
        }

        private func scrollToBottom() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let y = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            suppressBoundsObservation = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            releaseBoundsObservation()
        }

        private func releaseBoundsObservation() {
            DispatchQueue.main.async { [weak self] in
                self?.suppressBoundsObservation = false
            }
        }

        @objc private func boundsDidChange() {
            guard !suppressBoundsObservation, let scrollView,
                  let documentView = scrollView.documentView
            else { return }
            let maximumY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let isAtBottom = scrollView.contentView.bounds.origin.y >= maximumY - 2
            followingLatest = isAtBottom
            if parent.isFollowingLatest != isAtBottom {
                parent.isFollowingLatest = isAtBottom
            }
            if isAtBottom, parent.hasNewContent {
                parent.hasNewContent = false
            }
        }
    }
}

final class TranscriptNSScrollView: NSScrollView {
    var layoutHandler: (() -> Void)?
    var userWillScrollHandler: (() -> Void)?
    var userDidScrollHandler: (() -> Void)?

    func notifyUserWillScroll() {
        userWillScrollHandler?()
    }

    private func notifyUserDidScroll() {
        userDidScrollHandler?()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        notifyUserDidScroll()
    }
    override func layout() {
        super.layout()
        layoutHandler?()
    }
}

// MARK: - Recording Dot

struct PreparingDot: View {

    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(TF.recording.opacity(0.16), lineWidth: 1.6)
                .frame(width: 14, height: 14)

            Circle()
                .trim(from: 0.16, to: 0.76)
                .stroke(
                    TF.recording,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: 24, height: 24)
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Recording Dot

/// Audio-reactive red dot with dual concentric pulse rings.
struct RecordingDot: View {

    let meter: AudioLevelMeter

    @State private var outerPulse = false
    @State private var innerPulse = false

    var body: some View {
        TimelineView(.animation) { _ in
            let level = CGFloat(max(0.05, min(1.0, meter.current)))
            let levelSize: CGFloat = 10 + level * 12

            ZStack {
                // Outer slow pulse ring
                Circle()
                    .fill(TF.recording.opacity(outerPulse ? 0.0 : 0.25))
                    .frame(width: outerPulse ? 24 : 10, height: outerPulse ? 24 : 10)

                // Audio-reactive ring (smooth following)
                Circle()
                    .fill(TF.recording.opacity(0.18))
                    .frame(width: levelSize, height: levelSize)

                // Inner faster pulse ring (offset phase)
                Circle()
                    .stroke(TF.recording.opacity(innerPulse ? 0.2 : 0.0), lineWidth: 1)
                    .frame(width: innerPulse ? 18 : 12, height: innerPulse ? 18 : 12)

                // Core dot
                Circle()
                    .fill(TF.recording)
                    .frame(width: 10, height: 10)
                    .shadow(color: TF.recording.opacity(0.4), radius: 3)
            }
        }
        .frame(width: 24, height: 24)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                outerPulse = true
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.15)) {
                innerPulse = true
            }
        }
    }
}

// MARK: - Processing Orb

/// Purple/blue gradient sphere with rotation + breathing glow.
struct ProcessingOrb: View {

    @State private var rotation: Double = 0
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        Color(red: 0.40, green: 0.30, blue: 0.90),
                        Color(red: 0.30, green: 0.55, blue: 1.00),
                        Color(red: 0.40, green: 0.30, blue: 0.90),
                    ],
                    center: .center,
                    startAngle: .degrees(rotation),
                    endAngle: .degrees(rotation + 360)
                )
            )
            .frame(width: 22, height: 22)
            .scaleEffect(breathe ? 1.08 : 0.95)
            .shadow(
                color: Color(red: 0.35, green: 0.35, blue: 0.90).opacity(breathe ? 0.6 : 0.3),
                radius: breathe ? 10 : 5
            )
            .onAppear {
                withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}

struct ErrorDot: View {

    var body: some View {
        ZStack {
            Circle()
                .fill(TF.settingsAccentRed.opacity(0.18))
                .frame(width: 16, height: 16)

            Text("!")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TF.settingsAccentRed)
                .offset(y: -0.5)
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Recording Timer

/// Shows elapsed time since recording started, updates every second.
struct RecordingTimer: View {

    let startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = startDate.map { timeline.date.timeIntervalSince($0) } ?? 0
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            Text(String(format: "%02d:%02d", minutes, seconds))
        }
    }
}

// MARK: - Processing Progress

/// Particle progress bar with two-phase fill:
/// - Fast phase: 0% → 70% in 1.5s (ease-out)
/// - Slow cruise: 70% → 95% asymptotically (never stalls, always creeping)
/// When processingFinishTime is set, sprints toward 100% in 0.3s.
/// When doneStartDate is set, fills remaining gap to 100% in 0.15s.
/// All timing comes from parent — no @State, so view recreation is harmless.
struct ProcessingProgress: View {

    let finishTime: Date?
    var processingStartDate: Date?
    var doneStartDate: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let startRef = processingStartDate?.timeIntervalSinceReferenceDate ?? time
                let elapsed = time - startRef

                var progress: CGFloat
                let cruiseProgress: CGFloat
                if elapsed <= 1.5 {
                    // Fast phase: ease-out to 70%
                    let t = min(1.0, CGFloat(elapsed / 1.5))
                    cruiseProgress = t * 0.7 * (2.0 - t)
                } else {
                    // Slow cruise: 70% → 95%, exponential approach (τ=6s)
                    let slowT = 1.0 - exp(-(elapsed - 1.5) / 6.0)
                    cruiseProgress = 0.7 + CGFloat(slowT) * 0.25
                }

                if let finishTime {
                    let finishElapsed = time - finishTime.timeIntervalSinceReferenceDate
                    let sprintT = min(1.0, CGFloat(finishElapsed / 0.3))
                    progress = cruiseProgress + (1.0 - cruiseProgress) * sprintT
                } else {
                    progress = cruiseProgress
                }

                // Done: fill remaining gap to 100% in 0.15s
                if let doneStartDate {
                    let doneElapsed = time - doneStartDate.timeIntervalSinceReferenceDate
                    let doneT = min(1.0, CGFloat(doneElapsed / 0.15))
                    let base = max(progress, 0.7)
                    progress = base + (1.0 - base) * doneT
                }

                // Push soft leading edge past visible boundary when full
                let fillEdge = progress * size.width + (progress >= 0.99 ? 20 : 0)
                let center = size.height / 2

                var col = 0
                var xi: CGFloat = 0
                while xi <= size.width {
                    let nx = xi / size.width

                    // Color: white (left) → blue (right)
                    let t = min(1.0, max(0, nx))
                    let cr = 0.82 - t * 0.42
                    let cg = 0.85 - t * 0.25
                    let coreColor = Color(red: cr, green: cg, blue: 1.0)

                    // Density: filled region is dense, edge has a soft falloff
                    let distToEdge = fillEdge - xi
                    let edgeFade: CGFloat
                    if distToEdge > 20 {
                        edgeFade = 1.0  // fully filled
                    } else if distToEdge > 0 {
                        edgeFade = distToEdge / 20  // soft leading edge
                    } else if distToEdge > -15 {
                        edgeFade = max(0, (distToEdge + 15) / 15) * 0.3  // sparse scatter ahead
                    } else {
                        col += 1; xi += 2; continue
                    }

                    let count = Int(edgeFade * 200)
                    for j in 0..<count {
                        let h1 = hash(col, j)
                        let h2 = hash(col, j &+ 53)
                        let h3 = hash(col, j &+ 137)

                        // Scatter vertically, dense at center
                        let scatter = (h1 - 0.5) * 2
                        let py = center + scatter * abs(scatter) * size.height * 0.48

                        // Fade from center outward
                        let distFromCenter = abs(py - center)
                        let distFade = pow(max(0, 1.0 - distFromCenter / (size.height * 0.48)), 1.3)

                        // Twinkle
                        let freq = 3.0 + Double(h2) * 10.0
                        let twinkle = CGFloat(0.5 + 0.5 * sin(time * freq + Double(h3) * .pi * 2))

                        let op = Double(distFade * twinkle * edgeFade * 0.85)
                        guard op > 0.03 else { continue }

                        let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                        context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(op)))
                    }

                    col += 1
                    xi += 2
                }
            }
        }
        .drawingGroup()
    }

    private func hash(_ a: Int, _ b: Int) -> CGFloat {
        var h = a &* 374761393 &+ b &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(abs(h) % 10000) / 10000.0
    }
}

// MARK: - Audio Ripple

/// Audio visualizer with three selectable styles:
/// - classic: two sine-wave stroke lines
/// - dual: particles clustered around two sine-wave spines
/// - timeline: scrolling level history, right = now
struct AudioRipple: View {

    let meter: AudioLevelMeter
    let style: RecordingVisualStyle
    @State private var smootherSlow = LevelSmoother(timeConstant: 0.8)
    @State private var smootherFast = LevelSmoother(timeConstant: 0)
    @State private var startTime: Double = 0
    @State private var levelTimeline = LevelTimeline()

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                switch style {
                case .classic: drawClassicWaves(context: &context, size: size, time: time)
                case .dual: drawDualSpine(context: &context, size: size, time: time)
                case .timeline, .hidden: drawTimeline(context: &context, size: size, time: time)
                }
            }
        }
        .drawingGroup()
    }

    // MARK: - Classic Waves (stroke lines only)

    private func drawClassicWaves(context: inout GraphicsContext, size: CGSize, time: Double) {
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherSlow.target = max(0.012, rawLevel)
        let level = smootherSlow.update(time: time)
        let amp = min(1.0, pow(max(0, (level - 0.012) / 0.45), 0.7))
        let center = size.height / 2
        let maxAmp = size.height * (0.15 + amp * 0.35)
        let opacity = 0.4 + Double(amp) * 0.4

        for w in 0..<2 {
            let period: Double = w == 0 ? 130.0 : 90.0
            let speed: Double = w == 0 ? 1.0 : 0.7
            let phase: Double = w == 0 ? 0.0 : 1.3

            var path = Path()
            var first = true
            var xi: CGFloat = 0
            while xi <= size.width {
                let nx = Double(xi / size.width)
                let env = 0.07 + pow(nx, 1.5) * (0.10 + Double(amp))
                let y = center + CGFloat(sin(Double(xi) / period * .pi * 2 + time * speed * .pi + phase) * env) * maxAmp
                if first { path.move(to: CGPoint(x: xi, y: y)); first = false }
                else { path.addLine(to: CGPoint(x: xi, y: y)) }
                xi += 2
            }

            context.stroke(path, with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.82, green: 0.85, blue: 1.0).opacity(opacity * 0.7),
                    Color(red: 0.40, green: 0.60, blue: 1.0).opacity(opacity)
                ]),
                startPoint: CGPoint(x: 0, y: center),
                endPoint: CGPoint(x: size.width, y: center)
            ), lineWidth: 1.5)
        }
    }

    // MARK: - Dual Spine Particles

    private func drawDualSpine(context: inout GraphicsContext, size: CGSize, time: Double) {
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherSlow.target = max(0.012, rawLevel)
        let level = smootherSlow.update(time: time)
        let amp = min(1.0, pow(max(0, (level - 0.012) / 0.45), 0.7))
        let center = size.height / 2
        let maxAmp = size.height * (0.15 + amp * 0.35)
        let levelBright: CGFloat = 0.75 + amp * 0.25
        let bandHalf: CGFloat = size.height * (0.2 + amp * 0.3)

        var xi: CGFloat = 0
        var col = 0
        while xi <= size.width {
            let nx = xi / size.width
            let env = 0.07 + pow(Double(nx), 1.5) * (0.10 + Double(amp))
            let s1y = center + CGFloat(sin(Double(xi) / 130.0 * .pi * 2 + time * .pi) * env) * maxAmp
            let s2y = center + CGFloat(sin(Double(xi) / 90.0 * .pi * 2 + time * 0.7 * .pi) * env) * maxAmp
            let localAmp = (abs(s1y - center) + abs(s2y - center)) / 2
            let localIntensity = min(1.0, localAmp / max(maxAmp * 0.5, 1))
            let posBright: CGFloat = 0.6 + pow(nx, 0.8) * 0.4

            let cr: Double = 0.82 - Double(nx) * 0.42
            let cg: Double = 0.85 - Double(nx) * 0.25
            let coreColor = Color(red: cr, green: cg, blue: 1.0)

            let count = 160 + Int(localIntensity * 120)
            let posScale: CGFloat = 0.4 + pow(nx, 0.8) * 0.6
            let localBand = bandHalf * posScale * (0.5 + amp * 1.0)

            for j in 0..<count {
                let h1 = hash(col, j)
                let h2 = hash(col, j &+ 53)
                let h3 = hash(col, j &+ 137)
                let h5 = hash(col, j &+ 293)

                let spineY = h5 > 0.5 ? s1y : s2y
                let scatter = (h1 - 0.5) * 2
                let py = spineY + scatter * abs(scatter) * localBand

                let distFromSpine = abs(py - spineY)
                let normDist = distFromSpine / max(localBand, 1)
                let distFade: CGFloat = normDist < 0.25 ? 1.0 : max(0, 1.0 - (normDist - 0.25) / 0.75)

                let freq = 3.0 + Double(h2) * 10.0
                let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

                let baseOp = posBright * distFade * twinkle * levelBright
                guard baseOp > 0.02 else { continue }

                let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
            }

            col += 1
            xi += 2
        }
    }

    // MARK: - Timeline Particles (scrolling history)

    private func drawTimeline(context: inout GraphicsContext, size: CGSize, time: Double) {
        if startTime == 0 { DispatchQueue.main.async { startTime = time } }
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherFast.target = max(0.005, rawLevel)
        let smoothed = smootherFast.update(time: time)
        let levels = levelTimeline.update(time: time, currentLevel: smoothed)

        let center = size.height / 2
        let bufCount = levels.count
        let colCount = Int(size.width / 2) + 1

        for col in 0..<colCount {
            let xi = CGFloat(col) * 2
            let nx = xi / size.width

            let histIdx = min(Int(nx * CGFloat(bufCount - 1)), bufCount - 1)
            let histLevel = levels[histIdx]
            let amp = min(1.0, pow(max(0, (histLevel - 0.08) / 0.62), 0.85))

            let bandHalf = size.height * (0.03 + amp * 0.45)
            let posBright: CGFloat = 0.4 + pow(nx, 0.8) * 0.3
            let levelBright: CGFloat = 0.45 + amp * 0.35

            let cr: Double = 0.82 - Double(nx) * 0.42
            let cg: Double = 0.85 - Double(nx) * 0.25
            let coreColor = Color(red: cr, green: cg, blue: 1.0)

            for j in 0..<180 {
                let h1 = hash(col, j)
                let h2 = hash(col, j &+ 53)
                let h3 = hash(col, j &+ 137)

                let scatter = (h1 - 0.5) * 2
                let py = center + scatter * abs(scatter) * bandHalf

                let freq = 3.0 + Double(h2) * 10.0
                let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

                let baseOp = posBright * twinkle * levelBright
                guard baseOp > 0.02 else { continue }

                let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
            }
        }
    }

    private func hash(_ a: Int, _ b: Int) -> CGFloat {
        var h = a &* 374761393 &+ b &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(abs(h) % 10000) / 10000.0
    }
}

/// Frame-rate-independent exponential smoothing for audio level.
private final class LevelSmoother {
    var current: CGFloat = 0
    var target: CGFloat = 0
    private var lastTime: Double = 0
    private let timeConstant: Double

    init(timeConstant: Double = 0.8) {
        self.timeConstant = timeConstant
    }

    func update(time: Double) -> CGFloat {
        if lastTime == 0 { lastTime = time; return current }
        let dt = min(time - lastTime, 0.05)
        lastTime = time
        if timeConstant <= 0 {
            current = target
        } else {
            let alpha = CGFloat(1.0 - exp(-dt / timeConstant))
            current += (target - current) * alpha
        }
        return current
    }
}

/// Scrolling level history: newest on right, drifts left over time.
/// Index 0 = oldest (leftmost), last = newest (rightmost).
private final class LevelTimeline {
    private static let bufferSize = 200
    private var levels: [CGFloat]
    private var lastTime: Double = 0
    private var accumulator: Double = 0
    private let scrollSpeed: Double = 50  // entries shifted per second

    init() {
        levels = Array(repeating: 0, count: Self.bufferSize)
    }

    func update(time: Double, currentLevel: CGFloat) -> [CGFloat] {
        if lastTime == 0 {
            lastTime = time
            return levels
        }
        let dt = min(time - lastTime, 0.05)
        lastTime = time

        accumulator += dt * scrollSpeed
        let shift = Int(accumulator)
        if shift > 0 {
            accumulator -= Double(shift)
            let actual = min(shift, Self.bufferSize)
            levels.removeFirst(actual)
            for _ in 0..<actual {
                levels.append(currentLevel)
            }
        }
        levels[levels.count - 1] = currentLevel
        return levels
    }
}

// MARK: - Hover Tracking (works even when app is not active)

/// Uses NSTrackingArea with `.activeAlways` so hover fires on a non-key,
/// non-activating NSPanel regardless of which app is in the foreground.
struct FloatingBarHoverTracker: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

final class HoverTrackingNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var enterWorkItem: DispatchWorkItem?

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        enterWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            // Re-check mouse position at trigger time: updateTrackingAreas()
            // sends synthetic mouseEntered when the tracking area is recreated
            // with the cursor inside (e.g. bar grows during recording).
            let mouseInView = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard self.bounds.contains(mouseInView) else { return }
            self.onHoverChanged?(true)
        }
        enterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        enterWorkItem?.cancel()
        onHoverChanged?(false)
    }
}
