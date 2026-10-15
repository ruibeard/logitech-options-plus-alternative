#!/usr/bin/env python3
"""Run all native and installer regression tests without touching user settings."""
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
FLAGS = ["-g", "-O1", "-Wall", "-Wextra", "-Werror", "-Isrc",
         "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
FRAMEWORKS = ["-framework", "CoreFoundation", "-framework", "CoreGraphics",
              "-framework", "ApplicationServices", "-framework", "IOKit"]


def run(*arguments, **kwargs):
    subprocess.run(list(map(str, arguments)), cwd=ROOT, check=True, **kwargs)


def isolated_run(binary):
    with tempfile.TemporaryDirectory(prefix="mx-test-home-") as directory:
        (pathlib.Path(directory) / "Library/Application Support").mkdir(parents=True)
        run(binary, env=dict(os.environ, HOME=directory))


def main():
    BUILD.mkdir(exist_ok=True)
    for name, sources, frameworks in (
        ("core", ["src/core.c", "tests/core_test.c"], []),
        ("storage", ["src/core.c", "src/storage.c", "tests/storage_test.c"], FRAMEWORKS),
        ("device", ["src/device.c", "tests/device_test.c"], []),
    ):
        binary = BUILD / f"{name}-tests"
        run("xcrun", "clang", "-std=c11", *FLAGS, *sources, *frameworks, "-o", binary)
        isolated_run(binary)

    objects = []
    for name in ("core", "storage"):
        obj = BUILD / f"import-{name}.o"
        run("xcrun", "clang", "-std=c11", *FLAGS, "-c", f"src/{name}.c", "-o", obj)
        objects.append(obj)
    binary = BUILD / "import-tests"
    run("xcrun", "clang", "-fobjc-arc", *FLAGS, "src/import_options.m",
        "tests/options_import_test.m", *objects, "-framework", "Foundation",
        *FRAMEWORKS, "-lsqlite3", "-o", binary)
    isolated_run(binary)
    run(sys.executable, ROOT / "tests/test_build.py")


if __name__ == "__main__":
    main()
