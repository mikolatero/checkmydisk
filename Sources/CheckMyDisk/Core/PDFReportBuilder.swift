import AppKit

/// Renders a drive report as a clean, paginated, print-ready PDF: identity, health
/// ratings, problems, and the full SMART attribute / error / self-test tables — the
/// data a sysadmin needs, laid out to be actually readable.
enum PDFReportBuilder {
    static func pdf(snapshot: DriveSnapshot, assessment: DriveAssessment, anonymize: Bool) -> Data {
        let renderer = PDFReportRenderer()
        renderer.render(snapshot: snapshot, assessment: assessment, anonymize: anonymize)
        return renderer.finish()
    }
}

private final class PDFReportRenderer {
    private let data = NSMutableData()
    private let context: CGContext
    private let pageSize = CGSize(width: 612, height: 792) // US Letter @ 72dpi
    private let margin: CGFloat = 48
    private var y: CGFloat = 0
    private var page = 0
    private var footerTitle = ""

    // Palette (light, print-friendly).
    private let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
    private let subtle = NSColor(calibratedWhite: 0.42, alpha: 1)
    private let hairline = NSColor(calibratedWhite: 0.82, alpha: 1)
    private let zebra = NSColor(calibratedWhite: 0.965, alpha: 1)
    private let headerFill = NSColor(calibratedWhite: 0.91, alpha: 1)

    init() {
        var box = CGRect(origin: .zero, size: pageSize)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    }

    private var contentWidth: CGFloat { pageSize.width - margin * 2 }
    private var bottomLimit: CGFloat { pageSize.height - margin - 18 }

    // MARK: - Content

    func render(snapshot: DriveSnapshot, assessment: DriveAssessment, anonymize: Bool) {
        footerTitle = snapshot.modelName
        beginPage()
        drawHeader(snapshot: snapshot, assessment: assessment)
        drawRatings(snapshot: snapshot, assessment: assessment)
        drawInfo(snapshot: snapshot, anonymize: anonymize)
        drawProblems(assessment: assessment)
        drawAttributes(snapshot: snapshot)
        drawErrors(snapshot: snapshot)
        drawSelfTests(snapshot: snapshot)
    }

    func finish() -> Data {
        if page > 0 { endPage() }
        context.closePDF()
        return data as Data
    }

    private func drawHeader(snapshot: DriveSnapshot, assessment: DriveAssessment) {
        line("DRIVE HEALTH REPORT", font: .systemFont(ofSize: 9, weight: .semibold), color: subtle, gapAfter: 2)
        line(snapshot.modelName, font: .systemFont(ofSize: 21, weight: .bold), color: ink, gapAfter: 6)
        badge(text: "S.M.A.R.T. " + assessment.smartStatus.rawValue, state: assessment.smartStatus)
        y += 21
        let kind = snapshot.isRotational == true ? "HDD" : (snapshot.device.type.lowercased() == "nvme" ? "SSD (NVMe)" : "SSD")
        line("\(snapshot.device.name)  ·  \(snapshot.device.protocolName)  ·  \(kind)", font: monoFont(9), color: subtle, gapAfter: 1)
        line("Generated \(snapshot.checkedAt.formatted(date: .abbreviated, time: .standard))", font: .systemFont(ofSize: 9), color: subtle, gapAfter: 10)
        rule()
    }

    private func drawRatings(snapshot: DriveSnapshot, assessment: DriveAssessment) {
        var tiles: [(String, Int, DriveHealthState)] = [
            ("Overall Health", assessment.overallHealth, stateForPercent(assessment.overallHealth)),
            ("Performance", assessment.overallPerformance, stateForPercent(assessment.overallPerformance)),
        ]
        if let life = assessment.ssdLifetimeLeft {
            tiles.append(("SSD Lifetime Left", life, stateForPercent(life)))
        }
        if let temperature = snapshot.temperature {
            let thresholds = HealthEvaluator.temperatureThresholds(for: snapshot)
            let state: DriveHealthState = temperature >= thresholds.failing ? .failing : (temperature >= thresholds.warning ? .warning : .ok)
            tiles.append(("Temperature", temperature, state)) // shown as °C, not %
        }

        y += 6
        let gap: CGFloat = 12
        let tileW = (contentWidth - gap * CGFloat(tiles.count - 1)) / CGFloat(tiles.count)
        let tileH: CGFloat = 58
        ensure(tileH + 8)
        for (index, tile) in tiles.enumerated() {
            let x = margin + CGFloat(index) * (tileW + gap)
            let isTemperature = tile.0 == "Temperature"
            drawTile(x: x, width: tileW, height: tileH, title: tile.0,
                     value: isTemperature ? "\(tile.1) °C" : "\(tile.1)%",
                     fraction: isTemperature ? nil : Double(tile.1) / 100, state: tile.2)
        }
        y += tileH + 12
    }

