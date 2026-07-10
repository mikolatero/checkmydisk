import XCTest
@testable import CheckMyDisk

/// Salida real de `smartctl -x -j` de un NVMe interno de Apple Silicon
/// (serial anonimizado). Verifica el pipeline completo parser -> evaluador
/// con datos del mundo real, incluido el exit status 4 (bit 2) que Apple
/// devuelve porque su controlador no soporta leer el error log.
final class AppleNVMeIntegrationTests: XCTestCase {
    func testRealAppleNVMeOutputEvaluatesAsHealthy() throws {
        let device = SmartDeviceSummary(name: "IOService:...", infoName: "Apple NVMe", type: "nvme", protocolName: "NVMe")
        let snapshot = try SmartctlParser.parseSnapshot(Data(appleNVMeJSON.utf8), fallbackDevice: device, exitStatus: SmartctlExitStatus(rawValue: 4))
        let assessment = HealthEvaluator.evaluate(snapshot)

        XCTAssertEqual(snapshot.modelName.isEmpty, false)
        XCTAssertEqual(snapshot.smartStatusPassed, true)
        XCTAssertNotNil(snapshot.nvme)
        XCTAssertNotNil(snapshot.temperature)
        XCTAssertFalse(snapshot.attributes.isEmpty, "los atributos sinteticos NVMe deben generarse")
        XCTAssertEqual(snapshot.messages.count, 1, "el mensaje de error del log no soportado se conserva")

        // Un disco sano no debe mostrar problemas por el bit 2 + mensaje de error.
        XCTAssertEqual(assessment.smartStatus, .ok)
        XCTAssertTrue(assessment.problems.isEmpty, "un disco sano no debe reportar problemas")
        XCTAssertGreaterThanOrEqual(assessment.overallHealth, 90)
        XCTAssertNotNil(assessment.ssdLifetimeLeft)
    }

    private let appleNVMeJSON = #"""
{
 "json_format_version": [
  1,
  0
 ],
 "smartctl": {
  "version": [
   7,
   5
  ],
  "pre_release": false,
  "svn_revision": "5714",
  "platform_info": "Darwin 25.5.0 arm64",
  "build_info": "(local build)",
  "argv": [
   "smartctl",
   "-x",
   "-j",
   "IOService:/AppleARMPE/arm-io/AppleT602xIO/ans@47400000/AppleASCWrapV4/iop-ans-nub/RTBuddy(ANS2)/RTBuddyService/AppleANS3CGv2Controller/NS_01@1"
  ],
  "messages": [
   {
    "string": "Read 1 entries from Error Information Log failed: GetLogPage failed: system=0x38, sub=0x0, code=745",
    "severity": "error"
   }
  ],
  "exit_status": 4
 },
 "local_time": {
  "time_t": 1783665881,
  "asctime": "Fri Jul 10 08:44:41 2026 CEST"
 },
 "device": {
  "name": "IOService:/AppleARMPE/arm-io/AppleT602xIO/ans@47400000/AppleASCWrapV4/iop-ans-nub/RTBuddy(ANS2)/RTBuddyService/AppleANS3CGv2Controller/NS_01@1",
  "info_name": "IOService:/AppleARMPE/arm-io/AppleT602xIO/ans@47400000/AppleASCWrapV4/iop-ans-nub/RTBuddy(ANS2)/RTBuddyService/AppleANS3CGv2Controller/NS_01@1",
  "type": "nvme",
  "protocol": "NVMe"
 },
 "model_name": "APPLE SSD AP0512Z",
 "serial_number": "REDACTED123",
 "firmware_version": "561.100.",
 "nvme_pci_vendor": {
  "id": 4203,
  "subsystem_id": 4203
 },
 "nvme_ieee_oui_identifier": 0,
 "nvme_controller_id": 0,
 "nvme_version": {
  "string": "<1.2",
  "value": 0
 },
 "nvme_number_of_namespaces": 3,
 "smart_support": {
  "available": true,
  "enabled": true
 },
 "nvme_firmware_update_capabilities": {
  "value": 2,
  "slots": 1,
  "first_slot_is_read_only": false,
  "activiation_without_reset": false,
  "multiple_update_detection": false,
  "other": 0
 },
 "nvme_optional_admin_commands": {
  "value": 4,
  "security_send_receive": false,
  "format_nvm": false,
  "firmware_download": true,
  "namespace_management": false,
  "self_test": false,
  "directives": false,
  "mi_send_receive": false,
  "virtualization_management": false,
  "doorbell_buffer_config": false,
  "get_lba_status": false,
  "command_and_feature_lockdown": false,
  "other": 0
 },
 "nvme_optional_nvm_commands": {
  "value": 4,
  "compare": false,
  "write_uncorrectable": false,
  "dataset_management": true,
  "write_zeroes": false,
  "save_select_feature_nonzero": false,
  "reservations": false,
  "timestamp": false,
  "verify": false,
  "copy": false,
  "other": 0
 },
 "nvme_log_page_attributes": {
  "value": 0,
  "smart_health_per_namespace": false,
  "commands_effects_log": false,
  "extended_get_log_page_cmd": false,
  "telemetry_log": false,
  "persistent_event_log": false,
  "supported_log_pages_log": false,
  "telemetry_data_area_4": false,
  "other": 0
 },
 "nvme_maximum_data_transfer_pages": 256,
 "nvme_power_states": [
  {
   "non_operational_state": false,
   "relative_read_latency": 0,
   "relative_read_throughput": 0,
   "relative_write_latency": 0,
   "relative_write_throughput": 0,
   "entry_latency_us": 0,
   "exit_latency_us": 0,
   "max_power": {
    "value": 0,
    "scale": 2,
    "units_per_watt": 100
   }
  }
 ],
 "smart_status": {
  "passed": true,
  "nvme": {
   "value": 0
  }
 },
 "nvme_smart_health_information_log": {
  "nsid": -1,
  "critical_warning": 0,
  "temperature": 34,
  "available_spare": 100,
  "available_spare_threshold": 99,
  "percentage_used": 3,
  "data_units_read": 482910976,
  "data_units_written": 174266959,
  "host_reads": 24032946831,
  "host_writes": 5112660008,
  "controller_busy_time": 0,
  "power_cycles": 225,
  "power_on_hours": 4961,
  "unsafe_shutdowns": 30,
  "media_errors": 0,
  "num_err_log_entries": 0
 },
 "temperature": {
  "current": 34
 },
 "spare_available": {
  "current_percent": 100,
  "threshold_percent": 99
 },
 "endurance_used": {
  "current_percent": 3
 },
 "power_cycle_count": 225,
 "power_on_time": {
  "hours": 4961
 }
}
"""#
}
