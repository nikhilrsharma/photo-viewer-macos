import AppKit
import XCTest

@testable import PhotoViewer

@MainActor
final class NavigationWindowTests: XCTestCase {
  func testUnmodifiedArrowKeysNavigateIncludingKeyRepeat() throws {
    let window = makeWindow()
    var offsets: [Int] = []
    window.onNavigate = { offsets.append($0) }

    window.sendEvent(try keyEvent(keyCode: 123))
    window.sendEvent(try keyEvent(keyCode: 124, isARepeat: true))

    XCTAssertEqual(offsets, [-1, 1])
  }

  func testModifiedArrowKeyDoesNotNavigate() throws {
    let window = makeWindow()
    var offsets: [Int] = []
    window.onNavigate = { offsets.append($0) }

    window.sendEvent(try keyEvent(keyCode: 124, modifiers: .command))

    XCTAssertTrue(offsets.isEmpty)
  }

  func testArrowKeyIsReservedForActiveTextFieldEditor() throws {
    let window = makeWindow()
    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
    window.contentView?.addSubview(textField)
    let editor = try XCTUnwrap(window.fieldEditor(true, for: textField) as? NSTextView)
    XCTAssertTrue(editor.isFieldEditor)

    XCTAssertNil(
      NavigationWindow.navigationDirection(
        for: try keyEvent(keyCode: 124),
        firstResponder: editor
      )
    )
  }

  func testManualGeometryUsesOriginalPixelsAtBothBackingScales() throws {
    let originalSize = CGSize(width: 4_000, height: 3_000)
    let preview = LoadedImage(
      cgImage: try makeImage(width: 40, height: 30), pixelSize: originalSize)

    for scale: CGFloat in [1, 2] {
      let (window, scrollView) = makeScrollView(backingScale: scale)
      defer { window.close() }
      scrollView.configure(image: preview, zoomMode: .manual(100))
      let canvas = try XCTUnwrap(scrollView.documentView as? ImageCanvasView)

      XCTAssertEqual(canvas.imageFrame.width, originalSize.width / scale, accuracy: 0.001)
      XCTAssertEqual(canvas.imageFrame.height, originalSize.height / scale, accuracy: 0.001)
      XCTAssertEqual(canvas.frame.size, canvas.imageFrame.size)
      XCTAssertEqual(
        canvas.image?.width, 40, "A small decoded preview must retain original 100% geometry")
    }
  }

  func testFitPercentageUsesOriginalPixelsAtBothBackingScales() async throws {
    let originalSize = CGSize(width: 4_000, height: 3_000)
    let preview = LoadedImage(
      cgImage: try makeImage(width: 40, height: 30), pixelSize: originalSize)

    for scale: CGFloat in [1, 2] {
      let (window, scrollView) = makeScrollView(backingScale: scale)
      defer { window.close() }
      var reportedPercentage: Double?
      scrollView.onFitPercentageChanged = { reportedPercentage = $0 }
      scrollView.configure(image: preview, zoomMode: .fit)
      let canvas = try XCTUnwrap(scrollView.documentView as? ImageCanvasView)
      let viewport = scrollView.contentSize
      let expectedPercentage = Double(
        min(
          viewport.width * scale / originalSize.width, viewport.height * scale / originalSize.height
        ) * 100
      )

      // The view reports its geometry asynchronously to avoid publishing state
      // during an AppKit layout pass. Yield without showing or activating a window.
      for _ in 0..<100 where reportedPercentage == nil {
        try await Task.sleep(for: .milliseconds(5))
      }

      XCTAssertEqual(try XCTUnwrap(reportedPercentage), expectedPercentage, accuracy: 0.001)
      XCTAssertLessThanOrEqual(canvas.imageFrame.width, viewport.width + 0.001)
      XCTAssertLessThanOrEqual(canvas.imageFrame.height, viewport.height + 0.001)
      XCTAssertEqual(canvas.imageFrame.width / canvas.imageFrame.height, 4.0 / 3.0, accuracy: 0.001)
    }
  }