    private func drawTile(x: CGFloat, width: CGFloat, height: CGFloat, title: String, value: String, fraction: Double?, state: DriveHealthState) {
        let box = CGRect(x: x, y: y, width: width, height: height)
        roundedRect(box, radius: 6, fill: NSColor(calibratedWhite: 0.975, alpha: 1), stroke: hairline)
        drawText(title, font: .systemFont(ofSize: 8.5, weight: .semibold), color: subtle, rect: CGRect(x: x + 10, y: y + 8, width: width - 20, height: 12))
        drawText(value, font: .systemFont(ofSize: 20, weight: .bold), color: ink, rect: CGRect(x: x + 10, y: y + 20, width: width - 20, height: 24))
        if let fraction {
            let barY = y + height - 14
            let barRect = CGRect(x: x + 10, y: barY, width: width - 20, height: 5)
            roundedRect(barRect, radius: 2.5, fill: NSColor(calibratedWhite: 0.9, alpha: 1), stroke: nil)
            let filled = CGRect(x: barRect.minX, y: barRect.minY, width: max(2, barRect.width * CGFloat(min(1, max(0, fraction)))), height: barRect.height)
            roundedRect(filled, radius: 2.5, fill: color(for: state), stroke: nil)
        }
    }

    private func drawInfo(snapshot: DriveSnapshot, anonymize: Bool) {
        sectionTitle("Device Information")
        var pairs: [(String, String)] = [
            ("Model", snapshot.modelName),
            ("Serial No.", anonymize ? redact(snapshot.serialNumber) : (snapshot.serialNumber ?? "-")),
            ("Firmware", snapshot.firmwareVersion ?? "-"),
            ("Capacity", snapshot.userCapacityBytes.map(ReportBuilder.formatBytes) ?? "-"),
            ("Sector Size", snapshot.sectorSize ?? "-"),
            ("Protocol", snapshot.device.protocolName),
        ]
        if let wwn = snapshot.wwn { pairs.append(("WWN", anonymize ? redact(wwn) : wwn)) }
        if let form = snapshot.formFactor { pairs.append(("Form Factor", form)) }
        if let rpm = snapshot.rotationRate { pairs.append(("Rotation Rate", rpm == 0 ? "SSD" : "\(rpm) rpm")) }
        if let speed = snapshot.interfaceSpeed { pairs.append(("Interface Speed", speed)) }
        if let version = snapshot.sataVersion ?? snapshot.ataVersion ?? snapshot.nvmeVersion { pairs.append(("Standard", version)) }
        if let trim = snapshot.trimSupported { pairs.append(("TRIM", trim ? "Supported" : "Not supported")) }
        pairs.append(("Data Written", DriveUsageMetrics.formattedBytesWritten(for: snapshot) ?? "-"))
        pairs.append(("Data Read", DriveUsageMetrics.formattedBytesRead(for: snapshot) ?? "-"))
        pairs.append(("Power-On Hours", snapshot.powerOnHours.map { "\($0) h" } ?? "-"))
        pairs.append(("Power Cycles", snapshot.powerCycles.map(String.init) ?? "-"))
        pairs.append(("Temperature", snapshot.temperature.map { "\($0) °C" } ?? "-"))

        let colW = contentWidth / 2
        let rowH: CGFloat = 15
        let rows = (pairs.count + 1) / 2
        for row in 0..<rows {
            ensure(rowH)
            drawPair(pairs[row * 2], x: margin, width: colW - 10)
            if row * 2 + 1 < pairs.count {
                drawPair(pairs[row * 2 + 1], x: margin + colW, width: colW - 10)
            }
            y += rowH
        }
        y += 6
    }

    private func drawPair(_ pair: (String, String), x: CGFloat, width: CGFloat) {
        let labelW: CGFloat = 104
        drawText(pair.0, font: .systemFont(ofSize: 9, weight: .semibold), color: subtle, rect: CGRect(x: x, y: y, width: labelW, height: rowLineHeight))
        drawText(pair.1, font: monoFont(9), color: ink, rect: CGRect(x: x + labelW + 4, y: y, width: width - labelW - 4, height: rowLineHeight), truncate: true)
    }

