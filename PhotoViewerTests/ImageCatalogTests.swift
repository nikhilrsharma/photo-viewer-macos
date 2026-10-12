import Darwin
import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import PhotoViewer

final class ImageCatalogTests: XCTestCase {
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

  func testSupportedExtensionsAreCaseInsensitive() {
    let supported = [
      "JPG", "jpeg", "JfIf", "PNG", "apng", "HEIC", "heif", "HEICS", "AVIF", "avifs",
      "TIF", "tiff", "GIF", "BMP", "dib", "WEBP", "JXL", "jp2", "j2k", "j2c", "jpf",
      "jpx", "PSD", "EXR", "TGA", "targa", "HDR", "rgbe", "ICO", "cur", "ICNS", "MPO",
      "PBM", "pgm", "ppm", "pnm", "SGI", "rgb", "rgba", "bw",
    ]

    for extensionName in supported {
      XCTAssertTrue(
        ImageCatalog.supports(URL(fileURLWithPath: "/tmp/photo.\(extensionName)")),
        "Expected .\(extensionName) to be supported"
      )
    }

    for extensionName in ["raw", "dng", "svg", "pdf", "mj2", "psb", "txt"] {
      XCTAssertFalse(
        ImageCatalog.supports(URL(fileURLWithPath: "/tmp/photo.\(extensionName)")),
        "Expected .\(extensionName) to remain unsupported"
      )
    }
  }

  func testContentTypeCanRecognizeAnImageWithoutAnExtensionButExcludesRaw() {
    let extensionlessURL = URL(fileURLWithPath: "/tmp/photo")

    XCTAssertTrue(ImageCatalog.supports(extensionlessURL, contentType: .png))
    XCTAssertFalse(ImageCatalog.supports(extensionlessURL, contentType: .rawImage))
  }

  func testCatalogRejectsNonlocalAndNonFileURLs() {
    for value in [
      "https://example.invalid/photo.jpg", "file://example.invalid/tmp/photo.png",
      "file:relative.jpg", "file:///tmp/photo%00.jpg", "file://user@localhost/tmp/photo.jpg",
    ] {
      let url = URL(string: value)!
      XCTAssertFalse(ImageCatalog.supports(url, contentType: .png))
      XCTAssertNil(ImageCatalog.unorderedImagesIfAvailable(in: url))
    }
  }

  func testCatalogExcludesSpecialFilesAndTheirAliasesWithoutOpeningThem() throws {
    let regular = temporaryFolder.appendingPathComponent("photo.png")
    try Data([0]).write(to: regular)
    let fifo = temporaryFolder.appendingPathComponent("pipe.jpg")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    let alias = temporaryFolder.appendingPathComponent("pipe-alias.png")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fifo)
    let broken = temporaryFolder.appendingPathComponent("broken.jpg")
    try FileManager.default.createSymbolicLink(
      at: broken, withDestinationURL: temporaryFolder.appendingPathComponent("missing.jpg"))
    let regularAlias = temporaryFolder.appendingPathComponent("photo-alias.png")
    try FileManager.default.createSymbolicLink(at: regularAlias, withDestinationURL: regular)