  func testSamePhotoResolutionUpgradePreservesPannedCenter() throws {
    let originalSize = CGSize(width: 4_000, height: 3_000)
    let preview = LoadedImage(
      cgImage: try makeImage(width: 40, height: 30), pixelSize: originalSize)
    let higherResolution = LoadedImage(
      cgImage: try makeImage(width: 400, height: 300), pixelSize: originalSize)
    let identity = URL(fileURLWithPath: "/synthetic/photo.jpg")

    for scale: CGFloat in [1, 2] {
      let (window, scrollView) = makeScrollView(backingScale: scale)
      defer { window.close() }
      scrollView.configure(image: preview, zoomMode: .manual(100), imageIdentity: identity)
      scrollView.contentView.scroll(to: CGPoint(x: 320, y: 240))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      let before = scrollView.documentVisibleRect
      let canvas = try XCTUnwrap(scrollView.documentView as? ImageCanvasView)
      let originalFrame = canvas.imageFrame

      scrollView.configure(image: higherResolution, zoomMode: .manual(100), imageIdentity: identity)

      XCTAssertEqual(canvas.image?.width, 400)
      XCTAssertEqual(canvas.imageFrame, originalFrame)
      XCTAssertEqual(scrollView.documentVisibleRect.midX, before.midX, accuracy: 0.001)
      XCTAssertEqual(scrollView.documentVisibleRect.midY, before.midY, accuracy: 0.001)

      scrollView.configure(
        image: preview, zoomMode: .manual(100),
        imageIdentity: URL(fileURLWithPath: "/synthetic/another-photo.jpg")
      )
      XCTAssertEqual(scrollView.documentVisibleRect.midX, canvas.frame.midX, accuracy: 0.001)
      XCTAssertEqual(scrollView.documentVisibleRect.midY, canvas.frame.midY, accuracy: 0.001)
    }
  }

  func testAboutBuildDateUsesRecordedDateAndStableEnglishFormatting() {
    XCTAssertEqual(AppAboutInfo.formattedBuildDate("2026-10-11"), "11 October 2026")
    XCTAssertEqual(AppAboutInfo.formattedBuildDate("1999-12-31"), "31 December 1999")
    XCTAssertEqual(AppAboutInfo.formattedBuildDate("2000-02-29"), "29 February 2000")
  }

  func testAboutBuildDateNeverInventsDateWhenMetadataIsMissingOrInvalid() {
    let invalidDates: [String?] = [nil, "", "not-a-date", "2026-13-11", "2026-02-29"]
    for rawDate in invalidDates {
      XCTAssertEqual(
        AppAboutInfo.formattedBuildDate(rawDate), "Unavailable",
        "Expected invalid build metadata to remain unavailable: \(rawDate ?? "nil")"
      )
    }
  }

  func testAboutCreatorAndAICreditUseRequestedWording() {
    XCTAssertEqual(AppAboutInfo.creator, "Nikhil Sharma")
    XCTAssertEqual(
      AppAboutInfo.aiCredit,
      "Created with assistance from Codex, OpenAI’s AI coding assistant."
    )
  }

  func testAboutPanelIsLazyClosableNonresizableAndReused() throws {
    let controller = AboutPanelController()
    XCTAssertNil(controller.panel)

    controller.show()
    let panel = try XCTUnwrap(controller.panel)
    defer { panel.close() }

    XCTAssertEqual(panel.title, "About Photo Viewer")
    XCTAssertTrue(panel.styleMask.contains(.closable))
    XCTAssertFalse(panel.styleMask.contains(.resizable))
    XCTAssertFalse(panel.isReleasedWhenClosed)
    XCTAssertTrue(panel.isVisible)

    controller.show()
    XCTAssertTrue(controller.panel === panel)

    panel.performClose(nil)
    XCTAssertFalse(panel.isVisible)
    controller.show()
    XCTAssertTrue(controller.panel === panel)
    XCTAssertTrue(panel.isVisible)
  }

  private func makeScrollView(backingScale: CGFloat) -> (GeometryTestWindow, ViewerScrollView) {
    let window = GeometryTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.simulatedBackingScale = backingScale
    let view = ViewerScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return (window, view)
  }

  private func makeImage(width: Int, height: Int) throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    return try XCTUnwrap(context.makeImage())
  }

  private func makeWindow() -> NavigationWindow {
    NavigationWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
  }

  private func keyEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = [],
    isARepeat: Bool = false
  ) throws -> NSEvent {
    let characters = keyCode == 123 ? "\u{F702}" : "\u{F703}"
    return try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: isARepeat,
        keyCode: keyCode
      ))
  }
}

// Backing scale is injected without relying on the physical display or showing
// a test window, so the same tests cover Retina and non-Retina geometry.
@MainActor
private final class GeometryTestWindow: NSWindow {
  var simulatedBackingScale: CGFloat = 1
  override var backingScaleFactor: CGFloat { simulatedBackingScale }
}
