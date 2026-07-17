import Foundation
import UserNotifications

/// Posts a local notification when a drive's health state gets worse. Owns the
/// per-device "last seen" state so `DriveStore` no longer has to.
@MainActor
final class NotificationService {
    private var previousStates: [String: DriveHealthState] = [:]

    /// Notifies (when enabled) only when the new state is a worsening relative to
    /// the last state observed for this device.
    func notifyIfNeeded(device: SmartDeviceSummary, assessment: DriveAssessment, notificationsEnabled: Bool) {
        let previous = previousStates[device.id]
        previousStates[device.id] = assessment.smartStatus
        guard notificationsEnabled, Self.shouldNotify(previous: previous, new: assessment.smartStatus) else { return }

        let content = UNMutableNotificationContent()
        content.title = "CheckMyDisk: \(assessment.smartStatus.rawValue)"
        content.body = String(localized: "\(device.displayName) has \(assessment.issueCount) health issue(s).")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
    }

    /// Requests notification authorization only when the user actually wants
    /// notifications. `requestAuthorization` is idempotent: once the status is
    /// determined it returns without prompting again.
    func requestAuthorizationIfEnabled(_ enabled: Bool) {
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Worsening = strictly higher severity than before and above OK. The very
    /// first observation (no previous state) never notifies.
    static func shouldNotify(previous: DriveHealthState?, new: DriveHealthState) -> Bool {
        guard let previous else { return false }
        return new.severity > previous.severity && new.severity > DriveHealthState.ok.severity
    }
}
