import Foundation

enum HealthEvaluator {
    static func evaluate(_ snapshot: DriveSnapshot) -> DriveAssessment {
        var problems: [HealthProblem] = []

        if snapshot.smartStatusPassed == false {
            problems.append(.init(
                title: String(localized: "Built-in SMART status failed"),
                state: .failed,
                detail: String(localized: "The drive firmware reports a failing SMART state. Back up important data now.")
            ))
        }

        // Synthetic attributes mirror the NVMe health log evaluated below; counting
        // them here again would double the penalty for the same condition.
        for attribute in snapshot.attributes where attribute.isSynthetic != true {
            if attribute.status.severity > DriveHealthState.ok.severity {
                problems.append(.init(
                    title: attribute.name,
                    state: attribute.status,
                    detail: String(localized: "Raw value \(attribute.rawValue) is outside the expected range for this indicator.")
                ))
            }
            if let whenFailed = attribute.whenFailed, !whenFailed.isEmpty, attribute.status.severity <= DriveHealthState.ok.severity {
                problems.append(.init(
                    title: attribute.name,
                    state: whenFailed.lowercased().contains("now") ? .failed : .warning,
                    detail: String(localized: "The drive reports this attribute as failed (\(whenFailed)).")
                ))
            }
        }

        if let nvme = snapshot.nvme {
            if let warning = nvme.criticalWarning, warning != 0 {
                problems.append(.init(
                    title: String(localized: "NVMe critical warning"),
                    state: .failed,
                    detail: String(localized: "The NVMe critical warning bitmask is \(warning).")
                ))
            }
            if let mediaErrors = nvme.mediaErrors, mediaErrors > 0 {
                problems.append(.init(
                    title: String(localized: "NVMe media errors"),
                    state: .failing,
                    detail: String(localized: "\(mediaErrors) media/data integrity errors have been reported.")
                ))
            }
            if let spare = nvme.availableSpare, let threshold = nvme.availableSpareThreshold, spare <= threshold {
                problems.append(.init(
                    title: String(localized: "Available spare below threshold"),
                    state: .failed,
                    detail: String(localized: "Available spare is \(spare)% and threshold is \(threshold)%.")
                ))
            }
            if let used = nvme.percentageUsed, used >= 70 {
                let state: DriveHealthState = used >= 100 ? .failed : used >= 90 ? .failing : .warning
                problems.append(.init(
                    title: String(localized: "SSD lifetime consumed"),
                    state: state,
                    detail: String(localized: "The drive reports \(used)% lifetime used.")
                ))
            }
        }

        let thresholds = temperatureThresholds(for: snapshot)
        if let temperature = snapshot.temperature, temperature >= thresholds.warning {
            problems.append(.init(
                title: String(localized: "High temperature"),
                state: temperature >= thresholds.failing ? .failing : .warning,
                detail: String(localized: "Current temperature is \(temperature) °C.")
            ))
        }

        problems.append(contentsOf: exitStatusProblems(snapshot))
        problems.append(contentsOf: messageProblems(snapshot))

        let smartState = strongestState(in: problems) ?? (snapshot.smartStatusPassed == true ? .ok : .unknown)
        let health = calculateHealth(snapshot: snapshot, problems: problems)
        let performance = calculatePerformance(snapshot: snapshot, problems: problems)
        let lifetime = calculateLifetime(snapshot: snapshot)

        return DriveAssessment(
            smartStatus: smartState,
            overallHealth: health,
            overallPerformance: performance,
            ssdLifetimeLeft: lifetime,
            problems: problems
        )
    }

    /// Spinning drives run hotter into trouble sooner than SSDs.
    static func temperatureThresholds(for snapshot: DriveSnapshot) -> (warning: Int, failing: Int) {
        snapshot.isRotational == true ? (55, 65) : (70, 85)
    }

