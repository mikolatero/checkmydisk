import Foundation

enum DriveHealthState: String, Codable, CaseIterable {
    case ok = "OK"
    case warning = "WARNING"
    case failing = "FAILING"
    case failed = "FAILED"
    case unknown = "UNKNOWN"

    var severity: Int {
        switch self {
        case .ok: 0
        case .warning: 1
        case .failing: 2
        case .failed: 3
        case .unknown: -1
        }
    }
}

enum DriveSection: String, CaseIterable, Codable, Identifiable {
    case dashboard = "Dashboard"
    case indicators = "Health Indicators"
    case errors = "Errors Log"
    case statistics = "Device Statistics"
    case selfTests = "Self-tests"
    case history = "History"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .dashboard: String(localized: "Dashboard")
        case .indicators: String(localized: "Health Indicators")
        case .errors: String(localized: "Errors Log")
        case .statistics: String(localized: "Device Statistics")
        case .selfTests: String(localized: "Self-tests")
        case .history: String(localized: "History")
        }
    }
}

struct SmartDeviceSummary: Identifiable, Codable, Hashable {
    var id: String { infoName.isEmpty ? name : infoName }
    let name: String
    let infoName: String
    let type: String
    let protocolName: String

    var displayName: String {
        infoName.isEmpty ? name : infoName
    }
}

struct SmartMessage: Codable, Hashable {
    let severity: String
    let text: String
}

struct SmartAttribute: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let type: String
    let rawValue: String
    let prettyValue: String?
    let current: Int?
    let worst: Int?
    let threshold: Int?
    let whenFailed: String?
    let percent: Int?
    var status: DriveHealthState
    // Attributes synthesized from the NVMe health log, as opposed to real ATA
    // attributes. The evaluator must not count them again as problems.
    var isSynthetic: Bool?
}

struct SmartErrorEntry: Identifiable, Codable, Hashable {
    let id: Int
    let lifetimeHours: Int?
    let errors: String
    let priorCommand: String
    let lba: String?
}

struct SmartSelfTestEntry: Identifiable, Codable, Hashable {
    let id: Int
    let lifetimeHours: Int?
    let testType: String
    let status: String
    let remainingPercent: Int?
    let lbaOfFirstError: String?
}

struct ActiveSelfTestStatus: Codable, Hashable {
    let title: String
    let progressPercent: Int?
    let remainingPercent: Int?
    var estimatedMinutesShort: Int?
    var estimatedMinutesExtended: Int?

    var isRunning: Bool {
        let lowercased = title.lowercased()
        return lowercased.contains("progress") ||
            lowercased.contains("remaining") ||
            lowercased.contains("routine in progress") ||
            remainingPercent != nil
    }

    /// ETA for the test that is actually running ("short"/"long"), when known.
    func estimatedMinutes(forKind kind: String?) -> Int? {
        switch kind {
        case "long", "extended": return estimatedMinutesExtended ?? estimatedMinutesShort
        case "short", "conveyance": return estimatedMinutesShort
        default: return estimatedMinutesExtended ?? estimatedMinutesShort
        }
    }
}

struct DeviceStatistic: Identifiable, Codable, Hashable {
    var id: String { "\(section).\(name)" }
    let section: String
    let name: String
    let value: String
}

struct NVMeHealthLog: Codable, Hashable {
    let criticalWarning: Int?
    let temperature: Int?
    let availableSpare: Int?
    let availableSpareThreshold: Int?
    let percentageUsed: Int?
    let dataUnitsRead: UInt64?
    let dataUnitsWritten: UInt64?
    let hostReads: UInt64?
    let hostWrites: UInt64?
    let controllerBusyTime: UInt64?
    let powerCycles: UInt64?
    let powerOnHours: UInt64?
    let unsafeShutdowns: UInt64?
    let mediaErrors: UInt64?
    let errorLogEntries: UInt64?
    var temperatureSensors: [Int]?
    var warningTempTime: Int?
    var criticalCompTime: Int?
}

