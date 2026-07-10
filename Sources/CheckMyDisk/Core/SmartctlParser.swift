import Foundation

enum SmartctlParserError: Error, LocalizedError {
    case invalidJSON

    var errorDescription: String? {
        "smartctl returned JSON that CheckMyDisk could not parse."
    }
}

enum SmartctlParser {
    typealias JSON = [String: Any]

    static func parseScan(_ data: Data) throws -> [SmartDeviceSummary] {
        let root = try object(from: data)
        let devices = root["devices"] as? [[String: Any]] ?? []
        return devices.map {
            SmartDeviceSummary(
                name: string($0["name"]),
                infoName: string($0["info_name"]),
                type: string($0["type"]),
                protocolName: string($0["protocol"])
            )
        }
    }

    static func parseSnapshot(_ data: Data, fallbackDevice: SmartDeviceSummary, exitStatus: SmartctlExitStatus? = nil) throws -> DriveSnapshot {
        let root = try object(from: data)
        let deviceRoot = root["device"] as? JSON
        let device = SmartDeviceSummary(
            name: string(deviceRoot?["name"], fallback: fallbackDevice.name),
            infoName: string(deviceRoot?["info_name"], fallback: fallbackDevice.infoName),
            type: string(deviceRoot?["type"], fallback: fallbackDevice.type),
            protocolName: string(deviceRoot?["protocol"], fallback: fallbackDevice.protocolName)
        )
        let smartctlRoot = root["smartctl"] as? JSON
        let messages = (smartctlRoot?["messages"] as? [[String: Any]] ?? []).map {
            SmartMessage(severity: string($0["severity"]), text: string($0["string"]))
        }

        let nvme = parseNVMe(root["nvme_smart_health_information_log"] as? JSON)
        var attributes = parseATAAttributes(root["ata_smart_attributes"] as? JSON)
        if attributes.isEmpty, let nvme {
            attributes = nvmeAttributes(from: nvme)
        }

        var errorLog = parseErrors(root["ata_smart_error_log"] as? JSON)
        errorLog.append(contentsOf: parseNVMeErrorLog(root["nvme_error_information_log"] as? JSON))

        var statistics = parseDeviceStatistics(root["ata_device_statistics"] as? JSON)
        statistics.append(contentsOf: parsePhyCounters(root["sata_phy_event_counters"] as? JSON))

        let temperatureRoot = root["temperature"] as? JSON

        var snapshot = DriveSnapshot(
            device: device,
            checkedAt: parseDate(root["local_time"] as? JSON) ?? Date(),
            modelName: string(root["model_name"], fallback: string(root["device_model"], fallback: device.displayName)),
            serialNumber: optionalString(root["serial_number"]),
            firmwareVersion: optionalString(root["firmware_version"]),
            userCapacityBytes: uint((root["user_capacity"] as? JSON)?["bytes"]),
            sectorSize: parseSectorSize(root),
            smartStatusPassed: (root["smart_status"] as? JSON)?["passed"] as? Bool,
            temperature: int(temperatureRoot?["current"]) ?? nvme?.temperature,
            powerOnHours: uint((root["power_on_time"] as? JSON)?["hours"]) ?? nvme?.powerOnHours,
            powerCycles: uint(root["power_cycle_count"]) ?? nvme?.powerCycles,
            nvme: nvme,
            attributes: attributes,
            errorLog: errorLog,
            selfTests: parseSelfTests(root),
            activeSelfTest: parseActiveSelfTest(root),
            deviceStatistics: statistics,
            messages: messages
        )
        snapshot.exitStatus = exitStatus
        snapshot.rotationRate = int(root["rotation_rate"])
        snapshot.formFactor = optionalString((root["form_factor"] as? JSON)?["name"])
        snapshot.interfaceSpeed = parseInterfaceSpeed(root["interface_speed"] as? JSON)
        snapshot.ataVersion = optionalString((root["ata_version"] as? JSON)?["string"] ?? root["ata_version"])
        snapshot.sataVersion = optionalString((root["sata_version"] as? JSON)?["string"] ?? root["sata_version"])
        snapshot.nvmeVersion = optionalString((root["nvme_version"] as? JSON)?["string"] ?? root["nvme_version"])
        snapshot.wwn = parseWWN(root["wwn"] as? JSON)
        snapshot.trimSupported = (root["trim"] as? JSON)?["supported"] as? Bool
        snapshot.temperatureLifetimeMin = int(temperatureRoot?["lifetime_min"])
        snapshot.temperatureLifetimeMax = int(temperatureRoot?["lifetime_max"])
        snapshot.sctTemperatureHistory = parseSCTTemperatureHistory(root["ata_sct_temperature_history"] as? JSON)
        return snapshot
    }

