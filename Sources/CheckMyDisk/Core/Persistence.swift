import Foundation
import GRDB

struct HistoryPoint: Sendable, Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let state: DriveHealthState
    let temperature: Int?
    let health: Int
    let performance: Int
    let lifetime: Int?
}

/// Stores a lightweight time series of drive health in SQLite via GRDB. History
/// metrics live in dedicated columns (cheap to store and query); the full JSON of
/// only the most recent snapshot per drive is retained in `latest_snapshots`.
/// Uses a `DatabasePool` (WAL) so reads never block the writer.
final class SnapshotStore: Sendable {
    private let dbPool: DatabasePool

    init(url: URL? = nil) throws {
        let databaseURL = try url ?? Self.defaultURL()
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        dbPool = try DatabasePool(path: databaseURL.path)
        try Self.migrator.migrate(dbPool)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v2_columnar_schema") { db in
            // A pre-GRDB build stored one JSON blob per check in a `snapshots` table.
            // If that legacy table is present (no GRDB migration tracking yet), set it
            // aside, build the new columnar schema, then import the history from it.
            let legacyExists = try db.tableExists("snapshots")
                && (try db.columns(in: "snapshots").contains { $0.name == "snapshot_json" })
            if legacyExists {
                try db.execute(sql: "ALTER TABLE snapshots RENAME TO snapshots_legacy_v1")
            }

            try db.create(table: "snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("device_id", .text).notNull()
                t.column("checked_at", .double).notNull()
                t.column("state", .text).notNull()
                t.column("temperature", .integer)
                t.column("health", .integer).notNull()
                t.column("performance", .integer).notNull()
                t.column("lifetime", .integer)
            }
            try db.create(index: "idx_snapshots_device_time", on: "snapshots", columns: ["device_id", "checked_at"])

            try db.create(table: "latest_snapshots") { t in
                t.primaryKey("device_id", .text)
                t.column("checked_at", .double).notNull()
                t.column("snapshot_json", .blob).notNull()
                t.column("assessment_json", .blob).notNull()
            }

            if legacyExists {
                try importLegacyHistory(db)
                try db.execute(sql: "DROP TABLE snapshots_legacy_v1")
            }
        }
        return migrator
    }

    /// Best-effort import of the old JSON-blob history into the columnar table.
    /// Rows that fail to decode are skipped rather than aborting the migration.
    private static func importLegacyHistory(_ db: Database) throws {
        let decoder = JSONDecoder()
        let rows = try Row.fetchAll(db, sql: "SELECT device_id, checked_at, state, snapshot_json, assessment_json FROM snapshots_legacy_v1")
        for row in rows {
            let assessmentData: Data? = row["assessment_json"]
            guard let assessmentData,
                  let assessment = try? decoder.decode(PartialAssessment.self, from: assessmentData) else { continue }
            let snapshotData: Data? = row["snapshot_json"]
            let temperature = snapshotData.flatMap { try? decoder.decode(PartialSnapshot.self, from: $0) }?.temperature
            let deviceID: String = row["device_id"]
            let checkedAt: Double = row["checked_at"]
            let state: String = row["state"]
            try db.execute(sql: """
                INSERT INTO snapshots (device_id, checked_at, state, temperature, health, performance, lifetime)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [deviceID, checkedAt, state, temperature, assessment.overallHealth, assessment.overallPerformance, assessment.ssdLifetimeLeft])
        }
    }

    func save(snapshot: DriveSnapshot, assessment: DriveAssessment) async throws {
        let snapshotData = try JSONEncoder.pretty.encode(snapshot)
        let assessmentData = try JSONEncoder.pretty.encode(assessment)
        let deviceID = snapshot.persistentID
        let checkedAt = snapshot.checkedAt.timeIntervalSince1970
        let state = assessment.smartStatus.rawValue
        let temperature = snapshot.temperature
        let health = assessment.overallHealth
        let performance = assessment.overallPerformance
        let lifetime = assessment.ssdLifetimeLeft
        try await dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO snapshots (device_id, checked_at, state, temperature, health, performance, lifetime)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [deviceID, checkedAt, state, temperature, health, performance, lifetime])
            try db.execute(sql: """
                INSERT INTO latest_snapshots (device_id, checked_at, snapshot_json, assessment_json)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    checked_at = excluded.checked_at,
                    snapshot_json = excluded.snapshot_json,
                    assessment_json = excluded.assessment_json
                """, arguments: [deviceID, checkedAt, snapshotData, assessmentData])
        }
    }

    /// Chronological history for a drive. `deviceIDs` accepts several candidate
    /// identities (serial number plus legacy scan ids) so rows written by older
    /// versions are not orphaned.
    func history(deviceIDs: [String], since: Date? = nil) async throws -> [HistoryPoint] {
        guard !deviceIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: deviceIDs.count).joined(separator: ", ")
        var sql = "SELECT checked_at, state, temperature, health, performance, lifetime FROM snapshots WHERE device_id IN (\(placeholders))"
        if since != nil {
            sql += " AND checked_at >= ?"
        }
        sql += " ORDER BY checked_at ASC"
        let query = sql
        return try await dbPool.read { db in
            var arguments: [DatabaseValueConvertible] = deviceIDs
            if let since {
                arguments.append(since.timeIntervalSince1970)
            }
            return try Row.fetchAll(db, sql: query, arguments: StatementArguments(arguments)).map { row in
                HistoryPoint(
                    date: Date(timeIntervalSince1970: row["checked_at"]),
                    state: DriveHealthState(rawValue: row["state"]) ?? .unknown,
                    temperature: row["temperature"],
                    health: row["health"],
                    performance: row["performance"],
                    lifetime: row["lifetime"]
                )
            }
        }
    }

    /// The full most-recent snapshot stored for a drive, used as the baseline for
    /// "changes since last check" across app launches. Nil until the first save.
    func latestSnapshot(deviceID: String) async throws -> DriveSnapshot? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT snapshot_json FROM latest_snapshots WHERE device_id = ?", arguments: [deviceID]),
                  let data = row["snapshot_json"] as Data? else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(DriveSnapshot.self, from: data)
        }
    }

    func pruneHistory(olderThanDays days: Int) async throws {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM snapshots WHERE checked_at < ?", arguments: [cutoff])
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

    private static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("CheckMyDisk/checkmydisk.sqlite")
    }
}

#if DEBUG
extension SnapshotStore {
    /// Test seam (debug-only): writes rows in the pre-GRDB legacy schema — one JSON
    /// blob per check — so the migration path can be exercised without the test
    /// target depending on GRDB directly.
    static func makeLegacyDatabaseForTesting(
        at url: URL,
        rows: [(deviceID: String, checkedAt: Double, state: String, snapshotJSON: Data, assessmentJSON: Data)]
    ) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE snapshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id TEXT NOT NULL,
                    checked_at REAL NOT NULL,
                    state TEXT NOT NULL,
                    snapshot_json BLOB NOT NULL,
                    assessment_json BLOB NOT NULL
                );
                """)
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO snapshots (device_id, checked_at, state, snapshot_json, assessment_json)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [row.deviceID, row.checkedAt, row.state, row.snapshotJSON, row.assessmentJSON])
            }
        }
    }
}
#endif

private struct PartialSnapshot: Decodable {
    let temperature: Int?
}

private struct PartialAssessment: Decodable {
    let overallHealth: Int
    let overallPerformance: Int
    let ssdLifetimeLeft: Int?
}
