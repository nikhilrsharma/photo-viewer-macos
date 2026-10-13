# Security hardening - 11 October 2026

## Update - 13 October 2026

The app is now named **Nik's Photo Viewer**. The updated PRD describes the current
sandboxed product; only the delivery-backlog PDF remains a pre-hardening snapshot.
The source is public at [photo-viewer-macos](https://github.com/nikhilrsharma/photo-viewer-macos).
GitHub Build/tests and Swift CodeQL both passed for commit `cc756f3` after the
CodeQL-only build disabled Xcode user-script sandboxing. App Sandbox remains on.
The keyboard-zoom and branding update passed 85 local tests with zero failures,
plus Release signature, read-only entitlement, hardened-runtime, architecture and
coverage checks. Each new commit still needs its own GitHub workflow results.

The following sections preserve the 11 October audit and its then-pending gates.

This change follows the initial product/security review. It supersedes the
pre-hardening security status in the two retrospective portfolio PDFs. The app's
visible name remains **Photo Viewer**; the repository name is **photo-viewer-macos**.
The owner has approved the MIT licence, copyright 2026 Nikhil Sharma.

## Issues addressed

| Earlier finding | Implemented response |
|---|---|
| No operating-system sandbox boundary | App Sandbox, read-only user-selected access and read-only app-scoped bookmarks. No network or user-selected write entitlements. |
| No hard limit before original-resolution decoding | Validate dimensions/depth, source size, total pixels and estimated decoded bytes before requesting a raster; validate actual decoded bytes afterward. |
| Non-file and special-file inputs could enter decoding | Shared absolute local-URL policy; read-only nonblocking open, regular-file `fstat` check, and rejection before URL normalization. |
| Paths could change while loading or caching | Pin the descriptor, use bounded `pread`, detect source changes, and validate cache entries against target identity and nanosecond timestamps. |
| Missing hardened-runtime flag in personal binary | Explicit Release runtime signing flag, with a verification script that inspects the resulting signature. |
| Read-only permissions overstated in README | Current documentation distinguishes read-only file grants, app-owned storage, decoder limitations and signing/notarisation. |
| Publication could include local artifacts | Source-only allowlist, metadata-free ZIP, ignores, conservative pattern checks, and review of public documentation. |

The limits are 512 MiB source bytes, 100 million original pixels, 100,000 pixels
per source edge, an 8,192-pixel Fit preview edge, and 512 MiB estimated/actual
decoded buffer per request. The 128 MiB RAM-only revisit cache is separate.
An image can be safe to preview yet too expensive at full detail; clicking Fit
explicitly recovers from a rejected manual-resolution request. Automatic resize
does not create a failure/retry loop.

## User-visible permission change

Finder/drop opens still display the selected image immediately. If the app cannot
read siblings, it asks the user to select the exact containing folder once.
Cancel leaves the image visible; arrow keys and foreground refresh do not repeatedly
show the chooser. Reopening the image permits another attempt. A read-only bookmark
remembers approval for later launches, subject to macOS access rules and bookmark
validity. At most 32 folder bookmarks are retained, not photo copies.

Security-scope leases are retained until the associated background operations
actually finish, including a native decode whose awaiting UI task was cancelled.

## Validation performed

- The final local XCTest run passed **77 tests, zero failures** on 11 October 2026.
- Automated XCTest coverage includes URL rejection before I/O, directories/FIFOs,
  symlink targets, oversized sparse files, malformed dimensions, crafted PNG
  headers, arithmetic overflow, pinned-source truncation, cache invalidation,
  scope lifetime, permission cancellation/retry/restoration, stale grants and Fit
  recovery. Existing navigation, metadata, geometry and format regressions remain.
- Local Release inspection verifies its signature, exact three sandbox/read-only
  entitlements, actual hardened-runtime flag, arm64 architecture and absence of
  coverage instrumentation using `scripts/verify_release.py`.
- Native UI smoke checks with two generated PNG/JPEG fixtures: opening, cancelling
  folder access, no repeated prompt on arrow navigation, reopening to retry,
  approving the exact synthetic folder, mixed-format arrows, and saved approval
  after quitting/relaunching. No personal photos are used in this workflow.
- Before/after checks on those synthetic files found identical SHA-256 contents,
  names, sizes, creation dates and modification dates. The opening workflow added
  a `com.apple.lastuseddate#PS` extended attribute; the pre-existing provenance
  attribute was unchanged. Read-only app permissions do not promise that macOS
  leaves access/last-used metadata untouched.
- Source hygiene review excludes local builds, user settings, profiling outputs,
  personal paths, test images and credentials from the public package. The two PDFs
  were previously rendered and checked; they contain no private photo screenshots.

The tests and Release checks use Xcode 27 / Swift 6.4 on arm64 macOS 27.0.1. The
deployment target remains macOS 26; an end-to-end macOS 26 runner result is not yet
available. The initial saved pre-hardening run of 53 tests and performance numbers
in the PDFs are historical evidence, not the validation count or benchmark of
this hardened source.

## Remaining limits and publication gates

- ImageIO is a native, in-process parser. Header checks themselves require parsing;
  there is no separate decoder process, enforced decode timeout or proof that all
  malicious files are harmless. Keep macOS patched. The limits do not cap total
  process memory or native codec scratch allocations.
- A source package can be published without shipping an executable. Local builds
  remain ad-hoc signed. A trusted public binary still needs the owner's Apple
  Developer ID identity, appropriate signing and notarisation, plus a clean-install
  Gatekeeper check. No certificate or credential was obtained or embedded here.
- GitHub CI/Swift CodeQL workflows are supplied, with SHA-pinned official actions
  and minimal permissions. They have not executed on GitHub. The `xcode-27` runner
  is currently a public-preview image; verify availability and CodeQL toolchain
  support at the first run. Do not treat a configured scanner as a passed scan.
- The owner still needs to select a GitHub account, create/approve the public
  repository, inspect staged contents and enable private vulnerability reporting.
  Check secret-scanning alerts and push protection. The included lightweight
  pattern checker is not a comprehensive secret or Git-history scanner.
- No code has been pushed and no public repository or downloadable release has
  been created by preparing this package. The installed personal app is not
  automatically replaced by source-package preparation.

## Primary references

- [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple: Configure App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Apple: Required-reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [GitHub: Swift CodeQL build options](https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages)
- [GitHub: Hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
