import Foundation

/// Mach service this daemon vends. Must match the app's copy by @objc selector so
/// XPC resolves across the two binaries.
let smartctlHelperMachServiceName = "com.checkmydisk.CheckMyDiskHelper"

@objc protocol SmartctlHelperProtocol {
    func runSmartctl(arguments: [String], timeoutSeconds: Double, reply: @escaping (Data, Data, Int32) -> Void)
}
