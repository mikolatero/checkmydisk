import Foundation

struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

enum ProcessRunnerError: Error, LocalizedError {
    case timedOut(command: String, seconds: Double)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, seconds):
            return String(localized: "\(command) did not finish within \(Int(seconds)) seconds and was terminated.")
        }
    }
}

/// Runs an external process reading stdout/stderr concurrently (so large outputs
/// cannot deadlock the child), with a hard timeout and cooperative cancellation.
enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String], timeout: Duration = .seconds(30)) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let box = ProcessBox(process: process)
        let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        let timeoutSeconds = Double(timeout.components.seconds)

        return try await withTaskCancellationHandler {
            // Readers must be draining before we wait for exit: a full pipe buffer
            // would otherwise block the child forever.
            async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
            async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

            do {
                try box.launch()
            } catch {
                // The child never ran, so nothing will close the write ends; close
                // them ourselves or the readers above would never see EOF.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                throw error
            }

            let status = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { await box.waitForExit() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    box.markTimedOut()
                    box.terminate()
                    try? await Task.sleep(for: .seconds(2))
                    box.forceKill()
                    throw CancellationError()
                }
                let status = try await group.next()!
                group.cancelAll()
                return status
            }

            let stdout = await stdoutData
            let stderr = await stderrData

            if box.didTimeOut {
                throw ProcessRunnerError.timedOut(command: command, seconds: timeoutSeconds)
            }
            try Task.checkCancellation()
            return ProcessResult(stdout: stdout, stderr: stderr, status: status)
        } onCancel: {
            box.terminate()
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}

/// Wraps Process so it can be touched from concurrent contexts. The termination
/// handler is installed before launch, so an exit can never be missed.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?
    private var timedOut = false

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] finished in
            self?.handleExit(finished.terminationStatus)
        }
    }

    func launch() throws {
        try process.run()
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { newContinuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                newContinuation.resume(returning: exitStatus)
            } else {
                continuation = newContinuation
                lock.unlock()
            }
        }
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    func forceKill() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func handleExit(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: status)
    }
}
