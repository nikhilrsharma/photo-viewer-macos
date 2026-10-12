import AppKit

/// Ownership of one security-scope grant. Worker requests retain their leases
/// until file access has actually finished, even when their UI task is cancelled.
final class SecurityScopeLease: @unchecked Sendable {
  let url: URL
  private let release: @Sendable () -> Void

  init(url: URL, release: @escaping @Sendable () -> Void) {
    self.url = url
    self.release = release
  }

  static func acquire(
    _ url: URL,
    start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
    stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
  ) -> SecurityScopeLease? {
    guard ImageInputValidation.isLocalFileURL(url), start(url) else { return nil }
    return SecurityScopeLease(url: url) { stop(url) }
  }

  /// Open-panel and Finder/drop handoffs already carry an implicit grant from
  /// macOS. Adopt that grant instead of starting it a second time.
  static func adoptingImplicitAccess(_ url: URL) -> SecurityScopeLease {
    SecurityScopeLease(url: url) { url.stopAccessingSecurityScopedResource() }
  }

  deinit {
    release()
  }
}

@MainActor
protocol FolderAccessAuthorizing: AnyObject {
  func restoreAccess(to folder: URL) async -> SecurityScopeLease?
  func requestAccess(to folder: URL) async -> SecurityScopeLease?
  func cancelRequest()
}

@MainActor
final class SandboxFolderAccess: NSObject, FolderAccessAuthorizing {
  private struct RestoredAccess: Sendable {
    let lease: SecurityScopeLease
    let refreshedBookmark: Data?
  }

  private let defaults: UserDefaults
  private let presentingWindow: @MainActor () -> NSWindow?
  private let bookmarkKey = "PhotoViewer.ReadOnlyFolderBookmarks"
  private let maximumSavedFolders = 32
  private var panel: NSOpenPanel?
  private var requestGeneration = UUID()

  init(
    defaults: UserDefaults = .standard,
    presentingWindow: @escaping @MainActor () -> NSWindow?
  ) {
    self.defaults = defaults
    self.presentingWindow = presentingWindow
  }

  func restoreAccess(to folder: URL) async -> SecurityScopeLease? {
    guard ImageInputValidation.isLocalFileURL(folder),
      let data = savedBookmarks[folder.standardizedFileURL.path]
    else { return nil }
    let restored = await Task.detached(priority: .utility) { () -> RestoredAccess? in
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope, .withoutUI],
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        guard let lease = SecurityScopeLease.acquire(url),
          Self.sameFolder(url, folder)
        else { return nil }
        let refreshed = stale ? try? Self.readOnlyBookmark(for: url) : nil
        return RestoredAccess(lease: lease, refreshedBookmark: refreshed)
      } catch {
        return nil
      }
    }.value
    guard !Task.isCancelled else { return nil }
    if let refreshed = restored?.refreshedBookmark {
      save(refreshed, for: folder)
    } else if restored == nil {
      var bookmarks = savedBookmarks
      bookmarks.removeValue(forKey: folder.standardizedFileURL.path)
      defaults.set(bookmarks, forKey: bookmarkKey)
    }
    return restored?.lease
  }

  func requestAccess(to folder: URL) async -> SecurityScopeLease? {
    guard ImageInputValidation.isLocalFileURL(folder), !Task.isCancelled, panel == nil else {
      return nil
    }
    let generation = UUID()
    requestGeneration = generation
    let chooser = NSOpenPanel()
    chooser.title = "Allow Photo Folder Access"
    chooser.message =
      "Select “\(folder.lastPathComponent)” to browse its images. Photo Viewer can only read the files in this folder."
    chooser.prompt = "Allow Read-Only Access"
    chooser.canChooseDirectories = true
    chooser.canChooseFiles = false
    chooser.canCreateDirectories = false
    chooser.allowsMultipleSelection = false
    chooser.directoryURL = folder
    chooser.resolvesAliases = true
    panel = chooser

    let response = await withCheckedContinuation { continuation in
      let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
        continuation.resume(returning: response)
      }
      if let window = presentingWindow() {
        chooser.beginSheetModal(for: window, completionHandler: completion)
      } else {
        chooser.begin(completionHandler: completion)
      }
    }
    if requestGeneration == generation { panel = nil }
    guard response == .OK, let selectedFolder = chooser.url else { return nil }
    let lease = SecurityScopeLease.adoptingImplicitAccess(selectedFolder)
    guard !Task.isCancelled, requestGeneration == generation else { return nil }

    let selection = await Task.detached(priority: .utility) { () -> (Bool, Data?) in
      withExtendedLifetime(lease) {
        guard Self.sameFolder(selectedFolder, folder) else { return (false, nil) }
        return (true, try? Self.readOnlyBookmark(for: selectedFolder))
      }
    }.value
    guard !Task.isCancelled, requestGeneration == generation else { return nil }
    // A different folder would grant a wider or unrelated scope. Do not retain it.
    guard selection.0 else { return nil }
    if let bookmark = selection.1 { save(bookmark, for: folder) }
    return lease
  }

  func cancelRequest() {
    requestGeneration = UUID()
    panel?.cancel(nil)
    panel = nil
  }

  private var savedBookmarks: [String: Data] {
    defaults.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
  }

  private func save(_ data: Data, for folder: URL) {
    let path = folder.standardizedFileURL.path
    var bookmarks = savedBookmarks
    if bookmarks[path] == nil, bookmarks.count >= maximumSavedFolders,
      let evictedKey = bookmarks.keys.sorted().first
    {
      bookmarks.removeValue(forKey: evictedKey)
    }
    bookmarks[path] = data
    defaults.set(bookmarks, forKey: bookmarkKey)
  }

  nonisolated private static func readOnlyBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  nonisolated private static func sameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
    guard ImageInputValidation.isLocalFileURL(lhs), ImageInputValidation.isLocalFileURL(rhs) else {
      return false
    }
    return lhs.standardizedFileURL.resolvingSymlinksInPath()
      == rhs.standardizedFileURL.resolvingSymlinksInPath()
  }
}
