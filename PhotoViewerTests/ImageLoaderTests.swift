import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PhotoViewer

final class ImageLoaderTests: XCTestCase {
  private var temporaryFolder: URL!

  override func setUpWithError() throws {
    temporaryFolder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryFolder,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporaryFolder)
  }

  func testLoadsWritableCommonMacFormats() throws {
    let formats: [(UTType, String)] = [
      (.jpeg, "jpg"),
      (.png, "png"),
      (.tiff, "tiff"),
      (.gif, "gif"),
      (.bmp, "bmp"),
    ]

    for (type, extensionName) in formats {
      let url = temporaryFolder.appendingPathComponent("fixture.\(extensionName)")
      try writeImage(to: url, type: type.identifier, width: 48, height: 32)
      let loaded = try ImageLoader.load(url: url)
      XCTAssertEqual(loaded.cgImage.width, 48, "Unexpected width for \(type.identifier)")
      XCTAssertEqual(loaded.cgImage.height, 32, "Unexpected height for \(type.identifier)")
    }
  }

  func testLoadsNativeHeicImage() throws {
    let sample = URL(
      fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/Valley Light.heic"
    )
    guard FileManager.default.fileExists(atPath: sample.path) else {
      throw XCTSkip("The system HEIC fixture is not installed")
    }

    let loaded = try ImageLoader.load(url: sample)
    XCTAssertGreaterThan(loaded.cgImage.width, 0)
    XCTAssertGreaterThan(loaded.cgImage.height, 0)
  }

  func testNativeDecoderAdvertisesEveryRegisteredContentType() {
    let identifiers = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    XCTAssertTrue(
      ImageCatalog.supportedContentTypeIdentifiers.isSubset(of: identifiers),
      "Registered types without a native decoder: \(ImageCatalog.supportedContentTypeIdentifiers.subtracting(identifiers).sorted())"
    )
  }

  func testAppliesExifOrientationWithoutWritingToFile() throws {
    let url = temporaryFolder.appendingPathComponent("oriented.jpg")
    try writeImage(
      to: url,
      type: UTType.jpeg.identifier,
      width: 40,
      height: 20,
      properties: [kCGImagePropertyOrientation: 6]
    )

    let dataBefore = try Data(contentsOf: url)
    let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)
    let loaded = try ImageLoader.load(url: url)
    let dataAfter = try Data(contentsOf: url)
    let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)

    XCTAssertEqual(loaded.cgImage.width, 20)
    XCTAssertEqual(loaded.cgImage.height, 40)
    XCTAssertEqual(dataAfter, dataBefore)
    XCTAssertEqual(
      attributesAfter[.modificationDate] as? Date,
      attributesBefore[.modificationDate] as? Date
    )
    XCTAssertEqual(
      attributesAfter[.size] as? NSNumber,
      attributesBefore[.size] as? NSNumber
    )
  }

  func testAnimatedGifLoadsOnlyFirstFrame() throws {
    let url = temporaryFolder.appendingPathComponent("animated.gif")
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.gif.identifier as CFString,
        2,
        nil
      )
    else {
      return XCTFail("Unable to create GIF destination")
    }

    let frameProperties: CFDictionary =
      [
        kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFDelayTime: 0.1
        ]
      ] as CFDictionary
    CGImageDestinationAddImage(
      destination, try makeImage(width: 24, height: 16, red: 0.9), frameProperties)
    CGImageDestinationAddImage(
      destination, try makeImage(width: 24, height: 16, red: 0.1), frameProperties)
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let loaded = try ImageLoader.load(url: url)
    XCTAssertEqual(loaded.cgImage.width, 24)
    XCTAssertEqual(loaded.cgImage.height, 16)
    XCTAssertGreaterThan(try redComponent(atCenterOf: loaded.cgImage), 0.7)
  }

  func testDownsamplingPreservesOriginalOrientedPixelDimensions() throws {
    let url = temporaryFolder.appendingPathComponent("large-oriented.jpg")
    try writeImage(
      to: url, type: UTType.jpeg.identifier, width: 400, height: 200,
      properties: [kCGImagePropertyOrientation: 6]
    )
    let loaded = try ImageLoader.load(url: url, maximumPixelSize: 100)
    XCTAssertEqual(loaded.pixelSize, CGSize(width: 200, height: 400))
    XCTAssertEqual(loaded.cgImage.width, 50)
    XCTAssertEqual(loaded.cgImage.height, 100)
  }

  func testDownsamplingNeverUpscalesSmallImages() throws {
    let url = temporaryFolder.appendingPathComponent("small.png")
    try writeImage(to: url, type: UTType.png.identifier, width: 48, height: 32)
    let loaded = try ImageLoader.load(url: url, maximumPixelSize: 1024)
    XCTAssertEqual(loaded.pixelSize, CGSize(width: 48, height: 32))
    XCTAssertEqual(loaded.cgImage.width, 48)
    XCTAssertEqual(loaded.cgImage.height, 32)
  }

  func testRejectsNonFileURLsAndNonlocalFileHosts() {
    for string in [
      "https://example.invalid/image.jpg", "file://example.invalid/tmp/image.jpg",
      "file:relative.jpg", "file://user@localhost/tmp/image.jpg",
      "file://localhost:80/tmp/image.jpg",
      "file:///tmp/image%00.jpg",
    ] {
      XCTAssertThrowsError(try ImageLoader.load(url: URL(string: string)!)) { error in
        XCTAssertEqual(error as? ImageLoadError, .unsupportedSource)
      }
    }
  }

  func testLocalFileURLPredicateRequiresAbsoluteUnambiguousPaths() {
    XCTAssertTrue(ImageInputValidation.isLocalFileURL(URL(fileURLWithPath: "/tmp/image.jpg")))
    XCTAssertTrue(
      ImageInputValidation.isLocalFileURL(URL(string: "file://LOCALHOST/tmp/image.jpg")!))
    XCTAssertFalse(ImageInputValidation.isLocalFileURL(URL(string: "file:relative.jpg")!))
  }

  func testLocalFileURLPredicateRejectsEncodedNULButAllowsLiteralPercent00Filename() {
    XCTAssertFalse(ImageInputValidation.isLocalFileURL(URL(string: "file:///tmp/photo%00.jpg")!))
    XCTAssertTrue(ImageInputValidation.isLocalFileURL(URL(string: "file:///tmp/photo%2500.jpg")!))
    XCTAssertTrue(ImageInputValidation.isLocalFileURL(URL(fileURLWithPath: "/tmp/photo%00.jpg")))
  }

  func testPipelineRejectsRelativeFileURLBeforeNormalizationOrDecoding() async {
    let recorder = DecodeRecorder()
    let pipeline = ImagePipeline { url, _ in
      recorder.record(url)
      throw ImageLoadError.invalid
    }
    do {
      _ = try await pipeline.load(url: URL(string: "file:relative.jpg")!)
      XCTFail("Relative file URLs must be rejected before normalizing them")
    } catch {
      XCTAssertEqual(error as? ImageLoadError, .unsupportedSource)
    }
    XCTAssertEqual(recorder.count, 0)
  }

  func testRejectsDirectoryAndFIFOWithoutWaitingForWriter() throws {
    XCTAssertThrowsError(try ImageLoader.load(url: temporaryFolder)) { error in
      XCTAssertEqual(error as? ImageLoadError, .unsupportedSource)
    }
    let fifo = temporaryFolder.appendingPathComponent("pipe.jpg")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    let start = Date()
    XCTAssertThrowsError(try ImageLoader.load(url: fifo)) { error in
      XCTAssertEqual(error as? ImageLoadError, .unsupportedSource)
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }

  func testSymlinkToRegularImageLoadsButSpecialTargetIsRejected() throws {
    let regular = temporaryFolder.appendingPathComponent("image.png")
    try writeImage(to: regular, type: UTType.png.identifier, width: 48, height: 32)
    let link = temporaryFolder.appendingPathComponent("alias.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
    XCTAssertEqual(try ImageLoader.load(url: link).pixelSize, CGSize(width: 48, height: 32))

    let fifo = temporaryFolder.appendingPathComponent("pipe.jpg")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    let specialLink = temporaryFolder.appendingPathComponent("alias.jpg")
    try FileManager.default.createSymbolicLink(at: specialLink, withDestinationURL: fifo)
    XCTAssertThrowsError(try ImageInputValidation.validate(url: specialLink)) { error in
      XCTAssertEqual(error as? ImageLoadError, .unsupportedSource)
    }
  }

  func testRejectsOversizedSparseSourceBeforeImageParsing() throws {
    let url = temporaryFolder.appendingPathComponent("oversized.jpg")
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    XCTAssertEqual(ftruncate(descriptor, off_t(ImageDecodePolicy.maximumSourceBytes) + 1), 0)
    XCTAssertThrowsError(try ImageLoader.load(url: url)) { error in
      XCTAssertEqual(error as? ImageLoadError, .exceedsSafetyLimits)
    }
  }

  func testPinnedProviderRejectsSourceTruncatedBeforeRead() throws {
    let url = temporaryFolder.appendingPathComponent("truncated.png")
    try writeImage(to: url, type: UTType.png.identifier, width: 48, height: 32)
    let file = try PinnedImageFile(url: url)
    let provider = try file.makeProvider()
    // Simulate another process truncating the already-open source before ImageIO reads it.
    let writer = open(url.path, O_WRONLY | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(writer, 0)
    guard writer >= 0 else { return }
    defer { close(writer) }
    XCTAssertEqual(ftruncate(writer, 0), 0)
    XCTAssertFalse(file.isUnchanged())
    var bytes = [UInt8](repeating: 0, count: 16)
    let count = bytes.withUnsafeMutableBytes { buffer in
      file.read(into: buffer.baseAddress!, at: 0, count: buffer.count)
    }
    XCTAssertEqual(count, 0)
    let source = CGImageSourceCreateWithDataProvider(provider, nil)
    let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    XCTAssertNil(decoded)
  }

  func testRejectsUnreasonableOrNonfiniteImageMetadata() {
    for dimension in [Double.nan, .infinity, -.infinity, -1, 0, 1.5] {
      XCTAssertThrowsError(
        try ImageDecodePolicy.plan(
          width: dimension, height: 100, depth: 8, maximumPixelSize: 512
        ))
      XCTAssertThrowsError(
        try ImageDecodePolicy.plan(
          width: 100, height: dimension, depth: 8, maximumPixelSize: 512
        ))
    }
    for depth in [Double.nan, .infinity, -1, 0, 1.5, 64] {
      XCTAssertThrowsError(
        try ImageDecodePolicy.plan(
          width: 100, height: 100, depth: depth, maximumPixelSize: 512
        ))
    }
    for pair in [(100_001.0, 1.0), (10_001.0, 10_000.0), (Double.greatestFiniteMagnitude, 1)] {
      XCTAssertThrowsError(
        try ImageDecodePolicy.plan(
          width: pair.0, height: pair.1, depth: 8, maximumPixelSize: 512
        )
      ) { error in
        XCTAssertEqual(error as? ImageLoadError, .exceedsSafetyLimits)
      }
    }
  }

  func testOversizedPNGHeaderIsRejectedByParserOrDimensionPolicy() throws {
    let url = temporaryFolder.appendingPathComponent("oversized-header.png")
    try writeImage(to: url, type: UTType.png.identifier, width: 48, height: 32)
    var data = try Data(contentsOf: url)
    XCTAssertEqual(Array(data[12..<16]), Array("IHDR".utf8))
    // Keep the PNG structure and IHDR checksum valid while declaring an extreme width.
    data.replaceSubrange(16..<20, with: [0x00, 0x01, 0x86, 0xA1])
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data[12..<29] {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    crc ^= 0xFFFF_FFFF
    data.replaceSubrange(
      29..<33,
      with: [
        UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
        UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc),
      ])
    try data.write(to: url)
    XCTAssertThrowsError(try ImageLoader.load(url: url, maximumPixelSize: 256)) { error in
      // Some ImageIO versions reject the inconsistent PNG before exposing its
      // dimensions. Either early parser rejection or our limit is safe. The
      // policy tests independently require the exact limit error for this width.
      let loadError = error as? ImageLoadError
      XCTAssertTrue(loadError == .invalid || loadError == .exceedsSafetyLimits)
    }
  }

  func testDecodeBudgetAllows48MegapixelsAndCapsPreviewWithoutUpscaling() throws {
    let full = try ImageDecodePolicy.plan(
      width: 8000, height: 6000, depth: 8, maximumPixelSize: nil)
    XCTAssertEqual(full.maximumDimension, 8000)
    let preview = try ImageDecodePolicy.plan(
      width: 20_000, height: 5000, depth: 16, maximumPixelSize: Int.max
    )
    XCTAssertEqual(preview.maximumDimension, 8192)
    let small = try ImageDecodePolicy.plan(width: 48, height: 32, depth: 8, maximumPixelSize: 1024)
    XCTAssertEqual(small.maximumDimension, 48)
    XCTAssertThrowsError(
      try ImageDecodePolicy.plan(
        width: 20_000, height: 5000, depth: 16, maximumPixelSize: nil
      )
    ) { error in
      XCTAssertEqual(error as? ImageLoadError, .exceedsSafetyLimits)
    }
    XCTAssertThrowsError(
      try ImageDecodePolicy.plan(width: 48, height: 32, depth: 8, maximumPixelSize: 0))
  }

  func testDecodedByteValidationRejectsOverflowAndOverBudget() throws {
    XCTAssertNoThrow(try ImageDecodePolicy.validateDecodedBytes(bytesPerRow: 32_000, height: 6000))
    for pair in [(Int.max, 2), (ImageDecodePolicy.maximumDecodedBytes, 2)] {
      XCTAssertThrowsError(
        try ImageDecodePolicy.validateDecodedBytes(bytesPerRow: pair.0, height: pair.1)
      ) { error in
        XCTAssertEqual(error as? ImageLoadError, .exceedsSafetyLimits)
      }
    }
    XCTAssertThrowsError(try ImageDecodePolicy.validateDecodedBytes(bytesPerRow: 0, height: 1))
  }

  func testPipelineReusesCachedDecodeAndInvalidatesChangedFile() async throws {
    let url = temporaryFolder.appendingPathComponent("cached.png")
    try writeImage(to: url, type: UTType.png.identifier, width: 48, height: 32)
    let recorder = DecodeRecorder()
    let pipeline = ImagePipeline { url, maximum in
      recorder.record(url)
      return try ImageLoader.load(url: url, maximumPixelSize: maximum)
    }
    let first = try await pipeline.load(url: url, maximumPixelSize: 40)
    let cached = try await pipeline.load(url: url, maximumPixelSize: 30)
    XCTAssertTrue(first.cgImage === cached.cgImage)
    XCTAssertEqual(recorder.count, 1)

    try writeImage(to: url, type: UTType.png.identifier, width: 96, height: 64)
    let changed = try await pipeline.load(url: url, maximumPixelSize: 40)
    XCTAssertEqual(changed.pixelSize, CGSize(width: 96, height: 64))
    XCTAssertEqual(recorder.count, 2)
  }

  func testPipelineCacheValidatesSymlinkTargetIdentity() async throws {
    let target = temporaryFolder.appendingPathComponent("target.png")
    let link = temporaryFolder.appendingPathComponent("link.png")
    try writeImage(to: target, type: UTType.png.identifier, width: 48, height: 32)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let pipeline = ImagePipeline()
    _ = try await pipeline.load(url: link)
    try FileManager.default.removeItem(at: target)
    try writeImage(to: target, type: UTType.png.identifier, width: 96, height: 64)
    let updated = try await pipeline.load(url: link)
    XCTAssertEqual(updated.pixelSize, CGSize(width: 96, height: 64))
  }

  func testPipelineEvictsByDecodedBytesAndDoesNotCacheOversizedImages() async throws {
    let image = LoadedImage(cgImage: try makeImage(width: 48, height: 32, red: 0.5))
    let firstURL = temporaryFolder.appendingPathComponent("one.png")
    let secondURL = temporaryFolder.appendingPathComponent("two.png")
    try Data([1]).write(to: firstURL)
    try Data([2]).write(to: secondURL)
    let recorder = DecodeRecorder()
    let pipeline = ImagePipeline(byteLimit: image.decodedByteCount) { url, _ in
      recorder.record(url)
      return image
    }
    _ = try await pipeline.load(url: firstURL)
    _ = try await pipeline.load(url: secondURL)
    _ = try await pipeline.load(url: firstURL)
    XCTAssertEqual(recorder.count, 3)
    let cachedBytes = await pipeline.cachedByteCount
    XCTAssertEqual(cachedBytes, image.decodedByteCount)

    let tinyPipeline = ImagePipeline(byteLimit: image.decodedByteCount - 1) { _, _ in image }
    _ = try await tinyPipeline.load(url: firstURL)
    let oversizedCachedBytes = await tinyPipeline.cachedByteCount
    XCTAssertEqual(oversizedCachedBytes, 0)
  }

  func testPipelineSkipsSupersededQueueAndRunsOnlyOneDecoder() async throws {
    let image = LoadedImage(cgImage: try makeImage(width: 48, height: 32, red: 0.5))
    let firstURL = temporaryFolder.appendingPathComponent("first.png")
    let skippedURL = temporaryFolder.appendingPathComponent("skipped.png")
    let latestURL = temporaryFolder.appendingPathComponent("latest.png")
    for url in [firstURL, skippedURL, latestURL] { try Data([1]).write(to: url) }
    let recorder = DecodeRecorder()
    let releaseFirst = DispatchSemaphore(value: 0)
    let pipeline = ImagePipeline { url, _ in
      recorder.record(url)
      if url == firstURL { _ = releaseFirst.wait(timeout: .now() + 5) }
      return image
    }
    let first = Task { try await pipeline.load(url: firstURL) }
    for _ in 0..<500 where recorder.count == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(recorder.count, 1)
    let skipped = Task { try await pipeline.load(url: skippedURL) }
    // The first request only returns after the replacement has been enqueued.
    do {
      _ = try await first.value
      XCTFail("The obsolete foreground request should be cancelled")
    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    let latest = Task { try await pipeline.load(url: latestURL) }
    do {
      _ = try await skipped.value
      XCTFail("The superseded queued request should be cancelled")
    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    // No queued decoder may start until the non-cancellable first decode exits.
    XCTAssertEqual(recorder.urls, [firstURL])
    releaseFirst.signal()
    _ = try await latest.value
    XCTAssertEqual(recorder.urls, [firstURL, latestURL])
  }

  private func writeImage(
    to url: URL,
    type: String,
    width: Int,
    height: Int,
    properties: [CFString: Any] = [:]
  ) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        type as CFString,
        1,
        nil
      )
    else {
      throw ImageLoadError.invalid
    }

    CGImageDestinationAddImage(
      destination,
      try makeImage(width: width, height: height, red: 0.35),
      properties as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      throw ImageLoadError.invalid
    }
  }

  private func makeImage(width: Int, height: Int, red: CGFloat) throws -> CGImage {
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw ImageLoadError.invalid
    }

    context.setFillColor(NSColor(srgbRed: red, green: 0.55, blue: 0.8, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
      throw ImageLoadError.invalid
    }
    return image
  }

  private func redComponent(atCenterOf image: CGImage) throws -> CGFloat {
    var pixel = [UInt8](repeating: 0, count: 4)
    guard
      let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw ImageLoadError.invalid
    }

    context.draw(
      image,
      in: CGRect(
        x: -CGFloat(image.width) / 2,
        y: -CGFloat(image.height) / 2,
        width: CGFloat(image.width),
        height: CGFloat(image.height)
      )
    )
    return CGFloat(pixel[0]) / 255
  }
}

private final class DecodeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedURLs: [URL] = []

  var urls: [URL] { lock.withLock { recordedURLs } }
  var count: Int { lock.withLock { recordedURLs.count } }

  func record(_ url: URL) {
    lock.withLock { recordedURLs.append(url) }
  }
}
