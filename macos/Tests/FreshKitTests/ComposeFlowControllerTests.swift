import CoreText
import XCTest
@testable import FreshKit

private actor HeldFlowMeasurement {
  private var calls = 0, active = 0, maximum = 0
  private var held: CheckedContinuation<Void, Never>?
  private var firstGeometry: UUID?
  func run(_ snapshot: ComposeDocumentSnapshot, environment: ComposeFlowMeasurement.Environment,
           previous: ComposeFlowMeasurement?, overlay: ComposeDocumentOverlay? = nil, presentation: ComposeDocumentPresentation) async throws -> ComposeFlowMeasurement {
    XCTAssertFalse(Thread.isMainThread)
    let flow = try ComposeFlowMeasurement.measure(snapshot, environment: environment, overlay: overlay, reusing: previous, presentation: presentation)
    calls += 1; active += 1; maximum = max(maximum, active)
    if calls == 1 {
      firstGeometry = flow.geometryGeneration
      await withCheckedContinuation { held = $0 }
    }
    active -= 1
    // A successful result deliberately outlives cancellation.
    return flow
  }
  func release() { held?.resume(); held = nil }
  func state() -> (calls: Int, maximum: Int, first: UUID?) { (calls, maximum, firstGeometry) }
}

private actor WrongFirstFlow {
  private var calls = 0
  func run(_ snapshot: ComposeDocumentSnapshot, environment: ComposeFlowMeasurement.Environment,
           previous: ComposeFlowMeasurement?, presentation: ComposeDocumentPresentation) throws -> ComposeFlowMeasurement {
    calls += 1
    if calls == 1 {
      // A different complete instance can reuse every numeric owner/header ID.
      let duplicate = try ComposeDocumentReceiver.decode(snapshot.baseline.data, owner: snapshot.document.owner,
        selection: snapshot.document.selectionRevision, decoration: snapshot.document.decorationRevision!)
      let foreign = ComposeDocumentSnapshot(document: duplicate, pane: snapshot.pane, baseline: snapshot.baseline)
      return try ComposeFlowMeasurement.measure(foreign, environment: environment)
    }
    return try ComposeFlowMeasurement.measure(snapshot, environment: environment, reusing: previous, presentation: presentation)
  }
  func count() -> Int { calls }
}

