import Foundation

enum SATSupportDetector {
    static func detect() async -> SATSupportStatus {
        let fileManager = FileManager.default
        let kextInstalled = fileManager.fileExists(atPath: "/Library/Extensions/SATSMARTDriver.kext") ||
            fileManager.fileExists(atPath: "/System/Library/Extensions/SATSMARTDriver.kext")
        let pluginInstalled = fileManager.fileExists(atPath: "/Library/Extensions/SATSMARTLib.plugin") ||
            fileManager.fileExists(atPath: "/System/Library/Extensions/SATSMARTLib.plugin")
        return SATSupportStatus(
            kextInstalled: kextInstalled,
            pluginInstalled: pluginInstalled,
            iokitCapableDevices: await capableDeviceCount()
        )
    }

    private static func capableDeviceCount() async -> Int {
        let ioreg = URL(fileURLWithPath: "/usr/sbin/ioreg")
        // fi_dungeon_driver_IOSATDriver is the IOKit class registered by the
        // SAT-SMART kext (kasbert/OS-X-SAT-SMART-Driver).
        let arguments = ["-r", "-w", "0", "-c", "fi_dungeon_driver_IOSATDriver"]
        guard let result = try? await ProcessRunner.run(ioreg, arguments: arguments, timeout: .seconds(10)) else {
            return 0
        }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        return text.components(separatedBy: "SATSMARTCapable").count - 1
    }
}
