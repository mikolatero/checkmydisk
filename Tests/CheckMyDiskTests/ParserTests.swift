import XCTest
@testable import CheckMyDisk

final class ParserTests: XCTestCase {
    func testParsesScanJSON() throws {
        let data = """
        {
          "devices": [
            {"name": "/dev/disk0", "info_name": "/dev/disk0", "type": "nvme", "protocol": "NVMe"}
          ]
        }
        """.data(using: .utf8)!

        let devices = try SmartctlParser.parseScan(data)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "/dev/disk0")
        XCTAssertEqual(devices[0].protocolName, "NVMe")
    }

    func testParsesNVMeSnapshotAndEvaluatesHealthyDrive() throws {
        let snapshot = try SmartctlParser.parseSnapshot(nvmeJSON, fallbackDevice: fallback)
        let assessment = HealthEvaluator.evaluate(snapshot)

        XCTAssertEqual(snapshot.modelName, "APPLE SSD AP0512Z")
        XCTAssertEqual(snapshot.attributes.contains(where: { $0.name == "Available Spare" }), true)
        XCTAssertEqual(assessment.smartStatus, .ok)
        XCTAssertEqual(assessment.ssdLifetimeLeft, 97)
    }

    func testNVMeMediaErrorsBecomeFailing() throws {
        var root = try JSONSerialization.jsonObject(with: nvmeJSON) as! [String: Any]
        var log = root["nvme_smart_health_information_log"] as! [String: Any]
        log["media_errors"] = 2
        root["nvme_smart_health_information_log"] = log
        let data = try JSONSerialization.data(withJSONObject: root)

        let snapshot = try SmartctlParser.parseSnapshot(data, fallbackDevice: fallback)
        let assessment = HealthEvaluator.evaluate(snapshot)

        XCTAssertEqual(assessment.smartStatus, .failing)
        XCTAssertTrue(assessment.problems.contains(where: { $0.title.contains("media errors") }))
    }

    func testATAReallocatedSectorBecomesFailing() throws {
        let snapshot = try SmartctlParser.parseSnapshot(ataJSON, fallbackDevice: ataFallback)
        let assessment = HealthEvaluator.evaluate(snapshot)

        XCTAssertEqual(snapshot.attributes.first?.status, .failing)
        XCTAssertEqual(assessment.smartStatus, .failing)
    }

    func testReportAnonymizesSerial() throws {
        let snapshot = try SmartctlParser.parseSnapshot(nvmeJSON, fallbackDevice: fallback)
        let assessment = HealthEvaluator.evaluate(snapshot)
        let report = ReportBuilder.textReport(snapshot: snapshot, assessment: assessment, anonymize: true)

        XCTAssertFalse(report.contains("0ba0223ae0d45438"))
        XCTAssertTrue(report.contains("xxxxxxxx"))
        XCTAssertTrue(report.contains("Data Written"))
    }

    func testNVMeDataUnitsWrittenConvertToBytes() throws {
        let snapshot = try SmartctlParser.parseSnapshot(nvmeJSON, fallbackDevice: fallback)

        XCTAssertEqual(DriveUsageMetrics.bytesWritten(for: snapshot), 173_820_068 * 512_000)
        XCTAssertNotNil(DriveUsageMetrics.formattedBytesWritten(for: snapshot))
    }

    func testATALBAsWrittenConvertToBytes() throws {
        let snapshot = try SmartctlParser.parseSnapshot(ataWrittenJSON, fallbackDevice: ataFallback)

        XCTAssertEqual(DriveUsageMetrics.bytesWritten(for: snapshot), 1_000_000 * 512)
    }

    func testSelfTestTypeObjectUsesStringValue() throws {
        let snapshot = try SmartctlParser.parseSnapshot(selfTestJSON, fallbackDevice: ataFallback)

        XCTAssertEqual(snapshot.selfTests.first?.testType, "Short offline")
        XCTAssertEqual(snapshot.selfTests.first?.status, "Completed without error")
    }

    func testActiveSelfTestStatusParsesProgress() throws {
        let snapshot = try SmartctlParser.parseSnapshot(activeSelfTestJSON, fallbackDevice: ataFallback)

        XCTAssertEqual(snapshot.activeSelfTest?.isRunning, true)
        XCTAssertEqual(snapshot.activeSelfTest?.progressPercent, 50)
        XCTAssertEqual(snapshot.activeSelfTest?.remainingPercent, 50)
    }
}

