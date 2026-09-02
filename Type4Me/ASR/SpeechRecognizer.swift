@preconcurrency import AVFoundation
import Foundation

struct ASRRequestOptions: Sendable, Equatable {
    var enablePunc: Bool = true
    var hotwords: [String] = []
    var boostingTableID: String?
    var contextHistoryLength: Int = 20
    var bypassProxy: Bool = false
    /// Whether the client should discard the first ~400ms to avoid the start sound
    /// bleeding into recognition.
    ///
    /// True for the local microphone, where the cue plays into the same room. An
    /// external device gates its own tone before it opens the audio stream, so
    /// skipping there would throw away the user's first word instead.
    var skipsStartToneSamples: Bool = true
    /// When set, ASR clients connect to this URL instead of their default endpoint.
    var cloudProxyURL: String?
    var urlSessionConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        if bypassProxy {
            config.connectionProxyDictionary = [:]
        }
        return config
    }

    /// Shared URLSession for ASR WebSocket connections.
    /// Reusing one session across recordings keeps the TCP connection pool warm,
    /// saving ~150-300ms on each subsequent connect (skips TCP + TLS handshake).
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// The URLSession to use for ASR connections. Returns the shared session
    /// unless bypassProxy is set (which needs a custom configuration).
    var resolvedSession: URLSession {
        bypassProxy ? URLSession(configuration: urlSessionConfiguration) : Self.sharedSession
    }
}

enum ProxyBypassMode: String {
    case off, all, asr, llm

    static var current: ProxyBypassMode {
    ProxyBypassMode(rawValue: UserDefaults.standard.string(forKey: "tf_bypassProxy") ?? "off")
      ?? .off
    }

    var bypassASR: Bool { self == .all || self == .asr }
    var bypassLLM: Bool { self == .all || self == .llm }
}

enum TranscriptTextSource: String, Sendable, Equatable {
  case temporary
  case cumulative
}

struct RecognitionTranscript: Sendable, Equatable {
    let confirmedSegments: [String]
    let partialText: String
    let authoritativeText: String
    let isFinal: Bool
  /// Session-local semantic revision assigned by RecognitionSession.
  var revision: Int = 0
    /// Monotonic timestamp when the ASR client emitted this transcript.
    /// Used for pipeline latency diagnostics; excluded from Equatable.
    var emitTime: ContinuousClock.Instant = .now

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.confirmedSegments == rhs.confirmedSegments
            && lhs.partialText == rhs.partialText
            && lhs.authoritativeText == rhs.authoritativeText
            && lhs.isFinal == rhs.isFinal
      && lhs.revision == rhs.revision
    }

    static let empty = RecognitionTranscript(
        confirmedSegments: [],
        partialText: "",
        authoritativeText: "",
        isFinal: false
    )

    var composedText: String {
        let pieces = confirmedSegments + (partialText.isEmpty ? [] : [partialText])
        return pieces.joined()
    }

  /// The single text projection used by the panel, live optimization, and
  /// final insertion. Prefer the server's cumulative result and only fall
  /// back to locally composed utterances before it becomes available.
  var canonicalText: String {
        authoritativeText.isEmpty ? composedText : authoritativeText
    }

  var textSource: TranscriptTextSource {
    authoritativeText.isEmpty ? .temporary : .cumulative
  }

  var displayText: String { canonicalText }
}

enum InjectionOutcome: Sendable, Equatable {
    case inserted
    case copiedToClipboard
    /// Quick Note: kept in history, deliberately not typed and not put on the
    /// clipboard — the point is to leave whatever you were doing untouched.
    case savedAsNote

    var completionMessage: String {
        switch self {
        case .inserted:
            return L("已完成", "Done")
        case .copiedToClipboard:
            return L("已粘贴到剪贴板", "Copied to clipboard")
        case .savedAsNote:
            return L("已存为速记", "Saved as note")
        }
    }
}

enum RecognitionEvent: Sendable {
    case ready
    case transcript(RecognitionTranscript)
    case error(Error)
    case completed
    case finalizedEmpty
    case processingResult(text: String)
    case processingLabelOverride(String)
  case liveOptimizationStarted(sourceText: String, sourceRevision: Int, modeID: UUID)
  case liveOptimizationResult(
    text: String,
    sourceText: String,
    sourceRevision: Int,
    modeID: UUID
  )
    case liveOptimizationUnavailable(message: String)
  case liveOptimizationFailed(message: String, sourceText: String, sourceRevision: Int)
  case liveOptimizationLocked(sourceText: String, sourceRevision: Int)
    case llmRequestStarted(provider: String, model: String, attempt: Int)
  case llmRequestFinished(
    provider: String, model: String, attempt: Int, durationSeconds: Double, succeeded: Bool)
    case finalOptimizationFailed(message: String, sourceText: String)
    case recoveryStarted(text: String, message: String)
    case recoveryPrompt(text: String, message: String)
    case recoverySucceeded(text: String, message: String)
    case recoveryFailed(text: String, message: String)
    case recoveryInterrupted(text: String, message: String)
    case finalized(text: String, injection: InjectionOutcome)
    /// Mac Action mode: action result to surface in the floating bar with
    /// status-specific icon and color, holding for ~3 seconds.
    case macActionResult(message: String, status: MacActionResultStatus)
    /// Selection ask mode: show a separate answer panel and stream Markdown into it.
    case selectionAskStarted(question: String, selectedText: String)
    case selectionAskAnswerDelta(String)
    case selectionAskAnswerCompleted
}

struct LLMConfig: Sendable {
    let apiKey: String
    let model: String
    let baseURL: String

    init(apiKey: String, model: String, baseURL: String = "") {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }
}

protocol SpeechRecognizer: Sendable {
    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws
    func sendAudio(_ data: Data) async throws
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws
    func endAudio() async throws
    func disconnect() async
    var events: AsyncStream<RecognitionEvent> { get async }
}

extension SpeechRecognizer {
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
    }
}
