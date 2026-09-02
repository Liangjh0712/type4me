import Foundation
import SQLite3

extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("Type4Me.historyStoreDidChange")
}

actor HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let audioArchive: AudioArchive

    init(path: String? = nil, audioArchive: AudioArchive? = nil) {
        if let audioArchive {
            self.audioArchive = audioArchive
        } else if let path {
            self.audioArchive = AudioArchive(
                baseURL: URL(fileURLWithPath: path).deletingLastPathComponent()
            )
        } else {
            self.audioArchive = .shared
        }
        let dbPath: String
        if let path {
            dbPath = path
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("Type4Me", isDirectory: true)
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            dbPath = appSupport.appendingPathComponent("history-v2.db").path
        }

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            let sql = """
            CREATE TABLE IF NOT EXISTS recognition_history (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                duration_seconds REAL,
                raw_text TEXT NOT NULL,
                processing_mode TEXT,
                processed_text TEXT,
                final_text TEXT NOT NULL,
                status TEXT NOT NULL,
                character_count INTEGER,
                asr_provider TEXT,
                asr_model TEXT,
                audio_path TEXT,
                audio_bytes INTEGER,
                audio_duration_seconds REAL,
                audio_status TEXT,
                retranscribed_text TEXT,
                retranscription_provider TEXT,
                retranscription_model TEXT
            );
            """
            sqlite3_exec(db, sql, nil, nil, nil)


            // Index for ORDER BY created_at DESC pagination
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_history_created_at ON recognition_history(created_at DESC);", nil, nil, nil)
        } else if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - CRUD

    @discardableResult
    func insert(_ record: HistoryRecord) -> Bool {
        let sql = """
        INSERT OR REPLACE INTO recognition_history
        (id, created_at, duration_seconds, raw_text, processing_mode, processed_text, final_text, status, character_count, asr_provider, asr_model, audio_path, audio_bytes, audio_duration_seconds, audio_status, retranscribed_text, retranscription_provider, retranscription_model)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bind(stmt, 1, record.id)
        bind(stmt, 2, iso.string(from: record.createdAt))
        sqlite3_bind_double(stmt, 3, record.durationSeconds)
        bind(stmt, 4, record.rawText)
        bindOptional(stmt, 5, record.processingMode)
        bindOptional(stmt, 6, record.processedText)
        bind(stmt, 7, record.finalText)
        bind(stmt, 8, record.status)
        if let count = record.characterCount {
            sqlite3_bind_int(stmt, 9, Int32(count))
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        bindOptional(stmt, 10, record.asrProvider)
        bindOptional(stmt, 11, record.asrModel)
        bindOptional(stmt, 12, record.audioPath)
        if let bytes = record.audioBytes {
            sqlite3_bind_int64(stmt, 13, bytes)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        if let duration = record.audioDurationSeconds {
            sqlite3_bind_double(stmt, 14, duration)
        } else {
            sqlite3_bind_null(stmt, 14)
        }
        bindOptional(stmt, 15, record.audioStatus)
        bindOptional(stmt, 16, record.retranscribedText)
        bindOptional(stmt, 17, record.retranscriptionProvider)
        bindOptional(stmt, 18, record.retranscriptionModel)
        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
            return true
        }
        return false
    }

    func contains(id: String) -> Bool {
        let sql = "SELECT 1 FROM recognition_history WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func fetchAll(limit: Int? = nil, offset: Int = 0) -> [HistoryRecord] {
        let sql: String
        if let limit {
            sql = "SELECT * FROM recognition_history ORDER BY created_at DESC LIMIT \(limit) OFFSET \(offset);"
        } else {
            sql = "SELECT * FROM recognition_history ORDER BY created_at DESC;"
        }
        return executeQuery(sql)
    }

    /// Cursor-based pagination with optional date range and status filters.
    /// Pass `cursor` for subsequent pages, `from`/`to` as ISO8601 strings for date
    /// filtering, `status` to keep only one kind of entry (e.g. quick notes).
    ///
    /// The status filter lives in SQL rather than in the view so it survives
    /// pagination — filtering the loaded page instead would silently stop finding
    /// matches past the first fifty records.
    func fetchPage(
        limit: Int, before cursor: String? = nil, from: String? = nil, to: String? = nil,
        status: String? = nil
    ) -> [HistoryRecord] {
        var conditions: [String] = []
        var params: [String] = []
        if let cursor {
            conditions.append("created_at < ?")
            params.append(cursor)
        }
        if let from {
            conditions.append("created_at >= ?")
            params.append(from)
        }
        if let to {
            conditions.append("created_at < ?")
            params.append(to)
        }
        if let status {
            conditions.append("status = ?")
            params.append(status)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT * FROM recognition_history \(whereClause) ORDER BY created_at DESC LIMIT \(limit);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            bind(stmt, Int32(i + 1), param)
        }
        return readRows(stmt)
    }

    private func executeQuery(_ sql: String) -> [HistoryRecord] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        return readRows(stmt)
    }

    private func readRows(_ stmt: OpaquePointer?) -> [HistoryRecord] {
        let iso = ISO8601DateFormatter()
        var records: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(HistoryRecord(
                id: column(stmt, 0),
                createdAt: iso.date(from: column(stmt, 1)) ?? Date(),
                durationSeconds: sqlite3_column_double(stmt, 2),
                rawText: column(stmt, 3),
                processingMode: optionalColumn(stmt, 4),
                processedText: optionalColumn(stmt, 5),
                finalText: column(stmt, 6),
                status: column(stmt, 7),
                characterCount: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8)),
                asrProvider: optionalColumn(stmt, 9),
                asrModel: optionalColumn(stmt, 10),
                audioPath: optionalColumn(stmt, 11),
                audioBytes: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 12),
                audioDurationSeconds: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 13),
                audioStatus: optionalColumn(stmt, 14),
                retranscribedText: optionalColumn(stmt, 15),
                retranscriptionProvider: optionalColumn(stmt, 16),
                retranscriptionModel: optionalColumn(stmt, 17)
            ))
        }
        return records
    }

    /// Fetch recent records with non-empty rawText for smart correction UI.
    func recentForCorrection(limit: Int = 20) -> [(id: String, date: Date, rawText: String)] {
        let sql = """
        SELECT id, created_at, raw_text FROM recognition_history
        WHERE raw_text != '' AND status = 'completed'
        ORDER BY created_at DESC LIMIT \(limit);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        var results: [(id: String, date: Date, rawText: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                id: column(stmt, 0),
                date: iso.date(from: column(stmt, 1)) ?? Date(),
                rawText: column(stmt, 2)
            ))
        }
        return results
    }

    func count(from start: Date? = nil, to end: Date? = nil) -> Int {
        let sql: String
        if start != nil && end != nil {
            sql = "SELECT COUNT(*) FROM recognition_history WHERE created_at >= ? AND created_at < ?;"
        } else {
            sql = "SELECT COUNT(*) FROM recognition_history;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if let start, let end {
            let iso = ISO8601DateFormatter()
            bind(stmt, 1, iso.string(from: start))
            bind(stmt, 2, iso.string(from: end))
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func updateRetranscription(
        id: String,
        text: String,
        provider: String,
        model: String?
    ) {
        let sql = """
        UPDATE recognition_history SET
            raw_text = CASE WHEN final_text = '' THEN ? ELSE raw_text END,
            final_text = CASE WHEN final_text = '' THEN ? ELSE final_text END,
            status = CASE WHEN final_text = '' THEN 'retranscribed' ELSE status END,
            character_count = CASE WHEN final_text = '' THEN ? ELSE character_count END,
            retranscribed_text = ?,
            retranscription_provider = ?,
            retranscription_model = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, text)
        bind(stmt, 2, text)
        sqlite3_bind_int(stmt, 3, Int32(text.count))
        bind(stmt, 4, text)
        bind(stmt, 5, provider)
        bindOptional(stmt, 6, model)
        bind(stmt, 7, id)
        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
        }
    }

    func pruneAudio(
        now: Date = Date(),
        maximumAge: TimeInterval = 30 * 24 * 60 * 60,
        maximumCount: Int = 500,
        maximumBytes: Int64 = 1_000_000_000
    ) {
        let sql = """
        SELECT id, created_at, audio_path, COALESCE(audio_bytes, 0), raw_text, final_text, status
        FROM recognition_history
        WHERE audio_path IS NOT NULL
        ORDER BY created_at DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let iso = ISO8601DateFormatter()
        let cutoff = now.addingTimeInterval(-maximumAge)
        var retainedCount = 0
        var retainedBytes: Int64 = 0
        var expired: [(id: String, path: String, removeRow: Bool)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = column(stmt, 0)
            let createdAt = iso.date(from: column(stmt, 1)) ?? .distantPast
            let path = column(stmt, 2)
            let bytes = sqlite3_column_int64(stmt, 3)
            let rawText = column(stmt, 4)
            let finalText = column(stmt, 5)
            let status = column(stmt, 6)
            let canKeep = createdAt >= cutoff
                && retainedCount < maximumCount
                && retainedBytes + bytes <= maximumBytes
            if canKeep {
                retainedCount += 1
                retainedBytes += bytes
            } else {
                expired.append((
                    id: id,
                    path: path,
                    removeRow: rawText.isEmpty && finalText.isEmpty && status == "crash_recoverable"
                ))
            }
        }
        guard !expired.isEmpty else { return }
        var changed = false
        for item in expired {
            let updated: Bool
            if item.removeRow {
                updated = executeUpdate("DELETE FROM recognition_history WHERE id = ?;", id: item.id)
            } else {
                updated = executeUpdate(
                    "UPDATE recognition_history SET audio_path = NULL, audio_bytes = NULL, audio_duration_seconds = NULL, audio_status = 'expired' WHERE id = ?;",
                    id: item.id
                )
            }
            if updated {
                audioArchive.remove(relativePath: item.path)
                changed = true
            }
        }
        reconcileAudioArchive()
        guard changed else { return }
        postDidChangeNotification()
    }

    func audioStorageBytes() -> Int64 {
        let sql = "SELECT COALESCE(SUM(audio_bytes), 0) FROM recognition_history WHERE audio_path IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    func reconcileAudioArchive() {
        let sql = "SELECT audio_path FROM recognition_history WHERE audio_path IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        var referenced = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            referenced.insert(column(stmt, 0))
        }
        audioArchive.removeUnreferencedWAVs(referencedRelativePaths: referenced)
    }

    func delete(id: String) {
        let paths = audioPaths(for: [id])
        let sql = "DELETE FROM recognition_history WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        if sqlite3_step(stmt) == SQLITE_DONE {
            paths.forEach { audioArchive.remove(relativePath: $0) }
            reconcileAudioArchive()
            postDidChangeNotification()
        }
    }

    /// Deletes multiple rows in one transaction; posts a single change notification on success.
    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        let paths = audioPaths(for: ids)
        let chunkSize = 500
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        var ok = true
        for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[chunkStart ..< min(chunkStart + chunkSize, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM recognition_history WHERE id IN (\(placeholders));"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                ok = false
                break
            }
            defer { sqlite3_finalize(stmt) }
            for (idx, id) in chunk.enumerated() {
                bind(stmt, Int32(idx + 1), id)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                ok = false
                break
            }
        }
        if ok {
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
                paths.forEach { audioArchive.remove(relativePath: $0) }
                reconcileAudioArchive()
                postDidChangeNotification()
            } else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        } else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    func deleteAll() {
        let paths = allAudioPaths()
        if sqlite3_exec(db, "DELETE FROM recognition_history;", nil, nil, nil) == SQLITE_OK {
            paths.forEach { audioArchive.remove(relativePath: $0) }
            reconcileAudioArchive()
            postDidChangeNotification()
        }
    }


    // MARK: - Statistics

    struct Statistics: Sendable {
        let totalDuration: Double
        let totalCharacters: Int
        let recordCount: Int

        var averageSpeed: Double {
            guard totalDuration > 0 else { return 0 }
            return Double(totalCharacters) / totalDuration * 60  // 字/分钟
        }
    }

    struct UsageBreakdown: Identifiable, Sendable {
        let modelName: String
        let lastDayDuration: Double
        let last7DaysDuration: Double
        let last30DaysDuration: Double
        let allTimeDuration: Double
        let recordCount: Int

        var id: String { modelName }
    }

    /// 获取统计信息，可选日期范围过滤（ISO8601 字符串）
    func getStatistics(from: String? = nil, to: String? = nil) async -> Statistics {
        var conditions: [String] = []
        var params: [String] = []
        if let from {
            conditions.append("created_at >= ?")
            params.append(from)
        }
        if let to {
            conditions.append("created_at < ?")
            params.append(to)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN character_count IS NOT NULL THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(character_count), 0),
            COUNT(*)
        FROM recognition_history \(whereClause);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            bind(stmt, Int32(i + 1), param)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let duration = sqlite3_column_double(stmt, 0)
            let chars = Int(sqlite3_column_int(stmt, 1))
            let count = Int(sqlite3_column_int(stmt, 2))
            return Statistics(totalDuration: duration, totalCharacters: chars, recordCount: count)
        }
        return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0)
    }

    func getUsageBreakdown(now: Date = Date()) async -> [UsageBreakdown] {
        let iso = ISO8601DateFormatter()
        let lastDay = iso.string(from: now.addingTimeInterval(-24 * 60 * 60))
        let last7Days = iso.string(from: now.addingTimeInterval(-7 * 24 * 60 * 60))
        let last30Days = iso.string(from: now.addingTimeInterval(-30 * 24 * 60 * 60))
        let unknown = L("未知", "Unknown")

        let sql = """
        SELECT
            CASE
                WHEN lower(trim(COALESCE(asr_provider, ''))) = 'elevenlabs' THEN 'ElevenLabs'
                ELSE COALESCE(NULLIF(asr_model, ''), NULLIF(asr_provider, ''), ?)
            END AS model_name,
            COALESCE(SUM(CASE WHEN created_at >= ? THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN created_at >= ? THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN created_at >= ? THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(duration_seconds), 0),
            COUNT(*)
        FROM recognition_history
        GROUP BY 1
        ORDER BY CASE WHEN model_name = ? THEN 1 ELSE 0 END,
                 5 DESC,
                 model_name COLLATE NOCASE ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, unknown)
        bind(stmt, 2, lastDay)
        bind(stmt, 3, last7Days)
        bind(stmt, 4, last30Days)
        bind(stmt, 5, unknown)

        var rows: [UsageBreakdown] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(UsageBreakdown(
                modelName: column(stmt, 0),
                lastDayDuration: sqlite3_column_double(stmt, 1),
                last7DaysDuration: sqlite3_column_double(stmt, 2),
                last30DaysDuration: sqlite3_column_double(stmt, 3),
                allTimeDuration: sqlite3_column_double(stmt, 4),
                recordCount: Int(sqlite3_column_int(stmt, 5))
            ))
        }
        return rows
    }

    // MARK: - SQLite Helpers

    @discardableResult
    private func executeUpdate(_ sql: String, id: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func audioPaths(for ids: [String]) -> [String] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT audio_path FROM recognition_history WHERE id IN (\(placeholders)) AND audio_path IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (index, id) in ids.enumerated() {
            bind(stmt, Int32(index + 1), id)
        }
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            paths.append(column(stmt, 0))
        }
        return paths
    }

    private func allAudioPaths() -> [String] {
        let sql = "SELECT audio_path FROM recognition_history WHERE audio_path IS NOT NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            paths.append(column(stmt, 0))
        }
        return paths
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bind(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(stmt, index))
    }

    private func optionalColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    private func postDidChangeNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
    }
}
