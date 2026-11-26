import LorvexCore
import LorvexMobile

#if canImport(UIKit)
  import UIKit

  /// Finishes the app's save and sync work as it leaves the foreground, then
  /// suspends the database.
  ///
  /// The managed store must give up its locks before iOS suspends the process:
  /// holding one across suspension is what iOS terminates as `0xdead10cc`
  /// (see `DatabaseSuspension`). Suspending at once, though, would leave an
  /// edit made just before leaving the app queued until the next launch, and
  /// would lose a daily review entry still being typed. So the flush first
  /// writes the drafts that save on their own, then runs one sync pass inside a
  /// background task, and suspends the database when that pass ends or the
  /// task's time runs out, whichever comes first. Other background work still
  /// using the database at that point keeps it open until it ends too.
  /// Returning to the foreground before then resumes the database as usual, and
  /// the late suspension is skipped because the app is no longer in the
  /// background.
  @MainActor
  enum BackgroundSyncFlush {
    @discardableResult
    static func flushThenSuspend(
      store: MobileStore, cloudAccount: LorvexCloudAccountState? = nil
    ) -> Task<Void, Never>? {
      BackgroundDatabaseWork.begin()
      let flush = Flush()
      flush.taskID = UIApplication.shared.beginBackgroundTask(withName: "Lorvex sync") {
        flush.expire()
      }
      guard flush.taskID != .invalid else {
        flush.finish()
        return nil
      }
      flush.work = Task { @MainActor in
        defer { flush.finish() }
        guard flush.canContinue else { return }
        await store.flushAutosaveDraftsBeforeSuspension()
        // An autosave already in flight may finish after expiration. Keep that save,
        // but do not start a new sync after this flush gave up its database ownership.
        guard flush.canContinue else { return }
        // Lorvex Cloud owns the canonical outbox while CloudKit is disabled.
        // Join its cancelled foreground poll and flush the just-saved drafts
        // within this same OS background budget; do not start a separate task.
        await cloudAccount?.flushBeforeSuspension()
        guard flush.canContinue else { return }
        await store.flushCloudSyncBeforeSuspension()
      }
      return flush.work
    }

    /// One flush's background task; `finish()` runs its exit once.
    @MainActor
    private final class Flush {
      var taskID: UIBackgroundTaskIdentifier = .invalid
      var work: Task<Void, Never>?
      private var finished = false

      var canContinue: Bool { !finished && !Task.isCancelled }

      func expire() {
        work?.cancel()
        finish()
      }

      func finish() {
        guard !finished else { return }
        finished = true
        work = nil
        BackgroundDatabaseWork.end()
        if taskID != .invalid {
          UIApplication.shared.endBackgroundTask(taskID)
          taskID = .invalid
        }
      }
    }
  }
#endif