    let start = Date()
    let urls = try XCTUnwrap(ImageCatalog.unorderedImagesIfAvailable(in: temporaryFolder))
    XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["photo.png", "photo-alias.png"])
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }

  func testCatalogMixesFormatsAndUsesNaturalOrder() throws {
    let filenames = [
      "image11.jxl", "image10.avif", "image9.webp", "image8.gif", "image7.tiff",
      "image6.heif", "image5.heic", "image4.png", "image3.bmp", "image2.jpeg",
      "image1.JPG", "notes.txt", "scan.raw",
    ]
    for name in filenames {
      let data = Data([0])
      try data.write(to: temporaryFolder.appendingPathComponent(name))
    }

    try FileManager.default.createDirectory(
      at: temporaryFolder.appendingPathComponent("image12.jpg"),
      withIntermediateDirectories: false
    )

    let images = ImageCatalog.images(in: temporaryFolder)
    XCTAssertEqual(
      images.map(\.lastPathComponent),
      [
        "image1.JPG", "image2.jpeg", "image3.bmp", "image4.png", "image5.heic",
        "image6.heif", "image7.tiff", "image8.gif", "image9.webp", "image10.avif",
        "image11.jxl",
      ]
    )
  }

  func testMissingFolderReportsEnumerationFailure() {
    let missingFolder = temporaryFolder.appendingPathComponent("not-there", isDirectory: true)
    XCTAssertNil(ImageCatalog.imagesIfAvailable(in: missingFolder))
    XCTAssertEqual(ImageCatalog.images(in: missingFolder), [])
  }

  func testSnapshotNaturallySortsAndIndexesUniqueFiles() throws {
    let filenames = ["image10.png", "image2.jpg", "image1.heic"]
    let urls = filenames.map { temporaryFolder.appendingPathComponent($0) }
    for url in urls {
      try Data([0]).write(to: url)
    }

    let snapshot = FolderSnapshot(urls: urls + [urls[1], urls[0]])

    XCTAssertEqual(
      snapshot.urls.map(\.lastPathComponent), ["image1.heic", "image2.jpg", "image10.png"])
    XCTAssertEqual(snapshot.index(for: urls[2]), 0)
    XCTAssertEqual(snapshot.index(for: urls[1]), 1)
    XCTAssertEqual(snapshot.index(for: urls[0]), 2)
    XCTAssertEqual(snapshot.index(forCanonicalKey: ImageCatalog.canonicalKey(for: urls[1])), 1)
    XCTAssertNil(snapshot.index(for: temporaryFolder.appendingPathComponent("missing.jpg")))
  }

  func testSnapshotDeduplicatesSymlinksAndRetainsEveryAliasIndex() throws {
    let original = temporaryFolder.appendingPathComponent("photo2.jpg")
    let alias = temporaryFolder.appendingPathComponent("photo1.jpg")
    try Data([0]).write(to: original)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)

    let snapshot = FolderSnapshot(urls: [original, alias])

    XCTAssertEqual(snapshot.urls, [alias])
    XCTAssertEqual(snapshot.index(for: original), 0)
    XCTAssertEqual(snapshot.index(for: alias), 0)
    XCTAssertEqual(snapshot.index(forCanonicalKey: ImageCatalog.canonicalKey(for: original)), 0)

    // UI lookups use the captured paths even after a link or file disappears.
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.removeItem(at: original)
    XCTAssertEqual(snapshot.index(for: alias), 0)
    XCTAssertEqual(snapshot.index(for: original), 0)
  }

  func testCatalogExcludesSymlinkedDirectoriesWithImageExtensions() throws {
    let directory = temporaryFolder.appendingPathComponent("photos", isDirectory: true)
    let directoryAlias = temporaryFolder.appendingPathComponent("not-a-photo.jpg")
    let image = temporaryFolder.appendingPathComponent("photo.png")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: directory)
    try Data([0]).write(to: image)

    let snapshot = try XCTUnwrap(ImageCatalog.snapshotIfAvailable(in: temporaryFolder))

    XCTAssertEqual(snapshot.urls.map(\.lastPathComponent), ["photo.png"])
    XCTAssertEqual(snapshot.index(for: image), 0)
  }

  @MainActor
  func testFolderMonitorReportsChangesAndStopsCallbacks() async throws {
    let monitor = FolderMonitor()
    var didChange = false
    let isWatching = await monitor.watch(temporaryFolder) { didChange = true }
    XCTAssertTrue(isWatching)

    try Data([0]).write(to: temporaryFolder.appendingPathComponent("photo1.jpg"))
    for _ in 0..<100 where !didChange {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(didChange)

    monitor.stop()
    didChange = false
    try Data([0]).write(to: temporaryFolder.appendingPathComponent("photo2.jpg"))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(didChange)

    let watchedMissingFolder = await monitor.watch(
      temporaryFolder.appendingPathComponent("missing")
    ) {}
    XCTAssertFalse(watchedMissingFolder)
  }
}
