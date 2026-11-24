/// Normal Lorvex task, list and calendar updates are authorized when a
/// connected user grants the write scope or enables their in-app assistant.
/// The host and ChatGPT may still require confirmation for destructive tools.
public enum LorvexHanlinWritePolicy: Sendable {
  private static let routine = Set([
    "create_task","update_task","complete_task","reopen_task",
    "start_task","pause_task","plan_task","create_event","create_list",
    "complete_habit","uncomplete_habit","add_task_dependency","remove_task_dependency"
  ])
  public static func mayAutomaticallyAuthorize(_ alias:String) -> Bool {
    routine.contains(alias)
  }
}
