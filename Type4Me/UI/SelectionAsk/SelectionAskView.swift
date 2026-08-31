import AppKit
import SwiftUI

/// Quiet Frost. This sheet used to be the odd one out — an opaque warm-paper
/// card at 860×760 with document-window typography, while the other five
/// overlays were dark frosted glass. It now shares the same recipe: one
/// `frostSurface` for the sheet, `frostWell` for the turn cards nested inside
/// it (nested glass reads muddy), the `frostText` ramp, and no drop shadows.
struct SelectionAskView: View {
    let state: SelectionAskState
    let onClose: () -> Void
    let onFollowUp: () -> Void
    private let bottomAnchorID = "selectionAskBottomAnchor"

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        questionSection
                        ForEach(state.turns) { turn in
                            turnView(turn)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                        if state.turns.isEmpty {
                            answerSection
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.turns)
                }
                .onChange(of: state.turns) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
            }
            followUpBar
        }
        .clipShape(RoundedRectangle(cornerRadius: TF.frostSheet, style: .continuous))
        .frostSurface(cornerRadius: TF.frostSheet)
        .padding(10)
    }

    private var hairline: some View {
        Rectangle()
            .fill(TF.frostBorder)
            .frame(height: 0.5)
    }

    private var header: some View {
        HStack {
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                Text(L("随便问", "Ask Anything"))
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(TF.frostText)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.frostTextFaint)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.frostTextFaint)
                Text(state.question.isEmpty ? L("正在识别问题...", "Recognizing question...") : state.question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TF.frostText)
                Spacer()
                if hasSelectedText {
                    copyButton(text: state.selectedText, systemImage: "doc.on.doc")
                }
            }

            if hasSelectedText {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(TF.frostBorder)
                        .frame(width: 2)
                    Text(state.selectedText)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.frostTextDim)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                .padding(.leading, 22)
            }
        }
    }

    private var answerSection: some View {
        turnView(SelectionAskState.Turn(
            question: state.question,
            answer: answerText ?? "",
            isLoading: answerText == nil,
            errorMessage: errorText
        ))
    }

    private func turnView(_ turn: SelectionAskState.Turn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TF.frostTextFaint)
                Text(turn.question.isEmpty ? L("正在识别问题...", "Recognizing question...") : turn.question)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TF.frostText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            hairline

            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text(L("回答", "Answer").uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                Spacer()
                if !turn.answer.isEmpty {
                    copyButton(text: turn.answer, systemImage: "doc.on.doc")
                }
            }
            .foregroundStyle(TF.frostTextFaint)
            .padding(.horizontal, 14)
            .frame(height: 28)

            hairline

            Group {
                if let message = turn.errorMessage {
                    errorView(message)
                } else if turn.isLoading && turn.answer.isEmpty {
                    loadingView
                } else {
                    markdownView(turn.answer)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: TF.frostPanel, style: .continuous)
                .fill(TF.frostWell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TF.frostPanel, style: .continuous)
                .strokeBorder(TF.frostBorder, lineWidth: TF.frostBorderWidth)
        )
    }

    private var followUpBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(action: onFollowUp) {
                // Recording uses TF.recording, not the error red: an active
                // capture is a live state, not a failure, and reusing the
                // error color here would collide with the error view below.
                let tint = state.isRecordingFollowUp ? TF.recording : TF.signalTeal
                HStack(spacing: 7) {
                    Image(systemName: state.isRecordingFollowUp ? "stop.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 13, height: 13)
                    Text(state.isRecordingFollowUp ? L("停止追问", "Stop follow-up") : L("继续追问", "Ask follow-up"))
                        .font(.system(size: 11, weight: .semibold))
                    if state.isRecordingFollowUp {
                        VoiceBars(tint: tint)
                    }
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    Capsule().fill(tint.opacity(state.isRecordingFollowUp ? 0.18 : 0.14))
                )
                .overlay(
                    Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(L("正在思考...", "Thinking..."))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.frostTextDim)
        }
        .frame(minHeight: 140, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private func markdownView(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownRenderer.displayBlocks(from: markdown).enumerated()), id: \.offset) { _, block in
                Text(MarkdownRenderer.attributedString(from: block))
                    .font(.system(size: TF.topTranscriptPanelBodyFontSize))
                    .foregroundStyle(TF.frostText)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsAccentRed)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.frostText)
                .textSelection(.enabled)
        }
        .frame(minHeight: 110, alignment: .topLeading)
    }

    private var answerText: String? {
        if case .answered(let answer) = state.phase {
            return answer
        }
        return nil
    }

    private var errorText: String? {
        if case .error(let message) = state.phase {
            return message
        }
        return nil
    }

    private var hasSelectedText: Bool {
        !state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func copyButton(text: String, systemImage: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.frostTextFaint)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }
}

private struct VoiceBars: View {
    var tint: Color = TF.frostText
    @State private var active = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint.opacity(0.82))
                    .frame(width: 2.5, height: index.isMultiple(of: 2) ? 8 : 12)
                    .scaleEffect(y: active == index.isMultiple(of: 2) ? 1.35 : 0.72, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.45 + Double(index) * 0.08)
                            .repeatForever(autoreverses: true),
                        value: active
                    )
            }
        }
        .frame(width: 18)
        .onAppear { active = true }
    }
}
