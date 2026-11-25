#if canImport(UIKit)
import LorvexHanlinAgent
import LorvexMobile
import SwiftUI

@MainActor
struct LorvexHanlinTaskWorkspaceCard: View {
  let request: LorvexHanlinTaskWorkspace
  let store: MobileStore
  @State private var expanded = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(String(localized: "Live task workspace"), systemImage: "point.3.connected.trianglepath.dotted")
          .font(.headline)
        Spacer()
        Button(String(localized: "Expand workspace"), systemImage: "arrow.up.left.and.arrow.down.right") {
          expanded = true
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("hanlin.workspace.expand")
      }
      .padding(12)
      MobileTaskWorkspaceView(
        store: store, presentationName: request.presentation, rootTaskID: request.rootTaskID,
        listID: request.listID, embedded: true)
        .frame(height: 580)
    }
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
    .overlay { RoundedRectangle(cornerRadius: 18).stroke(.quaternary) }
    .sheet(isPresented: $expanded) {
      NavigationStack {
        MobileTaskWorkspaceView(
          store: store, presentationName: request.presentation,
          rootTaskID: request.rootTaskID, listID: request.listID)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(String(localized: "Close")) { expanded = false }
                .accessibilityIdentifier("hanlin.workspace.expanded.close")
            }
          }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("hanlin.workspace.expanded")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("hanlin.workspace." + request.id)
  }
}
#endif
