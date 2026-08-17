import Foundation

struct SpeculativeLLMThrottle: Sendable {
    static let debounceDuration: Duration = .milliseconds(800)
    static let minimumTextLength = 8
    static let minimumCharacterIncrement = 8
    private static let correctionTriggers = [
        "不对", "哦不", "不是", "算了", "改成", "应该是", "重说",
        "i mean", "actually", "change", "replace",
    ]

    enum Submission: Equatable, Sendable {
        case tooShort
        case deltaTooSmall
        case debounce
        case queued
        case duplicate
    }

    private(set) var lastStartedText = ""
    private var startedTexts: Set<String> = []
    private(set) var debounceText: String?
    private(set) var pendingText: String?
    private(set) var inFlight = false

    mutating func submit(_ text: String) -> Submission {
        guard text.count >= Self.minimumTextLength else {
            debounceText = nil
            pendingText = nil
            return .tooShort
        }
        guard !startedTexts.contains(text) else {
            debounceText = nil
            pendingText = nil
            return .duplicate
        }
        let bypassesMinimumIncrement = shouldBypassMinimumIncrement(for: text)
        guard lastStartedText.isEmpty
                || bypassesMinimumIncrement
                || text.count - lastStartedText.count >= Self.minimumCharacterIncrement
        else {
            debounceText = nil
            pendingText = nil
            return .deltaTooSmall
        }

        if inFlight {
            pendingText = text
            debounceText = nil
            return .queued
        }

        debounceText = text
        return .debounce
    }

    private func shouldBypassMinimumIncrement(for text: String) -> Bool {
        guard !lastStartedText.isEmpty else { return false }
        // A stable ASR rewrite is new source data even if its length did not grow.
        guard text.hasPrefix(lastStartedText) else { return true }
        let appended = text.dropFirst(lastStartedText.count)
        return Self.correctionTriggers.contains { trigger in
            appended.range(of: trigger, options: .caseInsensitive) != nil
        }
    }

    mutating func beginDebouncedRequest(for text: String) -> Bool {
        guard !inFlight, debounceText == text else { return false }
        debounceText = nil
        pendingText = nil
        lastStartedText = text
        startedTexts.insert(text)
        inFlight = true
        return true
    }

    mutating func requestCompleted(input: String) -> String? {
        guard inFlight, input == lastStartedText else { return nil }
        inFlight = false
        let next = pendingText
        pendingText = nil
        return next
    }

    mutating func reset() {
        lastStartedText = ""
        startedTexts.removeAll()
        debounceText = nil
        pendingText = nil
        inFlight = false
    }
}
