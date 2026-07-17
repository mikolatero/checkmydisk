import Foundation

/// Result of one full diagnostic sweep. `DriveStore` applies it to its observable
/// state; the service itself holds no UI state.
struct ScanData {
    let devices: [SmartDeviceSummary]
    let results: [(String, Result<(DriveSnapshot, DriveAssessment), Error>)]
}

struct DiagnosticsOutcome {
    /// `.failure` when the device scan itself failed; per-device read failures are
    /// carried inside `ScanData.results` instead.
    let scan: Result<ScanData, Error>
    let satStatus: SATSupportStatus
    let volumesByDisk: [String: [VolumeInfo]]
}

/// Runs the full diagnostic sweep: enumerate devices, read and evaluate each drive
/// in parallel, and gather SAT-driver status and mounted volumes. Kept `@MainActor`
/// (matching the previous in-store implementation) so the parallel child tasks and
/// the returned value have exactly the same isolation as before.
enum DiagnosticsService {
    @MainActor
    static func runFullScan(using runner: SmartctlRunner) async -> DiagnosticsOutcome {
        async let satUpdate = SATSupportDetector.detect()
        async let volumeUpdate = VolumeInfoProvider.volumesByDisk()

        let scan: Result<ScanData, Error>
        do {
            let scanned = try await runner.scan()
            let results = await withTaskGroup(
                of: (String, Result<(DriveSnapshot, DriveAssessment), Error>).self,
                returning: [(String, Result<(DriveSnapshot, DriveAssessment), Error>)].self
            ) { group in
                for device in scanned {
                    group.addTask {
                        do {
                            let snapshot = try await runner.readAll(device: device)
                            return (device.id, .success((snapshot, HealthEvaluator.evaluate(snapshot))))
                        } catch {
                            return (device.id, .failure(error))
                        }
                    }
                }
                var collected: [(String, Result<(DriveSnapshot, DriveAssessment), Error>)] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }
            scan = .success(ScanData(devices: scanned, results: results))
        } catch {
            scan = .failure(error)
        }

        return DiagnosticsOutcome(scan: scan, satStatus: await satUpdate, volumesByDisk: await volumeUpdate)
    }
}
