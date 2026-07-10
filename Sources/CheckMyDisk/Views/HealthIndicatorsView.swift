import SwiftUI

struct HealthIndicatorsView: View {
    let snapshot: DriveSnapshot
    @State private var search = ""
    @State private var typeFilter = "Any Type"
    @State private var statusFilter = "Any Status"

    private var filtered: [SmartAttribute] {
        snapshot.attributes.filter { attribute in
            (search.isEmpty || attribute.name.localizedCaseInsensitiveContains(search) || "\(attribute.id)".contains(search)) &&
            (typeFilter == "Any Type" || attribute.type.localizedCaseInsensitiveContains(typeFilter)) &&
            (statusFilter == "Any Status" || attribute.status.rawValue == statusFilter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $typeFilter) {
                    Text("Any Type").tag("Any Type")
                    Text("Pre-Fail").tag("pre-fail")
                    Text("Life-Span").tag("life-span")
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Picker("", selection: $statusFilter) {
                    Text("Any Status").tag("Any Status")
                    ForEach(DriveHealthState.allCases, id: \.rawValue) { state in
                        Text(state.rawValue).tag(state.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 420)

                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))

            HStack {
                header("id", width: 48)
                header("name", width: 260)
                header("raw value", width: 120)
                header("value", width: 160)
                header("status", width: 220)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.quaternary)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { attribute in
                        AttributeRow(attribute: attribute)
                    }
                }
                .padding(10)
            }
        }
    }

    private func header(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .textCase(.lowercase)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }
}

struct AttributeRow: View {
    let attribute: SmartAttribute

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(attribute.id)")
                .frame(width: 48, alignment: .leading)
                .font(.system(.body, design: .monospaced).weight(.bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(attribute.name)
                    .fontWeight(.bold)
                Text("Type: \(attribute.type)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let whenFailed = attribute.whenFailed, !whenFailed.isEmpty {
                    Label(String(localized: "Failed: \(whenFailed)"), systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 260, alignment: .leading)
            Text(attribute.prettyValue ?? attribute.rawValue)
                .frame(width: 120, alignment: .trailing)
                .textSelection(.enabled)
            VStack(alignment: .trailing, spacing: 1) {
                Text("Current: \(attribute.current.map(String.init) ?? "-")")
                Text("Worst: \(attribute.worst.map(String.init) ?? "-")")
                Text("Threshold: \(attribute.threshold.map(String.init) ?? "-")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 160, alignment: .trailing)
            HStack {
                ProgressView(value: Double(attribute.percent ?? 0), total: 100)
                    .tint(stateColor(attribute.status))
                    .frame(width: 120)
                Text(attribute.percent.map { "\($0)%" } ?? "-")
                    .frame(width: 42, alignment: .trailing)
                Text(attribute.status.rawValue)
                    .fontWeight(.bold)
                    .foregroundStyle(stateColor(attribute.status))
                    .frame(width: 70, alignment: .leading)
            }
            .frame(width: 220, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(attribute.name), \(attribute.status.rawValue)"))
    }
}
