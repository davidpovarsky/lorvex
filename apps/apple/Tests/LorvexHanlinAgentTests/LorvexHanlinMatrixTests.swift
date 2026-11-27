import Foundation
import HanlinChatCore
import HanlinHostContracts
import LorvexCore
import Testing
@testable import LorvexHanlinAgent

@MainActor
struct LorvexHanlinMatrixTests {
  @Test func matrixToolReturnsTheExistingCanonicalScopeAndPreservesTable() async throws {
    let core = try SwiftLorvexCoreService.inMemory()
    let namespace = try HanlinConversationNamespace(
      app: "lorvex", account: "matrix-test", workspace: "personal", space: "tasks")
    let host = LorvexHanlinHost(
      core: core, context: HanlinHostContext(namespace: namespace, sceneID: UUID(), generation: UUID()),
      authorizeWrite: { _ in true })
    let task = try await core.createTask(TaskCreateDraft(title: "Canonical Matrix task", priority: .p1))
    for presentation in ["matrix", "table"] {
      let response = await host.invokeRemoteTool(
        name: "show_task_workspace",
        argumentsJSON: try JSONSerialization.data(withJSONObject: [
          "presentation": presentation, "root_task_id": task.id]),
        remoteRequestID: "matrix-acceptance-" + presentation)
      #expect(!response.isError)
      let descriptor = try #require(LorvexHanlinTaskWorkspace(callID: presentation, resultJSON: response.text))
      #expect(descriptor.presentation == presentation)
      #expect(descriptor.rootTaskID == task.id)
      let json = try #require(try JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
      #expect(json["taskCount"] as? Int == 1)
    }
    #expect(try await core.loadTask(id: task.id).priority == .p1)
  }
}
