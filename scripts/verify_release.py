"""Check security configuration of a locally built Release app; no mutations."""
import pathlib
import plistlib
import re
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve(strict=True)
if not app.is_dir() or app.suffix != ".app":
    raise SystemExit("Expected a built .app directory")

def run(*args):
    return subprocess.run(args, check=True, capture_output=True)

run("/usr/bin/codesign", "--verify", "--strict", "--deep", str(app))
entitlements = run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)).stdout
grants = plistlib.loads(entitlements)
expected = {
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-only",
    "com.apple.security.files.bookmarks.app-scope",
}
assert all(grants.get(key) is True for key in expected), grants
# Fail closed on any additional capability (network, write, debugger, etc.).
assert set(grants) == expected, grants
details = run("/usr/bin/codesign", "-d", "--verbose=4", str(app)).stderr.decode()
assert re.search(r"flags=0x[0-9a-f]+\([^\n]*runtime", details), details
bundle_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
executable = bundle_info["CFBundleExecutable"]
assert pathlib.Path(executable).name == executable and executable not in {"", ".", ".."}
binary = app / "Contents/MacOS" / executable
assert run("/usr/bin/lipo", "-archs", str(binary)).stdout.strip() == b"arm64"
sections = run("/usr/bin/otool", "-l", str(binary)).stdout.decode()
assert "__llvm_prf" not in sections and "__llvm_cov" not in sections
print("Verified: valid signature, sandbox + read-only scope only, hardened runtime, arm64, no coverage instrumentation")
print("This check does not establish Developer ID identity, notarization, or vulnerability freedom.")
