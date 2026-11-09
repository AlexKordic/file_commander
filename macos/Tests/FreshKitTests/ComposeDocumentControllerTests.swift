import XCTest
@testable import FreshKit

private actor HeldDocumentDecode {
  private var calls = 0, active = 0, maximum = 0
  private var held: CheckedContinuation<Void,Never>?
  func run(_ job: ComposeDocumentDecode) async throws -> ComposeDocumentSnapshot {
    let value = try job.decode()
    calls += 1; active += 1; maximum = max(maximum,active)
    if calls == 1 { await withCheckedContinuation { held = $0 } }
    active -= 1
    // Deliberately return a successful value even after cancellation. The
    // coordinator must retire its ownership, not trust cooperative cancellation.
    return value
  }
  func release() { held?.resume(); held = nil }
  func state() -> (Int,Int) { (calls,maximum) }
}

@MainActor
final class ComposeDocumentControllerTests: XCTestCase {
  private func eventually(_ condition: ()->Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime+3
    while !condition() && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds:1_000_000) }
    XCTAssertTrue(condition()); if !condition() { throw POSIXError(.ETIMEDOUT) }
  }
  private func held(_ gate: HeldDocumentDecode) async throws {
    let end=ProcessInfo.processInfo.systemUptime+3
    while await gate.state().0 == 0 && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds:1_000_000) }
    let calls=await gate.state().0; XCTAssertEqual(calls,1)
  }
  private func feed(_ controller: ComposeDocumentController, _ chunk: WireComposeDocumentChunk) {
    for part in DocumentUpdateFixture.parts(chunk) { controller.receive(part) }
  }

  func testDemandCoalescesTheLatestTargetWithoutCancellingItsOwnFormatterPreparation() async throws {
    var requests:[WireComposeDocumentRequest]=[],fixture=DocumentUpdateFixture()
    let controller=ComposeDocumentController(quietNanoseconds:15_000_000,send:{requests.append($0)})
    defer {controller.reset()}
    controller.update(window:1,pane:fixture.pane,supported:true)
    try await Task.sleep(nanoseconds:25_000_000);XCTAssertTrue(requests.isEmpty)
    controller.activate()
    for _ in 0..<20 { fixture.pane.compose.selectionRevision += 1;controller.update(window:1,pane:fixture.pane,supported:true) }
    try await eventually {requests.filter(\.hasOwner).count==1}
    let request=try XCTUnwrap(requests.first(where:\.hasOwner));XCTAssertEqual(request.selectionRevision,fixture.pane.compose.selectionRevision)
    XCTAssertTrue(request.hasBaseID);XCTAssertEqual(request.baseID,0)
    for _ in 0..<5 { fixture.pane.compose.decorationRevision += 1;controller.update(window:1,pane:fixture.pane,supported:true) }
    XCTAssertFalse(requests.contains(where:{$0.cancel}),"preparing full formatting must not cancel its own read")
    feed(controller,try fixture.chunk(id:request.id))
    try await eventually {controller.status == .ready}
    XCTAssertEqual(controller.snapshot?.document.decorationRevision,fixture.pane.compose.decorationRevision)
    XCTAssertEqual(controller.snapshot?.pane.spans,fixture.pane.compose.spans)
    let generation=controller.generation,count=requests.count
    fixture.pane.compose.viewport.position=100
    controller.update(window:1,pane:fixture.pane,supported:true)
    try await Task.sleep(nanoseconds:25_000_000)
    XCTAssertEqual(controller.generation,generation);XCTAssertEqual(requests.count,count)
    fixture.pane.compose.decorationRevision += 1;controller.update(window:1,pane:fixture.pane,supported:true)
    try await eventually {requests.filter(\.hasOwner).count==2}
    let retired=try XCTUnwrap(requests.last(where:\.hasOwner))
    fixture.pane.compose.decorationRevision += 1;controller.update(window:1,pane:fixture.pane,supported:true)
    controller.receive(.with {$0.id=retired.id;$0.error="Formatting changed";$0.done=true})
    try await eventually {requests.filter(\.hasOwner).count==3}
    let retry=try XCTUnwrap(requests.last(where:\.hasOwner))
    feed(controller,try fixture.chunk(id:retry.id));try await eventually {controller.status == .ready}
  }

  func testSupersededDecodeKeepsOneWorkerAndSeedsTheLatestTargetWithItsVerifiedBaseline() async throws {
    let gate=HeldDocumentDecode();var requests:[WireComposeDocumentRequest]=[],fixture=DocumentUpdateFixture()
    let controller=ComposeDocumentController(quietNanoseconds:0,decode:{try await gate.run($0)},send:{requests.append($0)})
    defer {controller.reset()}
    var published:[UInt64]=[];controller.onChange={if let value=controller.snapshot {published.append(value.document.selectionRevision)}}
    controller.update(window:1,pane:fixture.pane,supported:true);controller.activate()
    try await eventually {requests.contains(where:\.hasOwner)}
    let first=try XCTUnwrap(requests.first(where:\.hasOwner));let base=try fixture.snapshot(id:first.id).baseline
    feed(controller,try fixture.chunk(id:first.id));try await held(gate)
    fixture.pane.compose.selectionRevision += 1;fixture.pane.compose.cursors[0].position=2
    controller.update(window:1,pane:fixture.pane,supported:true)
    XCTAssertNil(controller.snapshot);XCTAssertEqual(requests.filter(\.hasOwner).count,1)
    await gate.release()
    try await eventually {requests.filter(\.hasOwner).count==2}
    let next=try XCTUnwrap(requests.last(where:\.hasOwner));XCTAssertEqual(next.baseID,first.id)
    feed(controller,try fixture.chunk(id:next.id,base:base))
    try await eventually {controller.status == .ready}
    XCTAssertEqual(Set(published),[fixture.pane.compose.selectionRevision]);XCTAssertEqual(controller.lastEncoding,1)
    let state=await gate.state();XCTAssertEqual(state.1,1)
  }

  func testResetAndReconnectCannotReviveALateSuccessfulWorkerOrReuseItsBaseline() async throws {
    let gate=HeldDocumentDecode();var requests:[WireComposeDocumentRequest]=[],fixture=DocumentUpdateFixture()
    let controller=ComposeDocumentController(quietNanoseconds:0,decode:{try await gate.run($0)},send:{requests.append($0)})
    defer {controller.reset()}
    controller.update(window:1,pane:fixture.pane,supported:true);controller.activate()
    try await eventually {requests.contains(where:\.hasOwner)}
    let first=try XCTUnwrap(requests.first(where:\.hasOwner));let late=try fixture.chunk(id:first.id)
    feed(controller,late);try await held(gate);controller.reset()
    XCTAssertTrue(requests.contains(where:{$0.id==first.id && $0.cancel}))
    // A restarted backend can reuse every numeric owner ID. Connection reset
    // must still retire the old success and start with a fresh binary base.
    controller.update(window:1,pane:fixture.pane,supported:true);controller.activate()
    XCTAssertEqual(requests.filter(\.hasOwner).count,1)
    await gate.release()
    try await eventually {requests.filter(\.hasOwner).count==2}
    let next=try XCTUnwrap(requests.last(where:\.hasOwner));XCTAssertEqual(next.baseID,0)
    XCTAssertNil(controller.snapshot)
    let count=requests.count;feed(controller,late);XCTAssertEqual(requests.count,count)
    feed(controller,try fixture.chunk(id:next.id));try await eventually {controller.status == .ready}
    XCTAssertEqual(controller.snapshot?.document.owner,fixture.owner)
    let state=await gate.state();XCTAssertEqual(state.1,1)
  }

  func testUnsupportedPendingAndSilentPeersDoNotLoopOrKeepAnOwnedReadAlive() async throws {
    var requests:[WireComposeDocumentRequest]=[],fixture=DocumentUpdateFixture()
    let controller=ComposeDocumentController(quietNanoseconds:0,timeoutNanoseconds:20_000_000,send:{requests.append($0)})
    defer {controller.reset()}
    controller.update(window:1,pane:fixture.pane,supported:false);controller.activate()
    fixture.pane.compose.ready=false;fixture.pane.compose.currentProjection=false
    controller.update(window:1,pane:fixture.pane,supported:true)
    try await Task.sleep(nanoseconds:30_000_000);XCTAssertTrue(requests.isEmpty)
    fixture.pane.compose.ready=true;fixture.pane.compose.currentProjection=true
    controller.update(window:1,pane:fixture.pane,supported:true)
    try await eventually {controller.status == .failed}
    let first=try XCTUnwrap(requests.first(where:\.hasOwner));XCTAssertTrue(requests.contains(where:{$0.id==first.id && $0.cancel}))
    controller.update(window:1,pane:fixture.pane,supported:true)
    try await Task.sleep(nanoseconds:30_000_000);XCTAssertEqual(requests.filter(\.hasOwner).count,1)
    controller.retry();try await eventually {requests.filter(\.hasOwner).count==2}
    let next=try XCTUnwrap(requests.last(where:\.hasOwner))
    feed(controller,try fixture.chunk(id:first.id));XCTAssertNil(controller.snapshot)
    var bad=try fixture.chunk(id:next.id);bad.resultDigest=Data()
    feed(controller,bad);XCTAssertEqual(controller.status,.failed)
    XCTAssertTrue(requests.contains(where:{$0.id==next.id && $0.cancel}))
  }
}
