import Foundation
import HanlinChatCore
import HanlinHostContracts
import LorvexCore
import Testing
@testable import LorvexHanlinAgent

@MainActor
struct LorvexHanlinTaskWorkspaceTests {
  @Test func toolsWriteRealDependenciesAndReturnLiveViewDescriptors() async throws {
    let core = try SwiftLorvexCoreService.inMemory()
    let namespace = try HanlinConversationNamespace(
      app: "lorvex", account: "test-workspace", workspace: "personal", space: "tasks")
    let context = HanlinHostContext(namespace: namespace, sceneID: UUID(), generation: UUID())
    let host = LorvexHanlinHost(core: core, context: context, authorizeWrite: { _ in true })
    let first = try await core.createTask(TaskCreateDraft(title: "Research"))
    let second = try await core.createTask(TaskCreateDraft(title: "Ship"))
    let arguments = try JSONSerialization.data(withJSONObject: [
      "prerequisite_id": first.id, "dependent_id": second.id
    ])
    let connected = await host.invokeRemoteTool(
      name: "add_task_dependency", argumentsJSON: arguments,
      remoteRequestID: "workspace-connect-0001")
    #expect(!connected.isError)
    #expect(try await core.loadTask(id: second.id).dependsOn == [first.id])

    let view = await host.invokeRemoteTool(
      name: "show_task_workspace",
      argumentsJSON: try JSONSerialization.data(withJSONObject: [
        "presentation": "graph", "root_task_id": second.id
      ]),
      remoteRequestID: "workspace-show-0001")
    #expect(!view.isError)
    let descriptor = try #require(LorvexHanlinTaskWorkspace(callID: "show-1", resultJSON: view.text))
    #expect(descriptor.rootTaskID == second.id)
    #expect(descriptor.presentation == "graph")
    let graph = await host.invokeRemoteTool(
      name: "get_dependency_graph", argumentsJSON: Data("{}".utf8),
      remoteRequestID: "workspace-read-0001")
    #expect(!graph.isError)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(graph.text.utf8)) as? [String: Any])
    let edges = try #require(json["edges"] as? [[String: String]])
    #expect(edges.contains(["dependentID": second.id, "prerequisiteID": first.id]))

    let removed = await host.invokeRemoteTool(
      name: "remove_task_dependency", argumentsJSON: arguments,
      remoteRequestID: "workspace-remove-0001")
    #expect(!removed.isError)
    #expect(try await core.loadTask(id: second.id).dependsOn.isEmpty)
  }

  @Test func failedOrMalformedToolNeverCreatesAWorkspaceAndReplayIsStable() {
    var message = LorvexHanlinMessage(role: .assistant, text: "", status: .streaming)
    let payload = #"{"presentation":"board","rootTaskID":"task-1","listID":null,"taskCount":2}"#
    message.consume(.toolResult(callID: "denied", name: "show_task_workspace",
      modelText: payload, resultReference: nil, isError: true))
    message.consume(.toolResult(callID: "invalid", name: "show_task_workspace",
      modelText: #"{"presentation":"javascript"}"#, resultReference: nil, isError: false))
    #expect(message.workspaces.isEmpty)
    for _ in 0..<2 {
      message.consume(.toolResult(callID: "shown", name: "show_task_workspace",
        modelText: payload, resultReference: nil, isError: false))
    }
    #expect(message.workspaces.count == 1)
    #expect(message.workspaces[0].id == "shown")
    #expect(message.workspaces[0].rootTaskID == "task-1")
  }
}
