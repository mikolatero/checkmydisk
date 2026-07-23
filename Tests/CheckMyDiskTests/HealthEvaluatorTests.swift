import XCTest
@testable import CheckMyDisk

final class HealthEvaluatorTests: XCTestCase {
    // MARK: - Regresión del doble conteo NVMe

    func testNVMeProblemsAreNotCountedTwice() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(nvmeWornJSON.utf8), fallbackDevice: device)
        let assessment = HealthEvaluator.evaluate(snapshot)

        // 75% de vida usada debe producir UN solo problema, no uno por el
        // atributo sintético y otro por el health log NVMe.
        let lifetimeProblems = assessment.problems.filter {
            $0.title.localizedCaseInsensitiveContains("lifetime") || $0.title.localizedCaseInsensitiveContains("Percentage Used")
        }
        XCTAssertEqual(lifetimeProblems.count, 1)
        XCTAssertEqual(assessment.problems.count, 1)
    }

    func testSyntheticAttributesAreMarked() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(nvmeWornJSON.utf8), fallbackDevice: device)
        XCTAssertTrue(snapshot.attributes.allSatisfy { $0.isSynthetic == true })
    }

    // MARK: - NVMe tras puente USB: estado UNKNOWN con aviso accionable

    func testBridgeLimitedSnapshotReportsUnknownWithActionableNote() throws {
        let base = try SmartctlParser.parseSnapshot(Data(temperatureJSON(temperature: 40).utf8), fallbackDevice: device)
        let assessment = HealthEvaluator.evaluate(base.markingBridgeLimited())

        XCTAssertEqual(assessment.smartStatus, .unknown, "no podemos leer el disco: estado desconocido, no OK/WARNING")
        XCTAssertEqual(assessment.problems.count, 1, "solo el aviso claro del puente, sin ruido genérico")
        let problem = try XCTUnwrap(assessment.problems.first)
        XCTAssertEqual(problem.state, .unknown)
        XCTAssertTrue(problem.detail.localizedCaseInsensitiveContains("USB"))
        XCTAssertTrue(problem.detail.localizedCaseInsensitiveContains("Thunderbolt"))
        XCTAssertFalse(
            assessment.problems.contains { $0.title.localizedCaseInsensitiveContains("incomplete") },
            "no debe añadirse el aviso genérico 'may be incomplete'"
        )
    }

    // MARK: - Umbrales de temperatura según tipo de disco

    func testHDDTemperatureThresholdIsLower() throws {
        var snapshot = try SmartctlParser.parseSnapshot(Data(temperatureJSON(temperature: 56).utf8), fallbackDevice: device)
        snapshot.rotationRate = 7200
        let hdd = HealthEvaluator.evaluate(snapshot)
        XCTAssertTrue(hdd.problems.contains { $0.title.localizedCaseInsensitiveContains("temperature") })

        snapshot.rotationRate = 0
        let ssd = HealthEvaluator.evaluate(snapshot)
        XCTAssertFalse(ssd.problems.contains { $0.title.localizedCaseInsensitiveContains("temperature") })
    }

    func testSSDTemperatureWarningAt70() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(temperatureJSON(temperature: 70).utf8), fallbackDevice: device)
        let assessment = HealthEvaluator.evaluate(snapshot)
        XCTAssertTrue(assessment.problems.contains { $0.state == .warning })
    }

    /// Regresión: la temperatura tiene su propio medidor y su penalización aparte;
    /// un NVMe sano simplemente templado (50 °C) no debe hundir el "Health %".
    func testWarmButHealthyNVMeKeepsFullHealth() throws {
        let json = """
        {
          "model_name": "Healthy NVMe",
          "smart_status": {"passed": true},
          "nvme_smart_health_information_log": {
            "critical_warning": 0,
            "temperature": 50,
            "available_spare": 100,
            "available_spare_threshold": 10,
            "percentage_used": 0,
            "media_errors": 0,
            "num_err_log_entries": 0
          }
        }
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        let assessment = HealthEvaluator.evaluate(snapshot)
        XCTAssertEqual(assessment.smartStatus, .ok)
        XCTAssertTrue(assessment.problems.isEmpty)
        XCTAssertEqual(assessment.overallHealth, 100)
    }

    // MARK: - Exit status de smartctl

    func testDiskFailingExitBitBecomesFailedProblem() throws {
        let snapshot = try SmartctlParser.parseSnapshot(
            Data(temperatureJSON(temperature: 30).utf8),
            fallbackDevice: device,
            exitStatus: .diskFailing
        )
        let assessment = HealthEvaluator.evaluate(snapshot)
        XCTAssertEqual(assessment.smartStatus, .failed)
    }

    func testDeviceOpenFailedWithoutDataBecomesWarning() throws {
        // Sin smart_status ni atributos: la lectura falló de verdad.
        let snapshot = try SmartctlParser.parseSnapshot(
            Data(#"{"model_name": "Unreachable"}"#.utf8),
            fallbackDevice: device,
            exitStatus: .deviceOpenFailed
        )
        let assessment = HealthEvaluator.evaluate(snapshot)
        XCTAssertTrue(assessment.problems.contains { $0.state == .warning })
    }

    func testOptionalCommandFailureOnHealthyDriveIsNotAProblem() throws {
        // Caso real: el NVMe interno de Apple devuelve bit 2 porque no soporta
        // leer el error log, pero el estado SMART y el health log llegan bien.
        let snapshot = try SmartctlParser.parseSnapshot(
            Data(temperatureJSON(temperature: 30).utf8),
            fallbackDevice: device,
            exitStatus: .smartCommandFailed
        )
        let assessment = HealthEvaluator.evaluate(snapshot)
        XCTAssertEqual(assessment.smartStatus, .ok)
        XCTAssertTrue(assessment.problems.isEmpty)
    }

    func testFatalBitsDetection() {
        XCTAssertTrue(SmartctlExitStatus.deviceOpenFailed.hasFatalBits)
        XCTAssertTrue(SmartctlExitStatus(rawValue: 0b0000_0110).hasFatalBits)
        XCTAssertFalse(SmartctlExitStatus.diskFailing.hasFatalBits)
        XCTAssertFalse(SmartctlExitStatus(rawValue: 0b1111_1000).hasFatalBits)
    }

    // MARK: - Mensajes y when_failed

    func testErrorMessagesBecomeProblems() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(messagesJSON.utf8), fallbackDevice: device)
        let assessment = HealthEvaluator.evaluate(snapshot)
        XCTAssertTrue(assessment.problems.contains { $0.detail.contains("Read Device Identity failed") })
    }

    func testWhenFailedNowBecomesFailedProblem() throws {
        let snapshot = try SmartctlParser.parseSnapshot(Data(whenFailedJSON.utf8), fallbackDevice: device)
        let assessment = HealthEvaluator.evaluate(snapshot)
        XCTAssertTrue(assessment.problems.contains { $0.state == .failed })
    }

    // MARK: - Notificaciones

    @MainActor
    func testShouldNotifyRules() {
        XCTAssertFalse(NotificationService.shouldNotify(previous: nil, new: .failed), "primer estado no notifica")
        XCTAssertFalse(NotificationService.shouldNotify(previous: .unknown, new: .ok), "unknown → ok no es un empeoramiento")
        XCTAssertTrue(NotificationService.shouldNotify(previous: .unknown, new: .warning))
        XCTAssertTrue(NotificationService.shouldNotify(previous: .ok, new: .warning))
        XCTAssertTrue(NotificationService.shouldNotify(previous: .warning, new: .failed))
        XCTAssertFalse(NotificationService.shouldNotify(previous: .warning, new: .ok), "mejorar no notifica")
        XCTAssertFalse(NotificationService.shouldNotify(previous: .failed, new: .failed))
    }

    // MARK: - Tendencias (TrendAnalyzer)

    func testDeltaDetectsCriticalRawIncrease() throws {
        let previous = try SmartctlParser.parseSnapshot(Data(ataSnapshotJSON(reallocated: 0).utf8), fallbackDevice: device)
        let current = try SmartctlParser.parseSnapshot(Data(ataSnapshotJSON(reallocated: 3).utf8), fallbackDevice: device)
        let deltas = TrendAnalyzer.deltas(current: current, previous: previous)
        let reallocated = try XCTUnwrap(deltas.first { $0.name == "Reallocated_Sector_Ct" })
        XCTAssertEqual(reallocated.change, 3)
        XCTAssertTrue(reallocated.isCritical)
        // Power_On_Hours no cambió, así que no debe aparecer.
        XCTAssertFalse(deltas.contains { $0.name == "Power_On_Hours" })
    }

    func testCriticalIncreasesOnlyReturnsGrowingCritical() throws {
        let previous = try SmartctlParser.parseSnapshot(Data(ataSnapshotJSON(reallocated: 5).utf8), fallbackDevice: device)
        let current = try SmartctlParser.parseSnapshot(Data(ataSnapshotJSON(reallocated: 8).utf8), fallbackDevice: device)
        let increases = TrendAnalyzer.criticalIncreases(current: current, previous: previous)
        XCTAssertEqual(increases.count, 1)
        XCTAssertEqual(increases.first?.name, "Reallocated_Sector_Ct")
        // Sin retroceso: si baja (improbable), no cuenta como incremento crítico.
        XCTAssertTrue(TrendAnalyzer.criticalIncreases(current: previous, previous: current).isEmpty)
    }

    func testRemainingLifeEstimateForDecliningWear() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<10).map { day in
            HistoryPoint(date: start.addingTimeInterval(Double(day) * 86_400), state: .ok, temperature: 40, health: 100, performance: 100, lifetime: 100 - day)
        }
        let estimate = try XCTUnwrap(TrendAnalyzer.estimateRemainingLife(from: points, asOf: start.addingTimeInterval(9 * 86_400)))
        XCTAssertTrue((88...93).contains(estimate.daysRemaining), "daysRemaining inesperado: \(estimate.daysRemaining)")
    }

    func testRemainingLifeNilWhenFlat() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<10).map { day in
            HistoryPoint(date: start.addingTimeInterval(Double(day) * 86_400), state: .ok, temperature: 40, health: 100, performance: 100, lifetime: 95)
        }
        XCTAssertNil(TrendAnalyzer.estimateRemainingLife(from: points, asOf: start.addingTimeInterval(9 * 86_400)))
    }

    func testNVMeErrorLogEntriesIsNotFlaggedCritical() throws {
        func nvmeJSON(media: Int, errLog: Int) -> String {
            """
            {"model_name":"NVMe","smart_status":{"passed":true},
             "nvme_smart_health_information_log":{"critical_warning":0,"temperature":35,"available_spare":100,"available_spare_threshold":10,"percentage_used":1,"media_errors":\(media),"num_err_log_entries":\(errLog),"power_on_hours":10,"power_cycles":2,"data_units_read":1,"data_units_written":1}}
            """
        }
        let previous = try SmartctlParser.parseSnapshot(Data(nvmeJSON(media: 0, errLog: 0).utf8), fallbackDevice: device)
        let current = try SmartctlParser.parseSnapshot(Data(nvmeJSON(media: 1, errLog: 5).utf8), fallbackDevice: device)
        let increases = TrendAnalyzer.criticalIncreases(current: current, previous: previous)
        XCTAssertTrue(increases.contains { $0.name == "Media Errors" })
        XCTAssertFalse(increases.contains { $0.name == "Error Log Entries" }, "un error-log NVMe benigno no debe marcarse como crítico")
    }

    func testNVMeMediaErrorsReducePerformance() throws {
        let json = """
        {"model_name":"NVMe","smart_status":{"passed":true},
         "nvme_smart_health_information_log":{"critical_warning":0,"temperature":35,"available_spare":100,"available_spare_threshold":10,"percentage_used":1,"media_errors":3,"num_err_log_entries":0}}
        """
        let snapshot = try SmartctlParser.parseSnapshot(Data(json.utf8), fallbackDevice: device)
        let assessment = HealthEvaluator.evaluate(snapshot)
        XCTAssertLessThanOrEqual(assessment.overallPerformance, 60, "media errors deben restar rendimiento con independencia del idioma")
    }

    private func ataSnapshotJSON(reallocated: Int) -> String {
        """
        {
          "model_name": "SSD",
          "smart_status": {"passed": true},
          "ata_smart_attributes": {
            "table": [
              {"id": 5, "name": "Reallocated_Sector_Ct", "value": 100, "thresh": 10, "flags": {"prefailure": true}, "raw": {"value": \(reallocated), "string": "\(reallocated)"}},
              {"id": 9, "name": "Power_On_Hours", "value": 100, "thresh": 0, "flags": {"prefailure": false}, "raw": {"value": 1000, "string": "1000"}}
            ]
          }
        }
        """
    }

    // MARK: - Programador de self-tests (SelfTestScheduler)

    func testScheduledNotDueWithoutBaseline() {
        var settings = AppSettings()
        settings.scheduledSelfTestsEnabled = true
        XCTAssertFalse(SelfTestScheduler.isDue(last: nil, intervalDays: 7, now: Date()))
        XCTAssertNil(SelfTestScheduler.kindDue(settings: settings, lastShort: nil, lastLong: nil, now: Date()))
    }

    func testScheduledShortDueAfterInterval() {
        var settings = AppSettings()
        settings.scheduledSelfTestsEnabled = true
        settings.shortTestIntervalDays = 7
        settings.longTestIntervalDays = 0
        let now = Date()
        XCTAssertEqual(SelfTestScheduler.kindDue(settings: settings, lastShort: now.addingTimeInterval(-8 * 86_400), lastLong: nil, now: now), "short")
        XCTAssertNil(SelfTestScheduler.kindDue(settings: settings, lastShort: now.addingTimeInterval(-6 * 86_400), lastLong: nil, now: now))
    }

    func testScheduledPrefersLongWhenBothDue() {
        var settings = AppSettings()
        settings.scheduledSelfTestsEnabled = true
        settings.shortTestIntervalDays = 7
        settings.longTestIntervalDays = 30
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        XCTAssertEqual(SelfTestScheduler.kindDue(settings: settings, lastShort: old, lastLong: old, now: now), "long")
    }

    func testScheduledDisabledReturnsNil() {
        let settings = AppSettings() // scheduledSelfTestsEnabled = false por defecto
        XCTAssertNil(SelfTestScheduler.kindDue(settings: settings, lastShort: nil, lastLong: nil, now: Date()))
    }

    // MARK: - Fixtures

    private var device: SmartDeviceSummary {
        SmartDeviceSummary(name: "/dev/disk0", infoName: "/dev/disk0", type: "nvme", protocolName: "NVMe")
    }

    private let nvmeWornJSON = """
    {
      "model_name": "Worn SSD",
      "serial_number": "WORN123",
      "smart_status": {"passed": true},
      "nvme_smart_health_information_log": {
        "critical_warning": 0,
        "temperature": 35,
        "available_spare": 100,
        "available_spare_threshold": 10,
        "percentage_used": 75,
        "media_errors": 0,
        "num_err_log_entries": 0,
        "power_on_hours": 100,
        "power_cycles": 50,
        "unsafe_shutdowns": 2,
        "data_units_read": 1000,
        "data_units_written": 2000
      }
    }
    """

    private func temperatureJSON(temperature: Int) -> String {
        """
        {
          "model_name": "Test Drive",
          "smart_status": {"passed": true},
          "temperature": {"current": \(temperature)}
        }
        """
    }

    private let messagesJSON = """
    {
      "smartctl": {
        "messages": [
          {"severity": "error", "string": "Read Device Identity failed: something"}
        ]
      },
      "model_name": "Test Drive"
    }
    """

    private let whenFailedJSON = """
    {
      "model_name": "Test Drive",
      "smart_status": {"passed": true},
      "ata_smart_attributes": {
        "table": [
          {
            "id": 3,
            "name": "Spin_Up_Time",
            "value": 95,
            "worst": 60,
            "thresh": 0,
            "when_failed": "FAILING_NOW",
            "flags": {"prefailure": true},
            "raw": {"value": 0, "string": "0"}
          }
        ]
      }
    }
    """
}
