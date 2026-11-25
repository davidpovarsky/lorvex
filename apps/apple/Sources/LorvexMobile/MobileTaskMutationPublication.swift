import OSLog

/// Local visual controls wait for the committed write and canonical reads.
/// Existing callers can continue awaiting the best-effort system surfaces.
enum MobileTaskMutationPublication {
  case awaited
  case deferred
}

private let taskPublicationLog = Logger(subsystem: "com.itorah.lorvex", category: "task-surfaces")

extension MobileStore {
  func publishTaskMutationSurfaces(_ publication: MobileTaskMutationPublication) async {
    switch publication {
    case .awaited:
      await publishCoalescedTaskSurfaces()
    case .deferred:
      // The store is retained until the complete tail drains. The single-flight
      // below serializes publishers and re-reads after edits arriving mid-pass.
      Task { await publishCoalescedTaskSurfaces() }
    }
  }

  private func publishCoalescedTaskSurfaces() async {
    await taskSurfacesFlight.run {
      taskPublicationLog.debug("Beginning task widget publication")
      await publishMobileSyncSurfaces()
      taskPublicationLog.debug("Task widgets finished; beginning reminders")
      await rescheduleReminders()
      taskPublicationLog.debug("Task reminders finished; beginning badge")
      await updateBadge()
      taskPublicationLog.debug("Task publication completed")
    }
  }
}
