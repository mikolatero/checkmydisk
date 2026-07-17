import Foundation
import Observation

@MainActor
@Observable
final class DriveStore {
    var settings: AppSettings {
        didSet {
            settingsBox.value = settings
            SettingsStore.save(settings)
        }
    }
    var devices: [SmartDeviceSummary] = []
    var snapshots: [String: DriveSnapshot] = [:]
    var assessments: [String: DriveAssessment] = [:]
    var volumes: [String: [VolumeInfo]] = [:]
    var selectedDeviceID: String?
    var selectedSection: DriveSection = .dashboard
    var isLoading = false
    var isSelfTestPolling = false
    /// Scan/executable failures. Per-device read failures land in `deviceErrors`.
    var lastError: String?
    var deviceErrors: [String: String] = [:]
    var satStatus = SATSupportStatus(kextInstalled: false, pluginInstalled: false, iokitCapableDevices: 0)

    @ObservationIgnored private let settingsBox: SettingsBox
    @ObservationIgnored private lazy var runner = SmartctlRunner { [settingsBox] in
        settingsBox.value
    }
    @ObservationIgnored private let snapshotStore: SnapshotStore?
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private lazy var selfTests = SelfTestCoordinator(
        runner: runner,
        refreshAction: { [weak self] in await self?.refresh() },
        snapshotProvider: { [weak self] deviceID in self?.snapshots[deviceID] },
        setPolling: { [weak self] value in self?.isSelfTestPolling = value },
        reportError: { [weak self] deviceID, message in self?.deviceErrors[deviceID] = message }
    )
    @ObservationIgnored private var activeRefresh: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    init(snapshotStore: SnapshotStore? = try? SnapshotStore()) {
        let loaded = SettingsStore.load()
        settings = loaded
        settingsBox = SettingsBox(loaded)
        self.snapshotStore = snapshotStore
    }

    var selectedSnapshot: DriveSnapshot? {
        selectedDeviceID.flatMap { snapshots[$0] }
    }

    var selectedAssessment: DriveAssessment? {
        selectedDeviceID.flatMap { assessments[$0] }
    }

    var selectedVolumes: [VolumeInfo] {
        selectedDeviceID.flatMap { volumes[$0] } ?? []
    }

    var smartctlDescription: String {
        if let executable = runner.resolvedExecutable() {
            return "\(executable.source): \(executable.url.path)"
        }
        return String(localized: "Not found")
    }

    /// Kicks off the initial refresh, periodic monitoring and history pruning.
    /// Idempotent, so additional windows do not spawn additional loops.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        if let snapshotStore {
            let retentionDays = settings.historyRetentionDays
            Task.detached {
                try? await snapshotStore.pruneHistory(olderThanDays: retentionDays)
            }
        }
        monitorTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = max(60, self.settings.refreshIntervalSeconds)
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled {
                    await self.refresh()
                }
            }
        }
    }

    func refreshNow() {
        Task { await refresh() }
    }

    /// Coalesces concurrent callers (manual button, periodic loop, self-test
    /// polling) into a single in-flight refresh.
    func refresh() async {
        if let activeRefresh {
            await activeRefresh.value
            return
        }
        let task = Task { await performRefresh() }
        activeRefresh = task
        await task.value
        activeRefresh = nil
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        let outcome = await DiagnosticsService.runFullScan(using: runner)

        switch outcome.scan {
        case let .success(scanData):
            let scanned = scanData.devices
            devices = scanned
            let knownIDs = Set(scanned.map(\.id))
            snapshots = snapshots.filter { knownIDs.contains($0.key) }
            assessments = assessments.filter { knownIDs.contains($0.key) }
            deviceErrors = deviceErrors.filter { knownIDs.contains($0.key) }
            if selectedDeviceID.map({ !knownIDs.contains($0) }) ?? true {
                selectedDeviceID = scanned.first?.id
            }

            for (deviceID, result) in scanData.results {
                switch result {
                case let .success((snapshot, assessment)):
                    snapshots[deviceID] = snapshot
                    assessments[deviceID] = assessment
                    deviceErrors[deviceID] = nil
                    persist(snapshot: snapshot, assessment: assessment)
                    if let device = scanned.first(where: { $0.id == deviceID }) {
                        notifications.notifyIfNeeded(device: device, assessment: assessment, notificationsEnabled: settings.notificationsEnabled)
                    }
                case let .failure(error):
                    deviceErrors[deviceID] = error.localizedDescription
                }
            }
        case let .failure(error):
            lastError = error.localizedDescription
        }

        satStatus = outcome.satStatus
        var mappedVolumes: [String: [VolumeInfo]] = [:]
        for device in devices {
            let wholeDisk = VolumeInfoProvider.wholeDiskName(URL(fileURLWithPath: device.name).lastPathComponent)
            if let deviceVolumes = outcome.volumesByDisk[wholeDisk] {
                mappedVolumes[device.id] = deviceVolumes
            }
        }
        volumes = mappedVolumes
    }

    func history(for deviceID: String, since: Date?) async -> [HistoryPoint] {
        guard let snapshotStore else { return [] }
        var candidateIDs = [deviceID]
        if let snapshot = snapshots[deviceID], !candidateIDs.contains(snapshot.persistentID) {
            candidateIDs.append(snapshot.persistentID)
        }
        let points = (try? await snapshotStore.history(deviceIDs: candidateIDs, since: since)) ?? []
        return SnapshotStore.downsample(points)
    }

    func startSelfTest(kind: String) async {
        guard let snapshot = selectedSnapshot else { return }
        await selfTests.start(kind: kind, device: snapshot.device)
    }

    func cancelSelfTest() async {
        guard let snapshot = selectedSnapshot else { return }
        await selfTests.cancel(device: snapshot.device)
    }

    func selfTestKind(for deviceID: String) -> String? {
        selfTests.kind(for: deviceID)
    }

    func saveSettings() {
        SettingsStore.save(settings)
    }

    private func persist(snapshot: DriveSnapshot, assessment: DriveAssessment) {
        guard let snapshotStore else { return }
        Task.detached {
            try? await snapshotStore.save(snapshot: snapshot, assessment: assessment)
        }
    }
}

/// Thread-safe snapshot of the latest settings so the (non-isolated) runner
/// always sees exactly what the UI is editing.
private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AppSettings

    init(_ value: AppSettings) {
        storage = value
    }

    var value: AppSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

enum SettingsStore {
    private static let key = "CheckMyDisk.Settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
