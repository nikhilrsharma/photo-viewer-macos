import AppKit
import Darwin
import ImageIO

struct LoadedImage: @unchecked Sendable {
  let cgImage: CGImage
  let pixelSize: CGSize

  init(cgImage: CGImage, pixelSize: CGSize? = nil) {
    self.cgImage = cgImage
    self.pixelSize = pixelSize ?? CGSize(width: cgImage.width, height: cgImage.height)
  }

  var decodedByteCount: Int {
    let (bytes, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
    return overflow ? Int.max : bytes
  }
}

enum ImageLoadError: LocalizedError, Equatable {
  case unavailable
  case invalid
  case unsupportedSource
  case exceedsSafetyLimits
  case changedDuringLoad

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "This image is no longer available."
    case .invalid:
      return "This image cannot be displayed."
    case .unsupportedSource:
      return
        "Open a readable image file from Finder. Folders, devices, and non-file URLs are not supported."
    case .exceedsSafetyLimits:
      return "This image exceeds Photo Viewer’s safe viewing limits."
    case .changedDuringLoad:
      return "This image changed while it was loading. Open it again."
    }
  }
}

enum ImageDecodePolicy {
  static let maximumSourceBytes = 512 * 1024 * 1024
  static let maximumSourcePixels = 100_000_000
  static let maximumSourceDimension = 100_000
  static let maximumPreviewDimension = 8192
  static let maximumDecodedBytes = 512 * 1024 * 1024

  struct Plan {
    let width: Int
    let height: Int
    let maximumDimension: Int
  }

  static func plan(width: Double, height: Double, depth: Double?, maximumPixelSize: Int?) throws
    -> Plan
  {
    guard width.isFinite, height.isFinite, width > 0, height > 0,
      width.rounded(.towardZero) == width, height.rounded(.towardZero) == height
    else { throw ImageLoadError.invalid }
    guard width <= Double(maximumSourceDimension), height <= Double(maximumSourceDimension) else {
      throw ImageLoadError.exceedsSafetyLimits
    }
    let sourceWidth = Int(width)
    let sourceHeight = Int(height)
    let (pixels, pixelOverflow) = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
    guard !pixelOverflow, pixels <= maximumSourcePixels else {
      throw ImageLoadError.exceedsSafetyLimits
    }
    // Unknown component depth uses the conservative 32-bit RGBA estimate.
    let componentDepth = depth ?? 32
    guard componentDepth.isFinite, componentDepth > 0, componentDepth <= 32,
      componentDepth.rounded(.towardZero) == componentDepth
    else { throw ImageLoadError.invalid }
    if let maximumPixelSize, maximumPixelSize <= 0 { throw ImageLoadError.invalid }
    let sourceMaximum = max(sourceWidth, sourceHeight)
    let outputMaximum = min(
      sourceMaximum, maximumPixelSize.map { min($0, maximumPreviewDimension) } ?? sourceMaximum
    )
    let scale = Double(outputMaximum) / Double(sourceMaximum)
    let outputWidth = max(1, Int(ceil(width * scale)))
    let outputHeight = max(1, Int(ceil(height * scale)))
    let bytesPerPixel = 4 * ((max(8, Int(componentDepth)) + 7) / 8)
    // Allow aligned decoded rows when checking the estimate before decoding.
    let rowBytes = ((outputWidth * bytesPerPixel + 63) / 64) * 64
    try validateDecodedBytes(bytesPerRow: rowBytes, height: outputHeight)
    return Plan(width: sourceWidth, height: sourceHeight, maximumDimension: outputMaximum)
  }