    private func drawProblems(assessment: DriveAssessment) {
        sectionTitle("Problems Summary")
        guard !assessment.problems.isEmpty else {
            line("No health-related issues found.", font: .systemFont(ofSize: 9.5), color: color(for: .ok), gapAfter: 8)
            return
        }
        for problem in assessment.problems {
            let titleHeight = textHeight(problem.title, font: .systemFont(ofSize: 9.5, weight: .semibold), width: contentWidth - 90)
            let detailHeight = textHeight(problem.detail, font: .systemFont(ofSize: 9), width: contentWidth - 12)
            ensure(titleHeight + detailHeight + 8)
            badge(text: problem.state.rawValue, state: problem.state, small: true)
            drawText(problem.title, font: .systemFont(ofSize: 9.5, weight: .semibold), color: ink, rect: CGRect(x: margin + 76, y: y, width: contentWidth - 76, height: titleHeight))
            y += max(titleHeight, 13)
            drawText(problem.detail, font: .systemFont(ofSize: 9), color: subtle, rect: CGRect(x: margin + 12, y: y, width: contentWidth - 12, height: detailHeight))
            y += detailHeight + 7
        }
        y += 2
    }

    private func drawAttributes(snapshot: DriveSnapshot) {
        guard !snapshot.attributes.isEmpty else { return }
        sectionTitle("SMART Health Indicators")
        let widths: [CGFloat] = [34, 150, 52, 78, 40, 40, 40, 62]
        table(
            headers: ["ID", "Attribute", "Type", "Raw", "Cur", "Wst", "Thr", "Status"],
            rows: snapshot.attributes.map { attribute in
                [
                    String(format: "%03d", attribute.id),
                    attribute.name,
                    attribute.type,
                    attribute.prettyValue ?? attribute.rawValue,
                    attribute.current.map(String.init) ?? "-",
                    attribute.worst.map(String.init) ?? "-",
                    attribute.threshold.map(String.init) ?? "-",
                    attribute.status.rawValue,
                ]
            },
            widths: widths,
            statusColumn: 7,
            statusStates: snapshot.attributes.map(\.status)
        )
    }

    private func drawErrors(snapshot: DriveSnapshot) {
        guard !snapshot.errorLog.isEmpty else { return }
        sectionTitle("SMART Error Log")
        table(
            headers: ["#", "Lifetime (h)", "Error", "Prior command", "LBA"],
            rows: snapshot.errorLog.map { [String($0.id), $0.lifetimeHours.map(String.init) ?? "-", $0.errors, $0.priorCommand, $0.lba ?? "-"] },
            widths: [34, 78, 190, 130, 84]
        )
    }

    private func drawSelfTests(snapshot: DriveSnapshot) {
        guard !snapshot.selfTests.isEmpty else { return }
        sectionTitle("Self-tests")
        table(
            headers: ["#", "Lifetime (h)", "Type", "Status", "LBA of 1st error"],
            rows: snapshot.selfTests.map { [String($0.id), $0.lifetimeHours.map(String.init) ?? "-", $0.testType, $0.status, $0.lbaOfFirstError ?? "-"] },
            widths: [34, 78, 110, 200, 94]
        )
    }

    // MARK: - Table

    private func table(headers: [String], rows: [[String]], widths: [CGFloat], statusColumn: Int? = nil, statusStates: [DriveHealthState]? = nil) {
        let rowH: CGFloat = 15
        // Header row (repeated when the table breaks across pages).
        func drawHeaderRow() {
            ensure(rowH)
            fillRow(color: headerFill, height: rowH)
            drawCells(headers, widths: widths, font: .systemFont(ofSize: 8, weight: .semibold), color: ink)
            y += rowH
        }
        drawHeaderRow()
        for (index, row) in rows.enumerated() {
            if y + rowH > bottomLimit {
                beginPage()
                drawHeaderRow()
            }
            if index.isMultiple(of: 2) == false {
                fillRow(color: zebra, height: rowH)
            }
            drawCells(row, widths: widths, font: monoFont(8), color: NSColor(calibratedWhite: 0.2, alpha: 1), skip: statusColumn)
            if let statusColumn, let statusStates {
                // Recolour the status cell to match its state.
                let x = margin + widths.prefix(statusColumn).reduce(0, +)
                drawText(row[statusColumn], font: .systemFont(ofSize: 8, weight: .semibold), color: color(for: statusStates[index]),
                         rect: CGRect(x: x + 3, y: y + 3, width: widths[statusColumn] - 6, height: rowH - 4), truncate: true)
            }
            y += rowH
        }
        y += 8
    }

