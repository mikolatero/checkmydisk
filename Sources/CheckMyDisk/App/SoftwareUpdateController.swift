import Combine
import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class SoftwareUpdateController {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let updaterController: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckForUpdatesObserver: AnyCancellable?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        canCheckForUpdates = updaterController.updater.canCheckForUpdates
        canCheckForUpdatesObserver = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