  static func validateDecodedBytes(bytesPerRow: Int, height: Int) throws {
    guard bytesPerRow > 0, height > 0 else { throw ImageLoadError.invalid }
    let (bytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
    guard !overflow, bytes <= maximumDecodedBytes else {
      throw ImageLoadError.exceedsSafetyLimits
    }
  }
}

/// For callers doing background eligibility checks. Loading repeats validation
/// on its own pinned descriptor; this helper is not a substitute for that check.
enum ImageInputValidation {
  /// Pure URL-shape validation, safe to use before dispatching filesystem work.
  static func isLocalFileURL(_ url: URL) -> Bool {
    // URL.path can sanitize an encoded NUL. Decode the serialized path exactly
    // once, preserving a legitimate filename containing the literal text "%00".
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
      let decodedPath = components.percentEncodedPath.removingPercentEncoding,
      url.isFileURL, decodedPath.hasPrefix("/"), !decodedPath.utf8.contains(0),
      url.path.hasPrefix("/"), !url.path.utf8.contains(0),
      url.user == nil, url.password == nil, url.port == nil
    else { return false }
    return url.host == nil || url.host == "" || url.host?.lowercased() == "localhost"
  }

  static func validate(url: URL) throws {
    _ = try PinnedImageFile(url: url)
  }
}

final class PinnedImageFile {
  let descriptor: Int32
  let length: Int
  let initialStatus: stat

  init(url: URL) throws {
    guard ImageInputValidation.isLocalFileURL(url) else { throw ImageLoadError.unsupportedSource }
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ImageLoadError.unavailable }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      close(descriptor)
      throw ImageLoadError.unavailable
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      close(descriptor)
      throw ImageLoadError.unsupportedSource
    }
    guard status.st_size > 0 else {
      close(descriptor)
      throw ImageLoadError.invalid
    }
    guard status.st_size <= off_t(ImageDecodePolicy.maximumSourceBytes) else {
      close(descriptor)
      throw ImageLoadError.exceedsSafetyLimits
    }
    self.descriptor = descriptor
    self.length = Int(status.st_size)
    self.initialStatus = status
  }

  deinit { close(descriptor) }

  func isUnchanged() -> Bool {
    var status = stat()
    return fstat(descriptor, &status) == 0 && status.st_size == initialStatus.st_size
      && status.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec
      && status.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec
      && status.st_ctimespec.tv_sec == initialStatus.st_ctimespec.tv_sec
      && status.st_ctimespec.tv_nsec == initialStatus.st_ctimespec.tv_nsec
  }

  func read(into buffer: UnsafeMutableRawPointer, at position: off_t, count: Int) -> Int {
    guard position >= 0, position < off_t(length), count > 0, isUnchanged() else { return 0 }
    let amount = min(count, length - Int(position))
    var copied = 0
    while copied < amount {
      let result = pread(
        descriptor, buffer.advanced(by: copied), amount - copied, position + off_t(copied))
      if result < 0, errno == EINTR { continue }
      guard result > 0 else { break }
      copied += result
    }
    return isUnchanged() ? copied : 0
  }

  func makeProvider() throws -> CGDataProvider {
    let context = Unmanaged.passRetained(self).toOpaque()
    var callbacks = CGDataProviderDirectCallbacks(
      version: 0,
      getBytePointer: nil,
      releaseBytePointer: nil,
      getBytesAtPosition: { context, buffer, position, count in
        guard let context else { return 0 }
        return Unmanaged<PinnedImageFile>.fromOpaque(context).takeUnretainedValue()
          .read(into: buffer, at: position, count: count)
      },
      releaseInfo: { context in
        if let context { Unmanaged<PinnedImageFile>.fromOpaque(context).release() }
      }
    )
    guard
      let provider = CGDataProvider(directInfo: context, size: off_t(length), callbacks: &callbacks)
    else {
      Unmanaged<PinnedImageFile>.fromOpaque(context).release()
      throw ImageLoadError.invalid
    }
    return provider
  }
}

