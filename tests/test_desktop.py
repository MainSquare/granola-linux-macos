from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).parents[1]
DESKTOP_SCRIPT = PROJECT_DIR / "desktop.sh"


class DesktopIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app_dir = self.root / "Granola build"
        self.app_dir.mkdir()
        runner = self.app_dir / "run-granola"
        runner.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        runner.chmod(0o755)
        (self.app_dir / ".granola-linux-macos-build").write_text(
            "granola_version=test\n", encoding="utf-8"
        )
        (self.app_dir / "granola-app-icon.png").write_bytes(b"test icon")
        self.native_host = self.app_dir / "resources" / "native-host" / "meet-consent-host"
        self.native_host.parent.mkdir(parents=True)
        self.native_host.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        self.native_host.chmod(0o755)
        (self.root / "config" / "google-chrome").mkdir(parents=True)

        self.environment = os.environ.copy()
        self.environment["HOME"] = str(self.root / "home")
        self.environment["XDG_DATA_HOME"] = str(self.root / "xdg")
        self.environment["XDG_CONFIG_HOME"] = str(self.root / "config")
        self.desktop_file = (
            self.root
            / "xdg"
            / "applications"
            / "granola-linux-macos.desktop"
        )

    def run_desktop(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(DESKTOP_SCRIPT), *arguments],
            check=False,
            capture_output=True,
            env=self.environment,
            text=True,
        )

    def test_install_uses_clean_name_and_uninstall_removes_entry(self) -> None:
        installed = self.run_desktop("install", str(self.app_dir))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        contents = self.desktop_file.read_text(encoding="utf-8")

        self.assertIn("\nName=Granola\n", contents)
        self.assertNotIn("Name=Granola (", contents)
        self.assertIn(f'Exec="{self.app_dir}/run-granola" %U\n', contents)
        self.assertIn(f"Icon={self.app_dir}/granola-app-icon.png\n", contents)
        self.assertIn("Categories=Office;\n", contents)
        self.assertIn("StartupNotify=true\n", contents)

        removed = self.run_desktop("uninstall")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(self.desktop_file.exists())

    def test_registers_companion_host_only_for_installed_browsers(self) -> None:
        installed = self.run_desktop("install", str(self.app_dir))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        manifest = (
            self.root / "config" / "google-chrome" / "NativeMessagingHosts" / "com.granola.app.json"
        )
        contents = json.loads(manifest.read_text(encoding="utf-8"))
        self.assertEqual(contents["name"], "com.granola.app")
        self.assertEqual(contents["path"], str(self.native_host))
        self.assertIn(
            "chrome-extension://opaadbjlebbbnmjjgdmdllingedoleml/", contents["allowed_origins"]
        )
        self.assertFalse((self.root / "config" / "chromium").exists())

        removed = self.run_desktop("uninstall")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(manifest.exists())

    def test_escapes_companion_host_path_in_manifest(self) -> None:
        escaped_dir = self.root / "Granola\\build"
        self.app_dir.rename(escaped_dir)
        installed = self.run_desktop("install", str(escaped_dir))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        manifest = (
            self.root / "config" / "google-chrome" / "NativeMessagingHosts" / "com.granola.app.json"
        )
        contents = json.loads(manifest.read_text(encoding="utf-8"))
        self.assertEqual(
            contents["path"], str(escaped_dir / "resources" / "native-host" / "meet-consent-host")
        )

    def test_rejects_extra_install_arguments(self) -> None:
        result = self.run_desktop("install", str(self.app_dir), "unexpected")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at most one build directory", result.stderr)
        self.assertFalse(self.desktop_file.exists())


if __name__ == "__main__":
    unittest.main()
