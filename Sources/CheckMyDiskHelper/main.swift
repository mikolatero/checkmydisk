import Foundation

// Privileged helper daemon: vends an XPC service that runs smartctl as root so
// CheckMyDisk can read SATA/USB drives that require elevated access. Registered by
// the app via SMAppService.daemon; runs under launchd.
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: smartctlHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
