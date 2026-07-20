import Foundation

/// A change in an attribute's raw value between two consecutive checks.
struct AttributeDelta: Identifiable, Equatable, Hashable, Sendable {
    var id: Int { attributeID }
    let attributeID: Int
    let name: String
    let previousRaw: UInt64
    let currentRaw: UInt64
    let isCritical: Bool

    var change: Int64 { Int64(clamping: currentRaw) - Int64(clamping: previousRaw) }
}

/// A wear-based projection of when SSD life-left reaches 0%.
struct LifeEstimate: Equatable, Sendable {
    let daysRemaining: Int
    let projectedDate: Date
}

/// Turns the persisted history and consecutive snapshots into actionable trends:
/// per-attribute deltas between checks and a wear-based remaining-life projection.
enum TrendAnalyzer {
    /// ATA attribute IDs whose growth signals developing failure. NVMe synthetic
    /// attributes are matched by name via `criticalKeywords` instead (their IDs are
    /// only sequential).
    private static let criticalIDs: Set<Int> = [5, 187, 196, 197, 198]
    private static let criticalKeywords = ["reallocat", "pending", "uncorrectable", "media error"]

    /// Non-zero raw-value deltas between two snapshots, matched by attribute name,
    /// worst (largest magnitude) first.
    static func deltas(current: DriveSnapshot, previous: DriveSnapshot) -> [AttributeDelta] {
        let previousByName = Dictionary(previous.attributes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var deltas: [AttributeDelta] = []
        for attribute in current.attributes {
            guard let earlier = previousByName[attribute.name],
                  let currentRaw = rawCount(attribute.rawValue),
                  let previousRaw = rawCount(earlier.rawValue),
                  currentRaw != previousRaw else { continue }
            deltas.append(AttributeDelta(
                attributeID: attribute.id,
                name: attribute.name,
                previousRaw: previousRaw,
                currentRaw: currentRaw,
                isCritical: isCritical(attribute)
            ))
        }
        return deltas.sorted { abs($0.change) > abs($1.change) }
    }

    /// Critical attributes that grew since the last check — the ones worth alerting on.
    static func criticalIncreases(current: DriveSnapshot, previous: DriveSnapshot) -> [AttributeDelta] {
        deltas(current: current, previous: previous).filter { $0.isCritical && $0.change > 0 }
    }

    /// Least-squares projection of when SSD life-left reaches 0%, from the history.
    /// Returns nil unless there are enough samples over at least a day with a
    /// clearly declining trend, so noise does not produce a spurious date.
    static func estimateRemainingLife(from points: [HistoryPoint], asOf now: Date) -> LifeEstimate? {
        let samples = points.compactMap { point in point.lifetime.map { (point.date.timeIntervalSince1970, Double($0)) } }
        guard samples.count >= 3, let first = samples.first, let last = samples.last, last.0 - first.0 >= 86_400 else {
            return nil
        }
        // Offset x by the first timestamp to keep the regression numerically stable.
        let origin = first.0
        let xs = samples.map { $0.0 - origin }
        let ys = samples.map { $0.1 }
        let n = Double(samples.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n
        guard slope < 0 else { return nil } // life not declining → no estimate
        let projected = origin + (-intercept / slope)
        let secondsRemaining = projected - now.timeIntervalSince1970
        guard secondsRemaining > 0 else { return nil }
        return LifeEstimate(daysRemaining: Int(secondsRemaining / 86_400), projectedDate: Date(timeIntervalSince1970: projected))
    }

    private static func isCritical(_ attribute: SmartAttribute) -> Bool {
        // The ATA IDs apply only to real ATA attributes. Synthetic NVMe attributes
        // reuse sequential IDs (e.g. "Error Log Entries" happens to be id 5), so
        // they must be matched by name only — otherwise a benign NVMe error-log
        // entry (common on Apple's internal NVMe) would raise a false critical alert.
        if attribute.isSynthetic != true, criticalIDs.contains(attribute.id) { return true }
        let name = attribute.name.lowercased()
        return criticalKeywords.contains { name.contains($0) }
    }

    /// The leading integer of a raw value ("34 (Min/Max 20/45)" → 34, "1234" → 1234).
    private static func rawCount(_ value: String) -> UInt64? {
        let digits = value.prefix { $0.isNumber }
        return digits.isEmpty ? nil : UInt64(digits)
    }
}
