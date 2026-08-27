import AppKit
import os

/// Thread-safe flag for the detached sender to signal upload failure.
private final class UploadFailureFlag: Sendable {
  private let _value = OSAllocatedUnfairLock(initialState: false)
  var failed: Bool {
    get { _value.withLock { $0 } }
    set { _value.withLock { $0 = newValue } }
  }
}

actor RecognitionSession {

  // MARK: - State

  enum SessionState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case finishing
    case injecting
    case postProcessing  // Phase 3
    case recovering
  }

  enum RecoveryHotkeyAction: Equatable, Sendable {
    case notRecovering
    case prompted
    case interrupted
  }

  private(set) var state: SessionState = .idle

  var canStartRecording: Bool { state == .idle }

  /// Wait until the session reaches idle state, with a timeout.
  /// Returns true if idle was reached, false on timeout.
  func awaitIdle(timeout: Duration = .seconds(3)) async -> Bool {
    if state == .idle { return true }
    let deadline = ContinuousClock.now + timeout
    while state != .idle {
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return state == .idle
  }

  /// Exposed for testing; production code should use startRecording / stopRecording.
  func setState(_ newState: SessionState) {
    state = newState
  }

  /// Exposed for testing; production code should resolve modes through startRecording / switchMode.
  func currentModeForTesting() -> ProcessingMode {
    currentMode
  }

  // MARK: - Dependencies

  private let audioEngine = AudioCaptureEngine()
  private let injectionEngine = TextInjectionEngine()
  let historyStore = HistoryStore.shared
  private var asrClient: (any SpeechRecognizer)?

  private let logger = Logger(
    subsystem: "com.type4me.session",
    category: "RecognitionSession"
  )

  #if HAS_CLOUD_SUBSCRIPTION
    private var isCloudMode: Bool { activeProvider == .cloud }
  #endif

  /// Return the appropriate LLM client for the currently selected provider.
  private func currentLLMClient() -> any LLMClient {
    LLMRuntime.currentClient(isCloudMode: isCloudModeForLLM)
  }

  /// Load LLM credentials from the per-user credentials file.
  private func loadEffectiveLLMConfig() -> LLMConfig? {
    LLMRuntime.currentConfig(isCloudMode: isCloudModeForLLM)
  }

  private var isCloudModeForLLM: Bool {
    #if HAS_CLOUD_SUBSCRIPTION
      return isCloudMode
    #else
      return false
    #endif
  }

  private func currentASRModelLabel(for provider: ASRProvider) -> String? {
    let providerName = provider.displayName

    if provider == .sherpa {
      return "\(providerName) · \(ModelManager.selectedStreamingModel.displayName)"
    }

    guard let credentials = CredentialStore.loadASRConfig(for: provider)?.toCredentials() else {
      return providerName
    }

    let modelKeys = ["model", "resourceId", "devPid", "lmId"]
    let model =
      modelKeys
      .compactMap { credentials[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }

    guard let model else { return providerName }
    return "\(providerName) · \(model)"
  }

  private static func volcanoConfigFromEnvironment(
    _ environment: [String: String]
  ) -> VolcanoASRConfig? {
    var credentials = [
      "resourceId": environment["VOLC_RESOURCE_ID"]
        ?? VolcanoASRConfig.resourceIdSeedASR
    ]

    if let apiKey = nonEmptyEnvironmentValue("VOLC_API_KEY", in: environment) {
      credentials["authMode"] = VolcanoASRConfig.authModeAPIKey
      credentials["apiKey"] = apiKey
    } else if let appKey = nonEmptyEnvironmentValue("VOLC_APP_KEY", in: environment),
      let accessKey = nonEmptyEnvironmentValue("VOLC_ACCESS_KEY", in: environment)
    {
      credentials["authMode"] = VolcanoASRConfig.authModeLegacy
      credentials["appKey"] = appKey
      credentials["accessKey"] = accessKey
    } else {
      return nil
    }

    return VolcanoASRConfig(credentials: credentials)
  }

  private static func nonEmptyEnvironmentValue(
    _ key: String,
    in environment: [String: String]
  ) -> String? {
    guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }

  /// Pre-initialize audio subsystem so the first recording starts instantly.
  func warmUp() { audioEngine.warmUp() }

  /// Pre-warm TCP connection to the ASR endpoint so the next WebSocket
  /// connect skips the handshake. Called on app launch and after each recording.
  nonisolated func warmUpASRConnection() {
    Task.detached(priority: .utility) {
      await self.pingASREndpoint()
    }
  }

  private func pingASREndpoint() async {
    let endpoint: String
    #if HAS_CLOUD_SUBSCRIPTION
      if CredentialStore.selectedASRProvider == .cloud {
        endpoint = CloudConfig.apiEndpoint + "/health"
      } else {
        endpoint = currentASREndpoint()
      }
    #else
      endpoint = currentASREndpoint()
    #endif
    guard let url = URL(string: endpoint) else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "HEAD"
    req.timeoutInterval = 5
    _ = try? await ASRRequestOptions.sharedSession.data(for: req)
  }

  private func currentASREndpoint() -> String {
    let provider = CredentialStore.selectedASRProvider
    switch provider {
    case .volcano:
      return "https://openspeech.bytedance.com"
    case .stepfunBatch:
      return "https://api.stepfun.com"
    case .soniox:
      return "https://stt-rt.soniox.com"
    case .deepgram:
      return "https://api.deepgram.com"
    default:
      return ""
    }
  }

  // MARK: - Mode & Timing

  private var currentMode: ProcessingMode = .direct
  private var recordingStartTime: Date?
  private var currentConfig: (any ASRProviderConfig)?
  /// The ASR provider for the current session, captured at start time.
  /// stopRecording reads this, not the global setting.
  private var activeProvider: ASRProvider = .volcano
  private var currentRecordID: String?
  private var currentRecordingCreatedAt: Date?
  private var currentArchivedAudio: ArchivedAudio?

  // MARK: - UI Callback

  /// Called on every ASR event so the UI layer can update.
  /// Set by AppDelegate to bridge actor → @MainActor.
  private var onASREvent: (@Sendable (RecognitionEvent) -> Void)?

  func setOnASREvent(_ handler: @escaping @Sendable (RecognitionEvent) -> Void) {
    onASREvent = handler
  }

  /// Called with normalized audio level (0..1) for UI visualization.
  private var onAudioLevel: (@Sendable (Float) -> Void)?

  func setOnAudioLevel(_ handler: @escaping @Sendable (Float) -> Void) {
    onAudioLevel = handler
  }

  // MARK: - Session generation (prevents zombie tasks after forceReset)

  private var sessionGeneration: Int = 0

  // MARK: - Accumulated text

  private let maxRecordingDuration: TimeInterval = 1200  // 20 minutes

  private var currentTranscript: RecognitionTranscript = .empty
  private var eventConsumptionTask: Task<Void, Never>?
  private var maxDurationTask: Task<Void, Never>?
  private var firstStreamingTextTimeoutTask: Task<Void, Never>?
  private var hasEmittedReadyForCurrentSession = false
  private var audioChunkContinuation: AsyncStream<Data>.Continuation?
  private var audioChunkSenderTask: Task<Void, Never>?
  private var uploadFailureFlag: UploadFailureFlag?
  private var lastStreamingError: Error?
  private var recoveryTask: Task<Void, Never>?
  private var recoveryInterruptPromptShown = false
  private var recoveryRecordId: String?
  private var recoveryCreatedAt: Date?
  private var recoveryPartialText = ""
  private var recoveryDuration: Double = 0
  private var recoveryModeName: String?
  private var recoveryProvider: ASRProvider = .volcano
  private var recoveryASRModel: String?

  /// Flipped to true when mic level exceeds threshold during recording.
  /// When false at stop time, we skip the full ASR teardown (no speech = nothing to finalize).
  private var speechDetected = false
  private static let speechLevelThreshold: Float = 0.15

  private func markSpeechDetected() {
    if !speechDetected {
      speechDetected = true
    }
  }

  // MARK: - Prompt context (selected text + clipboard captured at recording start)

  private struct PendingPromptContextCapture: Sendable {
    let id: UUID
    let generation: Int
    let requirements: PromptContext.CaptureRequirements
    let task: Task<PromptContext, Never>
  }

  private var promptContext: PromptContext = .empty
  private var capturedPromptContextRequirements: PromptContext.CaptureRequirements = []
  private var pendingPromptContextCapture: PendingPromptContextCapture?
  /// Serializes temporary Command+C fallbacks across consecutive sessions.
  private var lastPromptContextCaptureTask: Task<PromptContext, Never>?
  private var lastPromptContextCaptureID: UUID?

  private func resetPromptContextCapture(
    for mode: ProcessingMode,
    generation: Int
  ) {
    promptContext = .empty
    capturedPromptContextRequirements = []
    pendingPromptContextCapture = nil
    schedulePromptContextCaptureIfNeeded(for: mode, generation: generation)
  }

  private func schedulePromptContextCaptureIfNeeded(
    for mode: ProcessingMode,
    generation: Int
  ) {
    let requiresSelection = mode.executionKind == .selectionAsk
      || mode.id == ProcessingMode.macActionId
    let requested = PromptContext.captureRequirements(
      for: mode.prompt,
      requiresSelection: requiresSelection
    )
    let pendingRequirements = pendingPromptContextCapture?.generation == generation
      ? pendingPromptContextCapture?.requirements ?? []
      : []
    let covered = capturedPromptContextRequirements.union(pendingRequirements)
    let missing = requested.subtracting(covered)

    guard !missing.isEmpty else {
      if requested.isEmpty {
        DebugFileLogger.log("prompt context capture skipped mode=\(mode.name) requirements=none")
      }
      return
    }

    let previousTask = lastPromptContextCaptureTask
    let previousPending = pendingPromptContextCapture
    let baseContext = promptContext
    let id = UUID()
    let combinedRequirements = covered.union(missing)
    DebugFileLogger.log(
      "prompt context capture scheduled mode=\(mode.name) "
        + "missing=\(missing.logDescription) total=\(combinedRequirements.logDescription)"
    )

    let task = Task.detached {
      let previousResult = await previousTask?.value
      let base: PromptContext
      if previousPending?.generation == generation, let previousResult {
        base = previousResult
      } else {
        base = baseContext
      }

      let captureStartedAt = ContinuousClock.now
      let addition = await PromptContext.capture(requirements: missing)
      DebugFileLogger.log(
        "prompt context capture completed requirements=\(missing.logDescription) "
          + "duration=\(ContinuousClock.now - captureStartedAt)"
      )
      return base.merging(addition)
    }

    lastPromptContextCaptureTask = task
    lastPromptContextCaptureID = id
    pendingPromptContextCapture = PendingPromptContextCapture(
      id: id,
      generation: generation,
      requirements: combinedRequirements,
      task: task
    )
    Task { [weak self] in
      _ = await task.value
      await self?.clearPromptContextCaptureBarrier(id: id)
    }
  }

  private func clearPromptContextCaptureBarrier(id: UUID) {
    guard lastPromptContextCaptureID == id else { return }
    lastPromptContextCaptureTask = nil
    lastPromptContextCaptureID = nil
  }

  private func resolvePromptContextIfNeeded(generation: Int) async {
    while let pending = pendingPromptContextCapture,
      pending.generation == generation
    {
      let context = await pending.task.value
      guard sessionGeneration == generation else { return }
      guard pendingPromptContextCapture?.id == pending.id else { continue }

      promptContext = context
      capturedPromptContextRequirements.formUnion(pending.requirements)
      pendingPromptContextCapture = nil
      DebugFileLogger.log(
        "prompt context capture resolved requirements="
          + capturedPromptContextRequirements.logDescription
      )
      return
    }
  }

  /// Bundle identifier of the frontmost app when recording started.
  /// Used to select app-specific snippet rules.
  private var targetBundleId: String?

  // MARK: - Live optimization (fire during recording pauses)

  private var transcriptRevisionTracker = TranscriptRevisionTracker()
  private var liveOptimization = LiveOptimizationCoordinator()
  private var speculativeLLMTask: Task<String?, Never>?
  private var speculativeDebounceTask: Task<Void, Never>?
  private var speculativeThrottle = SpeculativeLLMThrottle()
  private var speculativeLLMUnavailable = false
  /// Persists across recordings while the app is running; entries expire after 30 minutes.
  private let llmRequestMemoizer = LLMRequestMemoizer()
  /// Stores the latest final LLM failure until the retry/raw decision UI consumes it.
  private var pendingLLMError: Error?
  private var pendingSelectionAskConversationContext = ""
  /// When true, skip text injection (paste) but still save to clipboard & history.
  private var injectionAborted = false
  // Decision used when a final LLM request fails and the user chooses retry/raw.
  private enum FinalOptimizationDecision {
    case retry
    case useRaw
  }

  private struct LLMRequestToken {
    let provider: String
    let model: String
    let attempt: Int
    let startedAt: ContinuousClock.Instant
    let sessionGeneration: Int
  }
  private var finalOptimizationDecisionCont: CheckedContinuation<FinalOptimizationDecision, Never>?
  private var finalOptimizationDecisionTimeoutTask: Task<Void, Never>?
  private var llmAttemptCounter = 0
  /// Continuation resumed when first non-empty streaming text arrives (for short-recording wait).
  private var firstStreamingTextCont: CheckedContinuation<Bool, Never>?

  // MARK: - Toggle

  func toggleRecording() async {
    switch state {
    case .idle:
      await startRecording()
    case .recording:
      await stopRecording()
    case .recovering:
      _ = await handleRecoveryHotkeyPress()
    default:
      logger.warning("toggleRecording ignored in state: \(String(describing: self.state))")
    }
  }

  func handleRecoveryHotkeyPress() async -> RecoveryHotkeyAction {
    guard state == .recovering else { return .notRecovering }

    if !recoveryInterruptPromptShown {
      recoveryInterruptPromptShown = true
      onASREvent?(
        .recoveryPrompt(
          text: recoveryPartialText,
          message: L(
            "正在恢复上一次识别。继续按下将打断当前恢复并重新开始录音。",
            "Recovering the previous dictation. Press again to interrupt recovery and start a new recording."
          )
        ))
      return .prompted
    }

    await interruptRecoveryForRestart()
    return .interrupted
  }

  private func interruptRecoveryForRestart() async {
    DebugFileLogger.log("recovery interrupted by hotkey")
    recoveryTask?.cancel()
    recoveryTask = nil
    await persistCurrentHistory(
      rawText: recoveryPartialText,
      processedText: nil,
      finalText: recoveryPartialText,
      status: "recovery_interrupted"
    )
    onASREvent?(
      .recoveryInterrupted(
        text: recoveryPartialText,
        message: L("已停止恢复，开始新的录音", "Recovery stopped. Starting a new recording.")
      ))
    clearRecoveryState()
    state = .idle
    currentTranscript = .empty
    warmUpASRConnection()
  }

  // MARK: - Start

  func startRecording(mode: ProcessingMode = .direct) async {
    if state == .finishing || state == .injecting || state == .postProcessing
      || state == .recovering
    {
      NSLog(
        "[Session] startRecording: blocked, current session still processing (state=%@)",
        String(describing: state))
      DebugFileLogger.log("startRecording blocked: still processing state=\(state)")
      return
    }
    if state != .idle {
      NSLog("[Session] startRecording: forcing reset from state=%@", String(describing: state))
      DebugFileLogger.log("session forcing reset from state=\(state)")
      await forceReset()
    }

    stoppedByMaxDuration = false
    targetBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let provider = CredentialStore.selectedASRProvider
    activeProvider = provider

    #if HAS_CLOUD_SUBSCRIPTION
      if provider == .cloud {
        let canUse = await CloudQuotaManager.shared.canUse()
        if !canUse {
          SoundFeedback.playError()
          state = .idle
          onASREvent?(
            .error(
              NSError(
                domain: "Type4Me", code: -10,
                userInfo: [NSLocalizedDescriptionKey: L("免费额度已用完", "Free quota exhausted")]
              )))
          onASREvent?(.completed)
          return
        }
      }
    #endif

    let effectiveMode = ASRProviderRegistry.resolvedMode(for: mode, provider: provider)
    if effectiveMode.executionKind != .selectionAsk {
      pendingSelectionAskConversationContext = ""
    }
    sessionGeneration &+= 1
    let myGeneration = sessionGeneration

    self.currentMode = effectiveMode
    self.recordingStartTime = nil
    hasEmittedReadyForCurrentSession = false
    injectionAborted = false
    speculativeThrottle.reset()
    speculativeLLMUnavailable = false
    pendingLLMError = nil
    lastStreamingError = nil
    llmAttemptCounter = 0
    transcriptRevisionTracker.reset()
    liveOptimization.reset()
    state = .starting

    // Load credentials for selected provider
    let config: any ASRProviderConfig

    if provider.isLocal {
      // Local providers: use default model directory if no saved config
      if let savedConfig = CredentialStore.loadASRConfig(for: provider) {
        config = savedConfig
        NSLog("[Session] Loaded %@ config from file store", provider.rawValue)
      } else if let defaultConfig = SherpaASRConfig(credentials: [
        "modelDir": ModelManager.defaultModelsDir
      ]) {
        config = defaultConfig
        NSLog("[Session] Using default model directory for %@", provider.rawValue)
      } else {
        NSLog("[Session] Failed to create default config for %@!", provider.rawValue)
        SoundFeedback.playError()
        state = .idle
        onASREvent?(
          .error(
            NSError(
              domain: "Type4Me", code: -1,
              userInfo: [NSLocalizedDescriptionKey: L("本地模型未配置", "Local model not configured")])))
        onASREvent?(.completed)
        return
      }
      // Verify required models are downloaded
      if !ModelManager.shared.areRequiredModelsAvailable() {
        NSLog("[Session] Required local models not downloaded for %@", provider.rawValue)
        SoundFeedback.playError()
        state = .idle
        onASREvent?(
          .error(
            NSError(
              domain: "Type4Me", code: -3,
              userInfo: [
                NSLocalizedDescriptionKey: L("请先下载识别模型", "Please download ASR models first")
              ])))
        onASREvent?(.completed)
        return
      }
    } else if let savedConfig = CredentialStore.loadASRConfig(for: provider) {
      config = savedConfig
      NSLog("[Session] Loaded %@ credentials from file store", provider.rawValue)
    } else if provider == .volcano,
      let volcConfig = Self.volcanoConfigFromEnvironment(
        ProcessInfo.processInfo.environment
      )
    {
      // Env var fallback (volcano only, for dev convenience)
      do {
        try CredentialStore.saveASRCredentials(for: .volcano, values: volcConfig.toCredentials())
        NSLog("[Session] Loaded credentials from env vars and persisted to file")
      } catch {
        NSLog(
          "[Session] WARNING: env var credentials loaded but failed to persist: %@",
          String(describing: error))
      }
      config = volcConfig
    } else {
      NSLog("[Session] No ASR credentials found for provider=%@!", provider.rawValue)
      SoundFeedback.playError()
      state = .idle
      onASREvent?(
        .error(
          NSError(
            domain: "Type4Me", code: -1,
            userInfo: [NSLocalizedDescriptionKey: L("未配置 API 凭证", "API credentials not configured")]
          )))
      onASREvent?(.completed)
      return
    }

    self.currentConfig = config

    guard let client = ASRProviderRegistry.createClient(for: provider) else {
      NSLog("[Session] No client implementation for provider=%@", provider.rawValue)
      SoundFeedback.playError()
      state = .idle
      onASREvent?(
        .error(
          NSError(
            domain: "Type4Me", code: -2,
            userInfo: [
              NSLocalizedDescriptionKey: L(
                "\(provider.displayName) 暂不支持", "\(provider.displayName) not yet supported")
            ])))
      onASREvent?(.completed)
      return
    }
    self.asrClient = client

    // Load hotwords
    let hotwords = HotwordStorage.loadEffective()
    let biasSettings = ASRBiasSettingsStorage.load()
    let requestOptions = ASRRequestOptions(
      enablePunc: true,
      hotwords: hotwords,
      boostingTableID: biasSettings.boostingTableID,
      bypassProxy: ProxyBypassMode.current.bypassASR
    )

    // Capture prompt context beside audio startup; resolve it only if the mode uses it.
    resetPromptContextCapture(for: effectiveMode, generation: myGeneration)

    // Reset text state and clean up previous pipeline
    currentTranscript = .empty
    await finishAudioChunkPipeline(timeout: .milliseconds(100))
    guard sessionGeneration == myGeneration else {
      DebugFileLogger.log("startRecording: zombie detected after pipeline cleanup, bailing")
      return
    }

    // ── Phase 1: Start recording immediately (before ASR connects) ──
    // Audio chunks are buffered while WebSocket handshake is in progress.
    // This eliminates the ~1s perceived latency from connect().

    let audioBuffer = AudioChunkBuffer()

    speechDetected = false
    let levelHandler = self.onAudioLevel
    let speechGraceMs = SoundFeedback.startSoundDurationMs()
    let speechGraceEnd = ContinuousClock.now + .milliseconds(speechGraceMs)
    audioEngine.onAudioLevel = { [weak self] level in
      if level > RecognitionSession.speechLevelThreshold,
        ContinuousClock.now >= speechGraceEnd
      {
        Task { await self?.markSpeechDetected() }
      }
      levelHandler?(level)
    }

    audioEngine.onAudioChunk = { [weak self] data in
      guard self != nil else { return }
      audioBuffer.append(data)
    }

    let recordID = UUID().uuidString
    let recordingCreatedAt = Date()
    currentRecordID = recordID
    currentRecordingCreatedAt = recordingCreatedAt
    currentArchivedAudio = nil

    do {
      let selectedDeviceUID = AudioInputDevicePreferenceStore.resolvedCachedDeviceUID()
      let preferenceMode = AudioInputDevicePreferenceStore.mode().rawValue
      let priorityUIDs = AudioInputDevicePreferenceStore.priorityEntries().map(\.uid).joined(
        separator: ",")
      audioEngine.selectedDeviceUID = selectedDeviceUID
      DebugFileLogger.log(
        "audio input selected uid=\(selectedDeviceUID ?? "system-default") "
          + "mode=\(preferenceMode) priority=[\(priorityUIDs)]"
      )
      try audioEngine.prepareAudioJournal(
        metadata: AudioJournalMetadata(
          recordID: recordID,
          createdAt: recordingCreatedAt,
          processingMode: currentMode == .direct ? nil : currentMode.name,
          asrProvider: provider.displayName,
          asrModel: currentASRModelLabel(for: provider),
          partialTranscript: "",
          state: .recording,
          audioRelativePath: nil,
          audioBytes: 0
        ))
      try audioEngine.start()
      NSLog("[Session] Audio engine started OK")
      DebugFileLogger.log("audio engine started OK")
    } catch {
      NSLog("[Session] Audio engine start FAILED: %@", String(describing: error))
      DebugFileLogger.log("audio engine start failed: \(String(describing: error))")
      SoundFeedback.playError()
      await client.disconnect()
      self.asrClient = nil
      audioEngine.discardAudioJournal()
      currentRecordID = nil
      currentRecordingCreatedAt = nil
      state = .idle
      onASREvent?(.error(error))
      onASREvent?(.completed)
      return
    }

    state = .recording
    markReadyIfNeeded()
    DebugFileLogger.log("session entered recording state (buffering, ASR connecting)")

    // Volume lowered in Type4MeApp .ready handler

    // ── Phase 2: Connect ASR (audio is already recording) ──

    do {
      DebugFileLogger.log("ASR connecting provider=\(provider.rawValue)")
      try await client.connect(config: config, options: requestOptions)
      NSLog(
        "[Session] ASR connected OK (streaming, hotwords=%d, history=%d)",
        hotwords.count,
        requestOptions.contextHistoryLength
      )
      DebugFileLogger.log("ASR connected OK provider=\(provider.rawValue)")
    } catch {
      NSLog(
        "[Session] ASR connect FAILED provider=%@ error=%@", provider.rawValue,
        String(describing: error))
      DebugFileLogger.log(
        "ASR connect failed provider=\(provider.rawValue): \(String(describing: error))")
      SoundFeedback.playError()
      audioEngine.stop()
      audioEngine.onAudioChunk = nil
      audioEngine.onAudioLevel = nil
      finalizeCurrentAudioIfNeeded()
      await persistCurrentHistory(
        rawText: "",
        processedText: nil,
        finalText: "",
        status: "asr_failed_audio_saved"
      )
      await client.disconnect()
      self.asrClient = nil
      state = .idle
      hasEmittedReadyForCurrentSession = false
      onASREvent?(.error(error))
      onASREvent?(.completed)
      SystemVolumeManager.restore()
      return
    }

    // Bail out if session was superseded or user stopped while we were connecting
    guard sessionGeneration == myGeneration, state == .recording else {
      DebugFileLogger.log(
        "startRecording: zombie or state change after connect (gen=\(myGeneration) current=\(sessionGeneration) state=\(state)), bailing"
      )
      await client.disconnect()
      self.asrClient = nil
      return
    }

    // ── Phase 3: Flush buffer → switch to live pipeline ──

    let events = await client.events
    let expectedGeneration = sessionGeneration
    eventConsumptionTask = Task { [weak self] in
      for await event in events {
        guard let self else { break }
        await self.handleASREvent(event, expectedGeneration: expectedGeneration)
        if case .completed = event { break }
      }
    }

    let chunkContinuation = setupAudioChunkPipeline()

    // Flush all chunks buffered during connect
    let bufferedChunks = audioBuffer.drain()
    for chunk in bufferedChunks {
      chunkContinuation.yield(chunk)
    }

    // Switch callback from buffer to live pipeline
    var chunkCount = bufferedChunks.count
    let failureFlag = self.uploadFailureFlag
    audioEngine.onAudioChunk = { [weak self] data in
      guard self != nil else { return }
      if failureFlag?.failed == true { return }
      chunkCount += 1
      chunkContinuation.yield(data)
    }

    // Catch any chunks that arrived between drain and callback switch
    for chunk in audioBuffer.drain() {
      chunkContinuation.yield(chunk)
    }

    DebugFileLogger.log("ASR pipeline live, flushed \(bufferedChunks.count) buffered chunks")

    // Pre-warm the live optimizer, or tell the UI to use the full raw transcript area.
    if !currentMode.prompt.isEmpty, currentMode.executionKind == .recording {
      if canRunSpeculativeLLMForCurrentSession,
        let llmConfig = loadEffectiveLLMConfig()
      {
        let client = currentLLMClient()
        Task { await client.warmUp(baseURL: llmConfig.baseURL) }
      } else {
        speculativeLLMUnavailable = true
        onASREvent?(
          .liveOptimizationUnavailable(
            message: L("实时优化暂不可用", "Live optimization unavailable")
          ))
      }
    }

    // Safety: auto-stop after maxRecordingDuration to prevent unbounded memory use
    maxDurationTask?.cancel()
    maxDurationTask = Task { [weak self, maxRecordingDuration] in
      try? await Task.sleep(for: .seconds(maxRecordingDuration))
      guard let self, !Task.isCancelled else { return }
      await self.autoStopIfRecording()
    }
  }

  func setSelectionAskConversationContext(_ context: String) {
    pendingSelectionAskConversationContext = context
  }

  /// Auto-stop triggered by max recording duration timer.
  private func autoStopIfRecording() async {
    guard state == .recording else { return }
    DebugFileLogger.log("max recording duration reached (\(maxRecordingDuration)s), auto-stopping")
    stoppedByMaxDuration = true
    await stopRecording()
  }

  /// Whether the current session was auto-stopped by max duration limit.
  private(set) var stoppedByMaxDuration = false

  /// Switch the processing mode for the active recording or immediately before stop.
  /// Any speculative result belongs to the old prompt, so discard it and schedule
  /// a fresh preview for the transcript accumulated so far.
  func switchMode(to mode: ProcessingMode) {
    let effectiveMode = ASRProviderRegistry.resolvedMode(for: mode, provider: activeProvider)
    guard currentMode.id != effectiveMode.id else { return }

    resetSpeculativeLLM()
    pendingLLMError = nil
    currentMode = effectiveMode
    schedulePromptContextCaptureIfNeeded(for: effectiveMode, generation: sessionGeneration)
    DebugFileLogger.log("session mode switched to \(effectiveMode.name)")

    if state == .recording,
      !effectiveMode.prompt.isEmpty,
      effectiveMode.executionKind == .recording
    {
      scheduleSpeculativeLLM()
    }
  }

  // MARK: - Stop

  /// Cancel an in-progress recording: tear down all resources without injecting any text.
  func cancelRecording() async {
    guard state == .recording || state == .starting else {
      logger.warning("cancelRecording called but state is \(String(describing: self.state))")
      return
    }
    DebugFileLogger.log("cancelRecording: discarding session from state=\(state)")
    SystemVolumeManager.restore()
    discardCurrentAudio()
    await forceReset()
  }

  // MARK: - Final optimization recovery

  func retryFinalOptimization() {
    resolveFinalOptimizationDecision(.retry)
  }

  func insertRawAfterOptimizationFailure() {
    resolveFinalOptimizationDecision(.useRaw)
  }

  private func resolveFinalOptimizationDecision(_ decision: FinalOptimizationDecision) {
    finalOptimizationDecisionTimeoutTask?.cancel()
    finalOptimizationDecisionTimeoutTask = nil
    guard let continuation = finalOptimizationDecisionCont else { return }
    finalOptimizationDecisionCont = nil
    continuation.resume(returning: decision)
  }

  /// Mark that injection should be skipped. Recognition, clipboard, and history still proceed.
  func abortInjection() {
    injectionAborted = true
    resolveFinalOptimizationDecision(.useRaw)
    DebugFileLogger.log("abortInjection: injection will be skipped")
  }

  /// Parse a Mac Action LLM reply for a `<tool_call>{...}</tool_call>`, dispatch
  /// the action via `ActionRegistry`, and return both the user-facing message
  /// and a status. The floating bar uses the status to pick an icon/color
  /// (✓ green / ✗ red / ? amber).
  private func dispatchMacAction(llmReply: String) async -> (
    message: String, status: MacActionResultStatus
  ) {
    guard let toolCall = ToolCallParser.parse(llmReply) else {
      DebugFileLogger.log("macAction: no tool_call in LLM reply: \(llmReply.prefix(120))")
      return (L("未匹配到操作", "No matching action"), .unsure)
    }
    DebugFileLogger.log("macAction: dispatching \(toolCall.name) args=\(toolCall.arguments)")
    guard let result = await ActionRegistry.dispatch(name: toolCall.name, args: toolCall.arguments)
    else {
      DebugFileLogger.log("macAction: unknown action name \(toolCall.name)")
      return (L("未知操作：\(toolCall.name)", "Unknown action: \(toolCall.name)"), .failure)
    }
    if result.success {
      DebugFileLogger.log("macAction: success \(toolCall.name): \(result.displayMessage)")
      return (result.displayMessage, .success)
    } else {
      DebugFileLogger.log("macAction: failed \(toolCall.name): \(result.errorMessage ?? "")")
      return (result.errorMessage ?? L("操作失败", "Action failed"), .failure)
    }
  }

  /// Persist history, emit floating-bar event + `.completed`, and reset
  /// session state — the post-LLM finishing path used when Mac Action mode
  /// dispatched (or attempted to dispatch) an action. This deliberately skips
  /// the text-injection block that the normal post-LLM path runs.
  private func completeMacAction(
    message: String,
    status: MacActionResultStatus,
    rawText: String,
    recordingStartTime: Date?,
    activeProvider: ASRProvider,
    myGeneration: Int
  ) async {
    let historyStatus: String = {
      switch status {
      case .success: return "action_success"
      case .failure: return "action_failed"
      case .unsure: return "action_unmatched"
      }
    }()
    await persistCurrentHistory(
      rawText: rawText,
      processedText: message,
      finalText: message,
      status: historyStatus
    )

    onASREvent?(.macActionResult(message: message, status: status))
    onASREvent?(.completed)

    if sessionGeneration == myGeneration, state != .idle {
      state = .idle
      hasEmittedReadyForCurrentSession = false
      currentTranscript = .empty
      warmUpASRConnection()
    }
    resetSpeculativeLLM()
    SystemVolumeManager.restore()
  }

  private func completeSelectionAsk(
    questionText: String,
    recordingStartTime: Date?,
    activeProvider: ASRProvider,
    myGeneration: Int
  ) async {
    await resolvePromptContextIfNeeded(generation: myGeneration)
    guard sessionGeneration == myGeneration else { return }

    let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
    let contextSource = SelectionAskPromptBuilder.contextSource(from: promptContext)
    let contextText = SelectionAskPromptBuilder.contextText(from: promptContext)
    let conversationContext = pendingSelectionAskConversationContext
    pendingSelectionAskConversationContext = ""

    guard !question.isEmpty else {
      await persistCurrentHistory(
        rawText: "",
        processedText: nil,
        finalText: "",
        status: "asr_no_text_audio_saved"
      )
      onASREvent?(.selectionAskStarted(question: "", selectedText: contextText))
      onASREvent?(
        .selectionAskAnswerDelta(L("没有识别到问题，请重试。", "No question was recognized. Please try again."))
      )
      onASREvent?(.selectionAskAnswerCompleted)
      onASREvent?(.completed)
      finishSelectionAskSession(myGeneration: myGeneration)
      return
    }

    guard let llmConfig = loadEffectiveLLMConfig() else {
      await persistCurrentHistory(
        rawText: question,
        processedText: nil,
        finalText: question,
        status: "selection_ask_no_llm"
      )
      onASREvent?(.selectionAskStarted(question: question, selectedText: contextText))
      onASREvent?(
        .selectionAskAnswerDelta(
          L("请先在设置中配置 LLM。", "Please configure an LLM provider in Settings first.")))
      onASREvent?(.selectionAskAnswerCompleted)
      onASREvent?(.completed)
      finishSelectionAskSession(myGeneration: myGeneration)
      return
    }

    state = .postProcessing
    onASREvent?(.selectionAskStarted(question: question, selectedText: contextText))

    let client = currentLLMClient()
    let effectiveContext = PromptContext(selectedText: contextText, clipboardText: "")
    let prompt = SelectionAskPromptBuilder.requestText(
      mode: currentMode,
      context: effectiveContext,
      question: question,
      conversationContext: conversationContext
    )
    DebugFileLogger.log(
      """
      selectionAsk LLM request
      provider=\(CredentialStore.selectedLLMProvider.rawValue)
      model=\(llmConfig.model)
      contextSource=\(contextSource.rawValue)
      question=\(question)
      selectedRaw=\(promptContext.selectedText)
      clipboardChars=\(promptContext.clipboardText.count)
      contextChars=\(contextText.count)
      conversationChars=\(conversationContext.count)
      prompt:
      \(prompt)
      """)
    do {
      _ = try await client.processStreaming(
        text: prompt,
        prompt: "{text}",
        config: llmConfig
      ) { [weak self] delta in
        await self?.emitSelectionAskDelta(delta)
      }
      onASREvent?(.selectionAskAnswerCompleted)
    } catch {
      onASREvent?(.selectionAskAnswerDelta(userFacingLLMError(error)))
      onASREvent?(.selectionAskAnswerCompleted)
    }

    await persistCurrentHistory(
      rawText: question,
      processedText: nil,
      finalText: question,
      status: "selection_ask"
    )
    onASREvent?(.completed)
    finishSelectionAskSession(myGeneration: myGeneration)
  }

  private func finalizeCurrentAudioIfNeeded() {
    guard currentArchivedAudio == nil else { return }
    currentArchivedAudio = audioEngine.finalizeAudioJournal()
  }

  private func persistCurrentHistory(
    rawText: String,
    processedText: String?,
    finalText: String,
    status: String
  ) async {
    guard let recordID = currentRecordID else { return }
    let audio = currentArchivedAudio
    guard audio != nil || !rawText.isEmpty || !finalText.isEmpty else {
      discardCurrentAudio()
      return
    }
    let measuredDuration =
      recordingStartTime.map { Date().timeIntervalSince($0) }
      ?? audio?.durationSeconds
      ?? 0
    let inserted = await historyStore.insert(
      HistoryRecord(
        id: recordID,
        createdAt: currentRecordingCreatedAt ?? Date(),
        durationSeconds: measuredDuration,
        rawText: rawText,
        processingMode: currentMode == .direct ? nil : currentMode.name,
        processedText: processedText,
        finalText: finalText,
        status: status,
        characterCount: finalText.isEmpty ? rawText.count : finalText.count,
        asrProvider: activeProvider.displayName,
        asrModel: currentASRModelLabel(for: activeProvider),
        audioPath: audio?.relativePath,
        audioBytes: audio?.byteCount,
        audioDurationSeconds: audio?.durationSeconds,
        audioStatus: audio == nil ? nil : "retained"
      ))
    if inserted {
      audioEngine.commitAudioJournal()
      await historyStore.pruneAudio()
    } else {
      // Keep the finalized WAV + metadata sidecar. The startup importer
      // will retry the durable history commit on the next launch.
      audioEngine.preserveAudioJournalForRecovery()
      DebugFileLogger.log("history insert failed; preserved audio journal id=\(recordID)")
    }
    currentRecordID = nil
    currentRecordingCreatedAt = nil
    currentArchivedAudio = nil
  }

  private func discardCurrentAudio() {
    audioEngine.discardAudioJournal()
    currentRecordID = nil
    currentRecordingCreatedAt = nil
    currentArchivedAudio = nil
  }

  private func emitSelectionAskDelta(_ delta: String) {
    guard !delta.isEmpty else { return }
    onASREvent?(.selectionAskAnswerDelta(delta))
  }

  private func finishSelectionAskSession(myGeneration: Int) {
    if sessionGeneration == myGeneration, state != .idle {
      state = .idle
      hasEmittedReadyForCurrentSession = false
      currentTranscript = .empty
      warmUpASRConnection()
    }
    resetSpeculativeLLM()
    SystemVolumeManager.restore()
  }

  private func userFacingLLMError(_ error: Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
      return localized
    }
    return error.localizedDescription
  }

  private func performTimedLLMRequest(
    client: any LLMClient,
    text: String,
    prompt: String,
    config: LLMConfig,
    rejectConversationalMetaResponse: Bool = false
  ) async throws -> String {
    llmAttemptCounter += 1
    let token = LLMRequestToken(
      provider: CredentialStore.selectedLLMProvider.displayName,
      model: config.model,
      attempt: llmAttemptCounter,
      startedAt: ContinuousClock.now,
      sessionGeneration: sessionGeneration
    )
    onASREvent?(
      .llmRequestStarted(
        provider: token.provider,
        model: token.model,
        attempt: token.attempt
      ))
    do {
      let result = try await client.process(text: text, prompt: prompt, config: config)
      guard !result.isEmpty else { throw LLMError.emptyResponse(nil) }
      if rejectConversationalMetaResponse,
        Self.isConversationalMetaResponse(result, sourceText: text)
      {
        throw LLMError.invalidOutput(
          L("模型返回了对话式确认语", "model returned a conversational acknowledgement"))
      }
      finishLLMRequest(token, succeeded: true)
      return result
    } catch {
      finishLLMRequest(token, succeeded: false)
      throw error
    }
  }

  private func performModeLLMRequest(
    client: any LLMClient,
    text: String,
    prompt: String,
    config: LLMConfig,
    modeID: UUID,
    retryInvalidOutput: Bool
  ) async throws -> String {
    let cacheable =
      modeID != ProcessingMode.macActionId
      && modeID != ProcessingMode.selectionAskId
    guard cacheable else {
      return try await performUncachedModeLLMRequest(
        client: client,
        text: text,
        prompt: prompt,
        config: config,
        modeID: modeID,
        retryInvalidOutput: retryInvalidOutput
      )
    }

    let key = OptimizationRequestKey(
      text: text,
      prompt: prompt,
      modeID: modeID,
      provider: CredentialStore.selectedLLMProvider.rawValue,
      model: config.model,
      baseURL: config.baseURL
    )
    let lookup = try await llmRequestMemoizer.value(for: key) {
      try await self.performUncachedModeLLMRequest(
        client: client,
        text: text,
        prompt: prompt,
        config: config,
        modeID: modeID,
        retryInvalidOutput: retryInvalidOutput
      )
    }
    switch lookup.source {
    case .network:
      DebugFileLogger.log(
        "llm cache: stored key=\(key.shortID) chars=\(lookup.result.count)"
      )
    case .inFlight:
      DebugFileLogger.log("llm cache: joined in-flight key=\(key.shortID)")
    case .cache:
      DebugFileLogger.log(
        "llm cache: hit key=\(key.shortID) chars=\(lookup.result.count)"
      )
    }
    return lookup.result
  }

  private func performUncachedModeLLMRequest(
    client: any LLMClient,
    text: String,
    prompt: String,
    config: LLMConfig,
    modeID: UUID,
    retryInvalidOutput: Bool
  ) async throws -> String {
    let rejectsMeta = modeID == ProcessingMode.formalWritingId
    do {
      return try await performTimedLLMRequest(
        client: client,
        text: text,
        prompt: prompt,
        config: config,
        rejectConversationalMetaResponse: rejectsMeta
      )
    } catch LLMError.invalidOutput where rejectsMeta && retryInvalidOutput {
      DebugFileLogger.log("llm: rejected conversational meta response; retrying once")
      let correction = L(
        "\n\n# 输出纠正\n前一次输出错误地回应了任务。重新整理 `<speech_transcript>` 内的原文；只输出整理后的正文，禁止确认语、解释和规则复述。",
        "\n\n# Output correction\nThe previous output responded to the task. Rewrite only the text inside `<speech_transcript>`; output only the rewritten body with no acknowledgement, explanation, or rule summary."
      )
      return try await performTimedLLMRequest(
        client: client,
        text: text,
        prompt: prompt + correction,
        config: config,
        rejectConversationalMetaResponse: true
      )
    }
  }

  private func finishLLMRequest(_ token: LLMRequestToken, succeeded: Bool) {
    guard token.sessionGeneration == sessionGeneration else {
      DebugFileLogger.log(
        "llm: ignoring stale finish attempt=\(token.attempt) generation=\(token.sessionGeneration) active=\(sessionGeneration)"
      )
      return
    }
    let elapsed = ContinuousClock.now - token.startedAt
    let seconds =
      Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    onASREvent?(
      .llmRequestFinished(
        provider: token.provider,
        model: token.model,
        attempt: token.attempt,
        durationSeconds: seconds,
        succeeded: succeeded
      ))
  }

  static func isConversationalMetaResponse(_ output: String, sourceText: String) -> Bool {
    func normalized(_ value: String) -> String {
      value.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "")
    }

    let candidate = normalized(output)
    let source = normalized(sourceText)
    let forbiddenPrefixes = [
      "好的，我会", "好的,我会", "好的！我会", "好的!我会", "好的。我会",
      "好的，我将", "好的,我将", "收到，我会", "收到,我会",
      "没问题，我会", "没问题,我会", "当然，我会", "当然,我会",
      "好的，以下是", "好的,以下是", "以下是按照", "按照上述规则",
      "sure,i'll", "okay,i'll", "hereisthepolished", "i'llfollow",
    ]
    return forbiddenPrefixes.contains { prefix in
      candidate.hasPrefix(prefix) && !source.hasPrefix(prefix)
    }
  }

  private func waitForFinalOptimizationRecovery(
    sourceText: String,
    initialError: Error
  ) async -> String? {
    guard !injectionAborted else { return nil }
    var failure = initialError
    while true {
      onASREvent?(
        .finalOptimizationFailed(
          message: userFacingLLMError(failure),
          sourceText: sourceText
        ))
      let decision = await withCheckedContinuation { continuation in
        finalOptimizationDecisionCont = continuation
        finalOptimizationDecisionTimeoutTask?.cancel()
        finalOptimizationDecisionTimeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(600))
          guard let self, !Task.isCancelled else { return }
          DebugFileLogger.log("final optimization decision timed out; preserving raw text")
          await self.resolveFinalOptimizationDecision(.useRaw)
        }
      }
      guard decision == .retry else { return nil }

      guard let config = loadEffectiveLLMConfig() else {
        failure = NSError(
          domain: "Type4Me.LLM",
          code: -1,
          userInfo: [NSLocalizedDescriptionKey: L("请先配置 LLM", "Please configure an LLM first")]
        )
        continue
      }
      let prompt = promptContext.expandContextVariables(currentMode.prompt)
      do {
        let result = try await performModeLLMRequest(
          client: currentLLMClient(),
          text: sourceText,
          prompt: prompt,
          config: config,
          modeID: currentMode.id,
          retryInvalidOutput: true
        )
        return result
      } catch {
        failure = error
      }
    }
  }

  func stopRecording() async {
    let myGeneration = sessionGeneration
    guard state == .recording else {
      logger.warning("stopRecording called but state is \(String(describing: self.state))")
      return
    }
    let stopRevision = currentTranscript.revision
    let canCommitPreview = currentMode.id != ProcessingMode.macActionId
    let lockedArtifact =
      canCommitPreview
      ? liveOptimization.committableArtifact(revision: stopRevision, modeID: currentMode.id)
      : nil
    let lockedRequest =
      lockedArtifact == nil && canCommitPreview
      ? liveOptimization.matchingActiveRequest(revision: stopRevision, modeID: currentMode.id)
      : nil
    let lockedInFlightTask = lockedRequest == nil ? nil : speculativeLLMTask
    if let lockedArtifact {
      DebugFileLogger.log(
        "stop: locked ready revision=\(stopRevision) key=\(lockedArtifact.request.key.shortID)"
      )
    } else if let lockedRequest {
      DebugFileLogger.log(
        "stop: locked in-flight revision=\(stopRevision) key=\(lockedRequest.key.shortID)"
      )
    } else {
      DebugFileLogger.log("stop: no lockable optimization revision=\(stopRevision)")
    }

    // Set state BEFORE any await to prevent a second stop from
    // slipping through the guard during the suspension point.
    state = .finishing
    maxDurationTask?.cancel()
    maxDurationTask = nil
    // Preview scheduling stops here, but a request already in flight is kept
    // alive: when its source still matches the session-final transcript, the
    // stop path awaits it below instead of firing an identical final request.
    // (state is already .finishing, so its completion emits no events and
    // reschedules nothing — only the return value is consumed.)
    speculativeDebounceTask?.cancel()
    speculativeDebounceTask = nil

    let stopT0 = ContinuousClock.now
    SystemVolumeManager.restore()
    SoundFeedback.playStop()

    // Stop capture first so flushRemaining() can emit the tail audio chunk.
    audioEngine.stop()
    audioEngine.onAudioChunk = nil
    await finishAudioChunkPipeline()
    finalizeCurrentAudioIfNeeded()
    DebugFileLogger.log("stop: audio stopped +\(ContinuousClock.now - stopT0)")
    guard sessionGeneration == myGeneration else {
      DebugFileLogger.log("stopRecording: zombie after audio pipeline, bailing")
      return
    }

    // Quick bail: if mic level never exceeded speech threshold, skip the
    // full ASR teardown (no speech = nothing to finalize). Saves 2-7s of waiting.
    if !speechDetected {
      let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
      DebugFileLogger.log(
        "stop: no speech detected (duration=\(String(format: "%.1f", duration))s), fast exit")
      discardCurrentAudio()
      if let client = asrClient {
        await client.disconnect()
        self.asrClient = nil
      }
      eventConsumptionTask?.cancel()
      eventConsumptionTask = nil
      onASREvent?(.finalizedEmpty)
      if sessionGeneration == myGeneration, state != .idle {
        state = .idle
        hasEmittedReadyForCurrentSession = false
        currentTranscript = .empty
        warmUpASRConnection()
      }
      resetSpeculativeLLM()
      SystemVolumeManager.restore()
      return
    }

    // Short recordings can stop before the first streaming token arrives. Wait up
    // to 1s for any text so genuine speech is not discarded as silence; once text
    // exists, the normal teardown below still drains the complete ASR event stream.
    let provider = activeProvider
    let providerIsStreaming = ASRProviderRegistry.capabilities(for: provider).isStreaming
    if providerIsStreaming {
      let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
      let hasStreamingText = !currentTranscript.composedText
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      if duration < 5 && !hasStreamingText {
        // Phase 1: wait up to 1s for any streaming text
        DebugFileLogger.log(
          "stop: short recording (\(String(format: "%.1f", duration))s) with no streaming text, waiting for partial"
        )
        let gotText = await awaitFirstStreamingText(timeout: .seconds(1))

        if !gotText {
          // No streaming text after 1s — likely not real speech, fast exit
          DebugFileLogger.log("stop: no streaming text after 1s wait, fast exit")
          if let client = asrClient {
            await client.disconnect()
            self.asrClient = nil
          }
          eventConsumptionTask?.cancel()
          eventConsumptionTask = nil
          await persistCurrentHistory(
            rawText: "",
            processedText: nil,
            finalText: "",
            status: "asr_no_text_audio_saved"
          )
          onASREvent?(.finalizedEmpty)
          if sessionGeneration == myGeneration, state != .idle {
            state = .idle
            hasEmittedReadyForCurrentSession = false
            currentTranscript = .empty
            warmUpASRConnection()
          }
          resetSpeculativeLLM()
          SystemVolumeManager.restore()
          return
        }

        DebugFileLogger.log(
          "stop: streaming text arrived; continuing to full teardown +\(ContinuousClock.now - stopT0)"
        )
      }
    }

    let needsLLM = !currentMode.prompt.isEmpty && currentMode.executionKind == .recording

    // ASR teardown: end audio, then drain the event stream through server EOS.
    // Utterance-level isFinal flags are not session-final on every provider, so
    // they are never sufficient to start the final fallback request.
    var asrTeardownClean = true
    if let client = asrClient {
      let endAudioTimeout: Duration = providerIsStreaming ? .seconds(3) : .seconds(60)
      let endAudioOK = await withTimeout(endAudioTimeout) {
        try await client.endAudio()
      }
      if !endAudioOK {
        DebugFileLogger.log("endAudio timeout or failed")
        asrTeardownClean = false
      }

      if let evtTask = eventConsumptionTask {
        let drainTimeout: Duration = providerIsStreaming ? .seconds(10) : .seconds(10)
        let drained = await withTimeout(drainTimeout) {
          await evtTask.value
        }
        if !drained {
          DebugFileLogger.log("event stream drain timeout before session-final ASR")
          asrTeardownClean = false
        }
      }
      await client.disconnect()
      eventConsumptionTask?.cancel()
      DebugFileLogger.log(
        "stop: ASR session-final teardown complete (clean=\(asrTeardownClean)) +\(ContinuousClock.now - stopT0)"
      )
    }

    eventConsumptionTask = nil
    asrClient = nil
    hasEmittedReadyForCurrentSession = false
    guard sessionGeneration == myGeneration else {
      DebugFileLogger.log("stopRecording: zombie after ASR teardown, bailing")
      return
    }

    // Any failed endAudio/drain path lacks a trustworthy session-final transcript.
    // Re-transcribe the saved full recording before allowing final LLM processing.
    let uploadFailed = uploadFailureFlag?.failed == true
    let streamingFailed = Self.shouldAttemptBatchFallback(
      uploadFailed: uploadFailed,
      asrTeardownClean: asrTeardownClean,
      streamingError: lastStreamingError
    )
    var hasSessionFinalTranscript = !streamingFailed
    if streamingFailed {
      let partialText = currentTranscript.composedText
      DebugFileLogger.log(
        "stop: ASR session finalization failed (partial=\(partialText.count) chars, uploadFailed=\(uploadFailed), hasStreamingError=\(lastStreamingError != nil)); attempting batch fallback"
      )
      let fullAudio = audioEngine.getRecordedAudio()
      if !fullAudio.isEmpty, let config = currentConfig {
        onASREvent?(
          .processingResult(
            text: partialText.isEmpty ? L("重新识别中...", "Retrying recognition...") : partialText
          ))
        if let batchText = await attemptBatchFallback(
          audio: fullAudio,
          config: config,
          provider: activeProvider
        ) {
          currentTranscript = versionedTranscript(
            RecognitionTranscript(
            confirmedSegments: [batchText],
            partialText: "",
            authoritativeText: batchText,
            isFinal: true
          )
          )
          hasSessionFinalTranscript = true
          DebugFileLogger.log(
            "stop: batch fallback produced session-final ASR, \(batchText.count) chars")
        }
      }
    }

    if !hasSessionFinalTranscript {
      let partialText = currentTranscript.composedText
      DebugFileLogger.log("stop: no session-final ASR; preserving audio and refusing final LLM")
      await persistCurrentHistory(
        rawText: partialText,
        processedText: nil,
        finalText: "",
        status: "asr_incomplete_audio_saved"
      )
      onASREvent?(
        .recoveryFailed(
          text: partialText,
          message: L("识别结果不完整，录音已保存", "Recognition incomplete; audio saved")
        ))
      currentConfig = nil
      if sessionGeneration == myGeneration, state != .idle {
        state = .idle
        hasEmittedReadyForCurrentSession = false
        currentTranscript = .empty
        warmUpASRConnection()
      }
      resetSpeculativeLLM()
      return
    }
    uploadFailureFlag = nil
    lastStreamingError = nil
    // Recording-time output is preview-only. The single insertion-eligible LLM
    // request is issued below after session-final ASR and snippet expansion.

    // Combine confirmed segments + any trailing unconfirmed partial.
    let effectiveText = currentTranscript.displayText
    currentConfig = nil

    if !effectiveText.isEmpty {
      let rawText = effectiveText
      var finalText = effectiveText
      var processedText: String? = nil
      var llmFailed = false

      if currentMode.executionKind == .selectionAsk {
        await completeSelectionAsk(
          questionText: rawText,
          recordingStartTime: recordingStartTime,
          activeProvider: activeProvider,
          myGeneration: myGeneration
        )
        return
      }

      // Apply snippet replacements before LLM (e.g. "我的邮箱" → actual email)
      finalText = SnippetStorage.applyEffective(to: finalText, bundleId: targetBundleId)

      // The hotkey press is the commit boundary. A ready artifact (or the
      // matching request already in flight) was locked before endAudio, so
      // later EOS rewrites cannot trigger a second LLM request.
      var commitArtifact = lockedArtifact
      if commitArtifact == nil,
        let lockedRequest,
        let lockedInFlightTask
      {
        DebugFileLogger.log(
          "stop: awaiting locked in-flight revision=\(lockedRequest.sourceRevision) key=\(lockedRequest.key.shortID)"
        )
        if let awaited = await awaitWithTimeout(lockedInFlightTask, after: .seconds(15)) {
          let cleaned = awaited.collapsingExtraSpaces
          if !cleaned.isEmpty {
            commitArtifact =
              liveOptimization.committableArtifact(
                revision: lockedRequest.sourceRevision,
                modeID: lockedRequest.modeID
              ) ?? LiveOptimizationArtifact(request: lockedRequest, result: cleaned)
          }
        }
      }

      if let commitArtifact,
        Self.requiresFinalLLM(needsLLM: needsLLM, finalText: finalText)
      {
        let committed = commitArtifact.result
        DebugFileLogger.log(
          "stop: committing locked revision=\(commitArtifact.request.sourceRevision) eosRevision=\(currentTranscript.revision) key=\(commitArtifact.request.key.shortID) chars=\(committed.count)"
        )
        processedText = committed
        finalText = committed
        onASREvent?(
          .liveOptimizationLocked(
            sourceText: commitArtifact.request.displaySourceText,
            sourceRevision: commitArtifact.request.sourceRevision
          ))
        onASREvent?(.processingResult(text: committed))
      } else if Self.requiresFinalLLM(needsLLM: needsLLM, finalText: finalText) {
        state = .postProcessing
        await resolvePromptContextIfNeeded(generation: myGeneration)
        guard sessionGeneration == myGeneration else { return }
        if let llmConfig = loadEffectiveLLMConfig() {
          DebugFileLogger.log(
            "stop: final LLM firing revision=\(currentTranscript.revision) mode=\(currentMode.name) model=\(llmConfig.model) with \(finalText.count) chars"
          )
          let client = currentLLMClient()
          let prompt = promptContext.expandContextVariables(currentMode.prompt)
          let textForLLM = finalText

          let llmResult: String? = await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let llmTask = Task<String?, Never> {
              do {
                return try await self.performModeLLMRequest(
                  client: client,
                  text: textForLLM,
                  prompt: prompt,
                  config: llmConfig,
                  modeID: currentMode.id,
                  retryInvalidOutput: true
                )
              } catch {
                DebugFileLogger.log("stop: final LLM FAILED: \(error)")
                self.setPendingLLMError(error)
                return nil as String?
              }
            }
            Task {
              let result = await llmTask.value
              if finished.withLock({
                let old = $0
                $0 = true
                return !old
              }) {
                continuation.resume(returning: result)
              }
            }
            Task {
              try? await Task.sleep(for: .seconds(15))
              if finished.withLock({
                let old = $0
                $0 = true
                return !old
              }) {
                llmTask.cancel()
                DebugFileLogger.log("stop: sync LLM timeout after 15s, falling back to raw text")
                continuation.resume(returning: nil)
              }
            }
          }

          if let result = llmResult {
            let cleaned = result.collapsingExtraSpaces
            if currentMode.id == ProcessingMode.macActionId {
              let action = await dispatchMacAction(llmReply: cleaned)
              await completeMacAction(
                message: action.message,
                status: action.status,
                rawText: rawText,
                recordingStartTime: recordingStartTime,
                activeProvider: activeProvider,
                myGeneration: myGeneration
              )
              return
            }
            processedText = cleaned
            finalText = cleaned
            onASREvent?(.processingResult(text: cleaned))
          } else {
            let error = pendingLLMError ?? LLMError.emptyResponse(nil)
            pendingLLMError = nil
            if let retried = await waitForFinalOptimizationRecovery(
              sourceText: finalText,
              initialError: error
            ) {
              let cleaned = retried.collapsingExtraSpaces
              processedText = cleaned
              finalText = cleaned
              onASREvent?(.processingResult(text: cleaned))
            } else {
              llmFailed = true
              onASREvent?(.processingResult(text: rawText))
            }
          }
        } else {
          let error = NSError(
            domain: "Type4Me.LLM",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L("请先配置 LLM", "Please configure an LLM first")]
          )
          if let retried = await waitForFinalOptimizationRecovery(
            sourceText: finalText,
            initialError: error
          ) {
            let cleaned = retried.collapsingExtraSpaces
            processedText = cleaned
            finalText = cleaned
            onASREvent?(.processingResult(text: cleaned))
          } else {
            llmFailed = true
            onASREvent?(.processingResult(text: rawText))
          }
        }
      }

      finalText = finalText.removingCJKLatinSpaces
      finalText = finalText.strippingTrailingPunctuation

      state = .injecting
      let defaults = UserDefaults.standard
      injectionEngine.preserveClipboard =
        defaults.object(forKey: "tf_preserveClipboard") != nil
        ? defaults.bool(forKey: "tf_preserveClipboard")
        : true

      // Run injection on a detached task to avoid blocking the actor with usleep().
      // .finalized is emitted directly from the detached task so the UI updates
      // immediately after paste, without waiting for actor re-scheduling.
      let engine = injectionEngine
      let aborted = injectionAborted
      let onEvent = self.onASREvent
      let injectLog =
        "stop: injecting method=clipboard len=\(finalText.count) +\(ContinuousClock.now - stopT0)"
      _ = await withCheckedContinuation { continuation in
        Task.detached {
          let outcome: InjectionOutcome
          if aborted {
            engine.copyToClipboard(finalText)
            DebugFileLogger.log("stop: injection aborted by ESC, text saved to clipboard & history")
            outcome = .copiedToClipboard
          } else {
            DebugFileLogger.log(injectLog)
            outcome = engine.inject(finalText)
          }
          // Notify UI immediately from this thread, before actor resumes
          onEvent?(.finalized(text: finalText, injection: outcome))
          DebugFileLogger.log("stop: finalized emitted from injection task")
          // Only restore clipboard when text was successfully inserted.
          // When outcome is .copiedToClipboard (injection failed or ESC abort),
          // keep the text in clipboard so user can manually paste.
          if outcome == .inserted {
            engine.finishClipboardRestore()
          }
          continuation.resume(returning: outcome)
        }
      }

      #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode {
          Task { await CloudQuotaManager.shared.refresh(force: true) }
        }
      #endif

      // Save text and its finalized audio under the recording's stable ID.
      let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
      let status: String
      if injectionAborted {
        status = "aborted"
      } else if llmFailed {
        status = "llm_error"
      } else if streamingFailed {
        status = "stream_recovered"
      } else {
        status = "completed"
      }
      await persistCurrentHistory(
        rawText: rawText,
        processedText: processedText,
        finalText: finalText,
        status: status
      )
      CredentialStore.addASRUsage(seconds: duration)

      // Note: injectionAborted and llmFailed info is already conveyed
      // through the .finalized event's InjectionOutcome / completionMessage.
      // No separate .error emission here to avoid green→red UI flash.

    } else {
      // Speech was captured but ASR produced no usable text. Keep the audio
      // as an explicit recovery record instead of silently dropping it.
      let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
      DebugFileLogger.log("stop: no text recognized (duration=\(duration)s), preserving audio")
      await persistCurrentHistory(
        rawText: "",
        processedText: nil,
        finalText: "",
        status: "asr_no_text_audio_saved"
      )
      onASREvent?(.finalizedEmpty)
    }

    // Only reset to idle if this is still the active session.
    if sessionGeneration == myGeneration, state != .idle {
      state = .idle
      hasEmittedReadyForCurrentSession = false
      currentTranscript = .empty
      // Pre-warm connection for next recording
      warmUpASRConnection()
    }
    resetSpeculativeLLM()
    SystemVolumeManager.restore()
    logger.info("Session complete, injected \(effectiveText.count) chars")
  }

  // MARK: - Stream interruption recovery

  private func beginStreamRecovery(trigger: String) async {
    guard state == .recording else {
      DebugFileLogger.log("recovery ignored: state=\(state) trigger=\(trigger)")
      return
    }

    let myGeneration = sessionGeneration
    let provider = activeProvider
    let config = currentConfig
    let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    let partialText = normalizedRecoveryText(currentTranscript.displayText)
    let asrModel = currentASRModelLabel(for: provider)

    DebugFileLogger.log("recovery started trigger=\(trigger) partial=\(partialText.count) chars")
    state = .recovering
    recoveryInterruptPromptShown = false
    recoveryRecordId = currentRecordID
    recoveryCreatedAt = currentRecordingCreatedAt
    recoveryPartialText = partialText
    recoveryDuration = duration
    recoveryModeName = currentMode == .direct ? nil : currentMode.name
    recoveryProvider = provider
    recoveryASRModel = asrModel

    maxDurationTask?.cancel()
    maxDurationTask = nil
    cancelSpeculativeLLM()
    SystemVolumeManager.restore()

    audioEngine.stop()
    audioEngine.onAudioChunk = nil
    audioEngine.onAudioLevel = nil
    await finishAudioChunkPipeline(timeout: .milliseconds(250))
    finalizeCurrentAudioIfNeeded()
    let fullAudio = audioEngine.getRecordedAudio()

    eventConsumptionTask?.cancel()
    eventConsumptionTask = nil
    if let client = asrClient {
      Task.detached { await client.disconnect() }
    }
    asrClient = nil
    uploadFailureFlag = nil
    lastStreamingError = nil

    if !partialText.isEmpty {
      injectRecoveryPartial(partialText)
    }

    onASREvent?(
      .recoveryStarted(
        text: partialText,
        message: L(
          "连接中断，已保留当前文字，正在用整段录音重试",
          "Connection interrupted. Current text was saved; retrying with the full recording."
        )
      ))

    guard sessionGeneration == myGeneration, state == .recovering else { return }
    guard !fullAudio.isEmpty, let config else {
      await finishRecovery(
        recoveredText: nil,
        generation: myGeneration,
        failureMessage: L(
          "连接中断，已保留部分识别结果",
          "Connection interrupted. Partial recognition was saved."
        )
      )
      return
    }

    recoveryTask?.cancel()
    recoveryTask = Task {
      let recovered = await self.attemptBatchFallback(
        audio: fullAudio,
        config: config,
        provider: provider
      )
      await self.finishRecovery(
        recoveredText: recovered,
        generation: myGeneration,
        failureMessage: L(
          "连接中断，已保留部分识别结果",
          "Connection interrupted. Partial recognition was saved."
        )
      )
    }
  }

  private func finishRecovery(
    recoveredText: String?,
    generation: Int,
    failureMessage: String
  ) async {
    guard state == .recovering, generation == sessionGeneration, !Task.isCancelled else {
      return
    }

    let recovered = recoveredText.map(normalizedRecoveryText)?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if let recovered, !recovered.isEmpty {
      injectionEngine.copyToClipboard(recovered)
      currentTranscript = versionedTranscript(
        RecognitionTranscript(
        confirmedSegments: [recovered],
        partialText: "",
        authoritativeText: recovered,
        isFinal: true
      )
      )
      await persistCurrentHistory(
        rawText: recoveryPartialText,
        processedText: nil,
        finalText: recovered,
        status: "stream_recovered"
      )
      CredentialStore.addASRUsage(seconds: recoveryDuration)
      onASREvent?(
        .recoverySucceeded(
          text: recovered,
          message: L("已恢复完整识别", "Full recognition recovered")
        ))
      DebugFileLogger.log("recovery succeeded \(recovered.count) chars")
    } else {
      await persistCurrentHistory(
        rawText: recoveryPartialText,
        processedText: nil,
        finalText: recoveryPartialText,
        status: recoveryPartialText.isEmpty ? "asr_failed_audio_saved" : "stream_partial_saved"
      )
      onASREvent?(.recoveryFailed(text: recoveryPartialText, message: failureMessage))
      DebugFileLogger.log("recovery failed, partial=\(recoveryPartialText.count) chars")
    }

    clearRecoveryState()
    state = .idle
    currentTranscript = .empty
    resetSpeculativeLLM()
    SystemVolumeManager.restore()
    warmUpASRConnection()
  }

  private func normalizedRecoveryText(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .removingCJKLatinSpaces
      .strippingTrailingPunctuation
  }

  private func injectRecoveryPartial(_ text: String) {
    let engine = injectionEngine
    Task.detached {
      engine.preserveClipboard = false
      _ = engine.inject(text)
    }
  }

  private func clearRecoveryState() {
    recoveryTask?.cancel()
    recoveryTask = nil
    recoveryInterruptPromptShown = false
    recoveryRecordId = nil
    recoveryCreatedAt = nil
    recoveryPartialText = ""
    recoveryDuration = 0
    recoveryModeName = nil
    recoveryProvider = .volcano
    recoveryASRModel = nil
    currentConfig = nil
  }

  // MARK: - ASR Events
  private func versionedTranscript(_ transcript: RecognitionTranscript) -> RecognitionTranscript {
    var versioned = transcript
    versioned.revision = transcriptRevisionTracker.update(transcript.canonicalText)
    return versioned
  }

  private func handleASREvent(_ event: RecognitionEvent, expectedGeneration: Int) {
    guard expectedGeneration == sessionGeneration else {
      DebugFileLogger.log(
        "ignoring stale ASR event for gen=\(expectedGeneration), active=\(sessionGeneration)")
      return
    }
    switch event {
    case .ready:
      // Deduplicate: ASR clients may emit .ready, but we also emit it
      // on first audio chunk via markReadyIfNeeded(). Route both through
      // the same guard to avoid double-firing the start sound.
      markReadyIfNeeded()
      return  // markReadyIfNeeded calls onASREvent(.ready) internally

    default:
      break
    }
    if case .transcript(let rawTranscript) = event {
      let transcript = versionedTranscript(rawTranscript)
      currentTranscript = transcript
      onASREvent?(.transcript(transcript))
      audioEngine.updateAudioJournalPartialTranscript(transcript.canonicalText)
      if !transcript.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        speechDetected = true
        if let cont = firstStreamingTextCont {
          firstStreamingTextCont = nil
          firstStreamingTextTimeoutTask?.cancel()
          firstStreamingTextTimeoutTask = nil
          cont.resume(returning: true)
        }
      }
      DebugFileLogger.log(
        "asr revision=\(transcript.revision) source=\(transcript.textSource.rawValue) chars=\(transcript.canonicalText.count)"
      )
      logger.info("Transcript updated: \(transcript.canonicalText)")
      if state == .recording && !currentMode.prompt.isEmpty
        && currentMode.executionKind == .recording
      {
        scheduleSpeculativeLLM()
      }
      return
    }

    // Notify UI layer for all non-ready events. Streaming errors during
    // recording become recoverable interruptions, not red error toasts.
    if case .error = event, state == .recording {
      // beginStreamRecovery surfaces the user-facing state.
    } else {
      onASREvent?(event)
    }

    switch event {
    case .ready:
      break  // handled above

    case .transcript:
      break  // handled and versioned before generic dispatch
    case .error(let error):
      lastStreamingError = error
      logger.error("ASR error: \(error)")
      if state == .recording {
        Task { await self.beginStreamRecovery(trigger: "ASR error: \(error)") }
      }

    case .completed:
      logger.info("ASR stream completed")
      if state == .recording {
        if lastStreamingError != nil || uploadFailureFlag?.failed == true {
          NSLog("[Session] Server closed ASR after interruption, initiating recovery")
          DebugFileLogger.log("server completed after streaming interruption")
          Task { await self.beginStreamRecovery(trigger: "ASR completed after interruption") }
        } else if activeProvider != .grok {
          NSLog("[Session] Server closed ASR while recording, initiating stop")
          DebugFileLogger.log("server-initiated stop from recording state")
          Task { await self.stopRecording() }
        }
      }

    case .processingResult, .processingLabelOverride,
      .liveOptimizationStarted, .liveOptimizationResult, .liveOptimizationLocked,
      .liveOptimizationUnavailable, .liveOptimizationFailed,
      .llmRequestStarted, .llmRequestFinished, .finalOptimizationFailed,
      .recoveryStarted, .recoveryPrompt, .recoverySucceeded, .recoveryFailed,
      .recoveryInterrupted, .finalized, .finalizedEmpty, .macActionResult,
      .selectionAskStarted, .selectionAskAnswerDelta, .selectionAskAnswerCompleted:
      break
    }
  }

  // MARK: - Soniox punctuation helpers

  private static let sonioxPunctuationPrompt = """
    为以下语音识别文本添加标点符号并修正空格。规则:
    1. 根据语义添加合适的标点
    2. 去掉中文之间不必要的空格，中英文之间保留一个空格
    3. 不改任何文字内容
    4. 直接返回结果
    {text}
    """

  private static let chinesePunctuationSet: Set<Character> = [
    "\u{3002}", "\u{FF0C}", "\u{3001}", "\u{FF1B}", "\u{FF1A}",  // 。，、；：
    "\u{FF01}", "\u{FF1F}", "\u{2026}", "\u{2014}", "\u{00B7}",  // ！？…—·
    "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",  // ""''
    "\u{FF08}", "\u{FF09}", "\u{3010}", "\u{3011}",  // （）【】
    "\u{300A}", "\u{300B}",  // 《》
  ]

  private static func stripChinesePunctuation(_ text: String) -> String {
    var result = ""
    var skipSpaces = false
    for char in text {
      if chinesePunctuationSet.contains(char) {
        skipSpaces = true
        continue
      }
      if skipSpaces && char == " " {
        continue
      }
      skipSpaces = false
      result.append(char)
    }
    return result
  }

  // MARK: - Internal helpers

  private func setupAudioChunkPipeline() -> AsyncStream<Data>.Continuation {
    audioChunkContinuation?.finish()
    audioChunkSenderTask?.cancel()

    let (stream, continuation) = AsyncStream<Data>.makeStream()
    audioChunkContinuation = continuation

    // Capture everything needed for sending so the Task body
    // does NOT hop back to the actor.  This prevents a blocking
    // WebSocket send from starving stopRecording().
    let client = asrClient
    let audioInput = ASRProviderRegistry.capabilities(for: activeProvider).audioInput

    let failureFlag = UploadFailureFlag()
    self.uploadFailureFlag = failureFlag

    audioChunkSenderTask = Task.detached {
      var chunkCount = 0
      var lastLogTime: ContinuousClock.Instant?
      for await data in stream {
        guard let client else { break }
        let t0 = ContinuousClock.now
        do {
          switch audioInput {
          case .pcmData:
            try await client.sendAudio(data)
          case .pcmBuffer:
            guard let buffer = AudioCaptureEngine.makePCMBuffer(from: data) else { continue }
            try await client.sendAudioBuffer(buffer)
          }
        } catch {
          DebugFileLogger.log("audio chunk send failed: \(error)")
          failureFlag.failed = true
          Task { await self.beginStreamRecovery(trigger: "audio chunk send failed: \(error)") }
          // If send fails, stop pumping — connection is dead.
          break
        }
        let elapsed = ContinuousClock.now - t0
        chunkCount += 1
        let shouldLog =
          chunkCount % 50 == 0
          || elapsed > .milliseconds(200)
          || lastLogTime == nil
        if shouldLog {
          DebugFileLogger.log("audio chunk #\(chunkCount) sent \(data.count)B in \(elapsed)")
          lastLogTime = ContinuousClock.now
        }
      }
    }
    return continuation
  }

  private func finishAudioChunkPipeline(timeout: Duration = .seconds(1)) async {
    audioChunkContinuation?.finish()
    audioChunkContinuation = nil

    // Give the detached sender a brief window to drain remaining chunks
    // (especially the tail audio from flushRemaining). Since it's detached,
    // this wait does NOT block the actor.
    guard let senderTask = audioChunkSenderTask else { return }
    let drained = await withTimeout(timeout) {
      await senderTask.value
    }
    if !drained {
      senderTask.cancel()
      DebugFileLogger.log("audio chunk pipeline drain timeout; sender cancelled")
    }
    audioChunkSenderTask = nil
  }

  private func markReadyIfNeeded() {
    guard !hasEmittedReadyForCurrentSession else { return }
    hasEmittedReadyForCurrentSession = true
    recordingStartTime = Date()
    DebugFileLogger.log("session emitting ready")
    onASREvent?(.ready)
    logger.info("Recording started")
  }

  // MARK: - Speculative LLM

  private var isSpeculativeLLMEnabled: Bool {
    let provider = CredentialStore.selectedLLMProvider
    guard provider.supportsSpeculativeProcessing else { return false }
    if let override = UserDefaults.standard.object(forKey: "tf_enableSpeculativeLLM") as? Bool {
      return override
    }
    return true
  }

  private var canRunSpeculativeLLMForCurrentSession: Bool {
    guard isSpeculativeLLMEnabled else { return false }
    #if HAS_CLOUD_SUBSCRIPTION
      guard !isCloudMode else { return false }
    #endif
    return true
  }

  /// Wait for a stable pause before sending a preview. The throttle also enforces
  /// a per-session request cap and a minimum interval between requests.
  private func scheduleSpeculativeLLM() {
    guard canRunSpeculativeLLMForCurrentSession,
      !speculativeLLMUnavailable
    else { return }
    let displaySourceText = currentTranscript.canonicalText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let text = SnippetStorage.applyEffective(to: displaySourceText, bundleId: targetBundleId)
    scheduleSpeculativeLLM(
      text: text,
      displaySourceText: displaySourceText,
      sourceRevision: currentTranscript.revision
    )
  }

  private func scheduleSpeculativeLLM(
    text: String,
    displaySourceText: String,
    sourceRevision: Int
  ) {
    guard state == .recording else { return }
    switch speculativeThrottle.submit(text) {
    case .tooShort:
      DebugFileLogger.log("speculative LLM: skipped reason=tooShort len=\(text.count)")
      speculativeDebounceTask?.cancel()
      speculativeDebounceTask = nil
      return
    case .duplicate:
      DebugFileLogger.log("speculative LLM: skipped reason=duplicate len=\(text.count)")
      speculativeDebounceTask?.cancel()
      speculativeDebounceTask = nil
      return
    case .deltaTooSmall:
      DebugFileLogger.log(
        "speculative LLM: skipped reason=deltaTooSmall len=\(text.count) last=\(speculativeThrottle.lastStartedText.count)"
      )
      speculativeDebounceTask?.cancel()
      speculativeDebounceTask = nil
      return
    case .queued:
      DebugFileLogger.log("speculative LLM: queued latest pending len=\(text.count)")
      return
    case .cooldown(let remaining):
      DebugFileLogger.log("speculative LLM: cooling down remaining=\(remaining)")
      speculativeDebounceTask?.cancel()
      speculativeDebounceTask = Task { [text, displaySourceText, sourceRevision] in
        try? await Task.sleep(for: remaining)
        guard !Task.isCancelled, state == .recording else { return }
        guard currentTranscript.revision == sourceRevision else {
          scheduleSpeculativeLLM()
          return
        }
        scheduleSpeculativeLLM(
          text: text,
          displaySourceText: displaySourceText,
          sourceRevision: sourceRevision
        )
      }
      return
    case .limitReached:
      DebugFileLogger.log(
        "speculative LLM: session request cap reached count=\(speculativeThrottle.requestCount)"
      )
      speculativeDebounceTask?.cancel()
      speculativeDebounceTask = nil
      return
    case .circuitOpen:
      DebugFileLogger.log("speculative LLM: circuit open, preview suppressed")
      speculativeDebounceTask?.cancel()
      speculativeDebounceTask = nil
      return
    case .debounce:
      break
    }

    speculativeDebounceTask?.cancel()
    speculativeDebounceTask = Task { [text, displaySourceText, sourceRevision] in
      try? await Task.sleep(for: SpeculativeLLMThrottle.debounceDuration)
      guard !Task.isCancelled, state == .recording else { return }
      guard currentTranscript.revision == sourceRevision else {
        scheduleSpeculativeLLM()
        return
      }
      await fireSpeculativeLLM(
        text: text,
        displaySourceText: displaySourceText,
        sourceRevision: sourceRevision
      )
    }
  }

  private func fireSpeculativeLLM(
    text: String,
    displaySourceText: String,
    sourceRevision: Int
  ) async {
    guard currentTranscript.revision == sourceRevision,
      speculativeThrottle.beginDebouncedRequest(for: text)
    else { return }
    let contextGeneration = sessionGeneration
    await resolvePromptContextIfNeeded(generation: contextGeneration)
    guard !Task.isCancelled,
      sessionGeneration == contextGeneration,
      state == .recording
    else {
      _ = speculativeThrottle.requestCompleted(input: text)
      return
    }
    guard let llmConfig = loadEffectiveLLMConfig() else {
      speculativeLLMUnavailable = true
      _ = speculativeThrottle.requestCompleted(input: text)
      onASREvent?(
        .liveOptimizationUnavailable(
          message: L("实时优化暂不可用", "Live optimization unavailable")
        ))
      return
    }

    let requestModeID = currentMode.id
    let prompt = promptContext.expandContextVariables(currentMode.prompt)
    let key = OptimizationRequestKey(
      text: text,
      prompt: prompt,
      modeID: requestModeID,
      provider: CredentialStore.selectedLLMProvider.rawValue,
      model: llmConfig.model,
      baseURL: llmConfig.baseURL
    )
    let request = LiveOptimizationRequest(
      key: key,
      displaySourceText: displaySourceText,
      sourceRevision: sourceRevision,
      modeID: requestModeID
    )
    liveOptimization.begin(request)
    let client = currentLLMClient()
    let requestGeneration = sessionGeneration
    onASREvent?(
      .liveOptimizationStarted(
        sourceText: displaySourceText,
        sourceRevision: sourceRevision,
        modeID: requestModeID
      ))
    DebugFileLogger.log(
      "speculative LLM: firing revision=\(sourceRevision) key=\(key.shortID) mode=\(currentMode.name) model=\(llmConfig.model) with \(text.count) chars"
    )

    speculativeLLMTask = Task {
      do {
        let result = try await self.performModeLLMRequest(
          client: client,
          text: text,
          prompt: prompt,
          config: llmConfig,
          modeID: requestModeID,
          retryInvalidOutput: false
        )
        guard !Task.isCancelled, requestGeneration == self.sessionGeneration else {
          _ = self.speculativeThrottle.requestCompleted(input: text)
          self.liveOptimization.fail(request)
          return nil
        }

        let cleaned = result.collapsingExtraSpaces
        DebugFileLogger.log(
          "speculative LLM: done revision=\(sourceRevision) key=\(key.shortID) chars=\(cleaned.count)"
        )
        let pending = self.speculativeThrottle.requestCompleted(input: text)
        let artifact = self.liveOptimization.complete(request, result: cleaned)
        if self.state == .recording {
          if let artifact {
            self.onASREvent?(
              .liveOptimizationResult(
                text: artifact.result,
                sourceText: request.displaySourceText,
                sourceRevision: request.sourceRevision,
                modeID: request.modeID
              ))
          } else {
            self.onASREvent?(
              .liveOptimizationFailed(
                message: L("实时优化失败", "Live optimization failed"),
                sourceText: request.displaySourceText,
                sourceRevision: request.sourceRevision
              ))
          }
          if pending != nil {
            self.scheduleSpeculativeLLM()
          }
        }
        return result
      } catch {
        let pending = self.speculativeThrottle.requestCompleted(input: text)
        self.liveOptimization.fail(request)
        guard !Task.isCancelled, requestGeneration == self.sessionGeneration else {
          return nil
        }
        let rateLimited = Self.isLLMRateLimit(error)
        DebugFileLogger.log("speculative LLM: failed \(error) rateLimited=\(rateLimited)")
        self.setPendingLLMError(error)
        if rateLimited {
          self.speculativeThrottle.tripCircuit()
          self.speculativeLLMUnavailable = true
        }
        if self.state == .recording {
          if rateLimited {
            self.onASREvent?(
              .liveOptimizationUnavailable(
                message: L(
                  "实时优化已暂停，停止录音后将尝试最终优化",
                  "Live preview paused; final optimization will run when recording stops"
                )
              ))
          } else {
            self.onASREvent?(
              .liveOptimizationFailed(
                message: L("实时优化失败", "Live optimization failed"),
                sourceText: request.displaySourceText,
                sourceRevision: request.sourceRevision
              ))
            if pending != nil {
              self.scheduleSpeculativeLLM()
            }
          }
        }
        return nil
      }
    }
  }

  static func isLLMRateLimit(_ error: Error) -> Bool {
    if case LLMError.requestFailed(429) = error { return true }
    let description = error.localizedDescription.lowercased()
    return description.contains("429")
      || description.contains("rate limit")
      || description.contains("too many requests")
      || description.contains("请求超限")
      || description.contains("请求过于频繁")
  }

  static func requiresFinalLLM(needsLLM: Bool, finalText: String) -> Bool {
    needsLLM && !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func cancelSpeculativeLLM() {
    speculativeDebounceTask?.cancel()
    speculativeDebounceTask = nil
    speculativeLLMTask?.cancel()
    speculativeLLMTask = nil
    liveOptimization.reset()
  }

  private func setPendingLLMError(_ error: Error) {
    pendingLLMError = error
  }

  private func resetSpeculativeLLM() {
    speculativeDebounceTask?.cancel()
    speculativeDebounceTask = nil
    speculativeLLMTask?.cancel()
    speculativeLLMTask = nil
    liveOptimization.reset()
    speculativeThrottle.reset()
    speculativeLLMUnavailable = false
  }

  /// Await an in-flight speculative task with a hard deadline; on timeout the
  /// task is cancelled and nil is returned so the caller can fire the final
  /// request itself.
  private func awaitWithTimeout(
    _ task: Task<String?, Never>,
    after duration: Duration
  ) async -> String? {
    await withCheckedContinuation { continuation in
      let finished = OSAllocatedUnfairLock(initialState: false)
      Task {
        let value = await task.value
        if finished.withLock({
          let old = $0
          $0 = true
          return !old
        }) {
          continuation.resume(returning: value)
        }
      }
      Task {
        try? await Task.sleep(for: duration)
        if finished.withLock({
          let old = $0
          $0 = true
          return !old
        }) {
          task.cancel()
          continuation.resume(returning: nil)
        }
      }
    }
  }

  // MARK: - Timeout Helper

  /// Run a @Sendable closure off-actor with a hard deadline.
  /// Returns true if completed in time. On timeout the operation task is cancelled.
  /// Uses detached tasks + continuation so withTaskGroup can't deadlock.
  private func withTimeout(
    _ duration: Duration,
    operation: @Sendable @escaping () async throws -> Void
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      let finished = OSAllocatedUnfairLock(initialState: false)
      let operationTask = Task.detached {
        let ok: Bool
        do {
          try await operation()
          ok = true
        } catch {
          ok = false
        }
        if finished.withLock({
          let old = $0
          $0 = true
          return !old
        }) {
          continuation.resume(returning: ok)
        }
      }
      Task.detached {
        try? await Task.sleep(for: duration)
        if finished.withLock({
          let old = $0
          $0 = true
          return !old
        }) {
          operationTask.cancel()
          continuation.resume(returning: false)
        }
      }
    }
  }

  private func resumeFirstStreamingTextOnTimeout() {
    if let cont = firstStreamingTextCont {
      firstStreamingTextCont = nil
      firstStreamingTextTimeoutTask = nil
      cont.resume(returning: false)
    }
  }

  /// Wait for the ASR to emit any non-empty streaming text, with timeout.
  /// Returns true if text arrived, false on timeout.
  private func awaitFirstStreamingText(timeout: Duration) async -> Bool {
    let text = currentTranscript.composedText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { return true }
    return await withCheckedContinuation { continuation in
      self.firstStreamingTextTimeoutTask?.cancel()
      self.firstStreamingTextCont = continuation
      self.firstStreamingTextTimeoutTask = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard let self, !Task.isCancelled else { return }
        await self.resumeFirstStreamingTextOnTimeout()
      }
    }
  }

  static func shouldAttemptBatchFallback(
    uploadFailed: Bool,
    asrTeardownClean: Bool,
    streamingError: Error?
  ) -> Bool {
    uploadFailed || !asrTeardownClean || streamingError != nil
  }

  // MARK: - Batch Fallback

  /// Try to transcribe full audio via the same provider.
  /// Soniox uses its async REST API (faster for complete audio); others use a fresh streaming connection.
  private func attemptBatchFallback(
    audio: Data,
    config: any ASRProviderConfig,
    provider: ASRProvider
  ) async -> String? {
    // Soniox: use async REST API instead of re-streaming
    if provider == .soniox, let sonioxConfig = config as? SonioxASRConfig {
      let bypass = ProxyBypassMode.current.bypassASR
      let hotwords = HotwordStorage.loadEffective()
      let apiKey = sonioxConfig.apiKey
      DebugFileLogger.log("batch fallback: using Soniox async API (\(audio.count) bytes)")
      let resultTask = Task.detached {
        await SonioxAsyncClient.transcribe(
          audioData: audio,
          apiKey: apiKey,
          hotwords: hotwords,
          bypassProxy: bypass
        )
      }
      return await withCheckedContinuation { continuation in
        let finished = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
          let result = await resultTask.value
          if finished.withLock({
            let old = $0
            $0 = true
            return !old
          }) {
            continuation.resume(returning: result?.text)
          }
        }
        Task.detached {
          try? await Task.sleep(for: .seconds(90))
          if finished.withLock({
            let old = $0
            $0 = true
            return !old
          }) {
            resultTask.cancel()
            DebugFileLogger.log("batch fallback (async) timeout after 90s")
            continuation.resume(returning: nil)
          }
        }
      }
    }

    // Other providers: fresh streaming connection with all audio at once
    let resultTask = Task.detached { () -> String? in
      guard let client = ASRProviderRegistry.createClient(for: provider) else { return nil }
      do {
        let options = ASRRequestOptions(enablePunc: true)
        try await client.connect(config: config, options: options)
        try await client.sendAudio(audio)
        try await client.endAudio()

        let events = await client.events
        for await event in events {
          switch event {
          case .transcript(let transcript) where transcript.isFinal:
            await client.disconnect()
            let text =
              transcript.authoritativeText.isEmpty
              ? transcript.composedText : transcript.authoritativeText
            return text.isEmpty ? nil : text
          case .error:
            await client.disconnect()
            return nil
          case .completed:
            await client.disconnect()
            return nil
          default:
            continue
          }
        }
        await client.disconnect()
        return nil
      } catch {
        DebugFileLogger.log("batch fallback error: \(error)")
        await client.disconnect()
        return nil
      }
    }
    // Hard timeout via withCheckedContinuation (same pattern as withTimeout).
    // If resultTask is stuck in a non-cooperative await, we return nil after 90s.
    return await withCheckedContinuation { continuation in
      let finished = OSAllocatedUnfairLock(initialState: false)
      Task.detached {
        let result = await resultTask.value
        if finished.withLock({
          let old = $0
          $0 = true
          return !old
        }) {
          continuation.resume(returning: result)
        }
      }
      Task.detached {
        try? await Task.sleep(for: .seconds(90))
        if finished.withLock({
          let old = $0
          $0 = true
          return !old
        }) {
          resultTask.cancel()
          DebugFileLogger.log("batch fallback timeout after 90s")
          continuation.resume(returning: nil)
        }
      }
    }
  }

  // MARK: - Force Reset

  /// Aggressively tear down all resources and return to idle.
  /// Used when a new recording is requested but the session is stuck
  /// (e.g. stopRecording hung on a WebSocket timeout).
  private func forceReset() async {
    NSLog("[Session] forceReset from state=%@", String(describing: state))
    DebugFileLogger.log("forceReset from state=\(state)")

    if let cont = firstStreamingTextCont {
      firstStreamingTextCont = nil
      firstStreamingTextTimeoutTask?.cancel()
      firstStreamingTextTimeoutTask = nil
      cont.resume(returning: false)
    }
    finalOptimizationDecisionTimeoutTask?.cancel()
    finalOptimizationDecisionTimeoutTask = nil
    if let continuation = finalOptimizationDecisionCont {
      finalOptimizationDecisionCont = nil
      continuation.resume(returning: .useRaw)
    }
    eventConsumptionTask?.cancel()
    eventConsumptionTask = nil
    maxDurationTask?.cancel()
    maxDurationTask = nil
    recoveryTask?.cancel()
    recoveryTask = nil
    resetSpeculativeLLM()

    audioEngine.stop()
    audioEngine.onAudioChunk = nil
    audioEngine.onAudioLevel = nil
    await finishAudioChunkPipeline(timeout: .milliseconds(100))
    finalizeCurrentAudioIfNeeded()
    if currentRecordID != nil {
      let partial = currentTranscript.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
      await persistCurrentHistory(
        rawText: partial,
        processedText: nil,
        finalText: partial,
        status: partial.isEmpty ? "session_reset_audio_saved" : "session_reset_partial_saved"
      )
    }

    if let client = asrClient {
      Task.detached { await client.disconnect() }  // fire-and-forget: detached to avoid blocking actor
    }
    asrClient = nil

    sessionGeneration &+= 1
    state = .idle
    currentTranscript = .empty
    promptContext = .empty
    capturedPromptContextRequirements = []
    pendingPromptContextCapture = nil
    hasEmittedReadyForCurrentSession = false
    currentConfig = nil
    uploadFailureFlag = nil
    lastStreamingError = nil
    clearRecoveryState()
    SystemVolumeManager.restore()
  }

}

