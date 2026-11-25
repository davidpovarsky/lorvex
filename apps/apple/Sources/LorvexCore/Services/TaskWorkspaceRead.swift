import Foundation

/// Canonical task records for a bounded visual workspace, including tasks that
/// have no dependency edges. The dependency graph remains a relationship query.
public struct TaskWorkspaceRead: Sendable {
  public let tasks: [LorvexTask]
  public let truncated: Bool
}

extension LorvexTaskServicing {
  public func loadTaskWorkspace(
    rootTaskID: LorvexTask.ID? = nil, listID: LorvexList.ID? = nil
  ) async throws -> TaskWorkspaceRead {
    let limit = 500
    let graph = try await getDependencyGraph(
      rootTaskID: rootTaskID, listID: listID, includeInactive: true)
    var tasks: [LorvexTask] = []
    var truncated = graph.truncated
    if rootTaskID == nil {
      let page = try await listTasks(
        status: "all", listID: listID, priority: nil, text: nil, limit: limit, offset: 0)
      tasks = page.tasks
      truncated = truncated || page.truncated
    }
    var included = Set(tasks.map(\.id))
    for node in graph.nodes where !included.contains(node.id) {
      try Task.checkCancellation()
      guard tasks.count < limit else {
        truncated = true
        break
      }
      tasks.append(try await loadTask(id: node.id))
      included.insert(node.id)
    }
    try Task.checkCancellation()
    return TaskWorkspaceRead(tasks: tasks, truncated: truncated)
  }
}
