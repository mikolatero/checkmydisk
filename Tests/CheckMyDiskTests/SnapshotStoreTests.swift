import XCTest
@testable import CheckMyDisk

final class SnapshotStoreTests: XCTestCase {
    private func makeStore() throws -> SnapshotStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkmydisk-tests-\(UUID().uuidString).sqlite")
        return try SnapshotStore(url: url)
    }

    private func makeSnapshot(timestamp: Int, serial: String = "SER123", temperature: Int = 40) throws -> DriveSnapshot {
        let json = """
        {
          "model_name": "Test Drive",
          "serial_number": "\(serial)",
          "local_time": {"time_t": \(timestamp)},
          "smart_status": {"passed": true},
          "temperature": {"current": \(temperature)}
        }
        """
        let device = SmartDeviceSummary(name: "/dev/disk9", infoName: "/dev/disk9", type: "nvme", protocolName: "NVMe")
        return try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
    }

    func testSaveAndReadBackHistoryInChronologicalOrder() async throws {
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        let older = try makeSnapshot(timestamp: now - 3600, temperature: 42)
        let newer = try makeSnapshot(timestamp: now, temperature: 45)
        let assessment = HealthEvaluator.evaluate(older)

        try await store.save(snapshot: newer, assessment: HealthEvaluator.evaluate(newer))
        try await store.save(snapshot: older, assessment: assessment)

        let points = try await store.history(deviceIDs: ["SER123"])
        XCTAssertEqual(points.count, 2)
        XCTAssertLessThan(points[0].date, points[1].date)
        XCTAssertEqual(points[0].temperature, 42)
        XCTAssertEqual(points[1].temperature, 45)
    }

    func testHistoryUsesSerialNumberAsPersistentID() async throws {
        let snapshot = try makeSnapshot(timestamp: Int(Date().timeIntervalSince1970))
        XCTAssertEqual(snapshot.persistentID, "SER123")

        let store = try makeStore()
        try await store.save(snapshot: snapshot, assessment: HealthEvaluator.evaluate(snapshot))
        // Consultar con varios ids candidatos (serial + id legacy) encuentra la fila.
        let points = try await store.history(deviceIDs: ["/dev/disk9", "SER123"])
        XCTAssertEqual(points.count, 1)
    }

    func testSinceFilterExcludesOldRows() async throws {
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        try await store.save(snapshot: makeSnapshot(timestamp: now - 7200), assessment: HealthEvaluator.evaluate(try makeSnapshot(timestamp: now - 7200)))
        try await store.save(snapshot: makeSnapshot(timestamp: now), assessment: HealthEvaluator.evaluate(try makeSnapshot(timestamp: now)))

        let recent = try await store.history(deviceIDs: ["SER123"], since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(recent.count, 1)
    }

    func testPruneRemovesOldRows() async throws {
        let store = try makeStore()
        let now = Int(Date().timeIntervalSince1970)
        try await store.save(snapshot: makeSnapshot(timestamp: now - 10 * 86_400), assessment: HealthEvaluator.evaluate(try makeSnapshot(timestamp: now)))
        try await store.save(snapshot: makeSnapshot(timestamp: now), assessment: HealthEvaluator.evaluate(try makeSnapshot(timestamp: now)))

        try await store.pruneHistory(olderThanDays: 5)
        let points = try await store.history(deviceIDs: ["SER123"])
        XCTAssertEqual(points.count, 1)
    }

    func testDownsampleReducesPointCountAndKeepsWorstState() {
        let base = Date()
        var points: [HistoryPoint] = []
        for index in 0..<1000 {
            points.append(HistoryPoint(
                date: base.addingTimeInterval(Double(index) * 60),
                state: index == 500 ? .failed : .ok,
                temperature: 40,
                health: 100,
                performance: 100,
                lifetime: 90
            ))
        }
        let sampled = SnapshotStore.downsample(points, maxCount: 100)
        XCTAssertLessThanOrEqual(sampled.count, 100)
        XCTAssertTrue(sampled.contains { $0.state == .failed }, "el peor estado del bucket debe conservarse")
        XCTAssertEqual(sampled.first?.temperature, 40)
    }

    func testDownsampleLeavesShortSeriesUntouched() {
        let points = [
            HistoryPoint(date: Date(), state: .ok, temperature: 40, health: 100, performance: 100, lifetime: nil)
        ]
        XCTAssertEqual(SnapshotStore.downsample(points, maxCount: 600), points)
    }
}
