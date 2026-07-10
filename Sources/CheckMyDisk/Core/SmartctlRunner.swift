import Foundation

enum SmartctlError: Error, LocalizedError {
    case executableNotFound
    case failed(arguments: [String], status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return String(localized: "No smartctl executable was found. Install smartmontools or add a bundled smartctl resource.")
        case let .failed(arguments, status, stderr):
            return String(localized: "smartctl \(arguments.joined(separator: " ")) failed with status \(status): \(stderr)")
        }
    }
}

/// smartctl's exit code is a bitmask, not a scalar. Bits 0-2 signal that the run
/// itself went wrong; bits 3-7 carry drive-health information and must not be
/// treated as command failures.
struct SmartctlExitStatus: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int32

    static let commandLineParseError = SmartctlExitStatus(rawValue: 1 << 0)
    static let deviceOpenFailed = SmartctlExitStatus(rawValue: 1 << 1)
    static let smartCommandFailed = SmartctlExitStatus(rawValue: 1 << 2)
    static let diskFailing = SmartctlExitStatus(rawValue: 1 << 3)
    static let prefailAttributesBelowThreshold = SmartctlExitStatus(rawValue: 1 << 4)
    static let attributesBelowThresholdInPast = SmartctlExitStatus(rawValue: 1 << 5)
    static let errorLogContainsErrors = SmartctlExitStatus(rawValue: 1 << 6)
    static let selfTestLogContainsErrors = SmartctlExitStatus(rawValue: 1 << 7)

    static let fatalBits: SmartctlExitStatus = [.commandLineParseError, .deviceOpenFailed, .smartCommandFailed]

    var hasFatalBits: Bool {
        !intersection(Self.fatalBits).isEmpty
    }
}

struct SmartctlOutput {
    let stdout: Data
    let stderr: String
    let exitStatus: SmartctlExitStatus
}

struct SmartctlExecutable: Equatable {
    let url: URL
    let source: String
}

final class SmartctlRunner: @unchecked Sendable {
    private let settingsProvider: @Sendable () -> AppSettings

    init(settingsProvider: @escaping @Sendable () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    func scan() async throws -> [SmartDeviceSummary] {
        let output = try await run(["--scan", "-j"])
        return try SmartctlParser.parseScan(parseableData(from: output, arguments: ["--scan", "-j"]))
    }

    func readAll(device: SmartDeviceSummary) async throws -> DriveSnapshot {
        let arguments = ["-x", "-j", device.name]
        do {
            let output = try await run(arguments)
            return try parseSnapshot(output, arguments: arguments, device: device)
        } catch let error as SmartctlError {
            // Many USB enclosures only answer through SAT pass-through.
            guard case .failed = error, shouldRetryWithSAT(device) else { throw error }
            let satArguments = ["-d", "sat", "-x", "-j", device.name]
            guard let output = try? await run(satArguments),
                  let snapshot = try? parseSnapshot(output, arguments: satArguments, device: device) else {
                throw error
            }
            return snapshot
        }
    }

    private func shouldRetryWithSAT(_ device: SmartDeviceSummary) -> Bool {
        let type = device.type.lowercased()
        return type != "nvme" && !type.contains("sat")
    }

    func startSelfTest(device: SmartDeviceSummary, kind: String) async throws {
        let arguments = ["-t", kind, device.name]
        let output = try await run(arguments, timeoutSeconds: 60)
        if output.exitStatus.hasFatalBits {
            throw SmartctlError.failed(arguments: arguments, status: output.exitStatus.rawValue, stderr: output.stderr)
        }
    }

    func abortSelfTest(device: SmartDeviceSummary) async throws {
        let arguments = ["-X", device.name]
        _ = try await run(arguments, timeoutSeconds: 60)
    }

    private func parseSnapshot(_ output: SmartctlOutput, arguments: [String], device: SmartDeviceSummary) throws -> DriveSnapshot {
        try SmartctlParser.parseSnapshot(
            parseableData(from: output, arguments: arguments),
            fallbackDevice: device,
            exitStatus: output.exitStatus
        )
    }

    /// smartctl often exits with fatal bits set while still emitting a useful JSON
    /// document (typical for USB bridges). Only give up when there is no JSON at all.
    private func parseableData(from output: SmartctlOutput, arguments: [String]) throws -> Data {
        if output.exitStatus.hasFatalBits, !looksLikeJSON(output.stdout) {
            throw SmartctlError.failed(arguments: arguments, status: output.exitStatus.rawValue, stderr: output.stderr)
        }
        return output.stdout
    }

    private func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\n") && $0 != UInt8(ascii: "\t") }) else {
            return false
        }
        return first == UInt8(ascii: "{")
    }

    func resolvedExecutable() -> SmartctlExecutable? {
        let settings = settingsProvider()
        let bundled = bundledCandidates()
        let homebrew = [
            URL(fileURLWithPath: "/opt/homebrew/bin/smartctl"),
            URL(fileURLWithPath: "/usr/local/bin/smartctl"),
            URL(fileURLWithPath: "/usr/sbin/smartctl")
        ]
        let custom = settings.customSmartctlPath.isEmpty ? [] : [URL(fileURLWithPath: settings.customSmartctlPath)]

        let ordered: [(URL, String)]
        switch settings.smartctlMode {
        case .bundledFirst:
            ordered = bundled.map { ($0, "Bundled") } + homebrew.map { ($0, "Homebrew/System") } + custom.map { ($0, "Custom") }
        case .homebrewFirst:
            ordered = homebrew.map { ($0, "Homebrew/System") } + bundled.map { ($0, "Bundled") } + custom.map { ($0, "Custom") }
        case .customPath:
            ordered = custom.map { ($0, "Custom") } + bundled.map { ($0, "Bundled") } + homebrew.map { ($0, "Homebrew/System") }
        }

        for (url, source) in ordered where FileManager.default.isExecutableFile(atPath: url.path) {
            return SmartctlExecutable(url: url, source: source)
        }
        return nil
    }

    private func bundledCandidates() -> [URL] {
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: "smartctl", withExtension: nil, subdirectory: "Smartctl") {
            urls.append(url)
        }
        if let url = Bundle.main.url(forResource: "smartctl", withExtension: nil) {
            urls.append(url)
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Smartctl/smartctl") {
            urls.append(url)
        }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "smartctl", withExtension: nil, subdirectory: "Smartctl") {
            urls.append(url)
        }
        if let url = Bundle.module.url(forResource: "smartctl", withExtension: nil) {
            urls.append(url)
        }
        #endif
        return urls
    }

    private func run(_ arguments: [String], timeoutSeconds: Double? = nil) async throws -> SmartctlOutput {
        guard let executable = resolvedExecutable() else {
            throw SmartctlError.executableNotFound
        }
        let settings = settingsProvider()
        let timeout = timeoutSeconds ?? max(5, settings.commandTimeoutSeconds)
        let result = try await ProcessRunner.run(executable.url, arguments: arguments, timeout: .seconds(timeout))
        return SmartctlOutput(
            stdout: result.stdout,
            stderr: String(data: result.stderr, encoding: .utf8) ?? "",
            exitStatus: SmartctlExitStatus(rawValue: result.status)
        )
    }
}
