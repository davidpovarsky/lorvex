import Foundation
import Testing
import LorvexCore
import HanlinChatCore
@testable import LorvexHanlinAgent

@MainActor
struct LorvexHanlinPresentationStateTests {
  private func state() -> LorvexHanlinAssistantState {
    let database = FileManager.default.temporaryDirectory
      .appending(path: "lorvex-hanlin-state-" + UUID().uuidString + ".sqlite")
    return LorvexHanlinAssistantState(core: SwiftLorvexCoreService(
      databasePath: database.path, writeInitiatorDefault: "user"))
  }

  @Test func activityKeepsDistinctCallsAndObservedResultState() {
    var message = LorvexHanlinMessage(role: .assistant, text: "", status: .streaming)
    message.consume(.reasoningDelta("I will read the tasks first."))
    message.consume(.toolCallArgumentsStarted(id: "read-1", name: "list_tasks"))
    message.consume(.toolCallArgumentsDelta(id: "read-1", delta: "{\"limit\":5}"))
    message.consume(.toolCall(.init(id: "read-1", name: "list_tasks", argumentsJSON: "{\"limit\":5}")))
    message.consume(.toolCall(.init(id: "read-2", name: "list_tasks", argumentsJSON: "{\"limit\":10}")))
    message.consume(.toolResult(callID: "read-1", name: "list_tasks", modelText: "{\"tasks\":[]}",
                                resultReference: nil, isError: false))
    message.consume(.textDelta("No tasks were found."))
    message.finish(.completed)
    #expect(message.reasoning == "I will read the tasks first.")
    #expect(message.text == "No tasks were found.")
    #expect(message.activities.map(\.id) == ["read-1", "read-2"])
    #expect(message.activities[0].phase == .completed)
    #expect(message.activities[1].phase == .incomplete)
    #expect(message.activities[0].arguments == "{\"limit\":5}")
  }

  @Test func cancellationCannotPublishIntoTheNextRequest() async throws {
    let assistant = state()
    let old = try #require(assistant.beginResponse(prompt: "Old request"))
    assistant.consume(.textDelta("Partial"), runID: old.runID, responseID: old.responseID)
    await assistant.cancel()
    let current = try #require(assistant.beginResponse(prompt: "New request"))
    assistant.consume(.textDelta("Stale"), runID: old.runID, responseID: old.responseID)
    assistant.finishResponse(runID: old.runID, responseID: old.responseID, failure: "Old failure")
    #expect(assistant.isRunning)
    #expect(assistant.errorMessage == nil)
    #expect(assistant.messages.first { $0.id == old.responseID }?.text == "Partial")
    #expect(assistant.messages.first { $0.id == old.responseID }?.status == .cancelled)
    assistant.consume(.textDelta("Current answer"), runID: current.runID, responseID: current.responseID)
    assistant.finishResponse(runID: current.runID, responseID: current.responseID)
    #expect(!assistant.isRunning)
    #expect(assistant.messages.last?.text == "Current answer")
  }

  @Test func changedCredentialCreatesADifferentProviderIdentity() {
    let first = LorvexHanlinAssistantState.ModelIdentity(provider: "OpenAI", endpoint: "https://example.test",
                                                        modelID: "configured-model", credential: "first-key")
    let second = LorvexHanlinAssistantState.ModelIdentity(provider: "OpenAI", endpoint: "https://example.test",
                                                         modelID: "configured-model", credential: "replacement-key")
    #expect(first != second)
    #expect(first.credentialDigest.count == 32)
  }

  @Test func sourcesAreObservedDeduplicatedAndSafeForNavigation() {
    var message = LorvexHanlinMessage(role: .assistant, text: "", status: .streaming)
    message.consume(.source(id: "first", url: "https://example.test/plan", title: "Plan"))
    message.consume(.source(id: "second", url: "https://example.test/plan", title: "Updated title"))
    message.consume(.source(id: "unsafe", url: "javascript:alert(1)", title: "Invalid source"))
    #expect(message.sources.count == 1)
    #expect(message.sources.first?.title == "Updated title")
  }

  @Test func failedOrCancelledToolCannotBecomeACompletedReceipt() {
    var message = LorvexHanlinMessage(role: .assistant, text: "", status: .streaming)
    message.consume(.toolCall(.init(id: "write", name: "create_task", argumentsJSON: "{}")))
    message.consume(.toolResult(callID: "write", name: "create_task", modelText: "Denied by host",
                                resultReference: nil, isError: true))
    message.consume(.toolCall(.init(id: "pending", name: "get_today", argumentsJSON: "{}")))
    message.finish(.cancelled)
    #expect(message.activities[0].phase == .failed)
    #expect(message.activities[1].phase == .cancelled)
  }
}
