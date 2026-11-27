import LorvexCore
import SwiftUI
import TaskVisualizationKit

/// The app supplies priority from its canonical tasks; the shared five
/// presentations continue to use their existing unmodified snapshot contract.
@MainActor
struct MobileTaskMatrixView: View {
  let snapshot: TaskWorkspaceSnapshot
  let entries: [MobileTaskMatrixEntry]
  let onAction: (TaskWorkspaceAction) async throws -> Void
  let edit: (LorvexTask, MobileTaskField) -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var search = ""
  @State private var pending = Set<String>()
  @State private var actionError: String?
  @FocusState private var searchFocused: Bool

  private var filtered: [MobileTaskMatrixEntry] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty ? entries : entries.filter {
      $0.task.title.localizedStandardContains(query) || $0.task.notes.localizedStandardContains(query)
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= 680 && !dynamicTypeSize.isAccessibilitySize
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(userContent: snapshot.title).font(.title2.weight(.semibold))
          Text(MobileTaskMatrixCopy.legend)
            .font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("lorvex.matrix.legend")
          HStack(spacing: 12) {
            TextField(MobileTaskMatrixCopy.search, text: $search)
              .textFieldStyle(.roundedBorder)
              .focused($searchFocused)
              .submitLabel(.search)
              .onSubmit { searchFocused = false }
              .accessibilityIdentifier("lorvex.matrix.search")
            Button(MobileTaskWorkspaceCopy.add, systemImage: "plus") { perform(.createTask) }
              .labelStyle(.iconOnly)
              .frame(minWidth: 44, minHeight: 44)
              .accessibilityIdentifier("lorvex.matrix.add")
          }
          ForEach(snapshot.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
              .font(.footnote).foregroundStyle(.secondary)
          }
          if let actionError {
            Label(actionError, systemImage: "exclamationmark.triangle")
              .font(.footnote).foregroundStyle(LorvexDesign.Palette.error)
              .accessibilityIdentifier("lorvex.matrix.error")
          }
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: wide ? 2 : 1),
            alignment: .leading, spacing: 12
          ) {
            ForEach(MobileTaskMatrixQuadrant.allCases) { quadrant in
              section(quadrant)
            }
          }
        }
        .padding(12)
        .padding(.bottom, 64)
      }
      .scrollDismissesKeyboard(.interactively)
      .accessibilityIdentifier("lorvex.matrix.scroll")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("lorvex.matrix.workspace")
  }

  private func section(_ quadrant: MobileTaskMatrixQuadrant) -> some View {
    let tasks = filtered.filter { $0.quadrant == quadrant }
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(quadrant.isHighPriority
            ? LorvexTask.Priority.p1.localizedPhrase
            : [LorvexTask.Priority.p2.localizedPhrase, LorvexTask.Priority.p3.localizedPhrase]
              .joined(separator: " · "))
            .font(.headline)
          Text(quadrant.isDue ? MobileTaskMatrixCopy.due : MobileTaskMatrixCopy.later)
            .font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Text(verbatim: tasks.count.formatted()).font(.headline.monospacedDigit())
      }
      .accessibilityElement(children: .combine)
      ForEach(tasks) { entry in card(entry) }
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: LorvexDesign.Radius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("lorvex.matrix.quadrant." + quadrant.rawValue)
  }

  private func card(_ entry: MobileTaskMatrixEntry) -> some View {
    let task = entry.task
    let busy = pending.contains(task.id)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Button {
          perform(.setCompleted(taskID: task.id, completed: task.status != .completed), taskID: task.id)
        } label: {
          Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
            .font(.title3).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(task.status == .completed ? MobileTaskMatrixCopy.reopen : MobileTaskMatrixCopy.complete)
        .accessibilityIdentifier("lorvex.matrix.complete." + task.id)
        .disabled(busy || entry.visual.isReadOnly)
        Button { perform(.openTask(task.id)) } label: {
          Text(userContent: task.title)
            .font(.body.weight(.medium)).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lorvex.matrix.open." + task.id)
      }
      Text(status(task.status)).font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("lorvex.matrix.status." + task.id)
      if entry.visual.isBlocked {
        Label(MobileTaskMatrixCopy.blocked, systemImage: "hand.raised")
          .font(.caption).foregroundStyle(LorvexDesign.Palette.warning)
      }
      if !task.dependsOn.isEmpty {
        HStack {
          Label(MobileTaskFieldCopy.title(.waitsOn), systemImage: "link")
          Text(verbatim: task.dependsOn.count.formatted())
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lorvex.matrix.dependencies." + task.id)
      }
      Button { edit(task, .priority) } label: {
        Label(task.priority.localizedPhrase, systemImage: task.priority.prioritySymbolName)
          .foregroundStyle(task.priority.priorityTint)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
      .accessibilityIdentifier("lorvex.matrix.priority." + task.id)
      .disabled(busy || entry.visual.isReadOnly)
      dateButton(task, field: .due, date: entry.visual.dueDate, busy: busy || entry.visual.isReadOnly)
      dateButton(task, field: .doOn, date: entry.visual.plannedDate, busy: busy || entry.visual.isReadOnly)
    }
    .padding(10)
    .background(.background, in: RoundedRectangle(cornerRadius: LorvexDesign.Radius.m))
    .overlay(RoundedRectangle(cornerRadius: LorvexDesign.Radius.m).stroke(.quaternary, lineWidth: 1))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("lorvex.matrix.card." + task.id)
  }

  private func dateButton(
    _ task: LorvexTask, field: MobileTaskField, date: Date?, busy: Bool
  ) -> some View {
    Button { edit(task, field) } label: {
      VStack(alignment: .leading, spacing: 3) {
        Text(MobileTaskFieldCopy.title(field)).font(.caption).foregroundStyle(.secondary)
        Text(date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? MobileTaskFieldCopy.noDate)
          .font(.subheadline)
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
    .accessibilityIdentifier("lorvex.matrix." + (field == .due ? "due." : "planned.") + task.id)
    .disabled(busy)
  }

  private func perform(_ action: TaskWorkspaceAction, taskID: String? = nil) {
    if let taskID { pending.insert(taskID) }
    actionError = nil
    Task {
      defer { if let taskID { pending.remove(taskID) } }
      do { try await onAction(action) }
      catch { actionError = (error as? LocalizedError)?.errorDescription ?? MobileTaskWorkspaceCopy.failed }
    }
  }

  private func status(_ status: LorvexTask.Status) -> String {
    switch status {
    case .open: MobileTaskWorkspaceCopy.open
    case .inProgress: MobileTaskWorkspaceCopy.inProgress
    case .someday: MobileTaskWorkspaceCopy.someday
    case .completed: MobileTaskWorkspaceCopy.completed
    case .cancelled: MobileTaskWorkspaceCopy.cancelled
    }
  }
}

enum MobileTaskMatrixCopy {
  static var title: String {
    String(localized: "visualTasks.matrix.title", defaultValue: "Matrix", table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var due: String {
    String(localized: "visualTasks.matrix.due", defaultValue: "Due today or overdue", table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var later: String {
    String(localized: "visualTasks.matrix.later", defaultValue: "Due later or no due date", table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var legend: String {
    String(localized: "visualTasks.matrix.legend", defaultValue: "Urgency follows the deadline. The planned day remains independent.", table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var search: String {
    String(localized: "tasks.search.prompt", defaultValue: "Search tasks", table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var complete: String {
    String(localized: "action.complete", defaultValue: "Complete", table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var reopen: String {
    String(localized: "action.reopen", defaultValue: "Reopen", table: "Localizable", bundle: MobileL10n.bundle)
  }
  static var blocked: String {
    String(localized: "task.status.blocked", defaultValue: "Blocked", table: "Localizable", bundle: MobileL10n.bundle)
  }
}
