import Foundation
import ServiceManagement

/// Talks to the privileged helper daemon over XPC when it is installed and
/// enabled; otherwise reports unavailability so callers fall back to running
/// smartctl directly as the current user (the default, no-helper behaviour).
final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()
    static let daemonPlistName = "com.checkmydisk.CheckMyDiskHelper.plist"

    private var service: SMAppService { SMAppService.daemon(plistName: Self.daemonPlistName) }

    var status: SMAppService.Status { service.status }
    var isEnabled: Bool { service.status == .enabled }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }

    /// Runs smartctl through the helper when it is enabled. Returns nil when the
    /// helper is not installed/available or the connection fails — the caller then
    /// runs smartctl directly.
    func runSmartctl(arguments: [String], timeoutSeconds: Double) async -> SmartctlOutput? {
        guard isEnabled else { return nil }
        let connection = NSXPCConnection(machServiceName: smartctlHelperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SmartctlHelperProtocol.self)
        connection.resume()
        let result: SmartctlOutput? = await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in box.finish(nil) }
            guard let helper = proxy as? SmartctlHelperProtocol else {
                box.finish(nil)
                return
            }
            helper.runSmartctl(arguments: arguments, timeoutSeconds: timeoutSeconds) { stdout, stderr, status in
                box.finish(SmartctlOutput(
                    stdout: stdout,
                    stderr: String(data: stderr, encoding: .utf8) ?? "",
                    exitStatus: SmartctlExitStatus(rawValue: status)
                ))
            }
        }
        connection.invalidate()
        return result
    }
}

/// Resumes a checked continuation exactly once, safely, from either the XPC reply
/// or the connection error handler (whichever fires first).
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SmartctlOutput?, Never>?

    init(_ continuation: CheckedContinuation<SmartctlOutput?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: SmartctlOutput?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
