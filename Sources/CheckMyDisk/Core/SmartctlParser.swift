import Foundation

enum SmartctlParserError: Error, LocalizedError {
    case invalidJSON

    var errorDescription: String? {
        "smartctl returned JSON that CheckMyDisk could not parse."
    }
}

/// A thin, typed view over smartctl's decoded JSON. smartctl emits values that are
/// sometimes numbers and sometimes strings, plus deeply-optional nested objects, so
/// this wraps `Any?` with safe, chainable accessors instead of scattered `as?`
/// casts. Value extraction delegates to `SmartctlParser`'s primitives so the
/// number-or-string handling stays in one place.
struct SmartJSON {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw
    }

    static func object(from data: Data) throws -> SmartJSON {
        let value = try JSONSerialization.jsonObject(with: data)
        guard value is [String: Any] else { throw SmartctlParserError.invalidJSON }
        return SmartJSON(value)
    }

    /// Child by key; an empty `SmartJSON` when this is not an object or the key is
    /// absent, so navigation can be chained without intermediate `as?` casts.
    subscript(_ key: String) -> SmartJSON {
        SmartJSON((raw as? [String: Any])?[key])
    }

    var exists: Bool { raw != nil }

    /// Array of objects (a smartctl "table"/"pages"); empty when not an object array.
    var objects: [SmartJSON] {
        (raw as? [[String: Any]])?.map(SmartJSON.init) ?? []
    }

    /// Array of arbitrary values (e.g. the SCT temperature table of numbers/nulls).
    var values: [SmartJSON] {
        (raw as? [Any])?.map(SmartJSON.init) ?? []
    }

    var bool: Bool? { raw as? Bool }
    var int: Int? { SmartctlParser.int(raw) }
    var uint: UInt64? { SmartctlParser.uint(raw) }
    var string: String { SmartctlParser.string(raw) }
    func string(fallback: String) -> String { SmartctlParser.string(raw, fallback: fallback) }
    var optionalString: String? { SmartctlParser.optionalString(raw) }
    var smartctlString: String { SmartctlParser.smartctlString(raw) }
    func smartctlString(fallback: String) -> String { SmartctlParser.smartctlString(raw, fallback: fallback) }
}

enum SmartctlParser {
    static func parseScan(_ data: Data) throws -> [SmartDeviceSummary] {
        let root = try SmartJSON.object(from: data)
        return root["devices"].objects.map {
            SmartDeviceSummary(
                name: $0["name"].string,
                infoName: $0["info_name"].string,
                type: $0["type"].string,
                protocolName: $0["protocol"].string
            )
        }
    }

    static func parseSnapshot(_ data: Data, fallbackDevice: SmartDeviceSummary, exitStatus: SmartctlExitStatus? = nil) throws -> DriveSnapshot {
        let root = try SmartJSON.object(from: data)
        let deviceRoot = root["device"]
        let device = SmartDeviceSummary(
            name: deviceRoot["name"].string(fallback: fallbackDevice.name),
            infoName: deviceRoot["info_name"].string(fallback: fallbackDevice.infoName),
            type: deviceRoot["type"].string(fallback: fallbackDevice.type),
            protocolName: deviceRoot["protocol"].string(fallback: fallbackDevice.protocolName)
        )
        let messages = root["smartctl"]["messages"].objects.map {
            SmartMessage(severity: $0["severity"].string, text: $0["string"].string)
        }

        let nvme = parseNVMe(root["nvme_smart_health_information_log"])
        var attributes = parseATAAttributes(root["ata_smart_attributes"])
        if attributes.isEmpty, let nvme {
            attributes = nvmeAttributes(from: nvme)
        }

        var errorLog = parseErrors(root["ata_smart_error_log"])
        errorLog.append(contentsOf: parseNVMeErrorLog(root["nvme_error_information_log"]))

        var statistics = parseDeviceStatistics(root["ata_device_statistics"])
        statistics.append(contentsOf: parsePhyCounters(root["sata_phy_event_counters"]))

        let temperature = root["temperature"]

        var snapshot = DriveSnapshot(
            device: device,
            checkedAt: parseDate(root["local_time"]) ?? Date(),
            modelName: root["model_name"].string(fallback: root["device_model"].string(fallback: device.displayName)),
            serialNumber: root["serial_number"].optionalString,
            firmwareVersion: root["firmware_version"].optionalString,
            userCapacityBytes: root["user_capacity"]["bytes"].uint,
            sectorSize: parseSectorSize(root),
            smartStatusPassed: root["smart_status"]["passed"].bool,
            temperature: temperature["current"].int ?? nvme?.temperature,
            powerOnHours: root["power_on_time"]["hours"].uint ?? nvme?.powerOnHours,
            powerCycles: root["power_cycle_count"].uint ?? nvme?.powerCycles,
            nvme: nvme,
            attributes: attributes,
            errorLog: errorLog,
            selfTests: parseSelfTests(root),
            activeSelfTest: parseActiveSelfTest(root),
            deviceStatistics: statistics,
            messages: messages
        )
        snapshot.exitStatus = exitStatus
        snapshot.rotationRate = root["rotation_rate"].int
        snapshot.formFactor = root["form_factor"]["name"].optionalString
        snapshot.interfaceSpeed = parseInterfaceSpeed(root["interface_speed"])
        snapshot.ataVersion = optionalString(root["ata_version"]["string"].raw ?? root["ata_version"].raw)
        snapshot.sataVersion = optionalString(root["sata_version"]["string"].raw ?? root["sata_version"].raw)
        snapshot.nvmeVersion = optionalString(root["nvme_version"]["string"].raw ?? root["nvme_version"].raw)
        snapshot.wwn = parseWWN(root["wwn"])
        snapshot.trimSupported = root["trim"]["supported"].bool
        snapshot.temperatureLifetimeMin = temperature["lifetime_min"].int
        snapshot.temperatureLifetimeMax = temperature["lifetime_max"].int
        snapshot.sctTemperatureHistory = parseSCTTemperatureHistory(root["ata_sct_temperature_history"])
        return snapshot
    }

