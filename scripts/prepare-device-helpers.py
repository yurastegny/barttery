#!/usr/bin/env python3
"""Relocate copied device helpers before signing; never depend on DYLD overrides.

Both build systems flatten helpers and their dylibs into Contents/Resources.
Use --check on the final/exported bundle to verify the entire dependency closure
without changing any bytes or invalidating code signatures.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys


HELPERS = ("idevice_id", "ideviceinfo", "comptest", "bartbeat", "mobilebeat", "wifiwatch")
LOAD_COMMANDS = {
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB",
}
SOURCE_RESOURCES = Path(__file__).resolve().parents[1] / "Sources/Resources"


def load_commands(text):
    """Parse all architecture slices, excluding dylib IDs from dependencies."""
    command = None
    dependencies, identifiers = set(), set()
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("Load command "):
            command = None
        elif line.startswith("cmd "):
            command = line.split(maxsplit=1)[1]
        elif command in LOAD_COMMANDS or command == "LC_ID_DYLIB":
            match = re.fullmatch(r"name (.+) \(offset \d+\)", line)
            if match:
                (identifiers if command == "LC_ID_DYLIB" else dependencies).add(match[1])
    return dependencies, identifiers


def desired_dependency(dependency, libraries):
    if dependency.startswith(("/System/Library/", "/usr/lib/")):
        return dependency
    name = dependency.rsplit("/", 1)[-1]
    if name not in libraries:
        raise ValueError(f"Unbundled non-system dependency: {dependency}")
    return f"@loader_path/{name}"


def prepare(resources, check_only=False):
    resources = resources.resolve(strict=True)
    if resources == SOURCE_RESOURCES.resolve():
        raise ValueError("Refusing to modify source helpers; pass a copied app's Contents/Resources")
    helpers = [resources / name for name in HELPERS]
    for helper in helpers:
        if not helper.is_file() or helper.is_symlink():
            raise ValueError(f"Missing or symlinked helper: {helper}")
    libraries = {p.name: p for p in resources.glob("*.dylib")}
    if not libraries:
        raise ValueError(f"No bundled dylibs in {resources}")
    for library in libraries.values():
        if not library.is_file() or library.is_symlink():
            raise ValueError(f"Expected a regular copied dylib: {library}")

    # Preflight everything before making the first change.
    plan = []
    for binary in helpers + sorted(libraries.values()):
        output = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True)
        dependencies, identifiers = load_commands(output)
        if not dependencies and not identifiers:
            raise ValueError(f"Not a dynamic Mach-O helper/library: {binary}")
        changes = []
        for dependency in sorted(dependencies):
            desired = desired_dependency(dependency, libraries)
            if dependency != desired:
                changes.extend(["-change", dependency, desired])
        if binary.name in libraries:
            desired_id = f"@loader_path/{binary.name}"
            if not identifiers:
                raise ValueError(f"Missing dylib identity: {binary}")
            if identifiers != {desired_id}:
                changes.extend(["-id", desired_id])
        if check_only and changes:
            raise ValueError(f"Non-relocatable library paths in {binary.name}: {changes}")
        if check_only and binary in helpers and not binary.stat().st_mode & 0o111:
            raise ValueError(f"Helper is not executable: {binary}")
        plan.append((binary, changes))

    if not check_only:
        for binary, changes in plan:
            if binary in helpers:
                binary.chmod(binary.stat().st_mode | 0o111)
            if changes:
                subprocess.run(["/usr/bin/install_name_tool", *changes, str(binary)], check=True)
        # Re-read the binaries rather than trusting install_name_tool's exit code.
        prepare(resources, check_only=True)
    return len(plan)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("resources", type=Path, help="Copied app's Contents/Resources")
    parser.add_argument("--check", action="store_true", help="Verify only; do not modify signed files")
    args = parser.parse_args()
    try:
        count = prepare(args.resources, check_only=args.check)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Device helper packaging failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified {count} device helpers/libraries: all non-system loads use @loader_path")
    return 0


if __name__ == "__main__":
    sys.exit(main())
