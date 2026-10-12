import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Standalone synthetic microbenchmark. It never opens or modifies user photos.
// Baseline operations are snapshots of the pre-optimization ImageCatalog and
// ImageLoader behavior, so edits to the application cannot change the baseline.
// Cached lookup and display-sized decode measure the proposed strategies, not
// the complete application's end-to-end latency, animations, or peak RSS.

struct FileSnapshot: Equatable {
  let hash: String
  let size: UInt64
  let modified: Date
  let created: Date
  let extendedAttributes: [String: Data]

  init(_ url: URL) throws {
    hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    size = (attributes[.size] as! NSNumber).uint64Value
    modified = attributes[.modificationDate] as! Date
    created = attributes[.creationDate] as! Date
    extendedAttributes = try readExtendedAttributes(url)
  }
}

func readExtendedAttributes(_ url: URL) throws -> [String: Data] {
  let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
  guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
  guard count > 0 else { return [:] }
  var names = [CChar](repeating: 0, count: count)
  let result = listxattr(url.path, &names, count, XATTR_NOFOLLOW)
  guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
  let bytes = names.prefix(result).map { UInt8(bitPattern: $0) }
  var attributes: [String: Data] = [:]
  for nameBytes in bytes.split(separator: 0) {
    let name = String(decoding: nameBytes, as: UTF8.self)
    let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    var value = Data(count: size)
    let read = value.withUnsafeMutableBytes {
      getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
    }
    guard read == size else { throw POSIXError(.EIO) }
    attributes[name] = value
  }
  return attributes
}

func elapsedMilliseconds<T>(_ body: () throws -> T) rethrows -> (T, Double) {
  let start = DispatchTime.now().uptimeNanoseconds
  let result = try body()
  let end = DispatchTime.now().uptimeNanoseconds
  return (result, Double(end - start) / 1_000_000)
}

func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

func baselineCatalog(_ folder: URL) throws -> [URL] {
  let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .contentTypeKey]
  return try FileManager.default.contentsOfDirectory(
    at: folder,
    includingPropertiesForKeys: Array(keys),
    options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
  ).filter { url in
    let values = try? url.resourceValues(forKeys: keys)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard values?.isDirectory != true, !(exists && isDirectory.boolValue), values?.isHidden != true else {
      return false
    }
    // Fixtures all use known supported extensions, matching the normal fast
    // branch of the application's complete extension/content-type predicate.
    return ["jpg", "png", "heic", "bmp", "jpeg"].contains(url.pathExtension.lowercased())
  }.sorted {
    let comparison = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
    return comparison == .orderedSame
      ? $0.path.compare($1.path, options: .literal) == .orderedAscending
      : comparison == .orderedAscending
  }
}

func baselineSameFile(_ left: URL, _ right: URL) -> Bool {
  left.standardizedFileURL.resolvingSymlinksInPath()
    == right.standardizedFileURL.resolvingSymlinksInPath()
}

func navigationBenchmark(root: URL, count: Int) throws -> [String: Any] {
  let folder = root.appendingPathComponent("catalog-\(count)", isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let extensions = ["jpg", "png", "heic", "bmp", "jpeg"]
  for index in 1...count {
    let url = folder.appendingPathComponent("Photo \(index).\(extensions[index % extensions.count])")
    // Directory scanning does not decode pixels; tiny synthetic placeholders
    // deliberately isolate filename sorting / metadata / identity costs.
    try Data([0x50, 0x56]).write(to: url, options: .withoutOverwriting)
  }
  let prepared = try baselineCatalog(folder)
  let current = prepared[count - 1]
  let paths = prepared.map(\.path)
  let cachedIndices = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($1, $0) })
  let repeats = 5
  var scanSamples: [Double] = []
  var identitySamples: [Double] = []
  var totalSamples: [Double] = []
  var checksum = 0
  // Warm file-system caches once. Results below are explicitly warm-cache.
  _ = prepared.firstIndex { baselineSameFile($0, current) }
  for _ in 0..<repeats {
    let (urls, scan) = try elapsedMilliseconds { try baselineCatalog(folder) }
    let (index, identity) = elapsedMilliseconds { urls.firstIndex { baselineSameFile($0, current) }! }
    checksum &+= index
    scanSamples.append(scan)
    identitySamples.append(identity)
    totalSamples.append(scan + identity)
  }
  let (_, cachedMilliseconds) = elapsedMilliseconds {
    for index in 0..<100_000 { checksum &+= cachedIndices[paths[index % count]]! }
  }
  return [
    "images": count,
    "repetitions": repeats,
    "baseline_scan_sort_ms_median": median(scanSamples),
    "baseline_canonical_index_ms_median": median(identitySamples),
    "baseline_combined_ms_median": median(totalSamples),
    "cached_lookup_ms_per_operation": cachedMilliseconds / 100_000,
    "checksum": checksum,
    "fixture_kind": "tiny placeholders; warm filesystem cache; last-image baseline lookup",
  ]
}

