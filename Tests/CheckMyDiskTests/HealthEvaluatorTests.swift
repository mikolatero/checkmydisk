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
