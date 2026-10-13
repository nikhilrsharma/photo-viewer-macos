# Nik's Photo Viewer

A small, native, read-only photo browser for macOS. Built for personal use by
Nikhil Sharma with assistance from Codex, OpenAI's AI coding assistant.

Repository name: `photo-viewer-macos`. This is a source project, not an App Store
product or a notarized binary release.

## What it does

- Opens Finder-selected or dropped images in one reusable, resizable photo window.
- Browses supported images in the same folder with Left/Right arrows, in natural
  filename order (`photo2` before `photo10`), stopping at either end.
- Starts in Fit mode. Manual zoom is 20–200% in 5% steps, using the slider or
  minus/plus buttons or Up/Down arrows (including key repeat). Short, retargetable
  zoom transitions keep input responsive; Reduce Motion makes changes immediate.
  The percentage follows the slider thumb; Fit is visibly
  selected when active. Zoomed images can be panned.
- Displays filename and full path, then filesystem creation date, file size,
  and position in the folder. Creation date is not the camera's EXIF date taken.
- Preserves image orientation and uses native ImageIO decoding. Animated files
  show their first frame. There are no editing, rename, save, or delete commands.
- Includes an About panel with creator/AI credits and the recorded build date,
  without displaying an app version number.

The first window occupies about 90% of the usable display; later launches restore
its size. Standard window controls remain available without macOS full-screen
mode. A new Finder open replaces the image/folder and resets Fit; arrow navigation
keeps the selected zoom mode. Fit's actual percentage may fall outside the manual
20–200% range.

The app name sits beside the standard traffic-light controls. Its app menu contains
only About and Quit: no Hide commands or Window menu. Command-W and Command-M still
close and minimize the photo window. macOS itself can still offer Hide in the Dock.

### Formats

Common formats include JPEG/JPG/JFIF, PNG/APNG, HEIC/HEIF, AVIF, TIFF, GIF, BMP/DIB,
and WebP. The catalog also recognises native JPEG 2000, JPEG XL, PSD, OpenEXR, TGA,
HDR, icon, MPO, portable bitmap, and SGI variants. Decoding depends on the installed
macOS ImageIO codecs and the individual file; recognition does not guarantee that
every file is valid. Camera RAW and animation playback are out of scope.

## Build and test

The deployment target is **macOS 26 on Apple silicon (arm64)**. Development and
testing have used **Xcode 27 / Swift 6.4**. Compatibility with older Xcode releases
or Intel Macs has not been verified. No third-party package dependencies are
required; the app uses Apple frameworks.

From the repository root, with full Xcode selected as the active developer tools:

```sh
photo_viewer_build="$(mktemp -d -t photo-viewer-build)"
xcodebuild -project PhotoViewer.xcodeproj -scheme PhotoViewer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$photo_viewer_build/Debug" \
  -resultBundlePath "$photo_viewer_build/Tests.xcresult" test
xcodebuild -project PhotoViewer.xcodeproj -scheme PhotoViewer \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$photo_viewer_build/Release" \
  ENABLE_CODE_COVERAGE=NO build
```

The local app is at
`$photo_viewer_build/Release/Build/Products/Release/Nik's Photo Viewer.app`.
Keep the temporary build directory until you have inspected the test results and
copied any output you want to retain. Tests generate temporary fixtures; the HEIC
test additionally reads an optional system-provided image and skips when it is
not installed. There is no bundled personal-photo test corpus.

Release builds are optimized, use hardened runtime, and exclude code coverage.
Local builds are **ad-hoc signed**, not Developer ID signed or Apple notarized.
Do not represent them as verified public binary releases or disable Gatekeeper
to run an untrusted download. Developer ID distribution requires separate signing,
notarization, and verification work.

## Use and folder access

After building, place one copy of `Nik's Photo Viewer.app` in Applications and launch it.
In Finder, use **Open With → Nik's Photo Viewer**, or drop an image onto the photo window.
Avoid keeping multiple installed copies if Finder shows duplicate Open With entries.

The app uses the macOS App Sandbox with read-only user-selected file access. To
browse siblings when macOS has only granted access to the selected image, the app
asks you to select that image's containing folder. A read-only security-scoped
bookmark remembers approved access. Cancel leaves the selected image available;
reopen it to retry folder permission. macOS privacy controls can still restrict
Desktop, Documents, removable volumes, or other locations.

