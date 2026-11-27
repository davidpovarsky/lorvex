import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import OSLog

private struct ProbeDrag: Codable, Transferable {
    let scope: UUID
    let taskID: String
    let sourceLaneID: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
@main
struct BoardActivationControlApp: App {
    var body: some Scene { WindowGroup { ControlView() } }
}
private struct ControlView: View {
    @State private var dropped = false
    @State private var scope = UUID()
    private let kind = ProcessInfo.processInfo.environment["CALIBRATION_KIND"] ?? "string"
    private let logger = Logger(subsystem: "com.itorah.BoardCalibration", category: "NativeDrag")
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white
                Text("Native drag calibration: \(kind)")
                    .foregroundStyle(.black)
                    .position(x: geometry.size.width / 2, y: 120)
                Text(dropped ? "dropped" : "waiting")
                    .accessibilityIdentifier("calibration.result")
                    .foregroundStyle(.black)
                    .position(x: geometry.size.width / 2, y: 170)
                source
                    .frame(width: 256, height: 210)
                    .position(x: 149, y: 512.333333)
                destination
                    .frame(width: 256, height: 179.666667)
                    .position(x: 445, y: 497.166667)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .environment(\.layoutDirection, .rightToLeft)
    }
    private var sourceBody: some View {
        Text("Source")
            .font(.title)
            .foregroundStyle(.black)
            .frame(width: 256, height: 210)
            .background(Color.orange.opacity(0.25))
            .contentShape(Rectangle())
            .accessibilityIdentifier("calibration.source")
    }
    private var destinationBody: some View {
        Text("Destination")
            .foregroundStyle(.black)
            .frame(width: 256, height: 179.666667)
            .background(Color.blue.opacity(0.25))
            .contentShape(Rectangle())
            .accessibilityIdentifier("calibration.destination")
    }
    @ViewBuilder private var source: some View {
        if kind == "codable" {
            sourceBody.draggable(ProbeDrag(scope: scope, taskID: "native", sourceLaneID: "source"))
                .onDragSessionUpdated { session in
                    logger.notice("codable phase=\(String(describing: session.phase), privacy: .public) location=\(String(describing: session.location), privacy: .public)")
                }
        } else {
            sourceBody.draggable("native")
                .onDragSessionUpdated { session in
                    logger.notice("string phase=\(String(describing: session.phase), privacy: .public) location=\(String(describing: session.location), privacy: .public)")
                }
        }
    }
    @ViewBuilder private var destination: some View {
        if kind == "codable" {
            destinationBody.dropDestination(for: ProbeDrag.self) { items, location in
                logger.notice("codable drop count=\(items.count) location=\(String(describing: location), privacy: .public)")
                let valid = items.count == 1 && items[0].scope == scope && items[0].taskID == "native"
                dropped = valid
                return valid
            } isTargeted: { value in logger.notice("codable target=\(value)") }
        } else {
            destinationBody.dropDestination(for: String.self) { items, location in
                logger.notice("string drop count=\(items.count) location=\(String(describing: location), privacy: .public)")
                let valid = items == ["native"]
                dropped = valid
                return valid
            } isTargeted: { value in logger.notice("string target=\(value)") }
        }
    }
}
