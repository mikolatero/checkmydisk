import Foundation
import UserNotifications

@MainActor
final class DriveStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            settingsBox.value = settings
            SettingsStore.save(settings)
        }
    }
    @Published var devices: [SmartDeviceSummary] = []
    @Published var snapshots: [String: DriveSnapshot] = [:]
    @Published var assessments: [String: DriveAssessment] = [:]
    @Published var volumes: [String: [VolumeInfo]] = [:]
    @Published var selectedDeviceID: String?
    @Published var selectedSection: DriveSection = .dashboard
    @Published var isLoading = false
    @Published var isSelfTestPolling = false
    /// Scan/executable failures. Per-device read failures land in `deviceErrors`.
    @Published var lastError: String?
    @Published var deviceErrors: [String: String] = [:]
    @Published var satStatus = SATSupportStatus(kextInstalled: false, pluginInstalled: false, iokitCapableDevices: 0)

    private let settingsBox: SettingsBox
    private lazy var runner = SmartctlRunner { [settingsBox] in
        settingsBox.value
    }
    private let snapshotStore: SnapshotStore?
    private var previousStates: [String: DriveHealthState] = [:]
    private var activeRefresh: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var selfTestPollingTask: Task<Void, Never>?
    private var activeSelfTestKind: [String: String] = [:]

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

        async let satUpdate = SATSupportDetector.detect()
        async let volumeUpdate = VolumeInfoProvider.volumesByDisk()

        do {
            let scanned = try await runner.scan()
            devices = scanned
            let knownIDs = Set(scanned.map(\.id))
            snapshots = snapshots.filter { knownIDs.contains($0.key) }
            assessments = assessments.filter { knownIDs.contains($0.key) }
            deviceErrors = deviceErrors.filter { knownIDs.contains($0.key) }
            if selectedDeviceID.map({ !knownIDs.contains($0) }) ?? true {
                selectedDeviceID = scanned.first?.id
            }

            let runner = self.runner
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

            for (deviceID, result) in results {
                switch result {
                case let .success((snapshot, assessment)):
                    snapshots[deviceID] = snapshot
                    assessments[deviceID] = assessment
                    deviceErrors[deviceID] = nil
                    persist(snapshot: snapshot, assessment: assessment)
                    if let device = scanned.first(where: { $0.id == deviceID }) {
                        notifyIfNeeded(device: device, assessment: assessment)
                    }
                case let .failure(error):
                    deviceErrors[deviceID] = error.localizedDescription
                }
            }
        } catch {
            lastError = error.localizedDescription
        }

        satStatus = await satUpdate
        let volumesByDisk = await volumeUpdate
        var mappedVolumes: [String: [VolumeInfo]] = [:]
        for device in devices {
            let wholeDisk = VolumeInfoProvider.wholeDiskName(URL(fileURLWithPath: device.name).lastPathComponent)
            if let deviceVolumes = volumesByDisk[wholeDisk] {
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
        let deviceID = snapshot.device.id
        isSelfTestPolling = true
        do {
            try await runner.startSelfTest(device: snapshot.device, kind: kind)
            activeSelfTestKind[deviceID] = kind
            await refresh()
            let estimatedMinutes = snapshots[deviceID]?.activeSelfTest?.estimatedMinutes(forKind: kind)
                ?? (kind == "short" ? 2 : 90)
            startSelfTestPolling(for: deviceID, minimumPolls: max(3, estimatedMinutes * 60 / 10))
        } catch {
            isSelfTestPolling = false
            deviceErrors[deviceID] = error.localizedDescription
        }
    }

    func cancelSelfTest() async {
        guard let snapshot = selectedSnapshot else { return }
        let deviceID = snapshot.device.id
        do {
            try await runner.abortSelfTest(device: snapshot.device)
            selfTestPollingTask?.cancel()
            isSelfTestPolling = false
            activeSelfTestKind[deviceID] = nil
            await refresh()
        } catch {
            deviceErrors[deviceID] = error.localizedDescription
        }
    }

    func selfTestKind(for deviceID: String) -> String? {
        activeSelfTestKind[deviceID]
    }

    private func startSelfTestPolling(for deviceID: String, minimumPolls: Int) {
        selfTestPollingTask?.cancel()
        isSelfTestPolling = true
        let maxPolls = max(180, minimumPolls * 3)
        selfTestPollingTask = Task { [weak self] in
            var sawRunningStatus = false
            for pollIndex in 0..<maxPolls {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                await self.refresh()
                let stillRunning = self.snapshots[deviceID]?.activeSelfTest?.isRunning == true
                sawRunningStatus = sawRunningStatus || stillRunning
                if !stillRunning, sawRunningStatus || pollIndex >= minimumPolls {
                    break
                }
            }
            guard let self else { return }
            self.isSelfTestPolling = false
            self.activeSelfTestKind[deviceID] = nil
        }
    }

    func saveSettings() {
        SettingsStore.save(settings)
    }

    static func shouldNotify(previous: DriveHealthState?, new: DriveHealthState) -> Bool {
        guard let previous else { return false }
        return new.severity > previous.severity && new.severity > DriveHealthState.ok.severity
    }

    private func persist(snapshot: DriveSnapshot, assessment: DriveAssessment) {
        guard let snapshotStore else { return }
        Task.detached {
            try? await snapshotStore.save(snapshot: snapshot, assessment: assessment)
        }
    }

    private func notifyIfNeeded(device: SmartDeviceSummary, assessment: DriveAssessment) {
        let previous = previousStates[device.id]
        previousStates[device.id] = assessment.smartStatus
        guard settings.notificationsEnabled, Self.shouldNotify(previous: previous, new: assessment.smartStatus) else { return }

        let content = UNMutableNotificationContent()
        content.title = "CheckMyDisk: \(assessment.smartStatus.rawValue)"
        content.body = String(localized: "\(device.displayName) has \(assessment.issueCount) health issue(s).")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
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