enum ImageLoader {
  static func load(url: URL, maximumPixelSize: Int? = nil) throws -> LoadedImage {
    let file = try PinnedImageFile(url: url)
    let provider = try file.makeProvider()

    let options: CFDictionary =
      [
        kCGImageSourceShouldCache: false
      ] as CFDictionary

    guard let source = CGImageSourceCreateWithDataProvider(provider, options) else {
      throw ImageLoadError.invalid
    }

    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Double ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Double ?? 0
    let depth = properties?[kCGImagePropertyDepth] as? Double
    let plan = try ImageDecodePolicy.plan(
      width: width, height: height, depth: depth, maximumPixelSize: maximumPixelSize
    )
    let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1

    let thumbnailOptions: CFDictionary =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: plan.maximumDimension,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary

    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
      if !file.isUnchanged() { throw ImageLoadError.changedDuringLoad }
      throw ImageLoadError.invalid
    }
    guard file.isUnchanged() else { throw ImageLoadError.changedDuringLoad }
    guard image.width > 0, image.height > 0,
      max(image.width, image.height) <= plan.maximumDimension
    else { throw ImageLoadError.exceedsSafetyLimits }
    try ImageDecodePolicy.validateDecodedBytes(bytesPerRow: image.bytesPerRow, height: image.height)

    let originalSize: CGSize
    originalSize =
      (5...8).contains(orientation)
      ? CGSize(width: plan.height, height: plan.width)
      : CGSize(width: plan.width, height: plan.height)
    return LoadedImage(cgImage: image, pixelSize: originalSize)
  }
}