    private static func parseInterfaceSpeed(_ root: SmartJSON) -> String? {
        guard root.exists else { return nil }
        let current = root["current"]["string"].optionalString
        let max = root["max"]["string"].optionalString
        switch (current, max) {
        case let (current?, max?) where current == max: return current
        case let (current?, max?): return "\(current) (max \(max))"
        case let (current?, nil): return current
        case let (nil, max?): return max
        default: return nil
        }
    }

    private static func parseWWN(_ root: SmartJSON) -> String? {
        guard root.exists, let naa = root["naa"].int, let oui = root["oui"].int, let id = root["id"].uint else { return nil }
        return String(format: "%X %06X %09llX", naa, oui, id)
    }

    private static func parseSCTTemperatureHistory(_ root: SmartJSON) -> SCTTemperatureHistory? {
        guard root.exists, root["table"].raw is [Any] else { return nil }
        let interval = root["logging_interval_minutes"].int ?? root["sampling_period_minutes"].int ?? 1
        let temperatures = root["table"].values.map { $0.int }
        guard temperatures.contains(where: { $0 != nil }) else { return nil }
        return SCTTemperatureHistory(intervalMinutes: interval, temperatures: temperatures)
    }

    private static func parsePhyCounters(_ root: SmartJSON) -> [DeviceStatistic] {
        root["table"].objects.map {
            DeviceStatistic(section: "SATA Phy Event Counters", name: $0["name"].string, value: $0["value"].string)
        }
    }

    private static func parseNVMeErrorLog(_ root: SmartJSON) -> [SmartErrorEntry] {
        root["table"].objects.enumerated().map { index, row in
            SmartErrorEntry(
                id: row["error_count"].int ?? index + 1,
                lifetimeHours: nil,
                errors: row["status_field"]["string"].string(fallback: "NVMe error"),
                priorCommand: row["command_id"].int.map { String(format: "command id 0x%X", $0) } ?? "-",
                lba: optionalString(row["lba"]["value"].raw ?? row["lba"].raw)
            )
        }
    }

