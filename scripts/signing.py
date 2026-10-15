"""Choose a persistent code-signing identity for local rebuilds."""
import os
import pathlib
import re
import subprocess

SIGNING_CHOICE = pathlib.Path.home() / "Library/Application Support/MX Mouse/signing-identity.txt"


def signing_identity():
    explicit = os.environ.get("MX_SIGN_IDENTITY")
    if explicit is not None:
        if not explicit.strip():
            raise RuntimeError("MX_SIGN_IDENTITY must name a signing identity, or '-' for an explicit ad-hoc build.")
        return explicit, False
    result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Cannot inspect code-signing identities: " + result.stderr.strip())
    identities = re.findall(r'\d+\) ([0-9A-Fa-f]{40}) "([^"\n]+)"', result.stdout)
    if SIGNING_CHOICE.exists():
        saved = SIGNING_CHOICE.read_text().strip()
        if any(fingerprint == saved for fingerprint, _ in identities):
            return saved, False
        raise RuntimeError("The saved signing certificate is unavailable. Restore it in Keychain or explicitly choose a replacement with MX_SIGN_IDENTITY. Changing certificates may require granting permissions again.")
    for prefix in ("Apple Development:", "Developer ID Application:", "Mac Developer:"):
        for fingerprint, name in identities:
            if name.startswith(prefix):
                print(f"Using signing identity: {name} ({fingerprint})", flush=True)
                return fingerprint, True
    raise RuntimeError("No supported signing certificate found. Set MX_SIGN_IDENTITY to an existing code-signing identity. For a temporary ad-hoc build, explicitly set MX_SIGN_IDENTITY=-; rebuilds can then require permission grants again.")


def remember_identity(identity, remember):
    if remember:
        SIGNING_CHOICE.parent.mkdir(parents=True, exist_ok=True)
        SIGNING_CHOICE.write_text(identity + "\n")
