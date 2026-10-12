# Security

## Reporting a vulnerability

If GitHub private vulnerability reporting is enabled for this repository, use
**Security → Advisories → Report a vulnerability**. Do not post exploit details,
malicious images, private file paths, or personal photographs in a public issue.

If that reporting option is unavailable, open a minimal issue asking the maintainer
to provide a private reporting route, without sensitive details or an exploit
attachment. No private email address, response-time guarantee, or already-enabled
reporting channel is implied by this document.

Include the source revision, macOS/Xcode versions, reproduction steps, expected
and observed behaviour, and relevant sandbox or crash diagnostics with personal
paths redacted. Prefer a minimal synthetic reproducer that you have the right to
share. Review targets the current source; there is no declared backport or release
support schedule.

## Security model

Photo Viewer displays user-selected image files and discovers siblings in a folder
the user approves. It is not an editor and does not intentionally write image
content, names, metadata, or extended attributes.

This describes the app's access, not a guarantee about all macOS bookkeeping.
In a Finder/LaunchServices smoke test, image bytes, names, file sizes, creation
dates and modification dates stayed unchanged, but a `com.apple.lastuseddate#PS`
extended attribute was added. OS access/last-used metadata can change on opening.

The host application uses App Sandbox and hardened runtime. Its file entitlements
permit user-selected **read-only** access and persistent application-scoped
bookmarks, without user-selected read/write or network-client/server entitlements.
When sibling access is unavailable, a native directory chooser requests the exact
containing folder. Cancelling preserves the selected image without granting the
folder. Security-scoped access is balanced around the relevant asynchronous work.

ImageIO decoding still runs **inside the app process**. There is no separate decoder
process, hard per-decode timeout, or claim that malformed images cannot exploit an
operating-system codec. One decode runs at a time; replacing a queued request does
not interrupt a synchronous decoder that has already started. Keep macOS updated
and treat images from untrusted sources with appropriate caution.

### Input and resource limits

The loader accepts local file URLs for readable regular-file targets. Symlinks to
regular files are supported; directories, devices, FIFOs, and remote URLs are not
image sources. It pins a read-only descriptor and uses bounded reads rather than
mapping the entire source or copying it wholesale into memory.

The viewing policy enforces these limits:

| Check | Limit |
|---|---:|
| Source-file size | 512 MiB |
| Original width or height | 100,000 pixels |
| Original pixel count | 100,000,000 pixels |
| Fit-preview longest edge | 8,192 pixels |
| Estimated and actual decoded pixel buffer | 512 MiB |
| Recently viewed decoded-image cache | 128 MiB |

Dimension/depth metadata is validated, and buffer arithmetic is overflow-checked.
The original-dimension and pixel-count limits apply even in Fit mode. The decoded
buffer budget applies to the requested resolution: a high-bit-depth image may fit
within the preview budget while its full-resolution manual-zoom request is rejected.
These are application guardrails, not an assurance of a 512 MiB total memory ceiling:
codec temporary allocations, the current image, cached images, and UI/graphics
resources can coexist. Checking headers also requires native parsing. Invalid,
changed, or over-limit inputs produce an error; navigation remains available.

### Local data and permissions

The image cache lives in RAM and is discarded on process exit. The app does not
maintain a disk photo cache or proactively fetch neighbouring cloud files. macOS
can use swap and may retrieve a user-selected cloud-backed file. Window state and
approved-folder bookmarks are ordinary local application data, separate from photos.

There is no telemetry or application network feature. Paths and metadata appear
in the interface by design; users should redact them before sharing screenshots
or logs. A read-only application is not a substitute for backups, and the MIT
licence provides no warranty.

## Signing and distribution status

Source builds use local ad-hoc signing. Hardened runtime and sandbox entitlements
do **not** make a build Developer ID signed, notarized, independently audited, or
safe to run solely because it has a signature. Public binary distribution requires
a separate review of signing identity, nested-code signatures, notarization,
Gatekeeper behaviour, and the exact shipped archive. Never commit signing keys,
certificate exports, notarization credentials, personal fixtures, or build logs.

The PDF portfolio documents in `docs/` are historical, pre-hardening snapshots.
This document, the current source, and [Security hardening](docs/SECURITY-HARDENING.md)
supersede their sandbox, licensing, validation-count, and publication-gate statements.