private let fallback = SmartDeviceSummary(name: "/dev/disk0", infoName: "/dev/disk0", type: "nvme", protocolName: "NVMe")
private let ataFallback = SmartDeviceSummary(name: "/dev/disk2", infoName: "/dev/disk2", type: "sat", protocolName: "ATA")

private let nvmeJSON = """
{
  "local_time": {"time_t": 1783513991},
  "device": {"name": "/dev/disk0", "info_name": "/dev/disk0", "type": "nvme", "protocol": "NVMe"},
  "model_name": "APPLE SSD AP0512Z",
  "serial_number": "0ba0223ae0d45438",
  "firmware_version": "561.100.",
  "smart_status": {"passed": true},
  "nvme_smart_health_information_log": {
    "critical_warning": 0,
    "temperature": 34,
    "available_spare": 100,
    "available_spare_threshold": 99,
    "percentage_used": 3,
    "data_units_read": 481467922,
    "data_units_written": 173820068,
    "host_reads": 23995192870,
    "host_writes": 5101757186,
    "controller_busy_time": 0,
    "power_cycles": 225,
    "power_on_hours": 4948,
    "unsafe_shutdowns": 30,
    "media_errors": 0,
    "num_err_log_entries": 0
  }
}
""".data(using: .utf8)!

private let ataJSON = """
{
  "local_time": {"time_t": 1783513991},
  "device": {"name": "/dev/disk2", "info_name": "/dev/disk2", "type": "sat", "protocol": "ATA"},
  "model_name": "Example HDD",
  "serial_number": "S123",
  "smart_status": {"passed": true},
  "ata_smart_attributes": {
    "table": [
      {
        "id": 5,
        "name": "Reallocated_Sector_Ct",
        "value": 100,
        "worst": 100,
        "thresh": 10,
        "raw": {"value": 1, "string": "1"},
        "flags": {"prefailure": true}
      }
    ]
  }
}
""".data(using: .utf8)!

private let ataWrittenJSON = """
{
  "local_time": {"time_t": 1783513991},
  "device": {"name": "/dev/disk2", "info_name": "/dev/disk2", "type": "sat", "protocol": "ATA"},
  "model_name": "Example SSD",
  "serial_number": "S123",
  "logical_block_size": 512,
  "smart_status": {"passed": true},
  "ata_smart_attributes": {
    "table": [
      {
        "id": 241,
        "name": "Total_LBAs_Written",
        "value": 100,
        "worst": 100,
        "thresh": 0,
        "raw": {"value": 1000000, "string": "1000000"},
        "flags": {"prefailure": false}
      }
    ]
  }
}
""".data(using: .utf8)!

private let selfTestJSON = """
{
  "local_time": {"time_t": 1783513991},
  "device": {"name": "/dev/disk2", "info_name": "/dev/disk2", "type": "sat", "protocol": "ATA"},
  "model_name": "Example HDD",
  "smart_status": {"passed": true},
  "ata_smart_self_test_log": {
    "standard": {
      "table": [
        {
          "num": 1,
          "lifetime_hours": 24624,
          "type": {"string": "Short offline"},
          "status": {"string": "Completed without error"},
          "lba_first_error": "-"
        }
      ]
    }
  }
}
""".data(using: .utf8)!

private let activeSelfTestJSON = """
{
  "local_time": {"time_t": 1783513991},
  "device": {"name": "/dev/disk2", "info_name": "/dev/disk2", "type": "sat", "protocol": "ATA"},
  "model_name": "Example HDD",
  "smart_status": {"passed": true},
  "ata_smart_data": {
    "self_test": {
      "status": {
        "string": "Self-test routine in progress",
        "remaining_percent": 50
      },
      "polling_minutes": {
        "short": 2,
        "extended": 121
      }
    }
  }
}
""".data(using: .utf8)!