@MainActor
final class ComposeFlowControllerTests: XCTestCase {
  private func fixture() -> DocumentUpdateFixture {
    var value = DocumentUpdateFixture()
    value.pane.compose.text = String(repeating: "é café 👩🏽‍💻\r\n", count: 20)
    let count = UInt64(value.pane.compose.text.utf8.count)
    value.pane.compose.sourceEnd = count; value.pane.compose.documentLen = count
    value.pane.compose.segments[0].sourceEnd = count; value.pane.compose.segments[0].displayEnd = count
    return value
  }
  private func environment(_ width: CGFloat = 320) -> ComposeFlowMeasurement.Environment {
    .init(body: CTFontCreateWithName("Helvetica" as CFString, 18, nil),
      monospace: CTFontCreateWithName("Menlo" as CFString, 18, nil), width: width)
  }
  private func eventually(_ condition: () -> Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime + 4
    while !condition() && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 1_000_000) }
    XCTAssertTrue(condition()); if !condition() { throw POSIXError(.ETIMEDOUT) }
  }
  private func held(_ gate: HeldFlowMeasurement) async throws {
    let end = ProcessInfo.processInfo.systemUptime + 4
    while await gate.state().calls == 0 && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 1_000_000) }
    let state = await gate.state(); XCTAssertEqual(state.calls, 1)
  }

  func testLogicalValuePrecedesHeldGeometryAndSurvivesRefreshUntilReset() async throws {
    var fixture = fixture()
    let initial = try fixture.snapshot(), gate = HeldFlowMeasurement()
    let controller = ComposeFlowController { snapshot, environment, previous, overlay, presentation in
      try await gate.run(snapshot, environment: environment, previous: previous, overlay: overlay, presentation: presentation)
    }
    defer { controller.reset() }
    controller.update(snapshot: initial, environment: environment())
    try await held(gate)
    let logical = try XCTUnwrap(controller.presentation)
    XCTAssertEqual(logical.text, initial.document.text); XCTAssertNil(controller.flow)
    XCTAssertTrue(logical.document === initial.document)
    controller.update(snapshot: nil, environment: nil)
    XCTAssertTrue(controller.presentation === logical)
    fixture.pane.compose.selectionRevision += 1
    let next = try fixture.snapshot(id: 2)
    controller.update(snapshot: next, environment: environment(150))
    XCTAssertTrue(controller.presentation === logical, "the retained value keeps its original source owner")
    await gate.release()
    try await eventually { controller.status == .ready }
    XCTAssertTrue(controller.presentation === controller.flow?.presentation)
    XCTAssertTrue(controller.presentation?.document === next.document)
    XCTAssertEqual(controller.presentation?.text, logical.text)
    controller.reset(); XCTAssertNil(controller.presentation); XCTAssertNil(controller.flow)
  }

  func testGeometryFailureLeavesVerifiedTextAvailableAndAnotherDocumentRetiresIt() async throws {
    var fixture = fixture()
    let controller = ComposeFlowController { _, _, _, _, _ in throw ComposeFlowMeasurement.Failure.unavailable }
    defer { controller.reset() }
    let first = try fixture.snapshot()
    controller.update(snapshot: first, environment: environment())
    try await eventually { controller.status == .failed }
    XCTAssertEqual(controller.presentation?.text, first.document.text); XCTAssertNil(controller.flow)
    fixture.pane.buffer += 1
    controller.update(snapshot: try fixture.snapshot(id: 2), environment: environment())
    XCTAssertNil(controller.presentation, "another buffer must never inherit the old text")
    try await eventually { controller.status == .failed }
    XCTAssertEqual(controller.presentation?.document.owner.buffer, fixture.pane.buffer)
  }

  func testProposedGlobalSelectionKeepsOneValueUntilItsExactTokenIsConfirmedOrRetired() async throws {
    var fixture = fixture(); let initial = try fixture.snapshot(), controller = ComposeFlowController()
    defer { controller.reset() }
    let originalContext = UUID(), selectionContext = UUID(), nextContext = UUID(), token = UUID()
    controller.update(snapshot: initial, environment: environment(), context: originalContext)
    try await eventually { controller.status == .ready }
    let original = try XCTUnwrap(controller.presentation), geometry = controller.flow?.geometryGeneration
    XCTAssertTrue(controller.select([NSRange(location: 1, length: 2)], in: original, context: selectionContext, until: token))
    let proposal = try XCTUnwrap(controller.presentation)
    XCTAssertEqual(proposal.text, original.text); XCTAssertTrue(proposal.document === original.document)
    XCTAssertEqual(proposal.selectedRanges, [NSRange(location: 1, length: 2)])
    XCTAssertTrue(controller.flow?.presentation === proposal); XCTAssertEqual(controller.flow?.geometryGeneration, geometry)
    fixture.pane.compose.selectionRevision += 1; fixture.pane.compose.cursors[0].position = 2
    let next = try fixture.snapshot(id: 2)
    controller.update(snapshot: next, environment: environment(150), context: nextContext)
    controller.confirmSelection(UUID())
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertTrue(controller.presentation === proposal); XCTAssertEqual(controller.presentationContext, selectionContext)
    XCTAssertNil(controller.flow)
    controller.confirmSelection(token)
    try await eventually { controller.status == .ready }
    XCTAssertTrue(controller.presentation?.document === next.document); XCTAssertEqual(controller.presentationContext, nextContext)
    let again = try XCTUnwrap(controller.presentation), dropped = UUID()
    XCTAssertTrue(controller.select([NSRange(location: 0, length: 0)], in: again, context: UUID(), until: dropped))
    controller.retainSelection(while: [])
    try await eventually { controller.status == .ready }
    XCTAssertTrue(controller.presentation?.document === next.document)
  }

  func testHeaderUpdatesReuseCoordinatesButReplaceOwnershipAndEnvironmentChangesRemeasure() async throws {
    var fixture = fixture(); let initial = try fixture.snapshot(), controller = ComposeFlowController(), env = environment()
    defer { controller.reset() }
    controller.update(snapshot: initial, environment: env)
    try await eventually { controller.status == .ready }
    let first = try XCTUnwrap(controller.flow), generation = controller.generation
    controller.update(snapshot: initial, environment: env)
    XCTAssertEqual(controller.generation, generation)
    controller.update(snapshot: nil, environment: nil)
    XCTAssertNil(controller.flow)
    fixture.pane.compose.selectionRevision += 1; fixture.pane.compose.cursors[0].position = 2
    let next = try fixture.snapshot(id: 2)
    controller.update(snapshot: next, environment: env)
    try await eventually { controller.status == .ready }
    XCTAssertEqual(controller.flow?.geometryGeneration, first.geometryGeneration)
    XCTAssertTrue(controller.flow?.document === next.document)
    XCTAssertFalse(first.document.owns(window: 1, pane: fixture.pane))
    controller.update(snapshot: next, environment: environment(150))
    XCTAssertNil(controller.flow)
    try await eventually { controller.status == .ready }
    XCTAssertNotEqual(controller.flow?.geometryGeneration, first.geometryGeneration)
    XCTAssertEqual(controller.flow?.environment.width, 150)
  }

  func testManySupersededTargetsKeepOneWorkerAndPublishOnlyTheLatest() async throws {
    var fixture = fixture(); let initial = try fixture.snapshot(), gate = HeldFlowMeasurement()
    let controller = ComposeFlowController { snapshot, environment, previous, _, presentation in
      try await gate.run(snapshot, environment: environment, previous: previous, presentation: presentation)
    }
    defer { controller.reset() }
    var published: [UInt64] = []
    controller.onChange = { if let value = controller.flow { published.append(value.document.selectionRevision) } }
    controller.update(snapshot: initial, environment: environment())
    try await held(gate)
    for id in 2...20 {
      fixture.pane.compose.selectionRevision += 1
      controller.update(snapshot: try fixture.snapshot(id: UInt64(id)), environment: environment(CGFloat(300 + id)))
    }
    XCTAssertNil(controller.flow)
    let before = await gate.state(); XCTAssertEqual(before.calls, 1)
    await gate.release()
    try await eventually { controller.status == .ready }
    let state = await gate.state()
    XCTAssertEqual(state.calls, 2); XCTAssertEqual(state.maximum, 1)
    XCTAssertEqual(published, [fixture.pane.compose.selectionRevision])
    XCTAssertEqual(controller.flow?.environment.width, 320)
  }

  func testResetCannotReviveLateSuccessEvenWhenReconnectReusesAllIDs() async throws {
    let fixture = fixture(), first = try fixture.snapshot(), second = try fixture.snapshot(), gate = HeldFlowMeasurement()
    let controller = ComposeFlowController { snapshot, environment, previous, _, presentation in
      try await gate.run(snapshot, environment: environment, previous: previous, presentation: presentation)
    }
    defer { controller.reset() }
    controller.update(snapshot: first, environment: environment())
    try await held(gate)
    controller.reset(); XCTAssertNil(controller.flow)
    controller.update(snapshot: second, environment: environment())
    let waiting = await gate.state(); XCTAssertEqual(waiting.calls, 1)
    await gate.release()
    try await eventually { controller.status == .ready }
    let state = await gate.state()
    XCTAssertEqual(state.maximum, 1); XCTAssertEqual(state.calls, 2)
    XCTAssertTrue(controller.flow?.document === second.document)
    XCTAssertNotEqual(controller.flow?.geometryGeneration, state.first)
  }

  func testForeignResultFailsWithoutLoopingAndExplicitRetryBuildsTheCurrentDocument() async throws {
    let fixture = fixture(), snapshot = try fixture.snapshot(), wrong = WrongFirstFlow()
    let controller = ComposeFlowController { snapshot, environment, previous, _, presentation in
      try await wrong.run(snapshot, environment: environment, previous: previous, presentation: presentation)
    }
    defer { controller.reset() }
    controller.update(snapshot: snapshot, environment: environment())
    try await eventually { controller.status == .failed }
    XCTAssertNil(controller.flow)
    controller.update(snapshot: snapshot, environment: environment())
    try await Task.sleep(nanoseconds: 25_000_000)
    let count = await wrong.count(); XCTAssertEqual(count, 1)
    controller.retry()
    try await eventually { controller.status == .ready }
    XCTAssertTrue(controller.flow?.document === snapshot.document)
  }

  func testSupersededLocalDraftsCannotPublishUnderAnUnchangedFreshBaseline() async throws {
    let fixture = fixture(), snapshot = try fixture.snapshot(), gate = HeldFlowMeasurement()
    let controller = ComposeFlowController { snapshot, environment, previous, overlay, presentation in
      try await gate.run(snapshot, environment: environment, previous: previous, overlay: overlay, presentation: presentation)
    }
    defer { controller.reset() }
    let context = try XCTUnwrap(ComposeTextContext(.with { $0.text = fixture.pane.compose.text },documentLength: fixture.pane.compose.documentLen))
    var last: ComposeDocumentOverlay?
    for index in 1...10 {
      let text = "draft \(index) 👩🏽‍💻"
      let value = try XCTUnwrap(ComposeMarkedText(context: context,range: NSRange(location: 0,length: 0),source: 0..<0,
        text: NSAttributedString(string: text),selected: NSRange(location: text.utf16.count,length: 0)))
      let composition = try XCTUnwrap(ComposeComposition(primary: 1,values: [1:value]))
      last = try XCTUnwrap(ComposeDocumentOverlay(window: 1,pane: fixture.pane,composition: composition))
      controller.update(snapshot: snapshot,environment: environment(),overlay: last)
      if index == 1 { try await held(gate) }
    }
    XCTAssertNil(controller.flow)
    await gate.release()
    try await eventually { controller.status == .ready }
    let state = await gate.state()
    XCTAssertEqual(state.calls,2); XCTAssertEqual(state.maximum,1)
    XCTAssertEqual(controller.flow?.presentation.overlay?.id,last?.id)
    XCTAssertTrue(controller.flow?.presentation.text.hasPrefix("draft 10 👩🏽‍💻") == true)
    let equivalent = try XCTUnwrap(ComposeDocumentOverlay(window: 1, pane: fixture.pane,
      composition: last?.composition?.restore()))
    controller.update(snapshot: snapshot, environment: environment(220), overlay: equivalent)
    XCTAssertEqual(controller.presentation?.overlay?.id, equivalent.id)
    XCTAssertNil(controller.flow)
    try await eventually { controller.status == .ready }
    XCTAssertTrue(controller.flow?.presentation === controller.presentation)
    controller.update(snapshot: snapshot, environment: environment(), overlay: last)
    try await eventually { controller.status == .ready }
    let generation = controller.generation
    controller.update(snapshot: snapshot,environment: environment(),overlay: last)
    XCTAssertEqual(controller.generation,generation)
    controller.update(snapshot: snapshot,environment: environment())
    try await eventually { controller.status == .ready }
    XCTAssertNil(controller.flow?.presentation.overlay)
    XCTAssertEqual(controller.flow?.presentation.text,snapshot.document.text)
  }
}
