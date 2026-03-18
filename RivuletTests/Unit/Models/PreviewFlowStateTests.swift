import XCTest
@testable import Rivulet

final class PreviewFlowStateTests: XCTestCase {
    func testInitialStateStartsInEntryMorph() {
        let machine = PreviewStateMachine()

        XCTAssertEqual(machine.phase, .entryMorph)
        XCTAssertTrue(machine.isCarouselInputEnabled)
        XCTAssertFalse(machine.isExpanded)
        XCTAssertTrue(machine.motionLocked)
    }

    func testEntryCompletionTransitionsToCarouselStable() {
        var machine = PreviewStateMachine()

        machine.completeEntryMorph()
        machine.setMotionLocked(false)

        XCTAssertEqual(machine.phase, .carouselStable)
        XCTAssertTrue(machine.isCarouselInputEnabled)
        XCTAssertFalse(machine.isExpanded)
        XCTAssertFalse(machine.motionLocked)
    }

    func testExpandFlowTransitionsIntoExpandedState() {
        var machine = PreviewStateMachine()

        machine.completeEntryMorph()
        machine.setMotionLocked(false)
        machine.beginExpand()
        XCTAssertEqual(machine.phase, .expandingHero)
        XCTAssertFalse(machine.isCarouselInputEnabled)
        XCTAssertTrue(machine.isExpanded)
        XCTAssertTrue(machine.motionLocked)

        machine.finishExpand()

        XCTAssertEqual(machine.phase, .expandedHero)
        XCTAssertFalse(machine.isCarouselInputEnabled)
        XCTAssertTrue(machine.isExpanded)
        XCTAssertFalse(machine.motionLocked)
    }

    func testPagingLocksAndUnlocksMotionWithoutChangingStablePhase() {
        var machine = PreviewStateMachine()

        machine.completeEntryMorph()
        machine.setMotionLocked(false)

        machine.beginPaging()
        XCTAssertEqual(machine.phase, .carouselStable)
        XCTAssertTrue(machine.motionLocked)

        machine.finishPaging()
        XCTAssertEqual(machine.phase, .carouselStable)
        XCTAssertFalse(machine.motionLocked)
    }

    func testExitFromExpandedCollapsesToCarousel() {
        var machine = PreviewStateMachine()

        machine.completeEntryMorph()
        machine.setMotionLocked(false)
        machine.beginExpand()
        machine.finishExpand()
        machine.markDetailsStable()

        let action = machine.exitAction()

        XCTAssertEqual(action, .collapseToCarousel)
        XCTAssertEqual(machine.phase, .carouselStable)
        XCTAssertTrue(machine.isCarouselInputEnabled)
        XCTAssertFalse(machine.isExpanded)
    }

    func testExitFromCarouselDismissesOverlay() {
        var machine = PreviewStateMachine()

        machine.completeEntryMorph()
        machine.setMotionLocked(false)

        let action = machine.exitAction()

        XCTAssertEqual(action, .dismissOverlay)
        XCTAssertEqual(machine.phase, .carouselStable)
        XCTAssertTrue(machine.isCarouselInputEnabled)
    }

    func testCollapseToCarouselResetsExpandedStates() {
        var machine = PreviewStateMachine()

        machine.beginExpand()
        machine.collapseToCarousel()

        XCTAssertEqual(machine.phase, .carouselStable)
        XCTAssertTrue(machine.isCarouselInputEnabled)
        XCTAssertFalse(machine.isExpanded)
        XCTAssertFalse(machine.motionLocked)
    }

    func testPreviewLoadGateInvalidatesOlderTokens() {
        var gate = PreviewLoadGate()

        let firstToken = gate.begin()
        let secondToken = gate.begin()

        XCTAssertEqual(firstToken, 1)
        XCTAssertEqual(secondToken, 2)
        XCTAssertFalse(gate.isCurrent(firstToken))
        XCTAssertTrue(gate.isCurrent(secondToken))
    }
}