/// Temperature history recorded by the drive firmware itself (`ata_sct_temperature_history`).
struct SCTTemperatureHistory: Codable, Hashable {
    let intervalMinutes: Int
    let temperatures: [Int?]
}

struct DriveSnapshot: Identifiable, Codable, Hashable {
    var id: String { device.id }
    let device: SmartDeviceSummary
    let checkedAt: Date
    let modelName: String
    var serialNumber: String?
    let firmwareVersion: String?
    let userCapacityBytes: UInt64?
    let sectorSize: String?
    let smartStatusPassed: Bool?
    let temperature: Int?
    let powerOnHours: UInt64?
    let powerCycles: UInt64?
    let nvme: NVMeHealthLog?
    let attributes: [SmartAttribute]
    let errorLog: [SmartErrorEntry]
    let selfTests: [SmartSelfTestEntry]
    let activeSelfTest: ActiveSelfTestStatus?
    let deviceStatistics: [DeviceStatistic]
    let messages: [SmartMessage]
    var exitStatus: SmartctlExitStatus?
    var rotationRate: Int?
    var formFactor: String?
    var interfaceSpeed: String?
    var ataVersion: String?
    var sataVersion: String?
    var nvmeVersion: String?
    var wwn: String?
    var trimSupported: Bool?
    var temperatureLifetimeMin: Int?
    var temperatureLifetimeMax: Int?
    var sctTemperatureHistory: SCTTemperatureHistory?

    /// Stable identity for on-disk history: /dev/diskN numbering can change
    /// between boots, the serial number cannot.
    var persistentID: String {
        if let serialNumber, !serialNumber.isEmpty { return serialNumber }
        return device.id
    }

    /// True for spinning drives; nil when the drive did not report a rotation rate.
    var isRotational: Bool? {
        rotationRate.map { $0 > 0 }
    }
}

struct HealthProblem: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let state: DriveHealthState
    let detail: String

    init(id: UUID = UUID(), title: String, state: DriveHealthState, detail: String) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
    }
}

struct DriveAssessment: Codable, Hashable {
    let smartStatus: DriveHealthState
    let overallHealth: Int
    let overallPerformance: Int
    let ssdLifetimeLeft: Int?
    let problems: [HealthProblem]

    var issueCount: Int {
        problems.filter { $0.state != .ok }.count
    }
}

struct SATSupportStatus: Codable, Hashable {
    let kextInstalled: Bool
    let pluginInstalled: Bool
    let iokitCapableDevices: Int

    var isInstalled: Bool { kextInstalled && pluginInstalled }
}

struct AppSettings: Codable, Equatable {
    enum SmartctlMode: String, Codable, CaseIterable, Identifiable {
        case bundledFirst = "Bundled first"
        case homebrewFirst = "Homebrew first"
        case customPath = "Custom path"

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .bundledFirst: String(localized: "Bundled first")
            case .homebrewFirst: String(localized: "Homebrew first")
            case .customPath: String(localized: "Custom path")
            }
        }
    }

    var smartctlMode: SmartctlMode = .bundledFirst
    var customSmartctlPath: String = ""
    var refreshIntervalSeconds: Double = 300
    var notificationsEnabled: Bool = true
    var anonymizeReports: Bool = true
    var commandTimeoutSeconds: Double = 30
    var historyRetentionDays: Int = 90
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case smartctlMode, customSmartctlPath, refreshIntervalSeconds, notificationsEnabled,
             anonymizeReports, commandTimeoutSeconds, historyRetentionDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        smartctlMode = try container.decodeIfPresent(SmartctlMode.self, forKey: .smartctlMode) ?? .bundledFirst
        customSmartctlPath = try container.decodeIfPresent(String.self, forKey: .customSmartctlPath) ?? ""
        refreshIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? 300
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        anonymizeReports = try container.decodeIfPresent(Bool.self, forKey: .anonymizeReports) ?? true
        commandTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .commandTimeoutSeconds) ?? 30
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 90
    }
}
