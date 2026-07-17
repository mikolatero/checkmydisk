import SwiftUI

struct HealthIndicatorsView: View {
    let snapshot: DriveSnapshot
    @State private var search = ""
    @State private var typeFilter = "Any Type"
    @State private var statusFilter = "Any Status"
    @State private var sortOrder = [KeyPathComparator(\SmartAttribute.id)]

    private var rows: [SmartAttribute] {
        snapshot.attributes.filter { attribute in
            (search.isEmpty || attribute.name.localizedCaseInsensitiveContains(search) || "\(attribute.id)".contains(search)) &&
            (typeFilter == "Any Type" || attribute.type.localizedCaseInsensitiveContains(typeFilter)) &&
            (statusFilter == "Any Status" || attribute.status.rawValue == statusFilter)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("ID", value: \.id) { attribute in
                    Text(String(format: "%03d", attribute.id))
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 44, ideal: 52)

                TableColumn("Attribute", value: \.name) { attribute in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attribute.name).fontWeight(.semibold)
                        Text(attribute.type).font(.caption).foregroundStyle(.secondary)
                        if let whenFailed = attribute.whenFailed, !whenFailed.isEmpty {
                            Label(String(localized: "Failed: \(whenFailed)"), systemImage: "exclamationmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .width(min: 160, ideal: 240)

                TableColumn("Raw value") { attribute in
                    Text(attribute.prettyValue ?? attribute.rawValue)
                        .textSelection(.enabled)
                }

                TableColumn("Cur / Worst / Thr") { attribute in
                    Text("\(attribute.current.map(String.init) ?? "-") / \(attribute.worst.map(String.init) ?? "-") / \(attribute.threshold.map(String.init) ?? "-")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TableColumn("Health") { attribute in
                    HStack(spacing: 6) {
                        ProgressView(value: Double(attribute.percent ?? 0), total: 100)
                            .tint(stateColor(attribute.status))
                        Text(attribute.percent.map { "\($0)%" } ?? "-")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
                .width(min: 120, ideal: 160)

                TableColumn("Status", value: \.status.severity) { attribute in
                    Label(attribute.status.rawValue, systemImage: stateIcon(attribute.status))
                        .foregroundStyle(stateColor(attribute.status))
                }
                .width(min: 96, ideal: 116)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $typeFilter) {
                Text("Any Type").tag("Any Type")
                Text("Pre-Fail").tag("pre-fail")
                Text("Life-Span").tag("life-span")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("", selection: $statusFilter) {
                Text("Any Status").tag("Any Status")
                ForEach(DriveHealthState.allCases, id: \.rawValue) { state in
                    Text(state.rawValue).tag(state.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 12)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 220)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
    }
}
