import Foundation

/// Owns the self-test lifecycle (start / cancel) and the polling loop that watches
/// a running test to completion. It writes back to `DriveStore` through closures so
/// the store keeps the observable flags the UI reads, without this type holding a
/// strong reference back to the store.
@MainActor
final class SelfTestCoordinator {
    private var pollingTask: Task<Void, Never>?
    private var activeKind: [String: String] = [:]

    private let runner: SmartctlRunner
    private let refreshAction: () async -> Void
    private let snapshotProvider: (String) -> DriveSnapshot?
    private let setPolling: (Bool) -> Void
    private let reportError: (String, String) -> Void

    init(
        runner: SmartctlRunner,
        refreshAction: @escaping () async -> Void,
        snapshotProvider: @escaping (String) -> DriveSnapshot?,
        setPolling: @escaping (Bool) -> Void,
        reportError: @escaping (String, String) -> Void
    ) {
        self.runner = runner
        self.refreshAction = refreshAction
        self.snapshotProvider = snapshotProvider
        self.setPolling = setPolling
        self.reportError = reportError
    }

    func kind(for deviceID: String) -> String? {
        activeKind[deviceID]
    }

    func start(kind: String, device: SmartDeviceSummary) async {
        let deviceID = device.id
        setPolling(true)
        do {
            try await runner.startSelfTest(device: device, kind: kind)
            activeKind[deviceID] = kind
            await refreshAction()
            let estimatedMinutes = snapshotProvider(deviceID)?.activeSelfTest?.estimatedMinutes(forKind: kind)
                ?? (kind == "short" ? 2 : 90)
            startPolling(for: deviceID, minimumPolls: max(3, estimatedMinutes * 60 / 10))
        } catch {
            setPolling(false)
            reportError(deviceID, error.localizedDescription)
        }
    }

    func cancel(device: SmartDeviceSummary) async {
        let deviceID = device.id
        do {
            try await runner.abortSelfTest(device: device)
            pollingTask?.cancel()
            setPolling(false)
            activeKind[deviceID] = nil
            await refreshAction()
        } catch {
            reportError(deviceID, error.localizedDescription)
        }
    }

    private func startPolling(for deviceID: String, minimumPolls: Int) {
        pollingTask?.cancel()
        setPolling(true)
        let maxPolls = max(180, minimumPolls * 3)
        pollingTask = Task { [weak self] in
            var sawRunningStatus = false
            for pollIndex in 0..<maxPolls {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                await self.refreshAction()
                let stillRunning = self.snapshotProvider(deviceID)?.activeSelfTest?.isRunning == true
                sawRunningStatus = sawRunningStatus || stillRunning
                if !stillRunning, sawRunningStatus || pollIndex >= minimumPolls {
                    break
                }
            }
            guard let self else { return }
            self.setPolling(false)
            self.activeKind[deviceID] = nil
        }
    }
}