    private func drawCells(_ cells: [String], widths: [CGFloat], font: NSFont, color: NSColor, skip: Int? = nil) {
        var x = margin
        for (index, cell) in cells.enumerated() where index < widths.count {
            if index != skip {
                drawText(cell, font: font, color: color, rect: CGRect(x: x + 3, y: y + 3, width: widths[index] - 6, height: 12), truncate: true)
            }
            x += widths[index]
        }
    }

    // MARK: - Primitives

    private let rowLineHeight: CGFloat = 12

    private func beginPage() {
        if page > 0 { endPage() }
        page += 1
        context.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        y = margin
    }

    private func endPage() {
        let footer = NSAttributedString(string: "\(footerTitle)   ·   CheckMyDisk   ·   page \(page)", attributes: [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: subtle,
        ])
        footer.draw(in: flip(CGRect(x: margin, y: pageSize.height - margin + 4, width: contentWidth, height: 12)))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }

    private func ensure(_ height: CGFloat) {
        if y + height > bottomLimit { beginPage() }
    }

    private func sectionTitle(_ title: String) {
        y += 6
        ensure(24)
        line(title, font: .systemFont(ofSize: 12.5, weight: .bold), color: ink, gapAfter: 3)
        rule()
        y += 4
    }

    private func rule() {
        hairline.setStroke()
        let ruleY = pageSize.height - y
        let path = NSBezierPath()
        path.move(to: CGPoint(x: margin, y: ruleY))
        path.line(to: CGPoint(x: margin + contentWidth, y: ruleY))
        path.lineWidth = 0.5
        path.stroke()
    }

    /// Converts a top-left-origin rect to the PDF context's bottom-left origin.
    private func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: pageSize.height - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    @discardableResult
    private func line(_ text: String, font: NSFont, color: NSColor, gapAfter: CGFloat) -> CGFloat {
        let height = textHeight(text, font: font, width: contentWidth)
        ensure(height)
        drawText(text, font: font, color: color, rect: CGRect(x: margin, y: y, width: contentWidth, height: height))
        y += height + gapAfter
        return height
    }

    private func badge(text: String, state: DriveHealthState, small: Bool = false) {
        let font = NSFont.systemFont(ofSize: small ? 7.5 : 9, weight: .bold)
        let textColor: NSColor = state == .warning ? .black : .white
        let padding: CGFloat = small ? 5 : 7
        let width = (text as NSString).size(withAttributes: [.font: font]).width + padding * 2
        let height: CGFloat = small ? 12 : 15
        let box = CGRect(x: margin, y: y, width: width, height: height)
        roundedRect(box, radius: small ? 3 : 4, fill: color(for: state), stroke: nil)
        drawText(text, font: font, color: textColor, rect: CGRect(x: box.minX + padding, y: box.minY + (height - 10) / 2, width: width, height: 11))
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, rect: CGRect, truncate: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = truncate ? .byTruncatingTail : .byWordWrapping
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]).draw(in: flip(rect))
    }

    private func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let bounds = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(12, ceil(bounds.height))
    }

    private func fillRow(color: NSColor, height: CGFloat) {
        color.setFill()
        NSBezierPath(rect: flip(CGRect(x: margin, y: y, width: contentWidth, height: height))).fill()
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, fill: NSColor?, stroke: NSColor?) {
        let path = NSBezierPath(roundedRect: flip(rect), xRadius: radius, yRadius: radius)
        if let fill { fill.setFill(); path.fill() }
        if let stroke { stroke.setStroke(); path.lineWidth = 0.5; path.stroke() }
    }

    private func monoFont(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func color(for state: DriveHealthState) -> NSColor {
        switch state {
        case .ok: NSColor.systemGreen
        case .warning: NSColor.systemYellow
        case .failing: NSColor.systemOrange
        case .failed: NSColor.systemRed
        case .unknown: NSColor.systemGray
        }
    }

    private func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "-" }
        return String(repeating: "x", count: min(8, value.count))
    }
}
