import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SmartctlHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

/// Runs smartctl (only smartctl — never an arbitrary binary) with the caller's
/// arguments and returns its output. Reads stdout/stderr concurrently so a full
/// pipe cannot deadlock the child, and enforces a timeout.
final class HelperService: NSObject, SmartctlHelperProtocol {
    func runSmartctl(arguments: [String], timeoutSeconds: Double, reply: @escaping (Data, Data, Int32) -> Void) {
        guard let smartctl = Self.resolveSmartctl() else {
            reply(Data(), Data("smartctl not found".utf8), -1)
            return
        }

        let process = Process()
        process.executableURL = smartctl
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            reply(Data(), Data("failed to launch smartctl: \(error.localizedDescription)".utf8), -1)
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(1, timeoutSeconds)) {
            if process.isRunning { process.terminate() }
        }

        var stdout = Data()
        var stderr = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        group.wait()
        reply(stdout, stderr, process.terminationStatus)
    }

    /// Locates smartctl: the app's bundled copy (relative to this daemon inside the
    /// bundle) first, then common system locations.
    private static func resolveSmartctl() -> URL? {
        var candidates: [URL] = []
        if let executable = CommandLine.arguments.first, !executable.isEmpty {
            let contents = URL(fileURLWithPath: executable)
                .deletingLastPathComponent()  // Contents/MacOS
                .deletingLastPathComponent()  // Contents
            candidates.append(contents.appendingPathComponent("Resources/Smartctl/smartctl"))
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/smartctl"),
            URL(fileURLWithPath: "/usr/local/bin/smartctl"),
            URL(fileURLWithPath: "/usr/sbin/smartctl"),
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
