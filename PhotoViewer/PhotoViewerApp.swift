import AppKit
import SwiftUI

enum AppIdentity {
  static let name = "Nik's Photo Viewer"
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private lazy var folderAccess = SandboxFolderAccess(presentingWindow: { [weak self] in
    self?.window
  })
  private lazy var state = ApplicationState(folderAccess: folderAccess)
  private var window: NavigationWindow!
  private var hostingView: NSView!
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
    AppTitlebar.install(on: window)
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 640, height: 480)
    AppWindowControls.configure(window)
    let hostingView = FocusableHostingView(rootView: ContentView(state: state))
    self.hostingView = hostingView
    window.contentView = hostingView
    window.initialFirstResponder = hostingView
    window.onNavigate = { [weak self] offset in
      self?.state.navigate(by: offset)
    }
    window.onZoom = { [weak self] offset in
      self?.state.adjustZoom(by: offset)
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

  private func buildMainMenu() {
    NSApp.windowsMenu = nil
    NSApp.mainMenu = AppMenu.make(aboutTarget: self, aboutAction: #selector(showAbout(_:)))
  }

  @objc private func showAbout(_ sender: Any?) {
    aboutPanelController.show()
  }
}

@MainActor
enum AppMenu {
  static func make(aboutTarget: AnyObject?, aboutAction: Selector) -> NSMenu {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem(title: AppIdentity.name, action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: AppIdentity.name)
    let aboutItem = NSMenuItem(
      title: "About \(AppIdentity.name)", action: aboutAction, keyEquivalent: "")
    aboutItem.target = aboutTarget
    appMenu.addItem(aboutItem)
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit \(AppIdentity.name)",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    return mainMenu
  }
}

@MainActor
enum AppTitlebar {
  static func install(on window: NSWindow) {
    window.title = AppIdentity.name
    window.titleVisibility = .hidden
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .left
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 165, height: 24))
    let label = NSTextField(labelWithString: AppIdentity.name)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -6)
    ])
    accessory.view = view
    window.addTitlebarAccessoryViewController(accessory)
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
      newPanel.title = "About \(AppIdentity.name)"
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
      Text(AppIdentity.name)
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

@MainActor
enum AppWindowControls {
  static func configure(_ window: NSWindow) {
    window.collectionBehavior.insert(.fullScreenNone)
    if let button = window.standardWindowButton(.zoomButton) {
      button.target = window
      // performZoom simulates clicking this button, so using it as the button's
      // action recurses. zoom performs the actual normal-window resize.
      button.action = #selector(NSWindow.zoom(_:))
    }
  }
}

final class NavigationWindow: NSWindow {
  var onNavigate: ((Int) -> Void)?
  var onZoom: ((Int) -> Void)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Preserve the familiar shortcuts without adding a Window menu.
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "w": performClose(nil); return true
      case "m": performMiniaturize(nil); return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown,
      let direction = Self.zoomDirection(for: event, firstResponder: firstResponder)
    {
      onZoom?(direction)
      return
    }
    if event.type == .keyDown,
      let direction = Self.navigationDirection(for: event, firstResponder: firstResponder)
    {
      onNavigate?(direction)
      return
    }

    super.sendEvent(event)
  }

  static func navigationDirection(for event: NSEvent, firstResponder: NSResponder?) -> Int? {
    guard acceptsArrow(event, firstResponder: firstResponder) else { return nil }

    switch event.keyCode {
    case 123:
      return -1
    case 124:
      return 1
    default:
      return nil
    }
  }

  static func zoomDirection(for event: NSEvent, firstResponder: NSResponder?) -> Int? {
    guard acceptsArrow(event, firstResponder: firstResponder) else { return nil }
    switch event.keyCode {
    case 126: return 1
    case 125: return -1
    default: return nil
    }
  }

  private static func acceptsArrow(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
    if let editor = firstResponder as? NSTextView, editor.isFieldEditor || editor.isEditable {
      return false
    }
    return event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
  }
}
