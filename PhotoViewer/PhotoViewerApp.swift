import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private lazy var folderAccess = SandboxFolderAccess(presentingWindow: { [weak self] in
    self?.window
  })
  private lazy var state = ApplicationState(folderAccess: folderAccess)
  private var window: NavigationWindow!
  private var hostingView: NSView!
  private var subscriptions: Set<AnyCancellable> = []
  private let aboutPanelController = AboutPanelController()

  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
      application.run()
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    buildMainMenu()
    buildWindow()
    observeWindowTitle()

    window.makeKeyAndOrderFront(nil)
    focusViewer()
    NSApp.activate(ignoringOtherApps: true)
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard !urls.isEmpty else { return }
    ensureWindowVisible()
    state.openExternal(urls)
    focusViewer()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    ensureWindowVisible()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    folderAccess.cancelRequest()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    state.refreshCatalog()
  }

  private func buildWindow() {
    window = NavigationWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Photo Viewer"
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 640, height: 480)
    window.collectionBehavior.insert(.fullScreenNone)
    let hostingView = FocusableHostingView(rootView: ContentView(state: state))
    self.hostingView = hostingView
    window.contentView = hostingView
    window.initialFirstResponder = hostingView
    window.onNavigate = { [weak self] offset in
      self?.state.navigate(by: offset)
    }

    let frameName = "PhotoViewer.MainWindow"
    window.setFrameAutosaveName(frameName)
    if !window.setFrameUsingName(frameName) {
      let visibleFrame =
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
      let size = NSSize(
        width: max(640, visibleFrame.width * 0.9),
        height: max(480, visibleFrame.height * 0.9)
      )
      window.setFrame(
        NSRect(
          x: visibleFrame.midX - size.width / 2,
          y: visibleFrame.midY - size.height / 2,
          width: size.width,
          height: size.height
        ),
        display: false
      )
    }

    if let zoomButton = window.standardWindowButton(.zoomButton) {
      zoomButton.target = window
      zoomButton.action = #selector(NSWindow.performZoom(_:))
    }
  }

  private func ensureWindowVisible() {
    guard window != nil else { return }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    focusViewer()
    NSApp.activate(ignoringOtherApps: true)
  }

  private func focusViewer() {
    guard window != nil, hostingView != nil else { return }
    window.makeFirstResponder(hostingView)
  }

  private func observeWindowTitle() {
    state.$currentURL
      .sink { [weak self] url in
        self?.window?.title = url?.lastPathComponent ?? "Photo Viewer"
      }
      .store(in: &subscriptions)
  }

  private func buildMainMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem(title: "Photo Viewer", action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: "Photo Viewer")
    let aboutItem = NSMenuItem(
      title: "About Photo Viewer", action: #selector(showAbout(_:)), keyEquivalent: "")
    aboutItem.target = self
    appMenu.addItem(aboutItem)
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Hide Photo Viewer",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Photo Viewer",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Close",
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
    windowMenu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    windowMenu.addItem(
      withTitle: "Zoom",
      action: #selector(NSWindow.performZoom(_:)),
      keyEquivalent: ""
    )
    windowMenu.addItem(.separator())
    windowMenu.addItem(
      withTitle: "Bring All to Front",
      action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: ""
    )
    windowItem.submenu = windowMenu
    mainMenu.addItem(windowItem)
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }

  @objc private func showAbout(_ sender: Any?) {
    aboutPanelController.show()
  }
}

struct AppAboutInfo {
  static let creator = "Nikhil Sharma"
  static let aiCredit = "Created with assistance from Codex, OpenAI’s AI coding assistant."

  static func formattedBuildDate(_ rawDate: String?) -> String {
    guard let text = rawDate?.trimmingCharacters(in: .whitespacesAndNewlines),
      text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    else { return "Unavailable" }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
      return "Unavailable"
    }
    formatter.dateFormat = "d MMMM yyyy"
    return formatter.string(from: date)
  }

  static func buildDate(in bundle: Bundle = .main) -> String {
    let text = bundle.url(forResource: "BuildDate", withExtension: "txt")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    return formattedBuildDate(text)
  }
}

@MainActor
final class AboutPanelController {
  private(set) var panel: NSPanel?

  func show() {
    if panel == nil {
      let newPanel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      newPanel.title = "About Photo Viewer"
      newPanel.isReleasedWhenClosed = false
      newPanel.hidesOnDeactivate = false
      newPanel.isExcludedFromWindowsMenu = true
      newPanel.collectionBehavior.insert(.fullScreenNone)
      newPanel.contentView = NSHostingView(rootView: AboutView(buildDate: AppAboutInfo.buildDate()))
      newPanel.center()
      panel = newPanel
    }
    panel?.makeKeyAndOrderFront(nil)
  }
}

private struct AboutView: View {
  let buildDate: String

  var body: some View {
    VStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
      Text("Photo Viewer")
        .font(.system(size: 22, weight: .semibold))
      Text("Created by \(AppAboutInfo.creator)")
        .font(.system(size: 14, weight: .medium))
      Text(AppAboutInfo.aiCredit)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      Text("Last updated: \(buildDate)")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .padding(28)
    .frame(width: 420, height: 300)
  }
}

final class FocusableHostingView<Content: View>: NSHostingView<Content> {
  override var acceptsFirstResponder: Bool { true }
}

final class NavigationWindow: NSWindow {
  var onNavigate: ((Int) -> Void)?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown,
      let direction = Self.navigationDirection(for: event, firstResponder: firstResponder)
    {
      onNavigate?(direction)
      return
    }

    super.sendEvent(event)
  }

  static func navigationDirection(for event: NSEvent, firstResponder: NSResponder?) -> Int? {
    if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
      return nil
    }

    let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
    guard event.modifierFlags.intersection(blockedModifiers).isEmpty else { return nil }

    switch event.keyCode {
    case 123:
      return -1
    case 124:
      return 1
    default:
      return nil
    }
  }
}
