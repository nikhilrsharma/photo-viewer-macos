import AppKit
import Combine

struct ImageFileMetadata: Equatable, Sendable {
  let creationDate: Date?
  let fileSizeBytes: Int64?

  static func read(from url: URL) -> ImageFileMetadata {
    let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
    return ImageFileMetadata(
      creationDate: values?.creationDate,
      fileSizeBytes: values?.fileSize.map(Int64.init)
    )
  }
}

@MainActor
final class ApplicationState: ObservableObject {
  struct PhotoPosition: Equatable {
    let number: Int
    let total: Int
  }

  enum LoadState {
    case empty
    case loading
    case loaded(LoadedImage)
    case failed(String)
  }

  @Published private(set) var currentURL: URL?
  @Published private(set) var folderImages: [URL] = []
  @Published private(set) var hasEnumeratedFolder = false
  @Published private(set) var loadState: LoadState = .empty
  @Published private(set) var navigationNotice: String?
  @Published private(set) var fileMetadata: ImageFileMetadata?
  @Published private(set) var isMetadataLoading = false
  @Published private(set) var currentIndex: Int?
  @Published var zoomMode: ZoomMode = .fit
  @Published var effectiveFitPercentage = 100.0

  private var loadingTask: Task<Void, Never>?
  private var metadataTask: Task<Void, Never>?
  private var catalogTask: Task<Void, Never>?
  private var catalogDebounceTask: Task<Void, Never>?
  private var folderWatchTask: Task<Void, Never>?
  private var folderPollTask: Task<Void, Never>?
  private var resolutionTask: Task<Void, Never>?
  private var folderAuthorizationTask: Task<Void, Never>?
  private var loadGeneration = UUID()
  private var catalogGeneration = UUID()
  private var folderURL: URL?
  private var pendingNavigation: [Int] = []
  private var refreshAfterCurrent = false
  private var viewportPixels = CGSize.zero
  private var selectedFileLeases: [SecurityScopeLease] = []
  private var folderLease: SecurityScopeLease?
  private var isRestoringFolderAccess = false
  private var mayOfferFolderAccess = false
  private let folderMonitor = FolderMonitor()
  private let imagePipeline: ImagePipeline
  private let fileMetadataProvider: @Sendable (URL) -> ImageFileMetadata
  private let folderImagesProvider: @Sendable (URL) -> [URL]?
  private let folderAccess: (any FolderAccessAuthorizing)?

  init(
    fileMetadataProvider: @escaping @Sendable (URL) -> ImageFileMetadata = {
      ImageFileMetadata.read(from: $0)
    },
    folderImagesProvider: @escaping @Sendable (URL) -> [URL]? = {
      ImageCatalog.unorderedImagesIfAvailable(in: $0)
    },
    imagePipeline: ImagePipeline = ImagePipeline(),
    folderAccess: (any FolderAccessAuthorizing)? = nil
  ) {
    self.fileMetadataProvider = fileMetadataProvider
    self.folderImagesProvider = folderImagesProvider
    self.imagePipeline = imagePipeline
    self.folderAccess = folderAccess
  }

  deinit {
    loadingTask?.cancel()
    metadataTask?.cancel()
    catalogTask?.cancel()
    catalogDebounceTask?.cancel()
    folderWatchTask?.cancel()
    folderPollTask?.cancel()
    resolutionTask?.cancel()
    folderAuthorizationTask?.cancel()
  }

  var filename: String {
    currentURL?.lastPathComponent ?? AppIdentity.name
  }

  var fullPath: String {
    currentURL?.path ?? "Open an image from Finder"
  }

  var photoPosition: PhotoPosition? {
    guard hasEnumeratedFolder, let currentIndex else { return nil }
    return PhotoPosition(number: currentIndex + 1, total: folderImages.count)
  }

  func openExternal(_ url: URL) {
    openExternal([url])
  }

