import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var state: ApplicationState

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      viewer
    }
    .frame(minWidth: 640, minHeight: 480)
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: acceptDrop)
  }

  private var header: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(state.filename)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)

          Text("·")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize()

          Text(state.fullPath)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(fileIdentityLineText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filename: \(state.filename). Full path: \(state.fullPath)")

        if state.currentURL != nil {
          HStack(spacing: 5) {
            Text(createdDateText)
              .lineLimit(1)
              .truncationMode(.tail)

            Text("·")
              .fixedSize()

            Text(fileSizeText)
              .fixedSize()

            Text("·")
              .fixedSize()

            Text(photoPositionText)
              .fixedSize()
          }
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(metadataLineText)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(metadataLineText)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(alignment: .bottom, spacing: 8) {
        fitModeButton
        zoomOutControl
        zoomSliderControl
        zoomInControl
      }
      .fixedSize()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var zoomOutControl: some View {
    VStack(spacing: 1) {
      Text("Min 20%")
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .fixedSize()
        .frame(height: ZoomControlLayout.captionHeight)
        .accessibilityHidden(true)

      Button {
        state.adjustZoom(by: -1)
      } label: {
        Image(systemName: "minus")
          .frame(width: 12, height: 12)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityLabel("Zoom out")
      .accessibilityValue("Minimum 20 percent")
      .help("Zoom out by 5% (Down Arrow; minimum 20%)")
      .disabled(!state.canAdjustZoom(by: -1))
      .frame(height: ZoomControlLayout.controlHeight)
    }
  }

  private var zoomInControl: some View {
    VStack(spacing: 1) {
      Text("Max 200%")
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .fixedSize()
        .frame(height: ZoomControlLayout.captionHeight)
        .accessibilityHidden(true)

      Button {
        state.adjustZoom(by: 1)
      } label: {
        Image(systemName: "plus")
          .frame(width: 12, height: 12)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityLabel("Zoom in")
      .accessibilityValue("Maximum 200 percent")
      .help("Zoom in by 5% (Up Arrow; maximum 200%)")
      .disabled(!state.canAdjustZoom(by: 1))
      .frame(height: ZoomControlLayout.controlHeight)
    }
  }

  private var zoomSliderControl: some View {
    VStack(spacing: 1) {
      ZStack(alignment: .topLeading) {
        Text(zoomPercentageDescription)
          .font(.system(size: 9, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
          .position(
            x: CGFloat(ZoomSliderMetrics.labelCenter(for: state.sliderValue())),
            y: ZoomControlLayout.captionHeight / 2
          )
          .accessibilityHidden(true)
      }
      .frame(
        width: CGFloat(ZoomSliderMetrics.containerWidth),
        height: ZoomControlLayout.captionHeight
      )

      Slider(
        value: Binding(
          get: { state.sliderValue() },
          set: {
            state.setManualZoom($0)
          }
        ),
        in: ZoomPolicy.minimum...ZoomPolicy.maximum,
        step: ZoomPolicy.increment
      )
      .frame(width: CGFloat(ZoomSliderMetrics.sliderWidth))
      .frame(width: CGFloat(ZoomSliderMetrics.containerWidth))
      .frame(height: ZoomControlLayout.controlHeight)
      .disabled(state.currentURL == nil)
      .accessibilityLabel("Zoom level")
      .accessibilityValue(zoomAccessibilityDescription)
    }
    .frame(width: CGFloat(ZoomSliderMetrics.containerWidth))
  }

  @ViewBuilder
  private var viewer: some View {
    ZStack {
      ImageScrollView(
        image: loadedImage,
        zoomMode: state.zoomMode,
        imageIdentity: state.currentURL,
        onFitPercentageChanged: { percentage in
          if abs(state.effectiveFitPercentage - percentage) > 0.01 {
            state.effectiveFitPercentage = percentage
          }
        },
        onViewportChanged: { size, scale in
          state.updateViewport(size: size, backingScale: scale)
        }
      )

      switch state.loadState {
      case .empty:
        message("Open an image from Finder")
      case .loading:
        ProgressView()
          .controlSize(.small)
          .tint(.white)
      case .loaded:
        EmptyView()
      case .failed(let explanation):
        message(explanation)
      }

      if let notice = state.navigationNotice {
        VStack {
          Spacer()
          Text(notice)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
            .padding(16)
        }
        .allowsHitTesting(false)
      }
    }
  }

  private var loadedImage: LoadedImage? {
    if case .loaded(let image) = state.loadState {
      return image
    }
    return nil
  }

  @ViewBuilder
  private var fitModeButton: some View {
    if isFitMode {
      fitModeButtonContent
        .buttonStyle(.borderedProminent)
        .accessibilityAddTraits(.isSelected)
    } else {
      fitModeButtonContent
        .buttonStyle(.bordered)
    }
  }

  private var fitModeButtonContent: some View {
    Button {
      state.fitToWindow()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "checkmark")
          .font(.system(size: 9, weight: .bold))
          .opacity(isFitMode ? 1 : 0)
          .accessibilityHidden(true)

        Text("Fit")
      }
      .frame(width: 42)
    }
    .controlSize(.small)
    .disabled(state.currentURL == nil)
    .accessibilityLabel("Fit to window")
    .accessibilityValue(isFitMode ? "On" : "Off")
    .help(isFitMode ? "Fit to window is on" : "Fit to window is off. Click to turn it on.")
  }

  private var isFitMode: Bool {
    if case .fit = state.zoomMode {
      return true
    }
    return false
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 15))
      .foregroundStyle(.white.opacity(0.62))
      .padding(24)
      .multilineTextAlignment(.center)
  }

  private var zoomPercentageDescription: String {
    guard state.currentURL != nil else { return "—" }
    switch state.zoomMode {
    case .fit:
      return formattedPercentage(state.effectiveFitPercentage)
    case .manual(let percentage):
      return formattedPercentage(percentage)
    }
  }

  private var zoomAccessibilityDescription: String {
    guard state.currentURL != nil else { return "No image" }
    let roundedPercentage: Int
    switch state.zoomMode {
    case .fit:
      roundedPercentage = Int(state.effectiveFitPercentage.rounded())
      return "Fit, \(roundedPercentage) percent"
    case .manual(let percentage):
      roundedPercentage = Int(percentage.rounded())
      return "\(roundedPercentage) percent"
    }
  }

  private var createdDateText: String {
    if state.isMetadataLoading {
      return "Created date: Loading…"
    }
    guard let creationDate = state.fileMetadata?.creationDate else {
      return "Created date: Unavailable"
    }
    return "Created date: \(creationDate.formatted(date: .abbreviated, time: .shortened))"
  }

  private var fileSizeText: String {
    if state.isMetadataLoading {
      return "Size: Loading…"
    }
    guard let fileSizeBytes = state.fileMetadata?.fileSizeBytes else {
      return "Size: Unavailable"
    }
    return "Size: \(ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file))"
  }

  private var metadataLineText: String {
    "\(createdDateText) · \(fileSizeText) · \(photoPositionText)"
  }

  private var fileIdentityLineText: String {
    "\(state.filename) · \(state.fullPath)"
  }

  private var photoPositionText: String {
    guard let position = state.photoPosition else {
      return "Photo position unavailable"
    }
    return "Photo \(position.number) of \(position.total)"
  }

  private func formattedPercentage(_ percentage: Double) -> String {
    "\(Int(percentage.rounded()))%"
  }

  private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
      })
    else {
      return false
    }

    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
      let url: URL?
      if let data = item as? Data {
        url = URL(dataRepresentation: data, relativeTo: nil)
      } else {
        url = item as? URL
      }

      guard let url else { return }
      Task { @MainActor in
        state.openDropped(url)
      }
    }
    return true
  }
}

private enum ZoomControlLayout {
  static let captionHeight: CGFloat = 11
  static let controlHeight: CGFloat = 22
}
