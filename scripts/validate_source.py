"""Check the intended public source tree for common accidental disclosures.

This deliberately narrow, dependency-free check is NOT a complete secret scanner.
Run an independent scanner and review the Git history before publishing.
Only filenames and issue categories are reported, never matching secret values.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
skip_dirs = {".git", "work", "DerivedData", ".build", "build", "xcuserdata", "__pycache__"}
text_suffixes = {".swift", ".md", ".json", ".plist", ".xcprivacy", ".entitlements", ".pbxproj", ".xcscheme", ".yml", ".yaml", ".py", ".sh", ".svg"}
patterns = {
    "personal home path": rb"/(?:Users|home)/[^/\s]+/",
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "GitHub token": rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})",
    "API credential": rb"(?:sk-proj-[A-Za-z0-9_-]{30,}|AKIA[0-9A-Z]{16})",
}
issues = []
files = 0
for path in root.rglob("*"):
    relative = path.relative_to(root)
    if any(part in skip_dirs for part in relative.parts):
        continue
    if path.is_symlink():
        issues.append((str(relative), "symlink must be reviewed"))
        continue
    if not path.is_file():
        continue
    files += 1
    if path.name == ".DS_Store" or path.name.startswith("._") or path.suffix in {".profraw", ".p12", ".p8", ".key", ".mobileprovision", ".provisionprofile"}:
        issues.append((str(relative), "local or signing artifact"))
    if path.suffix in text_suffixes or path.name in {"LICENSE", ".gitignore"}:
        content = path.read_bytes()
        for kind, pattern in patterns.items():
            if re.search(pattern, content):
                issues.append((str(relative), kind))
if issues:
    for filename, kind in issues:
        print(f"REVIEW {filename}: {kind}")
    raise SystemExit(1)
print(f"Checked {files} files: no selected credential patterns, home paths, or local signing artifacts found.")
print("Limit: pattern checks do not prove absence of secrets; generated PDFs/assets and Git history also require review.")
