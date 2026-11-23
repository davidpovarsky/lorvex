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
                Text(summary.partial ? "Partial sample" : "All tasks")
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
                    x: .value("Category", bucket.name),
                    y: .value("Tasks", bucket.value))
                    .foregroundStyle(by: .value("Category", bucket.name))
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

}
