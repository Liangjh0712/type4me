import Foundation

struct AudioJournalMetadata: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case recording
        case finalized
    }

    let recordID: String
    let createdAt: Date
    let processingMode: String?
    let asrProvider: String
    let asrModel: String?
    var partialTranscript: String
    var state: State
    var audioRelativePath: String?
    var audioBytes: Int64
}

struct ArchivedAudio: Sendable, Equatable {
    let recordID: String
    let relativePath: String
    let byteCount: Int64
    let durationSeconds: Double
}

struct RecoveredAudio: Sendable, Equatable {
    let metadata: AudioJournalMetadata
    let audio: ArchivedAudio
}

enum AudioArchiveError: Error {
    case cannotCreateJournal
    case invalidAudioFile
}

final class AudioJournalWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let archive: AudioArchive
    private let partURL: URL
    private let metadataURL: URL
    private let finalURL: URL
    private var handle: FileHandle?
    private var metadata: AudioJournalMetadata
    private var pcmByteCount: Int64 = 0
    private var lastMetadataWrite = Date.distantPast
    private var lastAudioSync = Date.distantPast

    init(
        archive: AudioArchive,
        partURL: URL,
        metadataURL: URL,
        finalURL: URL,
        handle: FileHandle,
        metadata: AudioJournalMetadata
    ) {
        self.archive = archive
        self.partURL = partURL
        self.metadataURL = metadataURL
        self.finalURL = finalURL
        self.handle = handle
        self.metadata = metadata
    }

    var recordID: String { metadata.recordID }

    func append(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        lock.withLock {
            guard let handle else { return }
            do {
                try handle.write(contentsOf: pcmData)
                pcmByteCount += Int64(pcmData.count)
                if Date().timeIntervalSince(lastAudioSync) >= 1 {
                    try handle.synchronize()
                    lastAudioSync = Date()
                }
            } catch {
                DebugFileLogger.log("audio journal append failed: \(error)")
            }
        }
    }

    func updatePartialTranscript(_ text: String) {
        lock.withLock {
            metadata.partialTranscript = text
            guard Date().timeIntervalSince(lastMetadataWrite) >= 1 else { return }
            do {
                try archive.writeMetadata(metadata, to: metadataURL)
                try handle?.synchronize()
                lastMetadataWrite = Date()
            } catch {
                DebugFileLogger.log("audio journal metadata checkpoint failed: \(error)")
            }
        }
    }

    func finalize() -> ArchivedAudio? {
        lock.withLock {
            do {
                try handle?.synchronize()
                try handle?.close()
                handle = nil

                let partBytes = try archive.fileSize(at: partURL)
                guard partBytes > 0 else {
                    archive.removeItemIfPresent(partURL)
                    archive.removeItemIfPresent(metadataURL)
                    return nil
                }
                let audio = try archive.finalizePCM(
                    partURL: partURL,
                    finalURL: finalURL,
                    recordID: metadata.recordID
                )
                metadata.state = .finalized
                metadata.audioRelativePath = audio.relativePath
                metadata.audioBytes = audio.byteCount
                try archive.writeMetadata(metadata, to: metadataURL)
                return audio
            } catch {
                DebugFileLogger.log("audio journal finalize failed: \(error)")
                return nil
            }
        }
    }

    func commit() {
        lock.withLock {
            archive.removeItemIfPresent(metadataURL)
        }
    }

    func discard() {
        lock.withLock {
            try? handle?.close()
            handle = nil
            archive.removeItemIfPresent(partURL)
            archive.removeItemIfPresent(finalURL)
            archive.removeItemIfPresent(metadataURL)
        }
    }
}

final class AudioArchive: @unchecked Sendable {
    static let shared = AudioArchive()

    static let sampleRate = 16_000
    static let channels = 1
    static let bitsPerSample = 16
    static let bytesPerSecond = sampleRate * channels * bitsPerSample / 8
    static let minimumRecoverableBytes = bytesPerSecond / 3

    private let fileManager: FileManager
    private let baseURL: URL
    private let audioDirectoryURL: URL

