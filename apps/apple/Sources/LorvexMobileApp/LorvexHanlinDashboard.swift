import Charts
import SwiftUI
import LorvexHanlinAgent

/// This chart is Lorvex domain UI, fed only by the real get_summary result.
struct LorvexHanlinDashboard: View {
    let summary: LorvexHanlinSummary
    @State private var chartBreakdown = "status"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Task overview").font(.headline)
                Spacer()
                Text(summary.partial ? String(localized: "Partial sample") : String(localized: "All tasks"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("\(summary.open) active", systemImage: "circle.dotted")
                Label("\(summary.completed) completed", systemImage: "checkmark.circle")
            }
            .font(.caption)
            Picker("Breakdown", selection: $chartBreakdown) {
                Text("Status").tag("status")
                Text("Priority").tag("priority")
            }
            .pickerStyle(.segmented)
            Chart(summary.buckets(by: chartBreakdown)) { bucket in
                BarMark(
                    x: .value("Category", bucketTitle(bucket.name)),
                    y: .value("Tasks", bucket.value))
                    .foregroundStyle(by: .value("Category", bucketTitle(bucket.name)))
            }
            .chartLegend(.hidden)
            .frame(height: 170)
            .accessibilityLabel("Task summary bar chart")
            if summary.partial {
                Text("Based on \(summary.sampleSize) of \(summary.totalMatching) matching tasks.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Localize display labels only; the tool payload and bucket IDs stay canonical.
    private func bucketTitle(_ name: String) -> String {
        if chartBreakdown == "priority" { return name.uppercased() }
        switch name {
        case "open": return String(localized: "hanlin.dashboard.status.open", defaultValue: "Open")
        case "in_progress": return String(localized: "hanlin.dashboard.status.in_progress", defaultValue: "In progress")
        case "completed": return String(localized: "hanlin.dashboard.status.completed", defaultValue: "Completed")
        case "cancelled": return String(localized: "hanlin.dashboard.status.cancelled", defaultValue: "Cancelled")
        case "someday": return String(localized: "hanlin.dashboard.status.someday", defaultValue: "Someday")
        default: return name
        }
    }
}
