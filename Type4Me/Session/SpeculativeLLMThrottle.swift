import Foundation

struct SpeculativeLLMThrottle: Sendable {
    static let debounceDuration: Duration = .milliseconds(1_200)
    static let minimumTextLength = 4
    static let minimumCharacterIncrement = 20
    static let minimumRequestInterval: Duration = .seconds(5)
    static let maximumRequestsPerSession = 10

    private static let correctionTriggers = [
        "不对", "哦不", "不是", "算了", "改成", "应该是", "重说",
        "i mean", "actually", "change", "replace",
    ]
    private static let ignoredCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "，。！？；：、,.!?;:…—-_()[]{}\"'“”‘’")
    )

    enum Submission: Equatable, Sendable {
        case tooShort
        case deltaTooSmall
        case debounce
        case queued
        case duplicate
        case cooldown(Duration)
        case limitReached
        case circuitOpen
    }

    private(set) var lastStartedText = ""
    private var lastStartedFingerprint = ""
    private var startedFingerprints: Set<String> = []
    private(set) var debounceText: String?
    private(set) var pendingText: String?
    private(set) var inFlight = false
    private(set) var requestCount = 0
    private(set) var isCircuitOpen = false
    private var lastStartedAt: ContinuousClock.Instant?

    mutating func submit(
        _ text: String,
        now: ContinuousClock.Instant = .now
    ) -> Submission {
        guard !isCircuitOpen else { return .circuitOpen }
        let fingerprint = Self.fingerprint(text)
        guard fingerprint.count >= Self.minimumTextLength else {
            clearDebounceIfIdle()
            return .tooShort
        }
        guard !startedFingerprints.contains(fingerprint) else {
            clearDebounceIfIdle()
            return .duplicate
        }

        let bypassesMinimumIncrement = shouldBypassMinimumIncrement(for: text)
        let meaningfulIncrement = fingerprint.count - lastStartedFingerprint.count
        guard lastStartedFingerprint.isEmpty
                || bypassesMinimumIncrement
                || meaningfulIncrement >= Self.minimumCharacterIncrement
        else {
            clearDebounceIfIdle()
            return .deltaTooSmall
        }

        if inFlight {
            pendingText = text
            debounceText = nil
            return .queued
        }
        guard requestCount < Self.maximumRequestsPerSession else {
            debounceText = nil
            pendingText = nil
            return .limitReached
        }
        if let lastStartedAt {
            let elapsed = now - lastStartedAt
            if elapsed < Self.minimumRequestInterval {
                debounceText = nil
                return .cooldown(Self.minimumRequestInterval - elapsed)
            }
        }

        debounceText = text
        return .debounce
    }

    private mutating func clearDebounceIfIdle() {
        guard !inFlight else { return }
        debounceText = nil
    }

    private func shouldBypassMinimumIncrement(for text: String) -> Bool {
        guard !lastStartedText.isEmpty else { return false }
        return Self.correctionTriggers.contains { trigger in
            text.range(of: trigger, options: .caseInsensitive) != nil
                && lastStartedText.range(of: trigger, options: .caseInsensitive) == nil
        }
    }

    mutating func beginDebouncedRequest(
        for text: String,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        let fingerprint = Self.fingerprint(text)
        guard !isCircuitOpen,
              !inFlight,
              requestCount < Self.maximumRequestsPerSession,
              debounceText == text,
              !startedFingerprints.contains(fingerprint)
        else { return false }

        debounceText = nil
        pendingText = nil
        lastStartedText = text
        lastStartedFingerprint = fingerprint
        startedFingerprints.insert(fingerprint)
        lastStartedAt = now
        requestCount += 1
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

    mutating func tripCircuit() {
        isCircuitOpen = true
        inFlight = false
        debounceText = nil
        pendingText = nil
    }

    mutating func reset() {
        lastStartedText = ""
        lastStartedFingerprint = ""
        startedFingerprints.removeAll()
        debounceText = nil
        pendingText = nil
        inFlight = false
        requestCount = 0
        isCircuitOpen = false
        lastStartedAt = nil
    }

    private static func fingerprint(_ text: String) -> String {
        String(text.unicodeScalars.filter { !ignoredCharacters.contains($0) }).lowercased()
    }
}