  func openExternal(_ urls: [URL]) {
    guard !urls.isEmpty else { return }

    catalogGeneration = UUID()
    catalogTask?.cancel()
    catalogTask = nil
    catalogDebounceTask?.cancel()
    folderWatchTask?.cancel()
    folderPollTask?.cancel()
    folderMonitor.stop()
    folderAuthorizationTask?.cancel()
    folderAuthorizationTask = nil
    folderAccess?.cancelRequest()
    selectedFileLeases = []
    folderLease = nil
    isRestoringFolderAccess = false
    mayOfferFolderAccess = false
    pendingNavigation = []
    refreshAfterCurrent = false
    hasEnumeratedFolder = false
    navigationNotice = nil
    folderURL = nil
    zoomMode = .fit

    // Reject remote URLs before deriving filesystem paths or starting any I/O.
    let localURLs = urls.filter(ImageInputValidation.isLocalFileURL)
    let handedOffLeases = Set(localURLs).map(SecurityScopeLease.adoptingImplicitAccess)
    let url = localURLs.first(where: { ImageCatalog.supports($0) }) ?? localURLs.first
    guard let url, ImageCatalog.supports(url) else {
      loadingTask?.cancel()
      metadataTask?.cancel()
      resolutionTask?.cancel()
      loadGeneration = UUID()
      fileMetadata = nil
      isMetadataLoading = false
      currentURL = url
      folderImages = []
      currentIndex = nil
      hasEnumeratedFolder = false
      navigationNotice = nil
      zoomMode = .fit
      loadState = .failed(
        url == nil ? "Only local image files can be opened." : "This file is not a supported image."
      )
      return
    }

    folderURL = url.deletingLastPathComponent()
    selectedFileLeases = handedOffLeases.filter {
      ImageCatalog.supports($0.url) && $0.url.deletingLastPathComponent() == folderURL
    }
    mayOfferFolderAccess = folderAccess != nil

    // The selected image starts loading immediately; directory I/O never blocks it.
    // Finder's other selections remain usable even if directory access is denied.
    folderImages = localURLs.filter {
      ImageCatalog.supports($0) && $0.deletingLastPathComponent() == folderURL
    }.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
    currentIndex = folderImages.firstIndex(of: url)
    load(url)
    prepareFolderAccess()
  }

  func openDropped(_ url: URL) {
    openExternal(url)
  }

  func navigate(by offset: Int) {
    guard offset != 0, currentURL != nil else { return }
    if let index = currentIndex, folderImages.indices.contains(index + offset) {
      pendingNavigation = []
      currentIndex = index + offset
      load(folderImages[index + offset])
      if navigationNotice != nil { refreshCatalog() }
    } else {
      // A boundary/retry refresh also discovers files added just before the key press.
      pendingNavigation.append(offset)
      if pendingNavigation.count > 256 { pendingNavigation.removeFirst() }
      refreshCatalog()
    }
  }

  func setManualZoom(_ value: Double) {
    zoomMode = .manual(ZoomPolicy.normalized(value))
    scheduleResolutionUpdate()
  }

  func fitToWindow() {
    zoomMode = .fit
    if case .failed = loadState, let url = currentURL, ImageCatalog.supports(url) {
      // An explicit Fit action can recover from a full-resolution safety limit.
      // Automatic resize updates still leave failed loads alone.
      resolutionTask?.cancel()
      loadImage(url, preservePreview: false)
    } else {
      scheduleResolutionUpdate()
    }
  }

  func adjustZoom(by increments: Int) {
    guard currentURL != nil, increments != 0 else { return }
    setManualZoom(ZoomPolicy.stepped(from: sliderValue(), by: increments))
  }

  func canAdjustZoom(by increments: Int) -> Bool {
    guard currentURL != nil, increments != 0 else { return false }
    let percentage = sliderValue()
    return increments > 0 ? percentage < ZoomPolicy.maximum : percentage > ZoomPolicy.minimum
  }

  func sliderValue() -> Double {
    switch zoomMode {
    case .fit:
      return ZoomPolicy.normalized(effectiveFitPercentage)
    case .manual(let percentage):
      return percentage
    }
  }

