import UIKit
import XCTest

/// Diagnostic copy: this is not the original acceptance XCTest and gives no acceptance credit.
final class LorvexDragCalibrationTests: XCTestCase {
  private var calibrationHold: TimeInterval = 0.8
  @MainActor func testLorvex0800ms() throws { try runCalibration(hold: 0.8) }
  @MainActor func testLorvex1500ms() throws { try runCalibration(hold: 1.5) }

  @MainActor private func runCalibration(hold: TimeInterval) throws {
    continueAfterFailure = false
    calibrationHold = hold
    let language = TestLanguage.he
    let app = XCUIApplication(bundleIdentifier: "com.itorah.lorvex")
    app.launchArguments = ["-setupCompleted", "YES", "-AppleLanguages", "(he)", "-AppleLocale", "he_IL"]
    app.launchEnvironment["LORVEX_CLOUD_SYNC"] = "off"
    app.launchEnvironment["TASK_WORKSPACE_BOARD_DIAGNOSTICS"] = "1"
    app.launch()
    openWorkspace(app, language: language)
    selectMode("table", app: app, language: language)
    if app.buttons[language.clearSearch].exists { clearSearch(app, language: language) }
    let taskID = "01a21daf-f1d7-74c5-a763-25b8300e1926"
    let taskButton = app.buttons["task-workspace.open." + taskID]
    XCTAssertTrue(taskButton.waitForExistence(timeout: 10))
    let title = taskButton.label
    searchFor(title, app: app)
    let lane = app.buttons["task-workspace.lane." + taskID]
    XCTAssertTrue(lane.waitForExistence(timeout: 10))
    if lane.label != language.inProgress {
      lane.tap()
      app.buttons["task-workspace.lane-choice." + taskID + ".in_progress"].tap()
      expectation(for: NSPredicate(format: "label == %@", language.inProgress), evaluatedWith: lane)
      waitForExpectations(timeout: 10)
    }
    let observation = XCTAttachment(string: "diagnosticOnly=true productSHA=02e7a9b3ac475b0c2b2738ad153c18d6ed650d64 hold=\(hold) taskID=\(taskID)")
    observation.name = "Lorvex activation calibration input"
    observation.lifetime = .keepAlways
    add(observation)
    XCTAssertTrue(try verifyNativeBoardLiftAndDrop(app, taskID: taskID, title: title, language: language))
  }

  @MainActor
  private func verifyHanlinToolWorkspace(
    _ app: XCUIApplication, title: String, language: TestLanguage
  ) -> String {
    let open = app.buttons["hanlin.open"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.tap()
    let editor = app.textViews["hanlin-chat-input"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText(language == .he
      ? "צור משימה בשם \"\(title)\" והצג אותה בטבלה."
      : "Create a task named \"\(title)\" and show it as a table.")
    let send = app.buttons["hanlin.composer.send"]
    XCTAssertTrue(send.isEnabled && send.isHittable)
    send.tap()
    let card = app.otherElements["hanlin.workspace.lorvex-acceptance-workspace"]
    XCTAssertTrue(card.waitForExistence(timeout: 30))
    let completion = app.textViews.matching(
      NSPredicate(format: "label == %@", "Native workspace acceptance completed.")).firstMatch
    XCTAssertTrue(completion.waitForExistence(timeout: 15))
    XCTAssertFalse(app.staticTexts["hanlin.error"].exists)
    let created = card.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", title)
    ).firstMatch
    XCTAssertTrue(created.waitForExistence(timeout: 10))
    let taskID = String(created.identifier.dropFirst("task-workspace.open.".count))
    XCTAssertFalse(taskID.isEmpty)
    attachHierarchy(app, "Lorvex \(language.rawValue) - actual Hanlin tool result creates a live card")

    let expand = card.buttons["hanlin.workspace.expand"]
    let transcript = app.scrollViews.containing(.button, identifier: "hanlin.workspace.expand").firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 5))
    for _ in 0..<4 {
      if app.frame.contains(expand.frame), expand.isHittable { break }
      if expand.frame.minY < transcript.frame.minY { transcript.swipeDown() }
      else { transcript.swipeUp() }
    }
    XCTAssertTrue(expand.isHittable)
    expand.tap()
    let expanded = app.otherElements["hanlin.workspace.expanded"]
    XCTAssertTrue(expanded.waitForExistence(timeout: 10))
    let expandedTask = expanded.buttons["task-workspace.open." + taskID]
    XCTAssertTrue(expandedTask.waitForExistence(timeout: 10))
    XCTAssertEqual(expandedTask.label, title)
    expandedTask.tap()
    let complete = app.buttons["task.detail.complete"]
    XCTAssertTrue(complete.waitForExistence(timeout: 10))
    complete.tap()
    XCTAssertTrue(app.buttons["task.detail.reopen"].waitForExistence(timeout: 10))
    attach(app, "Lorvex \(language.rawValue) - Hanlin-created task completed in canonical editor")
    app.buttons["lorvex.visual.detail.close"].tap()
    expectation(for: NSPredicate(format: "label == %@", language.reopenTask),
      evaluatedWith: expanded.buttons["task-workspace.complete." + taskID])
    waitForExpectations(timeout: 10)
    app.buttons["hanlin.workspace.expanded.close"].tap()
    XCTAssertTrue(expanded.waitForNonExistence(timeout: 10))

