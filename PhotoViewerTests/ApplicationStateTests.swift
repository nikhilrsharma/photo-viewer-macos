import Foundation
import XCTest

@testable import PhotoViewer

@MainActor
final class ApplicationStateTests: XCTestCase {
  nonisolated(unsafe) private var temporaryFolder: URL!

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

  func testNavigatesAcrossMixedFormatsInNaturalOrderWithoutWrapping() async throws {
    let filenames = [
      "photo10.jxl", "photo2.jpeg", "photo1.JPG", "photo3.bmp", "photo4.png",
      "photo5.heic", "photo6.heif", "photo7.gif", "photo8.webp", "photo9.avif",
    ]
    try createFiles(named: filenames + ["notes.txt"])

    let state = ApplicationState()
    state.openExternal(temporaryFolder.appendingPathComponent("photo1.JPG"))
    await waitUntil { state.hasEnumeratedFolder }

    XCTAssertEqual(state.folderImages.map(\.lastPathComponent), filenames.sortedNaturally())
    XCTAssertEqual(state.currentURL?.lastPathComponent, "photo1.JPG")
    XCTAssertEqual(state.photoPosition, .init(number: 1, total: filenames.count))

    state.navigate(by: -1)
    XCTAssertEqual(state.currentURL?.lastPathComponent, "photo1.JPG")

    for (offset, expectedName) in filenames.sortedNaturally().dropFirst().enumerated() {
      state.navigate(by: 1)
      XCTAssertEqual(state.currentURL?.lastPathComponent, expectedName)
      XCTAssertEqual(
        state.photoPosition,
        .init(number: offset + 2, total: filenames.count)
      )
    }

    state.navigate(by: 1)
    XCTAssertEqual(state.currentURL?.lastPathComponent, "photo10.jxl")

    state.navigate(by: -1)
    XCTAssertEqual(state.currentURL?.lastPathComponent, "photo9.avif")
  }

  func testNavigationRefreshFindsNewSibling() async throws {
    try createFiles(named: ["photo1.jpg"])
    let state = ApplicationState()
    state.openExternal(temporaryFolder.appendingPathComponent("photo1.jpg"))
    await waitUntil { state.hasEnumeratedFolder }

    try createFiles(named: ["photo2.heic"])
    state.navigate(by: 1)
    await waitUntil { state.currentURL?.lastPathComponent == "photo2.heic" }
    XCTAssertEqual(state.currentURL?.lastPathComponent, "photo2.heic")
    XCTAssertEqual(state.photoPosition, .init(number: 2, total: 2))
  }

  func testNavigationKeepsCachedFolderWhenRefreshTemporarilyFails() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let second = temporaryFolder.appendingPathComponent("photo2.png")
    let invocationCount = LockedCounter()
    let state = ApplicationState(folderImagesProvider: { _ in
      return invocationCount.increment() == 1 ? [first, second] : nil
    })

    state.openExternal(first)
    await waitUntil { state.hasEnumeratedFolder }
    state.refreshCatalog()
    await waitUntil { state.navigationNotice != nil }
    state.navigate(by: 1)