    init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseURL {
            self.baseURL = baseURL
        } else {
            self.baseURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("Type4Me", isDirectory: true)
        }
        audioDirectoryURL = self.baseURL.appendingPathComponent("Audio", isDirectory: true)
        try? ensureDirectory()
    }

    func beginJournal(metadata: AudioJournalMetadata) throws -> AudioJournalWriter {
        try ensureDirectory()
        let partURL = audioDirectoryURL.appendingPathComponent("\(metadata.recordID).pcm.part")
        let metadataURL = audioDirectoryURL.appendingPathComponent("\(metadata.recordID).json")
        let finalURL = audioDirectoryURL.appendingPathComponent("\(metadata.recordID).wav")
        removeItemIfPresent(partURL)
        removeItemIfPresent(finalURL)
        guard fileManager.createFile(atPath: partURL.path, contents: nil) else {
            throw AudioArchiveError.cannotCreateJournal
        }
        let handle = try FileHandle(forWritingTo: partURL)
        try writeMetadata(metadata, to: metadataURL)
        try excludeFromBackup(partURL)
        return AudioJournalWriter(
            archive: self,
            partURL: partURL,
            metadataURL: metadataURL,
            finalURL: finalURL,
            handle: handle,
            metadata: metadata
        )
    }

    func recoverInterruptedRecordings() -> [RecoveredAudio] {
        do {
            try ensureDirectory()
            let urls = try fileManager.contentsOfDirectory(
                at: audioDirectoryURL,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            for temporaryWAV in urls where temporaryWAV.lastPathComponent.hasSuffix(".wav.tmp") {
                removeItemIfPresent(temporaryWAV)
            }
            let metadataURLs = urls.filter { $0.pathExtension == "json" }
            var recovered: [RecoveredAudio] = []
            var knownRecordIDs = Set<String>()

            for metadataURL in metadataURLs {
                guard let metadata = try? readMetadata(from: metadataURL) else {
                    removeItemIfPresent(metadataURL)
                    continue
                }
                knownRecordIDs.insert(metadata.recordID)
                if let item = recover(metadata: metadata, metadataURL: metadataURL) {
                    recovered.append(item)
                }
            }

            for partURL in urls where partURL.lastPathComponent.hasSuffix(".pcm.part") {
                let recordID = String(partURL.lastPathComponent.dropLast(".pcm.part".count))
                guard !knownRecordIDs.contains(recordID) else { continue }
                let values = try? partURL.resourceValues(forKeys: [.creationDateKey])
                let metadata = AudioJournalMetadata(
                    recordID: recordID,
                    createdAt: values?.creationDate ?? Date(),
                    processingMode: nil,
                    asrProvider: L("未知", "Unknown"),
                    asrModel: nil,
                    partialTranscript: "",
                    state: .recording,
                    audioRelativePath: nil,
                    audioBytes: 0
                )
                let metadataURL = audioDirectoryURL.appendingPathComponent("\(recordID).json")
                try? writeMetadata(metadata, to: metadataURL)
                if let item = recover(metadata: metadata, metadataURL: metadataURL) {
                    recovered.append(item)
                }
            }
            return recovered.sorted { $0.metadata.createdAt < $1.metadata.createdAt }
        } catch {
            DebugFileLogger.log("audio archive recovery scan failed: \(error)")
            return []
        }
    }

    func commitRecoveredMetadata(recordID: String) {
        removeItemIfPresent(audioDirectoryURL.appendingPathComponent("\(recordID).json"))
    }

    func fileURL(relativePath: String) -> URL {
        baseURL.appendingPathComponent(relativePath)
    }

    func readPCM(relativePath: String) throws -> Data {
        let wavData = try Data(contentsOf: fileURL(relativePath: relativePath), options: .mappedIfSafe)
        guard wavData.count >= 44,
              String(data: wavData.prefix(4), encoding: .ascii) == "RIFF",
              String(data: wavData[8..<12], encoding: .ascii) == "WAVE",
              Self.littleEndianUInt32(in: wavData, offset: 4) == UInt32(wavData.count - 8),
              Self.littleEndianUInt32(in: wavData, offset: 40) == UInt32(wavData.count - 44)
        else {
            throw AudioArchiveError.invalidAudioFile
        }
        return Data(wavData.dropFirst(44))
    }
    func remove(relativePath: String?) {
        guard let relativePath, !relativePath.isEmpty else { return }
        removeItemIfPresent(fileURL(relativePath: relativePath))
    }

    func removeUnreferencedWAVs(referencedRelativePaths: Set<String>) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: audioDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let pendingRecordIDs = Set(
            urls.filter { $0.pathExtension == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
        for url in urls where url.pathExtension == "wav" {
            let relativePath = "Audio/\(url.lastPathComponent)"
            let recordID = url.deletingPathExtension().lastPathComponent
            guard !referencedRelativePaths.contains(relativePath),
                  !pendingRecordIDs.contains(recordID)
            else { continue }
            removeItemIfPresent(url)
        }
    }

    func fileSize(relativePath: String) -> Int64 {
        (try? fileSize(at: fileURL(relativePath: relativePath))) ?? 0
    }

    fileprivate func finalizePCM(partURL: URL, finalURL: URL, recordID: String) throws -> ArchivedAudio {
        let pcmBytes = try fileSize(at: partURL)
        guard pcmBytes >= Int64(Self.minimumRecoverableBytes), pcmBytes <= Int64(UInt32.max) else {
            throw AudioArchiveError.invalidAudioFile
        }
        let temporaryURL = finalURL.appendingPathExtension("tmp")
        removeItemIfPresent(temporaryURL)
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw AudioArchiveError.cannotCreateJournal
        }
        let output = try FileHandle(forWritingTo: temporaryURL)
        let input = try FileHandle(forReadingFrom: partURL)
        do {
            try output.write(contentsOf: Self.wavHeader(pcmByteCount: UInt32(pcmBytes)))
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try output.close()
            try input.close()
            removeItemIfPresent(finalURL)
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? output.close()
            try? input.close()
            removeItemIfPresent(temporaryURL)
            throw error
        }
        removeItemIfPresent(partURL)
        try excludeFromBackup(finalURL)
        let finalBytes = try fileSize(at: finalURL)
        return ArchivedAudio(
            recordID: recordID,
            relativePath: "Audio/\(recordID).wav",
            byteCount: finalBytes,
            durationSeconds: Double(pcmBytes) / Double(Self.bytesPerSecond)
        )
    }

    fileprivate func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    fileprivate func writeMetadata(_ metadata: AudioJournalMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
        try excludeFromBackup(url)
    }

    fileprivate func removeItemIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func recover(metadata: AudioJournalMetadata, metadataURL: URL) -> RecoveredAudio? {
        do {
            let partURL = audioDirectoryURL.appendingPathComponent("\(metadata.recordID).pcm.part")
            let defaultFinalURL = audioDirectoryURL.appendingPathComponent("\(metadata.recordID).wav")
            let audio: ArchivedAudio

            // A surviving PCM journal is authoritative. A crash may have left a
            // partially copied WAV, so always rebuild from the complete PCM first.
            if fileManager.fileExists(atPath: partURL.path) {
                guard try fileSize(at: partURL) >= Int64(Self.minimumRecoverableBytes) else {
                    removeItemIfPresent(partURL)
                    removeItemIfPresent(defaultFinalURL)
                    removeItemIfPresent(metadataURL)
                    return nil
                }
                audio = try finalizePCM(
                    partURL: partURL,
                    finalURL: defaultFinalURL,
                    recordID: metadata.recordID
                )
            } else {
                let relativePath = metadata.audioRelativePath ?? "Audio/\(metadata.recordID).wav"
                let wavURL = fileURL(relativePath: relativePath)
                guard let validated = archivedAudioFromWAV(
                    url: wavURL,
                    relativePath: relativePath,
                    recordID: metadata.recordID
                ) else {
                    removeItemIfPresent(wavURL)
                    removeItemIfPresent(metadataURL)
                    return nil
                }
                audio = validated
            }

            var finalizedMetadata = metadata
            finalizedMetadata.state = .finalized
            finalizedMetadata.audioRelativePath = audio.relativePath
            finalizedMetadata.audioBytes = audio.byteCount
            try writeMetadata(finalizedMetadata, to: metadataURL)
            return RecoveredAudio(metadata: finalizedMetadata, audio: audio)
        } catch {
            DebugFileLogger.log("audio archive record recovery failed id=\(metadata.recordID): \(error)")
            return nil
        }
    }

    private func archivedAudioFromWAV(
        url: URL,
        relativePath: String,
        recordID: String
    ) -> ArchivedAudio? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 44,
              String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE",
              Self.littleEndianUInt32(in: data, offset: 4) == UInt32(data.count - 8),
              Self.littleEndianUInt32(in: data, offset: 40) == UInt32(data.count - 44)
        else { return nil }
        let pcmBytes = data.count - 44
        guard pcmBytes >= Self.minimumRecoverableBytes else { return nil }
        return ArchivedAudio(
            recordID: recordID,
            relativePath: relativePath,
            byteCount: Int64(data.count),
            durationSeconds: Double(pcmBytes) / Double(Self.bytesPerSecond)
        )
    }

    private func readMetadata(from url: URL) throws -> AudioJournalMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AudioJournalMetadata.self, from: Data(contentsOf: url))
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
        try excludeFromBackup(audioDirectoryURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func littleEndianUInt32(in data: Data, offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func wavHeader(pcmByteCount: UInt32) -> Data {
        let byteRate = UInt32(sampleRate * channels * bitsPerSample / 8)
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(36 + pcmByteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(pcmByteCount)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
