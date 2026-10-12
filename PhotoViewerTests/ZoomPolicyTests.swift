import XCTest

@testable import PhotoViewer

final class ZoomPolicyTests: XCTestCase {
  func testRoundsToNearestFive() {
    XCTAssertEqual(ZoomPolicy.normalized(37), 35)
    XCTAssertEqual(ZoomPolicy.normalized(38), 40)
    XCTAssertEqual(ZoomPolicy.normalized(37.5), 40)
  }

  func testClampsToManualRange() {
    XCTAssertEqual(ZoomPolicy.normalized(-100), 20)
    XCTAssertEqual(ZoomPolicy.normalized(219), 200)
  }

  func testStepsSliderByExactlyOneFivePercentTick() {
    XCTAssertEqual(ZoomPolicy.stepped(from: 37.2, by: 1), 40)
    XCTAssertEqual(ZoomPolicy.stepped(from: 37.2, by: -1), 30)
    XCTAssertEqual(ZoomPolicy.stepped(from: 40, by: 1), 45)
    XCTAssertEqual(ZoomPolicy.stepped(from: 40, by: -1), 35)
  }

  func testSteppingClampsAtManualBounds() {
    XCTAssertEqual(ZoomPolicy.stepped(from: 12, by: 1), 25)
    XCTAssertEqual(ZoomPolicy.stepped(from: 207, by: -1), 195)
    XCTAssertEqual(ZoomPolicy.stepped(from: 200, by: 1), 200)
    XCTAssertEqual(ZoomPolicy.stepped(from: 20, by: -1), 20)
  }

  func testZoomSliderThumbPositionTracksRangeAndClampsAtEndpoints() {
    XCTAssertEqual(ZoomSliderMetrics.thumbCenter(for: 20), 10, accuracy: 0.001)
    XCTAssertEqual(ZoomSliderMetrics.thumbCenter(for: 110), 85, accuracy: 0.001)
    XCTAssertEqual(ZoomSliderMetrics.thumbCenter(for: 200), 160, accuracy: 0.001)
    XCTAssertEqual(ZoomSliderMetrics.thumbCenter(for: 12), 10, accuracy: 0.001)
    XCTAssertEqual(ZoomSliderMetrics.thumbCenter(for: 207), 160, accuracy: 0.001)
  }

  func testZoomSliderLabelIncludesContainerPadding() {
    XCTAssertEqual(ZoomSliderMetrics.labelCenter(for: 20), 22, accuracy: 0.001)
    XCTAssertEqual(ZoomSliderMetrics.labelCenter(for: 110), 97, accuracy: 0.001)
    XCTAssertEqual(ZoomSliderMetrics.labelCenter(for: 200), 172, accuracy: 0.001)
  }
}
