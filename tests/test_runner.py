from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


RUNNER = Path(__file__).parents[1] / "scripts" / "run-granola"
BLUETOOTH_SOURCE = "bluez_input.00:11:22:33:44:55"
BLUETOOTH_CARD = "bluez_card.00_11_22_33_44_55"


def make_socket(path: Path) -> None:
    """Leave a real AF_UNIX socket file behind, so run-granola's -S test passes."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as endpoint:
        endpoint.bind(str(path))


class RunnerTests(unittest.TestCase):
    def make_fake_runtime(self, root: Path, default_source: str) -> dict[str, str]:
        fake_bin = root / "bin"
        fake_bin.mkdir()
        state = root / "profile"
        calls = root / "calls"
        sandbox_args = root / "sandbox-args"
        state.write_text("a2dp-sink\n")
        calls.write_text("")
        sandbox_args.write_text("")

        pactl = fake_bin / "pactl"
        pactl.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                case "$1" in
                  get-default-source)
                    printf '%s\n' "$FAKE_DEFAULT_SOURCE"
                    ;;
                  --format=json)
                    printf '[]\n'
                    ;;
                  set-card-profile)
                    printf '%s\n' "$3" >"$FAKE_PROFILE_STATE"
                    printf 'profile %s %s\n' "$2" "$3" >>"$FAKE_CALLS"
                    ;;
                  set-default-source)
                    printf 'source %s\n' "$2" >>"$FAKE_CALLS"
                    ;;
                  *)
                    exit 2
                    ;;
                esac
                """
            )
        )
        pactl.chmod(0o755)

        jq = fake_bin / "jq"
        jq.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                cat >/dev/null
                case "$*" in
                  *active_profile*)
                    cat "$FAKE_PROFILE_STATE"
                    ;;
                  *)
                    printf '%s\n' '{BLUETOOTH_SOURCE}'
                    ;;
                esac
                """
            )
        )
        jq.chmod(0o755)

        # Records the container argv, then runs the fake electron in place of
        # the one the real image would provide at /opt/granola/electron.
        docker = fake_bin / "docker"
        docker.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                case "$1" in
                  image) exit 0 ;;
                  ps) printf '' ; exit 0 ;;
                esac
                printf '%s\n' "$*" >>"$FAKE_SANDBOX_ARGS"
                arguments=("$@")
                for ((index = 0; index < ${#arguments[@]}; index++)); do
                  if [[ "${arguments[index]}" == /opt/granola/electron ]]; then
                    exec "$FAKE_ELECTRON" "${arguments[@]:index+1}"
                  fi
                done
                exit 3
                """
            )
        )
        docker.chmod(0o755)

        electron = root / "electron"
        electron.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                printf 'electron %s\n' "$*" >>"$FAKE_CALLS"
                sleep 0.05
                exit "${FAKE_ELECTRON_EXIT:-0}"
                """
            )
        )
        electron.chmod(0o755)

        runtime_dir = root / "run"
        runtime_dir.mkdir()
        make_socket(runtime_dir / "wayland-0")
        make_socket(runtime_dir / "pipewire-0")
        make_socket(runtime_dir / "pulse" / "native")

        home = root / "home"
        home.mkdir()

        runner = root / "run-granola"
        runner.write_bytes(RUNNER.read_bytes())
        runner.chmod(0o755)
        return {
            **os.environ,
            "PATH": f"{fake_bin}:/usr/bin:/bin",
            "HOME": str(home),
            "XDG_RUNTIME_DIR": str(runtime_dir),
            "WAYLAND_DISPLAY": "wayland-0",
            "FAKE_CALLS": str(calls),
            "FAKE_SANDBOX_ARGS": str(sandbox_args),
            "FAKE_ELECTRON": str(root / "electron"),
            "FAKE_DEFAULT_SOURCE": default_source,
            "FAKE_ELECTRON_EXIT": "7",
            "FAKE_PROFILE_STATE": str(state),
            "GRANOLA_BLUETOOTH_POLL_SECONDS": "0.01",
            "GRANOLA_AUDIO": "1",
            "GRANOLA_BLUETOOTH_HFP": "1",
        }

    def run_runner(
        self, root: Path, env: dict[str, str], *arguments: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [root / "run-granola", *arguments],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            # Never inherit a terminal: an unset option would prompt on it.
            stdin=subprocess.DEVNULL,
        )

    def test_holds_bluetooth_mic_profile_and_restores_stereo(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, BLUETOOTH_SOURCE)

            result = self.run_runner(root, env, "--test-argument")

            self.assertEqual(result.returncode, 7)
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(
                calls[0], f"profile {BLUETOOTH_CARD} headset-head-unit"
            )
            self.assertEqual(calls[1], f"source {BLUETOOTH_SOURCE}")
            self.assertIn("--test-argument", calls[2])
            self.assertEqual(calls[-1], f"profile {BLUETOOTH_CARD} a2dp-sink")

    def test_leaves_non_bluetooth_default_input_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, "alsa_input.internal-mic")

            result = self.run_runner(root, env)

            self.assertEqual(result.returncode, 7)
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(len(calls), 1)
            self.assertTrue(calls[0].startswith("electron "))

    def test_disabled_bluetooth_hfp_never_calls_pactl(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, BLUETOOTH_SOURCE)
            env["GRANOLA_BLUETOOTH_HFP"] = "0"

            result = self.run_runner(root, env)

            self.assertEqual(result.returncode, 7)
            # A Bluetooth headset is the default input and audio is on, yet the
            # headset profile must be left completely alone.
            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(len(calls), 1)
            self.assertTrue(calls[0].startswith("electron "))

    def test_audio_binds_the_host_sound_sockets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, "alsa_input.internal-mic")

            self.run_runner(root, env)

            sandbox = (root / "sandbox-args").read_text()
            self.assertIn("pipewire-0", sandbox)
            # Flattened out of a subdirectory so Docker cannot create a
            # root-owned parent that libpulse then refuses to use.
            self.assertIn(":/run/user/1000/pulse-native", sandbox.replace(
                "/run/user/%d" % __import__("os").getuid(), "/run/user/1000"))
            self.assertIn("PULSE_SERVER=unix:", sandbox)
            calls = (root / "calls").read_text()
            self.assertIn("--enable-features=WebRTCPipeWireCapturer", calls)

    def test_disabled_audio_omits_the_host_sound_sockets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, "alsa_input.internal-mic")
            env["GRANOLA_AUDIO"] = "0"

            self.run_runner(root, env)

            sandbox = (root / "sandbox-args").read_text()
            self.assertNotIn("pipewire-0", sandbox)
            self.assertNotIn("pulse/native", sandbox)
            # The Wayland socket still goes in; only sound is withheld.
            self.assertIn("wayland-0", sandbox)
            calls = (root / "calls").read_text()
            self.assertNotIn("WebRTCPipeWireCapturer", calls)

    def test_disabled_audio_forces_bluetooth_hfp_off(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, BLUETOOTH_SOURCE)
            env["GRANOLA_AUDIO"] = "0"
            env["GRANOLA_BLUETOOTH_HFP"] = "1"

            self.run_runner(root, env)

            calls = (root / "calls").read_text().splitlines()
            self.assertEqual(len(calls), 1)
            self.assertTrue(calls[0].startswith("electron "))

    def test_container_isolates_the_home_directory_and_mounts_the_app_readonly(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, "alsa_input.internal-mic")

            self.run_runner(root, env)

            sandbox = (root / "sandbox-args").read_text()
            # --rm is what makes the container disappear when the window closes.
            self.assertIn("--rm", sandbox)
            self.assertIn("--tmpfs /home/granola:", sandbox)
            self.assertIn(f"--volume {env['HOME']}/.config/Granola:", sandbox)
            # The app tree goes in read-only; nothing else of the home does.
            self.assertIn(":/opt/granola:ro", sandbox)
            calls = (root / "calls").read_text()
            self.assertIn("--password-store=basic", calls)
            # Chromium cannot build its own sandbox in a container while
            # kernel.apparmor_restrict_unprivileged_userns=1, so this is
            # deliberate: the boundary kept is the container's, around the host.
            self.assertIn("--no-sandbox", calls)

    def make_config(self, root: Path, env: dict[str, str], body: str) -> None:
        project = root / "project"
        project.mkdir(exist_ok=True)
        (project / "granola.conf").write_text(body)
        (root / ".granola-linux-macos-build").write_text(
            f"granola_version=test\nproject_dir={project}\n"
        )
        env.pop("GRANOLA_AUDIO", None)
        env.pop("GRANOLA_BLUETOOTH_HFP", None)

    def test_config_file_supplies_the_choices(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, BLUETOOTH_SOURCE)
            self.make_config(
                root, env, "GRANOLA_AUDIO=0\nGRANOLA_BLUETOOTH_HFP=0\n"
            )

            self.run_runner(root, env)

            sandbox = (root / "sandbox-args").read_text()
            self.assertNotIn("pipewire-0", sandbox)
            self.assertEqual(
                len((root / "calls").read_text().splitlines()), 1
            )

    def test_environment_overrides_the_config_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, "alsa_input.internal-mic")
            self.make_config(root, env, "GRANOLA_AUDIO=0\n")
            env["GRANOLA_AUDIO"] = "1"

            self.run_runner(root, env)

            self.assertIn("pipewire-0", (root / "sandbox-args").read_text())

    def test_invalid_config_value_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.make_fake_runtime(root, "alsa_input.internal-mic")
            self.make_config(root, env, "GRANOLA_AUDIO=yes\n")

            result = self.run_runner(root, env)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("GRANOLA_AUDIO", result.stderr)
            self.assertEqual((root / "calls").read_text(), "")


if __name__ == "__main__":
    unittest.main()
