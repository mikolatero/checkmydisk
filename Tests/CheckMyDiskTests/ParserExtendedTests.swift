import XCTest
@testable import CheckMyDisk

/// Cobertura de los campos que solo emite `smartctl -x`.
final class ParserExtendedTests: XCTestCase {
    private var device: SmartDeviceSummary {
        SmartDeviceSummary(name: "/dev/disk1", infoName: "/dev/disk1 [SAT]", type: "sat", protocolName: "ATA")
    }

    func testParsesExtendedATAIdentity() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(extendedATAJSON.utf8), fallbackDevice: device)
        XCTAssertEqual(snapshot.rotationRate, 7200)
        XCTAssertEqual(snapshot.isRotational, true)
        XCTAssertEqual(snapshot.formFactor, "3.5 inches")
        XCTAssertEqual(snapshot.interfaceSpeed, "6.0 Gb/s")
        XCTAssertEqual(snapshot.sataVersion, "SATA 3.1")
        XCTAssertEqual(snapshot.ataVersion, "ACS-2")
        XCTAssertEqual(snapshot.wwn, "5 0014EE 0C400105A")
        XCTAssertEqual(snapshot.trimSupported, false)
        XCTAssertEqual(snapshot.temperatureLifetimeMin, 15)
        XCTAssertEqual(snapshot.temperatureLifetimeMax, 55)
    }

    func testParsesDeviceStatisticsAndPhyCounters() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(extendedATAJSON.utf8), fallbackDevice: device)
        XCTAssertTrue(snapshot.deviceStatistics.contains { $0.name == "Power-on Hours" && $0.value == "5000" })
        let phy = snapshot.deviceStatistics.filter { $0.section == "SATA Phy Event Counters" }
        XCTAssertEqual(phy.count, 2)
        XCTAssertTrue(phy.contains { $0.value == "3" })
    }

    func testParsesSCTTemperatureHistory() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(extendedATAJSON.utf8), fallbackDevice: device)
        let history = try XCTUnwrap(snapshot.sctTemperatureHistory)
        XCTAssertEqual(history.intervalMinutes, 10)
        XCTAssertEqual(history.temperatures.count, 5)
        XCTAssertEqual(history.temperatures[0], 41)
        XCTAssertNil(history.temperatures[2], "los huecos del log circular se conservan como nil")
    }

    func testParsesInterfaceSpeedWithDifferentCurrentAndMax() throws {
        let json = """
        {
          "model_name": "Slow Link",
          "interface_speed": {
            "max": {"string": "6.0 Gb/s"},
            "current": {"string": "3.0 Gb/s"}
          }
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        XCTAssertEqual(snapshot.interfaceSpeed, "3.0 Gb/s (max 6.0 Gb/s)")
    }

    func testParsesNVMeErrorLogAndSensors() throws {
        let json = """
        {
          "model_name": "NVMe Drive",
          "nvme_smart_health_information_log": {
            "critical_warning": 0,
            "temperature": 40,
            "temperature_sensors": [40, 55],
            "warning_temp_time": 12,
            "critical_comp_time": 0,
            "available_spare": 100,
            "available_spare_threshold": 10,
            "percentage_used": 1
          },
          "nvme_error_information_log": {
            "table": [
              {
                "error_count": 7,
                "command_id": 28,
                "status_field": {"string": "Invalid Field in Command"},
                "lba": {"value": 0}
              }
            ]
          }
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        XCTAssertEqual(snapshot.nvme?.temperatureSensors, [40, 55])
        XCTAssertEqual(snapshot.nvme?.warningTempTime, 12)
        XCTAssertEqual(snapshot.errorLog.count, 1)
        XCTAssertEqual(snapshot.errorLog[0].id, 7)
        XCTAssertTrue(snapshot.errorLog[0].errors.contains("Invalid Field"))
    }

    func testActiveSelfTestExposesBothPollingMinutes() throws {
        let json = """
        {
          "model_name": "Test Drive",
          "ata_smart_data": {
            "self_test": {
              "status": {"string": "in progress, 70% remaining", "remaining_percent": 70},
              "polling_minutes": {"short": 2, "extended": 85}
            }
          }
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        let active = try XCTUnwrap(snapshot.activeSelfTest)
        XCTAssertEqual(active.estimatedMinutes(forKind: "short"), 2)
        XCTAssertEqual(active.estimatedMinutes(forKind: "long"), 85)
        XCTAssertEqual(active.progressPercent, 30)
    }

    func testNVMeSelfTestLogFallbacks() throws {
        let json = """
        {
          "model_name": "NVMe Drive",
          "nvme_self_test_log": {
            "table": [
              {
                "self_test_code": {"value": 1, "string": "Short"},
                "self_test_result": {"value": 0, "string": "Completed without error"},
                "power_on_hours": 999
              }
            ]
          }
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        XCTAssertEqual(snapshot.selfTests.count, 1)
        XCTAssertEqual(snapshot.selfTests[0].lifetimeHours, 999)
        XCTAssertEqual(snapshot.selfTests[0].testType, "Short")
        XCTAssertEqual(snapshot.selfTests[0].status, "Completed without error")
    }

    func testBytesReadFromATAAttribute() throws {
        let json = """
        {
          "model_name": "SSD",
          "logical_block_size": 512,
          "ata_smart_attributes": {
            "table": [
              {
                "id": 242,
                "name": "Total_LBAs_Read",
                "value": 100,
                "thresh": 0,
                "flags": {"prefailure": false},
                "raw": {"value": 1000000, "string": "1000000"}
              }
            ]
          }
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        XCTAssertEqual(DriveUsageMetrics.bytesRead(for: snapshot), 1_000_000 * 512)
    }

    private let extendedATAJSON = """
    {
      "model_name": "WDC WD40EFRX",
      "serial_number": "WD-TEST",
      "rotation_rate": 7200,
      "form_factor": {"ata_value": 2, "name": "3.5 inches"},
      "interface_speed": {
        "max": {"string": "6.0 Gb/s"},
        "current": {"string": "6.0 Gb/s"}
      },
      "sata_version": {"string": "SATA 3.1"},
      "ata_version": {"string": "ACS-2"},
      "wwn": {"naa": 5, "oui": 5358, "id": 3288338522},
      "trim": {"supported": false},
      "smart_status": {"passed": true},
      "temperature": {"current": 41, "lifetime_min": 15, "lifetime_max": 55},
      "ata_device_statistics": {
        "pages": [
          {
            "name": "General Statistics",
            "table": [
              {"name": "Power-on Hours", "value": 5000},
              {"name": "Logical Sectors Written", "value": 123456789}
            ]
          }
        ]
      },
      "sata_phy_event_counters": {
        "table": [
          {"id": 1, "name": "Command failed due to ICRC error", "value": 0},
          {"id": 2, "name": "R_ERR response for data FIS", "value": 3}
        ]
      },
      "ata_sct_temperature_history": {
        "sampling_period_minutes": 10,
        "logging_interval_minutes": 10,
        "table": [41, 42, null, 43, 41]
      }
    }
    """
}
