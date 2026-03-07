import XCTest
@testable import Rivulet

final class PreviewFlowStateTests: XCTestCase {
    func testInitialStateStartsInEnteringCarousel() {
        let machine = PreviewStateMachine()

        XCTAssertEqual(machine.phase, .enteringCarousel)
        XCTAssertTrue(machine.isCarouselInputEnabled)
        XCTAssertFalse(machine.isExpanded)
    }

    func testEntryCompletionTransitionsToCarousel() {
        var machine = PreviewStateMachine()

        machine.completeEntry()

        XCTAssertEqual(machine.phase, .carousel)
        XCTAssertTrue(machine.isCarouselInputEnabled)
        XCTAssertFalse(machine.isExpanded)
    }

    func testExpandFlowTransitionsIntoExpandedState() {
        var machine = PreviewStateMachine()

        machine.completeEntry()
        machine.beginExpand()
        XCTAssertEqual(machine.phase, .expanding)
        XCTAssertFalse(machine.isCarouselInputEnabled)
        XCTAssertTrue(machine.isExpanded)

        machine.finishExpand()

        XCTAssertEqual(machine.phase, .expanded)
        XCTAssertFalse(machine.isCarouselInputEnabled)
        XCTAssertTrue(machine.isExpanded)
    }

    func testExitFromExpandedCollapsesToCarousel() {
        var machine = PreviewStateMachine()

        machine.completeEntry()
        machine.beginExpand()
        machine.finishExpand()

        let action = machine.exitAction()

        XCTAssertEqual(action, .collapseToCarousel)
        XCTAssertEqual(machine.phase, .carousel)
        XCTAssertTrue(machine.isCarouselInputEnabled)
        XCTAssertFalse(machine.isExpanded)
    }

    func testExitFromCarouselDismissesOverlay() {
        var machine = PreviewStateMachine()

        machine.completeEntry()

        let action = machine.exitAction()

        XCTAssertEqual(action, .dismissOverlay)
        XCTAssertEqual(machine.phase, .carousel)
        XCTAssertTrue(machine.isCarouselInputEnabled)
    }

    func testCollapseToCarouselResetsExpandedStates() {
        var machine = PreviewStateMachine()

        machine.beginExpand()
        machine.collapseToCarousel()

        XCTAssertEqual(machine.phase, .carousel)
        XCTAssertTrue(machine.isCarouselInputEnabled)
        XCTAssertFalse(machine.isExpanded)
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
