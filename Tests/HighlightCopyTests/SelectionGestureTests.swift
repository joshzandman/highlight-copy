import CoreGraphics
import XCTest
@testable import HighlightCopyCore

final class SelectionGestureTests: XCTestCase {
    func testDragCopiesChangedText() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.mouseDragged(to: CGPoint(x: 10, y: 0))
        gesture.mouseUp(at: CGPoint(x: 12, y: 0), clickCount: 1)
        XCTAssertTrue(gesture.isHighlight)
        XCTAssertTrue(CopyDecision.shouldCopy(gesture: gesture, selectedText: "hello"))
    }

    func testPlainClickDoesNotCopy() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "already")
        gesture.mouseUp(at: CGPoint(x: 1, y: 1), clickCount: 1)
        XCTAssertFalse(gesture.isHighlight)
        XCTAssertFalse(CopyDecision.shouldCopy(gesture: gesture, selectedText: "new"))
    }

    func testUnchangedSelectionDoesNotCopy() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "same")
        gesture.mouseDragged(to: CGPoint(x: 20, y: 4))
        XCTAssertFalse(CopyDecision.shouldCopy(gesture: gesture, selectedText: "same"))
    }

    func testCopyTargetExposesSelectedTextOnlyForText() {
        XCTAssertEqual(CopyTarget.text(selected: "word").selectedText, "word")
        XCTAssertNil(CopyTarget.text(selected: nil).selectedText)
        XCTAssertNil(CopyTarget.other.selectedText)
        XCTAssertNil(CopyTarget.secure.selectedText)
        XCTAssertTrue(CopyTarget.secure.isSecure)
        XCTAssertFalse(CopyTarget.text(selected: nil).isSecure)
    }

    func testDoubleClickKeepsFirstSnapshot() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.mouseUp(at: .zero, clickCount: 1)
        gesture.mouseDown(at: .zero, clickCount: 2, selectedText: "word")
        gesture.mouseUp(at: .zero, clickCount: 2)
        XCTAssertEqual(gesture.snapshot, "")
        XCTAssertTrue(gesture.isHighlight)
        XCTAssertTrue(CopyDecision.shouldCopy(gesture: gesture, selectedText: "word"))
    }

    func testDoubleClickCopiesWhenTheWordWasAlreadySelected() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "word")
        gesture.mouseDown(at: .zero, clickCount: 2, selectedText: "word")
        gesture.mouseUp(at: .zero, clickCount: 1)
        XCTAssertEqual(gesture.clickCount, 2)
        XCTAssertTrue(CopyDecision.shouldCopy(gesture: gesture, selectedText: "word"))
    }

    func testWhitespaceOnlyDoesNotCopy() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.mouseDragged(to: CGPoint(x: 12, y: 0))
        XCTAssertFalse(CopyDecision.shouldCopy(gesture: gesture, selectedText: " \n\t"))
    }

    func testMovementBelowThresholdIsNotAHighlight() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.mouseUp(at: CGPoint(x: 2.9, y: 0), clickCount: 1)
        XCTAssertFalse(gesture.isHighlight)
    }

    func testMovementAtThresholdIsAHighlight() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: CGPoint(x: 5, y: 5), clickCount: 1, selectedText: "")
        gesture.mouseUp(at: CGPoint(x: 8, y: 5), clickCount: 1)
        XCTAssertTrue(gesture.isHighlight)
        XCTAssertTrue(CopyDecision.shouldCopy(gesture: gesture, selectedText: "dragged"))
    }

    func testTripleClickKeepsSnapshot() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "old")
        gesture.mouseDown(at: .zero, clickCount: 3, selectedText: "the whole line")
        XCTAssertEqual(gesture.snapshot, "old")
        XCTAssertTrue(CopyDecision.shouldCopy(gesture: gesture, selectedText: "the whole line"))
    }

    func testOptionHeldDuringDragDoesNotCopy() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.noteOptionHeld()
        gesture.mouseDragged(to: CGPoint(x: 12, y: 0))
        gesture.mouseUp(at: CGPoint(x: 12, y: 0), clickCount: 1)
        XCTAssertTrue(gesture.isHighlight)
        XCTAssertTrue(gesture.optionHeld)
        XCTAssertFalse(CopyDecision.shouldCopy(gesture: gesture, selectedText: "hello"))
    }

    func testOptionOnReleaseDoesNotCopy() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.mouseDragged(to: CGPoint(x: 12, y: 0))
        gesture.noteOptionHeld()
        gesture.mouseUp(at: CGPoint(x: 12, y: 0), clickCount: 1)
        XCTAssertFalse(CopyDecision.shouldCopy(gesture: gesture, selectedText: "hello"))
    }

    func testFreshClickClearsOptionHeld() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.noteOptionHeld()
        gesture.mouseUp(at: CGPoint(x: 12, y: 0), clickCount: 1)
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.mouseDragged(to: CGPoint(x: 12, y: 0))
        XCTAssertFalse(gesture.optionHeld)
        XCTAssertTrue(CopyDecision.shouldCopy(gesture: gesture, selectedText: "hello"))
    }

    func testOptionOnTheFirstClickOfADoubleClickStillSuppresses() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.noteOptionHeld()
        gesture.mouseUp(at: .zero, clickCount: 1)
        gesture.mouseDown(at: .zero, clickCount: 2, selectedText: "word")
        gesture.mouseUp(at: .zero, clickCount: 2)
        XCTAssertTrue(gesture.optionHeld)
        XCTAssertFalse(CopyDecision.shouldCopy(gesture: gesture, selectedText: "word"))
    }

    func testOptionOnTheSecondClickSuppresses() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: .zero, clickCount: 1, selectedText: "")
        gesture.mouseUp(at: .zero, clickCount: 1)
        gesture.mouseDown(at: .zero, clickCount: 2, selectedText: "word")
        gesture.noteOptionHeld()
        gesture.mouseUp(at: .zero, clickCount: 2)
        XCTAssertFalse(CopyDecision.shouldCopy(gesture: gesture, selectedText: "word"))
    }

    func testMouseUpFarFromAnchorIsAHighlightWithoutDragEvents() {
        var gesture = SelectionGesture()
        gesture.mouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1, selectedText: "")
        gesture.mouseUp(at: CGPoint(x: 40, y: 18), clickCount: 1)
        XCTAssertGreaterThan(gesture.travel, 3)
        XCTAssertTrue(gesture.isHighlight)
    }

    func testQuartzPointFlipsPrimaryDisplay() {
        let topLeft = ScreenCoordinates.quartzPoint(fromCocoa: CGPoint(x: 0, y: 1080), primaryHeight: 1080)
        XCTAssertEqual(topLeft, .zero)
        let bottomLeft = ScreenCoordinates.quartzPoint(fromCocoa: .zero, primaryHeight: 1080)
        XCTAssertEqual(bottomLeft, CGPoint(x: 0, y: 1080))
        let cocoa = CGPoint(x: 40, y: 200)
        let quartz = ScreenCoordinates.quartzPoint(fromCocoa: cocoa, primaryHeight: 1080)
        let roundTrip = ScreenCoordinates.quartzPoint(fromCocoa: quartz, primaryHeight: 1080)
        XCTAssertEqual(roundTrip, cocoa)
    }

    func testTooltipSitsJustPastTheSelection() {
        let origin = TooltipPlacement.origin(
            anchor: CGPoint(x: 100, y: 80),
            size: CGSize(width: 50, height: 20),
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        XCTAssertEqual(origin, CGPoint(x: 106, y: 70))
    }

    func testTooltipFlipsWhenTheSelectionEndsAtTheScreenEdge() {
        let origin = TooltipPlacement.origin(
            anchor: CGPoint(x: 380, y: 80),
            size: CGSize(width: 50, height: 20),
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        XCTAssertEqual(origin.x, 324)
        XCTAssertEqual(origin.y, 70)
    }
}
