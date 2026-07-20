import Foundation

enum ReportBuilder {
    static func textReport(snapshot: DriveSnapshot, assessment: DriveAssessment, anonymize: Bool) -> String {
        let serial = anonymize ? redact(snapshot.serialNumber) : snapshot.serialNumber ?? "-"
        let firmware = snapshot.firmwareVersion ?? "-"
        let capacity = snapshot.userCapacityBytes.map(formatBytes) ?? "-"
        let dataWritten = DriveUsageMetrics.formattedBytesWritten(for: snapshot) ?? "-"
        let lifetime = assessment.ssdLifetimeLeft.map { "\($0)%" } ?? "N/A"

        var lines: [String] = [
            "CheckMyDisk Drive Health Report",
            "Generated: \(snapshot.checkedAt.formatted(date: .abbreviated, time: .standard))",
            "",
            "Device: \(snapshot.device.displayName)",
            "Model: \(snapshot.modelName)",
            "Serial: \(serial)",
            "Firmware: \(firmware)",
            "Protocol: \(snapshot.device.protocolName)",
            "Capacity: \(capacity)",
            "Data Written: \(dataWritten)",
            "",
            "Advanced SMART Status: \(assessment.smartStatus.rawValue)",
            "Overall Health Rating: \(assessment.overallHealth)%",
            "Overall Performance Rating: \(assessment.overallPerformance)%",
            "SSD Lifetime Left Indicator: \(lifetime)",
            ""
        ]

        if !assessment.problems.isEmpty {
            lines.append("Problems Summary")
            for problem in assessment.problems {
                lines.append("- [\(problem.state.rawValue)] \(problem.title): \(problem.detail)")
            }
            lines.append("")
        }

        lines.append("Health Indicators")
        for attribute in snapshot.attributes {
            lines.append("\(attribute.id) \(attribute.name): raw=\(attribute.rawValue), current=\(attribute.current.map(String.init) ?? "-"), threshold=\(attribute.threshold.map(String.init) ?? "-"), status=\(attribute.status.rawValue)")
        }

        if !snapshot.errorLog.isEmpty {
            lines.append("")
            lines.append("Error Log")
            for entry in snapshot.errorLog {
                lines.append("#\(entry.id) lifetime=\(entry.lifetimeHours.map(String.init) ?? "-") errors=\(entry.errors) prior=\(entry.priorCommand)")
            }
        }

        if !snapshot.selfTests.isEmpty {
            lines.append("")
            lines.append("Self-tests")
            for entry in snapshot.selfTests {
                lines.append("#\(entry.id) lifetime=\(entry.lifetimeHours.map(String.init) ?? "-") type=\(entry.testType) status=\(entry.status) LBA=\(entry.lbaOfFirstError ?? "-")")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func jsonReport(snapshot: DriveSnapshot, assessment: DriveAssessment, anonymize: Bool) throws -> Data {
        var copy = snapshot
        if anonymize {
            copy.serialNumber = redact(snapshot.serialNumber)
            copy.wwn = copy.wwn.map { _ in redact(snapshot.wwn) }
        }
        let envelope = ReportEnvelope(snapshot: copy, assessment: assessment)
        return try JSONEncoder.pretty.encode(envelope)
    }

    private static func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "-" }
        return String(repeating: "x", count: min(8, value.count))
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal)
    }
}

enum DriveUsageMetrics {
    static func bytesWritten(for snapshot: DriveSnapshot) -> UInt64? {
        if let dataUnitsWritten = snapshot.nvme?.dataUnitsWritten {
            return dataUnitsWritten.multipliedReportingOverflow(by: 512_000).partialValue
        }

        let sectorBytes = UInt64(firstInteger(in: snapshot.sectorSize) ?? 512)
        for attribute in snapshot.attributes {
            let name = attribute.name.lowercased()
            guard let raw = rawNumber(attribute.rawValue) else { continue }

            if attribute.id == 241 ||
                name.contains("total_lbas_written") ||
                name.contains("host_lbas_written") {
                return raw.multipliedReportingOverflow(by: sectorBytes).partialValue
            }

            if name.contains("32mib") || name.contains("32 mib") {
                return raw.multipliedReportingOverflow(by: 32 * 1_048_576).partialValue
            }

            if name.contains("gib") {
                return raw.multipliedReportingOverflow(by: 1_073_741_824).partialValue
            }
            if name.contains("gb") {
                return raw.multipliedReportingOverflow(by: 1_000_000_000).partialValue
            }
        }

        return nil
    }

    static func formattedBytesWritten(for snapshot: DriveSnapshot) -> String? {
        bytesWritten(for: snapshot).map(ReportBuilder.formatBytes)
    }

    static func bytesRead(for snapshot: DriveSnapshot) -> UInt64? {
        if let dataUnitsRead = snapshot.nvme?.dataUnitsRead {
            return dataUnitsRead.multipliedReportingOverflow(by: 512_000).partialValue
        }
        let sectorBytes = UInt64(firstInteger(in: snapshot.sectorSize) ?? 512)
        for attribute in snapshot.attributes {
            let name = attribute.name.lowercased()
            guard let raw = rawNumber(attribute.rawValue) else { continue }
            if attribute.id == 242 || name.contains("total_lbas_read") || name.contains("host_lbas_read") {
                return raw.multipliedReportingOverflow(by: sectorBytes).partialValue
            }
        }
        return nil
    }

    static func formattedBytesRead(for snapshot: DriveSnapshot) -> String? {
        bytesRead(for: snapshot).map(ReportBuilder.formatBytes)
    }

    private static func rawNumber(_ value: String) -> UInt64? {
        let digits = value.filter(\.isNumber)
        return digits.isEmpty ? nil : UInt64(digits)
    }

    private static func firstInteger(in value: String?) -> Int? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars
        var current = ""
        for scalar in scalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                current.append(Character(scalar))
            } else if !current.isEmpty {
                return Int(current)
            }
        }
        return current.isEmpty ? nil : Int(current)
    }
}

private struct ReportEnvelope: Codable {
    let snapshot: DriveSnapshot
    let assessment: DriveAssessment
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