/// ImageIO decoding is synchronous. Keep one decode in flight and only the most
/// recent waiting request so rapid arrow-key navigation cannot accumulate work.
actor ImagePipeline {
  typealias Loader = @Sendable (URL, Int?) throws -> LoadedImage

  private struct FileStamp: Equatable {
    let size: Int
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int
    let fileNumber: UInt64
    let volumeNumber: Int32

    static func read(_ url: URL) -> FileStamp? {
      // Validate cache hits too, and fingerprint the opened symlink target rather
      // than the link itself so target replacement cannot return stale pixels.
      guard let file = try? PinnedImageFile(url: url) else { return nil }
      let status = file.initialStatus
      return FileStamp(
        size: file.length,
        modificationSeconds: status.st_mtimespec.tv_sec,
        modificationNanoseconds: status.st_mtimespec.tv_nsec,
        changeSeconds: status.st_ctimespec.tv_sec,
        changeNanoseconds: status.st_ctimespec.tv_nsec,
        fileNumber: status.st_ino,
        volumeNumber: status.st_dev
      )
    }
  }

  private struct Request {
    let id: UUID
    let url: URL
    let maximumPixelSize: Int?
    let stamp: FileStamp?
    let accessLeases: [SecurityScopeLease]
    var continuation: CheckedContinuation<LoadedImage, any Error>?
  }

  private struct CacheEntry {
    let url: URL
    let stamp: FileStamp
    let maximumPixelSize: Int?
    let image: LoadedImage
  }

  private let byteLimit: Int
  private let loader: Loader
  private var active: Request?
  private var pending: Request?
  // Least recently used first. The byte limit keeps this list small.
  private var cache: [CacheEntry] = []
  private(set) var cachedByteCount = 0

  init(
    byteLimit: Int = 128 * 1024 * 1024,
    loader: @escaping Loader = {
      try ImageLoader.load(url: $0, maximumPixelSize: $1)
    }
  ) {
    self.byteLimit = max(0, byteLimit)
    self.loader = loader
  }

  func load(
    url: URL, maximumPixelSize: Int? = nil, accessLeases: [SecurityScopeLease] = []
  ) async throws -> LoadedImage {
    try Task.checkCancellation()
    // Reject ambiguous relative file URLs before standardization can resolve
    // them against the process working directory and bypass input validation.
    guard ImageInputValidation.isLocalFileURL(url) else { throw ImageLoadError.unsupportedSource }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let normalizedURL = url.standardizedFileURL
        let stamp = FileStamp.read(normalizedURL)
        let maximum = maximumPixelSize.map { max(1, $0) }
        // A new foreground request supersedes even one waiting on a cache miss.
        pending?.continuation?.resume(throwing: CancellationError())
        pending = nil
        active?.continuation?.resume(throwing: CancellationError())
        active?.continuation = nil
        if let image = cachedImage(for: normalizedURL, stamp: stamp, maximumPixelSize: maximum) {
          continuation.resume(returning: image)
          return
        }
        pending = Request(
          id: id, url: normalizedURL, maximumPixelSize: maximum, stamp: stamp,
          accessLeases: accessLeases,
          continuation: continuation
        )
        startNextIfPossible()
      }
    } onCancel: {
      Task { await self.cancel(id: id) }
    }
  }

  func cancelPendingLoads() {
    pending?.continuation?.resume(throwing: CancellationError())
    pending = nil
    active?.continuation?.resume(throwing: CancellationError())
    active?.continuation = nil
  }

  func removeAllCachedImages() {
    cache.removeAll()
    cachedByteCount = 0
  }

  private func cancel(id: UUID) {
    if pending?.id == id {
      pending?.continuation?.resume(throwing: CancellationError())
      pending = nil
    }
    if active?.id == id {
      active?.continuation?.resume(throwing: CancellationError())
      active?.continuation = nil
    }
  }

  private func startNextIfPossible() {
    guard active == nil, let request = pending else { return }
    pending = nil
    // A finishing larger decode can satisfy a resize request that arrived while
    // it was running. Recheck here to avoid immediately decoding the file again.
    if let image = cachedImage(
      for: request.url, stamp: FileStamp.read(request.url),
      maximumPixelSize: request.maximumPixelSize
    ) {
      request.continuation?.resume(returning: image)
      return
    }
    active = request
    let loader = loader
    let id = request.id
    let url = request.url
    let maximum = request.maximumPixelSize
    let accessLeases = request.accessLeases
    Task.detached(priority: .userInitiated) {
      let result = withExtendedLifetime(accessLeases) {
        Result { try autoreleasepool { try loader(url, maximum) } }
      }
      await self.finished(id: id, result: result)
    }
  }

  private func finished(id: UUID, result: Result<LoadedImage, any Error>) {
    guard let request = active, request.id == id else { return }
    active = nil
    if case .success(let image) = result,
      let stamp = request.stamp, FileStamp.read(request.url) == stamp,
      image.decodedByteCount <= byteLimit
    {
      while cachedByteCount + image.decodedByteCount > byteLimit, !cache.isEmpty {
        cachedByteCount -= cache.removeFirst().image.decodedByteCount
      }
      cache.append(
        CacheEntry(
          url: request.url, stamp: stamp, maximumPixelSize: request.maximumPixelSize, image: image
        ))
      cachedByteCount += image.decodedByteCount
    }
    request.continuation?.resume(with: result)
    startNextIfPossible()
  }

  private func discardChangedEntries(for url: URL, stamp: FileStamp?) {
    cache.removeAll { entry in
      if entry.url == url && entry.stamp != stamp {
        cachedByteCount -= entry.image.decodedByteCount
        return true
      }
      return false
    }
  }

  private func cachedImage(for url: URL, stamp: FileStamp?, maximumPixelSize: Int?) -> LoadedImage?
  {
    discardChangedEntries(for: url, stamp: stamp)
    guard
      let index = cache.firstIndex(where: { entry in
        guard entry.url == url, entry.stamp == stamp else { return false }
        let decoded = max(entry.image.cgImage.width, entry.image.cgImage.height)
        let original = Int(max(entry.image.pixelSize.width, entry.image.pixelSize.height))
        return entry.maximumPixelSize == maximumPixelSize || decoded >= original
          || maximumPixelSize.map { decoded >= $0 } == true
      })
    else { return nil }
    let entry = cache.remove(at: index)
    cache.append(entry)
    return entry.image
  }
}
