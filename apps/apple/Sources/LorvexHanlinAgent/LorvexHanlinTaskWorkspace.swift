import Foundation

/// A validated view request, not a copy of task data. The app re-reads canonical
/// tasks whenever this component is displayed or the task revision changes.
public struct LorvexHanlinTaskWorkspace: Identifiable, Equatable, Sendable {
  public let id: String
  public let presentation: String
  public let rootTaskID: String?
  public let listID: String?

  public init?(callID: String, resultJSON: String) {
    struct Result: Decodable {
      let presentation: String
      let rootTaskID: String?
      let listID: String?
    }
    guard let data = resultJSON.data(using: .utf8),
      let result = try? JSONDecoder().decode(Result.self, from: data),
      ["graph", "board", "timeline", "network", "table", "matrix"].contains(result.presentation)
    else { return nil }
    id = callID
    presentation = result.presentation
    rootTaskID = result.rootTaskID
    listID = result.listID
  }
}
