from __future__ import annotations

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

        self.environment = os.environ.copy()
        self.environment["HOME"] = str(self.root / "home")
        self.environment["XDG_DATA_HOME"] = str(self.root / "xdg")
        # Never read or write the developer's own granola.conf.
        self.config_file = self.root / "granola.conf"
        self.environment["GRANOLA_CONFIG_FILE"] = str(self.config_file)
        for key in ("GRANOLA_AUDIO", "GRANOLA_BLUETOOTH_HFP",
                    "GRANOLA_SCHEME_HANDLER"):
            self.environment.pop(key, None)
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
            # Never inherit a terminal: an unset option would prompt on it.
            stdin=subprocess.DEVNULL,
        )

    def test_install_uses_clean_name_and_uninstall_removes_entry(self) -> None:
        installed = self.run_desktop(
            "install", "--scheme-handler", str(self.app_dir)
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        contents = self.desktop_file.read_text(encoding="utf-8")

        self.assertIn("\nName=Granola\n", contents)
        self.assertNotIn("Name=Granola (", contents)
        self.assertIn(f'"{self.app_dir}/run-granola" %U\n', contents)
        self.assertIn(f"Icon={self.app_dir}/granola-app-icon.png\n", contents)
        self.assertIn("Categories=Office;\n", contents)
        self.assertIn("StartupNotify=true\n", contents)

        removed = self.run_desktop("uninstall")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(self.desktop_file.exists())

    def test_rejects_extra_install_arguments(self) -> None:
        result = self.run_desktop(
            "install", "--no-scheme-handler", str(self.app_dir), "unexpected"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at most one build directory", result.stderr)
        self.assertFalse(self.desktop_file.exists())

    def test_scheme_handler_claims_the_url_scheme(self) -> None:
        installed = self.run_desktop(
            "install", "--scheme-handler", str(self.app_dir)
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        contents = self.desktop_file.read_text(encoding="utf-8")
        self.assertIn("MimeType=x-scheme-handler/granola;\n", contents)
        self.assertIn("%U", contents)

    def test_no_scheme_handler_leaves_the_url_scheme_unclaimed(self) -> None:
        installed = self.run_desktop(
            "install", "--no-scheme-handler", str(self.app_dir)
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        contents = self.desktop_file.read_text(encoding="utf-8")
        self.assertNotIn("MimeType", contents)
        self.assertNotIn("%U", contents)

    def test_launcher_carries_explicit_audio_choices(self) -> None:
        self.config_file.write_text(
            "GRANOLA_AUDIO=0\nGRANOLA_BLUETOOTH_HFP=0\n", encoding="utf-8"
        )
        installed = self.run_desktop(
            "install", "--no-scheme-handler", str(self.app_dir)
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        # The launcher has no stdin, so it must never need to ask.
        self.assertIn(
            "Exec=/usr/bin/env GRANOLA_AUDIO=0 GRANOLA_BLUETOOTH_HFP=0 ",
            self.desktop_file.read_text(encoding="utf-8"),
        )

    def test_unset_scheme_handler_refuses_to_guess(self) -> None:
        result = self.run_desktop("install", str(self.app_dir))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--no-scheme-handler", result.stderr)
        self.assertFalse(self.desktop_file.exists())

    def test_config_file_supplies_the_scheme_handler_choice(self) -> None:
        self.config_file.write_text(
            "GRANOLA_SCHEME_HANDLER=1\n", encoding="utf-8"
        )
        installed = self.run_desktop("install", str(self.app_dir))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertIn(
            "MimeType=x-scheme-handler/granola;",
            self.desktop_file.read_text(encoding="utf-8"),
        )


if __name__ == "__main__":
    unittest.main()
