#if DEBUG
import Foundation
import HanlinChatCore

/// A simulator-only provider boundary for native acceptance. The real SDK
/// parses these provider events and invokes the unchanged host/Core tools.
public enum LorvexHanlinWorkspaceAcceptance {
  public static let modelID = "lorvex-native-workspace"
  public static let endpoint = "https://lorvex-workspace-acceptance.invalid/v1"
  public static let credential = "isolated-simulator-provider-fixture"
  public static let completion = "Native workspace acceptance completed."
  private static let createCallID = "lorvex-acceptance-create"
  private static let workspaceCallID = "lorvex-acceptance-workspace"

  public static var isEnabled: Bool {
    #if targetEnvironment(simulator)
      ProcessInfo.processInfo.environment["LORVEX_HANLIN_WORKSPACE_ACCEPTANCE"] == "1"
        && ProcessInfo.processInfo.environment["LORVEX_CLOUD_SYNC"] == "off"
    #else
      false
    #endif
  }

  static func makeEngineIfEnabled(
    configuration: HanlinChatModelConfiguration
  ) throws -> HanlinAISDKAgentEngine? {
    guard isEnabled else { return nil }
    guard configuration.endpoint.absoluteString == endpoint,
          configuration.apiKey == credential else { throw FixtureError.invalidRequest }
    return try HanlinAISDKAgentEngine(configuration: configuration, fetch: { request in
      let (body, response) = try reply(to: request)
      return .init(body: .data(body), urlResponse: response)
    })
  }

  private static func reply(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let title = ProcessInfo.processInfo.environment["LORVEX_HANLIN_WORKSPACE_TASK_TITLE"] ?? ""
    guard !title.isEmpty, title.utf8.count <= 200,
          let url = request.url, url.host == "lorvex-workspace-acceptance.invalid",
          url.path == "/v1/chat/completions", request.httpMethod == "POST",
          let data = request.httpBody,
          let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          body["stream"] as? Bool == true,
          let messages = body["messages"] as? [[String: Any]],
          messages.contains(where: { $0["role"] as? String == "user"
            && text($0["content"]).contains(title) }),
          let tools = body["tools"] as? [[String: Any]] else { throw FixtureError.invalidRequest }

    let delta: [String: Any]
    let finish: String
    if let created = try toolResult(createCallID, in: messages) {
      guard let task = created["task"] as? [String: Any],
            let id = task["id"] as? String, !id.isEmpty,
            task["title"] as? String == title else { throw FixtureError.invalidToolResult }
      if let shown = try toolResult(workspaceCallID, in: messages) {
        guard shown["rootTaskID"] as? String == id,
              shown["presentation"] as? String == "table",
              (shown["taskCount"] as? Int ?? 0) > 0 else { throw FixtureError.invalidToolResult }
        delta = ["role": "assistant", "content": completion]
        finish = "stop"
      } else {
        delta = try toolCall(
          alias: "show_task_workspace", callID: workspaceCallID,
          arguments: ["presentation": "table", "root_task_id": id], tools: tools)
        finish = "tool_calls"
      }
    } else {
      delta = try toolCall(
        alias: "create_task", callID: createCallID, arguments: ["title": title], tools: tools)
      finish = "tool_calls"
    }
    let chunks: [[String: Any]] = [
      ["id": "lorvex-native-provider", "object": "chat.completion.chunk", "created": 1,
       "model": modelID,
       "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]],
      ["id": "lorvex-native-provider", "object": "chat.completion.chunk", "created": 1,
       "model": modelID,
       "choices": [["index": 0, "delta": [:], "finish_reason": finish]]],
    ]
    var stream = Data()
    for chunk in chunks {
      stream.append(Data("data: ".utf8))
      stream.append(try JSONSerialization.data(withJSONObject: chunk, options: [.sortedKeys]))
      stream.append(Data("\n\n".utf8))
    }
    stream.append(Data("data: [DONE]\n\n".utf8))
    guard let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"]) else { throw FixtureError.invalidRequest }
    return (stream, response)
  }

  private static func toolCall(
    alias: String, callID: String, arguments: [String: String], tools: [[String: Any]]
  ) throws -> [String: Any] {
    let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
      .filter { $0 == alias || $0.hasSuffix("__" + alias) }
    guard names.count == 1 else { throw FixtureError.missingTool }
    let argumentsData = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    return ["role": "assistant", "tool_calls": [[
      "index": 0, "id": callID, "type": "function",
      "function": ["name": names[0], "arguments": String(decoding: argumentsData, as: UTF8.self)],
    ]]]
  }

  private static func toolResult(
    _ callID: String, in messages: [[String: Any]]
  ) throws -> [String: Any]? {
    guard let message = messages.last(where: {
      $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == callID
    }) else { return nil }
    guard let object = try JSONSerialization.jsonObject(
      with: Data(text(message["content"]).utf8)) as? [String: Any] else {
      throw FixtureError.invalidToolResult
    }
    return object
  }

  private static func text(_ value: Any?) -> String {
    if let value = value as? String { return value }
    return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
  }

  private enum FixtureError: Error { case invalidRequest, missingTool, invalidToolResult }
}
#endif
