import Foundation

/// Mach service the privileged helper daemon vends. Kept identical (by @objc
/// selector) in the daemon target so XPC matches across the two binaries.
let smartctlHelperMachServiceName = "com.checkmydisk.CheckMyDiskHelper"

/// XPC surface of the privileged helper: it only ever runs smartctl as root.
@objc protocol SmartctlHelperProtocol {
    func runSmartctl(arguments: [String], timeoutSeconds: Double, reply: @escaping (Data, Data, Int32) -> Void)
}