// MARK: - String helpers

// `internal` (not `private`) so the text-normalization rules can be unit-tested
// via `@testable import Type4Me` (see RecognitionSessionTests).
extension String {
  /// Collapse runs of 2+ spaces into a single space.
  /// LLMs sometimes insert extra spaces between CJK and Latin text.
  var collapsingExtraSpaces: String {
    replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
  }

  /// Remove spurious spaces that hug a CJK character, while preserving the
  /// space between a CJK character and an adjacent Latin letter or digit
  /// (Pangu spacing, e.g. "最新的 prompt 提交" stays intact — see issue #186).
  ///
  /// Chinese text uses no inter-word spaces, so a space between two CJK
  /// characters — or between a CJK character and punctuation — is noise from
  /// ASR token boundaries or LLM formatting and is removed (中↔中, 中↔符,
  /// 符↔中). A space between a CJK character and an ASCII letter/digit is
  /// intentional and is kept (中↔英, 英↔中, 中↔数). Pure English
  /// "hello world" is untouched.
  var removingCJKLatinSpaces: String {
    let cjk = "[\\u3400-\\u4DBF\\u4E00-\\u9FFF\\uF900-\\uFAFF]"
    let preserveCJKLatinSpacing =
      UserDefaults.standard.object(forKey: "tf_preserveCJKLatinSpacing") as? Bool ?? true
    guard preserveCJKLatinSpacing else {
      var s = self
      s = s.replacingOccurrences(of: "(?<=\(cjk)) +(?=\\S)", with: "", options: .regularExpression)
      s = s.replacingOccurrences(of: "(?<=\\S) +(?=\(cjk))", with: "", options: .regularExpression)
      return s
    }
    // A neighbour that should hug the CJK character with no space: anything
    // that is neither whitespace nor an ASCII letter/digit (i.e. another CJK
    // char, punctuation, or a symbol). Latin letters/digits are excluded so
    // Pangu spacing is preserved.
    let glue = "[^\\sA-Za-z0-9]"
    var s = self
    // Space after CJK, before a non-letter/digit: "你 好" / "你 ，" → "你好" / "你，"
    // ("最新的 prompt" keeps its space because 'p' is a letter.)
    s = s.replacingOccurrences(
      of: "(?<=\(cjk)) +(?=\(glue))", with: "", options: .regularExpression)
    // Space before CJK, after a non-letter/digit: "， 你" → "，你"
    // ("Max 你" / "3 个" keep their space because 'x' / '3' are letter/digit.)
    s = s.replacingOccurrences(
      of: "(?<=\(glue)) +(?=\(cjk))", with: "", options: .regularExpression)
    return s
  }

  /// Strip trailing punctuation based on user preference (tf_stripTrailingPunctuation).
  var strippingTrailingPunctuation: String {
    let mode = UserDefaults.standard.string(forKey: "tf_stripTrailingPunctuation") ?? "off"
    guard mode != "off", !isEmpty else { return self }
    var s = self
    if mode == "period" {
      // Remove trailing periods: 。.
      while s.hasSuffix("。") || s.hasSuffix(".") {
        s.removeLast()
      }
    } else if mode == "all" {
      // Remove trailing punctuation (CJK + ASCII)
      let cjkPunc =
        "\u{3002}\u{FF0C}\u{FF01}\u{FF1F}\u{FF1B}\u{FF1A}\u{3001}\u{2026}\u{2014}\u{FF5E}\u{00B7}\u{300C}\u{300D}\u{300E}\u{300F}\u{3010}\u{3011}\u{FF08}\u{FF09}\u{300A}\u{300B}\u{201C}\u{201D}\u{2018}\u{2019}"
      let trailing = CharacterSet.punctuationCharacters
        .union(CharacterSet(charactersIn: cjkPunc))
      while let last = s.unicodeScalars.last, trailing.contains(last) {
        s.unicodeScalars.removeLast()
      }
    }
    return s
  }
}
