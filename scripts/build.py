#!/usr/bin/env python3
"""Build two native macOS bundles using only the Xcode command line tools."""
import argparse
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

from signing import remember_identity, signing_identity

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
APP = BUILD / "MX Mouse Settings.app"
HELPER = APP / "Contents/Library/LoginItems/MX Mouse Helper.app"


def run(*arguments, quiet_success=False):
    result = subprocess.run(list(map(str, arguments)), cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"{arguments[0]} failed (exit {result.returncode})." + (f"\n{detail}" if detail else ""))
    if not quiet_success:
        if result.stdout.strip():
            print(result.stdout.strip())
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)


def require_apps_stopped():
    for executable in ("mxmouse-settings", "mxmouse-helper"):
        result = subprocess.run(["pgrep", "-x", executable], capture_output=True, text=True)
        if result.returncode == 0:
            raise RuntimeError("Quit MX Mouse Settings and stop its helper before installing. Disable Start at login in Settings, quit Settings, then stop the helper with pkill -TERM -x mxmouse-helper and retry.")
        if result.returncode != 1:
            raise RuntimeError("Could not check running MX Mouse processes; installation stopped.")


def install_app(source, destination):
    # Stage a complete bundle: merging into an old app leaves obsolete sealed resources.
    with tempfile.TemporaryDirectory(prefix=".mxmouse-install-", dir=destination.parent) as directory:
        stage = pathlib.Path(directory)
        replacement = stage / destination.name
        backup = stage / "previous.app"
        run("ditto", source, replacement)
        run("codesign", "--verify", "--deep", "--strict", replacement, quiet_success=True)
        require_apps_stopped()
        had_previous = destination.exists()
        if had_previous:
            destination.rename(backup)
        try:
            replacement.rename(destination)
        except OSError:
            if had_previous:
                backup.rename(destination)
            raise


def info(bundle, identifier, executable, background=False):
    contents = bundle / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    value = {
        "CFBundleIdentifier": identifier,
        "CFBundleName": bundle.stem,
        "CFBundleDisplayName": bundle.stem,
        "CFBundleExecutable": executable,
        "CFBundlePackageType": "APPL",
        "CFBundleIconFile": "MXMouseHelper" if background else "MXMouse",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "5",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
    }
    if background:
        value["LSBackgroundOnly"] = True
        value["NSInputMonitoringUsageDescription"] = "Read connected Logitech mouse buttons and wheels to apply each mouse's settings."
    (contents / "Info.plist").write_bytes(plistlib.dumps(value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Also copy the app to /Applications; Settings and its helper must be stopped.")
    arguments = parser.parse_args()
    if arguments.install:
        require_apps_stopped()
    identity, remember = signing_identity()
    print("Building native helper and Settings…", flush=True)
    BUILD.mkdir(exist_ok=True)
    info(APP, "local.mxmouse.settings", "mxmouse-settings")
    info(HELPER, "local.mxmouse.helper", "mxmouse-helper", True)
    flags = ["-Os", "-DNDEBUG", "-Wall", "-Wextra", "-Werror", "-fblocks", "-mmacosx-version-min=13.0", "-Isrc"]
    for name in ("core", "storage", "device"):
        run("xcrun", "clang", *flags, "-std=c11", "-c", ROOT / f"src/{name}.c", "-o", BUILD / f"{name}.o")
    common = [BUILD / "core.o", BUILD / "storage.o", BUILD / "device.o", "-framework", "CoreFoundation", "-framework", "CoreGraphics", "-framework", "ApplicationServices", "-framework", "IOKit"]
    run("xcrun", "clang", *flags, "-std=c11", ROOT / "src/helper.c", *common,
        "-Wl,-dead_strip", "-o", HELPER / "Contents/MacOS/mxmouse-helper")
    run("xcrun", "clang", *flags, "-fobjc-arc", ROOT / "src/settings.m", ROOT / "src/mouse_view.m", ROOT / "src/import_options.m", ROOT / "src/logi_controls.m", ROOT / "src/helper_drag_view.m", *common,
        "-framework", "AppKit", "-framework", "ServiceManagement", "-lsqlite3", "-Wl,-dead_strip",
        "-o", APP / "Contents/MacOS/mxmouse-settings")
    run("xcrun", "clang", *flags, "-fobjc-arc", ROOT / "scripts/icon.m",
        "-framework", "AppKit", "-o", BUILD / "make-icon")
    run(BUILD / "make-icon", BUILD / "MXMouse.iconset", BUILD / "MXMouseHelper.iconset")
    resources = APP / "Contents/Resources"
    resources.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / "assets/mx-master-3.png", resources / "mx-master-3.png")
    shutil.copyfile(ROOT / "assets/m705.png", resources / "m705.png")
    run("iconutil", "-c", "icns", BUILD / "MXMouse.iconset", "-o", resources / "MXMouse.icns")
    helper_resources = HELPER / "Contents/Resources"
    helper_resources.mkdir(exist_ok=True)
    (helper_resources / "MXMouse.icns").unlink(missing_ok=True)
    run("iconutil", "-c", "icns", BUILD / "MXMouseHelper.iconset", "-o", helper_resources / "MXMouseHelper.icns")
    print("Signing and verifying app bundles…", flush=True)
    for bundle in (HELPER, APP):
        run("codesign", "--force", "--sign", identity, "--identifier",
            "local.mxmouse.helper" if bundle == HELPER else "local.mxmouse.settings", bundle, quiet_success=True)
    run("codesign", "--verify", "--deep", "--strict", APP, quiet_success=True)
    remember_identity(identity, remember)
    destination = APP
    if arguments.install:
        require_apps_stopped()
        destination = pathlib.Path("/Applications/MX Mouse Settings.app")
        print("Installing in Applications…", flush=True)
        install_app(APP, destination)
    print(f"App: {destination}")
    print("Executable sizes on disk (not RAM):")
    print(f"  Helper: {(HELPER / 'Contents/MacOS/mxmouse-helper').stat().st_size:,} bytes")
    print(f"  Settings: {(APP / 'Contents/MacOS/mxmouse-settings').stat().st_size:,} bytes")
    if identity == "-":
        print("Ad-hoc signed development build: rebuilds can require granting helper permissions again.")
    print("BUILD SUCCEEDED", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"BUILD FAILED: {error}", file=sys.stderr)
        sys.exit(1)
