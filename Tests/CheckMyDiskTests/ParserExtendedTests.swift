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

    // MARK: - NVMe tras puente USB: no confiar en la lectura ATA basura

    func testGarbageATAReadIsNotTrustworthy() throws {
        // Un NVMe leído como ATA a través del puente USB "responde" pero con una
        // estructura corrupta: checksum inválido y todas las filas "Unknown_Attribute".
        let snapshot = try SmartctlParser.parseSnapshot(Data(bridgeGarbageJSON.utf8), fallbackDevice: device)
        XCTAssertFalse(snapshot.attributes.isEmpty, "el parser aún lee las filas crudas")
        XCTAssertEqual(snapshot.smartStatusPassed, true, "el PASSED engañoso está presente en el JSON")
        XCTAssertFalse(snapshot.hasTrustworthyHealthData, "filas 'Unknown_Attribute' + checksum inválido no son fiables")
    }

    func testRealSATAReadIsTrustworthy() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(realSATAJSON.utf8), fallbackDevice: device)
        XCTAssertTrue(snapshot.hasTrustworthyHealthData, "atributos reconocidos + checksum válido son fiables")
    }

    func testStatusOnlyReadIsTrustworthy() throws {
        // Algunos puentes SATA-USB devuelven el veredicto global sin tabla de
        // atributos; sigue siendo un dato fiable y no debe marcarse como puente roto.
        let json = """
        { "smartctl": { "exit_status": 0 }, "model_name": "Some SATA SSD", "smart_status": { "passed": true } }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        XCTAssertTrue(snapshot.attributes.isEmpty)
        XCTAssertTrue(snapshot.hasTrustworthyHealthData)
    }

    func testMarkingBridgeLimitedStripsUntrustedData() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(bridgeGarbageJSON.utf8), fallbackDevice: device)
        let limited = snapshot.markingBridgeLimited()
        XCTAssertTrue(limited.attributes.isEmpty)
        XCTAssertNil(limited.smartStatusPassed)
        XCTAssertNil(limited.temperature)
        XCTAssertFalse(limited.hasBasicHealthData)
        XCTAssertEqual(limited.accessLimitation, .smartUnavailableOverBridge)
        // La identidad del disco se conserva para poder listarlo.
        XCTAssertEqual(limited.modelName, "Samsung SSD 990 PRO 2TB")
    }

    // MARK: - Escalera de acceso (auto -> sat -> snt*)

    func testCandidateLadderForATAAddsSATAndNVMeBridges() {
        let ata = SmartDeviceSummary(name: "/dev/disk6", infoName: "", type: "ata", protocolName: "ATA")
        let joined = SmartctlRunner.candidateArguments(for: ata).map { $0.arguments.joined(separator: " ") }
        XCTAssertEqual(joined.first, "-x -j /dev/disk6", "primero el auto-detect")
        XCTAssertTrue(joined.contains("-d sat -x -j /dev/disk6"))
        XCTAssertTrue(joined.contains("-d sntrealtek -x -j /dev/disk6"))
        XCTAssertTrue(joined.contains("-d sntjmicron -x -j /dev/disk6"))
        XCTAssertTrue(joined.contains("-d sntasmedia -x -j /dev/disk6"))
        XCTAssertTrue(SmartctlRunner.candidateArguments(for: ata).dropFirst().allSatisfy { $0.isBridgeAccess })
    }

    func testCandidateLadderForNVMeStaysDirect() {
        let nvme = SmartDeviceSummary(name: "/dev/disk0", infoName: "", type: "nvme", protocolName: "NVMe")
        let candidates = SmartctlRunner.candidateArguments(for: nvme)
        XCTAssertEqual(candidates.count, 1, "un NVMe nativo se lee directo, sin puentes")
        XCTAssertEqual(candidates.first?.isBridgeAccess, false)
    }

    func testCandidateLadderForSATSkipsRedundantSAT() {
        // `device` ya viene tipado "sat": el auto-detect ya es la lectura SAT, así que
        // no repetimos `-d sat`, pero sí probamos los puentes NVMe.
        let joined = SmartctlRunner.candidateArguments(for: device).map { $0.arguments.joined(separator: " ") }
        XCTAssertFalse(joined.contains { $0.hasPrefix("-d sat ") }, "no repetir la lectura SAT")
        XCTAssertTrue(joined.contains("-d sntrealtek -x -j /dev/disk1"))
    }

    private let bridgeGarbageJSON = """
    {
     "smartctl": { "version": [7, 5],
       "messages": [ { "string": "Warning! SMART Attribute Data Structure error: invalid SMART checksum.", "severity": "warning" } ],
       "exit_status": 4 },
     "device": { "name": "/dev/disk6", "info_name": "/dev/disk6", "type": "ata", "protocol": "ATA" },
     "model_name": "Samsung SSD 990 PRO 2TB",
     "smart_status": { "passed": true },
     "temperature": { "current": 45 },
     "ata_smart_attributes": { "table": [
       { "id": 32, "name": "Unknown_Attribute", "value": 0, "worst": 0, "thresh": 32, "when_failed": "now", "flags": { "prefailure": false }, "raw": { "value": 89289182412800, "string": "89289182412800" } },
       { "id": 88, "name": "Unknown_Attribute", "value": 68, "worst": 97, "thresh": 74, "when_failed": "now", "flags": { "prefailure": false }, "raw": { "value": 35688735929171, "string": "35688735929171" } }
     ] }
    }
    """

    private let realSATAJSON = """
    {
     "smartctl": { "version": [7, 5], "exit_status": 0 },
     "device": { "name": "/dev/disk3", "info_name": "/dev/disk3 [SAT]", "type": "sat", "protocol": "ATA" },
     "model_name": "Crucial CT1000MX500SSD1",
     "smart_status": { "passed": true },
     "ata_smart_attributes": { "table": [
       { "id": 9, "name": "Power_On_Hours", "value": 99, "worst": 99, "thresh": 0, "flags": { "prefailure": false }, "raw": { "value": 1234, "string": "1234" } },
       { "id": 5, "name": "Reallocated_Sector_Ct", "value": 100, "worst": 100, "thresh": 10, "flags": { "prefailure": true }, "raw": { "value": 0, "string": "0" } }
     ] }
    }
    """

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

    func testBytesWrittenFromNVMeDataUnits() throws {
        let json = """
        {
          "model_name": "NVMe Drive",
          "nvme_smart_health_information_log": {
            "critical_warning": 0,
            "temperature": 40,
            "available_spare": 100,
            "available_spare_threshold": 10,
            "percentage_used": 1,
            "data_units_read": 1000,
            "data_units_written": 2000
          }
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        // NVMe data units are reported in multiples of 1000 * 512 bytes.
        XCTAssertEqual(DriveUsageMetrics.bytesWritten(for: snapshot), 2000 * 512_000)
        XCTAssertEqual(DriveUsageMetrics.bytesRead(for: snapshot), 1000 * 512_000)
    }

    func testBytesWrittenFromATAAttribute() throws {
        let json = """
        {
          "model_name": "SSD",
          "logical_block_size": 512,
          "ata_smart_attributes": {
            "table": [
              {
                "id": 241,
                "name": "Total_LBAs_Written",
                "value": 100,
                "thresh": 0,
                "flags": {"prefailure": false},
                "raw": {"value": 2000000, "string": "2000000"}
              }
            ]
          }
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        XCTAssertEqual(DriveUsageMetrics.bytesWritten(for: snapshot), 2_000_000 * 512)
    }

    func testWholeDiskNameStripsPartitionAndSlice() {
        XCTAssertEqual(VolumeInfoProvider.wholeDiskName("disk3s1s1"), "disk3")
        XCTAssertEqual(VolumeInfoProvider.wholeDiskName("disk0"), "disk0")
        XCTAssertEqual(VolumeInfoProvider.wholeDiskName("disk12s4"), "disk12")
        XCTAssertEqual(VolumeInfoProvider.wholeDiskName("notadisk"), "notadisk")
    }

    // MARK: - Topología (Fusion Drive / AppleRAID)

    func testParseAPFSStoresKeepsAllPhysicalStores() {
        let plist: [String: Any] = ["AllDisksAndPartitions": [
            ["DeviceIdentifier": "disk3", "APFSPhysicalStores": [["DeviceIdentifier": "disk0s2"], ["DeviceIdentifier": "disk1s2"]]]
        ]]
        XCTAssertEqual(VolumeInfoProvider.parseAPFSStores(plist)["disk3"], ["disk0", "disk1"])
    }

    func testParseCoreStorageMapsFusionLogicalVolumeToMembers() {
        let plist: [String: Any] = ["CoreStorageLogicalVolumeGroups": [[
            "CoreStoragePhysicalVolumes": [["DeviceIdentifier": "disk0s2"], ["DeviceIdentifier": "disk1s2"]],
            "CoreStorageLogicalVolumeFamilies": [["CoreStorageLogicalVolumes": [["DeviceIdentifier": "disk2"]]]]
        ]]]
        XCTAssertEqual(VolumeInfoProvider.parseCoreStorageMembers(plist)["disk2"], ["disk0", "disk1"])
    }

    func testParseAppleRAIDMapsSetToMembers() {
        let plist: [String: Any] = ["AppleRAIDSets": [[
            "BSDName": "disk5", "Members": [["BSDName": "disk1s2"], ["BSDName": "disk2s2"]]
        ]]]
        XCTAssertEqual(VolumeInfoProvider.parseAppleRAIDMembers(plist)["disk5"], ["disk1", "disk2"])
    }

    func testPhysicalDisksExpandsAggregateElseFallsBack() {
        var fusion = VolumeInfoProvider.DiskTopology()
        fusion.apfsStores = ["disk3": ["disk2"]]
        fusion.aggregateMembers = ["disk2": ["disk0", "disk1"]]
        XCTAssertEqual(VolumeInfoProvider.physicalDisks(forContainer: "disk3", topology: fusion), ["disk0", "disk1"])

        var plain = VolumeInfoProvider.DiskTopology()
        plain.apfsStores = ["disk3": ["disk0"]]
        XCTAssertEqual(VolumeInfoProvider.physicalDisks(forContainer: "disk3", topology: plain), ["disk0"])

        // Unknown container falls back to itself.
        XCTAssertEqual(VolumeInfoProvider.physicalDisks(forContainer: "disk9", topology: VolumeInfoProvider.DiskTopology()), ["disk9"])
    }

    func testParsesATAErrorLogUnderExtended() throws {
        let json = """
        {
          "model_name": "HDD",
          "ata_smart_error_log": {"extended": {"table": [
            {"error_number": 1, "lifetime_hours": 100, "error_description": "UNC error", "prior_command": "READ DMA"}
          ]}}
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        XCTAssertEqual(snapshot.errorLog.count, 1)
        XCTAssertEqual(snapshot.errorLog.first?.errors, "UNC error")
        XCTAssertEqual(snapshot.errorLog.first?.lifetimeHours, 100)
    }

    func testPDFReportRendersValidMultiSectionDocument() throws {
        let json = """
        {
          "model_name": "Samsung SSD 990 PRO 2TB",
          "serial_number": "S6Z1NF0T900001",
          "firmware_version": "4B2QJXD7",
          "user_capacity": {"bytes": 2000398934016},
          "logical_block_size": 512,
          "rotation_rate": 0,
          "trim": {"supported": true},
          "smart_status": {"passed": true},
          "temperature": {"current": 41, "lifetime_min": 20, "lifetime_max": 63},
          "power_on_time": {"hours": 12045},
          "power_cycle_count": 431,
          "ata_smart_attributes": {"table": [
            {"id": 5, "name": "Reallocated_Sector_Ct", "value": 100, "worst": 100, "thresh": 10, "flags": {"prefailure": true}, "raw": {"value": 0, "string": "0"}},
            {"id": 9, "name": "Power_On_Hours", "value": 95, "worst": 95, "thresh": 0, "flags": {"prefailure": false}, "raw": {"value": 12045, "string": "12045"}},
            {"id": 194, "name": "Temperature_Celsius", "value": 59, "worst": 63, "thresh": 0, "flags": {"prefailure": false}, "raw": {"value": 41, "string": "41 (Min/Max 20/63)"}},
            {"id": 197, "name": "Current_Pending_Sector", "value": 100, "worst": 100, "thresh": 0, "flags": {"prefailure": false}, "raw": {"value": 0, "string": "0"}},
            {"id": 241, "name": "Total_LBAs_Written", "value": 99, "worst": 99, "thresh": 0, "flags": {"prefailure": false}, "raw": {"value": 45000000000, "string": "45000000000"}}
          ]},
          "ata_smart_error_log": {"table": [
            {"error_number": 1, "lifetime_hours": 11800, "error_description": "Error: UNC at LBA = 0x01c2f3a4", "prior_command": "READ DMA EXT"}
          ]},
          "ata_smart_self_test_log": {"standard": {"table": [
            {"num": 1, "lifetime_hours": 12000, "type": {"string": "Extended offline"}, "status": {"string": "Completed without error"}},
            {"num": 2, "lifetime_hours": 11500, "type": {"string": "Short offline"}, "status": {"string": "Completed without error"}}
          ]}}
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        let assessment = HealthEvaluator.evaluate(snapshot)
        let pdf = PDFReportBuilder.pdf(snapshot: snapshot, assessment: assessment, anonymize: false)
        XCTAssertGreaterThan(pdf.count, 1500)
        XCTAssertEqual(pdf.prefix(4), Data("%PDF".utf8))
        // Optional: write the sample somewhere for visual inspection.
        if let out = ProcessInfo.processInfo.environment["CHECKMYDISK_PDF_OUT"] {
            try pdf.write(to: URL(fileURLWithPath: out))
        }
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
