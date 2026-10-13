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

  func testVerticalArrowsZoomIncludingRepeatWithoutNavigating() throws {
    let window = makeWindow()
    var zooms: [Int] = []
    var navigation: [Int] = []
    window.onZoom = { zooms.append($0) }
    window.onNavigate = { navigation.append($0) }
    window.sendEvent(try keyEvent(keyCode: 126))
    window.sendEvent(try keyEvent(keyCode: 126, isARepeat: true))
    window.sendEvent(try keyEvent(keyCode: 125))
    XCTAssertEqual(zooms, [1, 1, -1])
    XCTAssertTrue(navigation.isEmpty)
  }

  func testVerticalArrowsRespectTextEditingAndModifiers() throws {
    let editor = NSTextView()
    editor.isEditable = true
    for code: UInt16 in [125, 126] {
      XCTAssertNil(NavigationWindow.zoomDirection(for: try keyEvent(keyCode: code), firstResponder: editor))
      for modifier: NSEvent.ModifierFlags in [.shift, .command, .control, .option] {
        XCTAssertNil(NavigationWindow.zoomDirection(
          for: try keyEvent(keyCode: code, modifiers: modifier), firstResponder: nil))
      }
    }
    XCTAssertNil(NavigationWindow.zoomDirection(for: try keyEvent(keyCode: 124), firstResponder: nil))
  }

  func testMenuHasAboutAndQuitWithoutHideOrWindowMenu() throws {
    let menu = AppMenu.make(aboutTarget: nil, aboutAction: #selector(NSObject.description))
    XCTAssertEqual(menu.items.map(\.title), ["Nik's Photo Viewer"])
    let appMenu = try XCTUnwrap(menu.items.first?.submenu)
    XCTAssertEqual(appMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
                   ["About Nik's Photo Viewer", "Quit Nik's Photo Viewer"])
    XCTAssertFalse(appMenu.items.contains { $0.action == #selector(NSApplication.hide(_:)) })
  }

  func testTitlebarIdentityIsLeftAlignedAndStable() throws {
    let window = makeWindow()
    window.isReleasedWhenClosed = false
    defer { window.close() }
    AppTitlebar.install(on: window)
    XCTAssertEqual(window.title, "Nik's Photo Viewer")
    let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.first)
    XCTAssertEqual(accessory.layoutAttribute, .left)
    let label = try XCTUnwrap(accessory.view.subviews.first as? NSTextField)
    XCTAssertEqual(label.stringValue, AppIdentity.name)
    XCTAssertFalse(label.isEditable)
  }

  func testZoomAnimationInterpolatesAndRetargetsWithoutOvershoot() {
    let transition = ZoomTransition(from: 1, to: 2, startedAt: 10)
    XCTAssertEqual(transition.scale(at: 9), 1)
    XCTAssertEqual(transition.scale(at: 11), 2)
    let middle = transition.scale(at: 10.07)
    XCTAssertGreaterThan(middle, 1)
    XCTAssertLessThan(middle, 2)
    let reverse = ZoomTransition(from: middle, to: 0.2, startedAt: 10.07)
    XCTAssertEqual(reverse.scale(at: 10.07), middle)
    XCTAssertEqual(reverse.scale(at: 11), 0.2, accuracy: 0.0001)
  }

  func testZoomAnimationCompletesAndNewImageCancelsIt() async throws {
    let (window, view) = makeScrollView(backingScale: 2)
    defer { window.close() }
    view.reduceMotion = { false }
    let image = LoadedImage(cgImage: try makeImage(width: 40, height: 30),
                            pixelSize: CGSize(width: 4000, height: 3000))
    let url = URL(fileURLWithPath: "/synthetic/one.jpg")
    view.configure(image: image, zoomMode: .manual(100), imageIdentity: url)
    view.configure(image: image, zoomMode: .manual(105), imageIdentity: url)
    XCTAssertTrue(view.isAnimatingZoom)
    for _ in 0..<100 where view.isAnimatingZoom { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertFalse(view.isAnimatingZoom)
    let canvas = try XCTUnwrap(view.documentView as? ImageCanvasView)
    XCTAssertEqual(canvas.imageFrame.width, 2100, accuracy: 0.01)
    view.configure(image: image, zoomMode: .manual(200), imageIdentity: url)
    XCTAssertTrue(view.isAnimatingZoom)
    let nextURL = URL(fileURLWithPath: "/synthetic/two.jpg")
    view.configure(image: image, zoomMode: .manual(200), imageIdentity: nextURL)
    XCTAssertFalse(view.isAnimatingZoom, "A different photo cancels even if its raster is shared")
    XCTAssertEqual(canvas.imageFrame.width, 4000, accuracy: 0.01)
    view.configure(image: image, zoomMode: .manual(195), imageIdentity: nextURL)
    XCTAssertTrue(view.isAnimatingZoom)
    view.configure(image: nil, zoomMode: .fit, imageIdentity: nil)
    XCTAssertFalse(view.isAnimatingZoom)
    XCTAssertEqual(canvas.imageFrame, .zero)
  }

  func testReduceMotionMakesZoomImmediate() throws {
    let (window, view) = makeScrollView(backingScale: 1)
    defer { window.close() }
    view.reduceMotion = { true }
    let image = LoadedImage(cgImage: try makeImage(width: 40, height: 30),
                            pixelSize: CGSize(width: 4000, height: 3000))
    view.configure(image: image, zoomMode: .manual(100))
    view.configure(image: image, zoomMode: .manual(150))
    XCTAssertFalse(view.isAnimatingZoom)
    let canvas = try XCTUnwrap(view.documentView as? ImageCanvasView)
    XCTAssertEqual(canvas.imageFrame.width, 6000, accuracy: 0.01)
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

    XCTAssertEqual(panel.title, "About Nik's Photo Viewer")
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
