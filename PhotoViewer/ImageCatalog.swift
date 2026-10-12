import Darwin
import Dispatch
import Foundation
import UniformTypeIdentifiers

struct FolderSnapshot: Sendable {
  let urls: [URL]
  let indexByCanonicalKey: [String: Int]
  let indexByPath: [String: Int]

  init(urls: [URL]) {
    let entries = urls.map { url in
      (
        url: url,
        name: url.lastPathComponent,
        path: url.standardizedFileURL.path,
        key: ImageCatalog.canonicalKey(for: url)
      )
    }.sorted { lhs, rhs in
      let comparison = lhs.name.localizedStandardCompare(rhs.name)
      if comparison == .orderedSame {
        return lhs.path.compare(rhs.path, options: .literal) == .orderedAscending
      }
      return comparison == .orderedAscending
    }

    var uniqueURLs: [URL] = []
    var indices: [String: Int] = [:]
    var pathIndices: [String: Int] = [:]
    uniqueURLs.reserveCapacity(entries.count)
    indices.reserveCapacity(entries.count)
    pathIndices.reserveCapacity(entries.count)
    for entry in entries {
      let index: Int
      if let existingIndex = indices[entry.key] {
        index = existingIndex
      } else {
        index = uniqueURLs.count
        indices[entry.key] = index
        uniqueURLs.append(entry.url)
      }
      pathIndices[entry.path] = index
      pathIndices[entry.key] = index
    }
    self.urls = uniqueURLs
    self.indexByCanonicalKey = indices
    self.indexByPath = pathIndices
  }

  func index(forCanonicalKey key: String) -> Int? {
    indexByCanonicalKey[key]
  }

  func index(for url: URL) -> Int? {
    indexByPath[url.standardizedFileURL.path]
  }
}

enum ImageCatalog {
  static let supportedExtensions: Set<String> = [
    // Everyday photo and web formats.
    "jpg", "jpeg", "jpe", "jfif", "png", "apng", "gif", "webp",
    "heic", "heif", "heics", "avif", "avifs",
    "tif", "tiff", "bmp", "dib",

    // Modern and professional formats decoded natively by macOS ImageIO.
    "jxl", "jp2", "j2k", "j2c", "jpf", "jpx",
    "psd", "exr", "tga", "targa", "hdr", "rgbe",

    // Icons, multi-picture images, and portable bitmap families.
    "ico", "cur", "icns", "mpo",
    "pbm", "pgm", "ppm", "pnm", "sgi", "rgb", "rgba", "bw",
  ]

  static let supportedContentTypeIdentifiers: Set<String> = [
    "public.jpeg",
    "public.png",
    "public.heic",
    "public.heif",
    "public.heics",
    "public.avif",
    "public.avis",
    "public.tiff",
    "com.compuserve.gif",
    "com.microsoft.bmp",
    "org.webmproject.webp",
    "public.jpeg-2000",
    "public.jpeg-xl",
    "com.adobe.photoshop-image",
    "com.ilm.openexr-image",
    "com.truevision.tga-image",
    "public.radiance",
    "com.microsoft.ico",
    "com.microsoft.cur",
    "com.apple.icns",
    "public.mpo-image",
    "public.pbm",
    "com.sgi.sgi-image",
  ]

  static func supports(_ url: URL, contentType: UTType? = nil) -> Bool {
    guard ImageInputValidation.isLocalFileURL(url) else { return false }
    if supportedExtensions.contains(url.pathExtension.lowercased()) {
      return true
    }

    guard let contentType, !contentType.conforms(to: .rawImage) else {
      return false
    }
    return supportedContentTypeIdentifiers.contains(contentType.identifier)
  }

  static func images(in folder: URL, fileManager: FileManager = .default) -> [URL] {
    imagesIfAvailable(in: folder, fileManager: fileManager) ?? []
  }

  static func imagesIfAvailable(
    in folder: URL,
    fileManager: FileManager = .default
  ) -> [URL]? {
    snapshotIfAvailable(in: folder, fileManager: fileManager)?.urls
  }

  static func snapshotIfAvailable(
    in folder: URL,
    fileManager: FileManager = .default
  ) -> FolderSnapshot? {
    unorderedImagesIfAvailable(in: folder, fileManager: fileManager).map {
      FolderSnapshot(urls: $0)
    }
  }

  static func unorderedImagesIfAvailable(
    in folder: URL,
    fileManager: FileManager = .default
  ) -> [URL]? {
    guard ImageInputValidation.isLocalFileURL(folder) else { return nil }
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .contentTypeKey,
    ]
    let urls: [URL]
    do {
      urls = try fileManager.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
      )
    } catch {
      return nil
    }

    let images = urls.filter { url in
      let values = try? url.resourceValues(forKeys: keys)
      guard values?.isDirectory != true, values?.isHidden != true,
        supports(url, contentType: values?.contentType)
      else { return false }

      // Do not open every sibling: doing so can hydrate cloud placeholders.
      // Follow links only for metadata, and fail closed for special/missing files.
      // ImageLoader independently validates a pinned descriptor before decoding,
      // so a path replaced after this snapshot cannot bypass the regular-file guard.
      if values?.isSymbolicLink == true || values?.isRegularFile == nil {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return false }
        return (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
      }
      return values?.isRegularFile == true
    }
    return images
  }

  static func canonicalKey(for url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  static func refersToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
    canonicalKey(for: lhs) == canonicalKey(for: rhs)
  }
}

@MainActor
final class FolderMonitor {
  private var watchToken: FolderWatchToken?
  private var generation = UUID()

  @discardableResult
  func watch(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) async -> Bool {
    guard !Task.isCancelled else { return false }
    stop()
    let activeGeneration = generation
    let path = url.path
    let descriptor = await Task.detached(priority: .utility) {
      open(path, O_EVTONLY | O_CLOEXEC)
    }.value
    guard !Task.isCancelled, generation == activeGeneration, descriptor >= 0 else {
      if descriptor >= 0 { close(descriptor) }
      return false
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
      queue: .global(qos: .utility)
    )
    source.setEventHandler { @Sendable [weak self] in
      Task { @MainActor [weak self] in
        guard self?.generation == activeGeneration else { return }
        onChange()
      }
    }
    source.setCancelHandler { @Sendable in close(descriptor) }
    watchToken = FolderWatchToken(source: source)
    source.resume()
    return true
  }

  func stop() {
    generation = UUID()
    watchToken = nil
  }
}

// The source can be cancelled from any thread. Owning it in this token also
// closes the read-only descriptor when its main-actor monitor is released.
private final class FolderWatchToken: @unchecked Sendable {
  let source: DispatchSourceFileSystemObject

  init(source: DispatchSourceFileSystemObject) {
    self.source = source
  }

  deinit {
    source.cancel()
  }
}