    private static func parseInterfaceSpeed(_ root: JSON?) -> String? {
        guard let root else { return nil }
        let current = optionalString((root["current"] as? JSON)?["string"])
        let max = optionalString((root["max"] as? JSON)?["string"])
        switch (current, max) {
        case let (current?, max?) where current == max: return current
        case let (current?, max?): return "\(current) (max \(max))"
        case let (current?, nil): return current
        case let (nil, max?): return max
        default: return nil
        }
    }

    private static func parseWWN(_ root: JSON?) -> String? {
        guard let root, let naa = int(root["naa"]), let oui = int(root["oui"]), let id = uint(root["id"]) else { return nil }
        return String(format: "%X %06X %09llX", naa, oui, id)
    }

    private static func parseSCTTemperatureHistory(_ root: JSON?) -> SCTTemperatureHistory? {
        guard let root, let table = root["table"] as? [Any] else { return nil }
        let interval = int(root["logging_interval_minutes"]) ?? int(root["sampling_period_minutes"]) ?? 1
        let temperatures = table.map { int($0) }
        guard temperatures.contains(where: { $0 != nil }) else { return nil }
        return SCTTemperatureHistory(intervalMinutes: interval, temperatures: temperatures)
    }

    private static func parsePhyCounters(_ root: JSON?) -> [DeviceStatistic] {
        guard let table = root?["table"] as? [[String: Any]] else { return [] }
        return table.map {
            DeviceStatistic(section: "SATA Phy Event Counters", name: string($0["name"]), value: string($0["value"]))
        }
    }

    private static func parseNVMeErrorLog(_ root: JSON?) -> [SmartErrorEntry] {
        guard let table = root?["table"] as? [[String: Any]] else { return [] }
        return table.enumerated().map { index, row in
            SmartErrorEntry(
                id: int(row["error_count"]) ?? index + 1,
                lifetimeHours: nil,
                errors: string((row["status_field"] as? JSON)?["string"], fallback: "NVMe error"),
                priorCommand: int(row["command_id"]).map { String(format: "command id 0x%X", $0) } ?? "-",
                lba: optionalString((row["lba"] as? JSON)?["value"] ?? row["lba"])
            )
        }
    }

