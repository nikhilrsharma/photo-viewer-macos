import AppKit
import SwiftUI

struct ImageScrollView: NSViewRepresentable {
  let image: LoadedImage?
  let zoomMode: ZoomMode
  let imageIdentity: URL?
  let onFitPercentageChanged: (Double) -> Void
  let onViewportChanged: (CGSize, CGFloat) -> Void

  init(
    image: LoadedImage?, zoomMode: ZoomMode, imageIdentity: URL? = nil,
    onFitPercentageChanged: @escaping (Double) -> Void,
    onViewportChanged: @escaping (CGSize, CGFloat) -> Void = { _, _ in }
  ) {
    self.image = image
    self.zoomMode = zoomMode
    self.imageIdentity = imageIdentity
    self.onFitPercentageChanged = onFitPercentageChanged
    self.onViewportChanged = onViewportChanged
  }

  func makeNSView(context: Context) -> ViewerScrollView {
    let view = ViewerScrollView()
    view.onFitPercentageChanged = onFitPercentageChanged
    view.onViewportChanged = onViewportChanged
    return view
  }

  func updateNSView(_ view: ViewerScrollView, context: Context) {
    view.onFitPercentageChanged = onFitPercentageChanged
    view.onViewportChanged = onViewportChanged
    view.configure(image: image, zoomMode: zoomMode, imageIdentity: imageIdentity)
  }
}

final class ViewerScrollView: NSScrollView {
  private let canvas = ImageCanvasView()
  private var displayedImage: LoadedImage?
  private var displayedIdentity: URL?
  private var zoomMode: ZoomMode = .fit
  private var lastViewportSize: CGSize = .zero
  private var lastBackingScale: CGFloat = 0
  private var dragOrigin: CGPoint = .zero
  private var isLayingOutDocument = false

  var onFitPercentageChanged: ((Double) -> Void)?
  var onViewportChanged: ((CGSize, CGFloat) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = true
    backgroundColor = ImageCanvasView.backgroundColor
    borderType = .noBorder
    scrollerStyle = .overlay
    autohidesScrollers = true
    hasHorizontalScroller = true
    hasVerticalScroller = true
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .none
    documentView = canvas

    let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.buttonMask = 0x1
    canvas.addGestureRecognizer(pan)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func configure(image: LoadedImage?, zoomMode: ZoomMode, imageIdentity: URL? = nil) {
    let imageChanged = displayedImage?.cgImage !== image?.cgImage
    let samePhoto = imageIdentity != nil && imageIdentity == displayedIdentity
    let zoomChanged = self.zoomMode != zoomMode
    displayedImage = image
    displayedIdentity = imageIdentity
    self.zoomMode = zoomMode
    canvas.image = image?.cgImage

    if imageChanged || zoomChanged {
      layoutDocument(preserveCenter: !imageChanged || samePhoto)
    }
  }

  override func layout() {
    super.layout()
    guard !isLayingOutDocument else { return }

    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    if contentSize != lastViewportSize || scale != lastBackingScale {
      layoutDocument(preserveCenter: zoomMode != .fit)
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    layoutDocument(preserveCenter: true)
  }

  private func layoutDocument(preserveCenter: Bool) {
    guard !isLayingOutDocument else { return }
    isLayingOutDocument = true
    defer { isLayingOutDocument = false }

    let viewport = contentSize
    guard viewport.width > 0, viewport.height > 0 else { return }
    let backingScale = max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    if viewport != lastViewportSize || backingScale != lastBackingScale {
      DispatchQueue.main.async { [weak self] in
        self?.onViewportChanged?(viewport, backingScale)
      }
    }

    let oldDocumentSize = canvas.frame.size
    let oldVisibleRect = documentVisibleRect
    let normalizedCenter: CGPoint? =
      if preserveCenter,
        oldDocumentSize.width > 0,
        oldDocumentSize.height > 0
      {
        CGPoint(
          x: oldVisibleRect.midX / oldDocumentSize.width,
          y: oldVisibleRect.midY / oldDocumentSize.height
        )
      } else {
        nil
      }

    guard let image = displayedImage else {
      canvas.imageFrame = .zero
      canvas.frame = CGRect(origin: .zero, size: viewport)
      canvas.needsDisplay = true
      lastViewportSize = viewport
      lastBackingScale = backingScale
      return
    }

    let baseSize = CGSize(
      width: image.pixelSize.width / backingScale,
      height: image.pixelSize.height / backingScale
    )
    let fitScale = min(viewport.width / baseSize.width, viewport.height / baseSize.height)

    let imageScale: CGFloat
    switch zoomMode {
    case .fit:
      imageScale = fitScale
    case .manual(let percentage):
      imageScale = percentage / 100
    }

    let drawnSize = CGSize(
      width: max(1, baseSize.width * imageScale),
      height: max(1, baseSize.height * imageScale)
    )
    let documentSize = CGSize(
      width: max(viewport.width, drawnSize.width),
      height: max(viewport.height, drawnSize.height)
    )

    canvas.frame = CGRect(origin: .zero, size: documentSize)
    canvas.imageFrame = CGRect(
      x: (documentSize.width - drawnSize.width) / 2,
      y: (documentSize.height - drawnSize.height) / 2,
      width: drawnSize.width,
      height: drawnSize.height
    )
    canvas.needsDisplay = true

    if let normalizedCenter {
      let target = CGPoint(
        x: normalizedCenter.x * documentSize.width - viewport.width / 2,
        y: normalizedCenter.y * documentSize.height - viewport.height / 2
      )
      contentView.scroll(to: target)
    } else {
      let centered = CGPoint(
        x: (documentSize.width - viewport.width) / 2,
        y: (documentSize.height - viewport.height) / 2
      )
      contentView.scroll(to: centered)
    }
    reflectScrolledClipView(contentView)

    lastViewportSize = viewport
    lastBackingScale = backingScale

    let fitPercentage = Double(fitScale * 100)
    DispatchQueue.main.async { [weak self] in
      self?.onFitPercentageChanged?(fitPercentage)
    }
  }

  @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
    guard canvas.frame.width > contentSize.width || canvas.frame.height > contentSize.height else {
      return
    }

    switch recognizer.state {
    case .began:
      dragOrigin = contentView.bounds.origin
      NSCursor.closedHand.push()
    case .changed:
      let translation = recognizer.translation(in: canvas)
      contentView.scroll(
        to: CGPoint(
          x: dragOrigin.x - translation.x,
          y: dragOrigin.y - translation.y
        ))
      reflectScrolledClipView(contentView)
    case .ended, .cancelled, .failed:
      NSCursor.pop()
    default:
      break
    }
  }
}

final class ImageCanvasView: NSView {
  static let backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1)

  var image: CGImage?
  var imageFrame: CGRect = .zero

  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current else { return }
    Self.backgroundColor.setFill()
    dirtyRect.fill()

    guard let image, !imageFrame.isEmpty else { return }
    context.imageInterpolation = .high
    context.cgContext.draw(image, in: imageFrame)
  }
}