    private static func exitStatusProblems(_ snapshot: DriveSnapshot) -> [HealthProblem] {
        guard let status = snapshot.exitStatus else { return [] }
        var problems: [HealthProblem] = []
        if status.contains(.diskFailing) {
            problems.append(.init(
                title: String(localized: "smartctl reports the disk as failing"),
                state: .failed,
                detail: String(localized: "The smartctl exit status has the DISK FAILING bit set. Back up important data now.")
            ))
        }
        if status.contains(.prefailAttributesBelowThreshold) {
            problems.append(.init(
                title: String(localized: "Pre-fail attributes below threshold"),
                state: .failing,
                detail: String(localized: "One or more pre-fail attributes are at or below their failure threshold.")
            ))
        }
        if status.contains(.attributesBelowThresholdInPast) {
            problems.append(.init(
                title: String(localized: "Attributes were below threshold in the past"),
                state: .warning,
                detail: String(localized: "Some attributes have been at or below their threshold at some point in the drive's life.")
            ))
        }
        // Bit 1/2 also fire when an *optional* sub-command fails (e.g. Apple's
        // internal NVMe rejects reading the error log). Only flag the drive when
        // not even the basic SMART status could be read; otherwise the failure
        // details are already visible in the messages section.
        let couldReadBasics = snapshot.smartStatusPassed != nil || snapshot.nvme != nil || !snapshot.attributes.isEmpty
        if (status.contains(.deviceOpenFailed) || status.contains(.smartCommandFailed)) && !couldReadBasics {
            problems.append(.init(
                title: String(localized: "SMART data may be incomplete"),
                state: .warning,
                detail: String(localized: "smartctl could not fully talk to this device; some values may be missing or stale.")
            ))
        }
        return problems
    }

    private static func messageProblems(_ snapshot: DriveSnapshot) -> [HealthProblem] {
        // Error messages describe tooling/communication issues, not drive health.
        // They only become problems when the basic health data is missing too;
        // either way they stay visible in the Dashboard's messages section.
        let couldReadBasics = snapshot.smartStatusPassed != nil || snapshot.nvme != nil || !snapshot.attributes.isEmpty
        guard !couldReadBasics else { return [] }
        return snapshot.messages
            .filter { $0.severity.lowercased() == "error" && !$0.text.isEmpty }
            .map { message in
                HealthProblem(
                    title: String(localized: "smartctl reported an error"),
                    state: .warning,
                    detail: message.text
                )
            }
    }

    private static func strongestState(in problems: [HealthProblem]) -> DriveHealthState? {
        problems.map(\.state).max { $0.severity < $1.severity }
    }

    private static func calculateHealth(snapshot: DriveSnapshot, problems: [HealthProblem]) -> Int {
        if snapshot.smartStatusPassed == false { return 0 }
        let worstAttribute = snapshot.attributes.compactMap(\.percent).min() ?? 100
        let penalty = problems.reduce(0) { sum, problem in
            switch problem.state {
            case .failed: sum + 60
            case .failing: sum + 35
            case .warning: sum + 15
            case .ok, .unknown: sum
            }
        }
        return max(0, min(100, min(worstAttribute, 100 - penalty)))
    }

    private static func calculatePerformance(snapshot: DriveSnapshot, problems: [HealthProblem]) -> Int {
        var score = 100
        if let temperature = snapshot.temperature {
            let comfortable = snapshot.isRotational == true ? 45 : 55
            score -= max(0, temperature - comfortable)
        }
        if problems.contains(where: { $0.title.localizedCaseInsensitiveContains("media errors") }) {
            score -= 40
        }
        if snapshot.attributes.contains(where: { [188, 199].contains($0.id) && $0.isSynthetic != true && $0.status != .ok }) {
            score -= 20
        }
        return max(0, min(100, score))
    }

    private static func calculateLifetime(snapshot: DriveSnapshot) -> Int? {
        if let used = snapshot.nvme?.percentageUsed {
            return max(0, min(100, 100 - used))
        }
        let lifetimeAttributeNames = [
            "Percentage Used",
            "Media Wearout Indicator",
            "Wear Leveling Count",
            "SSD Life Left",
            "Remaining Life",
            "Percent Lifetime Used"
        ]
        for attribute in snapshot.attributes {
            if lifetimeAttributeNames.contains(where: { attribute.name.localizedCaseInsensitiveContains($0) }) {
                if attribute.name.localizedCaseInsensitiveContains("used"),
                   let raw = UInt64(attribute.rawValue.filter(\.isNumber)) {
                    return max(0, min(100, 100 - Int(raw)))
                }
                if let percent = attribute.percent {
                    return max(0, min(100, percent))
                }
            }
        }
        return nil
    }
}
