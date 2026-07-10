import Foundation
import SQLite3

struct HistoryPoint: Sendable, Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let state: DriveHealthState
    let temperature: Int?
    let health: Int
    let performance: Int
    let lifetime: Int?
}

actor SnapshotStore {
    // Only ever touched from actor-isolated methods; the annotation exists solely
    // so deinit can close the handle.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let encoder = JSONEncoder.pretty
    private let decoder: JSONDecoder

    init(url: URL? = nil) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let databaseURL = try url ?? Self.defaultURL()
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        if sqlite3_open(databaseURL.path, &handle) != SQLITE_OK {
            let message = Self.errorMessage(handle)
            sqlite3_close(handle)
            throw DatabaseError.openFailed(message)
        }
        try Self.execute("""
        create table if not exists snapshots (
            id integer primary key autoincrement,
            device_id text not null,
            checked_at real not null,
            state text not null,
            snapshot_json blob not null,
            assessment_json blob not null
        );
        """, on: handle)
        try Self.execute("create index if not exists idx_snapshots_device_time on snapshots(device_id, checked_at desc);", on: handle)
        db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    func save(snapshot: DriveSnapshot, assessment: DriveAssessment) throws {
        let snapshotData = try encoder.encode(snapshot)
        let assessmentData = try encoder.encode(assessment)
        var statement: OpaquePointer?
        let sql = "insert into snapshots(device_id, checked_at, state, snapshot_json, assessment_json) values (?, ?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(message)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, snapshot.persistentID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, snapshot.checkedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, assessment.smartStatus.rawValue, -1, SQLITE_TRANSIENT)
        _ = snapshotData.withUnsafeBytes {
            sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        _ = assessmentData.withUnsafeBytes {
            sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.insertFailed(message)
        }
    }

    /// Chronological history for a drive. `deviceIDs` accepts several candidate
    /// identities (serial number plus legacy scan ids) so rows written by older
    /// versions are not orphaned.
    func history(deviceIDs: [String], since: Date? = nil) throws -> [HistoryPoint] {
        guard !deviceIDs.isEmpty else { return [] }
        let placeholders = deviceIDs.map { _ in "?" }.joined(separator: ", ")
        var sql = "select checked_at, state, snapshot_json, assessment_json from snapshots where device_id in (\(placeholders))"
        if since != nil {
            sql += " and checked_at >= ?"
        }
        sql += " order by checked_at asc;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(message)
        }
        defer { sqlite3_finalize(statement) }
        for (index, deviceID) in deviceIDs.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), deviceID, -1, SQLITE_TRANSIENT)
        }
        if let since {
            sqlite3_bind_double(statement, Int32(deviceIDs.count + 1), since.timeIntervalSince1970)
        }

        var points: [HistoryPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let checkedAt = sqlite3_column_double(statement, 0)
            let stateText = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard let assessmentData = columnData(statement, index: 3),
                  let assessment = try? decoder.decode(PartialAssessment.self, from: assessmentData) else {
                continue
            }
            let temperature = columnData(statement, index: 2)
                .flatMap { try? decoder.decode(PartialSnapshot.self, from: $0) }?
                .temperature
            points.append(HistoryPoint(
                date: Date(timeIntervalSince1970: checkedAt),
                state: DriveHealthState(rawValue: stateText) ?? assessment.smartStatus,
                temperature: temperature,
                health: assessment.overallHealth,
                performance: assessment.overallPerformance,
                lifetime: assessment.ssdLifetimeLeft
            ))
        }
        return points
    }

    func pruneHistory(olderThanDays days: Int) throws {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "delete from snapshots where checked_at < ?;", -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(message)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(message)
        }
    }

    /// Reduces a long series to at most `maxCount` points by averaging buckets,
    /// keeping the worst state seen inside each bucket.
    static func downsample(_ points: [HistoryPoint], maxCount: Int = 600) -> [HistoryPoint] {
        guard points.count > maxCount, maxCount > 0 else { return points }
        let bucketSize = Int((Double(points.count) / Double(maxCount)).rounded(.up))
        var result: [HistoryPoint] = []
        result.reserveCapacity(points.count / bucketSize + 1)
        var start = 0
        while start < points.count {
            let bucket = points[start..<min(start + bucketSize, points.count)]
            let temperatures = bucket.compactMap(\.temperature)
            let lifetimes = bucket.compactMap(\.lifetime)
            result.append(HistoryPoint(
                date: bucket[bucket.startIndex + bucket.count / 2].date,
                state: bucket.map(\.state).max { $0.severity < $1.severity } ?? .unknown,
                temperature: temperatures.isEmpty ? nil : temperatures.reduce(0, +) / temperatures.count,
                health: bucket.map(\.health).reduce(0, +) / bucket.count,
                performance: bucket.map(\.performance).reduce(0, +) / bucket.count,
                lifetime: lifetimes.isEmpty ? nil : lifetimes.reduce(0, +) / lifetimes.count
            ))
            start += bucketSize
        }
        return result
    }

    private func columnData(_ statement: OpaquePointer?, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private static func execute(_ sql: String, on db: OpaquePointer?) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.executeFailed(errorMessage(db))
        }
    }

    private static func errorMessage(_ db: OpaquePointer?) -> String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error"
    }

    private var message: String {
        Self.errorMessage(db)
    }

    private static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("CheckMyDisk/checkmydisk.sqlite")
    }
}

private struct PartialSnapshot: Decodable {
    let temperature: Int?
}

private struct PartialAssessment: Decodable {
    let smartStatus: DriveHealthState
    let overallHealth: Int
    let overallPerformance: Int
    let ssdLifetimeLeft: Int?
}

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case insertFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "Could not open SQLite database: \(message)"
        case let .prepareFailed(message): "Could not prepare SQLite statement: \(message)"
        case let .executeFailed(message): "Could not execute SQLite statement: \(message)"
        case let .insertFailed(message): "Could not insert SQLite row: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
