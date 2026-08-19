import CryptoKit
import Foundation

/// Assigns one semantic revision to every canonical ASR text. Formatting-only
/// rewrites stay on the same revision so they do not invalidate an LLM result.
struct TranscriptRevisionTracker: Sendable {
  private(set) var revision = 0
  private(set) var latestText = ""

  mutating func update(_ text: String) -> Int {
    let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return revision }

    if latestText.isEmpty {
      revision = 1
    } else if !TranscriptDiff.classify(source: latestText, final: candidate).canReuseLLMResult {
      revision &+= 1
    }
    latestText = candidate
    return revision
  }

  mutating func reset() {
    revision = 0
    latestText = ""
  }
}

/// Complete identity of one cacheable text-processing request. Equality uses
/// the full values; SHA-256 is only a stable diagnostic identifier.
struct OptimizationRequestKey: Hashable, Codable, Sendable {
  let text: String
  let prompt: String
  let modeID: UUID
  let provider: String
  let model: String
  let baseURL: String

  var shortID: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(self)) ?? Data()
    return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
  }
}

struct LiveOptimizationRequest: Equatable, Sendable {
  let key: OptimizationRequestKey
  let displaySourceText: String
  let sourceRevision: Int
  let modeID: UUID
}

struct LiveOptimizationArtifact: Equatable, Sendable {
  let request: LiveOptimizationRequest
  let result: String
}

/// Keeps request metadata and its result atomic. A newer request can never
/// accidentally relabel an older result as belonging to new input.
struct LiveOptimizationCoordinator: Sendable {
  private(set) var activeRequest: LiveOptimizationRequest?
  private(set) var latestArtifact: LiveOptimizationArtifact?

  mutating func begin(_ request: LiveOptimizationRequest) {
    activeRequest = request
  }

  mutating func complete(
    _ request: LiveOptimizationRequest,
    result: String
  ) -> LiveOptimizationArtifact? {
    guard activeRequest == request else { return nil }
    activeRequest = nil
    guard !result.isEmpty else { return nil }
    let artifact = LiveOptimizationArtifact(request: request, result: result)
    latestArtifact = artifact
    return artifact
  }

  mutating func fail(_ request: LiveOptimizationRequest) {
    if activeRequest == request {
      activeRequest = nil
    }
  }

  func committableArtifact(revision: Int, modeID: UUID) -> LiveOptimizationArtifact? {
    guard let latestArtifact,
      latestArtifact.request.sourceRevision == revision,
      latestArtifact.request.modeID == modeID
    else { return nil }
    return latestArtifact
  }

  func matchingActiveRequest(revision: Int, modeID: UUID) -> LiveOptimizationRequest? {
    guard let activeRequest,
      activeRequest.sourceRevision == revision,
      activeRequest.modeID == modeID
    else { return nil }
    return activeRequest
  }

  mutating func reset() {
    activeRequest = nil
    latestArtifact = nil
  }
}

/// Small in-memory LRU with a hard TTL. Failed or empty requests are never inserted.
struct LLMResultCache: Sendable {
  struct Entry: Sendable {
    let result: String
    let createdAt: ContinuousClock.Instant
    var lastAccessedAt: ContinuousClock.Instant
  }

  let ttl: Duration
  let maximumEntryCount: Int
  private(set) var entries: [OptimizationRequestKey: Entry] = [:]

  init(ttl: Duration = .seconds(30 * 60), maximumEntryCount: Int = 32) {
    self.ttl = ttl
    self.maximumEntryCount = max(1, maximumEntryCount)
  }

  mutating func value(
    for key: OptimizationRequestKey,
    now: ContinuousClock.Instant = .now
  ) -> String? {
    pruneExpired(now: now)
    guard var entry = entries[key] else { return nil }
    entry.lastAccessedAt = now
    entries[key] = entry
    return entry.result
  }

  mutating func insert(
    _ result: String,
    for key: OptimizationRequestKey,
    now: ContinuousClock.Instant = .now
  ) {
    guard !result.isEmpty else { return }
    pruneExpired(now: now)
    if entries[key] == nil, entries.count >= maximumEntryCount,
      let oldestKey = entries.min(by: {
        $0.value.lastAccessedAt < $1.value.lastAccessedAt
      })?.key
    {
      entries.removeValue(forKey: oldestKey)
    }
    entries[key] = Entry(result: result, createdAt: now, lastAccessedAt: now)
  }

  mutating func removeAll() {
    entries.removeAll(keepingCapacity: true)
  }

  private mutating func pruneExpired(now: ContinuousClock.Instant) {
    entries = entries.filter { now - $0.value.createdAt < ttl }
  }
}

actor LLMRequestMemoizer {
  enum Source: Sendable, Equatable, Hashable {
    case network
    case inFlight
    case cache
  }

  struct Lookup: Sendable, Equatable {
    let result: String
    let source: Source
  }

  private var cache: LLMResultCache
  private var inFlight: [OptimizationRequestKey: Task<String, Error>] = [:]

  init(ttl: Duration = .seconds(30 * 60), maximumEntryCount: Int = 32) {
    cache = LLMResultCache(ttl: ttl, maximumEntryCount: maximumEntryCount)
  }

  func value(
    for key: OptimizationRequestKey,
    operation: @escaping @Sendable () async throws -> String
  ) async throws -> Lookup {
    if let cached = cache.value(for: key) {
      return Lookup(result: cached, source: .cache)
    }
    if let task = inFlight[key] {
      return Lookup(result: try await task.value, source: .inFlight)
    }

    let task = Task<String, Error> {
      try await operation()
    }
    inFlight[key] = task
    do {
      let result = try await task.value
      inFlight.removeValue(forKey: key)
      cache.insert(result, for: key)
      return Lookup(result: result, source: .network)
    } catch {
      inFlight.removeValue(forKey: key)
      throw error
    }
  }
}
