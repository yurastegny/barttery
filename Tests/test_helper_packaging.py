"""Dependency-closure regression tests; no certificates or devices required."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("helper_packaging", ROOT / "scripts/prepare-device-helpers.py")
packaging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packaging)
SYSTEM = "/usr/lib/libSystem.B.dylib"


def commands(dependencies, identifiers=()):
    result = []
    for number, (command, name) in enumerate(
        [("LC_ID_DYLIB", name) for name in identifiers]
        + [("LC_LOAD_DYLIB", name) for name in dependencies]
    ):
        result.append(f"Load command {number}\n  cmd {command}\n  name {name} (offset 24)")
    return "\n".join(result)


class HelperPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="barttery packaging test ")
        self.addCleanup(self.temp.cleanup)
        self.resources = Path(self.temp.name) / "Barttery.app/Contents/Resources"
        self.resources.mkdir(parents=True)
        self.binaries = {}
        for name in packaging.HELPERS:
            self.binaries[name] = ([SYSTEM, "@executable_path/../lib/libdevice.dylib"], [])
        self.binaries["libdevice.dylib"] = (
            [SYSTEM, "@rpath/libtransport.dylib"], ["/opt/homebrew/lib/libdevice.dylib"]
        )
        self.binaries["libtransport.dylib"] = ([SYSTEM], ["@executable_path/../lib/libtransport.dylib"])
        for name in self.binaries:
            (self.resources / name).write_bytes(b"copied Mach-O fixture")

    def inspect(self, args, **kwargs):
        dependencies, identifiers = self.binaries[Path(args[-1]).name]
        return commands(dependencies, identifiers)

    def relocate(self, args, **kwargs):
        dependencies, identifiers = self.binaries[Path(args[-1]).name]
        index = 1
        while index < len(args) - 1:
            if args[index] == "-change":
                old, new = args[index + 1:index + 3]
                dependencies[:] = [new if dep == old else dep for dep in dependencies]
                index += 3
            elif args[index] == "-id":
                identifiers[:] = [args[index + 1]]
                index += 2
            else:
                self.fail(f"Unexpected install_name_tool argument: {args[index]}")
        return subprocess.CompletedProcess(args, 0)

    def test_parser_separates_ids_and_deduplicates_universal_slices(self):
        text = commands([SYSTEM, "@rpath/libdevice.dylib"], ["old-id"])
        dependencies, identifiers = packaging.load_commands(text + "\n" + text)
        self.assertEqual(dependencies, {SYSTEM, "@rpath/libdevice.dylib"})
        self.assertEqual(identifiers, {"old-id"})

    def test_resolves_legacy_absolute_and_loader_relative_paths(self):
        libraries = {"libdevice.dylib": None}
        for original in ("@executable_path/../lib/libdevice.dylib", "/opt/homebrew/lib/libdevice.dylib",
                         "@rpath/libdevice.dylib", "@loader_path/libdevice.dylib"):
            self.assertEqual(packaging.desired_dependency(original, libraries), "@loader_path/libdevice.dylib")
        self.assertEqual(packaging.desired_dependency(SYSTEM, libraries), SYSTEM)
        with self.assertRaisesRegex(ValueError, "Unbundled"):
            packaging.desired_dependency("/opt/homebrew/lib/missing.dylib", libraries)

    def test_relocates_transitive_dependencies_before_signing_and_is_idempotent(self):
        with patch.object(packaging.subprocess, "check_output", side_effect=self.inspect), \
             patch.object(packaging.subprocess, "run", side_effect=self.relocate) as install:
            self.assertEqual(packaging.prepare(self.resources), 8)
            self.assertTrue(install.called)
            for helper in packaging.HELPERS:
                self.assertTrue((self.resources / helper).stat().st_mode & 0o111)
            self.assertIn("@loader_path/libtransport.dylib", self.binaries["libdevice.dylib"][0])
            self.assertEqual(self.binaries["libdevice.dylib"][1], ["@loader_path/libdevice.dylib"])
            install.reset_mock()
            packaging.prepare(self.resources)
            packaging.prepare(self.resources, check_only=True)
            install.assert_not_called()

    def test_check_mode_rejects_the_published_broken_layout_without_modifying_it(self):
        with patch.object(packaging.subprocess, "check_output", side_effect=self.inspect), \
             patch.object(packaging.subprocess, "run") as install:
            with self.assertRaisesRegex(ValueError, "Non-relocatable"):
                packaging.prepare(self.resources, check_only=True)
            install.assert_not_called()

    def test_missing_transitive_library_fails_before_any_changes(self):
        (self.resources / "libtransport.dylib").unlink()
        with patch.object(packaging.subprocess, "check_output", side_effect=self.inspect), \
             patch.object(packaging.subprocess, "run") as install:
            with self.assertRaisesRegex(ValueError, "Unbundled"):
                packaging.prepare(self.resources)
            install.assert_not_called()
            self.assertFalse((self.resources / "bartbeat").stat().st_mode & 0o111)

    def test_missing_helper_fails(self):
        (self.resources / "wifiwatch").unlink()
        with self.assertRaisesRegex(ValueError, "Missing"):
            packaging.prepare(self.resources)

    def test_non_macho_helper_fails_before_any_changes(self):
        with patch.object(packaging.subprocess, "check_output", return_value="not an object file"), \
             patch.object(packaging.subprocess, "run") as install:
            with self.assertRaisesRegex(ValueError, "Not a dynamic Mach-O"):
                packaging.prepare(self.resources)
            install.assert_not_called()

    def test_source_helpers_are_never_modified(self):
        with self.assertRaisesRegex(ValueError, "source helpers"):
            packaging.prepare(ROOT / "Sources/Resources")

    def test_both_build_systems_relocate_before_signing(self):
        for filename in ("project.yml", "Makefile"):
            text = (ROOT / filename).read_text()
            self.assertLess(text.index("scripts/prepare-device-helpers.py"), text.index("codesign --force"))
        self.assertNotIn("DYLD_LIBRARY_PATH", (ROOT / "Sources/IDeviceReader.swift").read_text())


if __name__ == "__main__":
    unittest.main()
