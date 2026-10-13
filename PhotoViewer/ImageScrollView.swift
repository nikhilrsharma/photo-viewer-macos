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
  private var renderedScale: CGFloat?
  private var zoomTransition: ZoomTransition?
  private var zoomTimer: Timer?
  private var zoomAnchor: CGPoint?
  var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  var isAnimatingZoom: Bool { zoomTransition != nil }

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
    let photoChanged = imageIdentity != displayedIdentity
    let samePhoto = imageIdentity != nil && imageIdentity == displayedIdentity
    let zoomChanged = self.zoomMode != zoomMode
    let canAnimate = zoomChanged && !photoChanged && displayedImage != nil && image != nil
      && (!imageChanged || samePhoto) && !reduceMotion()
    let startScale = renderedScale
    displayedImage = image
    displayedIdentity = imageIdentity
    self.zoomMode = zoomMode
    canvas.image = image?.cgImage

    if canAnimate, let startScale, let targetScale = targetScale() {
      startZoomAnimation(from: startScale, to: targetScale)
      return
    }
    if zoomChanged || photoChanged || (imageChanged && !samePhoto) {
      stopZoomAnimation()
    }
    if imageChanged || zoomChanged || photoChanged {
      layoutDocument(preserveCenter: !photoChanged && (!imageChanged || samePhoto))
    }
  }

  override func layout() {
    super.layout()
    guard !isLayingOutDocument else { return }

    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    if contentSize != lastViewportSize || scale != lastBackingScale {
      stopZoomAnimation()
      layoutDocument(preserveCenter: zoomMode != .fit)
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    stopZoomAnimation()
    layoutDocument(preserveCenter: true)
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { stopZoomAnimation() }
    super.viewWillMove(toWindow: newWindow)
  }

  private func targetScale() -> CGFloat? {
    guard let image = displayedImage else { return nil }
    switch zoomMode {
    case .manual(let value): return value / 100
    case .fit:
      let backing = max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
      return min(contentSize.width * backing / image.pixelSize.width,
                 contentSize.height * backing / image.pixelSize.height)
    }
  }

  private func startZoomAnimation(from: CGFloat, to: CGFloat) {
    stopZoomAnimation()
    let visible = documentVisibleRect
    let frame = canvas.imageFrame
    if frame.width > 0, frame.height > 0 {
      zoomAnchor = CGPoint(x: (visible.midX - frame.minX) / frame.width,
                           y: (visible.midY - frame.minY) / frame.height)
    }
    zoomTransition = ZoomTransition(from: from, to: to, startedAt: ProcessInfo.processInfo.systemUptime)
    let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
      guard let self else { timer.invalidate(); return }
      MainActor.assumeIsolated {
        self.advanceZoomAnimation()
      }
    }
    zoomTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func advanceZoomAnimation() {
    guard let transition = zoomTransition else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let finished = now - transition.startedAt >= ZoomTransition.duration || reduceMotion()
    renderedScale = finished ? transition.to : transition.scale(at: now)
    layoutDocument(preserveCenter: true)
    if finished { stopZoomAnimation() }
  }

  private func stopZoomAnimation() {
    zoomTimer?.invalidate()
    zoomTimer = nil
    zoomTransition = nil
    zoomAnchor = nil
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
      renderedScale = nil
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
    if zoomTransition != nil, let renderedScale {
      imageScale = renderedScale
    } else {
      switch zoomMode {
      case .fit:
        imageScale = fitScale
      case .manual(let percentage):
        imageScale = percentage / 100
      }
    }
    renderedScale = imageScale

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

    if let anchor = zoomAnchor {
      contentView.scroll(to: CGPoint(
        x: canvas.imageFrame.minX + anchor.x * drawnSize.width - viewport.width / 2,
        y: canvas.imageFrame.minY + anchor.y * drawnSize.height - viewport.height / 2))
    } else if let normalizedCenter {
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
      stopZoomAnimation()
      layoutDocument(preserveCenter: true)
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

struct ZoomTransition {
  static let duration: TimeInterval = 0.14
  let from: CGFloat
  let to: CGFloat
  let startedAt: TimeInterval

  func scale(at time: TimeInterval) -> CGFloat {
    let progress = min(1, max(0, (time - startedAt) / Self.duration))
    let eased = 1 - pow(1 - progress, 3)
    return from + (to - from) * eased
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
