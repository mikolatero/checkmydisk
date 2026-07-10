import XCTest
@testable import CheckMyDisk

final class ProcessRunnerTests: XCTestCase {
    // Con >64KB el patrón antiguo (waitUntilExit antes de leer) se bloqueaba.
    func testLargeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "262144", "/dev/zero"],
            timeout: .seconds(20)
        )
        XCTAssertEqual(result.stdout.count, 262_144)
        XCTAssertEqual(result.status, 0)
    }

    func testTimeoutTerminatesHangingProcess() async {
        let start = Date()
        do {
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                timeout: .seconds(1)
            )
            XCTFail("Expected a timeout error")
        } catch is ProcessRunnerError {
            // 1s timeout + 2s de gracia; con margen amplio para CI.
            XCTAssertLessThan(Date().timeIntervalSince(start), 15)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCapturesExitStatusAndStderr() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err 1>&2; exit 5"],
            timeout: .seconds(10)
        )
        XCTAssertEqual(result.status, 5)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "out\n")
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "err\n")
    }

    func testCancellationKillsChildProcess() async throws {
        let task = Task {
            try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                timeout: .seconds(120)
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let start = Date()
        _ = try? await task.value
        // Si la cancelación no matase al hijo, esperaríamos los 60s del sleep.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
