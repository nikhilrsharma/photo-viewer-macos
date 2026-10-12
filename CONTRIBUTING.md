# Contributing

Photo Viewer is a deliberately small, native, read-only macOS utility. Keep changes
focused on opening, inspecting, and navigating images. Editing tools, a photo
library, accounts, background uploads, animation playback, and a cross-platform
rewrite are outside the current scope. Discuss substantial new features before
implementing them.

## Development

Use the build/test commands in [README](README.md). The verified development tools
are Xcode 27 / Swift 6.4 on Apple silicon; macOS 26 is the deployment target. There
are no third-party runtime package dependencies to install.

Use Release builds for performance measurements. Debug instrumentation and test
coverage are useful for testing but must not ship in a distribution build. The
build date resource is generated during the build; do not replace it with the
current date at launch or edit an installed app bundle.

## Regression expectations

Add or update tests for the behaviour you change. In particular, preserve:

- One reusable image window, natural mixed-format ordering, non-wrapping navigation,
  folder-context replacement, and recovery after denied access or removed files.
- Read-only sandbox permissions and balanced security-scoped access, including
  cancellation, superseded requests, and asynchronous work that outlives its caller.
- Fit/manual mode behaviour, 5% manual steps, 20–200% manual bounds, original-pixel
  geometry on 1×/2× screens, orientation, and first-frame-only animation handling.
- Accurate metadata states, preview/centre preservation during resolution upgrades,
  bounded decoded-image caching, and single-decoder/latest-pending-request behaviour.
- Input-size limits, safe numeric conversions, non-regular-file rejection, and
  failure messages that do not prevent further navigation.
- About credits, a genuine build-recorded date, and no visible version number.

The native HEIC test uses an optional system fixture and is expected to skip if
that fixture is absent. A skipped format test is not evidence that format was
verified on the machine. OS codec availability does not prove visual fidelity for
every file variant. For UI changes, also inspect a local build at minimum window
size and with long filenames/paths; unit tests alone do not establish visual quality.

## Fixtures, privacy, and licences

Prefer small, deterministic fixtures generated in a temporary test directory.
Do not commit personal photos, full home-directory paths, private screenshots,
access bookmarks, logs, DerivedData, compiled apps, or profiling data. The ignore
file is a convenience, not a substitute for reviewing staged files.

Any added asset or sample must have documented redistribution rights. The existing
self-contained project icon and its raster assets are included under the project's
MIT licence with the owner's authorization; do not infer a broader third-party
provenance claim. Do not copy macOS system images into the repository. Contributions
must be compatible with [MIT](LICENSE).

For read-only changes, compare synthetic fixtures before and after viewing: bytes,
names, creation/modification dates, and relevant extended attributes. Tests may
create and clean up their own temporary fixtures; the app must not modify originals.

## Performance claims and review

State the tested commit, Release configuration, OS/toolchain, fixture dimensions
and format, warm/cold-cache conditions, sample count, and statistic. Distinguish
decode time, UI latency, pixel-buffer bytes, cache budget, and process memory.
Do not turn a synthetic microbenchmark into a percentage claim about the whole app.
Re-run measurements after security or architecture changes that affect loading.

Before proposing a change, inspect its diff for private data, run the relevant
tests and a Release build, and describe remaining gaps honestly. Do not publish
binaries or alter sandbox/signing entitlements as an incidental cleanup.
For vulnerabilities, follow [Security](SECURITY.md) rather than a public bug report.