    private static func parseDate(_ root: SmartJSON) -> Date? {
        guard let time = root["time_t"].int else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time))
    }

    private static func parseSectorSize(_ root: SmartJSON) -> String? {
        if root["logical_block_size"].exists {
            return "\(root["logical_block_size"].string) bytes"
        }
        if root["physical_block_size"].exists {
            return "\(root["physical_block_size"].string) bytes"
        }
        return nil
    }

    private static func parseNVMe(_ root: SmartJSON) -> NVMeHealthLog? {
        guard root.exists else { return nil }
        var log = NVMeHealthLog(
            criticalWarning: root["critical_warning"].int,
            temperature: root["temperature"].int,
            availableSpare: root["available_spare"].int,
            availableSpareThreshold: root["available_spare_threshold"].int,
            percentageUsed: root["percentage_used"].int,
            dataUnitsRead: root["data_units_read"].uint,
            dataUnitsWritten: root["data_units_written"].uint,
            hostReads: root["host_reads"].uint,
            hostWrites: root["host_writes"].uint,
            controllerBusyTime: root["controller_busy_time"].uint,
            powerCycles: root["power_cycles"].uint,
            powerOnHours: root["power_on_hours"].uint,
            unsafeShutdowns: root["unsafe_shutdowns"].uint,
            mediaErrors: root["media_errors"].uint,
            errorLogEntries: root["num_err_log_entries"].uint
        )
        let sensors = root["temperature_sensors"].values.compactMap { $0.int }
        log.temperatureSensors = sensors.isEmpty ? nil : sensors
        log.warningTempTime = root["warning_temp_time"].int
        log.criticalCompTime = root["critical_comp_time"].int
        return log
    }

    private static func parseATAAttributes(_ root: SmartJSON) -> [SmartAttribute] {
        root["table"].objects.compactMap { row in
            guard let id = row["id"].int else { return nil }
            let raw = row["raw"]
            let current = row["value"].int
            let threshold = row["thresh"].int
            let percent = normalizedPercent(current: current, threshold: threshold)
            let state = stateForAttribute(id: id, current: current, threshold: threshold, rawValue: raw["value"].uint)
            return SmartAttribute(
                id: id,
                name: row["name"].string,
                type: row["flags"]["prefailure"].bool == true ? "pre-fail" : "life-span",
                rawValue: rawValueString(raw),
                prettyValue: raw["string"].optionalString,
                current: current,
                worst: row["worst"].int,
                threshold: threshold,
                whenFailed: row["when_failed"].optionalString,
                percent: percent,
                status: state
            )
        }
    }

    private static func parseErrors(_ root: SmartJSON) -> [SmartErrorEntry] {
        // smartctl nests the ATA error table differently across versions and logs:
        // directly under the log, or under "extended" / "summary".
        var rows = root["table"].objects
        if rows.isEmpty { rows = root["extended"]["table"].objects }
        if rows.isEmpty { rows = root["summary"]["table"].objects }
        return rows.enumerated().map { index, row in
            SmartErrorEntry(
                id: row["error_number"].int ?? index + 1,
                lifetimeHours: row["lifetime_hours"].int,
                errors: row["error_description"].string(fallback: row["error"].string),
                priorCommand: row["prior_command"].string,
                lba: row["lba"].optionalString
            )
        }
    }

    private static func parseSelfTests(_ root: SmartJSON) -> [SmartSelfTestEntry] {
        let logs = [root["ata_smart_self_test_log"]["standard"], root["nvme_self_test_log"]]
        let table = logs.flatMap { $0["table"].objects }
        return table.enumerated().map { index, row in
            let statusRoot = row["status"]
            let status = statusRoot["string"].string(fallback: row["status"].string(fallback: row["self_test_result"].smartctlString))
            return SmartSelfTestEntry(
                id: row["num"].int ?? index + 1,
                lifetimeHours: row["lifetime_hours"].int ?? row["power_on_hours"].int,
                testType: row["type"].smartctlString(fallback: row["self_test_code"].smartctlString),
                status: status,
                remainingPercent: statusRoot["remaining_percent"].int,
                lbaOfFirstError: optionalString(row["lba_first_error"].raw ?? row["lba"]["value"].raw)
            )
        }
    }

    private static func parseActiveSelfTest(_ root: SmartJSON) -> ActiveSelfTestStatus? {
        let ataSelfTest = root["ata_smart_data"]["self_test"]
        if ataSelfTest.exists {
            let status = ataSelfTest["status"]
            let remaining = status["remaining_percent"].int
            let title = status.smartctlString(fallback: ataSelfTest["status"].smartctlString)
            let polling = ataSelfTest["polling_minutes"]
            if !title.isEmpty || remaining != nil {
                return ActiveSelfTestStatus(
                    title: title.isEmpty ? "Self-test status unavailable" : title,
                    progressPercent: remaining.map { max(0, min(100, 100 - $0)) },
                    remainingPercent: remaining,
                    estimatedMinutesShort: polling["short"].int,
                    estimatedMinutesExtended: polling["extended"].int
                )
            }
        }

        let nvmeLog = root["nvme_self_test_log"]
        if nvmeLog.exists {
            let status = nvmeLog["current_self_test_operation"].smartctlString
            let completion = nvmeLog["current_self_test_completion_percent"].int
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

    private static func parseDeviceStatistics(_ root: SmartJSON) -> [DeviceStatistic] {
        root["pages"].objects.flatMap { page -> [DeviceStatistic] in
            let section = page["name"].string(fallback: "Device Statistics")
            return page["table"].objects.map {
                DeviceStatistic(section: section, name: $0["name"].string, value: $0["value"].string)
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

    private static func rawValueString(_ raw: SmartJSON) -> String {
        if let string = raw["string"].optionalString { return string }
        if raw["value"].exists { return raw["value"].string }
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