    // The shipped assistant toolbar opens the same current database as the
    // tool result card. Read the exact tool-created ID through that route too.
    app.buttons["hanlin.workspace.open"].tap()
    let sheet = app.otherElements["hanlin.workspace.sheet"]
    XCTAssertTrue(sheet.waitForExistence(timeout: 10))
    let toolbarTask = sheet.buttons["task-workspace.open." + taskID]
    fitGraphToTask(toolbarTask, app: app, language: language)
    XCTAssertEqual(toolbarTask.label, title)
    toolbarTask.tap()
    XCTAssertTrue(app.buttons["task.detail.reopen"].waitForExistence(timeout: 10))
    app.buttons["lorvex.visual.detail.close"].tap()
    app.buttons["hanlin.workspace.close"].tap()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    app.buttons["hanlin.close"].tap()
    XCTAssertTrue(open.waitForExistence(timeout: 10))

    clearSearch(app, language: language)
    searchFor(title, app: app)
    let canonical = app.buttons["task-workspace.open." + taskID]
    XCTAssertTrue(canonical.waitForExistence(timeout: 10))
    XCTAssertEqual(canonical.label, title)
    XCTAssertEqual(app.buttons["task-workspace.complete." + taskID].label, language.reopenTask)
    attachHierarchy(app, "Lorvex \(language.rawValue) - main workspace reads exact Hanlin task and saved completion")
    return taskID
  }

  @MainActor
  private func verifyAssistantControlDoesNotCoverWorkspace(
    _ app: XCUIApplication, mode: String, language: TestLanguage
  ) {
    let assistant = app.buttons["hanlin.open"]
    XCTAssertTrue(assistant.waitForExistence(timeout: 10))
    let viewport = app.frame
    let assistantFrame = assistant.frame
    XCTAssertTrue(assistant.isHittable && viewport.contains(assistantFrame))
    let workspace = app.descendants(matching: .any)
      .matching(identifier: "lorvex.visual.workspace").firstMatch
    XCTAssertTrue(workspace.waitForExistence(timeout: 10))
    let snapshot: any XCUIElementSnapshot
    do {
      snapshot = try workspace.snapshot()
    } catch {
      XCTFail("The complete native workspace Button snapshot must be available: \(error)")
      return
    }
    // Keep one coherent native AX tree. Scroll views also expose offscreen
    // descendant frames, so test only the pixels inside their real clipping
    // viewports. Other containers are not assumed to clip. Do not filter by
    // isHittable: a genuinely covered control must still fail this assertion.
    var pending = snapshot.children.map {
      (node: $0, visibleClip: viewport, scrollClips: [String]())
    }
    var controls: [(identifier: String, label: String, visibleFrame: CGRect)] = []
    var observations: [String] = []
    while let entry = pending.popLast() {
      let control = entry.node
      var visibleClip = entry.visibleClip
      var scrollClips = entry.scrollClips
      if control.elementType == .scrollView {
        let frame = control.frame
        guard frame.minX.isFinite, frame.minY.isFinite,
          frame.width.isFinite, frame.height.isFinite, !frame.isEmpty
        else {
          XCTFail("A native scroll viewport must have finite, nonempty geometry: \(control.identifier) \(frame)")
          return
        }
        visibleClip = visibleClip.intersection(frame)
        scrollClips.append("\(control.identifier)=\(frame)")
      }
      pending.append(contentsOf: control.children.map {
        (node: $0, visibleClip: visibleClip, scrollClips: scrollClips)
      })
      guard control.elementType == .button else { continue }
      let rawFrame = control.frame
      guard rawFrame.minX.isFinite, rawFrame.minY.isFinite,
        rawFrame.width.isFinite, rawFrame.height.isFinite
      else {
        XCTFail("A native workspace Button must have finite geometry: \(control.identifier) \(rawFrame)")
        return
      }
      let visibleFrame = rawFrame.intersection(visibleClip)
      observations.append(
        "\(control.identifier) [\(control.label)] raw=\(rawFrame) visible=\(visibleFrame) scrollClips=\(scrollClips)")
      guard !visibleFrame.isNull, !visibleFrame.isEmpty else { continue }
      controls.append((control.identifier, control.label, visibleFrame))
    }
    XCTAssertFalse(controls.isEmpty)
    let observation = XCTAttachment(
      string: "hanlin=\(assistantFrame)\nviewport=\(viewport)\n" + observations.joined(separator: "\n"))
    observation.name = "Lorvex \(language.rawValue) - \(mode) assistant and workspace control frames"
    observation.lifetime = .keepAlways
    add(observation)
    for control in controls {
      XCTAssertFalse(
        assistantFrame.intersects(control.visibleFrame),
        "The Hanlin entry must not cover \(control.identifier) [\(control.label)].")
    }
  }

  @MainActor
  private func verifyNativeGraphFooterOpen(
    _ app: XCUIApplication, title: String, language: TestLanguage
  ) {
    let workspace = app.descendants(matching: .any)
      .matching(identifier: "lorvex.visual.workspace").firstMatch
    let open = workspace.buttons[language.openTask]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    XCTAssertTrue(app.frame.contains(open.frame) && open.isHittable)
    XCTAssertFalse(app.buttons["hanlin.open"].frame.intersects(open.frame))
    attachHierarchy(app, "Lorvex \(language.rawValue) - native Flow footer before opening selected task")
    open.tap()
    XCTAssertTrue(app.buttons["task.detail.complete"].waitForExistence(timeout: 10))
    let detailTitle = app.staticTexts["task.detail.title"]
    XCTAssertTrue(detailTitle.waitForExistence(timeout: 10))
    XCTAssertEqual(detailTitle.label, title)
    XCTAssertTrue(detailTitle.isHittable)
    attach(app, "Lorvex \(language.rawValue) - native Flow footer opens the selected canonical task")
    app.buttons["lorvex.visual.detail.close"].tap()
    XCTAssertTrue(app.buttons["task-workspace.tab.graph"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func fitGraphToTask(
    _ node: XCUIElement, app: XCUIApplication, language: TestLanguage
  ) {
    let fit = app.buttons["task-workspace.graph.fit"]
    XCTAssertTrue(fit.waitForExistence(timeout: 10))
    fit.tap()
    XCTAssertTrue(
      node.waitForExistence(timeout: 10),
      "Show whole flow must expose the exact canonical task as an accessible node.")
    XCTAssertTrue(node.isHittable && app.frame.contains(node.frame))
    attachHierarchy(app, "Lorvex \(language.rawValue) - graph Fit exposes the canonical task")
  }

  @MainActor
  private func verifyNativeNetworkPanAndFit(
    _ node: XCUIElement, app: XCUIApplication, language: TestLanguage
  ) {
    let canvas = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.network.canvas").firstMatch
    let fit = app.buttons["task-workspace.network.fit"]
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    XCTAssertTrue(fit.waitForExistence(timeout: 10))
    fit.tap()
    let bounds = canvas.frame.intersection(app.frame)
    let occupied = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "task-workspace.open.")
    ).allElementsBoundByIndex.map { $0.frame } + [fit.frame]
    let before = node.frame
    XCTAssertTrue(node.isHittable && bounds.contains(before))
    let dx: CGFloat = before.midX < bounds.midX ? 80 : -80
    let dy: CGFloat = before.midY < bounds.midY ? 56 : -56
    let fractions: [CGFloat] = [0.15, 0.5, 0.85]
    let candidates = fractions.flatMap { x in
      fractions.map { y in CGPoint(
        x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y) }
    }
    guard let start = candidates.first(where: { point in
      bounds.contains(CGPoint(x: point.x + dx, y: point.y + dy))
        && !occupied.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(point) })
    }) else {
      XCTFail("The visible network must expose empty space for a native pan.")
      return
    }
    let end = CGPoint(x: start.x + dx, y: start.y + dy)
    let observation = XCTAttachment(
      string: "canvas=\(bounds) node=\(before) pan=\(start)->\(end)\n" + app.debugDescription)
    observation.name = "Lorvex \(language.rawValue) - native network observed controls"
    observation.lifetime = .keepAlways
    add(observation)
    let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    origin.withOffset(CGVector(dx: start.x - app.frame.minX, dy: start.y - app.frame.minY))
      .press(forDuration: 0.05, thenDragTo:
        origin.withOffset(CGVector(dx: end.x - app.frame.minX, dy: end.y - app.frame.minY)))
    // Native pointer actions wait for idle. Direct frame reads preserve the
    // physical outcome without nesting accessibility queries in a polling block.
    let afterPan = node.frame
    let panX = afterPan.midX - before.midX
    let panY = afterPan.midY - before.midY
    let pan = XCTAttachment(string: "before=\(before) afterPan=\(afterPan)")
    pan.name = "Lorvex \(language.rawValue) - native network pan measurement"
    pan.lifetime = .keepAlways
    add(pan)
    XCTAssertGreaterThan(panX * panX + panY * panY, 24 * 24)
    attach(app, "Lorvex \(language.rawValue) - native network panned")
    fit.tap()
    let afterFit = node.frame
    let fitX = afterFit.midX - before.midX
    let fitY = afterFit.midY - before.midY
    let fitted = XCTAttachment(string: "before=\(before) afterPan=\(afterPan) afterFit=\(afterFit)")
    fitted.name = "Lorvex \(language.rawValue) - native network Fit measurement"
    fitted.lifetime = .keepAlways
    add(fitted)
    XCTAssertLessThan(fitX * fitX + fitY * fitY, 24 * 24)
    XCTAssertTrue(node.isHittable && bounds.contains(afterFit))
    attach(app, "Lorvex \(language.rawValue) - native network Fit restored")
  }

  private struct NativeBoardCardObservation {
    let id: String
    let frame: CGRect
    let value: String
  }

  @MainActor
  private func nativeBoardCards(
    in column: XCUIElement, viewport: CGRect
  ) throws -> [NativeBoardCardObservation] {
    let snapshot = try column.snapshot()
    var pending = snapshot.children
    var seen = Set<String>()
    var result: [NativeBoardCardObservation] = []
    let prefix = "task-workspace.board.card."
    while let element = pending.popLast() {
      guard element.identifier.hasPrefix(prefix) else {
        pending.append(contentsOf: element.children)
        continue
      }
      // Capture the outer draggable container once. Its native descendants may
      // inherit the same identifier; they are not additional board cards.
      let id = String(element.identifier.dropFirst(prefix.count))
      XCTAssertFalse(id.isEmpty)
      XCTAssertTrue(seen.insert(id).inserted, "Native card IDs must be unique within a column.")
      let frame = element.frame
      let visible = frame.intersection(viewport)
      guard !frame.isEmpty, !visible.isNull,
            visible.width >= 44, visible.height >= 44 else { continue }
      result.append(NativeBoardCardObservation(
        id: id, frame: frame, value: element.value as? String ?? ""))
    }
    return result.sorted { $0.frame.minY < $1.frame.minY }
  }

  @MainActor
  private func verifyNativeBoardLiftAndDrop(
    _ app: XCUIApplication, taskID: String, title: String, language: TestLanguage
  ) throws -> Bool {
    clearSearch(app, language: language)
    let destinationID = "01a21db3-a128-7da5-958e-8a98afe18214"
    selectMode("board", app: app, language: language)
    let destinationColumn = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.column.open").firstMatch
    let sourceColumn = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.column.in_progress").firstMatch
    let collapse = app.buttons["task-workspace.board.collapse.open"]
    XCTAssertTrue(destinationColumn.waitForExistence(timeout: 10))
    XCTAssertTrue(collapse.isHittable)
    collapse.tap()
    XCTAssertTrue(destinationColumn.waitForNonExistence(timeout: 5))
    XCTAssertTrue(collapse.isHittable && app.frame.contains(collapse.frame))
    XCTAssertGreaterThanOrEqual(collapse.frame.width, 44)
    XCTAssertGreaterThanOrEqual(collapse.frame.height, 44)
    attach(app, "Lorvex \(language.rawValue) - collapsed column retains its native expand control")
    // Commands remain available through their own native menu, leaving the
    // card body free for the unchanged system lift-and-drop gesture below.
    let actions = app.buttons["task-workspace.board.actions." + taskID]
    XCTAssertTrue(actions.waitForExistence(timeout: 5))
    XCTAssertTrue(actions.isHittable && app.frame.contains(actions.frame))
    XCTAssertGreaterThanOrEqual(actions.frame.width, 44)
    XCTAssertGreaterThanOrEqual(actions.frame.height, 44)
    let dismissMenu = app.buttons["task-workspace.tab.board"]
      .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    actions.tap()
    let openCommand = app.buttons[language.openTask]
    XCTAssertTrue(openCommand.waitForExistence(timeout: 5))
    XCTAssertTrue(openCommand.isEnabled && openCommand.isHittable)
    let laneCommands = language == .he
      ? ["פתוחות", "בהמשך", "הושלמו", "בוטלו"]
      : ["Open", "Someday", "Completed", "Cancelled"]
    for title in laneCommands {
      let command = app.buttons[title]
      XCTAssertTrue(command.exists && command.isEnabled && command.isHittable)
    }
    attachHierarchy(app, "Lorvex \(language.rawValue) - explicit Board menu preserves task commands")
    dismissMenu.tap()
    XCTAssertTrue(openCommand.waitForNonExistence(timeout: 5))
    collapse.tap()
    XCTAssertTrue(destinationColumn.waitForExistence(timeout: 5))
    XCTAssertTrue(sourceColumn.waitForExistence(timeout: 5))
    let source = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.card." + taskID).firstMatch
    let destination = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.card." + destinationID).firstMatch
    XCTAssertTrue(source.waitForExistence(timeout: 10))
    XCTAssertTrue(destination.waitForExistence(timeout: 10))
    let board = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board").firstMatch
    XCTAssertTrue(board.waitForExistence(timeout: 5))
    // Expanding the adjacent column can leave only a narrow strip of the
    // draggable card on screen. Reveal its whole body before the original lift.
    for _ in 0..<5 {
      let boardViewport = board.frame.intersection(app.frame)
      let horizontalViewport = boardViewport.insetBy(dx: 12, dy: 0)
      let frame = source.frame
      guard !boardViewport.isEmpty, !frame.isEmpty,
            frame.width <= horizontalViewport.width else {
        XCTFail("The full native Board card must fit in the observed viewport.")
        throw NSError(domain: "NativeBoardAcceptance", code: 2)
      }
      let destinationFrame = destination.frame
      let destinationVisible = destinationFrame.intersection(horizontalViewport)
      if frame.minX >= horizontalViewport.minX && frame.maxX <= horizontalViewport.maxX,
         !destinationVisible.isNull, destinationVisible.width >= 44 {
        break
      }
      // Keep the whole source and a real 44-point destination on screen.
      // Aligning only the nearest source edge can hide the adjacent lane.
      var minimumShift = horizontalViewport.minX - frame.minX
      var maximumShift = horizontalViewport.maxX - frame.maxX
      if destinationFrame.minX >= frame.maxX {
        maximumShift = min(maximumShift, horizontalViewport.maxX - 44 - destinationFrame.minX)
      } else if destinationFrame.maxX <= frame.minX {
        minimumShift = max(minimumShift, horizontalViewport.minX + 44 - destinationFrame.maxX)
      }
      guard minimumShift <= maximumShift else {
        XCTFail("The whole source card and a native destination must fit together.")
        throw NSError(domain: "NativeBoardAcceptance", code: 6)
      }
      let shift = (minimumShift + maximumShift) / 2
      let panY = min(sourceColumn.frame.maxY, destinationColumn.frame.maxY,
        boardViewport.maxY) - 16
      guard panY > max(source.frame.maxY, destination.frame.maxY) + 12 else {
        XCTFail("Horizontal Board reveal must begin in the observed empty column space.")
        throw NSError(domain: "NativeBoardAcceptance", code: 3)
      }
      let panX = shift > 0 ? horizontalViewport.minX + 20 : horizontalViewport.maxX - 20
      let distance = min(abs(shift), horizontalViewport.width - 40) * (shift > 0 ? 1 : -1)
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let panStart = origin.withOffset(CGVector(dx: panX, dy: panY))
      let panEnd = origin.withOffset(CGVector(dx: panX + distance, dy: panY))
      // A short release at XCTest's default velocity flings the scroll view
      // past this measured position. Hold the end of this empty-space pan to
      // settle scrolling; the original 0.8-second card lift below is unchanged.
      panStart.press(forDuration: 0.1, thenDragTo: panEnd,
        withVelocity: .slow, thenHoldForDuration: 0.25)
      let panObservation = XCTAttachment(string:
        "source=\(frame) destination=\(destinationFrame) shift=\(shift)\n"
        + "afterSource=\(source.frame) afterDestination=\(destination.frame)")
      panObservation.name = "Lorvex \(language.rawValue) - native Board viewport preparation"
      panObservation.lifetime = .keepAlways
      add(panObservation)
    }
    let fullSourceViewport = sourceColumn.frame.intersection(board.frame)
      .intersection(app.frame).insetBy(dx: 2, dy: 6)
    guard !source.frame.isEmpty && fullSourceViewport.contains(source.frame) else {
      attachHierarchy(app, "Lorvex \(language.rawValue) - Board drag source not fully visible")
      XCTFail("The full native Board source card must be visible before the original lift.")
      throw NSError(domain: "NativeBoardAcceptance", code: 4)
    }
    let viewport = app.frame
    let sourceFrame = source.frame
    let destinationFrame = destination.frame
    let sourceVisible = sourceFrame.intersection(sourceColumn.frame).intersection(viewport)
    let destinationVisible = destinationFrame.intersection(destinationColumn.frame).intersection(viewport)
    for visible in [sourceVisible, destinationVisible] {
      XCTAssertFalse(visible.isNull)
      XCTAssertGreaterThanOrEqual(visible.width, 44)
      XCTAssertGreaterThanOrEqual(visible.height, 44)
    }
    XCTAssertTrue(source.isHittable && destination.isHittable)
    let from = source.coordinate(withNormalizedOffset: CGVector(
      dx: (sourceVisible.midX - sourceFrame.minX) / sourceFrame.width,
      dy: (sourceVisible.midY - sourceFrame.minY) / sourceFrame.height))
    let to = destination.coordinate(withNormalizedOffset: CGVector(
      dx: (destinationVisible.midX - destinationFrame.minX) / destinationFrame.width,
      dy: (destinationVisible.midY - destinationFrame.minY) / destinationFrame.height))
    for (card, point, id) in [(source, from.screenPoint, taskID),
                              (destination, to.screenPoint, destinationID)] {
      let buttons = card.descendants(matching: .button).allElementsBoundByIndex
      let required: Set<String> = ["task-workspace.open." + id,
        "task-workspace.complete." + id, "task-workspace.board.actions." + id]
      guard required.isSubset(of: Set(buttons.map(\.identifier))),
            buttons.allSatisfy({ !$0.frame.isEmpty }),
            !buttons.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(point) }) else {
        attachHierarchy(app, "Lorvex \(language.rawValue) - Board drag point overlaps a button")
        XCTFail("A native Board drag must use the actual card body outside every inner button.")
        throw NSError(domain: "NativeBoardAcceptance", code: 5)
      }
    }
    let observation = XCTAttachment(string:
      "source=\(sourceFrame) visible=\(sourceVisible) nativePoint=\(from.screenPoint)\n"
      + "destination=\(destinationFrame) visible=\(destinationVisible) nativePoint=\(to.screenPoint)")
    observation.name = "Lorvex \(language.rawValue) - native Board system lift and drop coordinates"
    observation.lifetime = .keepAlways
    add(observation)
    attach(app, "Lorvex \(language.rawValue) - adjacent native columns before system lift")
    // Each coordinate remains relative to its actual card; XCTest applies the
    // device orientation transform. The hold activates system lift, not a swipe.
    from.press(forDuration: calibrationHold, thenDragTo: to)
    attach(app, "Lorvex \(language.rawValue) - diagnostic native Board immediately after drop")
    attachHierarchy(app, "Lorvex \(language.rawValue) - diagnostic native Board immediately after drop hierarchy")
    selectMode("table", app: app, language: language)
    searchFor(title, app: app)
    let lane = app.buttons["task-workspace.lane." + taskID]
    expectation(for: NSPredicate(format: "label == %@", language.openLane), evaluatedWith: lane)
    waitForExpectations(timeout: 10)
    attach(app, "Lorvex \(language.rawValue) - table confirms native Board system drop saved Open")
    return true
  }

  @MainActor
  private func verifyNativeBoardScroll(
    _ app: XCUIApplication, primaryTitle: String, language: TestLanguage
  ) throws -> Bool {
    // Grow the real fixture only when the observed column needs more content,
    // after all five original captures. Never assume a fixed device capacity.
    clearSearch(app, language: language)
    let batch = String(UUID().uuidString.prefix(8))
    var created = 0
    var observedOverflow = false
    var before: [NativeBoardCardObservation] = []
    var viewport = CGRect.zero
    selectMode("board", app: app, language: language)
    let column = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.column.open").firstMatch
    while true {
      XCTAssertTrue(column.waitForExistence(timeout: 10))
      viewport = column.frame.intersection(app.frame)
      before = try nativeBoardCards(in: column, viewport: viewport)
      XCTAssertGreaterThanOrEqual(before.count, 2)
      let ordinals = try before.map { observation -> (index: Int, count: Int) in
        let ordinal = try XCTUnwrap(
          observation.value.split(separator: ",", maxSplits: 1).first,
          "The native card must expose its real index, count and lane.")
        let components = ordinal.split(separator: "/")
          .map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count == 2 else {
          XCTFail("The native card ordinal must contain exactly an index and count: \(observation.value)")
          throw NSError(domain: "NativeBoardAcceptance", code: 1)
        }
        let index = try XCTUnwrap(Int(components[0]))
        let count = try XCTUnwrap(Int(components[1]))
        XCTAssertGreaterThanOrEqual(index, 1)
        XCTAssertGreaterThanOrEqual(count, index)
        return (index, count)
      }
      XCTAssertEqual(Set(ordinals.map { $0.count }).count, 1)
      let total = try XCTUnwrap(ordinals.first?.count)
      let maximumVisibleIndex = ordinals.map { $0.index }.max() ?? 0
      let lowestEdge = before.map { $0.frame.maxY }.max() ?? viewport.minY
      observedOverflow = maximumVisibleIndex < total || lowestEdge > viewport.maxY + 48
      let growth = XCTAttachment(string:
        "created=\(created) column=\(viewport) total=\(total) "
        + "lastVisibleIndex=\(maximumVisibleIndex) lowestEdge=\(lowestEdge) "
        + "overflow=\(observedOverflow)\n"
        + before.map { "\($0.id) value=\($0.value) frame=\($0.frame)" }.joined(separator: "\n"))
      growth.name = "Lorvex \(language.rawValue) - measured Board fixture capacity \(created)"
      growth.lifetime = .keepAlways
      add(growth)
      if observedOverflow { break }
      guard created < 12 else {
        XCTFail("Twelve real additional tasks did not produce measurable native column overflow.")
        return false
      }
      let strides = zip(before, before.dropFirst()).map { $1.frame.minY - $0.frame.minY }
      let measuredStride = max(44, strides.reduce(0, +) / CGFloat(strides.count))
      let needed = max(1, Int(ceil((viewport.maxY + 64 - lowestEdge) / measuredStride)))
      let addition = min(12 - created, needed)
      selectMode("table", app: app, language: language)
      for _ in 0..<addition {
        created += 1
        let fixtureTitle = language.boardScrollPrefix + batch + String(format: " %02d", created)
        createTask(app, title: fixtureTitle)
        searchFor(fixtureTitle, app: app)
        let row = findTaskButton(named: fixtureTitle, app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(row.label, fixtureTitle)
        XCTAssertFalse(String(row.identifier.dropFirst("task-workspace.open.".count)).isEmpty)
        clearSearch(app, language: language)
      }
      selectMode("board", app: app, language: language)
    }
    XCTAssertTrue(observedOverflow)
    let touched = try XCTUnwrap(before.filter { viewport.contains($0.frame) }
      .min { abs($0.frame.midY - viewport.midY) < abs($1.frame.midY - viewport.midY) })
    XCTAssertTrue(touched.value.contains(language.openLane))
    let card = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.board.card." + touched.id).firstMatch
    XCTAssertTrue(card.isHittable)
    let title = app.buttons["task-workspace.open." + touched.id].label
    XCTAssertFalse(title.isEmpty)
    let beforeObservation = XCTAttachment(string:
      "column=\(viewport) touched=\(touched.id)\n"
      + before.map { "\($0.id) value=\($0.value) frame=\($0.frame)" }.joined(separator: "\n"))
    beforeObservation.name = "Lorvex \(language.rawValue) - native Board card scroll before"
    beforeObservation.lifetime = .keepAlways
    add(beforeObservation)
    attach(app, "Lorvex \(language.rawValue) - native Board before ordinary card swipe")
    let distance = min(CGFloat(120), touched.frame.midY - viewport.minY - 24)
    XCTAssertGreaterThanOrEqual(distance, 48)
    let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = card.coordinate(withNormalizedOffset: CGVector(
      dx: 0.5, dy: 0.5 - distance / touched.frame.height))
    let endpoint = CGPoint(x: touched.frame.midX, y: touched.frame.midY - distance)
    XCTAssertTrue(viewport.contains(endpoint))
    let gesture = XCTAttachment(string:
      "card=\(touched.frame) column=\(viewport) displayStart=\(CGPoint(x: touched.frame.midX, y: touched.frame.midY)) "
      + "displayEnd=\(endpoint) distance=\(distance) nativeStart=\(start.screenPoint) nativeEnd=\(end.screenPoint)")
    gesture.name = "Lorvex \(language.rawValue) - native Board ordinary swipe endpoints"
    gesture.lifetime = .keepAlways
    add(gesture)
    // This short card-centred touch moves through at most 120 display points.
    // It must scroll immediately; the separate 0.8s gesture tests system lift.
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    let after = try nativeBoardCards(in: column, viewport: viewport)
    let beforeIDs = Set(before.map(\.id))
    let afterIDs = Set(after.map(\.id))
    let common = beforeIDs.intersection(afterIDs)
    XCTAssertTrue(common.contains(touched.id), "The touched card must remain observable after the short swipe.")
    XCTAssertGreaterThanOrEqual(common.count, 2)
    let original = before.filter { common.contains($0.id) }
    let scrolled = after.filter { common.contains($0.id) }
    XCTAssertEqual(original.map(\.id), scrolled.map(\.id), "Scrolling must preserve card order.")
    for (first, last) in zip(original, scrolled) {
      XCTAssertFalse(first.value.isEmpty)
      XCTAssertEqual(first.value, last.value, "Native index, count and lane must remain unchanged.")
      XCTAssertEqual(first.frame.midX, last.frame.midX, accuracy: 2)
      XCTAssertLessThan(last.frame.midY - first.frame.midY, -24,
        "The touched card and neighboring cards must move together through native scrolling.")
    }
    let afterObservation = XCTAttachment(string:
      after.map { "\($0.id) value=\($0.value) frame=\($0.frame)" }.joined(separator: "\n"))
    afterObservation.name = "Lorvex \(language.rawValue) - native Board card scroll after"
    afterObservation.lifetime = .keepAlways
    add(afterObservation)
    attach(app, "Lorvex \(language.rawValue) - native Board ordinary swipe scrolls without reordering")
    selectMode("table", app: app, language: language)
    searchFor(title, app: app)
    let lane = app.buttons["task-workspace.lane." + touched.id]
    XCTAssertTrue(lane.waitForExistence(timeout: 10))
    XCTAssertEqual(lane.label, language.openLane)
    attach(app, "Lorvex \(language.rawValue) - canonical lane unchanged after native Board scroll")
    clearSearch(app, language: language)
    searchFor(primaryTitle, app: app)
    return true
  }

  @MainActor
  private func verifyNativeConnectionDrag(
    _ app: XCUIApplication, prerequisiteID: String, dependentID: String,
    language: TestLanguage
  ) {
    let connectionID = "task-workspace.connection.remove." + prerequisiteID + "." + dependentID
    openConnectionEditor(app)
    let connection = app.buttons[connectionID]
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: connection)
    waitForExpectations(timeout: 10)
    connection.tap()
    XCTAssertTrue(connection.waitForNonExistence(timeout: 10))
    closeConnectionEditor(app)
    app.buttons["task-workspace.graph.arrange"].tap()
    app.buttons["task-workspace.graph.fit"].tap()
    let output = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.graph.handle.out." + prerequisiteID).firstMatch
    let input = app.descendants(matching: .any)
      .matching(identifier: "task-workspace.graph.handle.in." + dependentID).firstMatch
    XCTAssertTrue(output.waitForExistence(timeout: 10))
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    XCTAssertTrue(app.frame.contains(output.frame) && app.frame.contains(input.frame))
    XCTAssertTrue(output.isHittable && input.isHittable)
    attach(app, "Lorvex \(language.rawValue) - native Flow endpoints before connecting")
    output.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo:
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    openConnectionEditor(app)
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: connection)
    waitForExpectations(timeout: 10)
    attach(app, "Lorvex \(language.rawValue) - canonical edge saved by native Flow drag")
    closeConnectionEditor(app)
  }

  @MainActor
  private func openConnectionEditor(_ app: XCUIApplication) {
    app.buttons["task-workspace.options"].tap()
    app.buttons["task-workspace.connections"].tap()
    XCTAssertTrue(app.buttons["task-workspace.connection.done"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func closeConnectionEditor(_ app: XCUIApplication) {
    let done = app.buttons["task-workspace.connection.done"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done)
    waitForExpectations(timeout: 10)
    done.tap()
    XCTAssertTrue(done.waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func tapDateSwitch(_ row: XCUIElement, app: XCUIApplication) {
    // SwiftUI exposes the whole Form row as a Switch, with the actual native
    // switch as its descendant. A row-centre pointer tap hits the empty label
    // area. Select the observed native control without assuming an RTL side.
    let control = row.switches.firstMatch
    XCTAssertTrue(control.waitForExistence(timeout: 5))
    XCTAssertTrue(row.frame.contains(control.frame) && app.frame.contains(control.frame))
    XCTAssertTrue(control.isHittable)
    control.tap()
  }

  @MainActor
  private func selectConnectionChoice(_ title: String, app: XCUIApplication) {
    // The native Picker presents its choices inside a collection view. The
    // graph behind the sheet exposes the same real task title, so selecting
    // from every app button is ambiguous once graph accessibility is enabled.
    let choice = app.collectionViews.buttons[title]
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    XCTAssertTrue(choice.isHittable)
    choice.tap()
  }

  @MainActor
  private func createTask(_ app: XCUIApplication, title: String) {
    app.buttons["task-workspace.create"].tap()
    let field = app.textFields["lorvex.visual.create.title"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(title)
    app.buttons["lorvex.visual.create.save"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 10))
  }

  @MainActor
  private func openWorkspace(_ app: XCUIApplication, language: TestLanguage) {
    let tasks = app.tabBars.buttons[language.tasks].firstMatch
    if tasks.waitForExistence(timeout: 15) { tasks.tap() }
    else {
      let adaptiveTasks = app.buttons[language.tasks].firstMatch
      XCTAssertTrue(adaptiveTasks.waitForExistence(timeout: 5))
      adaptiveTasks.tap()
    }
    let open = app.buttons["lorvex.visual.open"]
    XCTAssertTrue(open.waitForExistence(timeout: 15))
    open.tap()
    XCTAssertTrue(app.buttons["task-workspace.create"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.buttons["task-workspace.tab.graph"].label, language.modeTitle("graph"))
  }

  @MainActor
  private func selectMode(_ mode: String, app: XCUIApplication, language: TestLanguage) {
    let tab = app.buttons["task-workspace.tab." + mode]
    XCTAssertTrue(tab.waitForExistence(timeout: 10))
    let picker = app.scrollViews.containing(.button, identifier: "task-workspace.tab." + mode).firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    // XCTest can throw while hit-testing an offscreen accessibility element.
    // Use observed geometry first; physical scroll direction also works in RTL.
    for _ in 0..<5 {
      let viewport = picker.frame.intersection(app.frame)
      let buttonFrame = tab.frame
      if !viewport.isEmpty && !buttonFrame.isEmpty && viewport.contains(buttonFrame) {
        break
      }
      if buttonFrame.maxX > viewport.maxX {
        picker.swipeLeft()
      } else if buttonFrame.minX < viewport.minX {
        picker.swipeRight()
      } else {
        XCTFail("The mode strip must be visible before selecting \(mode): \(viewport), button \(buttonFrame).")
        return
      }
    }
    let viewport = picker.frame.intersection(app.frame)
    guard !viewport.isEmpty, !tab.frame.isEmpty, viewport.contains(tab.frame) else {
      XCTFail("The \(mode) tab did not enter the visible mode strip: \(viewport), button \(tab.frame).")
      return
    }
    XCTAssertTrue(tab.isHittable, "The \(mode) presentation must be reachable in \(language.rawValue).")
    tab.tap()
    expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: tab)
    waitForExpectations(timeout: 5)
    XCTAssertEqual(tab.label, language.modeTitle(mode))
    let surfaceID: String
    switch mode {
    case "graph": surfaceID = "task-workspace.graph.canvas"
    case "network": surfaceID = "task-workspace.network.canvas"
    default: surfaceID = "task-workspace." + mode
    }
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: surfaceID)
        .firstMatch.waitForExistence(timeout: 10),
      "The selected \(mode) must render its actual native content.")
  }

  @MainActor
  private func findTaskButton(named title: String, app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task-workspace.open.", title)
    ).firstMatch
  }

  @MainActor
  private func searchFor(_ title: String, app: XCUIApplication) {
    let search = app.textFields["task-workspace.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText(title + "\n")
  }

  @MainActor
  private func clearSearch(_ app: XCUIApplication, language: TestLanguage) {
    app.buttons[language.clearSearch].tap()
  }

  @MainActor
  private func attachHierarchy(_ app: XCUIApplication, _ name: String) {
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = name + " hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    attach(app, name)
  }

  @MainActor
  private func attach(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }

  private enum TestLanguage: String {
    case en, he

    var locale: String { self == .he ? "he_IL" : "en_US" }
    var tasks: String { self == .he ? "משימות" : "Tasks" }
    var openLane: String { self == .he ? "פתוחות" : "Open" }
    var inProgress: String { self == .he ? "בביצוע" : "In Progress" }
    var taskPrefix: String { self == .he ? "בדיקת משימה " : "Visual task " }
    var hanlinTaskPrefix: String { self == .he ? "נוצרה דרך Hanlin " : "Hanlin created " }
    var dragTargetPrefix: String { self == .he ? "יעד לגרירה " : "Drag destination " }
    var boardScrollPrefix: String { self == .he ? "גלילת לוח " : "Board scroll " }
    var prerequisitePrefix: String { self == .he ? "הכנה " : "Prepare " }
    var editConnections: String { self == .he ? "עריכת קשרים" : "Edit connections" }
    var removeConnection: String { self == .he ? "הסרת קשר" : "Remove connection" }
    var openTask: String { self == .he ? "פתיחת משימה" : "Open task" }
    var reopenTask: String { self == .he ? "פתיחת המשימה מחדש" : "Reopen task" }
    var clearSearch: String { self == .he ? "ניקוי חיפוש" : "Clear search" }
    var hasDueDate: String { self == .he ? "יש מועד יעד" : "Has due date" }
    var setDate: String { self == .he ? "קביעת תאריך" : "Set date" }

    func modeTitle(_ mode: String) -> String {
      switch (self, mode) {
      case (.he, "graph"): "זרימה"
      case (.he, "board"): "לוח"
      case (.he, "timeline"): "ציר זמן"
      case (.he, "network"): "קשרים"
      case (.he, "table"): "טבלה"
      case (_, "graph"): "Flow"
      case (_, "board"): "Board"
      case (_, "timeline"): "Timeline"
      case (_, "network"): "Connections"
      case (_, "table"): "Table"
      default: mode
      }
    }
  }
}
