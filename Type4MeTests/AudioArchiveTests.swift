import XCTest
@testable import Type4Me

final class AudioArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Type4Me-AudioArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testFinalizeJournalProducesReadableWAV() throws {
        let archive = AudioArchive(baseURL: directory)
        let metadata = makeMetadata(id: "finalized")
        let writer = try archive.beginJournal(metadata: metadata)
        let pcm = Data(repeating: 0x2A, count: AudioArchive.bytesPerSecond * 2)

        writer.append(pcm)
        let audio = try XCTUnwrap(writer.finalize())

        XCTAssertEqual(audio.relativePath, "Audio/finalized.wav")
        XCTAssertEqual(audio.durationSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(audio.byteCount, Int64(pcm.count + 44))
        XCTAssertEqual(try archive.readPCM(relativePath: audio.relativePath), pcm)

        writer.commit()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Audio/finalized.json").path
        ))
    }

    func testRecoverInterruptedJournalPreservesPartialTranscript() throws {
        let archive = AudioArchive(baseURL: directory)
        let writer = try archive.beginJournal(metadata: makeMetadata(id: "crashed"))
        writer.updatePartialTranscript("崩溃前已经识别的内容")
        writer.append(Data(repeating: 0x11, count: AudioArchive.bytesPerSecond))

        let recovered = try XCTUnwrap(AudioArchive(baseURL: directory).recoverInterruptedRecordings().first)

        XCTAssertEqual(recovered.metadata.recordID, "crashed")
        XCTAssertEqual(recovered.metadata.partialTranscript, "崩溃前已经识别的内容")
        XCTAssertEqual(recovered.audio.durationSeconds, 1, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.fileURL(relativePath: recovered.audio.relativePath).path
        ))
    }

    func testRecoveryPrefersCompletePCMOverPartialWAV() throws {
        let archive = AudioArchive(baseURL: directory)
        let writer = try archive.beginJournal(metadata: makeMetadata(id: "partial-wav"))
        let pcm = Data(repeating: 0x33, count: AudioArchive.bytesPerSecond * 2)
        writer.append(pcm)
        let partialWAV = directory.appendingPathComponent("Audio/partial-wav.wav")
        try Data(repeating: 0, count: AudioArchive.minimumRecoverableBytes + 44).write(to: partialWAV)

        let recovered = try XCTUnwrap(AudioArchive(baseURL: directory).recoverInterruptedRecordings().first)
        XCTAssertEqual(recovered.audio.durationSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(try archive.readPCM(relativePath: recovered.audio.relativePath), pcm)
    }

    func testRecoverFinalizedWAVWhenMetadataCheckpointWasInterrupted() throws {
        let archive = AudioArchive(baseURL: directory)
        let metadata = makeMetadata(id: "finalize-race")
        let writer = try archive.beginJournal(metadata: metadata)

        writer.append(Data(repeating: 0x22, count: AudioArchive.bytesPerSecond))
        XCTAssertNotNil(writer.finalize())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let staleMetadataURL = directory.appendingPathComponent("Audio/finalize-race.json")
        try encoder.encode(metadata).write(to: staleMetadataURL, options: .atomic)

        let recovered = try XCTUnwrap(AudioArchive(baseURL: directory).recoverInterruptedRecordings().first)
        XCTAssertEqual(recovered.audio.relativePath, "Audio/finalize-race.wav")
        XCTAssertEqual(recovered.audio.durationSeconds, 1, accuracy: 0.001)
    }
    func testReconcileRemovesOnlyUnreferencedFinalAudio() throws {
        let archive = AudioArchive(baseURL: directory)
        let orphanWriter = try archive.beginJournal(metadata: makeMetadata(id: "orphan"))
        orphanWriter.append(Data(repeating: 0x44, count: AudioArchive.bytesPerSecond))
        let orphan = try XCTUnwrap(orphanWriter.finalize())
        orphanWriter.commit()

        let retainedWriter = try archive.beginJournal(metadata: makeMetadata(id: "retained"))
        retainedWriter.append(Data(repeating: 0x55, count: AudioArchive.bytesPerSecond))
        let retained = try XCTUnwrap(retainedWriter.finalize())
        retainedWriter.commit()

        archive.removeUnreferencedWAVs(referencedRelativePaths: [retained.relativePath])

        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.fileURL(relativePath: orphan.relativePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.fileURL(relativePath: retained.relativePath).path))
    }

    func testCorruptMetadataDoesNotPinOrphanedWAV() throws {
        let archive = AudioArchive(baseURL: directory)
        let writer = try archive.beginJournal(metadata: makeMetadata(id: "corrupt-metadata"))
        writer.append(Data(repeating: 0x66, count: AudioArchive.bytesPerSecond))
        let audio = try XCTUnwrap(writer.finalize())
        let metadataURL = directory.appendingPathComponent("Audio/corrupt-metadata.json")
        try Data("not-json".utf8).write(to: metadataURL)

        XCTAssertTrue(archive.recoverInterruptedRecordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))

        archive.removeUnreferencedWAVs(referencedRelativePaths: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.fileURL(relativePath: audio.relativePath).path))
    }

    func testTooShortInterruptedJournalIsNotImported() throws {
        let archive = AudioArchive(baseURL: directory)
        let writer = try archive.beginJournal(metadata: makeMetadata(id: "too-short"))
        writer.append(Data(repeating: 0, count: AudioArchive.minimumRecoverableBytes - 1))

        XCTAssertTrue(AudioArchive(baseURL: directory).recoverInterruptedRecordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Audio/too-short.pcm.part").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Audio/too-short.json").path
        ))
    }

    private func makeMetadata(id: String) -> AudioJournalMetadata {
        AudioJournalMetadata(
            recordID: id,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            processingMode: "语音润色",
            asrProvider: "Test ASR",
            asrModel: "test-model",
            partialTranscript: "",
            state: .recording,
            audioRelativePath: nil,
            audioBytes: 0
        )
    }
}