    private static func object(from data: Data) throws -> JSON {
        guard let root = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw SmartctlParserError.invalidJSON
        }
        return root
    }

    private static func parseDate(_ root: JSON?) -> Date? {
        guard let time = int(root?["time_t"]) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time))
    }

    private static func parseSectorSize(_ root: JSON) -> String? {
        if let size = root["logical_block_size"] {
            return "\(string(size)) bytes"
        }
        if let block = root["physical_block_size"] {
            return "\(string(block)) bytes"
        }
        return nil
    }

    private static func parseNVMe(_ root: JSON?) -> NVMeHealthLog? {
        guard let root else { return nil }
        var log = NVMeHealthLog(
            criticalWarning: int(root["critical_warning"]),
            temperature: int(root["temperature"]),
            availableSpare: int(root["available_spare"]),
            availableSpareThreshold: int(root["available_spare_threshold"]),
            percentageUsed: int(root["percentage_used"]),
            dataUnitsRead: uint(root["data_units_read"]),
            dataUnitsWritten: uint(root["data_units_written"]),
            hostReads: uint(root["host_reads"]),
            hostWrites: uint(root["host_writes"]),
            controllerBusyTime: uint(root["controller_busy_time"]),
            powerCycles: uint(root["power_cycles"]),
            powerOnHours: uint(root["power_on_hours"]),
            unsafeShutdowns: uint(root["unsafe_shutdowns"]),
            mediaErrors: uint(root["media_errors"]),
            errorLogEntries: uint(root["num_err_log_entries"])
        )
        if let sensors = root["temperature_sensors"] as? [Any] {
            let values = sensors.compactMap { int($0) }
            log.temperatureSensors = values.isEmpty ? nil : values
        }
        log.warningTempTime = int(root["warning_temp_time"])
        log.criticalCompTime = int(root["critical_comp_time"])
        return log
    }

    private static func parseATAAttributes(_ root: JSON?) -> [SmartAttribute] {
        guard let table = root?["table"] as? [[String: Any]] else { return [] }
        return table.compactMap { row in
            guard let id = int(row["id"]) else { return nil }
            let raw = row["raw"] as? JSON
            let flags = row["flags"] as? JSON
            let current = int(row["value"])
            let threshold = int(row["thresh"])
            let percent = normalizedPercent(current: current, threshold: threshold)
            let state = stateForAttribute(id: id, current: current, threshold: threshold, rawValue: rawValueNumber(raw))
            return SmartAttribute(
                id: id,
                name: string(row["name"]),
                type: string(flags?["prefailure"] as? Bool == true ? "pre-fail" : "life-span"),
                rawValue: rawValueString(raw),
                prettyValue: optionalString(raw?["string"]),
                current: current,
                worst: int(row["worst"]),
                threshold: threshold,
                whenFailed: optionalString(row["when_failed"]),
                percent: percent,
                status: state
            )
        }
    }

    private static func parseErrors(_ root: JSON?) -> [SmartErrorEntry] {
        guard let table = root?["table"] as? [[String: Any]] else { return [] }
        return table.enumerated().map { index, row in
            SmartErrorEntry(
                id: int(row["error_number"]) ?? index + 1,
                lifetimeHours: int(row["lifetime_hours"]),
                errors: string(row["error_description"], fallback: string(row["error"])),
                priorCommand: string(row["prior_command"]),
                lba: optionalString(row["lba"])
            )
        }
    }

    private static func parseSelfTests(_ root: JSON) -> [SmartSelfTestEntry] {
        let logs = [
            (root["ata_smart_self_test_log"] as? JSON)?["standard"] as? JSON,
            root["nvme_self_test_log"] as? JSON
        ].compactMap { $0 }
        let table = logs.compactMap { $0["table"] as? [[String: Any]] }.flatMap { $0 }
        return table.enumerated().map { index, row in
            let statusRoot = row["status"] as? JSON
            let status = string(statusRoot?["string"], fallback: string(row["status"], fallback: smartctlString(row["self_test_result"])))
            return SmartSelfTestEntry(
                id: int(row["num"]) ?? index + 1,
                lifetimeHours: int(row["lifetime_hours"]) ?? int(row["power_on_hours"]),
                testType: smartctlString(row["type"], fallback: smartctlString(row["self_test_code"])),
                status: status,
                remainingPercent: int(statusRoot?["remaining_percent"]),
                lbaOfFirstError: optionalString(row["lba_first_error"] ?? (row["lba"] as? JSON)?["value"])
            )
        }
    }

    private static func parseActiveSelfTest(_ root: JSON) -> ActiveSelfTestStatus? {
        if let ataSelfTest = ((root["ata_smart_data"] as? JSON)?["self_test"] as? JSON) {
            let status = ataSelfTest["status"] as? JSON
            let remaining = int(status?["remaining_percent"])
            let title = smartctlString(status, fallback: smartctlString(ataSelfTest["status"]))
            let polling = ataSelfTest["polling_minutes"] as? JSON
            if !title.isEmpty || remaining != nil {
                return ActiveSelfTestStatus(
                    title: title.isEmpty ? "Self-test status unavailable" : title,
                    progressPercent: remaining.map { max(0, min(100, 100 - $0)) },
                    remainingPercent: remaining,
                    estimatedMinutesShort: int(polling?["short"]),
                    estimatedMinutesExtended: int(polling?["extended"])
                )
            }
        }

        if let nvmeLog = root["nvme_self_test_log"] as? JSON {
            let status = smartctlString(nvmeLog["current_self_test_operation"])
            let completion = int(nvmeLog["current_self_test_completion_percent"])
            if !status.isEmpty || completion != nil {
                return ActiveSelfTestStatus(
                    title: status.isEmpty ? "NVMe self-test in progress" : status,
                    progressPercent: completion,
                    remainingPercent: completion.map { max(0, 100 - $0) },
                    estimatedMinutesShort: nil,
                    estimatedMinutesExtended: nil
                )
            }
        }

        return nil
    }

    private static func parseDeviceStatistics(_ root: JSON?) -> [DeviceStatistic] {
        guard let pages = root?["pages"] as? [[String: Any]] else { return [] }
        return pages.flatMap { page -> [DeviceStatistic] in
            let section = string(page["name"], fallback: "Device Statistics")
            let table = page["table"] as? [[String: Any]] ?? []
            return table.map {
                DeviceStatistic(section: section, name: string($0["name"]), value: string($0["value"]))
            }
        }
    }

    private static func nvmeAttributes(from log: NVMeHealthLog) -> [SmartAttribute] {
        var nextID = 1
        func make(_ name: String, raw: Any?, percent: Int?, state: DriveHealthState = .ok, type: String = "life-span") -> SmartAttribute {
            defer { nextID += 1 }
            return SmartAttribute(
                id: nextID,
                name: name,
                type: type,
                rawValue: raw.map { string($0) } ?? "-",
                prettyValue: nil,
                current: percent,
                worst: nil,
                threshold: nil,
                whenFailed: nil,
                percent: percent,
                status: state,
                isSynthetic: true
            )
        }

        var items: [SmartAttribute] = []
        items.append(make("Critical Warning", raw: log.criticalWarning, percent: log.criticalWarning == 0 ? 100 : 0, state: (log.criticalWarning ?? 0) == 0 ? .ok : .failed, type: "pre-fail"))
        items.append(make("Available Spare", raw: log.availableSpare, percent: log.availableSpare, state: spareState(log), type: "pre-fail"))
        items.append(make("Percentage Used", raw: log.percentageUsed, percent: max(0, 100 - (log.percentageUsed ?? 0)), state: usedState(log.percentageUsed), type: "life-span"))
        items.append(make("Media Errors", raw: log.mediaErrors, percent: log.mediaErrors == 0 ? 100 : 0, state: (log.mediaErrors ?? 0) == 0 ? .ok : .failing, type: "pre-fail"))
        items.append(make("Error Log Entries", raw: log.errorLogEntries, percent: log.errorLogEntries == 0 ? 100 : 90, state: (log.errorLogEntries ?? 0) == 0 ? .ok : .warning))
        items.append(make("Temperature", raw: log.temperature, percent: temperaturePercent(log.temperature), state: temperatureState(log.temperature)))
        items.append(make("Unsafe Shutdowns", raw: log.unsafeShutdowns, percent: 100, state: .ok))
        items.append(make("Power On Hours", raw: log.powerOnHours, percent: 100, state: .ok))
        items.append(make("Power Cycles", raw: log.powerCycles, percent: 100, state: .ok))
        items.append(make("Data Units Read", raw: log.dataUnitsRead, percent: 100, state: .ok))
        items.append(make("Data Units Written", raw: log.dataUnitsWritten, percent: 100, state: .ok))
        return items
    }

    private static func stateForAttribute(id: Int, current: Int?, threshold: Int?, rawValue: UInt64?) -> DriveHealthState {
        if let current, let threshold, threshold > 0, current <= threshold {
            return .failed
        }
        let criticalIDs: Set<Int> = [5, 10, 184, 187, 188, 196, 197, 198]
        let cableIDs: Set<Int> = [199]
        if criticalIDs.contains(id), (rawValue ?? 0) > 0 {
            return .failing
        }
        if cableIDs.contains(id), (rawValue ?? 0) > 0 {
            return .warning
        }
        return .ok
    }

    private static func normalizedPercent(current: Int?, threshold: Int?) -> Int? {
        guard let current else { return nil }
        guard let threshold, threshold > 0, current > threshold else {
            return max(0, min(100, current))
        }
        let denominator = max(1, 100 - threshold)
        return max(0, min(100, ((current - threshold) * 100) / denominator))
    }

    private static func spareState(_ log: NVMeHealthLog) -> DriveHealthState {
        guard let spare = log.availableSpare else { return .unknown }
        if spare <= (log.availableSpareThreshold ?? 10) { return .failed }
        if spare <= 10 { return .failing }
        if spare <= 20 { return .warning }
        return .ok
    }

    private static func usedState(_ used: Int?) -> DriveHealthState {
        guard let used else { return .unknown }
        if used >= 100 { return .failed }
        if used >= 90 { return .failing }
        if used >= 70 { return .warning }
        return .ok
    }

    private static func temperatureState(_ temperature: Int?) -> DriveHealthState {
        guard let temperature else { return .unknown }
        if temperature >= 85 { return .failing }
        if temperature >= 70 { return .warning }
        return .ok
    }

    private static func temperaturePercent(_ temperature: Int?) -> Int? {
        guard let temperature else { return nil }
        return max(0, min(100, 100 - max(0, temperature - 35) * 2))
    }

    private static func rawValueNumber(_ raw: JSON?) -> UInt64? {
        uint(raw?["value"])
    }

    private static func rawValueString(_ raw: JSON?) -> String {
        if let string = optionalString(raw?["string"]) { return string }
        if let value = raw?["value"] { return string(value) }
        return "-"
    }

    static func string(_ value: Any?, fallback: String = "") -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let object as [String: Any]:
            return smartctlString(object, fallback: fallback)
        case let value?:
            return "\(value)"
        default:
            return fallback
        }
    }

    static func optionalString(_ value: Any?) -> String? {
        let value = string(value)
        return value.isEmpty ? nil : value
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func uint(_ value: Any?) -> UInt64? {
        switch value {
        case let int as UInt64:
            return int
        case let int as Int:
            return int >= 0 ? UInt64(int) : nil
        case let number as NSNumber:
            return number.uint64Value
        case let string as String:
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func smartctlString(_ value: Any?, fallback: String = "") -> String {
        switch value {
        case let object as [String: Any]:
            if let text = object["string"] { return string(text, fallback: fallback) }
            if let text = object["name"] { return string(text, fallback: fallback) }
            if let value = object["value"] { return string(value, fallback: fallback) }
            return fallback
        default:
            return string(value, fallback: fallback)
        }
    }
}
