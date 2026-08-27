import Foundation
import os

struct HistoryRetranscriptionResult: Sendable, Equatable {
    let text: String
    let providerName: String
    let modelName: String?
}

enum HistoryRetranscriptionError: LocalizedError {
    case audioUnavailable
    case providerUnavailable(String)
    case configurationMissing(String)
    case emptyResult
    case timedOut

    var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            return L("历史音频不可用", "History audio is unavailable")
        case .providerUnavailable(let provider):
            return L("当前识别引擎不可用：\(provider)", "Current recognition provider is unavailable: \(provider)")
        case .configurationMissing(let provider):
            return L("请先配置 \(provider)", "Please configure \(provider) first")
        case .emptyResult:
            return L("没有识别到文字，音频仍已保留", "No text was recognized; the audio is still retained")
        case .timedOut:
            return L("重新转写超时，音频仍已保留", "Retranscription timed out; the audio is still retained")
        }
    }
}

enum HistoryRetranscriptionService {
    static func transcribe(audioRelativePath: String) async throws -> HistoryRetranscriptionResult {
        let pcmData: Data
        do {
            pcmData = try AudioArchive.shared.readPCM(relativePath: audioRelativePath)
        } catch {
            throw HistoryRetranscriptionError.audioUnavailable
        }
        guard !pcmData.isEmpty else { throw HistoryRetranscriptionError.audioUnavailable }

        let provider = CredentialStore.selectedASRProvider
        guard ASRProviderRegistry.capabilities(for: provider).isAvailable else {
            throw HistoryRetranscriptionError.providerUnavailable(provider.displayName)
        }
        guard let config = resolveConfig(for: provider) else {
            throw HistoryRetranscriptionError.configurationMissing(provider.displayName)
        }

        let result = await transcribe(
            pcmData: pcmData,
            config: config,
            provider: provider,
            timeout: .seconds(90)
        )
        guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HistoryRetranscriptionError.emptyResult
        }
        return HistoryRetranscriptionResult(
            text: result,
            providerName: provider.displayName,
            modelName: modelLabel(provider: provider, config: config)
        )
    }

    static func transcribe(
        pcmData: Data,
        config: any ASRProviderConfig,
        provider: ASRProvider,
        timeout: Duration
    ) async -> String? {
        let task = Task.detached { () -> String? in
            if provider == .soniox, let sonioxConfig = config as? SonioxASRConfig {
                let result = await SonioxAsyncClient.transcribe(
                    audioData: pcmData,
                    apiKey: sonioxConfig.apiKey,
                    hotwords: HotwordStorage.loadEffective(),
                    bypassProxy: ProxyBypassMode.current.bypassASR
                )
                return result?.text
            }

            guard let client = ASRProviderRegistry.createClient(for: provider) else { return nil }
            do {
                let options = ASRRequestOptions(
                    enablePunc: true,
                    hotwords: HotwordStorage.loadEffective(),
                    bypassProxy: ProxyBypassMode.current.bypassASR
                )
                try await client.connect(config: config, options: options)
                let capabilities = ASRProviderRegistry.capabilities(for: provider)
                switch capabilities.audioInput {
                case .pcmData:
                    if capabilities.isStreaming {
                        for offset in stride(from: 0, to: pcmData.count, by: AudioCaptureEngine.chunkByteSize) {
                            try Task.checkCancellation()
                            let end = min(offset + AudioCaptureEngine.chunkByteSize, pcmData.count)
                            try await client.sendAudio(Data(pcmData[offset..<end]))
                            await Task.yield()
                        }
                    } else {
                        try await client.sendAudio(pcmData)
                    }
                case .pcmBuffer:
                    if capabilities.isStreaming {
                        for offset in stride(from: 0, to: pcmData.count, by: AudioCaptureEngine.chunkByteSize) {
                            try Task.checkCancellation()
                            let end = min(offset + AudioCaptureEngine.chunkByteSize, pcmData.count)
                            guard let buffer = AudioCaptureEngine.makePCMBuffer(from: Data(pcmData[offset..<end])) else {
                                await client.disconnect()
                                return nil
                            }
                            try await client.sendAudioBuffer(buffer)
                            await Task.yield()
                        }
                    } else {
                        guard let buffer = AudioCaptureEngine.makePCMBuffer(from: pcmData) else {
                            await client.disconnect()
                            return nil
                        }
                        try await client.sendAudioBuffer(buffer)
                    }
                }
                try await client.endAudio()

                let events = await client.events
                let text = await sessionFinalText(from: events)
                await client.disconnect()
                return text
            } catch {
                DebugFileLogger.log("history retranscription failed: \(error)")
                await client.disconnect()
                return nil
            }
        }

        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            Task.detached {
                let result = await task.value
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: result)
                }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    task.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Reduce an ASR event stream to the session's final text.
    ///
    /// Transcript events are cumulative snapshots, and utterance-level
    /// `isFinal` is NOT session-final (RecognitionSession's teardown drain
    /// relies on this): the first final can be an early endpointed utterance
    /// — even an empty one, e.g. the retained start chime — while recognition
    /// is still ongoing. Keep the latest non-empty snapshot until a terminal
    /// event or stream end.
    static func sessionFinalText(from events: AsyncStream<RecognitionEvent>) async -> String? {
        var latestText = ""
        for await event in events {
            if Task.isCancelled { break }
            switch event {
            case .transcript(let transcript):
                let text = transcript.authoritativeText.isEmpty
                    ? transcript.composedText
                    : transcript.authoritativeText
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latestText = text
                }
            case .error(let error):
                DebugFileLogger.log(
                    "sessionFinalText: stream error after \(latestText.count) chars: \(error)")
                return latestText.isEmpty ? nil : latestText
            case .completed:
                return latestText.isEmpty ? nil : latestText
            default:
                continue
            }
        }
        return latestText.isEmpty ? nil : latestText
    }

    private static func resolveConfig(for provider: ASRProvider) -> (any ASRProviderConfig)? {
        if provider == .sherpa {
            return CredentialStore.loadASRConfig(for: provider)
                ?? SherpaASRConfig(credentials: ["modelDir": ModelManager.defaultModelsDir])
        }
        return CredentialStore.loadASRConfig(for: provider)
    }

    private static func modelLabel(
        provider: ASRProvider,
        config: any ASRProviderConfig
    ) -> String? {
        if provider == .sherpa {
            return ModelManager.selectedStreamingModel.displayName
        }
        let credentials = config.toCredentials()
        return ["model", "resourceId", "devPid", "lmId"]
            .compactMap { credentials[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