  /// Directory scans and path canonicalization run away from the interface thread.
  func refreshCatalog() {
    guard let folder = folderURL, let selectedURL = currentURL,
      ImageCatalog.supports(selectedURL), catalogTask == nil, !isRestoringFolderAccess
    else { return }
    let generation = catalogGeneration
    let provider = folderImagesProvider
    let accessLeases = resourceAccessLeases
    catalogTask = Task { [weak self] in
      let worker = Task.detached(priority: .utility) { () -> FolderSnapshot? in
        defer { withExtendedLifetime(accessLeases) {} }
        guard !Task.isCancelled, let urls = provider(folder), !Task.isCancelled else { return nil }
        return FolderSnapshot(urls: urls + [selectedURL])
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled, let self, self.catalogGeneration == generation else { return }
      self.catalogTask = nil
      if let result, let current = self.currentURL {
        self.mayOfferFolderAccess = false
        if let index = result.index(for: current) {
          if self.folderImages != result.urls { self.folderImages = result.urls }
          if self.currentIndex != index { self.currentIndex = index }
          if !self.hasEnumeratedFolder { self.hasEnumeratedFolder = true }
          if self.navigationNotice != nil { self.navigationNotice = nil }
        } else {
          // The selected file vanished while browsing during a scan; retain its
          // position for this refresh and include it in the next snapshot.
          self.refreshAfterCurrent = true
        }
      } else {
        self.navigationNotice =
          "Photo Viewer can’t read this folder to find nearby images. Reopen this image from Finder to allow access to its containing folder."
        self.offerFolderAccessIfNeeded(to: folder, generation: generation)
      }
      let offsets = self.pendingNavigation
      self.pendingNavigation = []
      if !offsets.isEmpty, let index = self.currentIndex, !self.folderImages.isEmpty {
        let target = offsets.reduce(index) { max(0, min(self.folderImages.count - 1, $0 + $1)) }
        if target != index {
          self.currentIndex = target
          self.load(self.folderImages[target])
        }
      }
      if self.refreshAfterCurrent {
        self.refreshAfterCurrent = false
        self.refreshCatalog()
      }
    }
  }

  private var resourceAccessLeases: [SecurityScopeLease] {
    selectedFileLeases + (folderLease.map { [$0] } ?? [])
  }

  private func prepareFolderAccess() {
    guard let folder = folderURL else { return }
    guard let folderAccess else {
      startFolderObservation()
      refreshCatalog()
      return
    }
    isRestoringFolderAccess = true
    let generation = catalogGeneration
    folderAuthorizationTask = Task { [weak self] in
      let lease = await folderAccess.restoreAccess(to: folder)
      guard !Task.isCancelled, let self, self.catalogGeneration == generation else { return }
      self.folderAuthorizationTask = nil
      self.folderLease = lease
      if lease != nil { self.selectedFileLeases = [] }
      self.isRestoringFolderAccess = false
      self.startFolderObservation()
      self.refreshCatalog()
    }
  }

  private func offerFolderAccessIfNeeded(to folder: URL, generation: UUID) {
    guard mayOfferFolderAccess, let folderAccess, folderAuthorizationTask == nil else { return }
    // Only a fresh external open permits a prompt. Navigation and polling never
    // reopen a declined sheet; the user can retry by opening the image again.
    mayOfferFolderAccess = false
    folderAuthorizationTask = Task { [weak self] in
      let lease = await folderAccess.requestAccess(to: folder)
      guard !Task.isCancelled, let self, self.catalogGeneration == generation else { return }
      self.folderAuthorizationTask = nil
      guard let lease else {
        self.navigationNotice =
          "Folder access wasn’t granted. Reopen this image from Finder to select its containing folder and try again."
        return
      }
      self.folderLease = lease
      self.selectedFileLeases = []
      self.navigationNotice = nil
      self.startFolderObservation()
      if let url = self.currentURL, case .failed = self.loadState { self.load(url) }
      self.refreshCatalog()
    }
  }

  private func startFolderObservation() {
    guard let folderURL else { return }
    folderWatchTask?.cancel()
    folderPollTask?.cancel()
    let monitor = folderMonitor
    let accessLeases = resourceAccessLeases
    folderWatchTask = Task { [weak self] in
      defer { withExtendedLifetime(accessLeases) {} }
      guard !Task.isCancelled else { return }
      await monitor.watch(folderURL) { [weak self] in
        guard !Task.isCancelled, let self else { return }
        self.catalogDebounceTask?.cancel()
        self.catalogDebounceTask = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(150))
          guard !Task.isCancelled, let self else { return }
          if self.catalogTask != nil {
            self.refreshAfterCurrent = true
          } else {
            self.refreshCatalog()
          }
        }
      }
    }
    // File providers/network mounts do not always deliver filesystem events.
    // A modest foreground-only fallback also recovers newly granted folder access.
    folderPollTask = Task { [weak self] in
      defer { withExtendedLifetime(accessLeases) {} }
      var previousModification: Date?
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        if NSApp?.isActive == true, NSApp?.keyWindow != nil {
          let modification = await Task.detached(priority: .utility) {
            (try? FileManager.default.attributesOfItem(atPath: folderURL.path))?[.modificationDate]
              as? Date
          }.value
          guard !Task.isCancelled else { return }
          if modification != previousModification || self?.navigationNotice != nil {
            self?.refreshCatalog()
          }
          previousModification = modification
        }
      }
    }
  }

  func updateViewport(size: CGSize, backingScale: CGFloat) {
    let pixels = CGSize(width: size.width * backingScale, height: size.height * backingScale)
    guard pixels.width > 0, pixels.height > 0, pixels != viewportPixels else { return }
    viewportPixels = pixels
    if zoomMode == .fit { scheduleResolutionUpdate() }
  }

  private var requestedPixelSize: Int? {
    guard zoomMode == .fit else { return nil }
    let screen = NSScreen.main
    let scale = screen?.backingScaleFactor ?? 2
    let size =
      viewportPixels == .zero
      ? CGSize(
        width: (screen?.visibleFrame.width ?? 1440) * scale,
        height: (screen?.visibleFrame.height ?? 900) * scale)
      : viewportPixels
    // Small buckets avoid decoding again for every point of a live resize.
    return max(256, Int(ceil(max(size.width, size.height) / 256)) * 256)
  }

  private func scheduleResolutionUpdate() {
    resolutionTask?.cancel()
    resolutionTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled, let self, let url = self.currentURL else { return }
      if case .loaded(let image) = self.loadState {
        let decoded = max(image.cgImage.width, image.cgImage.height)
        let original = Int(max(image.pixelSize.width, image.pixelSize.height))
        if decoded >= min(self.requestedPixelSize ?? original, original) { return }
      } else if case .failed = self.loadState {
        return
      }
      self.loadImage(url, preservePreview: true)
    }
  }

  private func load(_ url: URL) {
    resolutionTask?.cancel()
    metadataTask?.cancel()
    fileMetadata = nil
    isMetadataLoading = true
    currentURL = url
    let metadataProvider = fileMetadataProvider
    let accessLeases = resourceAccessLeases
    metadataTask = Task { [weak self] in
      let metadata = await Task.detached(priority: .utility) {
        withExtendedLifetime(accessLeases) { metadataProvider(url) }
      }.value
      guard !Task.isCancelled, let self, self.currentURL == url else { return }
      self.fileMetadata = metadata
      self.isMetadataLoading = false
    }
    loadImage(url, preservePreview: false)
  }

  private func loadImage(_ url: URL, preservePreview: Bool) {
    loadingTask?.cancel()
    let generation = UUID()
    loadGeneration = generation
    let hasPreview: Bool
    if preservePreview, case .loaded = loadState { hasPreview = true } else { hasPreview = false }
    if !hasPreview { loadState = .loading }
    let pipeline = imagePipeline
    let maximumPixelSize = requestedPixelSize
    let accessLeases = resourceAccessLeases
    loadingTask = Task { [weak self] in
      do {
        let image = try await pipeline.load(
          url: url, maximumPixelSize: maximumPixelSize, accessLeases: accessLeases)
        guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
        self.loadState = .loaded(image)
      } catch is CancellationError {
        // A newer selected image/resolution owns the UI now.
      } catch {
        guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
        self.loadState = .failed(error.localizedDescription)
      }
    }
  }
}