Folder access does not add editing features. Only one photo window is used; the
separate, reusable About panel is available from **Nik's Photo Viewer → About Nik's Photo Viewer**.
Closing the photo window leaves the app running. Use **Quit Nik's Photo Viewer** to exit.
The app does not rewrite photos. macOS can still update access/last-used metadata
when a file is opened; read-only app access cannot guarantee unchanged OS metadata.

## Performance, memory, and safety

- Folder discovery and indexing run away from the UI thread. Navigation uses an
  in-memory ordered list, refreshed through folder events and a foreground fallback.
- Fit mode decodes a display-sized image while retaining original, orientation-
  correct dimensions. At 100%, one image pixel occupies one screen pixel. Manual
  zoom requests original detail; resolution upgrades preserve the visible preview.
- One native decode runs at a time, and obsolete waiting requests are replaced.
  An active synchronous ImageIO decode cannot be forcibly cancelled.
- The recently viewed image cache is **RAM-only and limited to 128 MiB of decoded
  pixels**. This is not a total-process-memory limit. It is released on app exit;
  there is no app-managed photo cache accumulating on disk. macOS may page RAM to
  swap, and normal window preferences and access bookmarks are stored separately.
- No speculative neighbour downloads, telemetry, or application network requests
  are implemented. The user may still select a cloud-backed file that macOS must
  make available before it can be read.
- Local regular files are checked against source-size, dimension, pixel-count,
  and decoded-buffer limits. Oversized or invalid images show an error rather than
  blocking navigation. See [Security](SECURITY.md) for exact limits and residual risks.

## Product background and portfolio

This project grew from a deliberately narrow personal need: open a photo, inspect
it, and move to nearby photos without editing tools. Iterations refined keyboard
navigation, permission recovery, compact metadata, visible Fit state, zoom-control
alignment, and resource use. The implementation remained in Swift because the
main opportunities were avoiding repeated directory work and oversized decoding,
not replacing a measured CPU-heavy algorithm with another language.

- [Product requirements document](docs/Photo-Viewer-PRD.pdf)
- [Epics, features, stories, and acceptance criteria](docs/Photo-Viewer-Delivery-Backlog.pdf)
- [Security hardening and current validation notes](docs/SECURITY-HARDENING.md)
- [Reproducible historical microbenchmark](benchmarks/README.md)

**The PRD is updated through 13 October 2026**, including current requirements,
new user stories and acceptance criteria. The delivery backlog remains the original
retrospective, pre-hardening snapshot; its original unsandboxed architecture,
licence/publication gates, and test counts are historical. The current PRD, source,
this README, and [Security](SECURITY.md) supersede those older backlog statements.
Earlier synthetic performance measurements are not a
benchmark of the current security-hardened build. No whole-application performance
percentage, independent security audit, or representative usability study is claimed.

To rebuild the PRD on macOS, install the optional documentation dependencies
`reportlab` and `pypdf`, then run `python3 scripts/build_prd.py`. These are not app
dependencies.

### Icon

The colourful glass landscape icon was generated with OpenAI's built-in image
generation tool, then mechanically resized into Apple's required icon sizes.
[AppIcon.png](AppIcon.png) is the 1024-pixel master. Generation prompt:

> Use case: logo-brand. Asset type: macOS application icon for Nik's Photo Viewer.
> Create one polished colourful app icon, square composition, no text, no letters,
> no watermark. A luminous rounded-square photo tile: simple stylized mountains
> and a warm circular sun rendered as layered translucent glass in vivid jewel
> colours, clean silhouette and generous negative space, subtle dimensionality
> and refined soft highlights. Colourful but minimal and legible at tiny Dock
> sizes. A single centered icon occupying about 84 percent of the square,
> straight-on view, equal transparent margins. True transparent background
> outside the rounded-square icon. Do not include a device, desktop screenshot,
> border frame, or multiple variants.

## Contributing and licence

See [Contributing](CONTRIBUTING.md) for scope, test expectations, and fixture hygiene,
and [Security](SECURITY.md) for responsible reporting.

The source and included project icon assets are available under the [MIT licence](LICENSE),
copyright 2026 Nikhil Sharma. Apple frameworks and system resources are not
redistributed under this licence. The project does not require external runtime
packages or bundled third-party photo assets.
