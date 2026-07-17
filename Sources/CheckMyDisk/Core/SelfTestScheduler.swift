import Foundation

/// Persists the last time a scheduled self-test of each kind was started per drive.
struct SelfTestScheduleStore {
    private let key = "CheckMyDisk.SelfTestSchedule"

    func lastRun(_ deviceID: String, _ kind: String) -> Date? {
        entries()["\(deviceID)|\(kind)"].map(Date.init(timeIntervalSince1970:))
    }

    func record(_ deviceID: String, _ kind: String, _ date: Date) {
        var current = entries()
        current["\(deviceID)|\(kind)"] = date.timeIntervalSince1970
        UserDefaults.standard.set(current, forKey: key)
    }

    private func entries() -> [String: Double] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
}

/// Decides and launches recurring background self-tests (short weekly / full
/// monthly by default). Fire-and-forget: the drive runs the test itself and the
/// result shows up in the self-test log on the next refresh.
@MainActor
final class SelfTestScheduler {
    private let store = SelfTestScheduleStore()

    func runDueTests(
        devices: [SmartDeviceSummary],
        settings: AppSettings,
        now: Date,
        isRunning: (String) -> Bool,
        start: (SmartDeviceSummary, String) async -> Void
    ) async {
        guard settings.scheduledSelfTestsEnabled else { return }
        for device in devices where !isRunning(device.id) {
            let id = device.id
            // Seed baselines so enabling the schedule never triggers a test
            // immediately; the first run happens after one full interval.
            if settings.longTestIntervalDays > 0, store.lastRun(id, "long") == nil {
                store.record(id, "long", now)
            }
            if settings.shortTestIntervalDays > 0, store.lastRun(id, "short") == nil {
                store.record(id, "short", now)
            }
            guard let kind = Self.kindDue(
                settings: settings,
                lastShort: store.lastRun(id, "short"),
                lastLong: store.lastRun(id, "long"),
                now: now
            ) else {
                continue
            }
            store.record(id, kind, now)
            await start(device, kind)
        }
    }

    /// Which kind ("long"/"short") is due now, preferring the full test when both
    /// are due. Pure and side-effect free, for testing.
    nonisolated static func kindDue(settings: AppSettings, lastShort: Date?, lastLong: Date?, now: Date) -> String? {
        guard settings.scheduledSelfTestsEnabled else { return nil }
        if isDue(last: lastLong, intervalDays: settings.longTestIntervalDays, now: now) {
            return "long"
        }
        if isDue(last: lastShort, intervalDays: settings.shortTestIntervalDays, now: now) {
            return "short"
        }
        return nil
    }

    /// A `nil` `last` means "no baseline yet" (not due); the caller seeds it.
    nonisolated static func isDue(last: Date?, intervalDays: Int, now: Date) -> Bool {
        guard intervalDays > 0, let last else { return false }
        return now.timeIntervalSince(last) >= Double(intervalDays) * 86_400
    }
}