func makeJPEG(_ url: URL) throws {
  let width = 8000
  let height = 6000
  let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  let context = CGContext(
    data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: width * 4,
    space: colourSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
  )!
  let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
  // Deterministic colour/detail texture: reproducible, but not a real photo.
  var random: UInt32 = 0x50_56_20_26
  for y in 0..<height {
    for x in 0..<width {
      random ^= random << 13
      random ^= random >> 17
      random ^= random << 5
      let offset = (y * width + x) * 4
      let noise = Int(random & 31)
      pixels[offset] = UInt8((x / 32 + noise) % 256)
      pixels[offset + 1] = UInt8((y / 24 + noise) % 256)
      pixels[offset + 2] = UInt8(((x + y) / 40 + noise) % 256)
      pixels[offset + 3] = 255
    }
  }
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else {
    throw NSError(domain: "PhotoViewerBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "JPEG fixture creation failed"])
  }
  // Ensure the read-only check covers a nonempty extended-metadata value too.
  let marker = Data("preserve-benchmark-metadata".utf8)
  let result = marker.withUnsafeBytes {
    setxattr(url.path, "com.example.photoviewer.benchmark", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
  }
  guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
}

func decode(_ url: URL, maximumDimension: Int) -> CGImage {
  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)!
  let options: CFDictionary = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
    kCGImageSourceShouldCacheImmediately: true,
  ] as CFDictionary
  return CGImageSourceCreateThumbnailAtIndex(source, 0, options)!
}

func imageBenchmark(root: URL) throws -> [String: Any] {
  let fixture = root.appendingPathComponent("synthetic-48mp.jpg")
  try autoreleasepool { try makeJPEG(fixture) }
  let before = try FileSnapshot(fixture)
  let namesBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
  var results: [[String: Any]] = []
  for maximumDimension in [8000, 2560] {
    autoreleasepool { _ = decode(fixture, maximumDimension: maximumDimension) }
    var samples: [Double] = []
    var width = 0
    var height = 0
    var decodedBytes = 0
    for _ in 0..<7 {
      autoreleasepool {
        let (image, time) = elapsedMilliseconds { decode(fixture, maximumDimension: maximumDimension) }
        width = image.width
        height = image.height
        decodedBytes = image.bytesPerRow * image.height
        samples.append(time)
      }
    }
    results.append([
      "requested_maximum_dimension": maximumDimension,
      "decoded_width": width,
      "decoded_height": height,
      "decoded_pixel_buffer_bytes": decodedBytes,
      "decode_ms_median": median(samples),
      "decode_ms_samples": samples,
    ])
  }
  let after = try FileSnapshot(fixture)
  let namesAfter = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
  precondition(before == after && namesBefore == namesAfter, "A fixture changed while being decoded")
  return [
    "fixture": fixture.path,
    "fixture_bytes": before.size,
    "fixture_sha256": before.hash,
    "content_name_size_created_modified_xattrs_unchanged": before == after && namesBefore == namesAfter,
    "extended_attribute_names": before.extendedAttributes.keys.sorted(),
    "runs": results,
    "notes": "Warm-cache synchronous ImageIO microbenchmark on generated JPEG; decoded buffer sizes are not process peak RSS. No user image read or written.",
  ]
}

@main
struct Benchmark {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      print("Usage: PhotoViewerBenchmark <new-temporary-fixture-directory>")
      return
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    // Caller supplies a newly created empty temporary directory. Refuse to mix
    // benchmark-generated files with anything already stored there.
    let existing = try FileManager.default.contentsOfDirectory(atPath: root.path)
    precondition(existing.isEmpty, "Fixture directory must be empty")
    let navigation = try [100, 1000, 5000].map { try navigationBenchmark(root: root, count: $0) }
    let image = try imageBenchmark(root: root)
    let result: [String: Any] = [
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "processor_count": ProcessInfo.processInfo.processorCount,
      "fixture_directory": root.path,
      "navigation": navigation,
      "image": image,
    ]
    let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: output, as: UTF8.self))
  }
}