    XCTAssertEqual(state.folderImages, [first, second])
    XCTAssertEqual(state.currentURL, second)
    XCTAssertNotNil(state.navigationNotice)
    XCTAssertEqual(state.photoPosition, .init(number: 2, total: 2))
  }

  func testFolderReadFailureKeepsCurrentImageAndShowsNavigationNotice() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let state = ApplicationState(folderImagesProvider: { _ in nil })

    state.openExternal(first)
    await waitUntil { state.navigationNotice != nil }

    XCTAssertEqual(state.folderImages, [first])
    XCTAssertEqual(state.currentURL, first)
    XCTAssertNotNil(state.navigationNotice)
    XCTAssertNil(state.photoPosition)
  }

  func testMultipleFinderSelectionsRemainNavigableWhenFolderReadIsDenied() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let second = temporaryFolder.appendingPathComponent("photo2.png")
    let state = ApplicationState(folderImagesProvider: { _ in nil })

    state.openExternal([first, second])
    await waitUntil { state.navigationNotice != nil }
    state.navigate(by: 1)

    XCTAssertEqual(state.folderImages, [first, second])
    XCTAssertEqual(state.currentURL, second)
    XCTAssertNotNil(state.navigationNotice)
    XCTAssertNil(state.photoPosition)
  }

  func testNavigationRetriesFolderReadAndClearsNavigationNotice() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let second = temporaryFolder.appendingPathComponent("photo2.png")
    let invocationCount = LockedCounter()
    let state = ApplicationState(folderImagesProvider: { _ in
      return invocationCount.increment() == 1 ? nil : [first, second]
    })

    state.openExternal(first)
    await waitUntil { state.navigationNotice != nil }
    XCTAssertNotNil(state.navigationNotice)
    XCTAssertNil(state.photoPosition)

    state.navigate(by: 1)
    await waitUntil { state.currentURL == second }

    XCTAssertEqual(state.currentURL, second)
    XCTAssertNil(state.navigationNotice)
    XCTAssertEqual(state.photoPosition, .init(number: 2, total: 2))
  }

  func testCorruptImageDoesNotBlockLaterNavigation() async throws {
    try createFiles(named: ["photo1.jpg", "photo2.png", "photo3.heic"])
    let state = ApplicationState()
    state.openExternal(temporaryFolder.appendingPathComponent("photo1.jpg"))
    await waitUntil { state.hasEnumeratedFolder }

    state.navigate(by: 1)
    state.navigate(by: 1)

    XCTAssertEqual(state.currentURL?.lastPathComponent, "photo3.heic")
  }

  func testMetadataUpdatesWhenNavigating() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let second = temporaryFolder.appendingPathComponent("photo2.png")
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let secondDate = Date(timeIntervalSince1970: 1_710_000_000)
    let firstMetadata = ImageFileMetadata(creationDate: firstDate, fileSizeBytes: 1_234)
    let secondMetadata = ImageFileMetadata(creationDate: secondDate, fileSizeBytes: 5_678)
    let state = ApplicationState(
      fileMetadataProvider: { url in
        url.lastPathComponent == first.lastPathComponent ? firstMetadata : secondMetadata
      },
      folderImagesProvider: { _ in [first, second] }
    )

    state.openExternal(first)
    XCTAssertTrue(state.isMetadataLoading)
    await waitUntil { state.fileMetadata == firstMetadata }
    await waitUntil { state.hasEnumeratedFolder }
    XCTAssertEqual(state.fileMetadata, firstMetadata)
    XCTAssertFalse(state.isMetadataLoading)

    state.navigate(by: 1)
    XCTAssertNil(state.fileMetadata)
    XCTAssertTrue(state.isMetadataLoading)
    await waitUntil { state.fileMetadata == secondMetadata }
    XCTAssertEqual(state.fileMetadata, secondMetadata)
    XCTAssertFalse(state.isMetadataLoading)
  }

  func testSupersededMetadataCannotReplaceCurrentImageMetadata() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let second = temporaryFolder.appendingPathComponent("photo2.png")
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let secondDate = Date(timeIntervalSince1970: 1_710_000_000)
    let firstMetadata = ImageFileMetadata(creationDate: firstDate, fileSizeBytes: 111)
    let secondMetadata = ImageFileMetadata(creationDate: secondDate, fileSizeBytes: 222)
    let firstProviderStarted = LockedFlag()
    let allowFirstProviderToReturn = DispatchSemaphore(value: 0)
    let state = ApplicationState(
      fileMetadataProvider: { url in
        if url.lastPathComponent == first.lastPathComponent {
          firstProviderStarted.set()
          _ = allowFirstProviderToReturn.wait(timeout: .now() + 1)
          return firstMetadata
        }
        return secondMetadata
      },
      folderImagesProvider: { _ in [first, second] }
    )

    state.openExternal(first)
    await waitUntil { firstProviderStarted.get() }
    await waitUntil { state.hasEnumeratedFolder }
    state.navigate(by: 1)
    allowFirstProviderToReturn.signal()
    await waitUntil { state.fileMetadata == secondMetadata }
    try? await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(state.currentURL, second)
    XCTAssertEqual(state.fileMetadata, secondMetadata)
  }

  func testUnavailableMetadataFinishesLoadingWithoutInventingValues() async {
    let image = temporaryFolder.appendingPathComponent("photo.jpg")
    let state = ApplicationState(
      fileMetadataProvider: { _ in
        ImageFileMetadata(creationDate: nil, fileSizeBytes: nil)
      },
      folderImagesProvider: { _ in [image] }
    )

    state.openExternal(image)
    await waitUntil { !state.isMetadataLoading }

    XCTAssertEqual(
      state.fileMetadata,
      ImageFileMetadata(creationDate: nil, fileSizeBytes: nil)
    )
  }

  func testZeroByteFileSizeIsPreserved() async {
    let image = temporaryFolder.appendingPathComponent("photo.jpg")
    let metadata = ImageFileMetadata(creationDate: nil, fileSizeBytes: 0)
    let state = ApplicationState(
      fileMetadataProvider: { _ in metadata },
      folderImagesProvider: { _ in [image] }
    )

    state.openExternal(image)
    await waitUntil { !state.isMetadataLoading }

    XCTAssertEqual(state.fileMetadata?.fileSizeBytes, 0)
  }

  func testFileMetadataReadsLogicalFileSize() throws {
    let image = temporaryFolder.appendingPathComponent("known-size.jpg")
    try Data(repeating: 7, count: 12_345).write(to: image)

    let metadata = ImageFileMetadata.read(from: image)

    XCTAssertEqual(metadata.fileSizeBytes, 12_345)
  }

  func testUnsupportedOpenClearsMetadataAndPhotoPosition() async {
    let image = temporaryFolder.appendingPathComponent("photo.jpg")
    let unsupported = temporaryFolder.appendingPathComponent("notes.txt")
    let metadata = ImageFileMetadata(
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      fileSizeBytes: 42
    )
    let state = ApplicationState(
      fileMetadataProvider: { _ in metadata },
      folderImagesProvider: { _ in [image] }
    )

    state.openExternal(image)
    await waitUntil { state.fileMetadata == metadata }
    await waitUntil { state.hasEnumeratedFolder }
    XCTAssertNotNil(state.photoPosition)

    state.openExternal(unsupported)

    XCTAssertNil(state.fileMetadata)
    XCTAssertFalse(state.isMetadataLoading)
    XCTAssertNil(state.photoPosition)
  }

  func testZoomControlsSnapToFivePercentAndClampToManualRange() {
    let state = ApplicationState()
    state.openExternal(temporaryFolder.appendingPathComponent("photo.jpg"))
    state.effectiveFitPercentage = 67.7

    XCTAssertEqual(state.sliderValue(), 70)

    state.adjustZoom(by: 1)
    XCTAssertEqual(state.zoomMode, .manual(75))

    state.fitToWindow()
    state.adjustZoom(by: -1)
    XCTAssertEqual(state.zoomMode, .manual(65))

    state.setManualZoom(200)
    state.adjustZoom(by: 1)
    XCTAssertEqual(state.zoomMode, .manual(200))

    state.setManualZoom(20)
    state.adjustZoom(by: -1)
    XCTAssertEqual(state.zoomMode, .manual(20))
  }

  func testKeyboardZoomDoesNothingWithoutAnImage() {
    let state = ApplicationState()
    state.adjustZoom(by: 1)
    state.adjustZoom(by: -1)
    XCTAssertEqual(state.zoomMode, .fit)
  }

  func testZoomButtonsMoveIntoManualRangeFromOutOfRangeFit() {
    let image = temporaryFolder.appendingPathComponent("photo.jpg")
    let state = ApplicationState(folderImagesProvider: { _ in [image] })
    state.openExternal(image)

    state.effectiveFitPercentage = 12
    XCTAssertFalse(state.canAdjustZoom(by: -1))
    XCTAssertTrue(state.canAdjustZoom(by: 1))
    state.adjustZoom(by: 1)
    XCTAssertEqual(state.zoomMode, .manual(25))

    state.fitToWindow()
    state.effectiveFitPercentage = 207
    XCTAssertTrue(state.canAdjustZoom(by: -1))
    XCTAssertFalse(state.canAdjustZoom(by: 1))
    state.adjustZoom(by: -1)
    XCTAssertEqual(state.zoomMode, .manual(195))
  }

  func testCachedNavigationAndPositionDoNotRescanFolder() async {
    let urls = (1...50).map { temporaryFolder.appendingPathComponent("photo\($0).jpg") }
    let scans = LockedCounter()
    let state = ApplicationState(folderImagesProvider: { _ in
      _ = scans.increment()
      return urls
    })
    state.openExternal(urls[0])
    await waitUntil { state.hasEnumeratedFolder }
    for _ in 0..<20 {
      state.navigate(by: 1)
      _ = state.photoPosition
      state.setManualZoom(75)
    }
    XCTAssertEqual(state.currentURL, urls[20])
    XCTAssertEqual(state.photoPosition, .init(number: 21, total: 50))
    XCTAssertEqual(scans.get(), 1)
    XCTAssertEqual(state.zoomMode, .manual(75))
  }

  func testSlowFolderScanDoesNotBlockOpenAndSupersededResultIsIgnored() async {
    let first = temporaryFolder.appendingPathComponent("old/photo1.jpg")
    let second = temporaryFolder.appendingPathComponent("new/photo2.jpg")
    let started = LockedFlag()
    let releaseScan = DispatchSemaphore(value: 0)
    let state = ApplicationState(folderImagesProvider: { folder in
      if folder.lastPathComponent == "old" {
        started.set()
        _ = releaseScan.wait(timeout: .now() + 2)
        return [first]
      }
      return [second]
    })
    state.openExternal(first)
    XCTAssertEqual(state.currentURL, first)
    await waitUntil { started.get() }
    state.openExternal(second)
    await waitUntil { state.hasEnumeratedFolder }
    releaseScan.signal()
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(state.currentURL, second)
    XCTAssertEqual(state.folderImages, [second])
    XCTAssertEqual(state.zoomMode, .fit)
  }

  func testResolutionUpgradeKeepsOriginalZoomDimensionsAndPreview() async throws {
    let url = temporaryFolder.appendingPathComponent("large.png")
    try Data([0]).write(to: url)
    let upgradeStarted = LockedFlag()
    let releaseUpgrade = DispatchSemaphore(value: 0)
    let pipeline = ImagePipeline(loader: { _, maximum in
      if maximum == nil {
        upgradeStarted.set()
        _ = releaseUpgrade.wait(timeout: .now() + 2)
      }
      let width = min(maximum ?? 4000, 4000)
      let context = CGContext(
        data: nil, width: width, height: width / 2,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      return LoadedImage(
        cgImage: context.makeImage()!, pixelSize: CGSize(width: 4000, height: 2000))
    })
    let state = ApplicationState(folderImagesProvider: { _ in [url] }, imagePipeline: pipeline)
    state.updateViewport(size: CGSize(width: 600, height: 400), backingScale: 2)
    state.openExternal(url)
    await waitUntil {
      if case .loaded = state.loadState { return true }
      return false
    }
    if case .loaded(let preview) = state.loadState {
      XCTAssertEqual(preview.pixelSize.width, 4000)
      XCTAssertLessThan(preview.cgImage.width, 4000)
    }
    state.setManualZoom(100)
    await waitUntil { upgradeStarted.get() }
    if case .loaded(let preview) = state.loadState {
      XCTAssertLessThan(preview.cgImage.width, 4000)
    } else {
      XCTFail("The preview disappeared during the resolution upgrade")
    }
    releaseUpgrade.signal()
    await waitUntil {
      if case .loaded(let image) = state.loadState { return image.cgImage.width == 4000 }
      return false
    }
    XCTAssertEqual(state.zoomMode, .manual(100))
  }

  func testMissingImageDuringResolutionUpgradeShowsErrorAndKeepsNavigation() async throws {
    let first = temporaryFolder.appendingPathComponent("photo1.png")
    let second = temporaryFolder.appendingPathComponent("photo2.png")
    try createFiles(named: ["photo1.png", "photo2.png"])
    let pipeline = ImagePipeline(loader: { _, maximum in
      guard maximum != nil else { throw ImageLoadError.unavailable }
      let context = CGContext(
        data: nil, width: 32, height: 16,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      return LoadedImage(
        cgImage: context.makeImage()!, pixelSize: CGSize(width: 4000, height: 2000))
    })
    let state = ApplicationState(
      folderImagesProvider: { _ in [first, second] }, imagePipeline: pipeline)
    state.openExternal(first)
    await waitUntil {
      if case .loaded = state.loadState { return state.hasEnumeratedFolder }
      return false
    }
    state.setManualZoom(100)
    await waitUntil {
      if case .failed = state.loadState { return true }
      return false
    }
    state.navigate(by: 1)
    XCTAssertEqual(state.currentURL, second)
  }

  func testFolderAuthorizationOpensSelectedImageImmediatelyThenEnablesSiblings() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let second = temporaryFolder.appendingPathComponent("photo2.jpg")
    let allowed = LockedFlag()
    let authorization = TestFolderAccess()
    authorization.requestedLease = SecurityScopeLease(url: temporaryFolder) {}
    authorization.onRequest = { allowed.set() }
    let state = ApplicationState(
      folderImagesProvider: { _ in allowed.get() ? [first, second] : nil },
      folderAccess: authorization
    )

    state.openExternal(first)
    XCTAssertEqual(state.currentURL, first)
    await waitUntil { state.hasEnumeratedFolder }

    XCTAssertEqual(authorization.restoreCount, 1)
    XCTAssertEqual(authorization.requestCount, 1)
    XCTAssertEqual(authorization.requestedFolders, [temporaryFolder])
    state.navigate(by: 1)
    XCTAssertEqual(state.currentURL, second)
    XCTAssertNil(state.navigationNotice)
  }

  func testExplicitFitRecoversFromFullResolutionLimitWithoutAutomaticRetryLoop() async throws {
    let imageURL = temporaryFolder.appendingPathComponent("large.png")
    try Data([0]).write(to: imageURL)
    let attempts = LockedCounter()
    let pipeline = ImagePipeline(loader: { _, maximum in
      _ = attempts.increment()
      guard maximum != nil else { throw ImageLoadError.exceedsSafetyLimits }
      let context = CGContext(
        data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      return LoadedImage(
        cgImage: context.makeImage()!, pixelSize: CGSize(width: 10_000, height: 5_000))
    })
    let state = ApplicationState(
      folderImagesProvider: { _ in [imageURL] }, imagePipeline: pipeline)
    state.openExternal(imageURL)
    await waitUntil {
      if case .loaded = state.loadState { return true }
      return false
    }
    state.setManualZoom(100)
    await waitUntil {
      if case .failed = state.loadState { return true }
      return false
    }
    let attemptsAfterFailure = attempts.get()
    state.updateViewport(size: CGSize(width: 500, height: 350), backingScale: 2)
    try? await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(attempts.get(), attemptsAfterFailure)

    state.fitToWindow()
    await waitUntil {
      if case .loaded = state.loadState { return true }
      return false
    }
    XCTAssertEqual(state.zoomMode, .fit)
    XCTAssertEqual(state.currentURL, imageURL)
  }

  func testDeclinedFolderAuthorizationDoesNotRepromptOnNavigationOrRefresh() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let authorization = TestFolderAccess()
    let state = ApplicationState(folderImagesProvider: { _ in nil }, folderAccess: authorization)

    state.openExternal(first)
    await waitUntil { authorization.requestCount == 1 && state.navigationNotice != nil }
    for _ in 0..<5 {
      state.navigate(by: 1)
      state.refreshCatalog()
      try? await Task.sleep(for: .milliseconds(15))
    }
    XCTAssertEqual(state.currentURL, first)
    XCTAssertEqual(authorization.requestCount, 1)
    XCTAssertTrue(state.navigationNotice?.contains("Reopen") == true)

    state.openExternal(first)
    await waitUntil { authorization.requestCount == 2 }
    XCTAssertEqual(state.currentURL, first)
  }

  func testRestoredFolderScopeDoesNotPrompt() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let authorization = TestFolderAccess()
    authorization.restoredLease = SecurityScopeLease(url: temporaryFolder) {}
    let state = ApplicationState(
      folderImagesProvider: { _ in [first] }, folderAccess: authorization)

    state.openExternal(first)
    await waitUntil { state.hasEnumeratedFolder }
    XCTAssertEqual(authorization.restoreCount, 1)
    XCTAssertEqual(authorization.requestCount, 0)
  }

  func testLaterFolderFailureDoesNotTriggerAnUnsolicitedAuthorizationPrompt() async {
    let first = temporaryFolder.appendingPathComponent("photo1.jpg")
    let scans = LockedCounter()
    let authorization = TestFolderAccess()
    let state = ApplicationState(
      folderImagesProvider: { _ in scans.increment() == 1 ? [first] : nil },
      folderAccess: authorization
    )

    state.openExternal(first)
    await waitUntil { state.hasEnumeratedFolder }
    state.refreshCatalog()
    await waitUntil { state.navigationNotice != nil }
    XCTAssertEqual(authorization.requestCount, 0)
  }

  func testSupersededFolderGrantCannotReplaceNewFolderAndIsReleased() async {
    let oldFolder = temporaryFolder.appendingPathComponent("old", isDirectory: true)
    let oldImage = oldFolder.appendingPathComponent("photo1.jpg")
    let newImage = temporaryFolder.appendingPathComponent("new/photo2.jpg")
    let releasedScopes = LockedCounter()
    let authorization = TestFolderAccess()
    authorization.suspendRequests = true
    let state = ApplicationState(
      folderImagesProvider: { folder in folder == oldFolder ? nil : [newImage] },
      folderAccess: authorization
    )

    state.openExternal(oldImage)
    await waitUntil { authorization.pendingRequest != nil }
    state.openExternal(newImage)
    await waitUntil { state.hasEnumeratedFolder }
    authorization.pendingRequest?.resume(
      returning: SecurityScopeLease(url: oldFolder) { _ = releasedScopes.increment() })
    authorization.pendingRequest = nil
    await waitUntil { releasedScopes.get() == 1 }

    XCTAssertEqual(state.currentURL, newImage)
    XCTAssertEqual(state.folderImages, [newImage])
    XCTAssertEqual(authorization.requestCount, 1)
  }

  func testUntrustedURLOpenNeverRequestsFolderOrReadsMetadata() async {
    let metadataReads = LockedCounter()
    let folderReads = LockedCounter()
    let authorization = TestFolderAccess()
    let state = ApplicationState(
      fileMetadataProvider: { _ in
        _ = metadataReads.increment()
        return ImageFileMetadata(creationDate: nil, fileSizeBytes: nil)
      },
      folderImagesProvider: { _ in
        _ = folderReads.increment()
        return []
      },
      folderAccess: authorization
    )

    for rawURL in [
      "https://example.invalid/photo.jpg",
      "file:relative.jpg",
      "file://example.invalid/photo.jpg",
      "file://user@localhost/tmp/photo.jpg",
      "file:///tmp/photo%00.jpg",
    ] {
      state.openExternal(URL(string: rawURL)!)
      try? await Task.sleep(for: .milliseconds(20))
      XCTAssertNil(state.currentURL, rawURL)
      if case .failed = state.loadState {} else { XCTFail("An untrusted URL must be rejected") }
    }
    XCTAssertEqual(metadataReads.get(), 0)
    XCTAssertEqual(folderReads.get(), 0)
    XCTAssertEqual(authorization.restoreCount, 0)
    XCTAssertEqual(authorization.requestCount, 0)
  }

  func testSecurityScopeStopsOnlyAfterAllOwnersReleaseSuccessfulStart() {
    let starts = LockedCounter()
    let stops = LockedCounter()
    var owner = SecurityScopeLease.acquire(
      temporaryFolder,
      start: { _ in
        _ = starts.increment()
        return true
      },
      stop: { _ in _ = stops.increment() }
    )
    var worker = owner
    XCTAssertNotNil(worker)
    owner = nil
    XCTAssertEqual(starts.get(), 1)
    XCTAssertEqual(stops.get(), 0)
    worker = nil
    XCTAssertEqual(stops.get(), 1)
  }

  func testFailedSecurityScopeStartDoesNotStopAnUnownedScope() {
    let stops = LockedCounter()
    let lease = SecurityScopeLease.acquire(
      temporaryFolder, start: { _ in false }, stop: { _ in _ = stops.increment() })
    XCTAssertNil(lease)
    XCTAssertEqual(stops.get(), 0)
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not met before the timeout.", file: file, line: line)
  }

  private func createFiles(named filenames: [String]) throws {
    for name in filenames {
      try Data([0]).write(to: temporaryFolder.appendingPathComponent(name))
    }
  }
}

@MainActor
private final class TestFolderAccess: FolderAccessAuthorizing {
  var restoredLease: SecurityScopeLease?
  var requestedLease: SecurityScopeLease?
  var onRequest: (() -> Void)?
  var suspendRequests = false
  var pendingRequest: CheckedContinuation<SecurityScopeLease?, Never>?
  private(set) var restoreCount = 0
  private(set) var requestCount = 0
  private(set) var requestedFolders: [URL] = []

  func restoreAccess(to folder: URL) async -> SecurityScopeLease? {
    restoreCount += 1
    return restoredLease
  }

  func requestAccess(to folder: URL) async -> SecurityScopeLease? {
    requestCount += 1
    requestedFolders.append(folder)
    onRequest?()
    if suspendRequests {
      return await withCheckedContinuation { pendingRequest = $0 }
    }
    return requestedLease
  }

  func cancelRequest() {
    // The superseded-result test deliberately completes its old callback late.
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }

  func get() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

extension Array where Element == String {
  fileprivate func sortedNaturally() -> [String] {
    sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }
}
